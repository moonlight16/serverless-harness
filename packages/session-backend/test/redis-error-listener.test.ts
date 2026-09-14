import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EventEmitter } from 'node:events';

/**
 * A client that loses its socket must not take the worker with it.
 *
 * node-redis clients are EventEmitters, and `RedisSocket.#onSocketError` re-emits every socket error
 * on the client -- so with no `'error'` listener an established connection dropping is an uncaught
 * exception and Node exits 1. Probed on the pinned `redis@6.2.1` with `CLIENT KILL` against the
 * probe's own connection: no listener exits on an uncaught `SocketClosedUnexpectedlyError`, one
 * listener handles it and node-redis reconnects by itself.
 *
 * `redis-backend-rearm.test.ts` cannot see this: its mock is a plain object, so nothing ever emits.
 * This mock is a real EventEmitter for exactly that reason.
 *
 * The failure needs no in-flight turn to blame, which is what makes it worse here than it was: the
 * store is memoised for the process's life (run-turn.ts `sharedSessionStore`), so a Redis restart
 * while a worker sits idle is enough.
 */
class FakeClient extends EventEmitter {
  isOpen = false;
  connect = vi.fn(async () => undefined);
  quit = vi.fn(async () => 'OK');
  keys = vi.fn(async () => [] as string[]);
}

let client: FakeClient;
vi.mock('redis', () => ({ createClient: () => client }));

const { RedisSessionBackend } = await import('../src/redis-backend');

beforeEach(() => {
  client = new FakeClient();
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('RedisSessionBackend error listener', () => {
  it('survives an error emitted on an established connection', () => {
    new RedisSessionBackend();

    // The assertion that fails without the listener: EventEmitter.emit('error') with no listener
    // rethrows, which in the real client is an uncaught exception rather than a rejected promise.
    expect(() => client.emit('error', new Error('Socket closed unexpectedly'))).not.toThrow();
    expect(client.listenerCount('error')).toBe(1);
  });

  it('does not swallow the failure a caller is awaiting', async () => {
    client.connect.mockRejectedValueOnce(new Error('connect ETIMEDOUT'));
    const b = new RedisSessionBackend();

    // The listener is for unawaited EVENTS; a rejected command still reaches its caller.
    await expect(b.list()).rejects.toThrow('connect ETIMEDOUT');
  });
});
