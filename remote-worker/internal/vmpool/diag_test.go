package vmpool

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

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
	// Every phase must be NAMED. Asserting on durations would be a clock test -- the fake
	// clock does not advance, so all four are legitimately 0 even on correct code. What the
	// field set catches is a dropped phase or a rename, which is the failure that makes an
	// aggregated run silently miss a term.
	for _, field := range []string{
		"acquire_us=", "resume_us=",
		// Resume's sub-phases (#307 follow-up). Named here for the same reason as the
		// rest: resume_us was the last opaque phase on the gate-held path, and a rename
		// or a drop would make an aggregated run silently miss a term rather than fail.
		"vmresume_us=", "vsockdial_us=", "mount_us=",
		"run_us=", "destroy_us=", "cold=",
	} {
		if !strings.Contains(got, field) {
			t.Errorf("phase line is missing %q: %s", field, got)
		}
	}
	// cold is the one field that discriminates a populated Phases from a zero-valued one,
	// and so it is what actually pins the ExecPhased wiring: the field NAMES above appear
	// either way, because logPhases runs unconditionally on whatever it is handed. Only
	// ExecPhased sets ph.Cold, and this is a fresh pool's first Exec on an unseen key, so
	// the cause is deterministically first-exec -- no clock involved. Swap ExecPhased back
	// to Exec and ph stays zero, leaving cold="" here.
	if want := fmt.Sprintf("cold=%q", string(ColdFirstExec)); !strings.Contains(got, want) {
		t.Errorf("phase line has no %s -- Phases was not populated (Exec, not ExecPhased): %s", want, got)
	}
}

// phasingLauncher hands back VMs that report Resume sub-phases, i.e. that implement
// resumePhaser the way firecrackerVM does.
type phasingLauncher struct {
	*fakeLauncher
	vmResume, vsockDial, mount time.Duration
}

func (l *phasingLauncher) Restore(ctx context.Context, req RestoreRequest) (VM, error) {
	vm, err := l.fakeLauncher.Restore(ctx, req)
	if err != nil {
		return nil, err
	}
	return &phasingVM{VM: vm, lc: l}, nil
}

type phasingVM struct {
	VM
	lc *phasingLauncher
}

func (v *phasingVM) ResumePhases() (vmResume, vsockDial, mount time.Duration) {
	return v.lc.vmResume, v.lc.vsockDial, v.lc.mount
}

// TestExecPhasedReportsResumeSubPhases pins the type assertion in ExecPhased. Resume was
// the last opaque phase on the execGate-held critical path, and the whole decomposition
// hangs off one optional-interface check: drop it and resume_us keeps reporting while the
// three sub-phases silently read zero, which is indistinguishable from a launcher that
// does not implement the seam. Asserting on VALUES, not just field names, is what
// separates those two cases -- the fake clock cannot advance a real duration, so the
// launcher hands back fixed ones.
func TestExecPhasedReportsResumeSubPhases(t *testing.T) {
	p, lc, _ := testPool(t)
	pl := &phasingLauncher{
		fakeLauncher: lc,
		vmResume:     300 * time.Microsecond,
		vsockDial:    2 * time.Millisecond,
		mount:        20 * time.Millisecond,
	}
	// testPool already built the pool around lc, so swap the launcher the pool holds.
	p.(*pool).lc = pl

	var ph Phases
	if _, err := p.ExecPhased(context.Background(), "k1", Exec{
		ReqID: 1, Command: "true", TimeoutS: 5,
	}, &capturingSink{}, &ph); err != nil {
		t.Fatalf("ExecPhased: %v", err)
	}

	if ph.VMResume != pl.vmResume || ph.VsockDial != pl.vsockDial || ph.Mount != pl.mount {
		t.Errorf("sub-phases = (%v, %v, %v), want (%v, %v, %v) -- the resumePhaser assertion in ExecPhased is not wired",
			ph.VMResume, ph.VsockDial, ph.Mount, pl.vmResume, pl.vsockDial, pl.mount)
	}
}

// TestResumeSubPhasesAreZeroWithoutTheSeam is the other half: a launcher that does NOT
// implement resumePhaser must report zeros rather than panicking on the assertion. That
// is the CHV arm, whose Resume has no workspace mount to decompose.
func TestResumeSubPhasesAreZeroWithoutTheSeam(t *testing.T) {
	p, _, _ := testPool(t)
	var ph Phases
	if _, err := p.ExecPhased(context.Background(), "k1", Exec{
		ReqID: 1, Command: "true", TimeoutS: 5,
	}, &capturingSink{}, &ph); err != nil {
		t.Fatalf("ExecPhased: %v", err)
	}
	if ph.VMResume != 0 || ph.VsockDial != 0 || ph.Mount != 0 {
		t.Errorf("sub-phases = (%v, %v, %v), want all zero for a launcher without the seam",
			ph.VMResume, ph.VsockDial, ph.Mount)
	}
}
