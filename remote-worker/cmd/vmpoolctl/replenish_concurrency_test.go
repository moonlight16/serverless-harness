package main

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/kagenti/serverless-harness/remote-worker/internal/vmpool"
)

// countingHooks records the HIGH WATER MARK of concurrent RestoreOne calls. That is the
// quantity under test: --concurrency is a promise about overlap, and a driver that
// accepts the flag and restores serially anyway reports a c=N rung that ran at c=1.
// #307 published a "flat across c=8/c=16" finding from exactly that defect on the exec
// path (one shared execGate); this is the same defect on the replenish path, where it is
// the loop rather than a gate.
type countingHooks struct {
	mu       sync.Mutex
	inFlight int
	maxSeen  int
	restores atomic.Int64

	// release gates every RestoreOne so the test controls overlap rather than racing
	// it. Without it a fast fake could complete each restore before the next goroutine
	// is scheduled, and maxSeen would read 1 on a CORRECT implementation -- a flaky
	// test that fails for a reason the production code does not have.
	release chan struct{}
}

func (h *countingHooks) RestoreOne(_ context.Context, key string) (vmpool.VM, error) {
	h.mu.Lock()
	h.inFlight++
	if h.inFlight > h.maxSeen {
		h.maxSeen = h.inFlight
	}
	h.mu.Unlock()
	h.restores.Add(1)
	<-h.release
	h.mu.Lock()
	h.inFlight--
	h.mu.Unlock()
	return &countingVM{key: key}, nil
}

func (h *countingHooks) FillStandbys(context.Context, string, int) error { return nil }
func (h *countingHooks) DestroyAllStandbys(context.Context) (int, error) { return 0, nil }

type countingVM struct{ key string }

func (v *countingVM) Key() string                  { return v.key }
func (v *countingVM) Resume(context.Context) error { return nil }
func (v *countingVM) Destroy() error               { return nil }
func (v *countingVM) Run(context.Context, vmpool.Command, vmpool.Sink) (vmpool.Result, error) {
	return vmpool.Result{}, nil
}

// The probe #307's deferred-reap question needs: an aggregate restore RATE at a fixed
// concurrency, with no Execs in the way. runReplenishMode was a serial for loop, so
// --concurrency=64 --mode=replenish measured c=1 and its wall-clock rate was a
// per-restore latency reciprocal rather than a supply ceiling.
func TestModeReplenishOverlapsRestoresAtTheRequestedConcurrency(t *testing.T) {
	const iterations, concurrency = 12, 4
	h := &countingHooks{release: make(chan struct{})}
	// Let every restore through as it arrives; the barrier only stops a restore from
	// finishing before its peers have been counted.
	go func() {
		for i := 0; i < iterations; i++ {
			h.release <- struct{}{}
		}
	}()

	var res runResult
	samples, err := runReplenishMode(h, "run-a", iterations, 0, concurrency, &res)
	if err != nil {
		t.Fatalf("runReplenishMode: %v", err)
	}
	if got := len(samples); got != iterations {
		t.Fatalf("len(samples) = %d, want %d", got, iterations)
	}
	if got := h.restores.Load(); got != int64(iterations) {
		t.Fatalf("RestoreOne called %d times, want %d", got, iterations)
	}
	if h.maxSeen != concurrency {
		t.Fatalf("peak concurrent RestoreOne = %d, want %d: --concurrency is being "+
			"accepted and ignored, so a c=%d rung measures c=%d",
			h.maxSeen, concurrency, concurrency, h.maxSeen)
	}
}

// A mode that ignores --concurrency must REFUSE it rather than silently run at c=1.
// This is the file's established posture for two lists that must agree (see the mode
// dispatcher's default case): make the disagreement loud instead of silent. The cost of
// the silent version is a published number that is wrong by the swept variable.
func TestConcurrencyIsRefusedByModesThatIgnoreIt(t *testing.T) {
	dir := t.TempDir()
	for _, mode := range []string{"teardown-inflight", "teardown-standby", "teardown-bulk"} {
		out, err := run(t, "--vmm=fake", "--snapshot-dir="+dir, "--workspace-root="+dir,
			"--key=run-a", "--mode="+mode, "--iterations=3", "--concurrency=4", "--", "true")
		if err == nil {
			t.Fatalf("--mode=%s --concurrency=4 was accepted; it runs serially, so the "+
				"rung would be labelled c=4 and measured at c=1 (out=%s)", mode, out)
		}
		if !strings.Contains(err.Error(), "concurrency") {
			t.Fatalf("--mode=%s: error %q does not mention concurrency", mode, err)
		}
	}
}

// ...and the modes that DO honour it must keep accepting it, or the refusal above has
// silently disabled the instrument it exists to protect.
func TestConcurrencyIsAcceptedByModesThatHonourIt(t *testing.T) {
	dir := t.TempDir()
	for _, mode := range []string{"exec", "replenish"} {
		if _, err := run(t, "--vmm=fake", "--snapshot-dir="+dir, "--workspace-root="+dir,
			"--key=run-a", "--mode="+mode, "--iterations=4", "--concurrency=2", "--", "true"); err != nil {
			t.Fatalf("--mode=%s --concurrency=2: %v", mode, err)
		}
	}
}

// "Record the configuration next to the number" is the campaign's most expensive lesson:
// #259's two-worker result and E11's c=8 knee were both reproducible, correctly reported, and
// meant something other than what they said, because MaxConcurrent=4 was not in the frame. The
// deferred reap (#307) is an A/B on one binary, so which arm a record came from has to be IN
// the record -- otherwise the two arms are distinguishable only by which shell loop wrote them.
func TestTheRecordCarriesWhetherTheReapWasDeferred(t *testing.T) {
	dir := t.TempDir()
	for _, workers := range []int{0, 8} {
		out, err := run(t, "--vmm=fake", "--snapshot-dir="+dir, "--workspace-root="+dir,
			"--key=run-a", "--iterations=2", "--warmup=0", "--json",
			"--defer-reap-workers="+strconv.Itoa(workers), "--", "true")
		if err != nil {
			t.Fatalf("workers=%d: %v (out=%s)", workers, err, out)
		}
		var rec runResult
		if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &rec); err != nil {
			t.Fatalf("not JSON: %v\n%s", err, out)
		}
		if rec.DeferReapWorkers != workers {
			t.Fatalf("DeferReapWorkers=%d, want %d: the arm is not in the record",
				rec.DeferReapWorkers, workers)
		}
		// A saturated reaper means the arm was only partly applied -- reaps that ran inline paid
		// the synchronous cost anyway -- and it is the first thing to check when a deferral arm
		// measures flat. It has to be readable from the record, not inferred.
		if !strings.Contains(out, `"reaps_inline"`) {
			t.Fatalf("record has no reaps_inline: a saturated reaper would be invisible\n%s", out)
		}
	}
}

// ReplenishDelay defaults to 200 ms, and at 64 slots a slot consumes a VM every ~102 ms -- so
// refilling cannot start until the slot has already been empty for ~100 ms, and a cold acquire
// is structural rather than a symptom of load. #307's deferred reap made the consumer 1.7x
// faster and pushed coldAcquireRateTrue from 0.161 to 0.741, which makes this the knob to sweep
// next. It was not reachable from the driver at all, so no rung had ever varied it.
func TestReplenishDelayIsSettableAndRecorded(t *testing.T) {
	dir := t.TempDir()
	for _, ms := range []int{200, 20} {
		out, err := run(t, "--vmm=fake", "--snapshot-dir="+dir, "--workspace-root="+dir,
			"--key=run-a", "--iterations=2", "--warmup=0", "--json",
			"--replenish-delay-ms="+strconv.Itoa(ms), "--", "true")
		if err != nil {
			t.Fatalf("ms=%d: %v (out=%s)", ms, err, out)
		}
		var rec runResult
		if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &rec); err != nil {
			t.Fatalf("not JSON: %v\n%s", err, out)
		}
		if rec.ReplenishDelayMs != ms {
			t.Fatalf("ReplenishDelayMs=%d, want %d: the knob is not in the record, so two "+
				"rungs that differ only by it are indistinguishable", rec.ReplenishDelayMs, ms)
		}
	}
}
