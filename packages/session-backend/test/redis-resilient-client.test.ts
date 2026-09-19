import { describe, it, expect, vi } from 'vitest';
import { resilientClientOptions } from '../src/redis-errors';

/**
 * The listener and the reconnect bound are ONE fix; either alone is a different bug.
 *
 * Registering `'error'` stops the crash — an unhandled `'error'` on a node-redis client exits the
 * process, which is how a supervisor worker and an E11 relay died. But it also consumes the error
 * that used to make a failed `connect()` REJECT, so with node-redis's default (unbounded, backing-off)
 * strategy the attempt retries forever and `connect()` never settles. Probed on the pinned redis 6.2.1
 * against a dead port: no listener rejects in ~1 ms, listener-only was still pending at 6 s, listener
 * plus a bounded strategy rejects with `ReconnectStrategyError` — in ~5.5 s at the DEFAULT bound, whose
 * delays are the only cost against a refused port, and in milliseconds at the reduced bound these tests
 * use. A black-holed SYN pays the full 5 s `connectTimeout` per attempt instead, so ~60 s to reject —
 * bounded either way, but size nothing against the refused-port number (see `redis-errors.ts`).
 *
 * A hang is worse here than the crash it replaced. `RedisSessionBackend.arm()` re-arms by clearing its
 * memo when `connect()` rejects, so a promise that never settles does not merely delay a turn — it
 * disables the retry and every caller awaits forever, with nothing logged.
 *
 * #251 landed the same pairing for `RedisRecordStore`, reasoned from the same probe. This keeps the
 * two consistent instead of leaving one store fail-fast and four hanging.
 */
describe('resilientClientOptions', () => {
  it('bounds the reconnect so an absent Redis rejects instead of retrying forever', () => {
    const { socket } = resilientClientOptions('redis://127.0.0.1:6399', 3);

    // Under the bound: a number, i.e. "wait then retry".
    expect(typeof socket.reconnectStrategy(0)).toBe('number');
    expect(typeof socket.reconnectStrategy(3)).toBe('number');
    // Past it: an Error, which is how node-redis abandons the attempt and rejects connect().
    expect(socket.reconnectStrategy(4)).toBeInstanceOf(Error);
  });

  it('names the unreachable URL in the giving-up error, since this surfaces at startup', () => {
    const { socket } = resilientClientOptions('redis://db:6379', 1);

    expect(String(socket.reconnectStrategy(2))).toContain('redis://db:6379');
  });

  it('backs off rather than hot-looping, and caps the delay', () => {
    const { socket } = resilientClientOptions('redis://x:6379', 100);
    const delays = [0, 1, 5, 50].map((r) => socket.reconnectStrategy(r) as number);

    expect(delays.every((d) => d >= 0)).toBe(true);
    expect(delays[0]).toBeLessThanOrEqual(delays[3]);
    expect(Math.max(...delays)).toBeLessThanOrEqual(1000);
  });

  it('tolerates a transient blip within the bound, which is the case it exists for', () => {
    // A container recreated, or `docker run -d` returning before Redis accepts: the default bound
    // spans several seconds of retrying before it gives up.
    const { socket } = resilientClientOptions('redis://x:6379');
    expect(typeof socket.reconnectStrategy(5)).toBe('number');
  });
});

describe('swallowRedisErrors', () => {
  it('logs and does not rethrow, so the emit cannot reach the process', async () => {
    const { swallowRedisErrors } = await import('../src/redis-errors');
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const handlers: ((err: unknown) => void)[] = [];
    swallowRedisErrors({ on: (_e, h) => handlers.push(h) }, 'test store');

    expect(handlers).toHaveLength(1);
    expect(() => handlers[0](new Error('Socket closed unexpectedly'))).not.toThrow();
    expect(spy).toHaveBeenCalledWith(expect.stringContaining('test store'));
  });
});
