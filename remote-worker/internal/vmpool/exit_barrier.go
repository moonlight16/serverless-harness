package vmpool

import (
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// fcProcFDCount reports how many descriptors a pid still holds, and whether that could be
// read at all. A package var for the same reason fcProcComm is one (jail_exec_boundary.go):
// it lets the barrier be tested without procfs, which darwin does not have.
//
// AN UNREADABLE COUNT IS "CANNOT TELL", NEVER ZERO. os.ReadDir on a vanished /proc/<pid>/fd
// returns an error, and treating that as "no descriptors left" would report the barrier at
// the instant the process was already reaped -- the one reading that would make a real gate
// look safe to open when it is not. Same posture as cgroupPool.release refusing to reuse a
// cgroup whose procs it cannot read.
var fcProcFDCount = func(pid int) (int, bool) {
	ents, err := os.ReadDir("/proc/" + strconv.Itoa(pid) + "/fd")
	if err != nil {
		return 0, false
	}
	return len(ents), true
}

// fcProcThreadCount reports the pid's thread-group size from /proc/<pid>/status. 1 means
// only the group leader is left, so every vCPU and device thread has finished exiting.
var fcProcThreadCount = func(pid int) (int, bool) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/status")
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(b), "\n") {
		rest, ok := strings.CutPrefix(line, "Threads:")
		if !ok {
			continue
		}
		n, err := strconv.Atoi(strings.TrimSpace(rest))
		if err != nil {
			return 0, false
		}
		return n, true
	}
	return 0, false
}

// fcExitObserver times the two points, after a SIGKILL, that bound what a dying VMM can
// still do to the workspace image. Both are measured from the kill, so both are directly
// comparable with the wait_us the same Destroy reports.
//
// WHY THIS EXISTS (#307). execGate is held until cmd.Wait returns because "a second guest
// mounting [the ext4 workspace] rw while the first still holds it would corrupt it". cmd.Wait
// is 19.28 ms at c=1 rising to 52.48 ms at c=64, and #307 localised all of it to KVM
// structure teardown under kvm_vm_release -- reached from __fput in task_work_run during
// do_exit, i.e. AFTER exit_mm and exit_files. A teardown-standby VM, which never mounted the
// image at all, pays 16.04 ms of teardown-inflight's 17.48 ms, so that window is demonstrably
// not mount work. What is missing is an OBSERVABLE for where it becomes safe.
//
// TWO CANDIDATES, AND THEY ARE NOT EQUIVALENT:
//
//   - fdGone: /proc/<pid>/fd is empty. This is the correctness property ITSELF rather than a
//     proxy -- a process holding no descriptor on workspace.img cannot write to it. exit_files
//     drops every f_count before the expensive __fput work runs, so this is expected to land
//     early, at the START of the grace period rather than the end.
//   - threadsGone: /proc/<pid>/status Threads: is 1. Weaker (the leader still exists and its
//     own exit is unfinished) but it proves no vCPU or device thread is left to ISSUE a write.
//     Firecracker services virtio-blk on its own threads, so this bounds the window in which
//     an in-flight pwrite could still land.
//
// Both are reported because either could turn out to track cmd.Wait rather than precede it,
// and #307 already found that /proc/<pid> itself tracks wait4 to within 0.02 ms -- the task
// is alive in do_exit for the whole window, never a zombie, so the obvious probe answers
// nothing. If neither barrier lands early there is no observable one and the deferral has to
// rest on argument instead; that is a finding, not a failure.
//
// A DIAGNOSTIC, and it must never change a teardown. Nothing here can fail a Destroy: an
// unobservable barrier is reported as unobserved and the reap proceeds.
type fcExitObserver struct {
	pid   int
	start time.Time

	// mu guards the latches: poll runs on its own goroutine so it cannot delay cmd.Wait,
	// which is the very quantity it is being compared against.
	mu                  sync.Mutex
	fdAt, threadsAt     time.Duration
	fdSeen, threadsSeen bool
}

// newFCExitObserver prepares an observer for a pid that has just been signalled. start is
// the instant of the kill, so both barriers are comparable with wait_us.
func newFCExitObserver(pid int, start time.Time) *fcExitObserver {
	return &fcExitObserver{pid: pid, start: start}
}

// poll samples both barriers once, latching the FIRST observation of each. Latching matters
// for the same reason it does in fcExecBoundary.observe: a count that dips and recovers must
// not be able to move an answer already taken.
func (o *fcExitObserver) poll() {
	if o == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.fdSeen {
		if n, ok := fcProcFDCount(o.pid); ok && n == 0 {
			o.fdAt, o.fdSeen = time.Since(o.start), true
		}
	}
	if !o.threadsSeen {
		if n, ok := fcProcThreadCount(o.pid); ok && n <= 1 {
			o.threadsAt, o.threadsSeen = time.Since(o.start), true
		}
	}
}

// done reports that both barriers have been observed, so the polling goroutine can stop
// reading procfs for a process whose answers are already known.
func (o *fcExitObserver) done() bool {
	if o == nil {
		return false
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.fdSeen && o.threadsSeen
}

// results reports both barriers and whether each was observed at all. An unobserved barrier
// must be rendered as -1 by the caller, never 0 -- see logRestorePhases for what a 0 does to
// an aggregate.
func (o *fcExitObserver) results() (fd, threads time.Duration, fdSeen, threadsSeen bool) {
	if o == nil {
		return 0, 0, false, false
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.fdAt, o.threadsAt, o.fdSeen, o.threadsSeen
}

// fcExitBarrierPoll is the sampling interval. 50µs against a wait of 19-52 ms resolves the
// question this instrument asks -- "does a barrier land EARLY, or does it track wait4?" -- to
// 0.26%, and against the ~0.4 ms the cheap part of an exit is expected to take, to 12%. A
// tighter spin would answer no better and would steal CPU from the very task it is timing:
// at 64 concurrent destroys a sleepless loop is 64 busy cores. #304 is the cautionary case in
// the other direction -- a 20 ms quantum in which "appears at 2 ms" and "appears at 19 ms" are
// the same sample, which produced a 5x claim that was really 18%.
const fcExitBarrierPoll = 50 * time.Microsecond

// startFCExitObserver begins watching a signalled pid, returning the observer and a stop
// function that must be called before the results are read.
//
// OFF BY DEFAULT, and off means no goroutine and no procfs read at all: this samples two
// procfs files in a loop, which is nothing like the ~100ns the unconditional time.Now() calls
// in Destroy cost, so it cannot be left on for production teardowns. phaseLog IS the
// SH_DIAG_PHASES gate (diag.go sets it once, in init).
//
// Polling on its own goroutine rather than before cmd.Wait is deliberate: the barriers are
// being compared against the wait, and a probe that delayed the wait would move the number it
// is measured against.
func startFCExitObserver(pid int, start time.Time) (*fcExitObserver, func()) {
	if phaseLog == nil {
		return nil, func() {}
	}
	o := newFCExitObserver(pid, start)
	stop := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			o.poll()
			if o.done() {
				return
			}
			select {
			case <-stop:
				return
			case <-time.After(fcExitBarrierPoll):
			}
		}
	}()
	return o, func() {
		close(stop)
		<-done
	}
}

// barrierUs renders one barrier for the phase line: microseconds when observed, -1 when not.
// NEVER 0 for unobserved -- see fcExitObserver's doc comment for what that reading would
// license.
func barrierUs(d time.Duration, seen bool) int64 {
	if !seen {
		return -1
	}
	return d.Microseconds()
}

// fcBarrierTimeout bounds the production barrier. p95 is 4.62 ms and the worst of 1216
// samples was 8.85 ms at c=64, so 100 ms is ~11x the worst observed -- generous enough that
// hitting it means something is genuinely wrong, and short enough that it cannot wedge a run.
// Exceeding it is NOT tolerated silently: pool.destroy turns it into the old synchronous
// ordering, which is the only safe fallback.
const fcBarrierTimeout = 100 * time.Millisecond

// fcWaitFDsGone blocks until pid holds no file descriptor, returning how long that took and
// whether it was observed at all.
//
// THIS RUNS INSIDE execGate, which is the difference between it and fcExitObserver: it is
// production, not diagnostics, so it is bounded and it does not spawn a goroutine. What it buys
// is the other 96% -- the gate is released here instead of after cmd.Wait, which is 1.41 ms
// median rather than 52.88 ms at c=64 (#307).
//
// "Cannot tell" is never "drained": fcProcFDCount reports an unreadable /proc/<pid>/fd as
// (0, false), and only (0, true) satisfies the barrier. Treating an error as zero would open
// the gate for a process that may still hold the image -- and it is the likely reading, since
// a vanished directory is an error and a reaped process has no directory.
func fcWaitFDsGone(pid int, timeout time.Duration) (time.Duration, bool) {
	start := time.Now()
	deadline := start.Add(timeout)
	for {
		if n, ok := fcProcFDCount(pid); ok && n == 0 {
			return time.Since(start), true
		}
		if !time.Now().Before(deadline) {
			return time.Since(start), false
		}
		time.Sleep(fcExitBarrierPoll)
	}
}
