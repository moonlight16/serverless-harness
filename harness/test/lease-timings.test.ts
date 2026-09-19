import { describe, it, expect } from 'vitest';
import { leaseTimings } from '../src/lease-timings.js';

/**
 * `Number(env.X ?? default)` — what this replaces at every lease-taking path (`/turn` plus the three
 * leaf kinds) — misreads two shapes that reach production, and both land on the same place:
 *
 *  - `??` does not catch an empty string, so `KAGENTI_SANDBOX_HEARTBEAT_MS=` (set-but-empty, which is
 *    what an unset variable substituted into a manifest looks like) yields `Number('') === 0`.
 *  - anything unparseable (`20s`, `abc`) yields `NaN`.
 *
 * `setInterval` clamps 0 and NaN alike to **1 ms** — roughly 1000 lease renewals per second per
 * in-flight turn, against the Redis this PR exists to stop overloading. This file's sibling knowledge
 * is `server.ts`'s `intEnv`, added after the same class of bug emitted `Retry-After: NaN`.
 *
 * The clamp is the second half. `heartbeatMs` and `ttlMs` were independent, so
 * `KAGENTI_SANDBOX_LEASE_TTL_MS=15000` alone expired the lease before its first renewal: the sandbox
 * returned to the pool mid-turn and another turn could take the same pod past cap. ttl/3 guarantees
 * three attempts within a TTL and is exactly the default pairing (60000/3 = 20000), so a deployment
 * that overrides neither sees no change at all.
 */
describe('leaseTimings', () => {
  it('keeps the historical defaults when nothing is set', () => {
    expect(leaseTimings({})).toEqual({ cap: 20, ttlMs: 60000, heartbeatMs: 20000 });
  });

  it('reads valid overrides', () => {
    const t = leaseTimings({
      KAGENTI_SANDBOX_CAP: '4',
      KAGENTI_SANDBOX_LEASE_TTL_MS: '90000',
      KAGENTI_SANDBOX_HEARTBEAT_MS: '10000',
    });
    expect(t).toEqual({ cap: 4, ttlMs: 90000, heartbeatMs: 10000 });
  });

  it.each([
    ['empty string', ''],
    ['unparseable', '20s'],
    ['not a number at all', 'abc'],
    ['zero', '0'],
    ['negative', '-5'],
  ])('falls back to the default heartbeat for %s rather than a 1 ms renewal loop', (_n, raw) => {
    expect(leaseTimings({ KAGENTI_SANDBOX_HEARTBEAT_MS: raw }).heartbeatMs).toBe(20000);
  });

  it.each([
    ['empty string', ''],
    ['unparseable', 'abc'],
    ['zero', '0'],
  ])('falls back to the default cap and ttl for %s', (_n, raw) => {
    const t = leaseTimings({ KAGENTI_SANDBOX_CAP: raw, KAGENTI_SANDBOX_LEASE_TTL_MS: raw });
    expect(t.cap).toBe(20);
    expect(t.ttlMs).toBe(60000);
  });

  it('clamps the heartbeat so a short TTL cannot expire before its first renewal', () => {
    // The reported case: TTL alone lowered, heartbeat left at its 20s default.
    expect(leaseTimings({ KAGENTI_SANDBOX_LEASE_TTL_MS: '15000' }).heartbeatMs).toBe(5000);
  });

  // This case previously asserted `heartbeatMs === 1` for TTL=1 -- it documented that the clamp's own
  // `max(1, ...)` was the only thing standing between a 1 ms TTL and a 0 ms interval. That made the
  // hardening one-sided: the HEARTBEAT knob fell back to a default rather than produce a 1 ms renewal
  // loop, while the TTL knob could still produce one through the clamp (floor(1/3) = 0 -> max(1,0) = 1).
  // A 1 s floor on the TTL closes that side, so the 1 ms loop is now unreachable from either knob.
  it.each([
    ['1 ms', '1'],
    ['just under the floor', '999'],
  ])(
    'falls back to the default TTL for %s rather than clamping to a 1 ms renewal loop',
    (_n, raw) => {
      const t = leaseTimings({ KAGENTI_SANDBOX_LEASE_TTL_MS: raw });
      expect(t.ttlMs).toBe(60000);
      expect(t.heartbeatMs).toBe(20000);
    },
  );

  it('accepts the floor itself, so the boundary is inclusive', () => {
    // 1000 is a real (if impractical) value, not a rejected one -- the floor is `>= min`, and getting
    // this edge wrong would silently widen the fallback to a range operators might actually set.
    const t = leaseTimings({ KAGENTI_SANDBOX_LEASE_TTL_MS: '1000' });
    expect(t.ttlMs).toBe(1000);
    expect(t.heartbeatMs).toBe(333);
  });

  it('leaves a heartbeat already inside ttl/3 alone', () => {
    expect(
      leaseTimings({ KAGENTI_SANDBOX_LEASE_TTL_MS: '90000', KAGENTI_SANDBOX_HEARTBEAT_MS: '5000' })
        .heartbeatMs,
    ).toBe(5000);
  });
});
