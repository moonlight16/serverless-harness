/**
 * Integer env knob with a floor: `def` when unset, empty, unparseable, or below `min`.
 *
 * Replaces `Number(env.X ?? '20000')`, which misread two shapes that reach production — `??` does not
 * catch an empty string (`Number('') === 0`) and anything unparseable yields `NaN`. For an interval
 * both clamp to 1 ms, i.e. ~1000 Redis writes a second per in-flight turn. knative-server's `intEnv`
 * (server.ts) is the same answer to the same class of bug, added after it emitted `Retry-After: NaN`;
 * this one is harness-side because that one is not importable from here.
 */
function intEnv(env: NodeJS.ProcessEnv, name: string, def: number, min = 1): number {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return def;
  const n = Number(raw);
  return Number.isFinite(n) && n >= min ? Math.floor(n) : def;
}

/** The three knobs a pool lease is taken and kept under. */
export interface LeaseTimings {
  /** Soft cap on concurrent leases per sandbox. */
  cap: number;
  /** How long an acquired lease survives without a renewal. */
  ttlMs: number;
  /** Renewal interval, guaranteed to fit inside `ttlMs` (see below). */
  heartbeatMs: number;
}

/**
 * Read the lease knobs once, in one place, with the one relation between them enforced.
 *
 * Shared by `/turn` (acquireTurnSandbox) and all three leaf paths deliberately: they lease from the
 * SAME store, and two conventions for one store is how a cap comes to mean different things depending
 * on which path took the lease. Previously each of the four inlined its own `Number(...)`, so hardening
 * one would have created exactly that divergence.
 *
 * The clamp is the part nothing enforced before. `heartbeatMs` and `ttlMs` were independent knobs, so
 * `KAGENTI_SANDBOX_LEASE_TTL_MS=15000` on its own expired the lease before its first renewal: the
 * sandbox returned to the pool mid-turn, and another turn could then take the same pod past cap.
 * ttl/3 gives three renewal attempts inside a TTL and is exactly the default pairing
 * (60000/3 = 20000), so a deployment overriding neither is byte-for-byte unaffected.
 */
export function leaseTimings(env: NodeJS.ProcessEnv): LeaseTimings {
  const cap = intEnv(env, 'KAGENTI_SANDBOX_CAP', 20);
  const ttlMs = intEnv(env, 'KAGENTI_SANDBOX_LEASE_TTL_MS', 60000);
  const requested = intEnv(env, 'KAGENTI_SANDBOX_HEARTBEAT_MS', 20000);
  return { cap, ttlMs, heartbeatMs: Math.max(1, Math.min(requested, Math.floor(ttlMs / 3))) };
}
