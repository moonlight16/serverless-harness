import { describe, it, expect, afterAll } from "vitest";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager, type FileEntry } from "@earendil-works/pi-coding-agent";
import { RedisSessionBackend } from "@sh/session-backend";
import { BufferedRedisBackend } from "@sh/harness/buffered-redis-backend";
import { CountingBackend } from "../src/counting-backend";
import { buildCompactedSession } from "../src/session-fixture";
import {
  buildResultsMarkdown,
  deterministicView,
  parseE2Table,
  type E2Row,
} from "../src/report";

const REDIS = process.env.REDIS_URL ?? "redis://127.0.0.1:6379";
const store = new RedisSessionBackend<FileEntry>(REDIS);
const sids: string[] = [];
const Ns = [50, 200, 1000, 5000];

afterAll(async () => {
  for (const sid of sids) await store.reset(sid);
  await store.close();
});

async function measure(sessionId: string): Promise<{
  backend: { entries: number; bytes: number; ms: number };
  checkpoint: { entries: number; bytes: number; ms: number };
}> {
  const cb = new CountingBackend(new BufferedRedisBackend(store));

  cb.reset();
  let t0 = performance.now();
  const viaBackend = await SessionManager.openFromBackend(sessionId, cb, process.cwd());
  const backendMs = performance.now() - t0;
  const b = cb.counts();

  cb.reset();
  t0 = performance.now();
  const viaCheckpoint = await SessionManager.openFromCheckpoint(sessionId, cb, process.cwd());
  const checkpointMs = performance.now() - t0;
  const c = cb.counts();

  // Parity re-confirmation (spec §5).
  expect(viaCheckpoint.buildSessionContext()).toEqual(viaBackend.buildSessionContext());

  return {
    backend: { entries: b.entriesRead, bytes: b.bytesRead, ms: backendMs },
    checkpoint: { entries: c.entriesRead, bytes: c.bytesRead, ms: checkpointMs },
  };
}

describe("E2 — reconstruction cost", () => {
  it("checkpoint read stays ~constant while backend grows; ratio increases with N", async () => {
    const rows: E2Row[] = [];
    for (const n of Ns) {
      const fx = await buildCompactedSession(store, { n, tailKept: 4 });
      sids.push(fx.sessionId);
      const m = await measure(fx.sessionId);
      rows.push({
        n,
        backendEntries: m.backend.entries,
        checkpointEntries: m.checkpoint.entries,
        backendBytes: m.backend.bytes,
        checkpointBytes: m.checkpoint.bytes,
        ratioEntries: m.backend.entries / m.checkpoint.entries,
        backendMs: m.backend.ms,
        checkpointMs: m.checkpoint.ms,
      });
    }

    // Completeness guard: a partial run (e.g. a Redis hiccup mid-loop) would leave
    // `rows` short and let the strict-monotone ratio loop pass vacuously. Fail loudly.
    expect(rows.length).toBe(Ns.length);

    // Checkpoint entries are bounded by the kept tail, independent of N.
    const cpEntries = rows.map((r) => r.checkpointEntries);
    expect(Math.max(...cpEntries)).toBeLessThanOrEqual(10);

    // Backend entries grow with N.
    expect(rows[rows.length - 1].backendEntries).toBeGreaterThan(rows[0].backendEntries * 5);

    // Ratio strictly increases across the N series.
    for (let i = 1; i < rows.length; i++) {
      expect(rows[i].ratioEntries).toBeGreaterThan(rows[i - 1].ratioEntries);
    }
    // And the largest N dwarfs the smallest.
    expect(rows[rows.length - 1].ratioEntries).toBeGreaterThan(rows[0].ratioEntries * 5);

    const report = buildResultsMarkdown(rows);

    // Fresh measurements go to a gitignored path. This used to overwrite the committed
    // RESULTS.md on every run, so any `pnpm -r test` left the working tree dirty with
    // machine-local wall-clock timings. Override the directory with SH_E2_RESULTS_DIR.
    const outDir = process.env.SH_E2_RESULTS_DIR
      ? resolve(process.env.SH_E2_RESULTS_DIR)
      : fileURLToPath(new URL("../.results", import.meta.url));
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "RESULTS.md"), report);

    // The committed RESULTS.md is a checked-in baseline: assert the reproducible columns
    // still match it, so a change that moves the read counts has to be acknowledged rather
    // than quietly rewriting the recorded result. Only entries + ratio are compared --
    // backendBytes is environment-sensitive (+4 in CI) and the ms columns vary per run.
    // Refresh deliberately with SH_E2_UPDATE_BASELINE=1 when a change legitimately moves them.
    const baselinePath = fileURLToPath(new URL("../RESULTS.md", import.meta.url));
    if (process.env.SH_E2_UPDATE_BASELINE === "1") {
      writeFileSync(baselinePath, report);
    } else {
      const baseline = parseE2Table(readFileSync(baselinePath, "utf8"));
      expect(deterministicView(rows)).toEqual(deterministicView(baseline));
    }

    // Echo to stdout (redirected to $LOG_DIR by the runner) for the record.
    console.log(JSON.stringify(rows, null, 2));
  }, 120_000);
});
