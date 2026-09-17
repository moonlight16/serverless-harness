#!/usr/bin/env bash
# deploy/microvm/tests/e13-restore-capacity-control.test.sh
#
# KVM-free contract test for e13-restore-capacity-control.sh, in
# e12-vsock-egress-probe.test.sh's own style (extract_fn/check).
#
# Run: bash deploy/microvm/tests/e13-restore-capacity-control.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/e13-restore-capacity-control.sh"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else
  echo "  FAIL: $1 (want '$3', got '$2')"
  fails=$((fails + 1))
fi; }

extract_fn() {
  local name="$1" start end
  start=$(grep -n "^${name}() {" "$SCRIPT" | head -n1 | cut -d: -f1)
  [ -n "$start" ] || return 1
  end=$(awk -v s="$start" 'NR>s && /^}$/{print NR; exit}' "$SCRIPT")
  [ -n "$end" ] || return 1
  sed -n "${start},${end}p" "$SCRIPT"
}

echo "== the script exists, is executable, and is shellcheck-clean"
check "control present" "$([ -f "$SCRIPT" ] && echo yes || echo no)" "yes"
check "control executable" "$([ -x "$SCRIPT" ] && echo yes || echo no)" "yes"
if command -v shellcheck >/dev/null; then
  # -x (follow sourced files) is required here, and its own `source=` path
  # in e13-restore-capacity-control.sh resolves relative to shellcheck's
  # CWD, not the linted file's directory - confirmed by hand against the
  # build of shellcheck in use - so cd into $DIR first, or SC1091 fires even
  # with a correct directive and the sourced file sitting right next to it.
  # (Do not start a comment line with the tool's own name: it gets parsed as
  # a directive and fails SC1072/SC1073.)
  if (cd "$DIR" && shellcheck -x "$(basename "$SCRIPT")") >/tmp/e13-control-shellcheck.out 2>&1; then
    check "shellcheck" "clean" "clean"
  else
    check "shellcheck" "$(cat /tmp/e13-control-shellcheck.out)" "clean"
  fi
else
  echo "  skip: shellcheck not installed"
fi

echo "== set -uo pipefail, and NOT set -e"
check "has set -uo pipefail" "$(grep -cE '^set -uo pipefail$' "$SCRIPT")" "1"
check "does not set -e" "$(grep -cE '^set -e|^set -[a-z]*e[a-z]* ' "$SCRIPT")" "0"

echo "== it reuses e12-vsock-egress-probe.sh, never modifies it"
check "sources e12's driver" \
  "$([ "$(grep -c 'source.*e12-vsock-egress-probe.sh' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"
check "sets E12_PROBE_SOURCE_ONLY=1 before sourcing" \
  "$([ "$(grep -c 'E12_PROBE_SOURCE_ONLY=1' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"

echo "== the whole point: it NEVER touches the second port or its listener"
# Call/reference SHAPES, not bare substrings - a header comment explaining
# WHY this script has none of these is expected and must not itself trip
# the check (e12's own call sites always look like `start_host_listener "`,
# `run_probe_once "`, `$PROBE_PORT`).
check "never references PROBE_PORT" "$(grep -Fc '$PROBE_PORT' "$SCRIPT")" "0"
check "never calls start_host_listener" "$(grep -Fc 'start_host_listener "' "$SCRIPT")" "0"
check "never calls run_probe_once" "$(grep -Fc 'run_probe_once "' "$SCRIPT")" "0"

echo "== it drives the EXISTING agent port only, the same way rung D does"
check "uses AGENT_PORT against GUEST_CLIENT" \
  "$([ "$(grep -c 'GUEST_CLIENT.*AGENT_PORT' "$SCRIPT")" -ge 1 ] && echo yes || echo no)" "yes"

echo "== own results/jail dirs, never e12's or e11's"
check "does not hardcode /tmp/e12-results" "$(grep -c '/tmp/e12-results' "$SCRIPT")" "0"
check "does not hardcode /srv/e12-jails" "$(grep -c '/srv/e12-jails' "$SCRIPT")" "0"

echo "== run_control_n exists and writes both per-VM and aggregate records"
ctrl_body="$(extract_fn run_control_n || true)"
check "run_control_n exists" "$([ -n "$ctrl_body" ] && echo yes || echo no)" "yes"
check "it calls restore_vm" "$([ "$(echo "$ctrl_body" | grep -c 'restore_vm')" -ge 1 ] && echo yes || echo no)" "yes"
check "it calls teardown_jail" "$([ "$(echo "$ctrl_body" | grep -c 'teardown_jail')" -ge 1 ] && echo yes || echo no)" "yes"
check "it writes a per-VM record" \
  "$([ "$(echo "$ctrl_body" | grep -Fc 'control-${n}-${i}')" -ge 1 ] && echo yes || echo no)" "yes"
check "it writes an aggregate record" \
  "$([ "$(echo "$ctrl_body" | grep -c 'ok_count')" -ge 1 ] && echo yes || echo no)" "yes"

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "all checks passed"
