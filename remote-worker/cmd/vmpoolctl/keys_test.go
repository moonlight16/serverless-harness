package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// decode unmarshals the one --json record realMain emits. The existing tests inline this;
// the two below assert on two fields each, so it is worth a helper rather than a fourth
// copy of the same three lines.
func decode(t *testing.T, out string) runResult {
	t.Helper()
	var rec runResult
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &rec); err != nil {
		t.Fatalf("unmarshal %q: %v", out, err)
	}
	return rec
}

// --keys exists because --concurrency alone cannot produce concurrency on the Firecracker
// arm, and #307's original per-Exec table is what that costs when it goes unnoticed: it
// reported Destroy as identical at "c=8" and "c=16" and concluded teardown does not scale
// with load, when the launcher's SerializesExecsPerRun had held both runs to one VM at a
// time. These tests pin the three parts of the fix separately -- the key itself, the
// refusal, and the warmup -- because each fails in a different, quiet way.

// keys=1 must be byte-identical to the behaviour before --keys existed, so every recorded
// invocation in the notes still means what it says.
func TestExecKeyLeavesASingleKeyUntouched(t *testing.T) {
	for _, i := range []int{0, 1, 7, 1000} {
		if got := execKey("run-1", 1, i); got != "run-1" {
			t.Errorf("execKey(run-1, 1, %d) = %q, want the bare key", i, got)
		}
	}
	// 0 and negative are not reachable through realMain (the flag is validated), but
	// execKey is the function the measured loop calls per iteration and must not return
	// a suffixed key for them.
	if got := execKey("run-1", 0, 3); got != "run-1" {
		t.Errorf("execKey with keys=0 = %q, want the bare key", got)
	}
}

// Round-robin rather than random or per-goroutine: with iterations >> keys every run pool
// gets the same number of Execs, so no single pool's standby depth is favoured and the
// per-key load is even by construction rather than in expectation.
func TestExecKeyRoundRobinsAcrossKeys(t *testing.T) {
	seen := map[string]int{}
	for i := 0; i < 12; i++ {
		seen[execKey("run", 4, i)]++
	}
	if len(seen) != 4 {
		t.Fatalf("distinct keys = %d, want 4: %v", len(seen), seen)
	}
	for k, n := range seen {
		if n != 3 {
			t.Errorf("key %q ran %d times, want 3 (round-robin must be even)", k, n)
		}
	}
	if got := execKey("run", 4, 5); got != "run-k1" {
		t.Errorf("execKey(run, 4, 5) = %q, want run-k1", got)
	}
}

// Refused, not clamped. A clamp would produce a record reading concurrency=16 for a run
// that never had more than one VM alive -- which is precisely the artifact this flag was
// added to make impossible, so accepting the flags and fixing them up silently would
// reintroduce it behind a warning.
func TestRefusesConcurrencyAboveKeysOnFirecracker(t *testing.T) {
	dir := t.TempDir()
	_, err := run(t, "--vmm=firecracker", "--snapshot-dir="+dir, "--workspace-root="+dir,
		"--key=k", "--iterations=100", "--concurrency=8", "--keys=2", "--", "true")
	if err == nil {
		t.Fatal("realMain accepted --concurrency=8 with --keys=2 on the firecracker arm")
	}
	if !strings.Contains(err.Error(), "SerializesExecsPerRun") {
		t.Fatalf("err = %v, want the refusal to name SerializesExecsPerRun as the reason", err)
	}
}

// The same flags are legitimate on an arm that does not serialize per run, so the refusal
// must be scoped to the launcher that has the constraint rather than applied globally.
// --vmm=fake runs host bash and reports SerializesExecsPerRun false.
func TestConcurrencyAboveKeysIsAllowedOffFirecracker(t *testing.T) {
	dir := t.TempDir()
	if _, err := run(t, "--vmm=fake", "--snapshot-dir="+dir, "--workspace-root="+dir,
		"--key=k", "--iterations=20", "--concurrency=4", "--keys=1", "--", "true"); err != nil {
		t.Fatalf("realMain refused a legitimate fake-arm run: %v", err)
	}
}

// Every run pool must have paid its first restore before timing starts. The derived
// default is min(iterations/10, 5), so at --keys=8 it would otherwise warm 5 of 8 pools
// and charge three first-restores to the measured window -- a bias that grows with the
// very variable a slot sweep sweeps.
func TestDerivedWarmupIsFlooredAtOnePerKey(t *testing.T) {
	dir := t.TempDir()
	out, err := run(t, "--vmm=fake", "--snapshot-dir="+dir, "--workspace-root="+dir,
		"--key=k", "--iterations=40", "--concurrency=1", "--keys=8", "--json", "--", "true")
	if err != nil {
		t.Fatalf("realMain: %v", err)
	}
	rec := decode(t, out)
	if rec.WarmupDiscarded != 8 {
		t.Errorf("warmup_discarded = %d, want 8 (one per key)", rec.WarmupDiscarded)
	}
	if rec.Keys != 8 {
		t.Errorf("keys = %d, want 8 recorded in the record", rec.Keys)
	}
}

// An explicit --warmup is the caller's decision. Raising it would silently discard
// iterations they asked to measure, and "0" is a legitimate, deliberate request.
func TestAnExplicitWarmupIsNotRaisedByKeys(t *testing.T) {
	dir := t.TempDir()
	out, err := run(t, "--vmm=fake", "--snapshot-dir="+dir, "--workspace-root="+dir,
		"--key=k", "--iterations=40", "--concurrency=1", "--keys=8", "--warmup=0", "--json", "--", "true")
	if err != nil {
		t.Fatalf("realMain: %v", err)
	}
	if rec := decode(t, out); rec.WarmupDiscarded != 0 {
		t.Errorf("warmup_discarded = %d, want 0 (an explicit warmup must survive --keys)", rec.WarmupDiscarded)
	}
}
