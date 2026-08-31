import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { buildResultsMarkdown, parseE2Table, deterministicView, type E2Row } from "../src/report";

const ROWS: E2Row[] = [
  {
    n: 50,
    backendEntries: 53,
    checkpointEntries: 6,
    backendBytes: 7482,
    checkpointBytes: 896,
    ratioEntries: 53 / 6,
    backendMs: 0.9,
    checkpointMs: 1.0,
  },
  {
    n: 5000,
    backendEntries: 5003,
    checkpointEntries: 6,
    backendBytes: 706909,
    checkpointBytes: 906,
    ratioEntries: 5003 / 6,
    backendMs: 22.7,
    checkpointMs: 20.9,
  },
];

describe("parseE2Table", () => {
  it("round-trips the table that buildResultsMarkdown emits", () => {
    const parsed = parseE2Table(buildResultsMarkdown(ROWS));
    expect(parsed).toHaveLength(ROWS.length);
    expect(parsed.map((r) => r.n)).toEqual([50, 5000]);
    expect(parsed.map((r) => r.backendEntries)).toEqual([53, 5003]);
    expect(parsed.map((r) => r.checkpointEntries)).toEqual([6, 6]);
    expect(parsed.map((r) => r.backendBytes)).toEqual([7482, 706909]);
    expect(parsed.map((r) => r.checkpointBytes)).toEqual([896, 906]);
    // The markdown carries ratio/ms at 1 decimal, so those come back rounded.
    expect(parsed.map((r) => r.ratioEntries)).toEqual([8.8, 833.8]);
  });

  it("ignores prose and other tables around the E2 table", () => {
    const md = `# Notes

| unrelated | table |
|---|---|
| a | b |

${buildResultsMarkdown(ROWS)}`;
    expect(parseE2Table(md).map((r) => r.n)).toEqual([50, 5000]);
  });

  it("throws on a table with no data rows rather than returning nothing", () => {
    expect(() => parseE2Table("# Empty\n\nno table here\n")).toThrow(/no E2 table/i);
  });
});

describe("deterministicView", () => {
  it("keeps only the environment-independent columns", () => {
    // backendBytes differs between CI and a dev box (+4 bytes, measured), and the ms
    // columns vary run to run -- so neither can be part of a baseline comparison.
    expect(deterministicView(ROWS)).toEqual([
      { n: 50, backendEntries: 53, checkpointEntries: 6, ratioEntries: 8.8 },
      { n: 5000, backendEntries: 5003, checkpointEntries: 6, ratioEntries: 833.8 },
    ]);
  });

  it("is stable across a build/parse round-trip, so a fresh run is comparable", () => {
    const reparsed = parseE2Table(buildResultsMarkdown(ROWS));
    expect(deterministicView(reparsed)).toEqual(deterministicView(ROWS));
  });

  it("is insensitive to byte and timing drift", () => {
    const drifted = ROWS.map((r) => ({
      ...r,
      backendBytes: r.backendBytes + 4, // the CI/local delta
      backendMs: r.backendMs * 3,
      checkpointMs: r.checkpointMs * 3,
    }));
    expect(deterministicView(drifted)).toEqual(deterministicView(ROWS));
  });

  it("does notice a real change in the entries counts", () => {
    const regressed = ROWS.map((r) => ({ ...r, checkpointEntries: r.checkpointEntries + 1 }));
    expect(deterministicView(regressed)).not.toEqual(deterministicView(ROWS));
  });
});

describe("the committed RESULTS.md baseline", () => {
  it("parses, and its deterministic view survives a round-trip", () => {
    const md = readFileSync(fileURLToPath(new URL("../RESULTS.md", import.meta.url)), "utf8");
    const baseline = parseE2Table(md);
    expect(baseline.length).toBeGreaterThan(0);
    // Guards against a hand-edit that breaks the table shape the E2 gate reads.
    expect(deterministicView(parseE2Table(buildResultsMarkdown(baseline)))).toEqual(
      deterministicView(baseline),
    );
  });
});
