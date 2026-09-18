import { describe, expect, it } from 'vitest';
import { RedisLeaseStore } from '../src/sandbox-lease.js';

/**
 * `close()` must not reject on the store whose connect FAILED — the one path that actually closes it.
 *
 * `dropMemo` (select-sandbox.ts) closes the store it evicts, and a rejected `connect()` is exactly
 * what triggers that eviction: the first command rejects, `guard` drops the memo, and the drop closes
 * the store. `close()` began with a bare `await this.ready`, so on that store it re-threw the connect's
 * rejection and never reached `client.close()`.
 *
 * Nothing leaks today — probed on the pinned redis 6.2.1, a client past the reconnect bound has
 * `isOpen: false` and its socket already destroyed, and `close()` on it rejects `ClientClosedError`
 * either way — so this is the two sibling classes' shape (`RedisRecordStore.close`,
 * `RedisSessionBackend.close`) applied to the third, not a leak fix. It matters because every current
 * caller happens to swallow (`void store.close().catch(() => {})`) and the next one need not: a
 * teardown helper that awaits would fail on the failure path, which is the path teardown exists for.
 *
 * Runs against a port nothing listens on, so it needs no Redis, and passes `maxReconnectAttempts = 0`
 * — the seam `resilientClientOptions` and `RedisRecordStore` already expose — so it gives up on the
 * first failed attempt. At the default bound the same assertion costs ~5.5 s of real backoff
 * (redis-errors.ts) for a property that is about two lines of `close()` and nothing about timing; it
 * would also move whenever that ladder is retuned.
 */
describe('RedisLeaseStore.close() on a store that never connected', () => {
  it('resolves rather than re-throwing the connect rejection', async () => {
    const store = new RedisLeaseStore('redis://127.0.0.1:6399', Date.now, 0);
    const started = Date.now();

    // The command rejects loudly — that half is `resilientClientOptions`' bound doing its job.
    await expect(store.load('sandbox-0-0')).rejects.toThrow();

    // ...and tearing the store down afterwards is the normal path, not an error.
    await expect(store.close()).resolves.toBeUndefined();

    // The seam is load-bearing for this file, not decoration: without it the two assertions above
    // wait out the real ladder. Generous enough not to flake on a loaded CI box, tight enough to fail
    // if the seam stops being honoured.
    expect(Date.now() - started).toBeLessThan(2_000);
  });
});
