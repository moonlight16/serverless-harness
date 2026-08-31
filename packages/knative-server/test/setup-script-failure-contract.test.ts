// Failure-reporting contract for the deploy/knative setup scripts (issue #178).
//
// #178 reported that setup-ocp.sh exits 0 after logging "✗ Sandbox pod not Ready". That did
// not reproduce -- the gate has ended in `exit 1` since it was written (cb191209), and a
// direct run does exit 1; the reported 0 came from reading $? past the script (its pasted pod
// table lacks the `-o wide` columns the script actually prints, so it came from a separate
// manual `get pod`). These tests exist so the contract the issue *assumed* is actually
// pinned, instead of holding by luck:
//
//   1. diagnostics go to stderr, so a failure survives `>/dev/null` and is distinguishable
//      when the caller pipes stdout (the thing that made the ✗ "easy to miss");
//   2. every failure branch terminates the script (or is explicitly counted and terminated
//      later), so a future edit cannot silently drop an `exit`;
//   3. readiness gates use if/else rather than `A && B || C` -- that shape (shellcheck
//      SC2015) runs the *failure* branch whenever B fails, so it only reported success
//      correctly because log_success happens to return 0.
//
// Pure file parsing plus one `bash -c` for the behavioural checks, following the pattern of
// authbridge-manifests.test.ts and ghcr-image-namespace.test.ts.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const DEPLOY = resolve(REPO_ROOT, 'deploy/knative');

function read(rel: string): string {
  return readFileSync(resolve(DEPLOY, rel), 'utf8');
}

/** Scripts that define the log_* helper family. setup-kind.sh uses bare `echo` instead. */
const HELPER_SCRIPTS = ['setup-ocp.sh', 'setup-k8s.sh'];

/** Every setup script, for the terminate-on-failure invariant. */
const ALL_SCRIPTS = ['setup-ocp.sh', 'setup-k8s.sh', 'setup-kind.sh'];

/**
 * Split a script into "logical statements": physical lines, but with `\`-continuations and
 * an unclosed `{ ... }` failure branch folded into the line that opened them. This is what
 * makes "does this log_error terminate?" answerable -- the `exit` frequently sits on a
 * later physical line of the same brace group.
 */
function logicalStatements(src: string): { line: number; text: string }[] {
  const lines = src.split('\n');
  const out: { line: number; text: string }[] = [];
  for (let i = 0; i < lines.length; i++) {
    let text = lines[i];
    const start = i;
    // Fold backslash continuations.
    while (text.endsWith('\\') && i + 1 < lines.length) {
      text = text.slice(0, -1) + ' ' + lines[++i];
    }
    // Fold an unbalanced brace group (a `|| { ... }` failure branch spanning lines).
    let depth = (text.match(/\{/g) ?? []).length - (text.match(/\}/g) ?? []).length;
    while (depth > 0 && i + 1 < lines.length) {
      const next = lines[++i];
      text += ' ' + next;
      depth += (next.match(/\{/g) ?? []).length - (next.match(/\}/g) ?? []).length;
    }
    out.push({ line: start + 1, text });
  }
  return out;
}

describe('setup script failure-reporting contract', () => {
  describe.each(HELPER_SCRIPTS)('%s', (script) => {
    const src = read(script);

    // log_info/log_success are progress, and may stay on stdout; log_warn/log_error are
    // diagnostics and must not be swallowed by a caller redirecting stdout.
    it.each(['log_warn', 'log_error'])('routes %s to stderr', (helper) => {
      const def = src.split('\n').find((l) => l.startsWith(`${helper}()`));
      expect(def, `${helper}() definition not found in ${script}`).toBeDefined();
      expect(def).toContain('>&2');
    });
  });

  describe.each(ALL_SCRIPTS)('%s', (script) => {
    const src = read(script);

    it('terminates (or explicitly counts) every failure it logs', () => {
      const stmts = logicalStatements(src);
      // A failure branch must exit, return non-zero, die, or bump a counted-failure tally
      // that a later gate turns into an exit. The terminator is usually inside the same
      // statement (`|| { log_error ...; exit 1; }`) but is sometimes the next statement or
      // two -- e.g. `log_error "..."` followed by `$DRY_RUN || exit 1`, which tolerates the
      // failure under --dry-run only. Hence the small lookahead.
      const TERMINATOR = /\b(exit|die)\b|return 1|vfail=|FAILS=/;
      const LOOKAHEAD = 2;
      const offenders = stmts
        .map((s, i) => ({ s, i }))
        // Call sites only -- skip the helper's own definition.
        .filter(({ s }) => /log_error\s/.test(s.text) && !/^log_error\(\)/.test(s.text.trim()))
        .filter(({ i }) => !stmts.slice(i, i + 1 + LOOKAHEAD).some((n) => TERMINATOR.test(n.text)))
        .map(({ s }) => `${script}:${s.line}`);
      expect(offenders).toEqual([]);
    });
  });

  // Only setup-ocp.sh is refactored here; it is the script #178 was filed against and the
  // one that carried every SC2015 gate. setup-k8s.sh/setup-kind.sh already used if/else or
  // multi-line `|| { ... exit 1; }` blocks.
  it('setup-ocp.sh uses if/else for gates, not `A && log_success || { ... }`', () => {
    const offenders = logicalStatements(read('setup-ocp.sh'))
      .filter((s) => /&&\s*log_success/.test(s.text) && /\|\|/.test(s.text))
      .map((s) => `setup-ocp.sh:${s.line}`);
    expect(offenders).toEqual([]);
  });

  describe('setup-ocp.sh helpers, exercised directly', () => {
    const OCP = resolve(DEPLOY, 'setup-ocp.sh');

    /**
     * Source setup-ocp.sh's helper prelude, run `snippet`, return its streams + status.
     * spawnSync (not execFileSync) because we assert on stderr for *successful* runs too,
     * and execFileSync only returns stdout.
     */
    function runSourced(snippet: string) {
      const script = `set -euo pipefail; SH_SOURCE_ONLY=1 . '${OCP}'; ${snippet}`;
      const r = spawnSync('bash', ['-c', script], { encoding: 'utf8' });
      return { status: r.status, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
    }

    it('can be sourced for its helpers without running the bring-up', () => {
      const r = runSourced('echo SOURCED');
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('SOURCED');
      // The bring-up banner must not have run.
      expect(r.stdout).not.toContain('Connected to cluster');
    });

    it('log_error writes to stderr, not stdout', () => {
      const r = runSourced('log_error "boom" >/dev/null');
      expect(r.stderr).toContain('boom');
    });

    it('die logs to stderr and exits non-zero', () => {
      const r = runSourced('die "fatal thing"');
      expect(r.status).not.toBe(0);
      expect(r.stderr).toContain('fatal thing');
      expect(r.stdout).not.toContain('fatal thing');
    });
  });
});
