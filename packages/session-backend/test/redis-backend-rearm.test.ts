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
 * `connect()` really can reject, though NOT for the reason one would guess. With node-redis's
 * default options an ECONNREFUSED retries forever (`defaultReconnectStrategy` returns an
 * exponential backoff), so a refused connect HANGS rather than failing. The rejecting path is the
 * 5s default `connectTimeout`: it raises `SocketTimeoutError`, and that is the one cause
 * `defaultReconnectStrategy` answers `false` to -- so the attempt is abandoned and `connect()`
 * rejects with no retry. In a cluster that is the COMMON transient shape: a Service with no ready
 * endpoints, or a NetworkPolicy drop, black-holes the SYN instead of refusing it.
 *
 * The `redis` module is mocked rather than pointed at a dead port because both real failure modes
 * are bad tests -- a refused connect retries forever (the test hangs), and a black-holed address
 * costs 5s per attempt and depends on the network answering with silence rather than ICMP.
 */
const connect = vi.fn<() => Promise<void>>();
const quit = vi.fn(async () => 'OK');
const keys = vi.fn(async () => [] as string[]);
const client = { connect, quit, keys, isOpen: false };

vi.mock('redis', () => ({
  createClient: () => client,
}));

const { RedisSessionBackend } = await import('../src/redis-backend');

beforeEach(() => {
  connect.mockReset();
  quit.mockClear();
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
