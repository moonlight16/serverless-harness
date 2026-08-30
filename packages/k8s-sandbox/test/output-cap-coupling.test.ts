import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { DEFAULT_OUTPUT_CAP } from "../src/transport.js";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const RUNNER_GO = resolve(REPO_ROOT, "remote-worker/internal/exec/runner.go");

/**
 * Loud-throw reader (same shape as knative-server's worker-deployment test): a
 * reformatted or renamed Go constant must fail the extraction, never limp through
 * as NaN and silently pass the comparison.
 */
const readBufferCapBytes = (): number => {
  const runnerGo = readFileSync(RUNNER_GO, "utf8");
  const match = /BufferCap = (\d+) \* 1024 \* 1024/.exec(runnerGo);
  if (!match) {
    throw new Error(
      "could not find `BufferCap = N * 1024 * 1024` in runner.go — constant renamed or reformatted?",
    );
  }
  return Number(match[1]) * 1024 * 1024;
};

describe("output cap is pinned across the language boundary", () => {
  it("DEFAULT_OUTPUT_CAP equals the Go worker's BufferCap", () => {
    // transport.ts says the Go worker's BufferCap "is pinned to this value — change
    // one and change the other". Nothing enforced that, so the two could drift: a
    // larger BufferCap lets the worker buffer bytes the harness will throw away
    // (wasted worker memory against its OOM limit), a smaller one truncates before
    // the harness cap ever trips, so the marker Pi relies on never appears and the
    // remote path silently returns short reads the kubectl path returns in full.
    expect(DEFAULT_OUTPUT_CAP).toBe(readBufferCapBytes());
  });
});
