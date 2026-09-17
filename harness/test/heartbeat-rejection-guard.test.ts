import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * Every fire-and-forget lease renewal must swallow its own rejection.
 *
 * A renewal ticks from a `setInterval`, so there is no caller to await it. A bare
 * `void lease.heartbeat()` therefore declines to handle a rejection, and Node's default
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
 *     ONE unhandled rejection is still fatal, and the next Redis-backed `void` need not come from
 *     a lease at all.)
 *
 * A failed renewal is safe to swallow, which is why swallowing is the right fix rather than a
 * band-aid: the lease's TTL simply lapses and the sandbox returns to the pool.
 *
 * Structural because the alternative is booting a leaf: these are `setInterval` bodies inside
 * 700-line functions, and the assertion is about a source pattern that regresses by omission.
 */
const src = (rel: string) =>
  readFileSync(fileURLToPath(new URL(`../src/${rel}`, import.meta.url)), 'utf8');

/** Strip comments, so the prose above (and in the sources) cannot satisfy a check. */
function code(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
}

/** Every `void <expr>.heartbeat(...)` statement, with whatever follows it on the line. */
function voidedHeartbeats(body: string): string[] {
  return body.match(/void\s+[\w.]*heartbeat\([^;]*;/g) ?? [];
}

describe('fire-and-forget lease renewals cannot become unhandled rejections', () => {
  it.each(['run-leaf.ts', 'run-turn.ts'])('every voided heartbeat in %s has a .catch', (file) => {
    const found = voidedHeartbeats(code(src(file)));
    expect(found.length).toBeGreaterThan(0);
    for (const stmt of found) expect(stmt).toMatch(/\.catch\(/);
  });

  it('pins the four known sites, so a new one has to be considered rather than merged', () => {
    // run-leaf: runPromptLeaf, realProduceSolve, realProduceVerdict. run-turn: the renewal in
    // executeTurn. If this count changes, the change is either a new interval that needs the same
    // guard or a removed one — both worth a reader's attention.
    expect(voidedHeartbeats(code(src('run-leaf.ts')))).toHaveLength(3);
    expect(voidedHeartbeats(code(src('run-turn.ts')))).toHaveLength(1);
  });

  it('proves the guard can fail: the unguarded form is detectable', () => {
    // An assertion never shown capable of failing asserts nothing.
    const unguarded = code(`
      heartbeat = setInterval(() => {
        void lease.heartbeat();
      }, hbMs);
    `);
    const found = voidedHeartbeats(unguarded);
    expect(found).toHaveLength(1);
    expect(found[0]).not.toMatch(/\.catch\(/);
  });
});
