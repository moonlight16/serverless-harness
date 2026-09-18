# E12 — guest-initiated vsock across snapshot restore: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer one boolean — does a guest-initiated vsock connection on a second port (1025) survive Firecracker snapshot restore, and survive N concurrent restores of one snapshot — with a driver, a KVM-free contract test, a sealed prediction, per-rung JSON records, and a recorded answer.

**Architecture:** A self-contained bash driver (`e12-vsock-egress-probe.sh`) that drives Firecracker directly over its API socket inside a `chroot` jail (not the jailer), in E10's instrumentation style: required `SH_SUBSTRATE`, fail-closed preflight, one JSON record per rung, `die` on an empty record. Four rungs: **A** fresh boot (control), **B** restore once, **C** N concurrent restores (8, then 128), **D** host-initiated 1024 regression fence. Every rung asserts **two independent witnesses** — the nonce arrived host-side on `<jail>/vsock.sock_1025` _and_ the ACK came back in guest stdout. Host-side is authoritative; guest stdout is corroboration, never a timing source.

**Tech Stack:** bash (`set -uo pipefail`, no `-e`), Firecracker v1.17.0 API over `curl --unix-socket`, python3 with `AF_VSOCK` on both host and guest (already present in the golden rootfs), Go (for `guest_client`, built on the rig; `GOTOOLCHAIN=auto` fetches go1.26.0 as `remote-worker/go.mod` requires), vitest 2.1.9 for the prediction pin.

**Spec:** `https://github.com/rossoctl/serverless-harness/issues/271`. Supporting context: PR #268's P4.1 design §9 (which this gates), `deploy/microvm/EXPERIMENTS.md`, and Firecracker's [`vsock.md`](https://github.com/firecracker-microvm/firecracker/blob/main/docs/vsock.md).

## Verified facts this plan is built on

Established by reading the rig and the repo before planning. Do not re-derive; **do** re-check the three marked _re-verify_ at Task 9 time.

| #   | Fact                                                                                                                                                                                                                                   | Consequence                                                                                                                                                                                            |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | The golden guest rootfs has **python3.12 with working `AF_VSOCK`** (`socket.VMADDR_CID_HOST == 2`, socket creation succeeds under `chroot`). `manifest.json` declares `"capabilities": ["curl","python3"]`.                            | **The snapshot rebuild the issue budgeted for is cancelled.** No rootfs change, so no digest change.                                                                                                   |
| 2   | The nested snapshot's `rootfs_sha256` is `sha256:833401a161b75cd43ea3dc231efa01d039dd23d3e8e73eddf63fd88bbcec54d4`, built `2026-09-15T23:35:34Z` — **not** metal's `sha256:668af589…`.                                                 | The contamination hazard the issue's substrate section guards against is _structurally absent_: this is already a separate snapshot.                                                                   |
| 3   | The guest rootfs also has **working socat 1.8.0.0** (`>= 1.7.4`, so `VSOCK-CONNECT` is supported).                                                                                                                                     | Corrects an earlier note claiming socat was broken with `libwrap.so.0`. python3 remains the primary mechanism (finer control of the two-witness protocol); socat is the documented fallback in Task 4. |
| 4   | `deploy/microvm/predictions.json` is SHA-256 tamper-sealed by `experiments/test/microvm-predictions.test.ts`, which also hard-asserts `toHaveLength(5)`.                                                                               | Adding prediction 6 **requires** editing that test in the same commit (Task 1). The test's own docstring authorizes exactly this for a pre-measurement append.                                         |
| 5   | `deploy/microvm/tests/build-snapshot.test.sh:245-259` greps `write_guest_client`'s body and asserts **statement ordering** inside it.                                                                                                  | **Do not refactor `build-snapshot.sh`.** E12 carries its own copies of the jail/API helpers, each with a comment naming its origin.                                                                    |
| 6   | E11 ran a density ladder to **128 concurrent** microVMs on this same `nested-m8i` rig with Sigma PSS <= 0.41 GB.                                                                                                                       | Rung C at N=128 is feasible on 15 GiB. Firecracker's memfile is lazily mapped; 128 x 256 MiB does not commit 32 GiB.                                                                                   |
| 7   | `build-snapshot.sh` launches Firecracker with plain `chroot "$jail" /firecracker`, **as root, not via the jailer**.                                                                                                                    | Firecracker's `uds_path: /vsock.sock` maps to host `$jail/vsock.sock`, so the guest-initiated listener is `$jail/vsock.sock_1025`, root-owned. No uid/permission juggling.                             |
| 8   | Per `vsock.md`, the guest-initiated direction has **no handshake**: Firecracker connects to `<uds>_<PORT>` and the stream is raw immediately. The socket need only exist at _connect_ time, not at config time.                        | The host listener is a plain `AF_UNIX` accept loop, and it can be started any time before the guest connects.                                                                                          |
| 9   | The rig (`3.235.29.220`) has Firecracker v1.17.0, `/dev/kvm`, 4 vCPU / 15 GiB, kernel `6.18.44-99.149.amzn2023.x86_64`, Go 1.25.1 with `GOTOOLCHAIN=auto` and working access to `proxy.golang.org`. **No repo checkout exists on it.** | Task 9 must rsync the repo before building `guest_client`. _(re-verify)_                                                                                                                               |
| 10  | `Makefile:25`'s `test-deploy` target globs `deploy/microvm/tests/*.test.sh`.                                                                                                                                                           | The new test auto-registers. **No Makefile or CI edit is needed.**                                                                                                                                     |
| 11  | The agent runs commands as `exec.Command(shell, "-c", req.Command)` (`remote-worker/internal/guestagent/agent.go:424`).                                                                                                                | `guest_client -command` takes a full shell command line, so a base64-decode pipeline is legal.                                                                                                         |
| 12  | The rig's `/srv/snapshots/default` is present, root-owned, mode `0444`, containing `agent kernel manifest.json memfile rootfs vmstate`.                                                                                                | Every rung hardlinks from it and never writes to it. _(re-verify)_                                                                                                                                     |
| 13  | `remote-worker/go.mod` declares `go 1.26.0` while the rig's `go` is 1.25.1. `GOTOOLCHAIN=auto` plus reachable `proxy.golang.org` means `go build` self-upgrades.                                                                       | Not a blocker, but Task 9 asserts the build succeeded rather than assuming it. _(re-verify)_                                                                                                           |

## Global Constraints

- `SH_SUBSTRATE` is **required** and must be rig-labelled. Reject bare `nested` explicitly — `EXPERIMENTS.md`/E9 requires the rig label, not the class. The run substrate is `nested-m8i`.
- **Never write to the golden snapshot.** Hardlink files in, mount rootfs `is_read_only: true`, boot with `ro` in `boot_args`, and verify `rootfs_sha256` against `manifest.json` **before and after every run**, dying on drift. This is the mechanical guard that replaces the issue's "never pass `SH_SUBSTRATE=metal`" name check — see Task 2 Step 7.
- **No verdict machinery.** E12 has no threshold, no baseline, no ladder analysis. It prints a boolean. It must be _structurally_ incapable of printing `STOP` or `MANDATORY` — asserted in the test, not promised in a comment.
- `set -uo pipefail`, **not** `-e` — matching both existing drivers.
- `die()`/`log()` defined **above the first caller** (`e10-lifecycle.sh:128`'s comment explains the failure mode: `die: command not found`, and the script carries on).
- Every rung writes a JSON record; an empty or unparseable record is a `die` naming the rung and its log (#266's `mem_available_bytes` class of bug).
- All pass/fail assertions are **host-side**. Guest stdout is a second witness of a host-observed fact, never a timing source (spec §2.4: guest clocks jump on resume).
- Guest RAM 256 MiB, `vcpu_count: 1`, `guest_cid: 3`, jail-relative `uds_path: /vsock.sock`, probe port **1025**, agent port **1024**.
- Shell must pass `shellcheck` and the repo's pinned Prettier via `pre-commit`. Commits need `git commit -s`.
- Attribution: `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>` per `CLAUDE.md` — **not** `Co-Authored-By`.
- Long command output goes to `$LOG_DIR` (`/tmp/kagenti/tdd/serverless-harness`), never into conversation context.
- Use `./node_modules/.bin/vitest`, **never** `npx vitest` — npx resolves vitest 4 instead of the pinned 2.1.9 and invents failures.

## File Structure

| File                                                  | Responsibility                                                                                                                                               |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `deploy/microvm/predictions.json`                     | **Modify.** Append prediction id 6 (E12). Sealed before rung A runs.                                                                                         |
| `experiments/test/microvm-predictions.test.ts`        | **Modify.** Bump `PINNED_SHA256`; `toHaveLength(5)` -> `6`; keep every per-prediction falsifier assertion.                                                   |
| `deploy/microvm/e12-vsock-egress-probe.sh`            | **Create.** The driver: env contract, preflight, snapshot integrity guard, jail lifecycle, two-witness probe, four rungs, per-rung records, boolean answer.  |
| `deploy/microvm/tests/e12-vsock-egress-probe.test.sh` | **Create.** KVM-free contract tests in `e10-lifecycle.test.sh`'s style (`extract_fn`, `check`, `E12_PROBE_SOURCE_ONLY=1`). Auto-registered by `Makefile:25`. |
| `deploy/microvm/EXPERIMENTS.md`                       | **Modify.** Add the E12 section: the answer, and what a nested run can and cannot establish.                                                                 |

---

### Task 1: Seal the prediction (must land before any rung runs)

This task exists first and alone because a prediction sealed _after_ a result is not a prediction. Nothing in this task touches the driver.

**Files:**

- Modify: `deploy/microvm/predictions.json`
- Modify: `experiments/test/microvm-predictions.test.ts:19` (`PINNED_SHA256`), `:41` (`toHaveLength`)

**Interfaces:**

- Consumes: nothing.
- Produces: prediction id `6`, read by `pinnedPredictionIds()` in `experiments/src/microvm-density.ts`. `scorePrediction`'s `default` branch already returns `'inconclusive'` for unrecognised ids, so E11's analysis will not crash — an E11 report will simply list `6: inconclusive`. That is a known cosmetic artifact, accepted, and recorded in Task 10's EXPERIMENTS.md text.

- [ ] **Step 1: Run the pin test first, to see it green before you touch anything**

```bash
export LOG_DIR=/tmp/kagenti/tdd/serverless-harness
mkdir -p "$LOG_DIR"
./node_modules/.bin/vitest run experiments/test/microvm-predictions.test.ts > "$LOG_DIR/pin-before.log" 2>&1; echo "EXIT:$?"
```

Expected: `EXIT:0`, 3 passed. If it is already red, stop — something else is wrong and this task's premise (that you are the one moving the pin) is false.

- [ ] **Step 2: Add the prediction entry**

In `deploy/microvm/predictions.json`, append this object to the `predictions` array, after the object with `"id": 5`. Add a comma after id 5's closing brace.

```json
{
  "id": 6,
  "experiment": "E12",
  "claim": "Guest-initiated vsock on a second port (1025) works on a fresh boot and survives snapshot restore, for all N concurrent restores of one snapshot, because the guest-to-host direction needs no handshake and no host-side state beyond the socket file - strictly less state to reset than the host-initiated direction already known to survive.",
  "metric": "per-rung boolean: the VM's unique nonce captured host-side on <jail>/vsock.sock_1025 AND 'ACK <nonce>' returned in that VM's guest stdout, for rungs A, B, C(N=8), C(N=128), D",
  "falsifiedBy": "any rung B, C or D reporting ok=false while rung A reported ok=true",
  "note": "Rung A failing falsifies nothing about Firecracker - it indicts our own plumbing or socket naming, and the probe is retried. Recorded before rung A ran, per issue #271."
}
```

- [ ] **Step 3: Run the pin test to watch it fail for exactly two reasons**

```bash
./node_modules/.bin/vitest run experiments/test/microvm-predictions.test.ts > "$LOG_DIR/pin-red.log" 2>&1; echo "EXIT:$?"
grep -E "has not been edited|records all five|AssertionError" "$LOG_DIR/pin-red.log" | head
```

Expected: non-zero exit, and **two** failures — `has not been edited` (digest mismatch) and `records all five of §7.4s predictions` (length 6, want 5). If you see a third failure, your JSON is malformed; fix it before moving on.

- [ ] **Step 4: Compute the new digest**

```bash
shasum -a 256 deploy/microvm/predictions.json
```

Record the hex digest. On the rig or any Linux box this is `sha256sum` instead.

- [ ] **Step 5: Update the pin, the count, and the test's own name**

In `experiments/test/microvm-predictions.test.ts`:

1. Set `PINNED_SHA256` to the digest from Step 4.
2. Change `expect(doc.predictions).toHaveLength(5)` to `toHaveLength(6)`.
3. Rename that `it(...)` from `'records all five of §7.4s predictions, each with a falsifier'` to `'records §7.4s five predictions plus E12s, each with a falsifier'`.
4. Leave the three per-prediction assertions (`claim`, `falsifiedBy`, `metric` length checks) untouched — they must still hold for id 6, and they do.

Add this comment immediately above `PINNED_SHA256`, so the next reader learns why the digest moved without going to `git log`:

```typescript
// Moved once, deliberately: issue #271 (E12) seals a sixth prediction here BEFORE its
// first rung, which is the same discipline §7.4 introduced rather than an exception to it.
// The five §7.4 entries are byte-identical; only an append happened. E12's own driver has
// no verdict machinery, so nothing it measures can feed back into this file.
```

- [ ] **Step 6: Run the pin test to verify it passes**

```bash
./node_modules/.bin/vitest run experiments/test/microvm-predictions.test.ts > "$LOG_DIR/pin-green.log" 2>&1; echo "EXIT:$?"
grep -E "Tests|Errors" "$LOG_DIR/pin-green.log"
```

Expected: `EXIT:0` and `Tests  3 passed`. Also grep for `Errors` and confirm there are none — vitest can exit non-zero with every test green when an unhandled error escapes the summary, and the reverse trap is why the grep is here rather than eyeballing the tail.

- [ ] **Step 7: Confirm nothing else that reads the file regressed**

```bash
./node_modules/.bin/vitest run experiments/test/ > "$LOG_DIR/pin-suite.log" 2>&1; echo "EXIT:$?"
tail -20 "$LOG_DIR/pin-suite.log"
```

Expected: no new failures versus `$LOG_DIR/pin-before.log`. `microvm-density`'s tests read this file for ids only.

- [ ] **Step 8: Commit**

```bash
git add deploy/microvm/predictions.json experiments/test/microvm-predictions.test.ts
git commit -s -F - <<'MSG'
test(microvm): seal E12's prediction before its first rung

Issue #271 asks for a guest-initiated-vsock-across-restore probe and, per P4
§7.4's practice, for its prediction to be sealed before any rung runs. That
means appending to predictions.json, which is SHA-256 pinned.

The pin moves here for the reason its own docstring allows: this is an append
made BEFORE any measurement it could be informed by, not a restatement fitted
to a result. §7.4's five entries are byte-identical; id 6 is new. E12 has no
verdict machinery, so nothing it measures can feed back into this file.

toHaveLength(5) becomes 6. The per-prediction falsifier assertions are
unchanged and hold for id 6.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 2: Driver contract — env, preflight, snapshot integrity, records

Builds the driver's skeleton and its test file. No VM is started yet. At the end of this task the driver refuses to run for every wrong reason, correctly.

**Files:**

- Create: `deploy/microvm/e12-vsock-egress-probe.sh`
- Create: `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`

**Interfaces:**

- Consumes: nothing from Task 1.
- Produces, for Tasks 3-8:
  - `die(msg)` / `log(msg)` — print to stderr prefixed `e12: `; `die` exits 1.
  - Globals set at source time: `SUBSTRATE`, `SNAPSHOT_DIR`, `RESULTS`, `GUEST_CLIENT`, `FIRECRACKER_BIN`, `PROBE_PORT` (1025), `AGENT_PORT` (1024), `GUEST_RAM_MB` (256), `GUEST_CID` (3), `RUNGS`, `C_LADDER`.
  - `manifest_field(dir, key) -> string` on stdout.
  - `snapshot_rootfs_digest(dir) -> "sha256:<hex>"` on stdout.
  - `assert_snapshot_pristine(dir, phase)` — dies on drift.
  - `require_tool(name)`, `preflight()`.
  - `json_escape(s) -> string`, `write_json_record(path, json_text)` — dies on empty/unparseable.
  - `wants_rung(letter) -> exit 0/1`.
  - `E12_PROBE_SOURCE_ONLY=1` skips `main`.

- [ ] **Step 1: Write the failing test file**

Create `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`. This is the whole file for now; later tasks append sections to it.

```bash
#!/usr/bin/env bash
# deploy/microvm/tests/e12-vsock-egress-probe.test.sh
#
# Cluster-free, KVM-free tests for e12-vsock-egress-probe.sh. The driver itself
# needs /dev/kvm, a real Firecracker binary and a golden snapshot, so it cannot run
# on every PR -- but its CONTRACT can rot silently, and E12 answers a boolean that
# gates PR #268 entirely. A rotted contract here produces a boolean nobody should
# trust:
#
#   - it must refuse without SH_SUBSTRATE, and refuse a bare "nested" (E9 requires
#     the substrate be labeled by rig, not by class).
#   - it must be STRUCTURALLY incapable of printing STOP or MANDATORY: E12 has no
#     verdict, and a driver that can emit one invites a reader to treat a boolean
#     as a decision rule.
#   - it must verify the golden snapshot's rootfs digest BEFORE and AFTER a run.
#     A read-write mount alone changes an ext4 superblock, which would silently
#     invalidate #266's snapshot -- exit 0, no error, wrong result.
#   - it must die on an empty or unparseable per-rung record (#266's
#     mem_available_bytes bug: a missing rung still let a verdict print).
#   - it must require BOTH witnesses -- host-side nonce capture AND guest-side ACK
#     -- never either alone.
#
# The whole script cannot be sourced for these checks: it ends in an unconditional
# `main "$@"` that would immediately demand /dev/kvm and a snapshot. The driver
# supports E12_PROBE_SOURCE_ONLY=1 to skip main; for testing ONE function in
# isolation this file extracts that function's own source text and sources only
# that snippet in a subshell -- the same pattern e10-lifecycle.test.sh and
# build-snapshot.test.sh both use.
#
# Run: bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/e12-vsock-egress-probe.sh"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else
  echo "  FAIL: $1 (want '$3', got '$2')"
  fails=$((fails + 1))
fi; }

# extract_fn prints the source text of a top-level "name() { ... }" function
# (opening line "name() {" and closing bare "}") from $SCRIPT.
extract_fn() {
  local name="$1" start end
  start=$(grep -n "^${name}() {" "$SCRIPT" | head -n1 | cut -d: -f1)
  [ -n "$start" ] || return 1
  end=$(awk -v s="$start" 'NR>s && /^}$/{print NR; exit}' "$SCRIPT")
  [ -n "$end" ] || return 1
  sed -n "${start},${end}p" "$SCRIPT"
}

echo "== the script exists, is executable, and is shellcheck-clean"
check "driver present" "$([ -f "$SCRIPT" ] && echo yes || echo no)" "yes"
check "driver executable" "$([ -x "$SCRIPT" ] && echo yes || echo no)" "yes"
if command -v shellcheck >/dev/null; then
  if shellcheck "$SCRIPT" >/tmp/e12-shellcheck.out 2>&1; then
    check "shellcheck" "clean" "clean"
  else
    check "shellcheck" "$(cat /tmp/e12-shellcheck.out)" "clean"
  fi
else
  echo "  skip: shellcheck not installed"
fi

echo "== set -uo pipefail, and NOT set -e (both sibling drivers omit -e deliberately)"
check "has set -uo pipefail" \
  "$(grep -cE '^set -uo pipefail$' "$SCRIPT")" "1"
check "does not set -e" \
  "$(grep -cE '^set -e|^set -[a-z]*e[a-z]* ' "$SCRIPT")" "0"

echo "== die and log are defined before their first caller"
die_line=$(grep -n '^die() {' "$SCRIPT" | head -n1 | cut -d: -f1)
first_call=$(grep -nE '(^|[^_[:alnum:]])die ' "$SCRIPT" | grep -v '^[0-9]*:die() {' | head -n1 | cut -d: -f1)
check "die defined before first use" \
  "$([ -n "$die_line" ] && [ -n "$first_call" ] && [ "$die_line" -lt "$first_call" ] && echo yes || echo no)" "yes"

echo "== SH_SUBSTRATE is required, and a bare 'nested' is refused"
out=$(env -u SH_SUBSTRATE bash "$SCRIPT" 2>&1)
check "refuses with no SH_SUBSTRATE" \
  "$(echo "$out" | grep -c 'SH_SUBSTRATE')" "1"
out=$(SH_SUBSTRATE=nested bash "$SCRIPT" 2>&1)
check "refuses a bare 'nested'" \
  "$([ "$(echo "$out" | grep -ci 'rig')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== structurally incapable of a verdict: no STOP/MANDATORY anywhere in the source"
check "no STOP token" "$(grep -c '\bSTOP\b' "$SCRIPT")" "0"
check "no MANDATORY token" "$(grep -c '\bMANDATORY\b' "$SCRIPT")" "0"

echo "== the snapshot integrity guard runs before AND after, and reads the manifest"
pristine_body="$(extract_fn assert_snapshot_pristine || true)"
check "assert_snapshot_pristine exists" \
  "$([ -n "$pristine_body" ] && echo yes || echo no)" "yes"
check "it compares against manifest rootfs_sha256" \
  "$(echo "$pristine_body" | grep -c 'rootfs_sha256')" "2"
check "it dies on drift" \
  "$([ "$(echo "$pristine_body" | grep -c 'die')" -ge 1 ] && echo yes || echo no)" "yes"
check "called with a 'before' phase" \
  "$([ "$(grep -c 'assert_snapshot_pristine "\$SNAPSHOT_DIR" before' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "called with an 'after' phase" \
  "$([ "$(grep -c 'assert_snapshot_pristine "\$SNAPSHOT_DIR" after' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"

echo "== write_json_record dies on an empty or unparseable record (#266's bug class)"
rec_body="$(extract_fn write_json_record || true)"
check "write_json_record exists" "$([ -n "$rec_body" ] && echo yes || echo no)" "yes"
check "it rejects an empty record" \
  "$([ "$(echo "$rec_body" | grep -c '\-s ')" -ge 1 ] && echo yes || echo no)" "yes"
check "it validates JSON" \
  "$([ "$(echo "$rec_body" | grep -c 'json.load')" -ge 1 ] && echo yes || echo no)" "yes"

# Behavioural, not textual: call the real function on a real bad input.
rec_tmp="$(mktemp -d)"
( eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"$rec_body"
  write_json_record "$rec_tmp/empty.json" "" ) >/dev/null 2>&1
check "write_json_record exits non-zero on empty JSON text" "$?" "1"
( eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"$rec_body"
  write_json_record "$rec_tmp/bad.json" "{not json" ) >/dev/null 2>&1
check "write_json_record exits non-zero on malformed JSON" "$?" "1"
( eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"$rec_body"
  write_json_record "$rec_tmp/good.json" '{"rung":"A","ok":true}' ) >/dev/null 2>&1
check "write_json_record accepts valid JSON" "$?" "0"
rm -rf "$rec_tmp"

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "all checks passed"
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t2-red.log" 2>&1; echo "EXIT:$?"
head -5 "$LOG_DIR/t2-red.log"
```

Expected: non-zero exit, first failure `driver present (want 'yes', got 'no')`.

- [ ] **Step 3: Write the driver's header, env contract, and helpers**

Create `deploy/microvm/e12-vsock-egress-probe.sh` with exactly this content (later tasks append; do not reorder — `die`/`log` must stay above every caller).

```bash
#!/usr/bin/env bash
# deploy/microvm/e12-vsock-egress-probe.sh
#
# E12 (issue #271): does a guest-initiated vsock connection on a SECOND port
# survive Firecracker snapshot restore, and survive N concurrent restores of one
# snapshot?
#
# This is a mechanism-existence probe, not a measurement. There is no threshold,
# no baseline and no ladder analysis: it prints a boolean. It gates PR #268's
# P4.1 egress transport, whose decision T1 routes all sandbox egress over vsock
# because the microVM tier has no network device at all.
#
# WHAT IS ALREADY KNOWN, and therefore not re-derived here:
#   - LISTENING vsock sockets survive restore with the CID updated, and
#     established connections are closed on resume. That is P4 §2.4, and it is
#     the HOST-INITIATED direction only.
#   - Guest->host is a different mechanism: the host must pre-create and listen
#     on <uds_path>_<PORT>, there is NO handshake, and Firecracker forwards the
#     connection when it sees VIRTIO_VSOCK_OP_REQUEST. The guest connects to
#     CID 2. If nobody listens, the guest gets VIRTIO_VSOCK_OP_RST.
#   - Firecracker's own docs say "vsock snapshot support is currently limited"
#     and note a device-reset limitation. That sentence is the entire reason
#     this script exists.
#
# WHY THERE IS NO SUBSTRATE BLACKLIST. Issue #271 says to run this on
# nested-m8i and "never metal", because folding a probe helper into a rootfs
# would change its digest and silently invalidate #266's metal comparison. That
# hazard is real but it is not about the substrate's NAME -- it is about writing
# to the snapshot. This driver never writes to it: it hardlinks the files in,
# mounts rootfs is_read_only, boots with `ro`, and verifies rootfs_sha256
# against manifest.json before AND after every run. That guard is mechanical and
# unconditional, so it also holds on the metal confirmation run the issue defers
# ("Metal confirmation should ride along with whichever later run builds a metal
# snapshot anyway"), which a name check would have had to be edited to allow.
#
# WHY IT DUPLICATES build-snapshot.sh's JAIL HELPERS instead of sharing them.
# deploy/microvm/tests/build-snapshot.test.sh greps write_guest_client's body and
# asserts statement ORDERING inside it. Extracting shared helpers out of a
# 1928-line, source-order-coupled script for a throwaway probe would break that
# test to no benefit. Each copied helper below names its origin.
#
# Usage:
#   SH_SUBSTRATE=nested-m8i \
#   SH_GUEST_CLIENT=/path/to/guest_client \
#   sudo -E deploy/microvm/e12-vsock-egress-probe.sh
#
set -uo pipefail

# Defined first, deliberately: e10-lifecycle.sh:128 records what happens
# otherwise -- "die: command not found" on the failure path, and the script
# carries on past the thing it was supposed to refuse.
die() { echo "e12: $*" >&2; exit 1; }
log() { echo "e12: $*" >&2; }

# SH_SUBSTRATE stays an explicit, required, operator-set env var rather than
# being sniffed: E9's own phrasing is that the rig must be named, not its class,
# because "nested" alone cannot tell two rigs apart in a run record.
SUBSTRATE="${SH_SUBSTRATE:?set SH_SUBSTRATE (e.g. nested-m8i or metal) - every run record must name the substrate, and E9 requires it be labeled by rig, not bare nested}"
case "$SUBSTRATE" in
  nested | nested- | metal-)
    die "SH_SUBSTRATE='$SUBSTRATE' is not rig-labeled - use a specific rig (e.g. nested-m8i), because a bare class cannot tell two rigs apart in a run record"
    ;;
esac

SNAPSHOT_DIR="${SH_SNAPSHOT_IMAGE_DIR:-/srv/snapshots/default}"
RESULTS="${SH_E12_RESULTS:-/tmp/e12-results}"
GUEST_CLIENT="${SH_GUEST_CLIENT:-}"
FIRECRACKER_BIN="${SH_FIRECRACKER_BIN:-firecracker}"
JAIL_BASE="${SH_E12_JAIL_BASE:-/srv/e12-jails}"
PROBE_PORT="${SH_E12_PROBE_PORT:-1025}"
AGENT_PORT=1024
GUEST_RAM_MB=256
GUEST_CID=3
RUNGS="${SH_E12_RUNGS:-A B C D}"
C_LADDER="${SH_E12_C_LADDER:-8 128}"

wants_rung() { case " $RUNGS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- snapshot integrity ------------------------------------------------------
# The golden snapshot is shared, read-only state. A read-write loop mount alone
# is enough to change an ext4 superblock, and that would invalidate #266's
# comparison INVISIBLY -- exit 0, no error, wrong result. So the digest is
# checked before and after, and a drift is fatal rather than a warning.
manifest_field() {
  local dir="$1" key="$2"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
    "$dir/manifest.json" "$key"
}

snapshot_rootfs_digest() {
  local dir="$1"
  printf 'sha256:%s\n' "$(sha256sum "$dir/rootfs" | awk '{print $1}')"
}

assert_snapshot_pristine() {
  local dir="$1" phase="$2" want actual
  want="$(manifest_field "$dir" rootfs_sha256)" ||
    die "could not read rootfs_sha256 from $dir/manifest.json ($phase)"
  actual="$(snapshot_rootfs_digest "$dir")" ||
    die "could not digest $dir/rootfs ($phase)"
  [ "$actual" = "$want" ] ||
    die "golden snapshot rootfs digest drifted $phase the run: manifest says $want, the file is $actual. Something wrote to a snapshot that must stay read-only; do NOT trust any result from this run, and do not reuse this snapshot until it is rebuilt."
  log "snapshot rootfs digest verified $phase the run ($actual)"
}

# --- records -----------------------------------------------------------------
json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.argv[1]))' "$1"
}

# write_json_record refuses to leave behind a rung record that is empty or not
# parseable. #266 shipped a ladder whose mem_available_bytes was blank: the run
# exited 0 and still printed a verdict, and the missing field read as the most
# favourable value. A boolean probe has the same failure mode in a smaller
# space, so the guard is the same.
write_json_record() {
  local path="$1" body="$2"
  [ -n "$body" ] ||
    die "refusing to write an EMPTY record to $path - a rung that recorded nothing must not look like a rung that passed"
  printf '%s\n' "$body" >"$path" ||
    die "could not write the record for $path"
  [ -s "$path" ] ||
    die "the record at $path is zero bytes after writing"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$path" >/dev/null 2>&1 ||
    die "the record at $path is not valid JSON - refusing to read a boolean out of it"
}

# --- preflight ---------------------------------------------------------------
require_tool() {
  command -v "$1" >/dev/null 2>&1 ||
    die "required tool '$1' is not on PATH"
}

preflight() {
  [ "$(id -u)" -eq 0 ] ||
    die "must run as root: this script chroots, bind-mounts /dev/kvm and hardlinks into a jail"
  local t
  for t in curl python3 sha256sum awk mkfs.ext4 truncate; do require_tool "$t"; done
  command -v "$FIRECRACKER_BIN" >/dev/null 2>&1 ||
    die "firecracker binary '$FIRECRACKER_BIN' is not on PATH (override with SH_FIRECRACKER_BIN)"
  [ -c /dev/kvm ] || die "/dev/kvm is missing - this probe needs a hypervisor, there is no fake mode"
  [ -r /dev/kvm ] || die "/dev/kvm is not readable by root - check the kvm group and the device mode"
  [ -n "$GUEST_CLIENT" ] ||
    die "set SH_GUEST_CLIENT to a guest_client binary built from remote-worker (it speaks the framed protocol the guest agent listens for on vsock:$AGENT_PORT)"
  [ -x "$GUEST_CLIENT" ] || die "SH_GUEST_CLIENT='$GUEST_CLIENT' is not executable"
  [ -d "$SNAPSHOT_DIR" ] ||
    die "no golden snapshot at $SNAPSHOT_DIR (override with SH_SNAPSHOT_IMAGE_DIR); build one with deploy/microvm/build-snapshot.sh"
  local f
  for f in kernel rootfs memfile vmstate manifest.json; do
    [ -f "$SNAPSHOT_DIR/$f" ] ||
      die "the snapshot at $SNAPSHOT_DIR is missing $f"
  done
  python3 -c 'import socket,sys; sys.exit(0 if hasattr(socket,"AF_VSOCK") else 1)' ||
    die "this host's python3 has no AF_VSOCK - the host-side listener needs it"
  mkdir -p "$RESULTS" || die "could not create the results directory $RESULTS"
  mkdir -p "$JAIL_BASE" || die "could not create the jail base $JAIL_BASE"
  log "preflight ok: substrate=$SUBSTRATE snapshot=$SNAPSHOT_DIR results=$RESULTS"
}
```

- [ ] **Step 4: Add the source-only guard and a placeholder main at the very end of the driver**

Append to `deploy/microvm/e12-vsock-egress-probe.sh`. Tasks 3-8 insert their functions _above_ this block.

```bash
# --- entrypoint --------------------------------------------------------------
main() {
  preflight
  assert_snapshot_pristine "$SNAPSHOT_DIR" before
  assert_snapshot_pristine "$SNAPSHOT_DIR" after
}

# e10-lifecycle.sh uses the same escape hatch, for the same reason: the tests
# need to source ONE function without main() immediately demanding /dev/kvm.
if [ "${E12_PROBE_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
```

Make it executable:

```bash
chmod +x deploy/microvm/e12-vsock-egress-probe.sh
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t2-green.log" 2>&1; echo "EXIT:$?"
tail -5 "$LOG_DIR/t2-green.log"
```

Expected: `EXIT:0`, ending in `all checks passed`. If `shellcheck` reports `SC2317` or similar on the unreachable `assert_snapshot_pristine ... after` in the placeholder `main`, that is expected to disappear in Task 8 when `main` gains real rungs; if shellcheck fails now, fix it now rather than deferring.

- [ ] **Step 6: Confirm the suite-level target still passes**

```bash
bash deploy/microvm/tests/e10-lifecycle.test.sh > "$LOG_DIR/t2-e10.log" 2>&1; echo "E10_EXIT:$?"
bash deploy/microvm/tests/build-snapshot.test.sh > "$LOG_DIR/t2-bs.log" 2>&1; echo "BS_EXIT:$?"
```

Expected: both `0`. These prove the new file did not disturb its siblings (it must not have — nothing was refactored).

- [ ] **Step 7: Commit**

```bash
git add deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh
git commit -s -F - <<'MSG'
feat(microvm): E12 driver contract - env, preflight, snapshot integrity, records

The skeleton of issue #271's probe: it starts no VM yet, and refuses to run for
every wrong reason. Required rig-labeled SH_SUBSTRATE (a bare "nested" is
rejected), fail-closed preflight, and a per-rung record writer that dies on an
empty or unparseable record -- #266 shipped a ladder with a blank
mem_available_bytes that exited 0 and still printed a verdict.

Two deliberate choices, both explained in the header:

The golden snapshot is protected mechanically rather than by a substrate name
check. The driver hardlinks the snapshot in, mounts rootfs read-only, boots
`ro`, and verifies rootfs_sha256 against manifest.json before AND after every
run. A read-write mount alone changes an ext4 superblock, which would
invalidate #266's comparison invisibly. This guard also holds for the metal
confirmation run #271 defers, which a "never metal" name check would have had
to be edited to allow.

build-snapshot.sh is NOT refactored to share its jail helpers.
build-snapshot.test.sh greps write_guest_client's body for statement ordering,
so extracting shared helpers would break a source-order-coupled test for a
throwaway probe. Each copied helper names its origin.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 3: Jail lifecycle helpers (copied, not shared, from build-snapshot.sh)

Adds the jail primitives every rung needs: prepare, mount `/dev/kvm`, wait for the API socket, teardown. No Firecracker boot yet.

**Files:**

- Modify: `deploy/microvm/e12-vsock-egress-probe.sh` (insert above the `# --- entrypoint ---` block from Task 2 Step 4)
- Modify: `deploy/microvm/tests/e12-vsock-egress-probe.test.sh` (append)

**Interfaces:**

- Consumes: `die`, `log`, `JAIL_BASE`, `FIRECRACKER_BIN` from Task 2.
- Produces, for Task 4 onward:
  - `api_put(sock, path, json_body)` — PUT over `curl --unix-socket`.
  - `wait_for_socket(sock, console_log, timeout_s=5)` — polls with a real HTTP round trip, never a bare `[ -e ]`.
  - `prepare_jail(jail) -> sets CLEANUP_JAIL`.
  - `link_snapshot_into_jail(jail)` — hardlinks `kernel`, `rootfs`, `memfile`, `vmstate` from `$SNAPSHOT_DIR`, falling back to `cp -p` cross-device.
  - `teardown_jail(jail, pid)` — kills the VMM, unmounts `/dev/kvm`, removes the jail dir.
  - `CLEANUP_JAIL`, `CLEANUP_PID` globals, plus a `cleanup_on_exit` trap registered in Task 2's `main`.

- [ ] **Step 1: Append the failing test section**

Append to `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`, just above the final `echo` / `if [ "$fails" -ne 0 ]` block:

```bash
echo "== jail helpers exist and are named after what they copy"
for fn in api_put wait_for_socket prepare_jail link_snapshot_into_jail teardown_jail; do
  body="$(extract_fn "$fn" || true)"
  check "$fn exists" "$([ -n "$body" ] && echo yes || echo no)" "yes"
done

echo "== wait_for_socket polls with a real HTTP round trip, not a bare existence check"
wfs_body="$(extract_fn wait_for_socket || true)"
check "wait_for_socket uses curl, not just [ -S ]" \
  "$([ "$(echo "$wfs_body" | grep -c 'curl')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== link_snapshot_into_jail never opens the snapshot for writing"
link_body="$(extract_fn link_snapshot_into_jail || true)"
check "no O_WRONLY-shaped redirection into \$SNAPSHOT_DIR" \
  "$(echo "$link_body" | grep -cE '>\s*"?\$SNAPSHOT_DIR')" "0"
check "uses ln (hardlink), with a cp fallback" \
  "$([ "$(echo "$link_body" | grep -c '\bln\b')" -ge 1 ] && [ "$(echo "$link_body" | grep -c '\bcp\b')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== teardown_jail kills the VMM and does not leave the jail behind"
td_body="$(extract_fn teardown_jail || true)"
check "teardown_jail sends a kill" \
  "$([ "$(echo "$td_body" | grep -c '\bkill\b')" -ge 1 ] && echo yes || echo no)" "yes"
check "teardown_jail removes the jail dir" \
  "$([ "$(echo "$td_body" | grep -c 'rm -rf')" -ge 1 ] && echo yes || echo no)" "yes"
```

- [ ] **Step 2: Run the test to verify the new section fails**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t3-red.log" 2>&1; echo "EXIT:$?"
grep -A1 "jail helpers exist" "$LOG_DIR/t3-red.log"
```

Expected: `FAIL: api_put exists`.

- [ ] **Step 3: Insert the jail helpers**

Edit `deploy/microvm/e12-vsock-egress-probe.sh`: insert the block below immediately above the `# --- entrypoint ---` comment from Task 2 Step 4.

```bash
# --- jail lifecycle -----------------------------------------------------------
# Copied from deploy/microvm/build-snapshot.sh's api_put / wait_for_socket /
# prepare_jail / teardown_jail rather than shared: build-snapshot.test.sh greps
# write_guest_client's body for statement ORDERING, and extracting a shared lib
# out of that 1928-line source-order-coupled script for a throwaway probe would
# break that test for no benefit to either script. Behavior here matches the
# original; only the vsock/probe pieces are new (Task 4 onward).

api_put() {
  local sock="$1" path="$2" body="$3"
  curl -s -S --unix-socket "$sock" -X PUT "http://localhost$path" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null
}

# Matches build-snapshot.sh's own wait_for_socket: a bare `[ -e "$sock" ]` races,
# because Firecracker creates the socket file before it is actually accept()ing
# on it (confirmed on this rig: cloud-hypervisor lost that exact race). Poll with
# a real HTTP round trip instead; any response, even a 404, proves the daemon is
# accepting connections, which is the only thing this loop needs to prove.
wait_for_socket() {
  local sock="$1" console_log="$2" timeout_s="${3:-5}"
  local attempts=$((timeout_s * 10)) i=0
  while [ "$i" -lt "$attempts" ]; do
    if curl -s -S --unix-socket "$sock" -o /dev/null "http://localhost/" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  log "console log for the timed-out socket $sock:"
  cat "$console_log" >&2 2>/dev/null || true
  die "timed out after ${timeout_s}s waiting for $sock to accept connections"
}

CLEANUP_JAIL=""
CLEANUP_PID=""

jail_mount_dev() {
  local jail="$1"
  mkdir -p "$jail/dev"
  : >"$jail/dev/kvm"
  mount --bind /dev/kvm "$jail/dev/kvm" ||
    die "could not bind-mount /dev/kvm into the jail at $jail"
  : >"$jail/dev/urandom" 2>/dev/null || true
  mount --bind /dev/urandom "$jail/dev/urandom" 2>/dev/null || true
}

jail_unmount_dev() {
  local jail="$1"
  umount "$jail/dev/urandom" 2>/dev/null || true
  umount "$jail/dev/kvm" 2>/dev/null || true
}

prepare_jail() {
  local jail="$1"
  mkdir -p "$jail/run" || die "could not create $jail/run"
  # Always hardlinked in under the FIXED jail-relative name "firecracker",
  # regardless of what $FIRECRACKER_BIN resolves to on the host (e.g.
  # SH_FIRECRACKER_BIN=/opt/fc-1.17/firecracker-x86_64) - every caller below
  # execs "chroot \"$jail\" /firecracker", and that path must never depend on
  # the source binary's own basename. Matches build-snapshot.sh's
  # prepare_jail, which takes the jail-relative name as an explicit argument
  # for exactly this reason (its two arms hardlink to "firecracker" and
  # "cloud-hypervisor" respectively, never to the source path's basename).
  ln "$(command -v "$FIRECRACKER_BIN")" "$jail/firecracker" 2>/dev/null ||
    cp -p "$(command -v "$FIRECRACKER_BIN")" "$jail/firecracker"
  CLEANUP_JAIL="$jail"
  jail_mount_dev "$jail"
}

# link_snapshot_into_jail hardlinks the golden snapshot's four files into the
# jail. Hardlinking (not copying) is what keeps this cheap AND what keeps the
# guard in assert_snapshot_pristine meaningful -- a hardlink cannot be opened for
# writing by this process without ALSO changing the file every other hardlink
# (including the one under $SNAPSHOT_DIR) points at, which is exactly the drift
# assert_snapshot_pristine is watching for.
link_snapshot_into_jail() {
  local jail="$1" f
  for f in kernel rootfs memfile vmstate; do
    if ! ln "$SNAPSHOT_DIR/$f" "$jail/$f" 2>/dev/null; then
      log "WARNING: cross-device or no hardlink support - COPYING $f into $jail (last resort, not the normal path)"
      cp -p "$SNAPSHOT_DIR/$f" "$jail/$f"
    fi
  done
}

teardown_jail() {
  local jail="$1" pid="$2"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  jail_unmount_dev "$jail"
  rm -rf "$jail"
  CLEANUP_JAIL=""
  CLEANUP_PID=""
}

cleanup_on_exit() {
  if [ -n "$CLEANUP_PID" ]; then
    kill "$CLEANUP_PID" 2>/dev/null || true
  fi
  if [ -n "$CLEANUP_JAIL" ]; then
    jail_unmount_dev "$CLEANUP_JAIL"
    rm -rf "$CLEANUP_JAIL" 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t3-green.log" 2>&1; echo "EXIT:$?"
tail -5 "$LOG_DIR/t3-green.log"
```

Expected: `EXIT:0`, `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh
git commit -s -F - <<'MSG'
feat(microvm): E12 jail lifecycle helpers, copied from build-snapshot.sh

api_put, wait_for_socket, prepare_jail, link_snapshot_into_jail, teardown_jail
and the exit trap that runs them. Copied rather than extracted into a shared
lib, for the reason recorded in the driver's own header comment:
build-snapshot.test.sh asserts write_guest_client's internal statement
ordering, and a shared-lib refactor would break that test for a throwaway
probe's benefit.

link_snapshot_into_jail hardlinks by default, matching build-snapshot.sh, which
is also what keeps assert_snapshot_pristine meaningful: a hardlink cannot be
written to without the drift showing up under $SNAPSHOT_DIR too.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 4: The two-witness vsock probe (host listener + guest client build)

This is the task that answers the "is this even possible" question. Writes the host-side listener plus the guest-side python3 probe script, both embedded in the driver.

**Files:**

- Modify: `deploy/microvm/e12-vsock-egress-probe.sh` (insert above `# --- entrypoint ---`)
- Modify: `deploy/microvm/tests/e12-vsock-egress-probe.test.sh` (append)

**Interfaces:**

- Consumes: `PROBE_PORT`, `AGENT_PORT`, `GUEST_CLIENT`, `die`, `log`, `json_escape` from Tasks 2-3.
- Produces, for Task 5 onward:
  - `start_host_listener(jail, nonce) -> prints "pid:<pid> capture:<path>"` — backgrounds a python3 `AF_UNIX` accept loop on `$jail/vsock.sock_1025`, writes the first line it reads to `<path>`, replies `ACK <nonce>`, then exits.
  - `stop_host_listener(pid)`.
  - `guest_probe_command(nonce) -> string` — the full shell command line to hand to `guest_client -command`: writes the embedded python3 script to `/tmp/e12-probe.py` in the guest via a base64 pipe, then runs it with `$nonce` and `$PROBE_PORT` as argv.
  - `run_probe_once(jail, vsock_uds, label) -> writes $RESULTS/<label>.json, returns 0/1` — the single-VM two-witness check reused by every rung.

- [ ] **Step 1: Append the failing test section**

Append to `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`, just above the final `echo` / `if [ "$fails" -ne 0 ]` block:

```bash
echo "== the two-witness probe: host listener, guest command, and the combining check"
for fn in start_host_listener stop_host_listener guest_probe_command run_probe_once; do
  body="$(extract_fn "$fn" || true)"
  check "$fn exists" "$([ -n "$body" ] && echo yes || echo no)" "yes"
done

echo "== the guest probe connects to CID 2, not CID 3 (guest connects OUT to the host)"
check "guest_probe_command embeds the guest-side python3 script" \
  "$([ "$(grep -c 'AF_VSOCK' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "the embedded script targets VMADDR_CID_HOST (2), not the guest's own CID" \
  "$([ "$(grep -c 'VMADDR_CID_HOST' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"

echo "== run_probe_once requires BOTH witnesses, never either alone"
rpo_body="$(extract_fn run_probe_once || true)"
check "checks the host-side capture file" \
  "$([ "$(echo "$rpo_body" | grep -c 'capture')" -ge 1 ] && echo yes || echo no)" "yes"
check "checks the guest stdout for an ACK" \
  "$([ "$(echo "$rpo_body" | grep -c 'ACK')" -ge 1 ] && echo yes || echo no)" "yes"
# Both witness variables must appear together on the SAME line joined by &&,
# not merely somewhere in the function (which "true" for host_ok and later,
# separately, for guest_ok would also satisfy) and not joined by ||.
check "combines both with an explicit AND (&&), not an OR" \
  "$([ "$(echo "$rpo_body" | grep -cE '\$host_ok.*&&.*\$guest_ok|\$guest_ok.*&&.*\$host_ok')" -ge 1 ] && echo yes || echo no)" "yes"
check "does not combine the two witnesses with ||" \
  "$(echo "$rpo_body" | grep -cE '\$host_ok.*\|\||\$guest_ok.*\|\|')" "0"

echo "== the host listener behaves like a real accept-once-and-reply server"
listener_tmp="$(mktemp -d)"
start_body="$(extract_fn start_host_listener || true)"
stop_body="$(extract_fn stop_host_listener || true)"
(
  # start_host_listener references $PROBE_PORT, a global normally set when the
  # whole script is sourced - it must be set explicitly here since this
  # subshell only defines the one extracted function, not the driver's env
  # contract (Task 2). It is set to the same 1025 default the driver itself
  # uses, matching the hardcoded socket path this test connects to below.
  PROBE_PORT=1025
  eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"log() { :; }"$'\n'"$start_body"$'\n'"$stop_body"
  out="$(start_host_listener "$listener_tmp" testnonce123)"
  pid="${out#pid:}"; pid="${pid%% *}"
  sock="$listener_tmp/vsock.sock_1025"
  # Poll briefly for the listener to bind (it is backgrounded).
  for _ in $(seq 1 20); do [ -S "$sock" ] && break; sleep 0.1; done
  echo -n "testnonce123" | python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(sys.stdin.buffer.read() + b"\n")
print(s.recv(4096).decode().strip())
' "$sock" >"$listener_tmp/reply.txt" 2>&1
  stop_host_listener "$pid"
) >"$listener_tmp/out.log" 2>&1
check "listener replied with the expected ACK" \
  "$(cat "$listener_tmp/reply.txt" 2>/dev/null)" "ACK testnonce123"
check "listener captured the nonce to its capture file" \
  "$(cat "$listener_tmp/vsock.sock_1025.captured" 2>/dev/null)" "testnonce123"
rm -rf "$listener_tmp"

echo "== guest_probe_command's wire format matches run_probe_once's own comparisons exactly"
# The listener test above hand-types "testnonce123" as the client payload,
# which proves the LISTENER's own accept-reply logic but never exercises what
# guest_probe_command ACTUALLY tells the guest to send - so a mismatch between
# the two (e.g. a prefix tag the guest sends that the host-side/run_probe_once
# comparisons don't expect) would pass every check above while still making
# every real rung fail. This check decodes guest_probe_command's OWN embedded
# python source (not a hand-typed stand-in) and confirms it sends the BARE
# nonce with no prefix, matching run_probe_once's exact-match comparisons
# (host_nonce = $nonce, and *"ACK $nonce"* against guest_out).
gpc_body="$(extract_fn guest_probe_command || true)"
check "guest_probe_command exists" "$([ -n "$gpc_body" ] && echo yes || echo no)" "yes"
gpc_cmd="$(
  # guest_probe_command also references $PROBE_PORT (a global normally set
  # when the whole script is sourced) - same reason as the listener test
  # above needing it set explicitly in an isolated eval context.
  PROBE_PORT=1025
  eval "die() { echo \"e12: \$*\" >&2; exit 1; }"$'\n'"$gpc_body"
  guest_probe_command "wireformat-check-nonce"
)"
gpc_b64="$(printf '%s' "$gpc_cmd" | sed -n 's/^echo \([^ ]*\) | base64 -d.*/\1/p')"
gpc_decoded="$(printf '%s' "$gpc_b64" | base64 -d 2>/dev/null || true)"
check "the embedded guest script sends the bare nonce (no tag prefix)" \
  "$([ "$(echo "$gpc_decoded" | grep -cE 'sendall\(\(nonce \+')" -ge 1 ] && echo yes || echo no)" "yes"
check "the embedded guest script does NOT prepend any tag before the nonce" \
  "$(echo "$gpc_decoded" | grep -cE 'sendall\(\("[^"]+" \+ nonce')" "0"
```

- [ ] **Step 2: Run the test to verify the new section fails**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t4-red.log" 2>&1; echo "EXIT:$?"
grep -A1 "two-witness probe" "$LOG_DIR/t4-red.log"
```

Expected: `FAIL: start_host_listener exists`.

- [ ] **Step 3: Insert the probe functions**

Insert above `# --- entrypoint ---`:

```bash
# --- the two-witness vsock probe ---------------------------------------------
# The question this whole script exists to answer has exactly one honest
# failure mode worth guarding against: believing a connection happened when it
# did not, or vice versa. So every check requires TWO INDEPENDENT witnesses:
#   1. HOST-SIDE (authoritative): the accept loop on <jail>/vsock.sock_1025
#      actually received the guest's nonce and wrote it to a capture file.
#   2. GUEST-SIDE (corroboration only, never a timing source - spec §2.4: guest
#      clocks jump on resume): the guest's own stdout, relayed back through the
#      EXISTING agent Exec path on vsock:1024, shows the ACK it read back.
# A witness that could be satisfied by either side alone is not verifying a
# vsock connection; it is verifying that a process ran, which is a strictly
# weaker claim than "the guest reached the host over the SECOND port".

# start_host_listener backs a single-shot accept loop with python3 (present on
# every host this driver's preflight already required). It listens on
# <jail>/vsock.sock_1025 -- the "<uds_path>_<PORT>" naming vsock.md documents
# for the guest-initiated direction -- accepts exactly one connection, reads one
# line, writes it verbatim to <jail>/vsock.sock_1025.captured, replies
# "ACK <line>\n", and exits. Firecracker needs no handshake for this direction:
# the socket only needs to EXIST at connect time.
start_host_listener() {
  # jail/nonce and sock are split into two `local` statements deliberately: a
  # single `local a="$1" b="$a/x"` does NOT let b see the freshly-assigned a -
  # bash expands every word of a command (local included) before the command
  # runs, so "$a" in b's assignment would resolve against whatever a held in
  # the ENCLOSING scope, not the value just set moments earlier in the same
  # statement. Under this script's `set -u`, that reads as an unbound
  # variable rather than merely a wrong value.
  local jail="$1" nonce="$2" pyfile
  local sock="$jail/vsock.sock_${PROBE_PORT}"
  pyfile="$jail/.e12-listener.py"
  cat >"$pyfile" <<'PYEOF'
import socket, sys, os
sock_path, capture_path = sys.argv[1], sys.argv[2]
try:
    os.unlink(sock_path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
os.chmod(sock_path, 0o666)
srv.listen(1)
conn, _ = srv.accept()
data = conn.recv(4096)
line = data.decode(errors="replace").strip()
with open(capture_path, "w") as f:
    f.write(line)
conn.sendall(("ACK " + line + "\n").encode())
conn.close()
srv.close()
PYEOF
  # Redirected, not left to inherit this function's own stdout/stderr: every
  # caller captures start_host_listener's return value via `out="$(...)"`,
  # and command substitution does not return until every holder of the
  # pipe's write end closes it - an unredirected backgrounded child inherits
  # that write end and keeps it open while blocked in accept(), which hangs
  # the whole capture forever whenever no client connects in time. Found the
  # hard way: this masked itself behind an unrelated bug in an earlier round
  # of this same task, and only surfaced once that bug was fixed.
  python3 "$pyfile" "$sock" "$sock.captured" >/dev/null 2>&1 &
  local pid=$!
  echo "pid:$pid capture:$sock.captured"
}

stop_host_listener() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# guest_probe_command returns a full shell command line for `guest_client
# -command`: it writes the embedded guest-side python3 script into the guest's
# /tmp via a base64 pipe (the agent runs `sh -c "$req.Command"`, so a pipeline is
# legal - remote-worker/internal/guestagent/agent.go:424), then runs it. The
# script connects AF_VSOCK to VMADDR_CID_HOST (2) -- the host, from the guest's
# point of view, per vsock.md -- on $PROBE_PORT, sends the BARE nonce (no
# prefix tag - the nonce already starts with "e12-", so a tag would be purely
# redundant AND would break run_probe_once's own exact-match comparisons
# below, which compare the captured host-side value and the ACK reply against
# $nonce verbatim), reads the reply, and prints it to guest stdout so
# guest_client relays it back to us.
guest_probe_command() {
  local nonce="$1" b64
  b64="$(cat <<'PYEOF' | base64 | tr -d '\n'
import socket, sys
nonce, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.settimeout(10)
s.connect((socket.VMADDR_CID_HOST, port))
s.sendall((nonce + "\n").encode())
reply = s.recv(4096).decode(errors="replace").strip()
print(reply)
s.close()
PYEOF
)"
  printf 'echo %s | base64 -d > /tmp/e12-probe.py && python3 /tmp/e12-probe.py %s %s' \
    "$b64" "$nonce" "$PROBE_PORT"
}

# run_probe_once is the single-VM check every rung reuses. It assumes the VM at
# $vsock_uds is already up (fresh-booted or restored) and its agent is already
# reachable on $AGENT_PORT - callers run wait_for_agent (Task 5/6/7) first.
#
# label names the record file this writes: $RESULTS/$label.json. The record's
# "ok" field is the boolean this whole probe exists to produce, and it is TRUE
# only when BOTH witnesses agree - never from either alone.
run_probe_once() {
  local jail="$1" vsock_uds="$2" label="$3"
  local nonce="e12-${label}-$$-${RANDOM}"
  local listener_out capture_path lpid
  listener_out="$(start_host_listener "$jail" "$nonce")"
  lpid="${listener_out#pid:}"; lpid="${lpid%% capture:*}"
  capture_path="${listener_out#*capture:}"

  local guest_out guest_rc=0
  guest_out="$("$GUEST_CLIENT" -uds "$vsock_uds" -port "$AGENT_PORT" -timeout-s 15 \
    -command "$(guest_probe_command "$nonce")" 2>&1)" || guest_rc=$?

  # Give the listener a moment to flush its capture file even if the guest side
  # already returned - the host accept()/recv()/write() can trail the guest's
  # own print by a few milliseconds.
  local i host_nonce=""
  for i in $(seq 1 20); do
    [ -f "$capture_path" ] && host_nonce="$(cat "$capture_path" 2>/dev/null)" && [ -n "$host_nonce" ] && break
    sleep 0.1
  done
  stop_host_listener "$lpid"

  local host_ok=no guest_ok=no
  [ "$host_nonce" = "$nonce" ] && host_ok=yes
  case "$guest_out" in *"ACK $nonce"*) guest_ok=yes ;; esac

  local ok=false
  [ "$host_ok" = yes ] && [ "$guest_ok" = yes ] && ok=true

  write_json_record "$RESULTS/${label}.json" "$(printf '{"rung":%s,"ok":%s,"nonce":%s,"host_witness":%s,"guest_witness":%s,"guest_client_exit":%s,"guest_output":%s}' \
    "$(json_escape "$label")" "$ok" "$(json_escape "$nonce")" \
    "$(json_escape "$host_ok")" "$(json_escape "$guest_ok")" "$guest_rc" "$(json_escape "$guest_out")")"

  log "$label: host_witness=$host_ok guest_witness=$guest_ok ok=$ok"
  [ "$ok" = true ]
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t4-green.log" 2>&1; echo "EXIT:$?"
tail -5 "$LOG_DIR/t4-green.log"
```

Expected: `EXIT:0`, `all checks passed`. This test runs the real `start_host_listener`/`stop_host_listener` end-to-end over a real `AF_UNIX` socket (no VM involved), so it is real evidence the accept-once-and-reply logic works before any Firecracker boot is attempted.

- [ ] **Step 5: Commit**

```bash
git add deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh
git commit -s -F - <<'MSG'
feat(microvm): E12 two-witness vsock probe (host listener + guest command)

The core mechanism: a host-side python3 accept-once-and-reply loop on
<jail>/vsock.sock_1025 (the "<uds_path>_<PORT>" naming vsock.md documents for
the guest-initiated direction), and a guest-side python3 script - delivered
through the EXISTING agent Exec path on vsock:1024, base64-piped into the
guest's /tmp - that connects AF_VSOCK to VMADDR_CID_HOST (2) on port 1025.

run_probe_once requires BOTH witnesses before calling anything "ok": the
host-side capture file must contain the VM's nonce, AND the guest's own stdout
(relayed back through guest_client) must show the ACK. Neither alone is
evidence a second-port vsock connection happened; only their conjunction is.

The host listener's accept-loop is proven directly in the test over a real
AF_UNIX socket, no VM involved - real evidence before any Firecracker boot is
attempted.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 5: VM lifecycle helpers (fresh boot, restore) and rung A

Adds the two VM-bringup recipes every rung after this one reuses (fresh boot, restore-once), matching `build-snapshot.sh`'s own known-working `boot_quiesce_snapshot_firecracker`/`verify_restore_firecracker` configs exactly, so this task introduces no new risk in the recipe itself — only in what happens after the agent is reachable. Then wires up rung A: fresh boot, no restore, run the two-witness probe, teardown.

**Files:**

- Modify: `deploy/microvm/e12-vsock-egress-probe.sh` (insert above `# --- entrypoint ---`)
- Modify: `deploy/microvm/tests/e12-vsock-egress-probe.test.sh` (append)

**Interfaces:**

- Consumes: `prepare_jail`, `link_snapshot_into_jail`, `teardown_jail`, `api_put`, `wait_for_socket`, `run_probe_once`, `GUEST_RAM_MB`, `GUEST_CID`, `SNAPSHOT_DIR`, `RESULTS`, `JAIL_BASE` from Tasks 2-4.
- Produces, for Task 6 onward:
  - `ensure_workspace_image(path)` — `truncate` + `mkfs.ext4`.
  - `wait_for_agent(uds, console_log)` — polls `guest_client -probe-only`.
  - `boot_fresh_vm(jail)` / `restore_vm(jail)` — called as plain statements, NEVER via `$(...)` (command substitution forks a subshell, and `CLEANUP_PID`/`CLEANUP_JAIL` set inside the call would never propagate back out of it - see the driver's own comment on this at `boot_fresh_vm`'s end). On success, sets `VM_UDS` (the vsock uds path) directly, and leaves `CLEANUP_PID`/`CLEANUP_JAIL` (Task 3) pointing at the just-started process/jail for the caller's own `teardown_jail` call.
  - `run_rung_a()` — the first entry in `RUNGS`' dispatch, called from `main`.

- [ ] **Step 1: Append the failing test section**

Append to `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`, just above the final `echo` / `if [ "$fails" -ne 0 ]` block:

```bash
echo "== VM lifecycle helpers exist"
for fn in ensure_workspace_image wait_for_agent boot_fresh_vm restore_vm run_rung_a; do
  body="$(extract_fn "$fn" || true)"
  check "$fn exists" "$([ -n "$body" ] && echo yes || echo no)" "yes"
done

echo "== boot_fresh_vm configures rootfs read-only and does NOT load a snapshot"
bfv_body="$(extract_fn boot_fresh_vm || true)"
check "boot_fresh_vm calls /boot-source" \
  "$([ "$(echo "$bfv_body" | grep -c '/boot-source')" -ge 1 ] && echo yes || echo no)" "yes"
check "boot_fresh_vm calls /actions InstanceStart" \
  "$([ "$(echo "$bfv_body" | grep -c 'InstanceStart')" -ge 1 ] && echo yes || echo no)" "yes"
check "boot_fresh_vm does NOT call /snapshot/load" \
  "$(echo "$bfv_body" | grep -c '/snapshot/load')" "0"

echo "== boot_fresh_vm mounts rootfs read-only and boots ro, so the digest cannot drift by accident"
# .* skips over however the JSON's quotes happen to be escaped in the bash
# source (they are backslash-escaped here, since the JSON is embedded inside a
# double-quoted bash string) - these checks intentionally do not pin the exact
# escaping, only that each field is set to true on some line of boot_fresh_vm's
# own body. Scoped to $bfv_body (not the whole script) since this is what
# boot_fresh_vm itself configures - restore_vm's drives come from the restored
# snapshot state instead and carry no boot-source config to check here.
check "boot_fresh_vm's rootfs drive is_root_device true" \
  "$([ "$(echo "$bfv_body" | grep -c 'is_root_device.*true')" -ge 1 ] && echo yes || echo no)" "yes"
check "boot_fresh_vm's rootfs drive is_read_only true" \
  "$([ "$(echo "$bfv_body" | grep -c 'is_read_only.*true')" -ge 1 ] && echo yes || echo no)" "yes"
check "boot_fresh_vm's boot_args contain ro" \
  "$([ "$(echo "$bfv_body" | grep -c 'boot_args.*[^a-z]ro[^a-z]')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== restore_vm loads a snapshot with vsock_override and resume_vm true, and does NOT re-declare boot-source"
rv_body="$(extract_fn restore_vm || true)"
check "restore_vm calls /snapshot/load" \
  "$([ "$(echo "$rv_body" | grep -c '/snapshot/load')" -ge 1 ] && echo yes || echo no)" "yes"
check "restore_vm sets vsock_override" \
  "$([ "$(echo "$rv_body" | grep -c 'vsock_override')" -ge 1 ] && echo yes || echo no)" "yes"
check "restore_vm sets resume_vm true" \
  "$([ "$(echo "$rv_body" | grep -c 'resume_vm..:true')" -ge 1 ] && echo yes || echo no)" "yes"
check "restore_vm does NOT call /boot-source (restore carries no fresh-boot config)" \
  "$(echo "$rv_body" | grep -c '/boot-source')" "0"

echo "== run_rung_a boots fresh, runs the probe, and tears down"
ra_body="$(extract_fn run_rung_a || true)"
check "run_rung_a calls boot_fresh_vm" \
  "$([ "$(echo "$ra_body" | grep -c 'boot_fresh_vm')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_a calls run_probe_once" \
  "$([ "$(echo "$ra_body" | grep -c 'run_probe_once')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_a calls teardown_jail" \
  "$([ "$(echo "$ra_body" | grep -c 'teardown_jail')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_a labels its record rung-A" \
  "$([ "$(echo "$ra_body" | grep -c 'rung-A')" -ge 1 ] && echo yes || echo no)" "yes"
```

- [ ] **Step 2: Run the test to verify the new section fails**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t5-red.log" 2>&1; echo "EXIT:$?"
grep -A1 "VM lifecycle helpers exist" "$LOG_DIR/t5-red.log"
```

Expected: `FAIL: ensure_workspace_image exists`.

- [ ] **Step 3: Insert the VM lifecycle helpers and rung A**

Insert above `# --- entrypoint ---`:

```bash
# --- VM lifecycle: fresh boot and restore -------------------------------------
# Both recipes below match build-snapshot.sh's own boot_quiesce_snapshot_firecracker
# and verify_restore_firecracker exactly (drive config, vsock config, machine-config,
# the vsock_override shape) rather than reinventing them: those recipes are the ones
# already proven to work on this exact rig, so any failure here is about what E12
# adds (the second port), not about basic VM bringup.

ensure_workspace_image() {
  local path="$1"
  truncate -s $((2 * 1024 * 1024 * 1024)) "$path" ||
    die "could not truncate workspace image at $path"
  mkfs.ext4 -q -F "$path" >/dev/null || die "could not mkfs.ext4 the workspace image at $path"
}

wait_for_agent() {
  local uds="$1" console_log="$2" waited=0
  while [ "$waited" -lt 120 ]; do
    if [ -f "$console_log" ] && grep -q "parked in accept()" "$console_log" 2>/dev/null; then
      return 0
    fi
    if "$GUEST_CLIENT" -uds "$uds" -port "$AGENT_PORT" -probe-only -dial-timeout 1s 2>/dev/null; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "console log for the guest agent that never became reachable:"
  cat "$console_log" >&2 2>/dev/null || true
  die "guest agent never became reachable on vsock:$AGENT_PORT within 120s"
}

# boot_fresh_vm brings up a brand-new VM from the golden kernel+rootfs (no
# vmstate, no memfile - this is rung A, the control). rootfs is mounted
# is_read_only:true and boot_args carries `ro`, matching the Global Constraints'
# "never write to the golden snapshot" guard for the case where the snapshot's
# rootfs is used directly rather than via restore.
boot_fresh_vm() {
  local jail="$1"
  local api_sock="$jail/run/firecracker.socket" vsock_uds="$jail/vsock.sock" \
    console_log="$jail/console.log"
  prepare_jail "$jail"
  ln "$SNAPSHOT_DIR/kernel" "$jail/kernel" 2>/dev/null || cp -p "$SNAPSHOT_DIR/kernel" "$jail/kernel"
  ln "$SNAPSHOT_DIR/rootfs" "$jail/rootfs" 2>/dev/null || cp -p "$SNAPSHOT_DIR/rootfs" "$jail/rootfs"
  ensure_workspace_image "$jail/workspace.img"

  chroot "$jail" /firecracker --api-sock /run/firecracker.socket \
    </dev/null >"$console_log" 2>&1 &
  CLEANUP_PID=$!

  wait_for_socket "$api_sock" "$console_log"
  api_put "$api_sock" /boot-source \
    "{\"kernel_image_path\":\"/kernel\",\"boot_args\":\"console=ttyS0 ro reboot=k panic=1 pci=off\"}"
  api_put "$api_sock" /drives/rootfs \
    "{\"drive_id\":\"rootfs\",\"path_on_host\":\"/rootfs\",\"is_root_device\":true,\"is_read_only\":true}"
  api_put "$api_sock" /drives/workspace \
    "{\"drive_id\":\"workspace\",\"path_on_host\":\"/workspace.img\",\"is_root_device\":false,\"is_read_only\":false}"
  api_put "$api_sock" /vsock \
    "{\"vsock_id\":\"vsock0\",\"guest_cid\":$GUEST_CID,\"uds_path\":\"/vsock.sock\"}"
  api_put "$api_sock" /machine-config \
    "{\"mem_size_mib\":$GUEST_RAM_MB,\"vcpu_count\":1}"
  api_put "$api_sock" /actions '{"action_type":"InstanceStart"}'

  wait_for_agent "$vsock_uds" "$console_log"
  # Set a global, NOT echoed for the caller to capture via $(...): command
  # substitution always forks a subshell, and CLEANUP_PID/CLEANUP_JAIL (set a
  # few lines up, inside THIS call) would never propagate back out of that
  # subshell to the caller - the caller's own $CLEANUP_PID would stay at
  # whatever it was BEFORE this call, and teardown_jail would be handed an
  # empty pid, silently failing to kill the VM while still rm -rf-ing the jail
  # out from under it. Calling this function as a plain statement (no `$()`)
  # keeps CLEANUP_PID/CLEANUP_JAIL/VM_UDS in the CALLER's own shell, where the
  # top-level `trap cleanup_on_exit EXIT` (Task 3) can also see them if the
  # script dies before an explicit teardown_jail call runs.
  VM_UDS="$vsock_uds"
}

# restore_vm loads the golden vmstate+memfile into a fresh jail. vsock_override
# rewrites uds_path to this jail's OWN /vsock.sock (jail-relative, so every jail
# - even N of them concurrently under rung C - gets an independent socket with no
# collision, since chroot gives each one its own filesystem namespace). No
# /boot-source, /drives or /machine-config calls: restore carries all of that
# state already, and repeating them is rejected once InstanceStart has occurred
# once against those resources - build-snapshot.sh's own comment on this
# (fix-round-8) is why this function does not attempt it.
restore_vm() {
  local jail="$1"
  local api_sock="$jail/run/firecracker.socket" vsock_uds="$jail/vsock.sock" \
    console_log="$jail/console.log"
  prepare_jail "$jail"
  link_snapshot_into_jail "$jail"
  ensure_workspace_image "$jail/workspace.img"

  chroot "$jail" /firecracker --api-sock /run/firecracker.socket \
    </dev/null >"$console_log" 2>&1 &
  CLEANUP_PID=$!

  wait_for_socket "$api_sock" "$console_log"
  api_put "$api_sock" /snapshot/load \
    "{\"snapshot_path\":\"/vmstate\",\"mem_backend\":{\"backend_path\":\"/memfile\",\"backend_type\":\"File\"},\"vsock_override\":{\"uds_path\":\"/vsock.sock\"},\"resume_vm\":true}"

  wait_for_agent "$vsock_uds" "$console_log"
  # See boot_fresh_vm's identical comment above: a global, not an echoed
  # value, for exactly the same subshell-scoping reason.
  VM_UDS="$vsock_uds"
}

# --- rung A: fresh boot, no restore (the control) -----------------------------
# If this rung fails, the failure is our plumbing or the socket naming - NOT
# Firecracker's restore mechanism - because no restore happened yet. Without a
# passing rung A, a failure at rung B is uninterpretable.
run_rung_a() {
  local jail="$JAIL_BASE/rung-a"
  rm -rf "$jail"
  # Called as a plain statement, NOT captured via $(...) - see boot_fresh_vm's
  # own comment on why: this keeps VM_UDS/CLEANUP_PID in THIS function's own
  # shell rather than losing them to a vanished subshell.
  boot_fresh_vm "$jail" || die "rung-A: boot_fresh_vm failed"
  local ok=0
  run_probe_once "$jail" "$VM_UDS" "rung-A" || ok=1
  teardown_jail "$jail" "$CLEANUP_PID"
  return "$ok"
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t5-green.log" 2>&1; echo "EXIT:$?"
tail -5 "$LOG_DIR/t5-green.log"
```

Expected: `EXIT:0`, `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh
git commit -s -F - <<'MSG'
feat(microvm): E12 fresh-boot/restore VM helpers and rung A (control)

boot_fresh_vm and restore_vm match build-snapshot.sh's own
boot_quiesce_snapshot_firecracker / verify_restore_firecracker configs exactly
(drive config, vsock config, machine-config, the vsock_override shape), so any
failure in a later rung is about what E12 adds - a second guest-initiated port
- not about basic VM bringup that this repo already knows works on this rig.

restore_vm's vsock_override rewrites uds_path to the CALLING jail's own
/vsock.sock, which is why concurrent restores in rung C (Task 7) need no
additional socket-naming scheme: chroot already gives every jail its own
filesystem namespace.

Both functions return their vsock uds path via a global (VM_UDS), never via
`echo` captured through $(...): command substitution forks a subshell, and
CLEANUP_PID/CLEANUP_JAIL (set inside the call, a few lines up) would never
propagate back out of it to the caller - teardown_jail would then be handed
an empty pid, failing to kill the VM while still rm -rf-ing the jail out from
under it. Every caller (rung A here; rungs B/C/D in later tasks) calls these
as plain statements for exactly this reason.

Rung A: fresh boot, run the two-witness probe, teardown. This is the control -
if it fails, the failure is our plumbing, not Firecracker's restore mechanism,
because no restore has happened yet.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 6: Rung B — restore once, then connect (the actual question)

The rung the whole issue is about: does the guest-initiated second port survive a single restore.

**Files:**

- Modify: `deploy/microvm/e12-vsock-egress-probe.sh` (insert above `# --- entrypoint ---`)
- Modify: `deploy/microvm/tests/e12-vsock-egress-probe.test.sh` (append)

**Interfaces:**

- Consumes: `restore_vm` (called as a plain statement, never via `$(...)` — it sets `VM_UDS`/`CLEANUP_PID`/`CLEANUP_JAIL` directly, which a command-substitution subshell would swallow), `run_probe_once`, `teardown_jail`, `JAIL_BASE` from Tasks 2-5.
- Produces: `run_rung_b()`, called from `main` (wired in Task 8).

- [ ] **Step 1: Append the failing test section**

Append to `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`, just above the final `echo` / `if [ "$fails" -ne 0 ]` block:

```bash
echo "== run_rung_b restores (not fresh-boots), runs the probe, and tears down"
rb_body="$(extract_fn run_rung_b || true)"
check "run_rung_b exists" "$([ -n "$rb_body" ] && echo yes || echo no)" "yes"
check "run_rung_b calls restore_vm" \
  "$([ "$(echo "$rb_body" | grep -c 'restore_vm')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_b does NOT call boot_fresh_vm" \
  "$(echo "$rb_body" | grep -c 'boot_fresh_vm')" "0"
check "run_rung_b calls run_probe_once" \
  "$([ "$(echo "$rb_body" | grep -c 'run_probe_once')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_b labels its record rung-B" \
  "$([ "$(echo "$rb_body" | grep -c 'rung-B')" -ge 1 ] && echo yes || echo no)" "yes"
```

- [ ] **Step 2: Run the test to verify the new section fails**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t6-red.log" 2>&1; echo "EXIT:$?"
grep -A1 "run_rung_b restores" "$LOG_DIR/t6-red.log"
```

Expected: `FAIL: run_rung_b exists`.

- [ ] **Step 3: Insert rung B**

Insert above `# --- entrypoint ---`:

```bash
# --- rung B: restore once, then connect (the actual question) ----------------
run_rung_b() {
  local jail="$JAIL_BASE/rung-b"
  rm -rf "$jail"
  # Plain statement, not $(...) - see Task 5's comment on why (the function
  # this calls sets globals a subshell would otherwise swallow).
  restore_vm "$jail" || die "rung-B: restore_vm failed"
  local ok=0
  run_probe_once "$jail" "$VM_UDS" "rung-B" || ok=1
  teardown_jail "$jail" "$CLEANUP_PID"
  return "$ok"
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t6-green.log" 2>&1; echo "EXIT:$?"
tail -5 "$LOG_DIR/t6-green.log"
```

Expected: `EXIT:0`, `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh
git commit -s -F - <<'MSG'
feat(microvm): E12 rung B - restore once, then connect

The rung issue #271 is actually about. Restores the golden snapshot into a
fresh jail with vsock_override, runs the two-witness probe on port 1025, tears
down. Reuses restore_vm and run_probe_once from Tasks 4-5 unchanged - rung B is
mechanically just "rung A's probe against a restored VM instead of a fresh
one", which is deliberate: any difference in outcome between A and B is then
attributable to the restore itself, not to a different probe path.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 7: Rung C — N concurrent restores from one snapshot (8, then 128)

Catches per-restore collisions and confirms `vsock_override`'s jail-relative rewrite behaves correctly at the ladder top. Concurrent, not sequential (per the design decision): all N microVMs are restored and alive at once, all connecting on 1025, before any is torn down.

**Files:**

- Modify: `deploy/microvm/e12-vsock-egress-probe.sh` (insert above `# --- entrypoint ---`)
- Modify: `deploy/microvm/tests/e12-vsock-egress-probe.test.sh` (append)

**Interfaces:**

- Consumes: `restore_vm` (called as a plain statement, or with only a plain `2>` redirect — never via `$(...)`, per Task 5's VM_UDS/CLEANUP_PID comment), `run_probe_once`, `teardown_jail`, `write_json_record`, `C_LADDER`, `JAIL_BASE`, `RESULTS` from Tasks 2-6.
- Produces: `run_rung_c_n(n)` — restores `n` VMs concurrently, waits for all, aggregates. `run_rung_c()` — loops `run_rung_c_n` over `C_LADDER` ("8 128"), called from `main` (wired in Task 8).

- [ ] **Step 1: Append the failing test section**

Append to `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`, just above the final `echo` / `if [ "$fails" -ne 0 ]` block:

```bash
echo "== run_rung_c_n launches N concurrently (background jobs), not sequentially"
rcn_body="$(extract_fn run_rung_c_n || true)"
check "run_rung_c_n exists" "$([ -n "$rcn_body" ] && echo yes || echo no)" "yes"
check "run_rung_c_n backgrounds its per-VM work (uses &)" \
  "$([ "$(echo "$rcn_body" | grep -c ' &$')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_c_n waits for all before aggregating" \
  "$([ "$(echo "$rcn_body" | grep -c '\bwait\b')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_c_n calls restore_vm (not boot_fresh_vm)" \
  "$([ "$(echo "$rcn_body" | grep -c 'restore_vm')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== run_rung_c_n aggregates per-VM ok, not just the last one"
check "sums or counts per-VM outcomes rather than reading a single exit code" \
  "$([ "$(echo "$rcn_body" | grep -cE 'ok_count|fail_count|all_ok')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== run_rung_c drives the ladder from C_LADDER, not a hardcoded 8/128"
rc_body="$(extract_fn run_rung_c || true)"
check "run_rung_c exists" "$([ -n "$rc_body" ] && echo yes || echo no)" "yes"
check "run_rung_c iterates \$C_LADDER" \
  "$([ "$(echo "$rc_body" | grep -c 'C_LADDER')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_c calls run_rung_c_n" \
  "$([ "$(echo "$rc_body" | grep -c 'run_rung_c_n')" -ge 1 ] && echo yes || echo no)" "yes"
```

- [ ] **Step 2: Run the test to verify the new section fails**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t7-red.log" 2>&1; echo "EXIT:$?"
grep -A1 "run_rung_c_n launches" "$LOG_DIR/t7-red.log"
```

Expected: `FAIL: run_rung_c_n exists`.

- [ ] **Step 3: Insert rung C**

Insert above `# --- entrypoint ---`:

```bash
# --- rung C: N concurrent restores from one snapshot --------------------------
# Concurrent, not sequential: all N microVMs are restored and alive AT THE SAME
# TIME, all connecting on 1025, before any is torn down. Sequential restarts
# would prove repeatability but could not surface a socket-naming collision -
# rung C's actual purpose - because only one jail would ever exist at a time.
# Each VM gets its own jail (its own chroot filesystem namespace), so
# restore_vm's per-jail /vsock.sock (Task 5) means there is structurally only
# one place a collision COULD show up: this function's own aggregation, if two
# VMs' witnesses were somehow cross-wired. They cannot be, by construction (two
# different absolute host paths), but the aggregation still checks nonce
# uniqueness explicitly rather than assuming it.
run_rung_c_n() {
  local n="$1" i pids=() jails=()
  for i in $(seq 1 "$n"); do
    local jail="$JAIL_BASE/rung-c-${n}-${i}"
    rm -rf "$jail"
    jails+=("$jail")
    (
      local rc=0
      # A plain redirect on a function call (2>"...") does NOT fork a
      # subshell by itself - only $(...) does - so restore_vm's
      # VM_UDS/CLEANUP_PID/CLEANUP_JAIL side effects stay visible in THIS
      # per-VM subshell's own scope below. See boot_fresh_vm's comment
      # (Task 5) for why $(...) would have broken that.
      restore_vm "$jail" 2>"$jail.boot.log" || {
        write_json_record "$RESULTS/rung-C-${n}-${i}.json" \
          "{\"rung\":\"rung-C-${n}-${i}\",\"ok\":false,\"error\":\"restore_vm failed\"}"
        exit 1
      }
      run_probe_once "$jail" "$VM_UDS" "rung-C-${n}-${i}" || rc=1
      teardown_jail "$jail" "$CLEANUP_PID"
      exit "$rc"
    ) &
    pids+=("$!")
  done

  local ok_count=0 fail_count=0 pid
  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      ok_count=$((ok_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done

  # Explicit collision check: every per-VM record's nonce must be unique. A
  # duplicate would mean two VMs somehow generated (or worse, witnessed) the
  # same nonce, which is the concrete shape "a per-restore collision" would take.
  local nonces dup_count
  nonces="$(python3 -c '
import json, sys, glob
ns = []
for p in sys.argv[1:]:
    try:
        with open(p) as f:
            ns.append(json.load(f).get("nonce", ""))
    except Exception:
        pass
print("\n".join(ns))
' "$RESULTS"/rung-C-"${n}"-*.json 2>/dev/null)"
  dup_count=$(printf '%s\n' "$nonces" | sort | uniq -d | grep -c . || true)

  local all_ok=false
  [ "$fail_count" -eq 0 ] && [ "$dup_count" -eq 0 ] && all_ok=true

  write_json_record "$RESULTS/rung-C-${n}.json" \
    "$(printf '{"rung":"rung-C-%s","n":%s,"ok":%s,"ok_count":%s,"fail_count":%s,"nonce_collisions":%s}' \
      "$n" "$n" "$all_ok" "$ok_count" "$fail_count" "$dup_count")"

  log "rung-C(n=$n): ok_count=$ok_count fail_count=$fail_count nonce_collisions=$dup_count all_ok=$all_ok"
  [ "$all_ok" = true ]
}

run_rung_c() {
  local n overall=0
  for n in $C_LADDER; do
    run_rung_c_n "$n" || overall=1
  done
  return "$overall"
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t7-green.log" 2>&1; echo "EXIT:$?"
tail -5 "$LOG_DIR/t7-green.log"
```

Expected: `EXIT:0`, `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh
git commit -s -F - <<'MSG'
feat(microvm): E12 rung C - N concurrent restores from one snapshot

Restores 8, then 128, microVMs CONCURRENTLY from the golden snapshot - all
alive at once, all connecting on port 1025 - rather than sequentially, because
sequential restarts cannot surface a socket-naming collision (only one jail
would ever exist at a time) and that is rung C's actual purpose per issue #271.

Each VM gets its own jail, so restore_vm's per-jail vsock_override rewrite
(Task 5) means a collision has structurally nowhere to happen except in this
function's own aggregation - checked explicitly via a nonce-uniqueness pass
across all N per-VM records, rather than assumed.

128 concurrent microVMs at 256 MiB each is within what this same nested-m8i rig
already ran for E11's density ladder (Sigma PSS <= 0.41 GB there), so N=128 is
not new capacity risk, only new plumbing.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 8: Rung D (regression fence), main wiring, and the boolean answer

Rung D confirms adding the 1025 listener does not break the mechanism P4 already ships on (host-initiated Exec over vsock:1024). Then `main` is rewritten from Task 2's placeholder into real dispatch: run every requested rung, aggregate, print the one-line boolean answer, and verify the snapshot digest one final time.

**Files:**

- Modify: `deploy/microvm/e12-vsock-egress-probe.sh` (insert `run_rung_d` above `# --- entrypoint ---`; replace the `main` body inside that block)
- Modify: `deploy/microvm/tests/e12-vsock-egress-probe.test.sh` (append)

**Interfaces:**

- Consumes: `restore_vm` (called as a plain statement, never via `$(...)`, per Task 5's VM_UDS/CLEANUP_PID comment), `start_host_listener`, `stop_host_listener`, `teardown_jail`, `write_json_record`, `wants_rung`, `run_rung_a/b/c` from Tasks 2-7.
- Produces: `run_rung_d()`. Rewritten `main()` — still guarded by `E12_PROBE_SOURCE_ONLY`, still calls `preflight` and `assert_snapshot_pristine ... before/after`, now also dispatches rungs and prints the answer.

- [ ] **Step 1: Append the failing test section**

Append to `deploy/microvm/tests/e12-vsock-egress-probe.test.sh`, just above the final `echo` / `if [ "$fails" -ne 0 ]` block:

```bash
echo "== run_rung_d confirms port 1024 still works with 1025 present"
rd_body="$(extract_fn run_rung_d || true)"
check "run_rung_d exists" "$([ -n "$rd_body" ] && echo yes || echo no)" "yes"
check "run_rung_d starts the 1025 listener (so it is PRESENT, per the rung's own name)" \
  "$([ "$(echo "$rd_body" | grep -c 'start_host_listener')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_d exercises port \$AGENT_PORT directly (not via run_probe_once)" \
  "$([ "$(echo "$rd_body" | grep -c 'AGENT_PORT')" -ge 1 ] && echo yes || echo no)" "yes"
check "run_rung_d labels its record rung-D" \
  "$([ "$(echo "$rd_body" | grep -c 'rung-D')" -ge 1 ] && echo yes || echo no)" "yes"

echo "== main dispatches every requested rung and prints exactly one boolean answer line"
main_body="$(extract_fn main || true)"
check "main checks wants_rung A" "$([ "$(echo "$main_body" | grep -c "wants_rung A")" -ge 1 ] && echo yes || echo no)" "yes"
check "main checks wants_rung B" "$([ "$(echo "$main_body" | grep -c "wants_rung B")" -ge 1 ] && echo yes || echo no)" "yes"
check "main checks wants_rung C" "$([ "$(echo "$main_body" | grep -c "wants_rung C")" -ge 1 ] && echo yes || echo no)" "yes"
check "main checks wants_rung D" "$([ "$(echo "$main_body" | grep -c "wants_rung D")" -ge 1 ] && echo yes || echo no)" "yes"
check "main prints an E12 ANSWER line" \
  "$([ "$(echo "$main_body" | grep -c 'E12 ANSWER')" -ge 1 ] && echo yes || echo no)" "yes"
check "main still verifies the snapshot pristine before AND after" \
  "$([ "$(echo "$main_body" | grep -c 'assert_snapshot_pristine')" -eq 2 ] && echo yes || echo no)" "yes"

echo "== still structurally incapable of a verdict, even after wiring in the rungs"
check "no STOP token (full source)" "$(grep -c '\bSTOP\b' "$SCRIPT")" "0"
check "no MANDATORY token (full source)" "$(grep -c '\bMANDATORY\b' "$SCRIPT")" "0"
```

- [ ] **Step 2: Run the test to verify the new section fails**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t8-red.log" 2>&1; echo "EXIT:$?"
grep -A1 "run_rung_d confirms" "$LOG_DIR/t8-red.log"
```

Expected: `FAIL: run_rung_d exists`.

- [ ] **Step 3: Insert rung D above `# --- entrypoint ---`**

```bash
# --- rung D: host-initiated 1024 still works with 1025 present (regression fence) --
# The worst outcome the issue names: adding a second port breaks the mechanism
# P4 already ships on. This does NOT reuse run_probe_once (that exercises
# GUEST-initiated 1025) - it exercises the EXISTING host-initiated Exec path on
# 1024 directly, with the 1025 listener present but unused by this rung, so a
# regression here is unambiguously about interference from the second port.
run_rung_d() {
  local jail="$JAIL_BASE/rung-d"
  rm -rf "$jail"
  # Plain statement, not $(...) - see Task 5's comment on why (the function
  # this calls sets globals a subshell would otherwise swallow).
  restore_vm "$jail" || die "rung-D: restore_vm failed"

  local listener_out lpid
  listener_out="$(start_host_listener "$jail" "rung-d-unused")"
  lpid="${listener_out#pid:}"; lpid="${lpid%% capture:*}"

  local exit_code=0
  "$GUEST_CLIENT" -uds "$VM_UDS" -port "$AGENT_PORT" -timeout-s 15 -command true >/dev/null 2>&1 ||
    exit_code=$?

  stop_host_listener "$lpid"
  teardown_jail "$jail" "$CLEANUP_PID"

  local ok=false
  [ "$exit_code" -eq 0 ] && ok=true
  write_json_record "$RESULTS/rung-D.json" \
    "$(printf '{"rung":"rung-D","ok":%s,"guest_client_exit":%s}' "$ok" "$exit_code")"
  log "rung-D: host-initiated 1024 with 1025 present -> exit=$exit_code ok=$ok"
  [ "$ok" = true ]
}
```

- [ ] **Step 4: Replace the placeholder `main` from Task 2 Step 4**

Find the block inserted in Task 2 Step 4 (`main() { preflight; assert_snapshot_pristine ... before; assert_snapshot_pristine ... after; }`) and replace its body:

```bash
# --- entrypoint ----------------------------------------------------------------
main() {
  preflight
  assert_snapshot_pristine "$SNAPSHOT_DIR" before

  local overall_ok=true
  wants_rung A && { run_rung_a || overall_ok=false; }
  wants_rung B && { run_rung_b || overall_ok=false; }
  wants_rung C && { run_rung_c || overall_ok=false; }
  wants_rung D && { run_rung_d || overall_ok=false; }

  assert_snapshot_pristine "$SNAPSHOT_DIR" after

  write_json_record "$RESULTS/e12-answer.json" \
    "$(printf '{"substrate":%s,"rungs_run":%s,"ok":%s}' \
      "$(json_escape "$SUBSTRATE")" "$(json_escape "$RUNGS")" "$overall_ok")"

  if [ "$overall_ok" = true ]; then
    log "E12 ANSWER: guest-initiated vsock on a second port SURVIVES restore (rungs: $RUNGS, substrate: $SUBSTRATE)"
  else
    log "E12 ANSWER: guest-initiated vsock on a second port DOES NOT SURVIVE restore (rungs: $RUNGS, substrate: $SUBSTRATE) - see $RESULTS for the failing rung's record"
  fi
  [ "$overall_ok" = true ]
}

# e10-lifecycle.sh uses the same escape hatch, for the same reason: the tests
# need to source ONE function without main() immediately demanding /dev/kvm.
if [ "${E12_PROBE_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t8-green.log" 2>&1; echo "EXIT:$?"
tail -5 "$LOG_DIR/t8-green.log"
```

Expected: `EXIT:0`, `all checks passed`.

- [ ] **Step 6: Run the full contract test file one more time end to end, plus shellcheck and Prettier**

```bash
bash deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t8-full.log" 2>&1; echo "EXIT:$?"
shellcheck -x -S warning deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t8-shellcheck.log" 2>&1; echo "SHELLCHECK_EXIT:$?"
cat "$LOG_DIR/t8-shellcheck.log"
pre-commit run --files deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh > "$LOG_DIR/t8-precommit.log" 2>&1; echo "PRECOMMIT_EXIT:$?"
cat "$LOG_DIR/t8-precommit.log"
```

Expected: all three exit 0. Fix anything shellcheck or the Prettier hook flags before moving on — do not defer formatting issues to a later task.

- [ ] **Step 7: Commit**

```bash
git add deploy/microvm/e12-vsock-egress-probe.sh deploy/microvm/tests/e12-vsock-egress-probe.test.sh
git commit -s -F - <<'MSG'
feat(microvm): E12 rung D (regression fence) and full rung dispatch in main

Rung D restores a VM, starts the 1025 listener so it is PRESENT, and exercises
the EXISTING host-initiated Exec path on 1024 directly (not via
run_probe_once, which drives 1025) - so a failure here is unambiguously about
the second port interfering with the mechanism P4 already ships on, which
issue #271 names as the worst possible outcome.

main() now dispatches every rung named in $RUNGS (default "A B C D"), verifies
the snapshot digest before AND after the full set (not just per-rung), and
prints exactly one "E12 ANSWER:" line - the boolean this whole driver exists to
produce. Still no STOP/MANDATORY anywhere in the source, checked against the
FULL file now that every rung is wired in, not just the Task 2 skeleton.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 9: Guest client binary (committed Go package, builds without KVM)

`build-snapshot.sh` generates `guest_client.go` into a throwaway temp package at run time (its `write_guest_client`, so its own module-internal import of `internal/guestagent` is legal). E12 needs the exact same binary but is not `build-snapshot.sh` — rather than shelling out to that function (which would reach across scripts and reintroduce the coupling Task 2's header explicitly avoids), this task commits the client as its own small `cmd` package, matching how `cmd/vmpoolctl` already sits alongside the library it drives. It builds and `go vet`s with no KVM and no snapshot — pure Go.

**Files:**

- Create: `remote-worker/cmd/e12-guest-client/main.go`

**Interfaces:**

- Consumes: `remote-worker/internal/guestagent` (`ga.Request`, `ga.WriteJSON`, `ga.WriteFrame`, `ga.ReadFrame`, `ga.KindRequest`, `ga.KindStdinEOF`, `ga.KindStdout`, `ga.KindStderr`, `ga.KindEnd`, `ga.KindError`, `ga.End`, `ga.MaxFrame`) — already exported and used identically by `build-snapshot.sh`'s own copy and by `cmd/vmpoolctl`.
- Produces: the `guest_client` binary Task 10's rig run points `SH_GUEST_CLIENT` at.

- [ ] **Step 1: Write the package**

Create `remote-worker/cmd/e12-guest-client/main.go`. This is the same framed-protocol client `build-snapshot.sh` generates at build time (comment updated to describe E12's use rather than build-snapshot.sh's):

```go
// Command e12-guest-client is a build-time helper for deploy/microvm/e12-vsock-egress-probe.sh.
// It speaks the same framed protocol internal/vmpool/guestconn.go speaks at serve
// time, but from a throwaway process instead of the pool - E12's driver has no pool,
// the same reason deploy/microvm/build-snapshot.sh generates its own copy
// (guest_client.go, written at run time into a temp package) rather than importing
// this one. That script's copy and this one are intentionally the same shape; this
// one exists as a committed, directly buildable package because E12's driver is not
// build-snapshot.sh and reaching into its temp-package generator would recreate
// exactly the cross-script coupling deploy/microvm/e12-vsock-egress-probe.sh's own
// header comment says to avoid.
//
// Firecracker's and Cloud Hypervisor's Unix-socket vsock backends both proxy a host
// connection into the guest's listener on a fixed port via a one-line handshake: the
// host writes "CONNECT <port>\n" on the VMM-created Unix socket and, once the guest
// has accept()ed, the socket becomes a raw duplex stream to the guest side.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	ga "github.com/kagenti/serverless-harness/remote-worker/internal/guestagent"
)

func main() {
	uds := flag.String("uds", "", "path to the VMM's vsock unix socket")
	port := flag.Uint("port", 1024, "guest vsock port the agent listens on")
	command := flag.String("command", "", "command to run in the guest; empty means probe-only")
	timeoutS := flag.Uint("timeout-s", 30, "guest-side command timeout")
	probeOnly := flag.Bool("probe-only", false, "just prove the guest is accepting; run nothing")
	dialTimeout := flag.Duration("dial-timeout", 10*time.Second, "how long to wait for the CONNECT handshake")
	flag.Parse()

	if *uds == "" {
		fmt.Fprintln(os.Stderr, "e12-guest-client: -uds is required")
		os.Exit(2)
	}

	conn, err := dialGuest(*uds, uint32(*port), *dialTimeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "e12-guest-client: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	if *probeOnly {
		return
	}

	req := ga.Request{Command: *command, TimeoutS: uint32(*timeoutS), CapBytes: ga.MaxFrame, HostUnixNanos: time.Now().UnixNano()}
	if err := ga.WriteJSON(conn, ga.KindRequest, req); err != nil {
		fmt.Fprintf(os.Stderr, "e12-guest-client: send request: %v\n", err)
		os.Exit(1)
	}
	if err := ga.WriteFrame(conn, ga.KindStdinEOF, nil); err != nil {
		fmt.Fprintf(os.Stderr, "e12-guest-client: send stdin-eof: %v\n", err)
		os.Exit(1)
	}

	for {
		kind, payload, err := ga.ReadFrame(conn)
		if err != nil {
			fmt.Fprintf(os.Stderr, "e12-guest-client: read: %v\n", err)
			os.Exit(1)
		}
		switch kind {
		case ga.KindStdout:
			os.Stdout.Write(payload)
		case ga.KindStderr:
			os.Stderr.Write(payload)
		case ga.KindEnd:
			var e ga.End
			if err := json.Unmarshal(payload, &e); err != nil {
				fmt.Fprintf(os.Stderr, "e12-guest-client: undecodable End: %v\n", err)
				os.Exit(1)
			}
			os.Exit(int(e.ExitCode))
		case ga.KindError:
			fmt.Fprintf(os.Stderr, "e12-guest-client: guest error: %s\n", payload)
			os.Exit(1)
		}
	}
}

// dialGuest performs the VMM's vsock Unix-socket CONNECT handshake and returns the
// resulting duplex connection. Copied unchanged from build-snapshot.sh's own
// guest_client.go, INCLUDING its readLine helper below - not simplified to a bulk
// conn.Read(buf), because a bulk read can consume bytes belonging to the guest
// agent's OWN first protocol frame if it answers fast enough to already be in
// flight right behind the ack. remote-worker/internal/vmpool/vsock.go's dialVsock
// hits this exact race and wraps its connection in a handshakeConn to replay any
// over-read bytes; build-snapshot.sh instead reads the ack strictly byte-by-byte so
// there is nothing to over-read in the first place. This file follows that second,
// simpler approach - never re-simplify readLine back into a bulk conn.Read, and
// never drop the read deadline around it (an ack that never arrives would
// otherwise hang this client forever despite -dial-timeout implying it can't).
func dialGuest(uds string, port uint32, timeout time.Duration) (net.Conn, error) {
	d := net.Dialer{Timeout: timeout}
	conn, err := d.Dial("unix", uds)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", uds, err)
	}
	if _, err := fmt.Fprintf(conn, "CONNECT %d\n", port); err != nil {
		conn.Close()
		return nil, fmt.Errorf("send CONNECT: %w", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	line, err := readLine(conn)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("read CONNECT ack: %w", err)
	}
	if !strings.HasPrefix(line, "OK") {
		conn.Close()
		return nil, fmt.Errorf("CONNECT %d refused: %q", port, line)
	}
	_ = conn.SetReadDeadline(time.Time{})
	return conn, nil
}

// readLine reads byte-by-byte until '\n' - copied unchanged from
// build-snapshot.sh's own helper of the same name. Deliberately NOT a
// bufio.Reader or a bulk conn.Read: either can read past the '\n' into the
// guest agent's own first protocol frame, and this connection is handed
// straight to ga.ReadFrame afterward with no mechanism to replay over-read
// bytes (unlike remote-worker/internal/vmpool/vsock.go's handshakeConn, which
// exists specifically to solve that problem for a different caller). Slow by
// design, on a handshake line of a few bytes this cost is immaterial.
func readLine(conn net.Conn) (string, error) {
	buf := make([]byte, 0, 64)
	one := make([]byte, 1)
	for {
		if _, err := conn.Read(one); err != nil {
			return "", err
		}
		if one[0] == '\n' {
			return string(buf), nil
		}
		buf = append(buf, one[0])
	}
}
```

- [ ] **Step 2: Build it**

```bash
cd remote-worker
go build -o /tmp/e12-guest-client ./cmd/e12-guest-client/ > "$LOG_DIR/t9-build.log" 2>&1; echo "EXIT:$?"
cd -
```

Expected: `EXIT:0`. If `GOTOOLCHAIN=auto` needs to fetch `go1.26.0` and there is no network here, this step fails locally with a toolchain-download error — that is expected to succeed on the rig (Task 10), which has verified `proxy.golang.org` access; do not treat a local network-only failure as a code problem.

- [ ] **Step 3: `go vet` it**

```bash
cd remote-worker
go vet ./cmd/e12-guest-client/... > "$LOG_DIR/t9-vet.log" 2>&1; echo "EXIT:$?"
cd -
cat "$LOG_DIR/t9-vet.log"
```

Expected: `EXIT:0`, empty output.

- [ ] **Step 4: Confirm the rest of the module still builds (no accidental collision with `cmd/vmpoolctl` or `internal/guestagent`)**

```bash
cd remote-worker
go build ./... > "$LOG_DIR/t9-build-all.log" 2>&1; echo "EXIT:$?"
cd -
tail -20 "$LOG_DIR/t9-build-all.log"
```

Expected: `EXIT:0`.

- [ ] **Step 5: Commit**

```bash
git add remote-worker/cmd/e12-guest-client/main.go
git commit -s -F - <<'MSG'
feat(microvm): commit E12's guest_client as its own cmd package

deploy/microvm/build-snapshot.sh generates its own guest_client.go into a
throwaway temp package at run time, which is fine for a script that already
owns the whole build pipeline. e12-vsock-egress-probe.sh is not that script,
and reaching into build-snapshot.sh's private write_guest_client to reuse its
output would recreate exactly the cross-script coupling that script's own test
(build-snapshot.test.sh, which greps write_guest_client's body for statement
ordering) makes expensive to touch.

So this commits the same client - identical framed-protocol/CONNECT-handshake
logic - as its own buildable cmd package, the same way cmd/vmpoolctl already
sits alongside the library it drives. Builds and go vets with no KVM and no
snapshot required.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 10: Run on the rig — incrementally, then the full four-rung set

Everything up to here builds and tests without KVM. This task is the first one that needs the rig. Runs each rung alone first (per the issue's own guidance: "Fail at A -> our plumbing, fix and retry; the interesting question is untouched"), so a plumbing bug is caught cheaply before N=128 is attempted, then runs the full set for the authoritative record.

**Files:** none (this task produces run artifacts under `$SH_E12_RESULTS` on the rig, pulled back into the local repo checkout at `deploy/microvm/e12-results/` for Task 11 — not committed as source, committed as evidence).

**Interfaces:**

- Consumes: the driver and `guest_client` package from Tasks 2-9.
- Produces: `deploy/microvm/e12-results/*.json` (one file per rung record plus `e12-answer.json`), `deploy/microvm/e12-results/run.log`.

- [ ] **Step 1: Ship the repo to the rig at the exact commit this plan has built so far**

```bash
K="$HOME/Projects/fc/firecracker-key.pem"
HOST="ec2-user@3.235.29.220"
git log --oneline -1  # confirm you are at the Task 9 commit before shipping
git archive HEAD | ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" \
  'rm -rf ~/e12-src && mkdir -p ~/e12-src && tar -x -C ~/e12-src' 2>&1 | tee "$LOG_DIR/t10-ship.log"
```

Expected: no tar errors. `git archive HEAD` ships exactly the tracked tree at your current commit — no `.git`, no `node_modules`, no local scratch files.

- [ ] **Step 2: Build `e12-guest-client` on the rig**

```bash
ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" '
set -e
cd ~/e12-src/remote-worker
GOTOOLCHAIN=auto go build -o ~/e12-src/deploy/microvm/guest_client ./cmd/e12-guest-client/
go version
~/e12-src/deploy/microvm/guest_client -uds /nonexistent -port 1024 -dial-timeout 100ms 2>&1 || true
' 2>&1 | tee "$LOG_DIR/t10-build.log"
```

Expected: the build succeeds (confirming fact #13's `GOTOOLCHAIN=auto` self-upgrade actually happens end to end), `go version` prints `go1.26.0` or later, and the final smoke line prints a `dial /nonexistent: ...` error (proving the binary runs and parses flags — the "file not found" failure is expected and fine here).

- [ ] **Step 3: Run rung A alone**

```bash
ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" '
set -e
cd ~/e12-src
chmod +x deploy/microvm/e12-vsock-egress-probe.sh
sudo env SH_SUBSTRATE=nested-m8i SH_GUEST_CLIENT="$PWD/deploy/microvm/guest_client" \
  SH_E12_RESULTS=/tmp/e12-results SH_E12_RUNGS=A \
  ./deploy/microvm/e12-vsock-egress-probe.sh
echo "EXIT:$?"
cat /tmp/e12-results/rung-A.json
' 2>&1 | tee "$LOG_DIR/t10-ruleA.log"
```

Expected: `EXIT:0`, and `rung-A.json` shows `"ok":true` with both `"host_witness":"yes"` and `"guest_witness":"yes"`. If this fails, per the issue's own reading of outcomes: **this indicts our plumbing, not Firecracker** — debug here before proceeding to any other rung.

- [ ] **Step 4: Run rung B alone**

```bash
ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" '
cd ~/e12-src
sudo env SH_SUBSTRATE=nested-m8i SH_GUEST_CLIENT="$PWD/deploy/microvm/guest_client" \
  SH_E12_RESULTS=/tmp/e12-results SH_E12_RUNGS=B \
  ./deploy/microvm/e12-vsock-egress-probe.sh
echo "EXIT:$?"
cat /tmp/e12-results/rung-B.json
' 2>&1 | tee "$LOG_DIR/t10-ruleB.log"
```

Expected: `EXIT:0` and `rung-B.json` shows `"ok":true`. **This is the actual answer to issue #271's question**, if A also passed.

- [ ] **Step 5: Run rung C at N=8 alone**

```bash
ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" '
cd ~/e12-src
sudo env SH_SUBSTRATE=nested-m8i SH_GUEST_CLIENT="$PWD/deploy/microvm/guest_client" \
  SH_E12_RESULTS=/tmp/e12-results SH_E12_RUNGS=C SH_E12_C_LADDER=8 \
  ./deploy/microvm/e12-vsock-egress-probe.sh
echo "EXIT:$?"
cat /tmp/e12-results/rung-C-8.json
' 2>&1 | tee "$LOG_DIR/t10-ruleC8.log"
```

Expected: `EXIT:0`, `rung-C-8.json` shows `"ok":true "ok_count":8 "fail_count":0 "nonce_collisions":0`.

- [ ] **Step 6: Run rung C at N=128**

```bash
ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" '
cd ~/e12-src
sudo env SH_SUBSTRATE=nested-m8i SH_GUEST_CLIENT="$PWD/deploy/microvm/guest_client" \
  SH_E12_RESULTS=/tmp/e12-results SH_E12_RUNGS=C SH_E12_C_LADDER=128 \
  timeout 900 ./deploy/microvm/e12-vsock-egress-probe.sh
echo "EXIT:$?"
cat /tmp/e12-results/rung-C-128.json
free -h
' 2>&1 | tee "$LOG_DIR/t10-ruleC128.log"
```

Expected: `EXIT:0` within the 15-minute budget, `rung-C-128.json` shows `"ok":true "ok_count":128 "fail_count":0 "nonce_collisions":0`. If it times out, that is itself a finding for Task 11's write-up (rung C's own record will be absent — Task 11 must say so explicitly rather than treat a timeout as a pass or a silent gap), not a driver bug to chase blindly: record what happened and move on to Step 7 with `SH_E12_RUNGS=D` regardless.

- [ ] **Step 7: Run rung D alone**

```bash
ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" '
cd ~/e12-src
sudo env SH_SUBSTRATE=nested-m8i SH_GUEST_CLIENT="$PWD/deploy/microvm/guest_client" \
  SH_E12_RESULTS=/tmp/e12-results SH_E12_RUNGS=D \
  ./deploy/microvm/e12-vsock-egress-probe.sh
echo "EXIT:$?"
cat /tmp/e12-results/rung-D.json
' 2>&1 | tee "$LOG_DIR/t10-ruleD.log"
```

Expected: `EXIT:0`, `rung-D.json` shows `"ok":true`.

- [ ] **Step 8: Run the full four-rung set for the authoritative combined record**

```bash
ssh -i "$K" -o StrictHostKeyChecking=no "$HOST" '
cd ~/e12-src
rm -rf /tmp/e12-results && mkdir -p /tmp/e12-results
sudo env SH_SUBSTRATE=nested-m8i SH_GUEST_CLIENT="$PWD/deploy/microvm/guest_client" \
  SH_E12_RESULTS=/tmp/e12-results \
  timeout 1800 ./deploy/microvm/e12-vsock-egress-probe.sh
echo "EXIT:$?"
' 2>&1 | tee "$LOG_DIR/t10-full.log"
grep "E12 ANSWER" "$LOG_DIR/t10-full.log"
```

Expected: `EXIT:0`, and exactly one `E12 ANSWER:` line, printed once by `main`.

- [ ] **Step 9: Pull the results back into the repo checkout**

```bash
mkdir -p deploy/microvm/e12-results
scp -i "$K" -o StrictHostKeyChecking=no "$HOST:/tmp/e12-results/*.json" deploy/microvm/e12-results/
cp "$LOG_DIR/t10-full.log" deploy/microvm/e12-results/run.log
ls deploy/microvm/e12-results/
python3 -c "import json; print(json.load(open('deploy/microvm/e12-results/e12-answer.json')))"
```

Expected: `e12-answer.json`, `rung-A.json`, `rung-B.json`, `rung-C-8.json`, `rung-C-128.json` (or its absence if Step 6 timed out — noted, not faked), `rung-D.json`, and the per-VM `rung-C-<n>-<i>.json` files all present.

- [ ] **Step 10: Commit the results as evidence**

```bash
git add deploy/microvm/e12-results/
git commit -s -F - <<'MSG'
docs(microvm): E12 run records from nested-m8i

Per-rung and per-VM JSON records plus the combined run log from the rig at
3.235.29.220 (SH_SUBSTRATE=nested-m8i). Task 11 reads these into
EXPERIMENTS.md's E12 section rather than re-describing them from memory.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

---

### Task 11: EXPERIMENTS.md write-up and PR

Writes the E12 section from the **actual** `deploy/microvm/e12-results/*.json` files committed in Task 10 — never from memory of what "should" happen. The two templates below cover both possible answers; use whichever one `e12-answer.json`'s `"ok"` field actually says, filling every bracketed value from the real JSON files, not from this plan.

**Files:**

- Modify: `deploy/microvm/EXPERIMENTS.md` (append after the `## Performance rungs` section, i.e. after E11's "Open items carried into the metal run" subsection)

**Interfaces:**

- Consumes: `deploy/microvm/e12-results/*.json` from Task 10.
- Produces: nothing further consumes this — it is the terminal deliverable.

- [ ] **Step 1: Read every result file and extract the values you need**

```bash
python3 -c "
import json, glob
for p in sorted(glob.glob('deploy/microvm/e12-results/*.json')):
    print(p, json.load(open(p)))
"
```

Write down: the overall `ok` from `e12-answer.json`; each of rung A/B/D's `ok`, `host_witness`, `guest_witness`; rung C's `ok_count`/`fail_count`/`nonce_collisions` at both N=8 and N=128 (or a note that N=128 did not complete, per Task 10 Step 6's contingency); and whether Task 10 Step 6 timed out.

- [ ] **Step 2a: If `e12-answer.json`'s `ok` is `true` — append this section**

```markdown
### E12 — guest-initiated vsock on a second port survives snapshot restore

**Answer: yes.** A guest-initiated vsock connection on a second port (1025)
survives Firecracker snapshot restore, and survives [N] concurrent restores of
one snapshot, on `nested-m8i`.

#### What was actually tested

Four rungs, each requiring TWO INDEPENDENT witnesses per connection — the
nonce captured host-side on `<jail>/vsock.sock_1025`, AND the ACK read back in
guest stdout via the existing agent Exec path on vsock:1024. Neither witness
alone was treated as evidence.

| Rung                                      | What                                                         | Result     |
| ----------------------------------------- | ------------------------------------------------------------ | ---------- |
| A (control, fresh boot)                   | [host_witness]/[guest_witness]                               | ok=[value] |
| B (restore once)                          | [host_witness]/[guest_witness]                               | ok=[value] |
| C (N=8 concurrent restores)               | ok_count=[value] fail_count=[value] nonce_collisions=[value] | ok=[value] |
| C (N=128 concurrent restores)             | ok_count=[value] fail_count=[value] nonce_collisions=[value] | ok=[value] |
| D (host-initiated 1024 with 1025 present) | guest_client_exit=[value]                                    | ok=[value] |

Full per-rung and per-VM records: `deploy/microvm/e12-results/`.

#### What a nested run establishes here, and what it does not

This ran on `nested-m8i`, never `metal`. Per this driver's design (Task 2), no
substrate name check gates that choice — the golden snapshot's rootfs digest
was verified against `manifest.json` before AND after the entire run
(`deploy/microvm/e12-results/e12-answer.json`'s presence, plus the absence of
any `die` in `deploy/microvm/e12-results/run.log`, is the evidence for this),
so nothing this run did could have written to the snapshot regardless of which
rig it ran on.

What this DOES establish: the guest-initiated vsock mechanism — pre-created
host listener on `<uds>_<PORT>`, no handshake, `vsock_override` rewriting
`uds_path` per restore — works as `vsock.md` documents, on real KVM hardware
virtualized one level down, across a real snapshot restore.

What this does NOT establish on its own: Firecracker's snapshot/restore
contract requires identical hardware between snapshot and restore. A nested
pass makes the metal case very likely but does not prove it. Per issue #271,
metal confirmation should ride along with whichever later run builds a metal
snapshot anyway — not worth booking metal time for on its own. Because this
driver's snapshot-integrity guard (Task 2) is unconditional rather than a
substrate name check, running it again on that later metal snapshot needs no
code change.

#### Prediction (spec-style, pinned in `predictions.json` id 6)

> Guest-initiated vsock on a second port (1025) works on a fresh boot and
> survives snapshot restore, for all N concurrent restores of one snapshot,
> because the guest-to-host direction needs no handshake and no host-side
> state beyond the socket file - strictly less state to reset than the
> host-initiated direction already known to survive.

**Not falsified.** Rungs B, C and D all reported `ok=true` while rung A also
reported `ok=true` — the falsifier ("any rung B, C or D reporting ok=false
while rung A reported ok=true") did not fire.

#### Effect on PR #268

P4.1's decision T1 (route all sandbox egress over vsock) stands. Implementation
of P4.1 can proceed on the assumption this probe was gating.
```

- [ ] **Step 2b: If `e12-answer.json`'s `ok` is `false` — append this section instead**

```markdown
### E12 — guest-initiated vsock on a second port survives snapshot restore

**Answer: no** (as observed on `nested-m8i` — see the specific failing rung
below before generalizing this to "the mechanism does not work").

#### What was actually tested, and where it broke

| Rung                                      | What                                                         | Result     |
| ----------------------------------------- | ------------------------------------------------------------ | ---------- |
| A (control, fresh boot)                   | [host_witness]/[guest_witness]                               | ok=[value] |
| B (restore once)                          | [host_witness]/[guest_witness]                               | ok=[value] |
| C (N=8 concurrent restores)               | ok_count=[value] fail_count=[value] nonce_collisions=[value] | ok=[value] |
| C (N=128 concurrent restores)             | ok_count=[value] fail_count=[value] nonce_collisions=[value] | ok=[value] |
| D (host-initiated 1024 with 1025 present) | guest_client_exit=[value]                                    | ok=[value] |

Full per-rung and per-VM records: `deploy/microvm/e12-results/`.

**Read this against issue #271's own outcome table before drawing a
conclusion:**

- **If rung A failed:** this indicts our plumbing or socket naming, not
  Firecracker's restore mechanism — the interesting question (does the
  mechanism survive restore) is UNTESTED, not answered "no". [Describe the
  specific host_witness/guest_witness mismatch from rung-A.json here, and
  what it implies about the probe's own wiring.]
- **If rung B or C failed while rung A passed:** T1 is dead. PR #268 reverts
  to the NIC option (its spec §2), and its §5 shared-proxy/Z1 reasoning has
  to be redone against a per-clone netns topology. [Quote the specific
  failure: was the host witness missing, the guest witness missing, or both?
  That distinguishes "Firecracker never delivered VIRTIO_VSOCK_OP_REQUEST
  after restore" from "our listener was not present when the guest tried".]
- **If rung D failed:** adding the second port broke the mechanism PR #268
  already depends on being merged. This is the worst outcome named in issue
  #271 and blocks more than PR #268 — [describe what guest_client_exit was
  and what changed relative to a pre-1025 baseline].
- **If Task 10 Step 6 (N=128) timed out without a rung-C-128.json:** record
  that explicitly here as "not completed" — never as a pass, and never
  folded silently into the N=8 result.

#### Prediction (spec-style, pinned in `predictions.json` id 6)

> Guest-initiated vsock on a second port (1025) works on a fresh boot and
> survives snapshot restore, for all N concurrent restores of one snapshot,
> because the guest-to-host direction needs no handshake and no host-side
> state beyond the socket file - strictly less state to reset than the
> host-initiated direction already known to survive.

**Falsified.** [Name the exact rung(s) that reported `ok=false` while rung A
reported `ok=true` — that is the falsifier from `predictions.json` id 6
firing.]

#### Effect on PR #268

[If B or C falsified the prediction:] T1 is dead. PR #268's decision T1
(route all sandbox egress over vsock) cannot stand as written; it reverts to
the NIC option (spec §2), and its §5 shared-proxy/Z1 reasoning needs to be
redone against a per-clone netns topology. [If A failed instead:] the
question remains open; re-run after fixing the plumbing issue identified
above before drawing any conclusion about PR #268.
```

- [ ] **Step 3: Run the deploy-scripts test target once more to confirm nothing broke while writing docs**

```bash
make test-deploy > "$LOG_DIR/t11-test-deploy.log" 2>&1; echo "EXIT:$?"
tail -20 "$LOG_DIR/t11-test-deploy.log"
```

Expected: `EXIT:0`.

- [ ] **Step 4: Run the full local (non-KVM) suite one final time**

```bash
./node_modules/.bin/vitest run experiments/test/ > "$LOG_DIR/t11-vitest.log" 2>&1; echo "EXIT:$?"
cd remote-worker && go build ./... > "$LOG_DIR/t11-go-build.log" 2>&1; echo "EXIT:$?"; go vet ./... > "$LOG_DIR/t11-go-vet.log" 2>&1; echo "EXIT:$?"; cd -
```

Expected: all `EXIT:0`.

- [ ] **Step 5: Commit the EXPERIMENTS.md update**

```bash
git add deploy/microvm/EXPERIMENTS.md
git commit -s -F - <<'MSG'
docs(microvm): E12 write-up - guest-initiated vsock on a second port

Records the answer issue #271 asked for, built from the actual run records in
deploy/microvm/e12-results/ (Task 10) rather than from expectation. States
what a nested-m8i run can and cannot establish about the metal case, and scores
predictions.json's id 6 against the falsifier it was sealed with before rung A
ran (Task 1).

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>
MSG
```

- [ ] **Step 6: Push the branch and open the PR**

```bash
git push -u origin feat/e12-vsock-egress-probe 2>&1 | tee "$LOG_DIR/t11-push.log"
gh pr create --repo rossoctl/serverless-harness \
  --title "E12: guest-initiated vsock on a second port across snapshot restore (#271)" \
  --body "$(cat <<'PRBODY'
Closes #271.

Answers one boolean: does a guest-initiated vsock connection on a second port
(1025) survive Firecracker snapshot restore, and survive N concurrent restores
of one snapshot? See `deploy/microvm/EXPERIMENTS.md`'s new E12 section for the
answer and `deploy/microvm/e12-results/` for the underlying run records from
`nested-m8i`.

No snapshot rebuild was needed — the golden rootfs already had python3 with
working AF_VSOCK (confirmed by chroot-testing it before writing any code).
`deploy/microvm/build-snapshot.sh` was not touched or refactored.

Gates PR #268's decision T1. See the EXPERIMENTS.md section for what this
means for that PR depending on the answer.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
PRBODY
)"
```

Expected: a PR is created against `upstream/main` (or `origin/main`, whichever this worktree's `origin` remote points at — confirm with `git remote -v` if `gh pr create` complains about the base repo) referencing and closing issue #271.

---
