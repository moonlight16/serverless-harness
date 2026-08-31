export interface E2Row {
  n: number;
  backendEntries: number;
  checkpointEntries: number;
  backendBytes: number;
  checkpointBytes: number;
  ratioEntries: number;
  backendMs: number;
  checkpointMs: number;
}

/**
 * The subset of an E2 row that is reproducible on any machine, and therefore the only part
 * a committed baseline can assert on. Measured across a dev box and CI:
 *
 *   - entries + ratio: identical (synthetic fixtures, deterministic reads)
 *   - backendBytes:    differs by +4 bytes in CI -- serialization is environment-sensitive
 *   - backendMs / checkpointMs: vary run to run even on one machine
 *
 * Ratio is rounded to the 1 decimal the markdown table carries, so a value read back from
 * RESULTS.md compares equal to a freshly measured one.
 */
export interface E2Deterministic {
  n: number;
  backendEntries: number;
  checkpointEntries: number;
  ratioEntries: number;
}

export function deterministicView(rows: E2Row[]): E2Deterministic[] {
  return rows.map((r) => ({
    n: r.n,
    backendEntries: r.backendEntries,
    checkpointEntries: r.checkpointEntries,
    ratioEntries: Number(r.ratioEntries.toFixed(1)),
  }));
}

/**
 * Read the E2 table back out of a RESULTS.md. Used to compare a fresh run against the
 * committed baseline; tolerates surrounding prose and unrelated tables by keying off the
 * 8-column shape that buildResultsMarkdown emits.
 */
export function parseE2Table(markdown: string): E2Row[] {
  const rows: E2Row[] = [];
  for (const line of markdown.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("|")) continue;
    const cells = trimmed.slice(1, trimmed.endsWith("|") ? -1 : undefined).split("|");
    if (cells.length !== 8) continue; // header, separator, and other tables
    const nums = cells.map((c) => Number(c.trim()));
    if (nums.some((v) => !Number.isFinite(v))) continue; // header/separator row
    const [
      n,
      backendEntries,
      checkpointEntries,
      ratioEntries,
      backendBytes,
      checkpointBytes,
      backendMs,
      checkpointMs,
    ] = nums;
    rows.push({
      n,
      backendEntries,
      checkpointEntries,
      ratioEntries,
      backendBytes,
      checkpointBytes,
      backendMs,
      checkpointMs,
    });
  }
  if (rows.length === 0) {
    throw new Error("no E2 table found: expected the 8-column table buildResultsMarkdown emits");
  }
  return rows;
}

export function buildResultsMarkdown(rows: E2Row[]): string {
  const header =
    "| N (session len) | backend entries | checkpoint entries | ratio (b/c) | backend bytes | checkpoint bytes | backend ms* | checkpoint ms* |\n" +
    "|---|---|---|---|---|---|---|---|";
  const body = rows
    .map(
      (r) =>
        `| ${r.n} | ${r.backendEntries} | ${r.checkpointEntries} | ${r.ratioEntries.toFixed(1)} | ${r.backendBytes} | ${r.checkpointBytes} | ${r.backendMs.toFixed(1)} | ${r.checkpointMs.toFixed(1)} |`,
    )
    .join("\n");
  return `# M6 Experiment Results

## E2 — local reconstruction cost (openFromCheckpoint vs openFromBackend)

Synthetic sessions, each compacted once with a fixed kept tail. Metric = entries + bytes
returned by \`backend.read()\` during reconstruction (the slice each loader rebuilds from).
\`*\` ms columns are wall-clock on a dev box — **illustrative only**; the gate is the
deterministic entries ratio. \`backend bytes\` is environment-sensitive too (it differs
between CI and a dev box), so the committed copy of this file is compared on the entries
and ratio columns only.

This file is a **committed baseline**: \`e2-reconstruction-cost.test.ts\` asserts that a fresh
run still matches those columns, and writes each run's own table to the gitignored
\`experiments/.results/\`. Refresh it deliberately when a change legitimately moves the read
counts: \`SH_E2_UPDATE_BASELINE=1 pnpm -C experiments test e2-reconstruction-cost\`.

${header}
${body}

**Pass:** checkpoint entries stay ~constant (bounded by the kept tail) while backend entries
grow linearly with N, so the backend/checkpoint ratio strictly increases with N. \`buildSessionContext()\`
is identical under both loaders at every N.

## E5 — budget-voter enforcement

Verified by \`e5-budget-structural.test.ts\` (no key, real Redis): once per-turn spend exceeds
\`SH_BUDGET_TOKENS\`, the \`tool_call\` is blocked and exactly one \`abort\` entry is persisted;
with the cap unset the voter is inert (no block, no \`abort\`). A key-gated live run
(\`e5-budget-live.test.ts\`, tiny cap) confirms the same end-to-end with a real model. See
\`README.md\` for how to run the live variant.

*Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>*
`;
}
