import { describe, it, expect, vi, beforeEach } from 'vitest';

/**
 * A failed connect must cost ONE call, not the process.
 *
 * `ready` used to be assigned once in the constructor and never reassigned, so a rejected
 * `connect()` left a permanently REJECTED promise that every method awaited for the life of the
 * object. Per-turn construction hid that -- a blip cost exactly one turn, and the next turn built a
 * fresh client -- but run-turn.ts now memoises ONE backend process-wide, which turns the same
 * transient failure into a permanent outage for every remaining turn the worker serves.
 *
 * `connect()` really can reject, and both common shapes do: probed against the pinned redis@6.2.1, a
 * refused connect rejects with `ECONNREFUSED` and a black-holed SYN rejects with
 * `ConnectionTimeoutError` once the 5s default `connectTimeout` fires. (The socket schedules its own
 * background retry in both cases, but the attempt this promise represents is already lost, which is
 * what the re-arm is about.) In a cluster the second is the COMMON transient shape: a Service with no
 * ready endpoints, or a NetworkPolicy drop, black-holes the SYN instead of refusing it.
 *
 * The `redis` module is mocked rather than pointed at a dead port because a black-holed address costs
 * 5s per attempt and depends on the network answering with silence rather than ICMP.
 *
 * This file proves the BOOKKEEPING only. Its mock is a plain object, so it cannot emit -- the crash
 * this re-arm was once thought to prevent lives on the event channel and is pinned separately, in
 * `redis-error-listener.test.ts`.
 */
const connect = vi.fn<() => Promise<void>>();
const quit = vi.fn(async () => 'OK');
const keys = vi.fn(async () => [] as string[]);
// `on` is a stub, not an emitter: the constructor registers its 'error' listener through it, and
// nothing here ever fires one. That is the boundary between the two files -- the crash on the event
// channel is `redis-error-listener.test.ts`, which mocks a real EventEmitter for it.
const on = vi.fn();
const client = { connect, quit, keys, on, isOpen: false };

vi.mock('redis', () => ({
  createClient: () => client,
}));

const { RedisSessionBackend } = await import('../src/redis-backend');

beforeEach(() => {
  connect.mockReset();
  quit.mockClear();
  on.mockClear();
  client.isOpen = false;
});

describe('RedisSessionBackend connect re-arm', () => {
  it('retries the connect on the next call after one fails', async () => {
    connect.mockRejectedValueOnce(new Error('connect ETIMEDOUT')).mockResolvedValueOnce(undefined);

    const b = new RedisSessionBackend(); // attempt 1, eager, as before

    await expect(b.list()).rejects.toThrow('connect ETIMEDOUT');
    // The assertion that fails on the old code: `ready` held one rejected promise, so this call
    // replayed the SAME error and never attempted a second connect.
    await expect(b.list()).resolves.toEqual([]);
    expect(connect).toHaveBeenCalledTimes(2);
  });

  it('does not re-attempt while a connect is still in flight or has succeeded', async () => {
    connect.mockResolvedValue(undefined);
    const b = new RedisSessionBackend();

    await Promise.all([b.list(), b.list(), b.list()]);

    // One connection per backend is the whole point of memoising it -- a re-arm that fired on the
    // happy path would put the per-turn leak straight back.
    expect(connect).toHaveBeenCalledTimes(1);
  });

  it('surfaces the LATEST attempt error, not a replay of the first', async () => {
    connect
      .mockRejectedValueOnce(new Error('first ETIMEDOUT'))
      .mockRejectedValueOnce(new Error('second ETIMEDOUT'));
    const b = new RedisSessionBackend();

    await expect(b.list()).rejects.toThrow('first ETIMEDOUT');
    // On the old code this second call replayed the cached `first` rejection forever -- Redis
    // recovering could not change the answer. Seeing the second attempt's own error is the
    // observable difference.
    await expect(b.list()).rejects.toThrow('second ETIMEDOUT');
    expect(connect).toHaveBeenCalledTimes(2);
  });

  it('close() resolves for a client that never connected', async () => {
    // close() used to `await this.ready`, so it could not close a never-connected client at all: it
    // rejected, callers swallowed that with `.catch(() => {})`, and the socket was left dangling --
    // a leak inside the teardown that exists to prevent leaks.
    connect.mockRejectedValue(new Error('connect ETIMEDOUT'));
    const b = new RedisSessionBackend();
    await expect(b.list()).rejects.toThrow();

    await expect(b.close()).resolves.toBeUndefined();
    expect(quit).not.toHaveBeenCalled(); // nothing was open to quit
  });

  it('close() quits a client that did connect', async () => {
    connect.mockResolvedValue(undefined);
    const b = new RedisSessionBackend();
    await b.list();
    client.isOpen = true;

    await b.close();

    expect(quit).toHaveBeenCalledTimes(1);
  });
});
