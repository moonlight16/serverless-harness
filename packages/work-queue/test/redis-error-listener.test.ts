import { describe, it, expect, vi, beforeEach } from 'vitest';
import { EventEmitter } from 'node:events';

/**
 * The queue client outlives every entry it serves, so a dropped socket must not end the worker.
 *
 * node-redis re-emits socket errors on the client, and an EventEmitter `'error'` with no listener is
 * an uncaught exception — proven with `CLIENT KILL` on the pinned redis@6.2.1, where a listener
 * instead lets node-redis reconnect by itself. The async worker holds one queue for its whole life,
 * so an idle-time Redis restart is enough to reach this.
 *
 * `queue.test.ts` drives a real Redis and so never exercises the emit; this mock is an EventEmitter
 * for exactly that reason.
 */
class FakeClient extends EventEmitter {
  isOpen = false;
  connect = vi.fn(async () => undefined);
  close = vi.fn(async () => undefined);
}

let client: FakeClient;
vi.mock('redis', () => ({ createClient: () => client }));

const { RedisWorkQueue } = await import('../src/queue');

beforeEach(() => {
  client = new FakeClient();
  vi.spyOn(console, 'error').mockImplementation(() => {});
});

describe('RedisWorkQueue error listener', () => {
  it('survives an error emitted on an established connection', () => {
    new RedisWorkQueue();

    expect(() => client.emit('error', new Error('Socket closed unexpectedly'))).not.toThrow();
    expect(client.listenerCount('error')).toBe(1);
  });
});
