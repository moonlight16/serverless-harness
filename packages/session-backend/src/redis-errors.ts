// packages/session-backend/src/redis-errors.ts

/** The slice of a node-redis client this needs: it is an EventEmitter. */
type ErrorEmitter = { on(event: 'error', listener: (err: unknown) => void): unknown };

/**
 * Register the `'error'` listener every long-lived node-redis client needs, so losing a socket costs
 * a reconnect rather than the process.
 *
 * node-redis clients are EventEmitters and `RedisSocket.#onSocketError` re-emits every socket error
 * on the client, so with no listener Node treats it as an uncaught exception and exits 1. It is
 * specifically the ESTABLISHED-connection path that is fatal. A failed initial `connect()` emits too,
 * but from inside the awaited `connect()` chain, so the throw surfaces as that promise's rejection
 * and the process survives — which is why the pattern looked safe for as long as it did, and why the
 * promise-side `.catch` in `RedisSessionBackend.arm()` does not cover this.
 *
 * Probed against the pinned `redis@6.2.1`, `CLIENT KILL` on the probe's own connection: with no
 * listener the process exits on an uncaught `SocketClosedUnexpectedlyError`; with one, the error is
 * handled and node-redis reconnects on its own (`isOpen` stays true). So the listener is what ENABLES
 * the built-in recovery, not just what hides the error.
 *
 * Two P6 observations were exactly this: recreating the Redis container under a running supervisor
 * killed worker 0 and `sh-relay.service`, and an E11 driver — which starts its own relay, with no
 * supervisor to restart it — lost the relay the same way and then burned a 360s client deadline.
 *
 * Every store using this is memoised for the process's life, which is what raises the stakes: there
 * need not be an in-flight turn for the drop to matter, so an idle-time Redis restart is enough.
 *
 * Log-and-swallow is the whole job. This suppresses nothing a caller awaits — a failed command still
 * rejects through its own promise — and the log is what tells an operator the reconnect happened.
 */
export function swallowRedisErrors(client: ErrorEmitter, label: string): void {
  client.on('error', (err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[redis] ${label}: ${message} (node-redis will reconnect)`);
  });
}
