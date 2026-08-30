import { randomInt } from "node:crypto";

const SALT_BITS = 21; // 2^21 ≈ 2.1M distinct replica spaces
const COUNTER_SPACE = 2 ** 32;

/**
 * Builds a req_id source whose ids are unique across processes, not merely within one.
 *
 * `req_id` is both the correlation key and the dedup key (spec §8), and the relay keys
 * its per-exec sinks by it *within a sandbox session* (relay.ts routeExec). A bare
 * per-process counter therefore collides whenever two harness replicas share a sandbox —
 * which select-sandbox does on purpose, at a lease cap of 20, behind max-scale 5. The
 * observable effect is not an error: one caller's sink is replaced and it hangs to its
 * deadline while the other receives both execs' output interleaved (#179).
 *
 * Layout: [21-bit random salt][32-bit counter]. The maximum producible id is
 * (2^21 - 1) * 2^32 + (2^32 - 1) = 9007199254740991, exactly Number.MAX_SAFE_INTEGER —
 * required because the generated client maps uint64 through longToNumber. That is zero
 * headroom, not a margin: widening the salt to 22 bits or the counter to 33 doesn't spend
 * slack, it immediately overflows into precision loss and silent id aliasing (two execs
 * collapsing onto one number). Uniqueness is probabilistic in the salt (birthday collision
 * across 5 replicas ≈ 4.8e-6 = C(5,2)/2^21), exact in the counter.
 */
export function makeReqIdSource(): () => number {
  const salt = randomInt(0, 2 ** SALT_BITS);
  let counter = 0;
  return () => {
    counter = (counter + 1) % COUNTER_SPACE;
    return salt * COUNTER_SPACE + counter;
  };
}
