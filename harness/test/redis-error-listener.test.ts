import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EventEmitter } from 'node:events';

/**
 * Every long-lived client in the harness must register `'error'`, or losing a socket ends the worker.
 *
 * node-redis re-emits socket errors on the client (`RedisSocket.#onSocketError`), and an EventEmitter
 * `'error'` with no listener is an uncaught exception. The initial-connect path is NOT the dangerous
 * one — it emits from inside the awaited `connect()` chain, so the throw becomes that promise's
 * rejection — which is why the omission survived review for so long. The dangerous one is a drop on
 * an ESTABLISHED connection, verified with `CLIENT KILL` against the probe's own connection on the
 * pinned redis@6.2.1: no listener exits on `SocketClosedUnexpectedlyError`, one listener recovers.
 *
 * These three stores are all memoised for the process's life (`select-sandbox.ts` for two of them),
 * so no turn need be in flight for a Redis restart to reach them.
 *
 * `RedisRecordStore` is included even though #251 gave it its own inline copy of the pairing: this is
 * the cross-cutting pin that a NEW long-lived store cannot be added without one, and it is cheap.
 * The bound that must accompany the listener is pinned separately, in
 * `packages/session-backend/test/redis-resilient-client.test.ts`.
 */
class FakeClient extends EventEmitter {
  isOpen = false;
  // Flipped as node-redis does (socket.js:170), which nothing here observes today -- the cases below
  // only construct and emit. It is here because `RedisResultStore.open()` now re-arms on !isOpen, so a
  // fake stuck at false would make any future case that awaits a store method reconnect on every call.
  connect = vi.fn(async () => {
    this.isOpen = true;
    return undefined;
  });
  quit = vi.fn(async () => 'OK');
  close = vi.fn(async () => undefined);
}

let client: FakeClient;
vi.mock('redis', () => ({ createClient: () => client }));

const { RedisRecordStore } = await import('../src/pool-records.js');
const { RedisLeaseStore } = await import('../src/sandbox-lease.js');
const { RedisResultStore } = await import('../src/leaf-result-store.js');

beforeEach(() => {
  client = new FakeClient();
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe.each([
  ['RedisRecordStore', () => new RedisRecordStore()],
  ['RedisLeaseStore', () => new RedisLeaseStore()],
  ['RedisResultStore', () => new RedisResultStore()],
])('%s error listener', (_name, build) => {
  it('survives an error emitted on an established connection', () => {
    build();

    expect(() => client.emit('error', new Error('Socket closed unexpectedly'))).not.toThrow();
    expect(client.listenerCount('error')).toBe(1);
  });
});
