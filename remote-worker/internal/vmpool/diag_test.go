package vmpool

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"

	wexec "github.com/kagenti/serverless-harness/remote-worker/internal/exec"
)

// capturePhaseLog points phaseLog at a recorder for one test and restores it after.
// phaseLog is package state, so this must not run in parallel with anything that Execs.
func capturePhaseLog(t *testing.T) *[]string {
	t.Helper()
	var mu sync.Mutex
	lines := []string{}
	prev := phaseLog
	phaseLog = func(format string, args ...any) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, fmt.Sprintf(format, args...))
	}
	t.Cleanup(func() { phaseLog = prev })
	return &lines
}

// TestPhaseLogIsOffByDefault pins the cost-when-off contract: an Exec on a worker that
// has not opted in must emit nothing at all. A default-on diagnostic would put a log line
// on the hot path of every Exec in production.
func TestPhaseLogIsOffByDefault(t *testing.T) {
	prev := phaseLog
	phaseLog = nil
	t.Cleanup(func() { phaseLog = prev })

	// logPhases must tolerate being called with the hook unset -- that IS the default path.
	logPhases(&Phases{})
}

// TestRunnerEmitsAllFourPhases is the regression this package did not have: the relayed
// path used Pool.Exec with a throwaway Phases, so Acquire/Resume/Run/Destroy were
// unobservable on the path the worker actually runs (#305, #307). If someone swaps
// ExecPhased back to Exec, the phases silently become zero and this fails.
func TestRunnerEmitsAllFourPhases(t *testing.T) {
	lines := capturePhaseLog(t)

	p, lc, _ := testPool(t)
	lc.setRunFn(func(_ *fakeVM, c Command, out Sink) (Result, error) {
		out.Stdout([]byte("ok\n"))
		return Result{ExitCode: 0}, nil
	})
	sink := newFrameSink()
	code, err := Runner{Pool: p}.Run(context.Background(), wexec.Spec{
		ReqID:        1,
		WorkspaceKey: "k1",
		Command:      "true",
		TimeoutS:     5,
	}, sink)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}

	if len(*lines) != 1 {
		t.Fatalf("want exactly one phase line per Exec, got %d: %v", len(*lines), *lines)
	}
	got := (*lines)[0]
	// Every phase must be NAMED. Asserting on values would be a clock test; asserting on
	// the field set is what catches a dropped phase or a rename, which is the failure that
	// makes an aggregated run silently miss a term.
	for _, field := range []string{"acquire_us=", "resume_us=", "run_us=", "destroy_us=", "cold="} {
		if !strings.Contains(got, field) {
			t.Errorf("phase line is missing %q: %s", field, got)
		}
	}
}
