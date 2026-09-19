# E11 Driver Artifact Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the three driver-side artifacts that make `deploy/microvm/e11-density.sh` report a `c=8` knee on both arms, and add a control arm that measures how much of the remaining latency is the driver's own.

**Architecture:** Four independent repairs to one bash driver, in dependency order. (1) Per-Exec payload construction moves out of the timed window, dropping ~9 process spawns per Exec to 1. (2) `run_density_rung` splits at a converge barrier so the timed window contains only Exec. (3) A background sampler brackets exactly that window and its mean/peak/min/count go into the rung record, with the old post-load snapshot retained under `postLoad*` names. (4) A ~60-line Go null-responder plus a third `driver-control` arm quantify the residual `grpcurl` cost. The TypeScript scorer gains optional field declarations and doc comments; no scorer logic changes.

**Tech Stack:** bash 5 (`EPOCHREALTIME`, `mapfile`, `printf -v`), awk (aggregation only, outside timed windows), Go 1.26 + grpc-go against the existing `gen/go/sandbox/v1` stubs (no new codegen), TypeScript 5 / vitest 2 for `experiments/`, shellcheck 0.10 at `-S warning`.

**Spec:** `docs/superpowers/specs/2026-09-17-e11-driver-artifact-design.md`

## Global Constraints

- **The driver is never executed by this work.** A real sweep needs `/dev/kvm`, Docker, `grpcurl` and real worker binaries. Every task's verification is the cluster-free suite, shellcheck, `go test`, and vitest. The PR states plainly that the instrument has not been run since these changes.
- **`deploy/microvm/predictions.json` is not touched.** It is SHA-256 pinned by `pnpm -C experiments exec vitest run microvm-predictions`.
- **No scorer logic changes** in `experiments/src/microvm-density.ts`. Only doc comments and optional field declarations on `RungSample`.
- **`deploy/microvm/e10-lifecycle.sh` is not changed.**
- **The published E11 numbers in `deploy/microvm/EXPERIMENTS.md` stay.** They are the record of what the broken instrument produced; only a dated caveat is added.
- **`drivingModel` stays `"closed-loop-per-slot"`** and its declared coordinated-omission bias is unchanged.
- **The driver keeps `set -uo pipefail` without `set -e`.** The first `set` line of the file must remain exactly `set -uo pipefail` — `deploy/microvm/tests/e11-density.test.sh` asserts that string.
- **shellcheck must stay clean at `-S warning` AND at `-o check-unassigned-uppercase -S warning`.** Every new uppercase global must be assigned at script scope, above first use.
- **Every temp path lives under `$E11_TMPDIR`.** The suite asserts zero bare `mktemp` / `mktemp -d` calls in non-comment code, and exactly one `E11_TMPDIR="$(mktemp -d` at script scope.
- **`extract_fn` contract:** every function the tests extract must open with `name() {` at column 0 and close with a bare `}` at column 0.
- **DCO sign-off on every commit:** `git commit -s`. Attribution line: `Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>`.
- **Redirect long output to files.** `export LOG_DIR=/tmp/kagenti/tdd/serverless-harness; mkdir -p $LOG_DIR` and then `cmd > $LOG_DIR/name.log 2>&1; echo "EXIT:$?"`.
- **`make lint` skips untracked files.** `git add` new files before running it, or the hook lints nothing and passes silently.

### Existing test assertions this plan deliberately changes

These are exact-count greps in `deploy/microvm/tests/e11-density.test.sh`. Changing them is part of the work, not a workaround; each is named in the task that changes it.

| assertion                                   | today                        | after                             | task   |
| ------------------------------------------- | ---------------------------- | --------------------------------- | ------ |
| `grep -c 'wait "$pid" \|\| slot_failures='` | `1`                          | replaced by two named waits       | Task 3 |
| `grep -c 'VIRTIOFSD_PROC_PATTERN'`          | `2`                          | `3` (the sampler reads it)        | Task 4 |
| trap probe expected order                   | `container microvm `         | `sampler container microvm `      | Task 4 |
| trap probe expected order, again            | `sampler container microvm ` | `sampler container microvm null ` | Task 6 |

### Existing assertions that must keep passing untouched

Do not add occurrences of these strings, or these counts break:

- `grep -c 'drivingModel'` = 3, `grep -c 'closed-loop-per-slot'` = 2
- `grep -c 'repoCacheShape'` = 1, `grep -c 'staticSettings'` = 1
- `grep -c "'leaseSaturations': 0,"` = 1, `grep -c 'bypasses the harness lease layer'` = 1
- `grep -c 'SH_VMM=firecracker'` = 1, `grep -c 'SH_E11_REDIS_IMAGE'` = 2
- `grep -v '^[[:space:]]*#' | grep -c 'docker run'` = 1, `grep -c '^  start_redis_loopback '` = 2
- `grep -cE 'require_numeric (p95Ms|throughput|coldAcquireRate|convergeMsP50|wallSeconds)'` = 5 — new numeric fields must use _new_ names in their `require_numeric` calls
- `grep -v '^[[:space:]]*#' | grep -c '/status'` = 0 and `grep -c 'VmRSS'` = 0 — never read `/proc/<pid>/status`
- `grep -c 'date +%s%N'` >= 1 — `converge_slot` and the `wall_t0`/`wall_t1` stamps keep it; only `grpc_exec_record` loses it
- `grep -nE '\|[^|]+\|\| *echo'` empty — never put `|| echo` on a pipeline
- `grep -v '^[[:space:]]*#' | grep -c 'run_density_rung container'` = 1 and `run_density_rung microvm` = 1

## File Structure

| file                                            | change | responsibility                                                                       |
| ----------------------------------------------- | ------ | ------------------------------------------------------------------------------------ |
| `deploy/microvm/e11-density.sh`                 | modify | the whole repair: payload construction, barrier, sampler, control arm, record schema |
| `deploy/microvm/tests/e11-density.test.sh`      | modify | cluster-free proof of each repair, in the existing `extract_fn` idiom                |
| `remote-worker/cmd/null-responder/main.go`      | create | the control arm's server: `SandboxExec` that sends one `End` and returns             |
| `remote-worker/cmd/null-responder/main_test.go` | create | in-process gRPC test of that server, no KVM and no relay                             |
| `experiments/src/microvm-density.ts`            | modify | `RungSample` doc comments + optional declarations for the new fields                 |
| `experiments/test/microvm-density.test.ts`      | modify | pins that the new fields change no verdict                                           |
| `deploy/microvm/EXPERIMENTS.md`                 | modify | dated caveat on the §E11 claims under repair                                         |

---

### Task 1: Payload construction leaves the timed window (spec §1)

Per-Exec spawns go from ~9 to 1. `grpcurl` stays; everything around it becomes a shell
builtin or moves to once-per-slot.

**Files:**

- Modify: `deploy/microvm/e11-density.sh` (config block ~line 150; `preflight()` at 323; `grpc_exec_record()` at 586; the timed loop inside `run_density_rung()` at ~936-957)
- Test: `deploy/microvm/tests/e11-density.test.sh` (new section after the `percentile` section, ~line 663)

**Interfaces:**

- Consumes: `json_escape` (586's current escaper, unchanged), `e11_tool_call_mix`, `E11_TMPDIR`, `die`, `log`.
- Produces, for Tasks 3 and 4:
  - `epoch_delta_ms <t0> <t1>` — both args are `$EPOCHREALTIME` readings; prints whole milliseconds as a bare integer. No subprocess.
  - `set_epoch_ms` — sets the global `EPOCH_MS` to the current time in whole milliseconds. No subprocess.
  - `escaped_mix` — prints one pre-escaped JSON string literal (quotes included) per line of `e11_tool_call_mix`, same order.
  - `require_epochrealtime` — dies unless `$EPOCHREALTIME` matches `^[0-9]+\.[0-9]+$`.
  - `grpc_exec_record <relay_port> <sandbox_id> <ws_json> <cmd_json> <req_id> <out_file> <err_log>` — `ws_json` and `cmd_json` are already-escaped JSON string literals _including_ their surrounding double quotes; `err_log` is a fixed path the callee truncates.

- [ ] **Step 1: Write the failing tests**

Append to `deploy/microvm/tests/e11-density.test.sh`, immediately before the
`echo "== a FAILED converge is not recorded as a fast converge"` line:

```bash
# ---------------------------------------------------------------------------
# Issue #291 item 2: payload construction leaves the timed window.
#
# grpc_exec_record used to run mktemp, date, json_escape x2 (python3 x2), grpcurl, date,
# rm, plus wc -l x2 in the caller's loop guard -- ~9 process creations per Exec, two of
# them interpreter startups, and t0 was stamped BEFORE the compound whose argument list
# contained both command substitutions, so both interpreter startups fell inside the
# measured latency. At c=64 that is ~64 slots x ~9 spawns continuously, which is enough to
# produce the observed c=8 knee with no contribution from the backend at all.
#
# Two properties are asserted: the payload is byte-identical to what json_escape produced
# (the correctness risk in moving escaping out of the loop), and the timed window contains
# none of the removed spawns (the regression that would silently undo the fix).
# ---------------------------------------------------------------------------
echo "== per-Exec payload construction is pre-escaped, outside the timed window (#291 item 2)"

esc_body="$(extract_fns json_escape e11_tool_call_mix escaped_mix || true)"
check "escaped_mix is extractable alongside json_escape and the mix" \
  "$([ -n "$esc_body" ] && echo yes || echo no)" "yes"

if [ -n "$esc_body" ]; then
  esc_tmpdir="$(mktemp -d)"
  esc_snippet="$esc_tmpdir/esc.sh"
  printf '%s\n' "$esc_body" >"$esc_snippet"

  # The hazardous command: a double quote AND a backslash, the two characters that make
  # naive bash interpolation produce JSON that either fails to parse or silently changes
  # the command the sandbox runs.
  hazard='echo "a\b" > /tmp/x'

  esc_pair=$(
    # shellcheck disable=SC1090
    . "$esc_snippet"
    # Override the mix with the single hazardous command, so escaped_mix's own output can be
    # compared against json_escape of the same string.
    e11_tool_call_mix() { printf '%s\n' 'echo "a\b" > /tmp/x'; }
    printf '%s\n%s\n' "$(escaped_mix)" "$(json_escape 'echo "a\b" > /tmp/x')"
  )
  esc_new="$(printf '%s\n' "$esc_pair" | sed -n 1p)"
  esc_old="$(printf '%s\n' "$esc_pair" | sed -n 2p)"
  check "escaped_mix is byte-identical to json_escape on a command with a quote and a backslash" \
    "$esc_new" "$esc_old"

  # And the assembled payload -- the thing grpcurl actually receives -- round-trips through
  # the real consumer with the command unchanged.
  esc_payload="{\"sandbox_id\":\"e11-test\",\"exec\":{\"req_id\":7,\"command\":$esc_new,\"timeout_s\":30,\"workspace_key\":\"ws-1\"}}"
  esc_rt_rc=0
  esc_rt="$(printf '%s' "$esc_payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["exec"]["command"])' 2>&1)" || esc_rt_rc=$?
  check "the assembled payload parses as JSON" "$esc_rt_rc" "0"
  check "  ...with the command byte-for-byte what was asked for" "$esc_rt" "$hazard"

  # Ordering and count: the mix has 7 commands and escaped_mix must preserve both.
  esc_count=$(
    # shellcheck disable=SC1090
    . "$esc_snippet"
    escaped_mix | wc -l | tr -d ' '
  )
  check "escaped_mix emits one line per mix command (7)" "$esc_count" "7"
  esc_first=$(
    # shellcheck disable=SC1090
    . "$esc_snippet"
    escaped_mix | sed -n 1p
  )
  check "  ...in the mix's own order (first is 'true')" "$esc_first" '"true"'

  rm -rf "$esc_tmpdir"
fi

echo "== the timed window forks nothing but grpcurl (#291 item 2, the regression guard)"
# timed_window_body prints exactly what runs inside the measured window: run_density_rung's
# lines from the wall_t0 stamp up to (not including) the wall_t1 stamp, plus the whole of
# grpc_exec_record, which every Exec in that window calls. Comments are stripped, because
# the explanations of this defect name the removed commands.
timed_window_body() {
  {
    printf '%s\n' "$(extract_fn run_density_rung)" |
      awk '/wall_t0="/{f=1} /wall_t1="/{exit} f{print}'
    extract_fn grpc_exec_record
  } | grep -v '^[[:space:]]*#'
}
tw_body="$(timed_window_body || true)"
check "the timed window is extractable and non-empty" \
  "$([ -n "$tw_body" ] && echo yes || echo no)" "yes"

# NON-VACUOUSNESS: the detector must flag each removed command in a fixture that contains
# it. Without this, "0 findings" below could mean the regex matches nothing.
tw_detect() { printf '%s\n' "$1" | grep -cE '\bjson_escape\b|date \+%s%N|\bmktemp\b|\bwc -l\b'; }
check "non-vacuousness: the detector flags a json_escape in the window" \
  "$(tw_detect '  -d "{\"command\":$(json_escape "$cmd\")}"')" "1"
check "non-vacuousness: the detector flags a date +%s%N in the window" \
  "$(tw_detect '  t0="$(date +%s%N)"')" "1"
check "non-vacuousness: the detector flags an mktemp in the window" \
  "$(tw_detect '  err_log="$(mktemp "$E11_TMPDIR/errlog.XXXXXX")"')" "1"
check "non-vacuousness: the detector flags a wc -l loop guard" \
  "$(tw_detect '  while [ "$(wc -l <"$times_file")" -lt "$want" ]; do')" "1"

if [ -n "$tw_body" ]; then
  check "no json_escape, date, mktemp or wc runs inside the timed window" \
    "$(tw_detect "$tw_body")" "0"
  # The complement, so the check above cannot pass by the window having gone away.
  check "  ...and grpcurl still does (the one spawn that is the measurement)" \
    "$([ "$(printf '%s\n' "$tw_body" | grep -c 'grpcurl')" -ge 1 ] && echo yes || echo no)" "yes"
  check "  ...and latency is stamped from EPOCHREALTIME, a shell variable" \
    "$([ "$(printf '%s\n' "$tw_body" | grep -c 'EPOCHREALTIME')" -ge 1 ] && echo yes || echo no)" "yes"
fi

echo "== epoch_delta_ms and the EPOCHREALTIME preflight"
ep_body="$(extract_fns die epoch_delta_ms set_epoch_ms require_epochrealtime || true)"
check "the epoch helpers are extractable" "$([ -n "$ep_body" ] && echo yes || echo no)" "yes"

if [ -n "$ep_body" ]; then
  ep_snippet="$(mktemp -d)/ep.sh"
  printf '%s\n' "$ep_body" >"$ep_snippet"
  ep() {
    (
      # shellcheck disable=SC1090
      . "$ep_snippet"
      epoch_delta_ms "$1" "$2"
    )
  }
  check "epoch_delta_ms over 1.5s" "$(ep 1789672470.000000 1789672471.500000)" "1500"
  check "epoch_delta_ms truncates sub-millisecond" "$(ep 1789672470.000000 1789672470.000999)" "0"
  check "epoch_delta_ms handles a leading-zero microsecond field" \
    "$(ep 1789672470.000000 1789672470.042000)" "42"
  check "epoch_delta_ms across a second boundary" \
    "$(ep 1789672470.900000 1789672471.100000)" "200"

  # The preflight: a shell with no EPOCHREALTIME (bash < 5.0, which is /bin/bash on macOS)
  # or a locale that renders a decimal comma both make every timed Exec an arithmetic
  # error. This refuses in preflight instead.
  ep_unset_rc=0
  ep_unset_out=$(
    (
      # shellcheck disable=SC1090
      . "$ep_snippet"
      unset EPOCHREALTIME
      require_epochrealtime
    ) 2>&1
  ) || ep_unset_rc=$?
  check "require_epochrealtime refuses when EPOCHREALTIME is unset" \
    "$([ "$ep_unset_rc" -ne 0 ] && echo yes || echo no)" "yes"
  case "$ep_unset_out" in *EPOCHREALTIME*) ep_named=yes ;; *) ep_named=no ;; esac
  check "  ...and the refusal names EPOCHREALTIME" "$ep_named" "yes"
  ep_comma_rc=0
  ep_comma_out=$(
    (
      # shellcheck disable=SC1090
      . "$ep_snippet"
      EPOCHREALTIME='1789672470,123935'
      require_epochrealtime
    ) 2>&1
  ) || ep_comma_rc=$?
  check "require_epochrealtime refuses a locale decimal COMMA (LC_NUMERIC=de_DE)" \
    "$([ "$ep_comma_rc" -ne 0 ] && echo yes || echo no)" "yes"
  case "$ep_comma_out" in *[Ll]ocale*) ep_loc=yes ;; *) ep_loc=no ;; esac
  check "  ...and says so, so the fix is obvious" "$ep_loc" "yes"
  ep_ok_rc=0
  (
    # shellcheck disable=SC1090
    . "$ep_snippet"
    EPOCHREALTIME='1789672470.123935'
    require_epochrealtime
  ) >/dev/null 2>&1 || ep_ok_rc=$?
  check "require_epochrealtime accepts a well-formed reading (does not refuse everything)" \
    "$ep_ok_rc" "0"
  rm -rf "$(dirname "$ep_snippet")"
fi

check "LC_ALL is pinned and exported for the whole driver" \
  "$([ "$(grep -c '^export LC_ALL$' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "preflight calls require_epochrealtime" \
  "$([ "$(printf '%s\n' "$(extract_fn preflight)" | grep -c 'require_epochrealtime')" -ge 1 ] && echo yes || echo no)" "yes"
check "the slot's error log is a fixed path under the trap-owned root, not an mktemp" \
  "$([ "$(grep -c 'err_log="\$slot_dir/slot-\$i.err"' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
# Spec section 1 says the escaping happens BEFORE TIMING STARTS, not merely outside the
# per-Exec loop. Assert the order structurally: the mix is escaped, and every slot's
# workspace_key with it, above the wall_t0 stamp.
pe_rdr="$(extract_fn run_density_rung || true)"
if [ -n "$pe_rdr" ]; then
  pe_line() { printf '%s\n' "$pe_rdr" | grep -n -- "$1" | head -n1 | cut -d: -f1; }
  pe_mix="$(pe_line 'mapfile -t mix_json')"
  pe_ws="$(pe_line 'ws_json_by_slot\[i\]=')"
  pe_t0="$(pe_line 'wall_t0="')"
  check "the mix is pre-escaped inside run_density_rung" \
    "$([ -n "$pe_mix" ] && echo yes || echo no)" "yes"
  check "each slot's workspace_key is pre-escaped too" \
    "$([ -n "$pe_ws" ] && echo yes || echo no)" "yes"
  if [ -n "$pe_mix" ] && [ -n "$pe_ws" ] && [ -n "$pe_t0" ]; then
    check "the mix is escaped BEFORE wall_t0 (before timing starts)" \
      "$([ "$pe_mix" -lt "$pe_t0" ] && echo yes || echo no)" "yes"
    check "the workspace keys are escaped before wall_t0 too" \
      "$([ "$pe_ws" -lt "$pe_t0" ] && echo yes || echo no)" "yes"
  fi
  check "the mix is escaped exactly once per rung, not once per slot" \
    "$(printf '%s\n' "$pe_rdr" | grep -c 'mapfile -t mix_json')" "1"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
export LOG_DIR=/tmp/kagenti/tdd/serverless-harness; mkdir -p "$LOG_DIR"
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t1-red.log" 2>&1; echo "EXIT:$?"
grep -c FAIL "$LOG_DIR/t1-red.log"
```

Expected: non-zero exit. `escaped_mix`, `epoch_delta_ms`, `set_epoch_ms` and
`require_epochrealtime` are not extractable, and `tw_detect` finds `json_escape`,
`date +%s%N`, `mktemp` and `wc -l` inside the timed window.

- [ ] **Step 3: Pin the locale, add the epoch helpers and the preflight**

In `deploy/microvm/e11-density.sh`, immediately after the `set -uo pipefail` line (line 122) and before the `# Configuration` comment, insert:

```bash
# LC_ALL is pinned for the WHOLE driver, and exported so awk, python3 and grpcurl inherit
# it. $EPOCHREALTIME -- which replaces two `date +%s%N` forks per Exec below -- renders with
# the LOCALE's decimal separator, so under e.g. LC_NUMERIC=de_DE it yields
# "1789672470,123935". epoch_delta_ms strips a '.', not a ',', so the comma would survive
# into `10#`, and every Exec's latency would become an arithmetic error INSIDE the timed
# loop. require_epochrealtime in preflight proves the pin took.
LC_ALL=C
export LC_ALL
```

Then, immediately above `json_escape()` (line 536), insert:

```bash
# ---------------------------------------------------------------------------
# Timing primitives (issue #291 item 2).
#
# $EPOCHREALTIME is a bash VARIABLE (bash >= 5.0), so reading it costs no process. It
# replaces the two `date +%s%N` forks grpc_exec_record used to take per Exec -- and,
# because t0 was stamped before the compound whose argument list held two python3 command
# substitutions, those two interpreter startups were inside the measured latency.
# Resolution drops from nanoseconds to microseconds, which is immaterial for millisecond
# latencies.
#
# Both helpers avoid command substitution deliberately: `x="$(f)"` is a FORK, which is the
# entire thing being removed here. epoch_delta_ms prints (it is called once per Exec, where
# one fork for the substitution is what the caller already pays for the assignment), while
# set_epoch_ms writes a global (it is called inside the sampler's tick loop, where nothing
# may fork).
# ---------------------------------------------------------------------------
EPOCH_MS=0

# epoch_delta_ms prints the whole milliseconds between two $EPOCHREALTIME readings.
# Stripping the '.' turns <seconds>.<6 digits> into integer MICROSECONDS, which bash's
# 64-bit arithmetic holds with room to spare (1.8e15 today). `10#` is defensive against a
# reading whose integer part could ever begin with 0.
epoch_delta_ms() {
  local a="${1/./}" b="${2/./}"
  echo $(((10#$b - 10#$a) / 1000))
}

# set_epoch_ms sets EPOCH_MS to now, in whole milliseconds, with no subprocess.
set_epoch_ms() {
  local e="${EPOCHREALTIME/./}"
  EPOCH_MS=$((10#$e / 1000))
}

# require_epochrealtime refuses a shell whose $EPOCHREALTIME is missing or not
# <digits>.<digits>. bash < 5.0 does not define it at all -- and bash 3.2 is both /bin/sh
# and /bin/bash on macOS -- so under `set -u` the FIRST timed Exec would abort its slot,
# every slot, and the rung would refuse with a message about converge. A locale rendering a
# decimal comma is the other way this reads wrong; LC_ALL=C above pins it.
require_epochrealtime() {
  [[ "${EPOCHREALTIME:-}" =~ ^[0-9]+\.[0-9]+$ ]] ||
    die "\$EPOCHREALTIME is '${EPOCHREALTIME:-<unset>}', not <seconds>.<microseconds>: this driver times every Exec from it (issue #291 item 2). Unset means bash < 5.0 (bash 3.2 is /bin/bash on macOS - run this under a bash 5 on PATH); a decimal comma means a locale is overriding the LC_ALL=C pin at the top of this file."
}
```

In `preflight()`, add `require_epochrealtime` as the first line of the function body,
above the `require_tool grpcurl` line.

- [ ] **Step 4: Add `escaped_mix` and rewrite `grpc_exec_record`**

Immediately above `grpc_exec_record()` (line 586), insert:

```bash
# escaped_mix prints one PRE-ESCAPED JSON string literal (surrounding double quotes
# included) per command of e11_tool_call_mix, in the mix's own order. It is called ONCE PER
# SLOT, before the slot's timed loop starts -- this is where the two python3 interpreter
# startups per Exec went (issue #291 item 2). It uses the same json_escape the timed loop
# used to call, so the bytes it produces are identical by construction rather than by a
# reimplementation of JSON escaping in bash, which is where this change's real risk was.
escaped_mix() {
  local cmd
  while IFS= read -r cmd; do
    json_escape "$cmd"
  done < <(e11_tool_call_mix)
}
```

Replace the body of `grpc_exec_record()` (lines 586-615) with:

```bash
grpc_exec_record() {
  local relay_port="$1" sandbox_id="$2" ws_json="$3" cmd_json="$4" req_id="$5" out_file="$6" err_log="$7"
  local t0 t1 ms cause status
  # ws_json and cmd_json arrive ALREADY ESCAPED, quotes included (escaped_mix / the caller's
  # one-shot workspace_key escape). err_log is a fixed per-slot path: `2>` truncates it on
  # every call, so the old mktemp+rm pair bought nothing. req_id is a number and needs no
  # escaping.
  t0="$EPOCHREALTIME"
  if grpcurl -plaintext -max-time "$EXEC_MAX_TIME_S" -import-path "$PROTO_IMPORT_PATH" -proto "$PROTO_REL_PATH" \
    -d "{\"sandbox_id\":\"$sandbox_id\",\"exec\":{\"req_id\":$req_id,\"command\":$cmd_json,\"timeout_s\":30,\"workspace_key\":$ws_json}}" \
    "localhost:${relay_port}" sandbox.v1.SandboxExec/Exec >/dev/null 2>"$err_log"; then
    t1="$EPOCHREALTIME"
    status="ok"
    cause="-"
  else
    t1="$EPOCHREALTIME"
    status="err"
    # These greps are the ONLY subprocesses left besides grpcurl, and they run only after an
    # Exec has already failed -- so they cannot contribute to a healthy rung's latency, and a
    # failed Exec's latency is not in the distribution p95 is taken over anyway.
    if grep -qi "workspace_key" "$err_log"; then
      cause="empty-workspace-key"
    elif grep -qi "mem" "$err_log"; then
      cause="memory-gate"
    elif grep -qi "maxruns\|max-runs\|max_runs" "$err_log"; then
      cause="max-runs"
    elif grep -qi "spawn" "$err_log"; then
      cause="spawn-failure"
    elif grep -qi "vsock" "$err_log"; then
      cause="vsock-short-response"
    else
      cause="unknown"
    fi
  fi
  ms="$(epoch_delta_ms "$t0" "$t1")"
  echo "$ms $status $cause" >>"$out_file"
}
```

Note the `t1` stamp moved _inside_ both branches, immediately after `grpcurl` returns, so
the error classification greps fall outside the measured latency too.

- [ ] **Step 5: Pre-escape the payloads before `wall_t0`, then rewrite the slot's timed loop**

Two edits. **First**, insert this immediately ABOVE the `wall_t0="$(date +%s%N)"` line
(currently 901), and delete the now-redundant bare `local i` line just below it:

```bash
  # Payload construction happens HERE, before timing starts -- spec section 1: "pre-escape
  # the 7 mix commands and the slot's workspace_key once per slot, before timing starts".
  # The mix is identical for every slot, so it is escaped once per RUNG; the workspace keys
  # differ, so there is one per slot. Both are plain shell variables, which the slot
  # subshells below inherit.
  #
  # json_escape (python3) is still what does the escaping, so the bytes are identical BY
  # CONSTRUCTION rather than by a reimplementation of JSON escaping in bash -- which is where
  # this change's real risk was. It just runs 7 + c times per rung instead of twice per Exec.
  local -a mix_json=() ws_json_by_slot=()
  mapfile -t mix_json < <(escaped_mix)
  [ "${#mix_json[@]}" -gt 0 ] ||
    die "rung arm=$arm d=$d ram=${ram_mb}MiB c=$c: escaped_mix produced no commands, so every slot would loop forever issuing no Execs"
  local i run_id_i wskey_i
  for i in $(seq 1 "$c"); do
    run_id_i="e11-${arm}-d${d}-ram${ram_mb}-c${c}-slot${i}"
    wskey_i=""
    if [ "$arm" = "microvm" ]; then
      wskey_i="$run_id_i" # microvm arm REFUSES an empty workspace_key (proto doc comment)
    fi                    # container arm may omit/empty it (today's single shared workspace)
    ws_json_by_slot[i]="$(json_escape "$wskey_i")"
  done
```

**Second**, replace the timed loop (the `local times_file=...` line through the
`done < <(e11_tool_call_mix)` line, currently 936-957) with:

```bash
      local times_file="$slot_dir/slot-$i.times" err_log="$slot_dir/slot-$i.err" req="$req_base"
      # Pre-escaped above, before wall_t0. Parameter expansion, not a command substitution:
      # `local x="$(...)"` would trip SC2155, which is a WARNING and so a lint failure here.
      local ws_json="${ws_json_by_slot[$i]}"
      : >"$times_file"
      : >"$err_log"
      # A shell counter, not `wc -l` twice per Exec: the timed loop is this file's only
      # writer, so the count is known without reading it back. `for mi in` over the array
      # pre-escaped above also removes the process-substitution subshell the inner
      # `while read` re-spawned on every pass over the mix.
      local want=$((ITERS_PER_SLOT + WARMUP_PER_SLOT)) issued=0 mi
      while [ "$issued" -lt "$want" ]; do
        for mi in "${!mix_json[@]}"; do
          req=$((req + 1))
          grpc_exec_record "$relay_port" "$sandbox_id" "$ws_json" "${mix_json[$mi]}" "$req" "$times_file" "$err_log"
          issued=$((issued + 1))
          [ "$issued" -ge "$want" ] && break
        done
      done
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t1-green.log" 2>&1; echo "EXIT:$?"
grep -E 'FAIL|Total failures' "$LOG_DIR/t1-green.log"
shellcheck -x -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t1-sc.log" 2>&1; echo "EXIT:$?"
shellcheck -o check-unassigned-uppercase -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t1-sc2154.log" 2>&1; echo "EXIT:$?"
```

Expected: `Total failures: 0`, exit 0 from all three.

- [ ] **Step 7: Commit**

```bash
git add deploy/microvm/e11-density.sh deploy/microvm/tests/e11-density.test.sh
git commit -s -m "fix(e11): move per-Exec payload construction out of the timed window

grpc_exec_record ran ~9 processes per Exec -- mktemp, date x2, json_escape x2
(python3 x2), grpcurl, rm, plus wc -l x2 in the caller's loop guard -- and t0 was
stamped before the compound whose argument list held both command substitutions, so
two interpreter startups were inside the measured latency. At c=64 that is ~64 slots
x ~9 spawns continuously, enough to produce the observed c=8 knee on both arms with
no contribution from either backend.

Refs #291 item 2.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 2: Fork-free host sampler primitives (spec §2, first half)

The sampler must not become the next artifact. This task builds the pieces that tick at
1 Hz with **zero** subprocesses on the every-tick path, and the low-cadence path that pays
for `pgrep` plus an N-file `smaps_rollup` walk every Nth tick. Nothing is wired into
`run_density_rung` yet — that is Task 4, after the barrier lands.

**Files:**

- Modify: `deploy/microvm/e11-density.sh` (config block, after `VIRTIOFSD_PROC_PATTERN` at line 186; new sampler section between `host_cpu_fraction()` at 461 and `host_signals_snapshot()` at 508)
- Test: `deploy/microvm/tests/e11-density.test.sh` (new section after the Task 1 section)

**Interfaces:**

- Consumes: `PROC_ROOT`, `VMM_PROC_PATTERN`, `VIRTIOFSD_PROC_PATTERN`, `discover_pids`, `pss_bytes_for_pids`, `set_epoch_ms` / `EPOCH_MS` (Task 1), `die`.
- Produces, for Task 4:
  - `SAMPLE_INTERVAL_MS` / `SAMPLE_SLICE_MS` / `SAMPLE_MIN_TICK_MS` / `SAMPLE_LOW_EVERY` — script-scope config globals.
  - `proc_stat_totals` — sets `SAMPLE_IDLE` and `SAMPLE_TOTAL` from the aggregate `cpu ` line; returns 1 if there is no such line.
  - `proc_meminfo_available` — sets `SAMPLE_MEM_AVAILABLE_BYTES`; returns 1 if there is no `MemAvailable:` line.
  - `host_sampler_tick <out_file>` — appends exactly one line, `<cpuFraction> <memAvailableBytes> <pssBytes|-> <processCount|->`, and advances `SAMPLE_PREV_IDLE`, `SAMPLE_PREV_TOTAL`, `SAMPLE_TICK`.
  - `host_sampler_loop <out_file> <stop_file>` — ticks until `stop_file` exists, then emits one final tick if at least `SAMPLE_MIN_TICK_MS` has elapsed since the last one. Intended to be backgrounded.

- [ ] **Step 1: Write the failing tests**

Append to `deploy/microvm/tests/e11-density.test.sh`, after the Task 1 section:

```bash
# ---------------------------------------------------------------------------
# Issue #291 item 1: host resource signals are sampled DURING the timed window.
#
# host_signals_snapshot was called after every slot subshell had exited and after the
# throughput window closed, and host_cpu_fraction then SLEPT ONE SECOND and diffed
# /proc/stat across that window -- so hostCpuFraction, memAvailableBytes and pssBytes all
# described a quiesced machine. The recorded values contain their own falsification: 0.0006
# on a 72-cpu host is 0.043 cores busy, while the same rung sustained ~41 Exec/sec at ~9
# spawns each, on the order of 370 process creations per second.
#
# Worse than weak: crosses('cpu') in experiments/src/microvm-density.ts reads
# hostCpuFraction >= 0.9, so a post-load 0.0006 makes the `cpu` bound STRUCTURALLY unable to
# fire at any rung. EXPERIMENTS.md's "no CPU ceiling was reached" is a restatement of the
# sampling bug, not a finding.
#
# The sampler that replaces it must not become the next artifact: reading 128 smaps_rollup
# files per second while measuring a density ceiling perturbs the thing under test. So the
# every-tick path uses only builtins, and the pgrep + N-file walk runs every Nth tick.
# ---------------------------------------------------------------------------
echo "== the sampler's every-tick path uses only builtins (#291 item 1)"

samp_body="$(extract_fns die set_epoch_ms discover_pids pss_bytes_for_pids proc_stat_totals proc_meminfo_available host_sampler_tick host_sampler_loop || true)"
check "the sampler functions are extractable" "$([ -n "$samp_body" ] && echo yes || echo no)" "yes"

# The every-tick path must contain no external command. awk, sleep, date, pgrep, python3 and
# wc are all forks; `sleep` is legitimate in host_sampler_loop's slice wait but must not
# appear in the tick itself, and pgrep/awk reach the tick only through the low-cadence
# branch, which is guarded.
tick_only="$(extract_fn host_sampler_tick | grep -v '^[[:space:]]*#' || true)"
check "host_sampler_tick body is extractable" "$([ -n "$tick_only" ] && echo yes || echo no)" "yes"
tick_forks() { printf '%s\n' "$1" | grep -cE '\bawk\b|\bsleep\b|date \+|\bpython3\b|\bwc\b|\bcat\b'; }
check "non-vacuousness: the fork detector flags an awk in a tick" \
  "$(tick_forks '  frac="$(awk -v x=1 "BEGIN{print x}")"')" "1"
if [ -n "$tick_only" ]; then
  check "host_sampler_tick calls no awk, sleep, date, python3, wc or cat" \
    "$(tick_forks "$tick_only")" "0"
  check "  ...and formats the CPU fraction with printf -v (a builtin, not a subshell)" \
    "$([ "$(printf '%s\n' "$tick_only" | grep -c 'printf -v')" -ge 1 ] && echo yes || echo no)" "yes"
  check "  ...and the pgrep walk is behind the low-cadence guard, not on every tick" \
    "$([ "$(printf '%s\n' "$tick_only" | grep -c 'SAMPLE_LOW_EVERY')" -ge 1 ] && echo yes || echo no)" "yes"
fi

if [ -n "$samp_body" ]; then
  sp_tmpdir="$(mktemp -d)"
  sp_snippet="$sp_tmpdir/samp.sh"
  printf '%s\n' "$samp_body" >"$sp_snippet"
  sp_proc="$sp_tmpdir/proc"
  mkdir -p "$sp_proc"

  # --- CPU diff correctness, against two hand-written /proc/stat snapshots.
  # Snapshot A: user=100 nice=0 system=100 idle=800 iowait=0, total 1000, idle+iowait 800.
  # Snapshot B: user=600 nice=0 system=100 idle=1300 iowait=0, total 2000, idle+iowait 1300.
  # dt=1000, di=500 -> busy fraction 1 - 500/1000 = 0.5000.
  printf 'cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 100 0 100 800 0 0 0 0 0 0\n' >"$sp_proc/stat"
  printf 'MemTotal:       16384000 kB\nMemFree:            1000 kB\nMemAvailable:    8192000 kB\n' >"$sp_proc/meminfo"

  sp_line=$(
    PROC_ROOT="$sp_proc"
    SAMPLE_LOW_EVERY=1000 # so tick 1 takes the LOW-cadence branch only if tick==1 forces it
    VMM_PROC_PATTERN="__e11_no_such_process__"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    proc_stat_totals
    SAMPLE_PREV_IDLE="$SAMPLE_IDLE"
    SAMPLE_PREV_TOTAL="$SAMPLE_TOTAL"
    SAMPLE_TICK=0 # the script-scope declaration is not in the extracted snippet
    printf 'cpu  600 0 100 1300 0 0 0 0 0 0\ncpu0 600 0 100 1300 0 0 0 0 0 0\n' >"$PROC_ROOT/stat"
    host_sampler_tick "$sp_tmpdir/out"
    cat "$sp_tmpdir/out"
  )
  check "the CPU diff over two hand-written /proc/stat snapshots is 0.5000" \
    "$(printf '%s\n' "$sp_line" | awk '{print $1}')" "0.5000"
  check "MemAvailable is parsed from a fake /proc/meminfo and converted to bytes" \
    "$(printf '%s\n' "$sp_line" | awk '{print $2}')" "8388608000"
  check "the tick emits exactly one line" "$(printf '%s\n' "$sp_line" | wc -l | tr -d ' ')" "1"
  rm -f "$sp_tmpdir/out"

  # --- A zero-delta snapshot pair is 0.0000, not a division by zero.
  printf 'cpu  100 0 100 800 0 0 0 0 0 0\n' >"$sp_proc/stat"
  sp_zero=$(
    PROC_ROOT="$sp_proc"
    SAMPLE_LOW_EVERY=1000
    VMM_PROC_PATTERN="__e11_no_such_process__"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    proc_stat_totals
    SAMPLE_PREV_IDLE="$SAMPLE_IDLE"
    SAMPLE_PREV_TOTAL="$SAMPLE_TOTAL"
    SAMPLE_TICK=0 # the script-scope declaration is not in the extracted snippet
    host_sampler_tick "$sp_tmpdir/out"
    awk '{print $1}' "$sp_tmpdir/out"
  )
  check "an identical snapshot pair yields 0.0000, not a divide-by-zero" "$sp_zero" "0.0000"
  rm -f "$sp_tmpdir/out"

  # --- A fully busy window is 1.0000 and never exceeds it.
  printf 'cpu  100 0 100 800 0 0 0 0 0 0\n' >"$sp_proc/stat"
  sp_busy=$(
    PROC_ROOT="$sp_proc"
    SAMPLE_LOW_EVERY=1000
    VMM_PROC_PATTERN="__e11_no_such_process__"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    proc_stat_totals
    SAMPLE_PREV_IDLE="$SAMPLE_IDLE"
    SAMPLE_PREV_TOTAL="$SAMPLE_TOTAL"
    SAMPLE_TICK=0 # the script-scope declaration is not in the extracted snippet
    printf 'cpu  1100 0 100 800 0 0 0 0 0 0\n' >"$PROC_ROOT/stat"
    host_sampler_tick "$sp_tmpdir/out"
    awk '{print $1}' "$sp_tmpdir/out"
  )
  check "a window with zero idle jiffies is 1.0000 (the value crosses('cpu') tests at 0.9)" \
    "$sp_busy" "1.0000"
  rm -f "$sp_tmpdir/out"

  # --- No MemAvailable line: 0, and still one clean line (the H2 class, in the sampler).
  printf 'MemTotal:       16384000 kB\n' >"$sp_proc/meminfo"
  printf 'cpu  100 0 100 800 0 0 0 0 0 0\n' >"$sp_proc/stat"
  sp_nomem=$(
    PROC_ROOT="$sp_proc"
    SAMPLE_LOW_EVERY=1000
    VMM_PROC_PATTERN="__e11_no_such_process__"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    proc_stat_totals
    SAMPLE_PREV_IDLE="$SAMPLE_IDLE"
    SAMPLE_PREV_TOTAL="$SAMPLE_TOTAL"
    SAMPLE_TICK=0 # the script-scope declaration is not in the extracted snippet
    host_sampler_tick "$sp_tmpdir/out"
    cat "$sp_tmpdir/out"
  )
  check "no MemAvailable line -> 0 bytes, on one line" \
    "$(printf '%s\n' "$sp_nomem" | awk '{print $2}')" "0"
  check "  ...and still exactly one line (no two-line value, the H2 shape)" \
    "$(printf '%s\n' "$sp_nomem" | wc -l | tr -d ' ')" "1"
  printf 'MemTotal:       16384000 kB\nMemFree:            1000 kB\nMemAvailable:    8192000 kB\n' >"$sp_proc/meminfo"
  rm -f "$sp_tmpdir/out"

  # --- The low cadence: tick 1 always carries pss/processCount (so a rung can never end
  # with zero of them while having CPU samples), then every SAMPLE_LOW_EVERY'th tick.
  sp_marker="$(marker_token sampler)"
  spawn_marker_process "$sp_marker"
  sp_live="$MARKER_PID"
  mkdir -p "$sp_proc/$sp_live"
  printf 'Pss:                 512 kB\n' >"$sp_proc/$sp_live/smaps_rollup"
  sp_cad=$(
    PROC_ROOT="$sp_proc"
    SAMPLE_LOW_EVERY=3
    VMM_PROC_PATTERN="$sp_marker"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    proc_stat_totals
    SAMPLE_PREV_IDLE="$SAMPLE_IDLE"
    SAMPLE_PREV_TOTAL="$SAMPLE_TOTAL"
    SAMPLE_TICK=0 # the script-scope declaration is not in the extracted snippet
    for _ in 1 2 3 4 5 6; do host_sampler_tick "$sp_tmpdir/out"; done
    awk '{print $3}' "$sp_tmpdir/out" | tr '\n' ' '
  )
  check "tick 1 carries pssBytes, then every 3rd tick does (ticks 1,3,6 of 6)" \
    "$sp_cad" "524288 - 524288 - - 524288 "
  sp_cad_proc=$(awk '{print $4}' "$sp_tmpdir/out" | tr '\n' ' ')
  check "  ...and processCount follows the same cadence" "$sp_cad_proc" "1 - 1 - - 1 "
  stop_marker_process "$sp_live"
  rm -f "$sp_tmpdir/out"

  # --- host_sampler_loop: ticks while running, stops on the stop file, and emits a final
  # tick so a short rung is not left with zero samples.
  printf 'cpu  100 0 100 800 0 0 0 0 0 0\n' >"$sp_proc/stat"
  sp_stop="$sp_tmpdir/stop"
  sp_out="$sp_tmpdir/loop-out"
  : >"$sp_out"
  (
    PROC_ROOT="$sp_proc"
    SAMPLE_INTERVAL_MS=200
    SAMPLE_SLICE_MS=100
    SAMPLE_MIN_TICK_MS=1
    SAMPLE_LOW_EVERY=1000
    VMM_PROC_PATTERN="__e11_no_such_process__"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    host_sampler_loop "$sp_out" "$sp_stop"
  ) &
  sp_loop_pid=$!
  sleep 1
  : >"$sp_stop"
  wait "$sp_loop_pid"
  sp_n="$(wc -l <"$sp_out" | tr -d ' ')"
  check "host_sampler_loop produced at least 3 ticks in ~1s at a 200ms interval" \
    "$([ "$sp_n" -ge 3 ] && echo yes || echo no)" "yes"
  check "  ...and exited on the stop file rather than running forever" \
    "$([ -e "/proc/$sp_loop_pid" ] && echo running || echo exited)" "exited"
  check "  ...and every line has exactly 4 fields" \
    "$(awk 'NF != 4 {bad++} END{print bad+0}' "$sp_out")" "0"

  # A rung shorter than one interval still gets one sample, from the stop tick.
  : >"$sp_out"
  rm -f "$sp_stop"
  (
    PROC_ROOT="$sp_proc"
    SAMPLE_INTERVAL_MS=60000
    SAMPLE_SLICE_MS=100
    SAMPLE_MIN_TICK_MS=1
    SAMPLE_LOW_EVERY=1000
    VMM_PROC_PATTERN="__e11_no_such_process__"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    host_sampler_loop "$sp_out" "$sp_stop"
  ) &
  sp_short_pid=$!
  sleep 0.5
  : >"$sp_stop"
  wait "$sp_short_pid"
  check "a window shorter than one interval still yields one sample (the stop tick)" \
    "$(wc -l <"$sp_out" | tr -d ' ')" "1"

  # ...but the stop tick REFUSES to fabricate a sample over an interval too short to diff.
  : >"$sp_out"
  rm -f "$sp_stop"
  (
    PROC_ROOT="$sp_proc"
    SAMPLE_INTERVAL_MS=60000
    SAMPLE_SLICE_MS=100
    SAMPLE_MIN_TICK_MS=60000
    SAMPLE_LOW_EVERY=1000
    VMM_PROC_PATTERN="__e11_no_such_process__"
    VIRTIOFSD_PROC_PATTERN="__e11_no_such_process__"
    # shellcheck disable=SC1090
    . "$sp_snippet"
    host_sampler_loop "$sp_out" "$sp_stop"
  ) &
  sp_tiny_pid=$!
  sleep 0.4
  : >"$sp_stop"
  wait "$sp_tiny_pid"
  check "a window below SAMPLE_MIN_TICK_MS records NO sample rather than a noise diff" \
    "$(wc -l <"$sp_out" | tr -d ' ')" "0"

  rm -rf "$sp_tmpdir"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t2-red.log" 2>&1; echo "EXIT:$?"
grep FAIL "$LOG_DIR/t2-red.log" | head
```

Expected: `the sampler functions are extractable` FAILs with `want 'yes', got 'no'`, and
the dependent blocks are skipped.

- [ ] **Step 3: Add the sampler config globals**

In `deploy/microvm/e11-density.sh`, immediately after the `VIRTIOFSD_PROC_PATTERN` line
(186), insert:

```bash
# In-rung host sampling (issue #291 item 1). The sampler brackets exactly the timed Exec
# window; see host_sampler_loop for why there are two cadences and what each costs.
#
# 1 Hz by default: the every-tick path is builtins only, so its cost is a `sleep` fork per
# slice and nothing else. SAMPLE_SLICE_MS is how often the loop checks the stop file, which
# bounds how much post-window time the final tick can include -- 100ms, against a window of
# seconds.
SAMPLE_INTERVAL_MS="${SH_E11_SAMPLE_INTERVAL_MS:-1000}"
SAMPLE_SLICE_MS="${SH_E11_SAMPLE_SLICE_MS:-100}"
# The floor under the final tick at stop. A /proc/stat diff over a few milliseconds is jiffy
# noise, not a measurement, so below this the stop tick records NOTHING and the rung's
# hostCpuSamples is 0 -- which run_density_rung refuses, naming the fix.
SAMPLE_MIN_TICK_MS="${SH_E11_SAMPLE_MIN_TICK_MS:-200}"
# pssBytes and processCount need pgrep plus an N-file smaps_rollup walk, so they run every
# Nth tick (and always on tick 1, so a rung with CPU samples can never have zero of them).
# Defensible because crosses('memory') in experiments/src/microvm-density.ts reads
# memAvailableBytes -- which IS every tick -- not pssBytes: PSS feeds the narrative, not the
# bound classification. The cadence is recorded in every rung's proxyLimitations, and each
# signal's own sample count is written to the record.
SAMPLE_LOW_EVERY="${SH_E11_SAMPLE_LOW_EVERY:-5}"

# Sampler state. At script scope, above first use, because `shellcheck -o
# check-unassigned-uppercase` is a gate here (a variable referenced but never assigned
# passes plain shellcheck AND `bash -n`, and is a hard failure under this driver's `set -u`
# on the first line that reads it -- exactly how $PROTO_IMPORT_PATH shipped undefined).
SAMPLE_IDLE=0
SAMPLE_TOTAL=0
SAMPLE_MEM_AVAILABLE_BYTES=0
SAMPLE_PREV_IDLE=0
SAMPLE_PREV_TOTAL=0
SAMPLE_TICK=0
```

- [ ] **Step 4: Add the sampler functions**

Insert between `host_cpu_fraction()` (which stays, for the post-load snapshot) and
`host_signals_snapshot()` — i.e. immediately above the `# host_signals_snapshot prints one
JSON object` comment at line 481:

```bash
# ---------------------------------------------------------------------------
# The in-rung sampler (issue #291 item 1).
#
# host_signals_snapshot below is KEPT, and its values are recorded under postLoad* names, so
# an idle reading can never again pass as an under-load one. What it cannot do is sample
# during the window: host_cpu_fraction SLEEPS for its diff, so calling it from inside a
# concurrency rung would either stall the driver or measure one second of a window that may
# be shorter than that.
#
# The every-tick path here therefore forks NOTHING. proc_stat_totals and
# proc_meminfo_available read /proc with the `read` builtin and a file redirection (not a
# pipe, so no subshell), the CPU fraction is formatted with `printf -v`, and the previous
# /proc/stat reading is kept in globals rather than re-derived -- which is what removes the
# `sleep` from inside a sample. Globals rather than printed values throughout, because
# `x="$(f)"` is a fork and this runs beside the thing being measured.
# ---------------------------------------------------------------------------

# proc_stat_totals sets SAMPLE_IDLE and SAMPLE_TOTAL from the aggregate "cpu " line.
# Returns non-zero when there is no such line, so a caller on a non-Linux host samples
# nothing rather than recording a fabricated 0.
#
# Missing trailing fields (guest / guest_nice are absent on older kernels) are ASSIGNED
# EMPTY by `read`, not left unset, and bash arithmetic treats an empty string as 0 -- so
# `set -u` is satisfied and the sum is still correct.
proc_stat_totals() {
  local label user nice system idle iowait irq softirq steal guest guest_nice
  SAMPLE_IDLE=0
  SAMPLE_TOTAL=0
  while read -r label user nice system idle iowait irq softirq steal guest guest_nice; do
    [ "$label" = "cpu" ] || continue
    SAMPLE_IDLE=$((idle + iowait))
    SAMPLE_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal + guest + guest_nice))
    return 0
  done <"$PROC_ROOT/stat"
  return 1
}

# proc_meminfo_available sets SAMPLE_MEM_AVAILABLE_BYTES from MemAvailable, in bytes.
# Returns non-zero when there is no MemAvailable line. mem_available_bytes' awk form stays
# in place for the post-load snapshot, where one fork per rung costs nothing.
#
# The third `read` variable is needed (two would put "8192000 kB" in $value) and named
# _rest because SC2034 -- "appears unused" -- is a WARNING, and shellcheck at -S warning is
# a gate here, so `unit` would fail `make lint`.
proc_meminfo_available() {
  local key value _rest
  SAMPLE_MEM_AVAILABLE_BYTES=0
  while read -r key value _rest; do
    if [ "$key" = "MemAvailable:" ]; then
      SAMPLE_MEM_AVAILABLE_BYTES=$((value * 1024))
      return 0
    fi
  done <"$PROC_ROOT/meminfo"
  return 1
}

# host_sampler_tick appends ONE line to $1:
#
#     <cpuFraction> <memAvailableBytes> <pssBytes|-> <processCount|->
#
# "-" marks a tick that did not carry the low-cadence signals; sampler_field skips those,
# which is how pssSamples can legitimately differ from hostCpuSamples in the record.
#
# The CPU fraction is computed in scaled integer arithmetic and the decimal point spliced in
# by `printf -v`, because awk or bc would be a fork per tick. It is clamped to [0, 1]: a
# CPU hotplug or a counter wrap can make the idle delta exceed the total delta, and a
# negative "fraction" would be interpolated straight into the rung's JSON.
host_sampler_tick() {
  local out_file="$1"
  local di dt scaled frac pss proc_count p vmm_pids virtiofsd_pids
  proc_stat_totals || return 1
  di=$((SAMPLE_IDLE - SAMPLE_PREV_IDLE))
  dt=$((SAMPLE_TOTAL - SAMPLE_PREV_TOTAL))
  SAMPLE_PREV_IDLE="$SAMPLE_IDLE"
  SAMPLE_PREV_TOTAL="$SAMPLE_TOTAL"
  scaled=0
  if [ "$dt" -gt 0 ]; then
    scaled=$(((dt - di) * 10000 / dt))
  fi
  [ "$scaled" -ge 0 ] || scaled=0
  [ "$scaled" -le 10000 ] || scaled=10000
  printf -v frac '%d.%04d' "$((scaled / 10000))" "$((scaled % 10000))"
  proc_meminfo_available || SAMPLE_MEM_AVAILABLE_BYTES=0
  SAMPLE_TICK=$((SAMPLE_TICK + 1))
  pss="-"
  proc_count="-"
  # Tick 1 is ALWAYS a low-cadence tick. Otherwise a rung whose window fits in fewer than
  # SAMPLE_LOW_EVERY ticks would record pssSamples=0 and processCountSamples=0 while having
  # CPU samples -- and standbysResident is derived from processCount, so it would have had to
  # fall back to the post-load count, reintroducing exactly the idle reading this fixes.
  if [ "$SAMPLE_TICK" -eq 1 ] || [ $((SAMPLE_TICK % SAMPLE_LOW_EVERY)) -eq 0 ]; then
    vmm_pids="$(discover_pids "$VMM_PROC_PATTERN")"
    virtiofsd_pids="$(discover_pids "$VIRTIOFSD_PROC_PATTERN")"
    # A `die` inside pss_bytes_for_pids exits only this command substitution's subshell, so
    # the assignment lands empty with a non-zero status. Recording "-" for that tick is
    # right: the refusal that matters (spec section 7.3's boxed warning) is enforced by
    # host_signals_snapshot on the post-load path, which run_density_rung checks and dies on.
    # shellcheck disable=SC2086 # word-splitting into pss_bytes_for_pids' "$@" is intended
    pss="$(pss_bytes_for_pids $vmm_pids $virtiofsd_pids)" || pss="-"
    [ -n "$pss" ] || pss="-"
    proc_count=0
    # shellcheck disable=SC2086
    for p in $vmm_pids $virtiofsd_pids; do
      [ -z "$p" ] || proc_count=$((proc_count + 1))
    done
  fi
  printf '%s %s %s %s\n' "$frac" "$SAMPLE_MEM_AVAILABLE_BYTES" "$pss" "$proc_count" >>"$out_file"
}

# host_sampler_loop ticks into $1 until $2 exists, then takes ONE final tick if at least
# SAMPLE_MIN_TICK_MS has elapsed since the last one, and returns. Meant to be backgrounded
# by run_density_rung immediately after wall_t0 and reaped immediately after wall_t1.
#
# It waits in SAMPLE_SLICE_MS slices rather than one SAMPLE_INTERVAL_MS sleep so that the
# stop file is noticed promptly: the final tick then covers at most one slice of post-window
# time, against a window of seconds. That costs one `sleep` fork per slice -- ten a second
# against the ~370 process creations a second issue #291 item 2 removed.
host_sampler_loop() {
  local out_file="$1" stop_file="$2"
  local slices_per_tick slice=0 last_ms slice_s
  slices_per_tick=$((SAMPLE_INTERVAL_MS / SAMPLE_SLICE_MS))
  [ "$slices_per_tick" -ge 1 ] || slices_per_tick=1
  printf -v slice_s '%d.%03d' "$((SAMPLE_SLICE_MS / 1000))" "$((SAMPLE_SLICE_MS % 1000))"
  proc_stat_totals || return 0 # no /proc/stat here: sample nothing rather than lie
  SAMPLE_PREV_IDLE="$SAMPLE_IDLE"
  SAMPLE_PREV_TOTAL="$SAMPLE_TOTAL"
  SAMPLE_TICK=0
  set_epoch_ms
  last_ms="$EPOCH_MS"
  while :; do
    if [ -e "$stop_file" ]; then
      set_epoch_ms
      if [ $((EPOCH_MS - last_ms)) -ge "$SAMPLE_MIN_TICK_MS" ]; then
        host_sampler_tick "$out_file" || true
      fi
      return 0
    fi
    sleep "$slice_s"
    slice=$((slice + 1))
    [ "$slice" -ge "$slices_per_tick" ] || continue
    slice=0
    host_sampler_tick "$out_file" || return 0
    set_epoch_ms
    last_ms="$EPOCH_MS"
  done
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t2-green.log" 2>&1; echo "EXIT:$?"
grep -E 'FAIL|Total failures' "$LOG_DIR/t2-green.log"
shellcheck -x -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t2-sc.log" 2>&1; echo "EXIT:$?"
shellcheck -o check-unassigned-uppercase -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t2-sc2154.log" 2>&1; echo "EXIT:$?"
```

Expected: `Total failures: 0`, exit 0 from both shellcheck runs.

> The `-e "/proc/$sp_loop_pid"` liveness check in the loop test only works on Linux. On
> darwin `/proc` does not exist, so it reads "exited" unconditionally — the assertion is
> weaker there but never wrong, because `wait` has already returned by that point. Do not
> "fix" it with `kill -0`: the pid is this shell's reaped child, so `kill -0` is a race.

- [ ] **Step 6: Commit**

```bash
git add deploy/microvm/e11-density.sh deploy/microvm/tests/e11-density.test.sh
git commit -s -m "feat(e11): add a fork-free in-rung host sampler

The every-tick path reads /proc/stat and /proc/meminfo with the read builtin, keeps
the previous CPU reading in globals so there is no sleep inside a sample, and formats
with printf -v. pgrep plus the smaps_rollup walk runs every Nth tick (and always on
tick 1), because reading 128 rollups a second while measuring a density ceiling would
perturb the thing under test.

Not wired into run_density_rung yet: the converge barrier lands first, or the sampled
window would still contain the git fetch.

Refs #291 item 1.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 3: A converge barrier precedes the timed window (spec §3)

`wall_t0` is stamped at line 901, each slot runs `converge_slot` at 927 _inside_ the timed
window, and `wall_t1` closes at 962 — so the git fetch sits in the throughput denominator.
The header's claim that converge is separated "so a slow fetch cannot misread as a
throughput ceiling" only ever applied to p50/p95. This splits `run_density_rung` into two
phases with a full drain between them.

This must land **before** Task 4 wires the sampler: if the sampled window still contained
converge, the fetch's CPU would land in the Exec window's mean and a fresh artifact would
have been built.

**Files:**

- Modify: `deploy/microvm/e11-density.sh` (new helpers above `converge_slot()` at 650; the phase section of `run_density_rung()`, currently lines 899-969)
- Test: `deploy/microvm/tests/e11-density.test.sh` (new section after the Task 2 section; and **replace** the existing `and every slot's exit status is checked, not discarded by a bare wait` assertion at ~line 688)

**Interfaces:**

- Consumes: `converge_slot`, `grpc_exec_record` and `escaped_mix` (Task 1), `die`, `log`, `E11_TMPDIR`, `RESULTS`.
- Produces:
  - `slot_run_id <arm> <d> <ram_mb> <c> <i>` — prints `e11-<arm>-d<d>-ram<ram_mb>-c<c>-slot<i>`.
  - `slot_workspace_key <arm> <run_id>` — prints `run_id` on the `microvm` arm, nothing otherwise.
  - `slot_req_base <i>` — prints `i * 1000000`.

- [ ] **Step 1: Write the failing tests**

First **replace** this existing assertion (in the
`echo "== a FAILED converge is not recorded as a fast converge"` block):

```bash
check "and every slot's exit status is checked, not discarded by a bare wait" \
  "$(grep -c 'wait "\$pid" || slot_failures=' "$SCRIPT")" "1"
```

with:

```bash
# Two wait loops since the converge barrier landed (#291 item 3): one per phase, each
# checking every slot's status. A bare `wait` in either would discard the reason a slot
# failed.
check "the converge phase checks every slot's exit status, not a bare wait" \
  "$(grep -c 'wait "\$pid" || converge_failures=' "$SCRIPT")" "1"
check "the timed phase checks every slot's exit status too" \
  "$(grep -c 'wait "\$pid" || exec_failures=' "$SCRIPT")" "1"
```

Then append a new section:

```bash
# ---------------------------------------------------------------------------
# Issue #291 item 3: converge is out of the throughput denominator.
#
# wall_t0 was stamped, then each slot ran converge_slot -- a git fetch -- and only then its
# Exec loop, and wall_t1 closed after all of it. throughput = successful Execs / wall
# seconds, so a slow fetch WAS a throughput ceiling, on both arms, by construction. The
# header's claim that converge is timed separately was true only of p50/p95.
#
# run_density_rung now runs two phases with a full drain between them. Each slot's run_id,
# workspace_key and req_base are deterministic in (arm, d, ram_mb, c, i), so phase 2
# recomputes them and lands on the workspace phase 1 prepared, and req_id spaces stay
# disjoint across the barrier.
# ---------------------------------------------------------------------------
echo "== the timed window starts AFTER every slot has converged (#291 item 3)"

bar_rdr="$(extract_fn run_density_rung || true)"
check "run_density_rung is still extractable after the phase split" \
  "$([ -n "$bar_rdr" ] && echo yes || echo no)" "yes"

if [ -n "$bar_rdr" ]; then
  bar_line() { printf '%s\n' "$bar_rdr" | grep -n -- "$1" | head -n1 | cut -d: -f1; }
  bar_conv="$(bar_line 'converge_slot ')"
  bar_conv_wait="$(bar_line 'wait "\$pid" || converge_failures=')"
  bar_t0="$(bar_line 'wall_t0="')"
  bar_exec="$(bar_line 'grpc_exec_record ')"
  bar_t1="$(bar_line 'wall_t1="')"
  for pair in "converge_slot:$bar_conv" "converge wait:$bar_conv_wait" "wall_t0:$bar_t0" \
    "grpc_exec_record:$bar_exec" "wall_t1:$bar_t1"; do
    check "the ${pair%%:*} line is present in run_density_rung" \
      "$([ -n "${pair##*:}" ] && echo yes || echo no)" "yes"
  done
  if [ -n "$bar_conv" ] && [ -n "$bar_conv_wait" ] && [ -n "$bar_t0" ] && [ -n "$bar_exec" ] && [ -n "$bar_t1" ]; then
    check "converge_slot runs before the converge phase is drained" \
      "$([ "$bar_conv" -lt "$bar_conv_wait" ] && echo yes || echo no)" "yes"
    check "the converge phase is drained BEFORE wall_t0 is stamped (the barrier)" \
      "$([ "$bar_conv_wait" -lt "$bar_t0" ] && echo yes || echo no)" "yes"
    check "wall_t0 is stamped before the first Exec is issued" \
      "$([ "$bar_t0" -lt "$bar_exec" ] && echo yes || echo no)" "yes"
    check "wall_t1 closes after the last Exec" \
      "$([ "$bar_exec" -lt "$bar_t1" ] && echo yes || echo no)" "yes"
    check "no converge_slot call remains between wall_t0 and wall_t1" \
      "$(printf '%s\n' "$bar_rdr" | awk -v a="$bar_t0" -v b="$bar_t1" 'NR>a && NR<b' | grep -c 'converge_slot ')" "0"
  fi
  check "both phases derive the run id from ONE helper, so they cannot drift" \
    "$(printf '%s\n' "$bar_rdr" | grep -c 'slot_run_id ')" "2"
  check "both phases derive the req_id base from ONE helper" \
    "$(printf '%s\n' "$bar_rdr" | grep -c 'slot_req_base ')" "2"
fi

echo "== the slot-identity helpers are deterministic in (arm, d, ram_mb, c, i)"
id_body="$(extract_fns slot_run_id slot_workspace_key slot_req_base || true)"
check "the slot-identity helpers are extractable" \
  "$([ -n "$id_body" ] && echo yes || echo no)" "yes"
if [ -n "$id_body" ]; then
  id_snippet="$(mktemp -d)/id.sh"
  printf '%s\n' "$id_body" >"$id_snippet"
  idf() {
    (
      # shellcheck disable=SC1090
      . "$id_snippet"
      "$@"
    )
  }
  check "slot_run_id is the documented shape" \
    "$(idf slot_run_id microvm 2 256 8 3)" "e11-microvm-d2-ram256-c8-slot3"
  check "slot_run_id is deterministic (same args, same id)" \
    "$([ "$(idf slot_run_id microvm 2 256 8 3)" = "$(idf slot_run_id microvm 2 256 8 3)" ] && echo yes || echo no)" "yes"
  check "slot_run_id distinguishes slots, so two slots cannot share a workspace" \
    "$([ "$(idf slot_run_id microvm 2 256 8 3)" != "$(idf slot_run_id microvm 2 256 8 4)" ] && echo yes || echo no)" "yes"
  check "the microvm arm gets a non-empty workspace_key (it REFUSES an empty one)" \
    "$(idf slot_workspace_key microvm e11-x-slot1)" "e11-x-slot1"
  check "the container arm gets an empty workspace_key (today's shared workspace)" \
    "$(idf slot_workspace_key container e11-x-slot1)" ""
  check "the driver-control arm follows the container path" \
    "$(idf slot_workspace_key driver-control e11-x-slot1)" ""
  check "slot_req_base spaces slots a million apart" "$(idf slot_req_base 3)" "3000000"
  check "  ...so no two slots' req_id ranges can overlap at any sane ITERS_PER_SLOT" \
    "$([ "$(idf slot_req_base 4)" -gt "$(($(idf slot_req_base 3) + 100000))" ] && echo yes || echo no)" "yes"
  rm -rf "$(dirname "$id_snippet")"
fi

echo "== a converge failure in phase 1 refuses the rung, and phase 2 never starts"
# The barrier's whole point, EXECUTED rather than grepped: the real run_density_rung is run
# with converge_slot and grpc_exec_record stubbed, so the assertion is about the real
# control flow. A marker file records whether any Exec was issued at all.
bar_body="$(extract_fns die log require_numeric json_escape e11_tool_call_mix escaped_mix slot_run_id slot_workspace_key slot_req_base run_density_rung || true)"
check "run_density_rung is extractable together with its slot helpers" \
  "$([ -n "$bar_body" ] && echo yes || echo no)" "yes"

if [ -n "$bar_body" ]; then
  bar_tmpdir="$(mktemp -d)"
  bar_probe="$bar_tmpdir/probe.sh"
  mkdir -p "$bar_tmpdir/results" "$bar_tmpdir/tmp"
  {
    echo 'set -uo pipefail'
    printf '%s\n' "$bar_body"
    # Stubs, defined AFTER the real functions so they win.
    echo 'assert_relay_alive() { :; }'
    echo 'converge_slot() { echo 5; return "$BAR_CONVERGE_RC"; }'
    echo 'grpc_exec_record() { : >"$BAR_MARKER"; echo "1 ok -" >>"$6"; }'
    echo 'host_sampler_loop() { :; }'
    echo 'percentile() { echo 1; }'
    echo 'run_density_rung "$@"'
  } >"$bar_probe"

  bar_env() {
    env BAR_CONVERGE_RC="$1" BAR_MARKER="$bar_tmpdir/exec-was-issued" \
      E11_TMPDIR="$bar_tmpdir/tmp" RESULTS="$bar_tmpdir/results" \
      ITERS_PER_SLOT=1 WARMUP_PER_SLOT=0 COLD_LATENCY_MS=50 \
      SUBSTRATE=nested-m8i REPO_CACHE_SHAPE=accept-cold-fetch \
      PROC_ROOT="$bar_tmpdir/proc" VMM_PROC_PATTERN=__none__ VIRTIOFSD_PROC_PATTERN=__none__ \
      SAMPLE_INTERVAL_MS=1000 SAMPLE_SLICE_MS=100 SAMPLE_MIN_TICK_MS=200 SAMPLE_LOW_EVERY=5 \
      EXEC_MAX_TIME_S=45 PROTO_IMPORT_PATH=/tmp PROTO_REL_PATH=x.proto \
      bash "$bar_probe" container - - 2 e11-test 8444 "$bar_tmpdir/out.json"
  }

  rm -f "$bar_tmpdir/exec-was-issued"
  bar_fail_rc=0
  bar_fail_out="$(bar_env 1 2>&1)" || bar_fail_rc=$?
  check "a converge failure in phase 1 makes the rung exit NONZERO" \
    "$([ "$bar_fail_rc" -ne 0 ] && echo yes || echo no)" "yes"
  case "$bar_fail_out" in *"slot(s) fail before their timed loop"*) bar_named=yes ;; *) bar_named=no ;; esac
  check "  ...with the refusal that names the rung and the count" "$bar_named" "yes"
  check "  ...and NOT ONE Exec was issued: the barrier held" \
    "$([ -e "$bar_tmpdir/exec-was-issued" ] && echo issued || echo none)" "none"
  check "  ...and no rung record was written" \
    "$([ -s "$bar_tmpdir/out.json" ] && echo wrote || echo nothing)" "nothing"

  # NON-VACUOUSNESS: with converge SUCCEEDING, the same probe does reach phase 2. Without
  # this, "none" above could mean the probe never ran at all. Only the marker is asserted --
  # the probe is free to die later, in the record writer it has no real inputs for.
  rm -f "$bar_tmpdir/exec-was-issued" "$bar_tmpdir/out.json"
  bar_env 0 >/dev/null 2>&1 || true
  check "non-vacuousness: with converge succeeding, phase 2 DOES issue Execs" \
    "$([ -e "$bar_tmpdir/exec-was-issued" ] && echo issued || echo none)" "issued"

  rm -rf "$bar_tmpdir"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t3-red.log" 2>&1; echo "EXIT:$?"
grep FAIL "$LOG_DIR/t3-red.log" | head -20
```

Expected: the slot-identity helpers are not extractable, the two named `wait` loops are
absent (count 0 where 1 is wanted), and `the converge phase is drained BEFORE wall_t0 is
stamped` FAILs — the current order is `wall_t0` then `converge_slot`.

- [ ] **Step 3: Add the slot-identity helpers**

In `deploy/microvm/e11-density.sh`, immediately above `converge_slot()` (line 650), insert:

```bash
# ---------------------------------------------------------------------------
# Slot identity (issue #291 item 3). Phase 2 RECOMPUTES a slot's identity rather than
# inheriting it from phase 1 -- the two phases are different subshells -- so all three
# derivations live in one place each and cannot drift into two slots sharing a workspace or
# a req_id space.
# ---------------------------------------------------------------------------
slot_run_id() {
  printf 'e11-%s-d%s-ram%s-c%s-slot%s' "$1" "$2" "$3" "$4" "$5"
}

# The microvm arm REFUSES an empty workspace_key (proto/sandbox/v1/sandbox.proto's own doc
# comment on Exec.workspace_key); the container arm may omit it, which means today's single
# shared workspace. The driver-control arm follows the container path.
slot_workspace_key() {
  local arm="$1" run_id="$2"
  case "$arm" in
  microvm) printf '%s' "$run_id" ;;
  *) : ;;
  esac
}

# A DISJOINT req_id space per slot, base 1000000 apart. Every slot in a rung talks to ONE
# shared sandbox_id and the relay demultiplexes responses BY req_id, so uniqueness is the
# caller's job: two concurrent Execs sharing a req_id collide, and on the validation rig one
# of the pair got the other's chunks and hung for 33 minutes. Converge uses the base itself
# and the Exec mix counts up from it, and phase 1 drains fully before phase 2 issues
# anything, so the collision cannot recur across the barrier either.
slot_req_base() {
  echo $(($1 * 1000000))
}
```

- [ ] **Step 4: Split `run_density_rung` into two phases**

Replace lines 899-969 — from `local wall_t0 wall_t1 pids=()` through the
`wall_s="$(require_numeric wallSeconds ...)" || die ...` block — with:

```bash
  # ---------------------------------------------------------------------------
  # PHASE 1: converge, OUTSIDE the timed window (issue #291 item 3).
  #
  # Every slot converges and exits; all are waited on. A non-zero exit still refuses the
  # rung, preserving the guarantee that a rung whose slots were not all measuring the same
  # thing is never recorded. Nothing here is inside wall_t0..wall_t1, so a slow git fetch can
  # no longer sit in the throughput denominator -- which is what made converge a throughput
  # ceiling on BOTH arms by construction.
  # ---------------------------------------------------------------------------
  local i pids=() pid
  for i in $(seq 1 "$c"); do
    (
      local run_id wskey cms cms_rc=0
      run_id="$(slot_run_id "$arm" "$d" "$ram_mb" "$c" "$i")"
      wskey="$(slot_workspace_key "$arm" "$run_id")"
      cms="$(converge_slot "$relay_port" "$sandbox_id" "$wskey" "$run_id" "$(slot_req_base "$i")")" || cms_rc=$?
      echo "$cms" >>"$converge_file"
      if [ "$cms_rc" -ne 0 ]; then
        echo "e11: slot $i: converge FAILED after ${cms}ms (see $RESULTS/e11-converge.log) - its workspace was never prepared, so its Exec timings would measure something else" >&2
        exit 1
      fi
    ) &
    pids+=("$!")
  done
  local converge_failures=0
  for pid in "${pids[@]}"; do
    wait "$pid" || converge_failures=$((converge_failures + 1))
  done
  [ "$converge_failures" -eq 0 ] ||
    die "rung arm=$arm d=$d ram=${ram_mb}MiB c=$c had $converge_failures of $c slot(s) fail before their timed loop (the reason is above, and in $RESULTS/e11-converge.log) - refusing to record a rung whose slots were not all measuring the same thing"

  # ---------------------------------------------------------------------------
  # Payload construction, still BEFORE timing starts (issue #291 item 2). This block MOVES
  # here from just above wall_t0, where Task 1 put it -- spec section 1: "pre-escape the 7 mix
  # commands and the slot's workspace_key once per slot, before timing starts". The
  # derivations now go through the same helpers phase 1 uses, so the two cannot drift.
  # ---------------------------------------------------------------------------
  local -a mix_json=() ws_json_by_slot=()
  mapfile -t mix_json < <(escaped_mix)
  [ "${#mix_json[@]}" -gt 0 ] ||
    die "rung arm=$arm d=$d ram=${ram_mb}MiB c=$c: escaped_mix produced no commands, so every slot would loop forever issuing no Execs"
  local run_id_i
  for i in $(seq 1 "$c"); do
    run_id_i="$(slot_run_id "$arm" "$d" "$ram_mb" "$c" "$i")"
    ws_json_by_slot[i]="$(json_escape "$(slot_workspace_key "$arm" "$run_id_i")")"
  done

  # ---------------------------------------------------------------------------
  # PHASE 2: the timed Exec loop, and nothing else.
  # ---------------------------------------------------------------------------
  local wall_t0 wall_t1
  wall_t0="$(date +%s%N)"
  pids=()
  for i in $(seq 1 "$c"); do
    (
      # No run_id or workspace_key derivation in here: phase 2 needs only the pre-escaped key
      # and the req_id base, so nothing that forks happens inside the timed window.
      local req_base req
      req_base="$(slot_req_base "$i")"
      req="$req_base"

      local times_file="$slot_dir/slot-$i.times" err_log="$slot_dir/slot-$i.err"
      # Pre-escaped above, before wall_t0. Parameter expansion, not a command substitution:
      # `local x="$(...)"` would trip SC2155, which is a WARNING and so a lint failure here.
      local ws_json="${ws_json_by_slot[$i]}"
      : >"$times_file"
      : >"$err_log"
      # A shell counter, not `wc -l` twice per Exec: the timed loop is this file's only
      # writer, so the count is known without reading it back. `for mi in` over the array
      # pre-escaped above also removes the process-substitution subshell the inner
      # `while read` re-spawned on every pass over the mix.
      local want=$((ITERS_PER_SLOT + WARMUP_PER_SLOT)) issued=0 mi
      while [ "$issued" -lt "$want" ]; do
        for mi in "${!mix_json[@]}"; do
          req=$((req + 1))
          grpc_exec_record "$relay_port" "$sandbox_id" "$ws_json" "${mix_json[$mi]}" "$req" "$times_file" "$err_log"
          issued=$((issued + 1))
          [ "$issued" -ge "$want" ] && break
        done
      done
    ) &
    pids+=("$!")
  done
  local exec_failures=0
  for pid in "${pids[@]}"; do
    wait "$pid" || exec_failures=$((exec_failures + 1))
  done
  wall_t1="$(date +%s%N)"
  [ "$exec_failures" -eq 0 ] ||
    die "rung arm=$arm d=$d ram=${ram_mb}MiB c=$c had $exec_failures of $c slot(s) fail inside the timed loop - refusing to record a rung whose slots were not all measuring the same thing"
  local wall_s
  wall_s="$(require_numeric wallSeconds "$(awk -v ns=$((wall_t1 - wall_t0)) 'BEGIN{printf "%.4f", ns/1000000000.0}')")" ||
    die "rung arm=$arm c=$c could not measure its own wall time (see the refusal above) - throughput is derived from it, so there is nothing to record"
```

This step **moves** Task 1's work rather than duplicating it: Task 1's pre-escape block
lands between the two phases (still before `wall_t0`), its inline run-id derivation is
replaced by the three helpers, and the Exec loop body moves into phase 2's subshell unchanged
except for losing the `run_id`/`wskey` lines it no longer needs. When you are done there must
be exactly ONE `mapfile -t mix_json`, ONE `while [ "$issued"` loop, and ONE `wall_t0=` in the
function — grep for each. `wall_t1` is stamped _before_ the `exec_failures` refusal so a
partial rung still has a measured window to report in the refusal path; the refusal then
discards it.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t3-green.log" 2>&1; echo "EXIT:$?"
grep -E 'FAIL|Total failures' "$LOG_DIR/t3-green.log"
shellcheck -x -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t3-sc.log" 2>&1; echo "EXIT:$?"
shellcheck -o check-unassigned-uppercase -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t3-sc2154.log" 2>&1; echo "EXIT:$?"
```

Expected: `Total failures: 0`, exit 0 from both shellcheck runs.

- [ ] **Step 6: Commit**

```bash
git add deploy/microvm/e11-density.sh deploy/microvm/tests/e11-density.test.sh
git commit -s -m "fix(e11): put a converge barrier before the timed window

wall_t0 was stamped, then every slot ran converge_slot -- a git fetch -- inside the
window wall_t1 closed, and throughput is successful Execs over those wall seconds. So
converge WAS a throughput ceiling on both arms by construction; the header's claim
that it is timed separately held only for p50/p95.

run_density_rung now converges every slot, drains, stamps wall_t0, and only then runs
the Exec loop. Slot identity is recomputed from three shared helpers, so phase 2 lands
on the workspace phase 1 prepared and req_id spaces stay disjoint across the barrier.

Refs #291 item 3.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 4: Wire the sampler into the rung, and the record schema (spec §2 second half, §5)

The sampler brackets exactly `wall_t0`..`wall_t1`, is reaped before aggregation, and its
mean/peak/min/count go into the record. `hostCpuFraction` — the field `crosses('cpu')`
already reads — becomes the **mean** over the timed window, because scoring a sealed
prediction off a single one-second peak (a GC pause, a `drop_caches`, an unrelated process
on a shared box) would be the same class of error as the artifact being fixed, pointed the
other way. Peak is still recorded, so nothing is lost. The post-load snapshot is **kept**
under explicitly different names, so an idle reading can never again pass as an under-load
one.

**Files:**

- Modify: `deploy/microvm/e11-density.sh` (`cleanup_on_exit()` at 257; new aggregation helpers after `host_sampler_loop`; the signals + record-writer section of `run_density_rung()`, currently lines 1029-1160)
- Test: `deploy/microvm/tests/e11-density.test.sh` (new `sampler_field` section; **edit** the `run_writer` fixture at ~line 487; **edit** the trap probe at ~line 823; **edit** the `VIRTIOFSD_PROC_PATTERN` count at ~line 1029)

**Interfaces:**

- Consumes: `host_sampler_loop` / `host_sampler_tick` (Task 2), `require_numeric`, `host_signals_snapshot`, `die`, the barrier's `wall_t0` / `wall_t1` (Task 3).
- Produces:
  - `sampler_field <file> <col> <stat> [fmt]` — `stat` is `mean|peak|min|count`; `fmt` is a printf format, default `%.4f`. Skips `-` cells. Returns non-zero when the file is empty or the column has no numeric cell (except `count`, which prints `0`).
  - `host_cpu_count` — prints the online CPU count, `1` if it cannot be determined.
  - `stop_host_sampler` — kills `$E11_SAMPLER_PID` if set; safe from the EXIT trap.

- [ ] **Step 1: Write the failing tests**

**(a)** Append a new `sampler_field` section:

```bash
echo "== sampler_field's arithmetic over a fixed synthetic sample file (#291 item 1)"
sf_body="$(extract_fns sampler_field host_cpu_count || true)"
check "sampler_field and host_cpu_count are extractable" \
  "$([ -n "$sf_body" ] && echo yes || echo no)" "yes"

if [ -n "$sf_body" ]; then
  sf_tmpdir="$(mktemp -d)"
  sf_snippet="$sf_tmpdir/sf.sh"
  printf '%s\n' "$sf_body" >"$sf_snippet"
  # Three ticks. Ticks 1 and 3 carry the low-cadence signals; tick 2 does not, and its "-"
  # cells must be SKIPPED rather than read as zero -- a 0 in a mean is a claim, an absent
  # sample is not.
  sf_file="$sf_tmpdir/samples"
  {
    echo '0.1000 8000000000 524288 2'
    echo '0.5000 4000000000 - -'
    echo '0.9000 6000000000 1048576 4'
  } >"$sf_file"
  sf() {
    (
      # shellcheck disable=SC1090
      . "$sf_snippet"
      sampler_field "$sf_file" "$1" "$2" "${3:-%.4f}"
    )
  }
  check "cpu mean over 3 ticks" "$(sf 1 mean)" "0.5000"
  check "cpu peak" "$(sf 1 peak)" "0.9000"
  check "cpu min" "$(sf 1 min)" "0.1000"
  check "cpu sample count" "$(sf 1 count '%d')" "3"
  check "memAvailable mean, as an integer" "$(sf 2 mean '%.0f')" "6000000000"
  check "memAvailable min (the only extreme that can indicate pressure)" "$(sf 2 min '%.0f')" "4000000000"
  check "pss mean SKIPS the '-' tick (2 samples, not 3)" "$(sf 3 mean '%.0f')" "786432"
  check "pss peak" "$(sf 3 peak '%.0f')" "1048576"
  check "pss sample count is 2, exposing the reduced cadence" "$(sf 3 count '%d')" "2"
  check "processCount mean, rounded to an integer" "$(sf 4 mean '%.0f')" "3"
  check "processCount peak" "$(sf 4 peak '%.0f')" "4"
  check "processCount sample count" "$(sf 4 count '%d')" "2"

  # An empty file is the ABSENCE of a measurement, not a zero -- same refusal shape as
  # percentile. count prints 0 so the caller can distinguish "no samples" from "failed".
  sf_empty="$sf_tmpdir/empty"
  : >"$sf_empty"
  sf_empty_rc=0
  (
    # shellcheck disable=SC1090
    . "$sf_snippet"
    sampler_field "$sf_empty" 1 mean '%.4f'
  ) >/dev/null 2>&1 || sf_empty_rc=$?
  check "an empty sample file is a refusal, not a 0.0000 mean" \
    "$([ "$sf_empty_rc" -ne 0 ] && echo yes || echo no)" "yes"

  # A column that is "-" on EVERY tick is likewise absent, not zero.
  sf_alldash="$sf_tmpdir/alldash"
  printf '0.1000 8000000000 - -\n0.2000 8000000000 - -\n' >"$sf_alldash"
  sf_dash_rc=0
  (
    # shellcheck disable=SC1090
    . "$sf_snippet"
    sampler_field "$sf_alldash" 3 mean '%.0f'
  ) >/dev/null 2>&1 || sf_dash_rc=$?
  check "an all-'-' column is a refusal too" \
    "$([ "$sf_dash_rc" -ne 0 ] && echo yes || echo no)" "yes"
  sf_dash_count=$(
    # shellcheck disable=SC1090
    . "$sf_snippet"
    sampler_field "$sf_alldash" 3 count '%d'
  )
  check "  ...while its count is 0, which is what the record shows" "$sf_dash_count" "0"

  sf_ncpu=$(
    # shellcheck disable=SC1090
    . "$sf_snippet"
    host_cpu_count
  )
  check "host_cpu_count prints a positive integer (coresBusy = mean x this)" \
    "$([ "$sf_ncpu" -ge 1 ] 2>/dev/null && echo yes || echo no)" "yes"

  rm -rf "$sf_tmpdir"
fi

echo "== the sampler brackets exactly the timed window, and nothing else (#291 item 1)"
sw_rdr="$(extract_fn run_density_rung || true)"
if [ -n "$sw_rdr" ]; then
  sw_line() { printf '%s\n' "$sw_rdr" | grep -n -- "$1" | head -n1 | cut -d: -f1; }
  sw_t0="$(sw_line 'wall_t0="')"
  sw_start="$(sw_line 'host_sampler_loop ')"
  sw_t1="$(sw_line 'wall_t1="')"
  sw_snap="$(sw_line 'host_signals_snapshot "\$require_vmm"')"
  check "the sampler is started inside run_density_rung" \
    "$([ -n "$sw_start" ] && echo yes || echo no)" "yes"
  if [ -n "$sw_t0" ] && [ -n "$sw_start" ] && [ -n "$sw_t1" ]; then
    check "the sampler starts AFTER wall_t0 (never before the window it describes)" \
      "$([ "$sw_t0" -lt "$sw_start" ] && echo yes || echo no)" "yes"
    check "the sampler starts BEFORE the first Exec is issued" \
      "$([ "$sw_start" -lt "$(sw_line 'grpc_exec_record ')" ] && echo yes || echo no)" "yes"
  fi
  if [ -n "$sw_t1" ] && [ -n "$sw_snap" ]; then
    check "the post-load snapshot is still taken, AFTER wall_t1" \
      "$([ "$sw_t1" -lt "$sw_snap" ] && echo yes || echo no)" "yes"
  fi
  check "the sampler is reaped before aggregation (a wait on its pid)" \
    "$([ "$(printf '%s\n' "$sw_rdr" | grep -c 'wait "\$E11_SAMPLER_PID"')" -ge 1 ] && echo yes || echo no)" "yes"
fi
check "hostCpuFraction is recorded from the sampler's MEAN, not the post-load snapshot" \
  "$([ "$(grep -c "'hostCpuFraction': \$cpu_mean," "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "the post-load snapshot keeps its own four explicitly named fields" \
  "$(grep -cE "'postLoad(HostCpuFraction|MemAvailableBytes|PssBytes|ProcessCount)':" "$SCRIPT")" "4"
check "samplingMode marks these records so they cannot be compared with pre-fix ones" \
  "$(grep -c "'samplingMode': 'in-rung-1hz-mean'," "$SCRIPT")" "1"
check "the reduced PSS/processCount cadence is disclosed in proxyLimitations" \
  "$([ "$(grep -c 'sampled every .* sampler tick' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "a rung with zero host samples is REFUSED, not backfilled from the idle snapshot" \
  "$([ "$(grep -c 'produced ZERO host samples over its timed window' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "standbysResident is derived from the SAMPLED process count, not the post-load one" \
  "$([ "$(grep -c 'standbys_resident=\$((proc_mean > c' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "the sampler is killed from the EXIT trap, so a die mid-rung cannot orphan it" \
  "$([ "$(printf '%s\n' "$(extract_fn cleanup_on_exit)" | grep -c 'stop_host_sampler')" -ge 1 ] && echo yes || echo no)" "yes"
```

**(b)** Edit the existing `run_writer` fixture (in the
`echo "== the rung-record writer, executed with real container-arm inputs"` block).
Replace these two lines:

```bash
      c=1 throughput=0.5000 p95=12 cold_rate=0.0000
      pss_bytes=0 mem_bytes=8388608000 cpu_frac=0.1000 proc_count=0
```

with:

```bash
      c=1 throughput=0.5000 p95=12 cold_rate=0.0000
      # The in-rung sampled signals (#291 item 1). cpu_mean is what crosses('cpu') reads.
      cpu_mean=0.4100 cpu_peak=0.9700 cpu_min=0.0500 cpu_samples=12 cores_busy=29.5200
      mem_mean=8388608000 mem_min=8000000000
      pss_mean=524288 pss_peak=1048576 pss_samples=3
      proc_mean=0 proc_peak=2 proc_samples=3
      # The retained post-load snapshot, under its own names.
      post_cpu=0.0006 post_mem=8388608000 post_pss=0 post_proc=0
      SAMPLE_LOW_EVERY=5
```

And add these assertions immediately after the existing
`check "  ...with the not-applicable dimensions as JSON null, not 0"` line:

```bash
  new_fields_rc=0
  new_fields="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
want = ["hostCpuFraction","hostCpuFractionPeak","hostCpuFractionMin","hostCpuSamples",
        "coresBusy","memAvailableBytes","memAvailableBytesMin","pssBytes","pssBytesPeak",
        "pssSamples","processCount","processCountPeak","processCountSamples","samplingMode",
        "postLoadHostCpuFraction","postLoadMemAvailableBytes","postLoadPssBytes",
        "postLoadProcessCount"]
missing = [k for k in want if k not in d]
print("missing:" + ",".join(missing) if missing else "all-present")
' "$ok_out" 2>&1)" || new_fields_rc=$?
  check "the record carries every field the #291 schema adds" "$new_fields" "all-present"
  check "  ...and json.load accepted it" "$new_fields_rc" "0"
  check "hostCpuFraction in the record is the UNDER-LOAD mean, not the post-load 0.0006" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hostCpuFraction"])' "$ok_out")" "0.41"
  check "  ...and the idle reading is still there, under its own name" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["postLoadHostCpuFraction"])' "$ok_out")" "0.0006"
  check "coresBusy is recorded, because 29.52 cores is legible where 0.41 is not" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["coresBusy"])' "$ok_out")" "29.52"
  check "samplingMode marks how these numbers were taken" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["samplingMode"])' "$ok_out")" "in-rung-1hz-mean"
  check "the PSS/processCount cadence is disclosed in the record's own proxyLimitations" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("yes" if any("sampler tick" in v for v in d["proxyLimitations"].values()) else "no")' "$ok_out")" "yes"
```

**(c)** Edit the trap probe. Replace:

```bash
    echo 'stop_container_stack() { echo container >>"$ORDER"; }'
```

with:

```bash
    echo 'stop_host_sampler() { echo sampler >>"$ORDER"; }'
    echo 'stop_container_stack() { echo container >>"$ORDER"; }'
```

and replace the expected order:

```bash
  check "it kills BOTH arms' stacks (kill before remove, as build-snapshot.sh does)" \
    "$(tr '\n' ' ' <"$tr_order")" "container microvm "
```

with:

```bash
  # The sampler goes FIRST: it is a background subshell that polls for its stop file, so
  # after `rm -rf $E11_TMPDIR` that file can never appear and it would spin forever writing
  # to a deleted path (#291 item 1).
  check "it kills the sampler and BOTH arms' stacks (kill before remove)" \
    "$(tr '\n' ' ' <"$tr_order")" "sampler container microvm "
```

**(d)** Edit the virtiofsd count. Replace:

```bash
check "virtiofsd is still sampled for (summed, can legitimately be 0)" \
  "$(grep -c 'VIRTIOFSD_PROC_PATTERN' "$SCRIPT")" "2"
```

with:

```bash
# Three since the in-rung sampler landed (#291 item 1): the config binding, the post-load
# snapshot, and the sampler's low-cadence tick.
check "virtiofsd is still sampled for (summed, can legitimately be 0)" \
  "$(grep -c 'VIRTIOFSD_PROC_PATTERN' "$SCRIPT")" "3"
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t4-red.log" 2>&1; echo "EXIT:$?"
grep FAIL "$LOG_DIR/t4-red.log" | head -20
```

Expected: `sampler_field` is not extractable, `VIRTIOFSD_PROC_PATTERN` count is 2 not 3,
the writer has no `postLoad*` keys, and the trap order is missing `sampler`.

- [ ] **Step 3: Add `stop_host_sampler` and hook it into the trap**

In the teardown block, add `E11_SAMPLER_PID=""` to the globals declared above the trap
(after `E11_WORKER_BIN=""`), and change `cleanup_on_exit` to:

```bash
cleanup_on_exit() {
  stop_host_sampler || true
  stop_container_stack || true
  stop_microvm_stack || true
  [ -z "${E11_TMPDIR:-}" ] || rm -rf "$E11_TMPDIR"
}
```

Then, immediately after `host_sampler_loop()`, add:

```bash
# stop_host_sampler kills the backgrounded sampler if one is running. It runs FIRST in
# cleanup_on_exit, before the `rm -rf $E11_TMPDIR`, because host_sampler_loop polls for a
# stop file under that root: once the root is gone the file can never appear, and the
# subshell would spin forever appending to a deleted path. `${VAR:-}` because the trap can
# fire before this is ever assigned.
stop_host_sampler() {
  [ -n "${E11_SAMPLER_PID:-}" ] || return 0
  kill "${E11_SAMPLER_PID:-}" 2>/dev/null
  E11_SAMPLER_PID=""
  return 0
}

# sampler_field prints one statistic over one COLUMN of a sampler file. `stat` is
# mean|peak|min|count; `fmt` is a printf format (default %.4f -- pass %.0f for the byte and
# count columns, whose consumers want integers, and whose mean is rounded rather than
# truncated).
#
# Cells holding "-" are SKIPPED, not read as zero: that marker means the tick did not carry
# the low-cadence signals, and a 0 in a mean is a claim about memory while an absent sample
# is not. It is also why pssSamples can legitimately be smaller than hostCpuSamples.
#
# An empty file, or a column with no numeric cell, is the ABSENCE of a measurement and
# returns non-zero rather than printing 0 -- the same refusal percentile makes, for the same
# reason. `count` is the exception: it prints 0, so a caller can tell "no samples" from
# "the aggregation failed".
#
# One awk per statistic per rung, after the sampler has been reaped: nothing here can
# perturb a measurement.
sampler_field() {
  local file="$1" col="$2" stat="$3" fmt="${4:-%.4f}"
  [ -s "$file" ] || {
    [ "$stat" = "count" ] && { echo 0; return 0; }
    return 1
  }
  awk -v col="$col" -v stat="$stat" -v fmt="$fmt" '
    $col != "-" {
      v = $col + 0
      n++
      s += v
      if (n == 1 || v > mx) mx = v
      if (n == 1 || v < mn) mn = v
    }
    END {
      if (stat == "count") { print n + 0; exit 0 }
      if (n == 0) { exit 1 }
      if (stat == "mean") { printf fmt, s / n }
      else if (stat == "peak") { printf fmt, mx }
      else if (stat == "min") { printf fmt, mn }
      else { exit 1 }
    }' "$file"
}

# host_cpu_count prints the online CPU count, for coresBusy. `getconf _NPROCESSORS_ONLN` is
# the portable fallback (it works on darwin, where the test suite runs, and nproc may not
# be installed). One fork per rung.
host_cpu_count() {
  local n=""
  if command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null)" || n=""
  fi
  if [ -z "$n" ]; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null)" || n=""
  fi
  [ -n "$n" ] || n=1
  printf '%s' "$n"
}
```

- [ ] **Step 4: Start and reap the sampler around the timed window**

In `run_density_rung()`, in the PHASE 2 block from Task 3, immediately after
`wall_t0="$(date +%s%N)"` insert:

```bash
  # The sampler brackets EXACTLY this window (issue #291 item 1). It is started after
  # wall_t0 and reaped after wall_t1, and the converge barrier above is what makes that
  # honest: with converge still inside the window, the git fetch's CPU would land in this
  # mean and a fresh artifact would have been built.
  local sampler_file="$E11_TMPDIR/sampler-$rung_tag" sampler_stop="$E11_TMPDIR/sampler-stop-$rung_tag"
  : >"$sampler_file"
  rm -f "$sampler_stop"
  host_sampler_loop "$sampler_file" "$sampler_stop" &
  E11_SAMPLER_PID="$!"
```

and immediately after `wall_t1="$(date +%s%N)"` insert:

```bash
  : >"$sampler_stop"
  wait "$E11_SAMPLER_PID" 2>/dev/null || true
  E11_SAMPLER_PID=""
```

Add `"$sampler_file" "$sampler_stop"` to the `rm -rf` at the end of the function.

- [ ] **Step 5: Aggregate the sampled signals and rename the post-load ones**

Replace the signals block (currently lines 1029-1055, from `local signals pss_bytes
mem_bytes cpu_frac proc_count` through the four `python3 -c` extractions) with:

```bash
  # ---------------------------------------------------------------------------
  # The four host signals, now sampled DURING the window (issue #291 item 1).
  #
  # hostCpuFraction becomes the MEAN. That is not "mean is more representative": with today's
  # idle samples both firstCrossing('cpu') and firstCrossing('memory') are Infinity and
  # scorePrediction1 reads inconclusive, but if CPU crosses 0.9 anywhere while memory and
  # process-count never do, `memOrProcAt <= cpuAt` is false and sealed prediction 1 flips
  # straight to FALSIFIED. Scoring that off a single one-second peak -- a GC pause, a
  # drop_caches, an unrelated process on a shared box -- would be the same class of error as
  # the artifact being fixed, pointed the other way. The mean matches what crosses('cpu')
  # asserts: THIS RUNG WAS CPU-SATURATED, not "this rung once touched saturation". Nothing is
  # lost, because the peak is recorded beside it.
  # ---------------------------------------------------------------------------
  local cpu_samples cpu_mean cpu_peak cpu_min cores_busy ncpu
  local mem_mean mem_min pss_mean pss_peak pss_samples proc_mean proc_peak proc_samples
  cpu_samples="$(require_numeric hostCpuSamples "$(sampler_field "$sampler_file" 1 count '%d')")" ||
    die "rung arm=$arm c=$c could not count its own host samples (see the refusal above)"
  [ "$cpu_samples" -gt 0 ] ||
    die "rung arm=$arm d=$d ram=${ram_mb}MiB c=$c produced ZERO host samples over its timed window ($sampler_file is empty), so it has no under-load hostCpuFraction, memAvailableBytes, pssBytes or processCount at all. Refusing to backfill from the post-load snapshot: that idle reading IS the defect issue #291 item 1 is about, and crosses('cpu') can never fire on one. The window was shorter than ${SAMPLE_MIN_TICK_MS}ms - raise SH_E11_ITERS_PER_SLOT, or lower SH_E11_SAMPLE_INTERVAL_MS and SH_E11_SAMPLE_MIN_TICK_MS."
  cpu_mean="$(require_numeric hostCpuFraction "$(sampler_field "$sampler_file" 1 mean '%.4f')")" ||
    die "rung arm=$arm c=$c: the sampled hostCpuFraction mean failed validation (see above)"
  cpu_peak="$(require_numeric hostCpuFractionPeak "$(sampler_field "$sampler_file" 1 peak '%.4f')")" ||
    die "rung arm=$arm c=$c: hostCpuFractionPeak failed validation (see above)"
  cpu_min="$(require_numeric hostCpuFractionMin "$(sampler_field "$sampler_file" 1 min '%.4f')")" ||
    die "rung arm=$arm c=$c: hostCpuFractionMin failed validation (see above)"
  ncpu="$(host_cpu_count)"
  # coresBusy, because "0.043 cores busy" is a number a human can act on where 0.0006 is not
  # -- and 0.0006 on a 72-cpu host next to ~370 process creations a second is precisely the
  # self-falsifying pair that exposed this bug.
  cores_busy="$(require_numeric coresBusy "$(awk -v m="$cpu_mean" -v n="$ncpu" 'BEGIN{printf "%.4f", m*n}')")" ||
    die "rung arm=$arm c=$c: coresBusy failed validation (see above)"
  mem_mean="$(require_numeric memAvailableBytes "$(sampler_field "$sampler_file" 2 mean '%.0f')")" ||
    die "rung arm=$arm c=$c: the sampled memAvailableBytes mean failed validation (see above)"
  mem_min="$(require_numeric memAvailableBytesMin "$(sampler_field "$sampler_file" 2 min '%.0f')")" ||
    die "rung arm=$arm c=$c: memAvailableBytesMin failed validation (see above)"
  pss_samples="$(require_numeric pssSamples "$(sampler_field "$sampler_file" 3 count '%d')")" ||
    die "rung arm=$arm c=$c: pssSamples failed validation (see above)"
  pss_mean="$(require_numeric pssBytes "$(sampler_field "$sampler_file" 3 mean '%.0f')")" ||
    die "rung arm=$arm d=$d ram=${ram_mb}MiB c=$c sampled $cpu_samples host ticks but not one carried a PSS reading, so Sigma PSS -- the one number spec section 7.3 insists must not be wrong -- has no under-load value for this rung. SH_E11_SAMPLE_LOW_EVERY is ${SAMPLE_LOW_EVERY}; tick 1 always carries it, so an empty column means pss_bytes_for_pids refused on every low-cadence tick (see its own refusals above)."
  pss_peak="$(require_numeric pssBytesPeak "$(sampler_field "$sampler_file" 3 peak '%.0f')")" ||
    die "rung arm=$arm c=$c: pssBytesPeak failed validation (see above)"
  proc_samples="$(require_numeric processCountSamples "$(sampler_field "$sampler_file" 4 count '%d')")" ||
    die "rung arm=$arm c=$c: processCountSamples failed validation (see above)"
  proc_mean="$(require_numeric processCount "$(sampler_field "$sampler_file" 4 mean '%.0f')")" ||
    die "rung arm=$arm c=$c: the sampled processCount mean failed validation (see above)"
  proc_peak="$(require_numeric processCountPeak "$(sampler_field "$sampler_file" 4 peak '%.0f')")" ||
    die "rung arm=$arm c=$c: processCountPeak failed validation (see above)"

  # The POST-LOAD snapshot is KEPT, under explicitly different names. Its refusals are still
  # the ones that matter most: require_vmm=1 on the microvm arm with D >= 1 means at least one
  # standby VMM is necessarily still resident (StandbyIdle is 90s), so zero matching processes
  # means the sampler is looking in the wrong place, not that memory is free. Keeping it under
  # postLoad* names is what makes it impossible for an idle reading to pass as an under-load
  # one ever again.
  local require_vmm=0
  if [ "$arm" = "microvm" ] && [ "$d" != "0" ]; then
    require_vmm=1
  fi
  local signals post_pss post_mem post_cpu post_proc
  signals="$(host_signals_snapshot "$require_vmm")" ||
    die "post-load host signal snapshot failed for rung arm=$arm c=$c (see the refusal above) - refusing to write a rung record from signals that could not be sampled"
  post_pss="$(python3 -c "import json,sys; print(json.load(sys.stdin)['pssBytes'])" <<<"$signals")"
  post_mem="$(python3 -c "import json,sys; print(json.load(sys.stdin)['memAvailableBytes'])" <<<"$signals")"
  post_cpu="$(python3 -c "import json,sys; print(json.load(sys.stdin)['hostCpuFraction'])" <<<"$signals")"
  post_proc="$(python3 -c "import json,sys; print(json.load(sys.stdin)['processCount'])" <<<"$signals")"
```

Note the `require_vmm` block moved _above_ the snapshot call (it was interleaved with the
old comment); the logic is unchanged.

Then in the `standbysResident` block below, change the two lines that read the old
`proc_count` to read the sampled and post-load values respectively:

```bash
  standbys_resident=$((proc_mean > c ? proc_mean - c : 0))
```

and, inside the `if [ "$arm" = "microvm" ]` poll,

```bash
    local waited=0 budget=135 interval=23 last_count="$post_proc" idle_snapshot
```

- [ ] **Step 6: Extend the record writer**

In the `python3 -c "` writer, replace these four lines:

```
  'pssBytes': $pss_bytes,
  'memAvailableBytes': $mem_bytes,
  'hostCpuFraction': $cpu_frac,
  'processCount': $proc_count,
```

with:

```
  # The four RungSample host signals, now sampled DURING the timed window (#291 item 1).
  # Same names, same place in the contract, under-load values.
  'hostCpuFraction': $cpu_mean,
  'memAvailableBytes': $mem_mean,
  'pssBytes': $pss_mean,
  'processCount': $proc_mean,
  # Extremes and sample counts, so a mean can always be checked against what it averaged.
  # hostCpuSamples exposes thin rungs: a mean of 2 samples deserves a visible caveat.
  'hostCpuFractionPeak': $cpu_peak,
  'hostCpuFractionMin': $cpu_min,
  'hostCpuSamples': $cpu_samples,
  'coresBusy': $cores_busy,
  'memAvailableBytesMin': $mem_min,
  'pssBytesPeak': $pss_peak,
  'pssSamples': $pss_samples,
  'processCountPeak': $proc_peak,
  'processCountSamples': $proc_samples,
  # Old and new records both carry hostCpuFraction meaning different things; without this
  # marker someone compares them later and is misled by the fix itself.
  'samplingMode': 'in-rung-1hz-mean',
  # The retained post-load snapshot, explicitly named so an idle reading can never again
  # pass as an under-load one.
  'postLoadHostCpuFraction': $post_cpu,
  'postLoadMemAvailableBytes': $post_mem,
  'postLoadPssBytes': $post_pss,
  'postLoadProcessCount': $post_proc,
```

and add one entry to the `proxyLimitations` dict, after the `standbysResident` line:

```
    'pssBytesCadence': 'pssBytes and processCount are sampled every ${SAMPLE_LOW_EVERY}th sampler tick (and always tick 1), not every tick: pgrep plus an N-file smaps_rollup walk at 1 Hz perturbs the density ceiling being measured. crosses(memory) reads memAvailableBytes, which IS every tick, so the bound classification is unaffected; PSS feeds the narrative. See pssSamples and processCountSamples for the actual counts (#291).',
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t4-green.log" 2>&1; echo "EXIT:$?"
grep -E 'FAIL|Total failures' "$LOG_DIR/t4-green.log"
shellcheck -x -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t4-sc.log" 2>&1; echo "EXIT:$?"
shellcheck -o check-unassigned-uppercase -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t4-sc2154.log" 2>&1; echo "EXIT:$?"
```

Expected: `Total failures: 0`, exit 0 from both shellcheck runs.

- [ ] **Step 8: Commit**

```bash
git add deploy/microvm/e11-density.sh deploy/microvm/tests/e11-density.test.sh
git commit -s -m "fix(e11): sample host signals during the timed window, not after it

host_signals_snapshot ran after every slot subshell had exited and after the
throughput window closed, and host_cpu_fraction then slept one second and diffed
/proc/stat across that window -- so hostCpuFraction, memAvailableBytes and pssBytes
all described a quiesced machine. 0.0006 on a 72-cpu host is 0.043 cores busy, while
the same rung sustained ~41 Exec/sec at ~9 spawns each. And because crosses('cpu')
reads hostCpuFraction >= 0.9, a post-load 0.0006 made the cpu bound structurally
unable to fire at any rung: 'no CPU ceiling was reached' was a restatement of this bug.

hostCpuFraction is now the MEAN over wall_t0..wall_t1, with peak, min and sample count
beside it -- the mean because scoring a sealed prediction off one one-second peak would
be the same class of error pointed the other way. The post-load snapshot is kept under
postLoad* names so an idle reading can never again pass as an under-load one.

Refs #291 item 1.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 5: The null-responder (spec §4, the server half)

A ~60-line Go binary against the existing `gen/go/sandbox/v1` stubs — **no new codegen**.
It serves `SandboxExec` and does nothing, so the third arm measures the driver's own cost.

**Files:**

- Create: `remote-worker/cmd/null-responder/main.go`
- Test: `remote-worker/cmd/null-responder/main_test.go`

**Interfaces:**

- Consumes: `github.com/kagenti/serverless-harness/gen/go/sandbox/v1` — `SandboxExecServer`, `UnimplementedSandboxExecServer`, `RegisterSandboxExecServer`, `ExecRequest`, `ExecEvent`, `ExecEvent_End`, `End{ReqId uint64, ExitCode int32}`, `AbortRequest`, `AbortResponse`.
- Produces, for Task 6: a binary buildable as `go build -o <path> ./cmd/null-responder`, taking `-listen <host:port>` (default `127.0.0.1:8445`), logging one line on startup, refusing a non-loopback address.

- [ ] **Step 1: Write the failing test**

Create `remote-worker/cmd/null-responder/main_test.go`:

```go
package main

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
)

// startResponder serves the real responder on an ephemeral loopback port and returns a
// client for it. Nothing here needs /dev/kvm, a relay, Redis or a worker -- which is the
// point of the control arm.
func startResponder(t *testing.T) pb.SandboxExecClient {
	t.Helper()
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	srv := newServer()
	go func() { _ = srv.Serve(lis) }()
	t.Cleanup(srv.Stop)

	cc, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = cc.Close() })
	return pb.NewSandboxExecClient(cc)
}

// The whole contract of the control arm's server: one End, carrying the request's own
// req_id, exit 0, then the stream ends. e11-density.sh gives every slot a disjoint req_id
// space because the relay demultiplexes by it; a control arm that answered 0 would not
// exercise the same client path.
func TestExecSendsOneEndCarryingTheRequestsReqID(t *testing.T) {
	client := startResponder(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := client.Exec(ctx, &pb.ExecRequest{
		SandboxId: "e11-driver-control",
		Exec:      &pb.Exec{ReqId: 3000001, Command: "true", TimeoutS: 30},
	})
	if err != nil {
		t.Fatalf("Exec: %v", err)
	}

	ev, err := stream.Recv()
	if err != nil {
		t.Fatalf("first Recv: %v", err)
	}
	end := ev.GetEnd()
	if end == nil {
		t.Fatalf("first event was %T, want an End", ev.GetEvent())
	}
	if end.GetReqId() != 3000001 {
		t.Errorf("End.req_id = %d, want the request's own 3000001", end.GetReqId())
	}
	if end.GetExitCode() != 0 {
		t.Errorf("End.exit_code = %d, want 0", end.GetExitCode())
	}

	if _, err := stream.Recv(); !errors.Is(err, io.EOF) {
		t.Errorf("second Recv = %v, want io.EOF (exactly one event, then done)", err)
	}
}

// A missing Exec sub-message must not panic the server: the driver builds the payload by
// string interpolation, so a malformed one is reachable.
func TestExecWithNoExecSubMessageStillEnds(t *testing.T) {
	client := startResponder(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := client.Exec(ctx, &pb.ExecRequest{SandboxId: "e11-driver-control"})
	if err != nil {
		t.Fatalf("Exec: %v", err)
	}
	ev, err := stream.Recv()
	if err != nil {
		t.Fatalf("Recv: %v", err)
	}
	if end := ev.GetEnd(); end == nil || end.GetReqId() != 0 {
		t.Errorf("got %v, want an End with req_id 0", ev.GetEvent())
	}
}

func TestAbortReturnsAnEmptyResponse(t *testing.T) {
	client := startResponder(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := client.Abort(ctx, &pb.AbortRequest{SandboxId: "e11-driver-control", ReqId: 1}); err != nil {
		t.Fatalf("Abort: %v", err)
	}
}

// Loopback is ENFORCED, not merely documented. This server answers every Exec with success
// and no execution, so anything that reached it over a network and believed it would be told
// its commands ran when nothing did.
func TestRequireLoopback(t *testing.T) {
	for _, ok := range []string{"127.0.0.1:8445", "localhost:8445", "[::1]:8445", "127.0.0.2:0"} {
		if err := requireLoopback(ok); err != nil {
			t.Errorf("requireLoopback(%q) = %v, want nil", ok, err)
		}
	}
	for _, bad := range []string{":8445", "0.0.0.0:8445", "10.0.0.5:8445", "example.com:8445", "8445"} {
		err := requireLoopback(bad)
		if err == nil {
			t.Errorf("requireLoopback(%q) = nil, want a refusal", bad)
			continue
		}
		// The refusal must name the address, or an operator cannot see what was wrong.
		if !strings.Contains(err.Error(), bad) {
			t.Errorf("requireLoopback(%q) refusal %q does not name the address", bad, err)
		}
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd remote-worker && go test ./cmd/null-responder/ > "$LOG_DIR/t5-red.log" 2>&1; echo "EXIT:$?"; cd ..
tail -5 "$LOG_DIR/t5-red.log"
```

Expected: build failure — `no Go files in .../cmd/null-responder` (the package does not
exist yet).

- [ ] **Step 3: Write the implementation**

Create `remote-worker/cmd/null-responder/main.go`:

```go
// Command null-responder is E11's DRIVER-OVERHEAD CONTROL (issue #291 section 4).
//
// It serves sandbox.v1.SandboxExec and does nothing: Exec sends one
// End{req_id, exit_code: 0} and returns, Abort returns an empty response. There is no relay,
// no Redis, no worker, no VMM and no command execution -- start_null_stack in
// deploy/microvm/e11-density.sh is just this binary.
//
// e11-density.sh drives the IDENTICAL run_density_rung against it as a third arm
// ("driver-control", on by default), so subtracting that arm at each c gives the driver's
// own contribution to observed latency. That number decides whether item 3 of the issue -- a
// persistent-connection Go client replacing grpcurl -- is needed before an authoritative
// metal run: grpcurl still re-parses the proto and opens a fresh connection per call, and if
// that residue dominates at high c, a fixed-but-still-grpcurl driver would show a knee that
// is STILL an artifact. Committing to item 3 before measuring it would be a guess.
//
// Built against the existing gen/go/sandbox/v1 stubs. No new codegen.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"

	"google.golang.org/grpc"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
)

type responder struct {
	pb.UnimplementedSandboxExecServer
}

// Exec answers with one End and returns. The request's own req_id is ECHOED rather than
// zeroed: the relay demultiplexes responses by req_id, which is why e11-density.sh gives
// every slot a disjoint req_id space (two concurrent Execs sharing one collided on the
// validation rig and hung for 33 minutes). A control arm that always answered 0 would not
// exercise the same client-side path the real arms do.
func (responder) Exec(req *pb.ExecRequest, stream grpc.ServerStreamingServer[pb.ExecEvent]) error {
	var reqID uint64
	if e := req.GetExec(); e != nil {
		reqID = e.GetReqId()
	}
	return stream.Send(&pb.ExecEvent{
		Event: &pb.ExecEvent_End{End: &pb.End{ReqId: reqID, ExitCode: 0}},
	})
}

func (responder) Abort(context.Context, *pb.AbortRequest) (*pb.AbortResponse, error) {
	return &pb.AbortResponse{}, nil
}

func newServer() *grpc.Server {
	srv := grpc.NewServer()
	pb.RegisterSandboxExecServer(srv, responder{})
	return srv
}

// requireLoopback refuses any listen address that is not on this host. This is a refusal
// rather than a comment because the server answers EVERY Exec with success and no
// execution: anything that reached it over a network and believed it would be told its
// commands ran when nothing did.
func requireLoopback(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("listen address %q is not host:port: %w", addr, err)
	}
	if host == "" {
		return fmt.Errorf("listen address %q has no host part, which binds every interface - the null-responder answers every Exec with success and no execution, so it must never be reachable off this host (issue #291 section 4)", addr)
	}
	if host == "localhost" {
		return nil
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		return nil
	}
	return fmt.Errorf("listen address %q is not loopback - the null-responder answers every Exec with success and no execution, so it must never be reachable off this host (issue #291 section 4)", addr)
}

func main() {
	addr := flag.String("listen", "127.0.0.1:8445", "loopback host:port to serve sandbox.v1.SandboxExec on")
	flag.Parse()

	if err := requireLoopback(*addr); err != nil {
		log.Fatalf("null-responder: %v", err)
	}
	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("null-responder: listen %s: %v", *addr, err)
	}
	log.Printf("null-responder: serving sandbox.v1.SandboxExec on %s (E11 driver-control arm, issue #291)", lis.Addr())
	if err := newServer().Serve(lis); err != nil {
		log.Fatalf("null-responder: serve: %v", err)
	}
}
```

- [ ] **Step 4: Run the test to verify it passes, and the Go gates**

```bash
cd remote-worker && go test ./cmd/null-responder/ > "$LOG_DIR/t5-green.log" 2>&1; echo "EXIT:$?"
gofmt -l . > "$LOG_DIR/t5-gofmt.log" 2>&1; echo "GOFMT:$(wc -l < "$LOG_DIR/t5-gofmt.log")"
go vet ./cmd/null-responder/ > "$LOG_DIR/t5-vet.log" 2>&1; echo "VET:$?"
go build -o /tmp/null-responder ./cmd/null-responder; echo "BUILD:$?"; cd ..
```

Expected: `EXIT:0`, `GOFMT:0` (empty — CI fails on any listed file), `VET:0`, `BUILD:0`.

- [ ] **Step 5: Commit**

```bash
git add remote-worker/cmd/null-responder/
git commit -s -m "feat(e11): add the null-responder for the driver-control arm

Serves sandbox.v1.SandboxExec against the existing gen/go stubs and does nothing: Exec
sends one End{req_id, exit_code: 0} and returns, Abort returns empty. No relay, no
Redis, no worker, no codegen.

e11-density.sh will drive the identical run_density_rung against it, so subtracting
that arm at each c gives the driver's own contribution -- the number that decides
whether replacing grpcurl with a persistent-connection Go client is required before an
authoritative metal run.

Loopback is enforced rather than documented: this answers every Exec with success and
no execution.

Refs #291 section 4.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 6: The `driver-control` arm (spec §4, the driver half)

A third arm drives the identical `run_density_rung` against the null-responder with no relay,
no Redis and no worker. It runs **by default** — the control whose absence let this artifact
through should not be opt-in.

**Files:**

- Modify: `deploy/microvm/e11-density.sh` (config block; teardown globals + `cleanup_on_exit()`; new `validate_arms()`; `preflight()`; `shuffle_e11_arms()` at 750; new `start_null_stack()` / `stop_null_stack()` after `stop_microvm_stack()` at 859; the `relay_log` selection in `run_density_rung()`; `main()`)
- Test: `deploy/microvm/tests/e11-density.test.sh` (new section; **edit** the trap probe again)

**Interfaces:**

- Consumes: `run_density_rung` (Tasks 1-4), `wait_for_relay_port`, `die`, `log`, `assemble_ladder`, and the `./cmd/null-responder` binary from Task 5.
- Produces: `E11_ARMS` array, `NULL_RESPONDER_PORT`, `validate_arms`, `start_null_stack`, `stop_null_stack`.

- [ ] **Step 1: Write the failing tests**

Append a new section:

```bash
# ---------------------------------------------------------------------------
# Issue #291 section 4: the driver-overhead control arm.
#
# The whole reason this artifact survived a metal run is that there was no arm whose latency
# was known to be all driver. A third arm drives the IDENTICAL run_density_rung against
# remote-worker/cmd/null-responder -- one End per Exec, no relay, no Redis, no worker, no VMM
# -- so subtracting it at each c gives the driver's own contribution. If that share is large
# at high c, a fixed-but-still-grpcurl driver would show a knee that is STILL an artifact and
# item 3 of the issue becomes mandatory before the authoritative run.
#
# It is ON BY DEFAULT, opt-out. A control that has to be remembered is a control that will not
# be run.
# ---------------------------------------------------------------------------
echo "== the driver-control arm runs by default and is driven by the same function (#291 section 4)"
check "SH_E11_ARMS defaults to all three arms, control included" \
  "$([ "$(grep -c 'SH_E11_ARMS:-container microvm driver-control' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "main() drives the control arm through run_density_rung, not a second function" \
  "$(grep -v '^[[:space:]]*#' "$SCRIPT" | grep -c 'run_density_rung driver-control')" "1"
check "no arm-specific Exec-driving function was added for it" \
  "$(grep -Ec '^run_density_rung_(container|microvm|driver_control|control)\(\)' "$SCRIPT")" "0"
check "the control arm's stack is ONLY the null-responder (no redis, no relay, no worker)" \
  "$(printf '%s\n' "$(extract_fn start_null_stack)" | grep -cE 'start_redis_loopback|sandbox-relay|cmd/worker|cmd/microvm-worker')" "0"
check "  ...and it builds the binary Task 5 added" \
  "$([ "$(printf '%s\n' "$(extract_fn start_null_stack)" | grep -c 'go build -o "\$E11_NULL_BIN" ./cmd/null-responder')" -ge 1 ] && echo yes || echo no)" "yes"
check "  ...on loopback only" \
  "$([ "$(printf '%s\n' "$(extract_fn start_null_stack)" | grep -c -- '-listen "127.0.0.1:')" -ge 1 ] && echo yes || echo no)" "yes"
check "  ...and waits for it to listen rather than sleeping and hoping" \
  "$([ "$(printf '%s\n' "$(extract_fn start_null_stack)" | grep -c 'wait_for_relay_port')" -ge 1 ] && echo yes || echo no)" "yes"
check "the control arm is torn down from the EXIT trap like the others" \
  "$([ "$(printf '%s\n' "$(extract_fn cleanup_on_exit)" | grep -c 'stop_null_stack')" -ge 1 ] && echo yes || echo no)" "yes"
check "analyze_slice is SKIPPED for the control arm (a ladder with no cold acquires)" \
  "$([ "$(grep -c 'analyze_slice skipped' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "  ...but its ladder is still assembled, because the subtraction needs it" \
  "$(grep -c 'e11-ladder-driver-control.json' "$SCRIPT")" "2"

echo "== only the three named arms validate, and shuffling covers whatever is configured"
arms_body="$(extract_fns die validate_arms shuffle_e11_arms || true)"
check "validate_arms is extractable" "$([ -n "$arms_body" ] && echo yes || echo no)" "yes"
if [ -n "$arms_body" ]; then
  arms_tmpdir="$(mktemp -d)"
  arms_snippet="$arms_tmpdir/arms.sh"
  printf '%s\n' "$arms_body" >"$arms_snippet"
  run_arms() {
    (
      read -r -a E11_ARMS <<<"$1"
      # shellcheck disable=SC1090
      . "$arms_snippet"
      validate_arms
    )
  }
  for good in "container" "microvm" "driver-control" "container microvm driver-control" "microvm driver-control"; do
    arms_rc=0
    run_arms "$good" >/dev/null 2>&1 || arms_rc=$?
    check "SH_E11_ARMS='$good' validates" "$arms_rc" "0"
  done
  arms_bad_rc=0
  arms_bad_out="$(run_arms "container cloud-hypervisor" 2>&1)" || arms_bad_rc=$?
  check "an invented arm is refused (nonzero)" \
    "$([ "$arms_bad_rc" -ne 0 ] && echo yes || echo no)" "yes"
  case "$arms_bad_out" in *cloud-hypervisor*) arms_named=yes ;; *) arms_named=no ;; esac
  check "  ...and the refusal names the bad value" "$arms_named" "yes"
  arms_empty_rc=0
  run_arms "" >/dev/null 2>&1 || arms_empty_rc=$?
  check "an EMPTY arm list is refused: a sweep with no arms measures nothing" \
    "$([ "$arms_empty_rc" -ne 0 ] && echo yes || echo no)" "yes"

  shuf_out=$(
    (
      read -r -a E11_ARMS <<<"container microvm driver-control"
      # shellcheck disable=SC1090
      . "$arms_snippet"
      shuffle_e11_arms | sort | tr '\n' ' '
    )
  )
  check "shuffle_e11_arms emits exactly the configured arms, in some order" \
    "$shuf_out" "container driver-control microvm "
  shuf_two=$(
    (
      read -r -a E11_ARMS <<<"container driver-control"
      # shellcheck disable=SC1090
      . "$arms_snippet"
      shuffle_e11_arms | wc -l | tr -d ' '
    )
  )
  check "  ...and it does not hardcode two arms any more" "$shuf_two" "2"
  rm -rf "$arms_tmpdir"
fi

echo "== the control arm records a rung with null swept dimensions and no require_vmm trip"
# It follows the CONTAINER path: dimension_literal maps its "-" dimensions to None, and
# require_vmm stays 0 because that flag is gated on arm = microvm. Converge hits the responder
# too, which is correct -- the control measures the driver's cost for BOTH phases.
check "the control arm passes '-' for both swept dimensions, like the container arm" \
  "$([ "$(grep -c 'run_density_rung driver-control - -' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
rv_rdr="$(extract_fn run_density_rung || true)"
if [ -n "$rv_rdr" ]; then
  check "require_vmm is gated on the microvm arm alone, so the control arm cannot trip it" \
    "$(printf '%s\n' "$rv_rdr" | grep -c 'if \[ "\$arm" = "microvm" \] && \[ "\$d" != "0" \]')" "1"
  check "the idle standby-residency poll is likewise microvm-only" \
    "$(printf '%s\n' "$rv_rdr" | grep -c 'if \[ "\$arm" = "microvm" \]; then')" "1"
  check "the control arm has its own relay-log path for assert_relay_alive" \
    "$(printf '%s\n' "$rv_rdr" | grep -c 'e11-driver-control-responder.log')" "1"
fi
```

Then **edit** the trap probe again — building on Task 4's version. Replace:

```bash
    echo 'stop_microvm_stack() { echo microvm >>"$ORDER"; }'
```

with:

```bash
    echo 'stop_microvm_stack() { echo microvm >>"$ORDER"; }'
    echo 'stop_null_stack() { echo null >>"$ORDER"; }'
```

and the expected order:

```bash
  check "it kills the sampler and BOTH arms' stacks (kill before remove)" \
    "$(tr '\n' ' ' <"$tr_order")" "sampler container microvm "
```

becomes:

```bash
  check "it kills the sampler and every arm's stack (kill before remove)" \
    "$(tr '\n' ' ' <"$tr_order")" "sampler container microvm null "
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t6-red.log" 2>&1; echo "EXIT:$?"
grep FAIL "$LOG_DIR/t6-red.log" | head -20
```

Expected: `validate_arms` is not extractable, `SH_E11_ARMS` is absent, `start_null_stack` is
absent, and the trap order lacks `null`.

- [ ] **Step 3: Add the config, the arm validator and the teardown globals**

In `deploy/microvm/e11-density.sh`, after the `ACTIVE_RUNS` line (~166), insert:

```bash
# The arms driven, in randomized order (shuffle_e11_arms). "driver-control" is ON BY DEFAULT
# (issue #291 section 4): it drives the identical run_density_rung against
# remote-worker/cmd/null-responder -- one End per Exec, no relay, no Redis, no worker, no VMM
# -- so subtracting it at each c gives the DRIVER's own contribution to observed latency. The
# control whose absence let a driver artifact be published as a density finding should not be
# opt-in. Set SH_E11_ARMS to opt out.
read -r -a E11_ARMS <<<"${SH_E11_ARMS:-container microvm driver-control}"
# The null-responder's loopback port. Deliberately NOT E11_RELAY_PORT: the control arm's
# "stack" is one process and never coexists with a relay, but sharing the port would make a
# stale relay from a previous arm answer the control arm's Execs, which is the one thing this
# arm must never measure.
NULL_RESPONDER_PORT="${SH_E11_NULL_RESPONDER_PORT:-8445}"
```

Add to the globals above the trap (after `E11_WORKER_BIN=""`):

```bash
E11_NULL_PID=""
E11_NULL_BIN=""
```

and extend `cleanup_on_exit` (which after Task 4 already calls `stop_host_sampler` first):

```bash
cleanup_on_exit() {
  stop_host_sampler || true
  stop_container_stack || true
  stop_microvm_stack || true
  stop_null_stack || true
  [ -z "${E11_TMPDIR:-}" ] || rm -rf "$E11_TMPDIR"
}
```

Immediately after `validate_repo_cache_shape()` (ends ~line 316), insert:

```bash
# validate_arms refuses an SH_E11_ARMS value that is not one of the three arms this driver
# implements, and refuses an empty list. An invented arm would otherwise fall through main()'s
# case with no branch, so the sweep would "succeed" having driven nothing -- which is the
# looks-like-success failure mode this file spends most of its refusals on. "cloud-hypervisor"
# in particular is a plausible typo and is NOT an arm here (see the header for why: on this
# rig CH does not restore).
validate_arms() {
  [ "${#E11_ARMS[@]}" -gt 0 ] ||
    die "SH_E11_ARMS is empty - a sweep with no arms would complete having measured nothing. The three arms are: container, microvm, driver-control."
  local arm
  for arm in "${E11_ARMS[@]}"; do
    case "$arm" in
    container | microvm | driver-control) : ;;
    *)
      die "SH_E11_ARMS contains '$arm', which is not one of this driver's three arms: container (today's remote-worker, the baseline), microvm (microvm-worker, Firecracker only), driver-control (the null-responder, issue #291 section 4). Cloud Hypervisor is not an arm here - see this file's header."
      ;;
    esac
  done
}
```

In `preflight()`, add `validate_arms` immediately after the `validate_repo_cache_shape` line.

> `preflight` still requires `docker`, `pnpm` and `/dev/kvm` unconditionally, so
> `SH_E11_ARMS=driver-control` alone is not yet a way to run the control on a machine
> without them. That is the same behaviour the two existing arms have and is out of this
> plan's scope; the control arm's value is as a _default third arm_ beside them.

- [ ] **Step 4: Make `shuffle_e11_arms` shuffle the configured arms**

Replace `shuffle_e11_arms()` (line 750) with:

```bash
# shuffle_e11_arms prints $E11_ARMS in randomized order (spec section 7.5: page-cache
# asymmetry between arms), same technique as e10-lifecycle.sh's shuffle_arms. It reads the
# configured list rather than a hardcoded pair, so adding the driver-control arm did not need
# a second randomiser that could drift from this one.
shuffle_e11_arms() {
  printf '%s\n' "${E11_ARMS[@]}" |
    awk -v seed="$(($$ + $(date +%s)))" 'BEGIN{srand(seed)} {print rand()"\t"$0}' | sort -n | cut -f2-
}
```

- [ ] **Step 5: Add the null stack**

Immediately after `stop_microvm_stack()` (ends ~line 879), insert:

```bash
# start_null_stack starts ONLY the null-responder (issue #291 section 4). No redis, no relay,
# no worker, no VMM: the control arm exists to measure what the DRIVER costs, so anything else
# left in the path would be measured along with it. That is also why this arm reuses neither
# E11_RELAY_PORT nor start_redis_loopback.
start_null_stack() {
  [ "$E11_START_STACK" = "1" ] || {
    log "driver-control stack: SH_E11_START_STACK=0, reusing an already-running null-responder"
    return 0
  }
  E11_NULL_BIN="$RESULTS/.e11-null-responder-bin"
  log "driver-control: building the null-responder"
  (cd "$REMOTE_WORKER_DIR" && go build -o "$E11_NULL_BIN" ./cmd/null-responder) ||
    die "go build ./cmd/null-responder failed - the driver-control arm has nothing to drive, so every Exec would time a missing binary rather than the driver's own overhead"

  log "driver-control: starting the null-responder on 127.0.0.1:$NULL_RESPONDER_PORT"
  "$E11_NULL_BIN" -listen "127.0.0.1:${NULL_RESPONDER_PORT}" \
    >"$RESULTS/e11-driver-control-responder.log" 2>&1 &
  E11_NULL_PID="$!"
  wait_for_relay_port "$NULL_RESPONDER_PORT" "$RESULTS/e11-driver-control-responder.log" \
    "the driver-control arm's null-responder"
}

stop_null_stack() {
  [ "$E11_START_STACK" = "1" ] || return 0
  # ${VAR:-} because this runs from the EXIT trap too, which can fire before it is assigned.
  [ -n "${E11_NULL_PID:-}" ] && kill "${E11_NULL_PID:-}" 2>/dev/null
  E11_NULL_PID=""
  return 0
}
```

- [ ] **Step 6: Give the control arm a relay-log path, and dispatch it from `main`**

In `run_density_rung()`, replace the two `relay_log` lines:

```bash
  local relay_log="$RESULTS/e11-container-relay.log"
  [ "$arm" = "microvm" ] && relay_log="$RESULTS/e11-microvm-relay-d${d}-ram${ram_mb}.log"
```

with:

```bash
  # The log name differs per arm, matching where each arm's server writes. assert_relay_alive
  # tails it, so a wrong path here costs the operator the one message that says what died.
  local relay_log="$RESULTS/e11-container-relay.log"
  case "$arm" in
  microvm) relay_log="$RESULTS/e11-microvm-relay-d${d}-ram${ram_mb}.log" ;;
  driver-control) relay_log="$RESULTS/e11-driver-control-responder.log" ;;
  esac
```

In `main()`, replace the `if [ "$arm" = "container" ]; then ... else ... fi` block with a
`case`, adding the new branch. The container and microvm branch bodies are **unchanged**;
only the dispatch shape and the new branch are new:

```bash
    case "$arm" in
    container)
      start_container_stack
      for c in "${ACTIVE_RUNS[@]}"; do
        run_density_rung container - - "$c" "e11-container" "$E11_RELAY_PORT" \
          "$RESULTS/e11-rung-container-c${c}.json"
      done
      stop_container_stack
      assemble_ladder "$RESULTS/e11-rung-container-c*.json" "$RESULTS/e11-ladder-container.json"
      analyze_slice "$RESULTS/e11-ladder-container.json" || log "analyze_slice(container) failed - see output above"
      ;;
    driver-control)
      start_null_stack
      for c in "${ACTIVE_RUNS[@]}"; do
        run_density_rung driver-control - - "$c" "e11-driver-control" "$NULL_RESPONDER_PORT" \
          "$RESULTS/e11-rung-driver-control-c${c}.json"
      done
      stop_null_stack
      assemble_ladder "$RESULTS/e11-rung-driver-control-c*.json" "$RESULTS/e11-ladder-driver-control.json"
      # analyze_slice is SKIPPED here: analyzeLadder scores a ladder of COLD ACQUIRES against
      # sealed predictions about a VM pool, and this arm has no pool and no acquires, so its
      # verdicts would be noise attached to real prediction ids. The ladder file is still
      # assembled, because subtracting this arm from the other two at each c is the entire
      # purpose of the arm.
      log "driver-control: ladder assembled at $RESULTS/e11-ladder-driver-control.json (analyze_slice skipped - no pool and no cold acquires; subtract this arm from the others at each c to get the driver's own share)"
      ;;
    microvm)
      local d ram_mb
      for d in "${D_VALUES[@]}"; do
        for ram_mb in "${RAM_MB_VALUES[@]}"; do
          start_microvm_stack "$d" "$ram_mb" "$max_c"
          for c in "${ACTIVE_RUNS[@]}"; do
            run_density_rung microvm "$d" "$ram_mb" "$c" "e11-microvm-d${d}-ram${ram_mb}" "$E11_RELAY_PORT" \
              "$RESULTS/e11-rung-microvm-d${d}-ram${ram_mb}-c${c}.json"
          done
          stop_microvm_stack
          assemble_ladder "$RESULTS/e11-rung-microvm-d${d}-ram${ram_mb}-c*.json" \
            "$RESULTS/e11-ladder-microvm-d${d}-ram${ram_mb}.json"
          analyze_slice "$RESULTS/e11-ladder-microvm-d${d}-ram${ram_mb}.json" ||
            log "analyze_slice(microvm d=$d ram=$ram_mb) failed - see output above"
        done
      done
      ;;
    esac
```

Also update `main()`'s opening `log` line, which still names two arms:

```bash
  log "arms: ${E11_ARMS[*]} (microvm is Firecracker only - hardware-corrections F5; driver-control is the null-responder, issue #291 section 4)"
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/t6-green.log" 2>&1; echo "EXIT:$?"
grep -E 'FAIL|Total failures' "$LOG_DIR/t6-green.log"
shellcheck -x -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t6-sc.log" 2>&1; echo "EXIT:$?"
shellcheck -o check-unassigned-uppercase -S warning deploy/microvm/e11-density.sh > "$LOG_DIR/t6-sc2154.log" 2>&1; echo "EXIT:$?"
```

Expected: `Total failures: 0`, exit 0 from both shellcheck runs.

- [ ] **Step 8: Commit**

```bash
git add deploy/microvm/e11-density.sh deploy/microvm/tests/e11-density.test.sh
git commit -s -m "feat(e11): add the driver-control arm, on by default

A third arm drives the identical run_density_rung against the null-responder, with no
relay, no Redis and no worker, so subtracting it at each c gives the driver's own
contribution to observed latency. grpcurl still re-parses the proto and opens a fresh
connection per call; if that residue dominates at high c, a fixed-but-still-grpcurl
driver would show a knee that is still an artifact and a persistent-connection client
becomes mandatory before the authoritative run.

It follows the container path -- require_vmm 0, no standby poll, swept dimensions
recorded as null -- and analyze_slice is skipped, because a ladder with no cold
acquires is not what analyzeLadder scores. Its ladder is still assembled: the
subtraction needs it.

SH_E11_ARMS is opt-OUT. The control whose absence let this artifact through should not
be opt-in.

Refs #291 section 4.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 7: `RungSample` records what its four host signals now mean (spec §5)

`hostCpuFraction`, `memAvailableBytes`, `pssBytes` and `processCount` keep their names and
their place in the contract but now carry under-load values. The interface records that in
doc comments and declares the new fields as optional. **No scorer logic changes** — the
verdict `analyzeLadder` produces can change, because real CPU data can cross 0.9, but not
because any comparison here was edited.

**Files:**

- Modify: `experiments/src/microvm-density.ts:27-58` (the `RungSample` interface and the field-notes block above it)
- Test: `experiments/test/microvm-density.test.ts`

**Interfaces:**

- Consumes: the record schema Task 4 writes.
- Produces: nothing downstream in this plan; `analyzeLadder`'s signature is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `experiments/test/microvm-density.test.ts`, inside the
`describe('E11 ladder analysis', ...)` block:

```typescript
// Issue #291: the four host signals are now sampled DURING the timed window, and the
// record carries the extremes and sample counts beside each mean. This module's job is to
// ACCEPT those fields and score exactly as before -- the whole repair is upstream, in the
// driver, and a scorer change smuggled in alongside it would make the re-run
// uninterpretable.
const enriched = (over: Partial<RungSample> & { c: number }): RungSample => ({
  ...rung(over),
  hostCpuFractionPeak: (over.hostCpuFraction ?? 0.2) + 0.3,
  hostCpuFractionMin: 0.01,
  hostCpuSamples: 12,
  coresBusy: (over.hostCpuFraction ?? 0.2) * 72,
  memAvailableBytesMin: (over.memAvailableBytes ?? 100e9) * 0.9,
  pssBytesPeak: (over.pssBytes ?? 1e9) * 2,
  pssSamples: 3,
  processCountPeak: (over.processCount ?? 10 * over.c) + 2,
  processCountSamples: 3,
  samplingMode: 'in-rung-1hz-mean',
  postLoadHostCpuFraction: 0.0006,
  postLoadMemAvailableBytes: over.memAvailableBytes ?? 100e9,
  postLoadPssBytes: over.pssBytes ?? 1e9,
  postLoadProcessCount: over.processCount ?? 10 * over.c,
});

it("accepts the #291 record's new fields and scores identically without them", () => {
  const ladder: Array<Partial<RungSample> & { c: number }> = [
    { c: 1 },
    { c: 2 },
    { c: 4 },
    { c: 8, p95Ms: 400, coldAcquireRate: 0.4 },
  ];
  const plain = analyzeLadder(ladder.map(rung));
  const withNew = analyzeLadder(ladder.map(enriched));
  expect(withNew).toEqual(plain);
});

it('scores the cpu bound off hostCpuFraction, which is now the under-load mean', () => {
  // The pre-fix records had hostCpuFraction ~0.0006 at every rung, which made
  // crosses('cpu') -- `>= 0.9` -- STRUCTURALLY unable to fire anywhere in a ladder. So
  // "nothing resembling a CPU ceiling was reached" was a restatement of the sampling bug,
  // not a finding. With a real under-load mean the same untouched comparison can fire.
  const idle = analyzeLadder([
    rung({ c: 1, hostCpuFraction: 0.0006 }),
    rung({ c: 2, hostCpuFraction: 0.0006 }),
    rung({ c: 4, hostCpuFraction: 0.0006, p95Ms: 400 }),
  ]);
  expect(idle.bound).not.toBe('cpu');

  const loaded = analyzeLadder([
    enriched({ c: 1, hostCpuFraction: 0.1 }),
    enriched({ c: 2, hostCpuFraction: 0.5 }),
    enriched({ c: 4, hostCpuFraction: 0.95, p95Ms: 400 }),
  ]);
  expect(loaded.bound).toBe('cpu');
});

it('ignores postLoadHostCpuFraction entirely: it is the record, not the signal', () => {
  // The idle snapshot is retained under its own name so it can never again pass as an
  // under-load reading. Nothing in this module may read it.
  const r = analyzeLadder([
    enriched({ c: 1, hostCpuFraction: 0.95 }),
    enriched({ c: 2, hostCpuFraction: 0.95 }),
    enriched({ c: 4, hostCpuFraction: 0.95, p95Ms: 400 }),
  ]);
  const alsoIdle = analyzeLadder([
    { ...enriched({ c: 1, hostCpuFraction: 0.95 }), postLoadHostCpuFraction: 0.99 },
    { ...enriched({ c: 2, hostCpuFraction: 0.95 }), postLoadHostCpuFraction: 0.99 },
    { ...enriched({ c: 4, hostCpuFraction: 0.95, p95Ms: 400 }), postLoadHostCpuFraction: 0.99 },
  ]);
  expect(alsoIdle).toEqual(r);
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
pnpm -C experiments exec vitest run microvm-density > "$LOG_DIR/t7-red.log" 2>&1; echo "EXIT:$?"
grep -E 'error TS|✗|FAIL|does not exist' "$LOG_DIR/t7-red.log" | head
pnpm -r typecheck > "$LOG_DIR/t7-red-tc.log" 2>&1; echo "EXIT:$?"
```

Expected: non-zero. `hostCpuFractionPeak`, `samplingMode` and the rest are not properties of
`RungSample`, so `enriched` fails to type-check (`Object literal may only specify known
properties`).

- [ ] **Step 3: Add the doc comments and the optional declarations**

In `experiments/src/microvm-density.ts`, add a fourth bullet to the field-notes block above
`RungSample` (after the `leaseSaturations` bullet, before the closing ` */`):

```typescript
 *  - The four host signals -- `pssBytes`, `memAvailableBytes`, `hostCpuFraction`,
 *    `processCount` -- are sampled DURING the rung's timed window and carry that window's
 *    MEAN. Before issue #291 they were sampled after every slot had exited, and
 *    `host_cpu_fraction` then slept one second and diffed /proc/stat across that window, so
 *    all four described a quiesced machine. The consequence was not merely weak evidence:
 *    `crosses('cpu')` tests `hostCpuFraction >= 0.9`, so a post-load 0.0006 on a 72-cpu host
 *    made the `cpu` bound structurally unable to fire at ANY rung, and E11's "no CPU ceiling
 *    was reached" was a restatement of the sampling bug. Records written before the fix carry
 *    no `samplingMode`; records written after carry `"in-rung-1hz-mean"`. The two are NOT
 *    comparable on any of these four fields.
 *  - The mean, not the peak, is what `hostCpuFraction` carries, and that choice is narrower
 *    than "the mean is more representative". `scorePrediction1` flips sealed prediction 1
 *    straight to `falsified` if CPU crosses 0.9 anywhere while memory and process-count never
 *    do. Scoring that off a single one-second peak -- a GC pause, a `drop_caches`, an
 *    unrelated process on a shared box -- would be the same class of error as the artifact
 *    being fixed, pointed the other way. The mean matches what `crosses('cpu')` asserts:
 *    THIS RUNG WAS CPU-SATURATED, not "this rung once touched saturation". Nothing is lost,
 *    because `hostCpuFractionPeak` is recorded beside it.
```

Then, at the end of the `RungSample` interface (after the `execErrorsByCause` field), add:

```typescript
  /**
   * The rest of this interface is what the driver RECORDS beside each mean (issue #291 §5).
   * All optional, because records written before that fix do not have them, and no scorer
   * reads any of them: they exist so a mean can always be checked against what it averaged.
   */
  /** Highest and lowest `hostCpuFraction` tick over the timed window. */
  hostCpuFractionPeak?: number;
  hostCpuFractionMin?: number;
  /**
   * Sampler ticks behind `hostCpuFraction`. Exposes thin rungs: a fast `c=1` rung may yield
   * only 2-3 samples, and a mean of 2 samples deserves a visible caveat.
   */
  hostCpuSamples?: number;
  /** `hostCpuFraction` x the host's online CPU count. "0.043 cores" is legible; 0.0006 is not. */
  coresBusy?: number;
  /** Lowest `memAvailableBytes` tick -- the only extreme of this signal that indicates pressure. */
  memAvailableBytesMin?: number;
  /** Highest Sigma PSS tick over the timed window. */
  pssBytesPeak?: number;
  /**
   * Ticks behind `pssBytes` / `processCount`. Lower than `hostCpuSamples` by design: those two
   * need `pgrep` plus an N-file smaps_rollup walk, so the driver takes them every Nth tick
   * (default 5, always including tick 1). Defensible because `crosses('memory')` reads
   * `memAvailableBytes`, which IS every tick -- PSS feeds the narrative, not the bound.
   */
  pssSamples?: number;
  processCountSamples?: number;
  /** Highest `processCount` tick over the timed window. */
  processCountPeak?: number;
  /**
   * How the four host signals above were taken. `"in-rung-1hz-mean"` since issue #291;
   * absent on older records, which took them from an idle host after the window closed.
   */
  samplingMode?: string;
  /**
   * The retained post-load snapshot, taken once after every slot exited. Kept under its own
   * names precisely so an idle reading can never again pass as an under-load one. NOTHING in
   * this module reads these.
   */
  postLoadHostCpuFraction?: number;
  postLoadMemAvailableBytes?: number;
  postLoadPssBytes?: number;
  postLoadProcessCount?: number;
```

- [ ] **Step 4: Run the tests and the typecheck to verify they pass**

```bash
pnpm -C experiments exec vitest run microvm-density > "$LOG_DIR/t7-green.log" 2>&1; echo "EXIT:$?"
tail -12 "$LOG_DIR/t7-green.log"
pnpm -C experiments exec vitest run microvm-predictions > "$LOG_DIR/t7-pred.log" 2>&1; echo "EXIT:$?"
pnpm -r typecheck > "$LOG_DIR/t7-tc.log" 2>&1; echo "EXIT:$?"
```

Expected: all `EXIT:0`. The predictions pin must still pass — `predictions.json` is
untouched, and if that run fails, something in this task edited a sealed file.

- [ ] **Step 5: Commit**

```bash
git add experiments/src/microvm-density.ts experiments/test/microvm-density.test.ts
git commit -s -m "docs(e11): record what RungSample's four host signals now mean

pssBytes, memAvailableBytes, hostCpuFraction and processCount keep their names and
their place in the contract but now carry the timed window's mean rather than a
post-load snapshot, and the record carries each one's extremes and sample count beside
it. Declared optional because pre-fix records lack them, and no scorer reads any of
them.

No scorer logic changes. The verdict analyzeLadder produces can now differ -- real CPU
data can cross 0.9 where an idle 0.0006 never could -- but not because a comparison
here was edited. predictions.json is untouched and its pin still passes.

Refs #291 section 5.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

---

### Task 8: Caveat the published §E11 claims, and verify the whole branch

The numbers **stay**. They are the record of what the broken instrument produced, and the
re-run is defined by comparison against them. What gets marked is which conclusions rest on
the defects.

**Files:**

- Modify: `deploy/microvm/EXPERIMENTS.md` (§E11, at line 697)
- No test: the deliverable is prose. The verification step is the whole-branch gate run.

**Interfaces:**

- Consumes: everything Tasks 1-7 produced.
- Produces: the statement the PR body will quote.

- [ ] **Step 1: Insert the caveat**

In `deploy/microvm/EXPERIMENTS.md`, immediately after the heading line
`### E11 — density, the replenishment ceiling, and the write-up` and before the
`**RUN ON BARE METAL, 14 rungs, exit 0.**` line, insert:

```markdown
> **2026-09-17 — three of this section's conclusions are under repair (issue #291).** The
> driver that produced these numbers had three mechanical defects, each affecting both arms
> identically by construction, and any one of which is sufficient to produce the knee below
> with no contribution from either backend: host resource signals were sampled on an idle
> host after the window closed; roughly nine process spawns per Exec, two of them Python
> interpreters, fell inside the timed window; and converge sat in the throughput denominator.
> Two structurally different backends saturating at the same `c` with the same curve shape
> was the tell.
>
> Specifically under repair, and not to be cited until a re-run:
>
> - **"`bound` is replenishment on both arms"** — the attribution, because a driver-bound
>   ladder produces this shape on any backend.
> - **"Nothing resembling a CPU or memory ceiling was reached"** — not a finding.
>   `crosses('cpu')` tests `hostCpuFraction >= 0.9`, and a post-load `0.0006` makes that
>   comparison structurally unable to fire at any rung. It is a restatement of the sampling
>   bug.
> - **The knee position, `c=8` on both arms** — the falsifiable question for the re-run is
>   whether it stays there. If it moves or vanishes, the conclusion above is an artifact and
>   needs retraction. If it holds with real under-load CPU data behind it, the conclusion was
>   right and only its evidence was wrong.
> - **Sealed prediction 3's SUPPORTED score** is derived from `coldAcquireRate`'s shape,
>   which is a latency-classification proxy computed from the same contaminated latencies.
>   Pending re-examination.
>
> The numbers stay. They are the record of what the broken instrument produced, and the
> re-run is defined by comparison against them. Rung records written by the repaired driver
> carry `samplingMode` — the ones below do not, and the two are not comparable on
> `hostCpuFraction`, `memAvailableBytes`, `pssBytes` or `processCount`. The repaired driver
> also adds a third arm, `driver-control`, whose latency is all driver; subtracting it at
> each `c` is what will say whether the re-run can separate backend from driver at all.
```

> Keep inline code spans in that blockquote short. Prettier will re-wrap a long
> `` `code span` `` across a line break and drop the `> ` prefix on the continuation, which
> silently breaks the blockquote while lint still passes. The spans above are all short
> enough; check the rendered diff after `make fmt` regardless.

- [ ] **Step 2: Format and confirm the blockquote survived**

```bash
pnpm exec prettier --write deploy/microvm/EXPERIMENTS.md
awk '/^### E11 /,/^\*\*RUN ON BARE METAL/' deploy/microvm/EXPERIMENTS.md | grep -c '^[^>]'
```

Expected: `2` — the heading line and the `**RUN ON BARE METAL` line. (Blank lines have no
first character, so `^[^>]` skips them.) Anything higher means a line lost its `> ` prefix,
which is how Prettier silently breaks a blockquote. Read the block to confirm:

```bash
awk '/^### E11 /,/^\*\*RUN ON BARE METAL/' deploy/microvm/EXPERIMENTS.md
```

> `make fmt` formats the whole repo and Prettier does not honour `.gitignore`, so it walks
> sibling worktrees under `.worktrees/`. Format the one file, as above, rather than running
> `make fmt`.

- [ ] **Step 3: Run every gate**

```bash
export LOG_DIR=/tmp/kagenti/tdd/serverless-harness; mkdir -p "$LOG_DIR"

bash deploy/microvm/tests/e11-density.test.sh > "$LOG_DIR/final-e11.log" 2>&1; echo "E11:$?"
tail -3 "$LOG_DIR/final-e11.log"

# The sibling suites, to prove nothing in deploy/microvm regressed.
make test-deploy > "$LOG_DIR/final-deploy.log" 2>&1; echo "DEPLOY:$?"
grep -E 'FAILED|Total failures' "$LOG_DIR/final-deploy.log"

(cd remote-worker && go test ./... ) > "$LOG_DIR/final-go.log" 2>&1; echo "GO:$?"
(cd remote-worker && gofmt -l . ) > "$LOG_DIR/final-gofmt.log" 2>&1; echo "GOFMT-FILES:$(wc -l < "$LOG_DIR/final-gofmt.log")"
(cd remote-worker && go vet ./... ) > "$LOG_DIR/final-vet.log" 2>&1; echo "VET:$?"

pnpm -C experiments exec vitest run > "$LOG_DIR/final-experiments.log" 2>&1; echo "EXPERIMENTS:$?"
# vitest can exit non-zero with every test green when an unhandled error escapes the
# summary. Check both the exit code AND this.
grep -E '^ *Errors ' "$LOG_DIR/final-experiments.log" || echo "(no unhandled errors)"

pnpm -r typecheck > "$LOG_DIR/final-typecheck.log" 2>&1; echo "TYPECHECK:$?"

# Stage first: `make lint` runs pre-commit, which skips untracked files -- a silent pass
# may have linted nothing.
git add -A
make lint > "$LOG_DIR/final-lint.log" 2>&1; echo "LINT:$?"
grep -Ev '^(Check|Trim|Fix|Mixed|Detect|Don|check|trim|fix|.*Passed|.*Skipped)' "$LOG_DIR/final-lint.log" | head -20
```

Expected: `E11:0`, `DEPLOY:0`, `GO:0`, `GOFMT-FILES:0`, `VET:0`, `EXPERIMENTS:0` with no
`Errors` line, `TYPECHECK:0`, `LINT:0`.

If `make test` is run instead, note it also runs `pnpm -r test`, which needs Redis for the
work-queue and session-backend suites — ten `ECONNREFUSED` failures across four files means
the Redis container is stopped, not that this branch broke anything.

- [ ] **Step 4: Commit**

```bash
git add deploy/microvm/EXPERIMENTS.md
git commit -s -m "docs(e11): caveat the conclusions that rest on the driver defects

The numbers stay -- they are the record of what the broken instrument produced, and the
re-run is defined by comparison against them. What is marked is which conclusions rest
on the three defects: the replenishment attribution, the 'no CPU or memory ceiling'
claim (which is a restatement of the sampling bug, since a post-load 0.0006 makes
crosses('cpu') unable to fire at all), the c=8 knee position, and prediction 3's
SUPPORTED score.

Refs #291.

Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>"
```

- [ ] **Step 5: State the unexecuted-fix risk in the PR body**

The PR description must say this plainly rather than imply it away:

> This instrument has **not been executed** since these changes. A real sweep needs
> `/dev/kvm`, Docker, `grpcurl` and real worker binaries. E10's first real execution found
> three defects, and a fourth at full `ITERS`; E11 is the larger driver. An unexecuted fix
> is a known risk, not a clean bill of health.
>
> Two outcomes of this work that are **not** failures of it: the control arm may show the
> driver still dominates, in which case the re-run still cannot separate backend from
> driver and a persistent-connection Go client becomes mandatory — that is the control
> doing its job. And `analyzeLadder` may now reach `falsified` where it read
> `inconclusive`, because real CPU data can cross 0.9. No scorer logic changed; the verdict
> it produces can.

Append to the PR body:

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```
