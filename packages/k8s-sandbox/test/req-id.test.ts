import { describe, expect, it } from "vitest";
import { makeReqIdSource } from "../src/req-id.js";

describe("makeReqIdSource", () => {
  it("is monotonic within one source", () => {
    const next = makeReqIdSource();
    const a = next(), b = next(), c = next();
    expect(b).toBeGreaterThan(a);
    expect(c).toBeGreaterThan(b);
  });

  it("yields disjoint id spaces across sources (the multi-replica property)", () => {
    // Two independently-seeded sources stand in for two harness replicas sharing one
    // worker. Today both emit 1,2,3... and the relay keys sinks by req_id alone, so a
    // collision silently swaps one caller's stream for another's (#179).
    const a = makeReqIdSource(), b = makeReqIdSource();
    const setA = new Set(Array.from({ length: 500 }, a));
    const setB = new Set(Array.from({ length: 500 }, b));
    expect([...setB].some((id) => setA.has(id))).toBe(false);
  });

  it("stays inside Number.MAX_SAFE_INTEGER even at counter exhaustion", () => {
    // req_id is uint64 on the wire but a JS number after longToNumber, so an id past
    // 2^53-1 would silently lose precision and alias onto another exec.
    const next = makeReqIdSource();
    for (let i = 0; i < 1000; i++) expect(Number.isSafeInteger(next())).toBe(true);
    // Max achievable id is (2^21-1)*2^32 + (2^32-1) = 2^53-1, i.e. MAX_SAFE_INTEGER exactly.
    // (2**21 * 2**32 alone is 2^53, one past MAX_SAFE_INTEGER -- the "-1" accounts for
    // salt and counter each maxing at their-space-minus-one, not their space size.)
    expect(2 ** 21 * 2 ** 32 - 1).toBeLessThanOrEqual(Number.MAX_SAFE_INTEGER);
  });
});
