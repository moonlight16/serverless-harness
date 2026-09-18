import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * Every fire-and-forget lease renewal must swallow its own rejection.
 *
 * A renewal ticks from a `setInterval`, so there is no caller to await it. A statement-position
 * `lease.heartbeat()` therefore declines to handle a rejection, and Node's default
 * `--unhandled-rejections=throw` ends the process — the leaf or the supervisor worker, mid-turn.
 * `packages/supervisor/src/main.ts` documents the same failure class in prose.
 *
 * This became reachable in this PR on two counts, and both are about rejections that did not use to
 * happen:
 *
 *  1. `resilientClientOptions`' bounded reconnect. Before it, node-redis's default strategy retried
 *     forever, so a command issued during an outage stayed QUEUED and eventually resolved. Past the
 *     bound node-redis gives up permanently, `isOpen` goes false, and every later command REJECTS
 *     `ClientClosedError`.
 *  2. `guard()`/`dropMemo` in select-sandbox.ts. A drop closes the failed store, so a renewal that
 *     rejected once used to keep rejecting on every subsequent tick — a fresh unhandled rejection
 *     each time, not a single unlucky one. (That half is now fixed at the source: `sharedLease`
 *     re-resolves the memo per command, see lease-closure-rearm.test.ts. This guard stays because
 *     ONE unhandled rejection is still fatal, and the next Redis-backed call need not be a lease.)
 *
 * A failed renewal is safe to swallow, which is why swallowing is the right fix rather than a
 * band-aid: the lease's TTL simply lapses and the sandbox returns to the pool.
 *
 * Structural because the alternative is booting a leaf: these are `setInterval` bodies inside
 * 700-line functions, and the assertion is about a source pattern that regresses by omission.
 *
 * Two things the first version of this file got wrong, both worth stating because they are what make
 * an absence-assertion worth having rather than merely present:
 *
 *  - **It required the `void` marker.** There is no ESLint anywhere in this repo — `make lint` is
 *    prettier + hadolint + shellcheck + gitleaks, and the root `devDependencies` is `prettier` alone —
 *    so nothing forces `void` at these sites; convention does. That made the most natural way to write
 *    the regression (`lease.heartbeat();`, no `void`, no `.catch`) invisible to both the `.catch` loop
 *    and the count, and `tsc` does not flag it either. Anchoring at line start instead costs nothing:
 *    `await …` and `return …` cannot match, and those are exactly the two forms that DO have a caller.
 *  - **It listed two files.** A renewal interval in a new module was uncovered, which the note above
 *    anticipates. It now reads every `.ts` under `../src`.
 */
const SRC = new URL('../src/', import.meta.url);

/** Every `.ts` under harness/src, comment-stripped, so the pin tracks the hazard and not two files. */
function sources(): { file: string; code: string }[] {
  return readdirSync(fileURLToPath(SRC))
    .filter((f) => f.endsWith('.ts'))
    .sort()
    .map((file) => ({
      file,
      // Strip block and line comments, so prose (here or in the sources) cannot satisfy a check.
      code: readFileSync(fileURLToPath(new URL(file, SRC)), 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/^\s*\/\/.*$/gm, ''),
    }));
}

/** A type signature rather than a call: `heartbeat(pod: string, …): Promise<void>;`. */
const isDeclaration = (stmt: string) => /\)\s*:\s*\S[^;]*;$/.test(stmt);

/** Every statement-position `heartbeat(...)` call, `void`ed or bare — both are fire-and-forget. */
function firedAndForgotten(body: string): string[] {
  // Anchored at line start, so `await`/`return` forms do not match: those have a caller. A bare
  // `lease.heartbeat();` does not, and there is no ESLint `no-floating-promises` here to force the
  // `void` marker. A class method (`async heartbeat(…) {`) and a property (`heartbeat: () => …`) do
  // not match either — the first has `async ` before the name, the second a `:` after it.
  //
  // The INTERFACE signature in sandbox-lease.ts does match the anchor, though: no `async`, at line
  // start, terminated by `;`. Found by widening the scan from two files to the directory, which is
  // a fair argument for having widened it. Excluded by shape (a `): Type;` tail, which no call has)
  // rather than by filename, so the next declaration is excluded too.
  return (body.match(/^[ \t]*(?:void\s+)?[\w.]*heartbeat\([^;]*;/gm) ?? []).filter(
    (stmt) => !isDeclaration(stmt),
  );
}

describe('fire-and-forget lease renewals cannot become unhandled rejections', () => {
  it('every statement-position heartbeat call in harness/src has a .catch', () => {
    const offenders = sources().flatMap(({ file, code }) =>
      firedAndForgotten(code)
        .filter((stmt) => !/\.catch\(/.test(stmt))
        .map((stmt) => `${file}: ${stmt.trim()}`),
    );
    expect(offenders).toEqual([]);
  });

  it('pins the four known sites, so a new one has to be considered rather than merged', () => {
    // run-leaf: runPromptLeaf, realProduceSolve, realProduceVerdict. run-turn: the renewal in
    // executeTurn. Asserted as a map so a failure names the file that changed, and totalled so a
    // renewal added in a NEW module fails here too rather than passing unseen.
    const counts = Object.fromEntries(
      sources()
        .map(({ file, code }) => [file, firedAndForgotten(code).length] as const)
        .filter(([, n]) => n > 0),
    );
    expect(counts).toEqual({ 'run-leaf.ts': 3, 'run-turn.ts': 1 });
  });

  it('proves the guard can fail: BOTH unguarded forms are detectable', () => {
    // An assertion never shown capable of failing asserts nothing. The bare form is the one the
    // original `void`-requiring pattern missed entirely.
    const voided = firedAndForgotten('      void lease.heartbeat();\n');
    const bare = firedAndForgotten('      lease.heartbeat();\n');
    expect(voided).toHaveLength(1);
    expect(bare).toHaveLength(1);
    expect(voided[0]).not.toMatch(/\.catch\(/);
    expect(bare[0]).not.toMatch(/\.catch\(/);
  });

  it('does not flag the forms that legitimately have a caller', () => {
    const awaited = '    await lease.heartbeat();\n';
    const returned = '    return store.heartbeat(pod, holderId, ttlMs);\n';
    const declared = '  async heartbeat(pod: string, holderId: string, ttlMs: number) {\n';
    const property = '    heartbeat: () => lease.heartbeat(name, holderId, opts.ttlMs),\n';
    // The LeaseStore interface's own signature — the false positive the directory scan turned up.
    const signature = '  heartbeat(pod: string, holderId: string, ttlMs: number): Promise<void>;\n';
    for (const form of [awaited, returned, declared, property, signature]) {
      expect(firedAndForgotten(form)).toEqual([]);
    }
  });
});
