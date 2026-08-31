#!/usr/bin/env bash
# deploy/knative/tests/lib-relay-shared.test.sh
#
# Locks the property lib-relay.sh exists to provide: the assertions that decide whether a
# remote-sandbox proof HOLDS are defined once and shared by both callers. Nothing else
# enforces it -- a future edit can re-inline a copy of validate_discriminator or
# assert_verdict into either script and every existing check still passes, while the two
# proofs quietly drift apart and one keeps asserting something the other dropped.
#
# Static: greps the scripts, runs no cluster and no kubectl. Complements the live gate
# (RELAY_LIVE_SMOKE=1 relay-leaf-smoke.sh), which cannot run in CI.
# Run: bash deploy/knative/tests/lib-relay-shared.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$DIR/lib-relay.sh"
CALLERS=("$DIR/relay-leaf-smoke.sh" "$DIR/demo-remote-worker.sh")

# The assertions whose duplication would let the two proofs disagree about what "passing"
# means. Not every helper in lib-relay.sh -- only the ones that decide a verdict.
SHARED_FNS=(validate_discriminator assert_verdict dispatch_pattern assert_no_pods_match count_pool_pods)

FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

echo "lib-relay.sh defines each shared assertion exactly once"
for fn in "${SHARED_FNS[@]}"; do
  n="$(grep -c "^${fn}() {" "$LIB")"
  [ "$n" = 1 ] && pass "$fn defined in lib-relay.sh" || fail "$fn defined $n time(s) in lib-relay.sh, want 1"
done

echo
echo "both callers source lib-relay.sh"
for c in "${CALLERS[@]}"; do
  if grep -qE '^\s*source \./lib-relay\.sh' "$c"; then
    pass "$(basename "$c") sources ./lib-relay.sh"
  else
    fail "$(basename "$c") does not source ./lib-relay.sh"
  fi
done

echo
echo "no caller redefines a shared assertion locally (anti-drift)"
for c in "${CALLERS[@]}"; do
  for fn in "${SHARED_FNS[@]}"; do
    if grep -qE "^\s*${fn}\(\) \{" "$c"; then
      fail "$(basename "$c") defines its own ${fn}() -- it must use lib-relay.sh's, or the two proofs can drift"
    else
      pass "$(basename "$c") does not shadow ${fn}()"
    fi
  done
done

echo
echo "count_pool_pods fails CLOSED: a failed query is not reported as zero pods"
# The one direction that must not fail open. Exercised behaviourally, with kubectl forced to
# fail: a green "matches 0 Running pods" on the strength of a kubectl error would hand back
# exactly the vacuous proof assert_no_pods_match exists to prevent.
out="$(
  set -uo pipefail
  # shellcheck disable=SC2034  # NS is read by the eval'd count_pool_pods, which shellcheck cannot follow
  NS=default
  ok() { echo "OK:$1"; }
  abort() { echo "ABORT:$1"; exit 9; }
  eval "$(sed -n '/^count_pool_pods() {/,/^}/p;/^assert_no_pods_match() {/,/^}/p' "$LIB")"
  kubectl() { return 1; }   # every query fails: wrong context / API error / no RBAC
  assert_no_pods_match "any=selector"
)"
rc=$?
if [ "$rc" = 9 ] && [[ "$out" == ABORT:* ]]; then
  pass "a failing kubectl aborts instead of asserting an empty candidate set"
else
  fail "a failing kubectl did not abort (rc=$rc, out=$out) -- defense #1 is failing open"
fi

# And the same helper must still pass when the query genuinely returns nothing.
out="$(
  set -uo pipefail
  # shellcheck disable=SC2034  # NS is read by the eval'd count_pool_pods, which shellcheck cannot follow
  NS=default
  ok() { echo "OK:$1"; }
  abort() { echo "ABORT:$1"; exit 9; }
  eval "$(sed -n '/^count_pool_pods() {/,/^}/p;/^assert_no_pods_match() {/,/^}/p' "$LIB")"
  kubectl() { return 0; }   # succeeds, no pods
  assert_no_pods_match "any=selector"
)"
if [[ "$out" == OK:* ]]; then
  pass "an empty result still passes (the assertion is not merely always-abort)"
else
  fail "an empty result did not pass (out=$out)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "PASS: lib-relay.sh is shared, unshadowed, and fails closed"
else
  echo "FAIL: $FAILS assertion(s) failed"
fi
exit "$FAILS"
