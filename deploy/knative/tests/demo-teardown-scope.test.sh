#!/usr/bin/env bash
# deploy/knative/tests/demo-teardown-scope.test.sh
#
# Unit test for demo-remote-worker.sh's teardown scope: `--teardown` must not silently
# delete a kind cluster the demo did not create. --reuse-cluster exists precisely so the
# demo can run against a long-lived dev cluster, and nothing in a fresh --teardown process
# records who created $CLUSTER_NAME -- so the safe default is to ask, and to keep the
# cluster when there is no one to ask.
#
# No cluster required: kind/kubectl/docker are mocked on PATH and only the call log is
# asserted. Run: bash deploy/knative/tests/demo-teardown-scope.test.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/demo-remote-worker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export MOCK_LOG="$TMP/calls.log"

# --- mocks: log every call. `kind get clusters` reports the demo's cluster as present, so
# the teardown path always has a cluster it *could* delete. ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kind" <<'EOF'
#!/usr/bin/env bash
echo "kind $*" >> "$MOCK_LOG"
[ "${1:-} ${2:-}" = "get clusters" ] && echo "sh-knative"
exit 0
EOF
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$MOCK_LOG"
exit 0
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$MOCK_LOG"
exit 0
EOF
chmod +x "$TMP/bin/kind" "$TMP/bin/kubectl" "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

FAILS=0
assert_grep()   { if grep -q -- "$1" "$MOCK_LOG"; then echo "  ok: $2"; else echo "  FAIL: $2 (expected /$1/)"; FAILS=$((FAILS+1)); fi; }
assert_absent() { if grep -q -- "$1" "$MOCK_LOG"; then echo "  FAIL: $2 (unexpected /$1/)"; FAILS=$((FAILS+1)); else echo "  ok: $2"; fi; }

# Runs the demo's teardown with stdin closed (no tty), so confirm_cluster_delete takes its
# non-interactive branch. CLUSTER_NAME is pinned to keep the mock and the assertions aligned.
run_teardown() {
  : > "$MOCK_LOG"
  CLUSTER_NAME=sh-knative bash "$SCRIPT" --teardown "$@" < /dev/null > "$TMP/out.txt" 2>&1
}

echo "case 1: --teardown with no tty and no --yes -> keeps the cluster, removes the rest"
run_teardown
assert_absent "kind delete"   "does not delete a cluster it cannot confirm ownership of"
assert_grep   "docker rm -f"  "still removes the worker container"
assert_grep   "docker rmi"    "still removes the built image"
assert_grep   "kubectl delete -f relay-deployment.yaml" "still removes the relay"
if grep -q "left running" "$TMP/out.txt"; then
  echo "  ok: says the cluster was left running"
else
  echo "  FAIL: does not tell the user the cluster survived"; FAILS=$((FAILS+1))
fi
if grep -q -- "--yes" "$TMP/out.txt"; then
  echo "  ok: names --yes as the way to delete it"
else
  echo "  FAIL: does not name the flag that would delete the cluster"; FAILS=$((FAILS+1))
fi

echo
echo "case 2: --teardown --yes -> deletes the cluster"
run_teardown --yes
assert_grep "kind delete cluster --name sh-knative" "deletes the cluster when explicitly told to"

echo
echo "case 3: -y is accepted as the short form"
run_teardown -y
assert_grep "kind delete cluster --name sh-knative" "-y also confirms"

echo
echo "case 4: the normal-exit hint never advertises --teardown for a cluster it did not create"
# CREATED_CLUSTER is raised only on the path that creates the cluster, so the reused-cluster
# branch of cleanup() must not point the reader at a command that destroys it.
if grep -q 'CREATED_CLUSTER=1' "$SCRIPT"; then
  echo "  ok: the script tracks whether this run created the cluster"
else
  echo "  FAIL: nothing records who created the cluster"; FAILS=$((FAILS+1))
fi
# The teardown hint must be inside a CREATED_CLUSTER guard, not unconditional.
if awk '/if \[ "\$CREATED_CLUSTER" = 1 \]/,/^    fi$/' "$SCRIPT" | grep -q -- '\$0 --teardown'; then
  echo "  ok: the '--teardown' hint is gated on this run having created the cluster"
else
  echo "  FAIL: the '--teardown' hint is not gated on CREATED_CLUSTER"; FAILS=$((FAILS+1))
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "PASS: teardown never deletes an unconfirmed cluster"
else
  echo "FAIL: $FAILS assertion(s) failed"
fi
exit "$FAILS"
