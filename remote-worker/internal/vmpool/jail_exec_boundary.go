package vmpool

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// procCommLen is TASK_COMM_LEN-1: the kernel stores a task name in 16 bytes including the NUL,
// so /proc/<pid>/comm holds at most 15 characters and a longer exec-file basename arrives
// TRUNCATED. Comparing against the untruncated name would silently never match, and the
// instrument would then report -1 forever -- indistinguishable from a platform with no procfs.
const procCommLen = 15

// fcProcComm reads a pid's comm. A variable for the same reason socketProbe is one: it lets the
// boundary be tested without procfs, which darwin does not have, and without a real jailer.
//
// A missing or unreadable comm is reported as "cannot tell" rather than as an empty name, so the
// caller can distinguish it from a name that simply has not flipped yet.
var fcProcComm = func(pid int) (string, bool) {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/comm")
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(b)), true
}

// fcExecBoundary observes the moment the jailer execve's into Firecracker, which is what splits
// the pre-socket window into the jailer's work and Firecracker's.
//
// WHY THIS IS NEEDED (#328). The `jailer` phase measured time.Since AFTER cmd.Start() returns --
// fork/exec RETURNING, 0.34-1.62 ms across a whole ladder -- so the jailer's 6-8 ms of chroot
// construction landed in the sockwait bucket instead. sockwait then read as "Firecracker is slow
// to bind" for two rounds of analysis, when Firecracker binds its socket in well under a
// millisecond. Measured on srv-r16b14s16, n=8, cold: comm flips at 4.86 ms, socket bound at
// 5.23 ms -- jailer_setup is 93% of the window and fc_bind is 0.37 ms.
//
// WHY comm AND NOT A FILE. The jailer execve's rather than forking, so cmd.Process.Pid names the
// Firecracker process too -- which makes the comm flip the execve ITSELF rather than a proxy for
// it. #328 floated two filesystem proxies and measurement rejected both: firecracker.pid appears
// 0.20 ms early (the jailer writes it just before the execve) and the jail directory appears at
// 1.55 ms, 68% of the window too early.
//
// It is also a DIAGNOSTIC and must never change a restore. Nothing here can fail a Restore: an
// unobservable boundary is reported as unobserved and the restore proceeds on sockwait alone.
type fcExecBoundary struct {
	pid   int
	want  string // the jailed binary's comm, already truncated to procCommLen
	start time.Time

	at   time.Duration
	seen bool
}

// newFCExecBoundary prepares an observer for the jailer at pid. start is the instant the sockwait
// window opens, so elapsed() is directly comparable with the sockwait total.
func newFCExecBoundary(pid int, execPath string, start time.Time) *fcExecBoundary {
	want := filepath.Base(execPath)
	if len(want) > procCommLen {
		want = want[:procCommLen]
	}
	return &fcExecBoundary{pid: pid, want: want, start: start}
}

// observe is waitForUnixSocketObserved's per-poll hook. It SELF-DISABLES after the flip: a
// sockwait of tens of milliseconds is ~27 poll iterations at #304's schedule, and paying a procfs
// read for every one of them after the answer is known would put the instrument on the critical
// path of the thing it measures. Latching also keeps the FIRST observation, so a comm that changes
// again later cannot move the boundary.
func (b *fcExecBoundary) observe() {
	if b == nil || b.seen {
		return
	}
	comm, ok := fcProcComm(b.pid)
	if !ok || comm != b.want {
		return
	}
	b.at = time.Since(b.start)
	b.seen = true
}

// elapsed reports how long the jailer took to reach its execve, and whether that was observed at
// all. Nil-safe, because the production path constructs no boundary.
func (b *fcExecBoundary) elapsed() (time.Duration, bool) {
	if b == nil {
		return 0, false
	}
	return b.at, b.seen
}

// restorePhases carries one restore's decomposition. A struct rather than eight positional
// arguments because two of the fields only mean anything together with boundaryObserved.
type restorePhases struct {
	prep, wsimg, spawn time.Duration
	// jailerSetup and fcBind partition sock, and are meaningful only when boundaryObserved.
	jailerSetup, fcBind time.Duration
	boundaryObserved    bool
	sock, load, total   time.Duration
}

// logRestorePhases emits one line per restore. Kept beside the boundary rather than inline in
// Restore for the reason diag.go's logPhases gives: the field names are parsed by whatever
// aggregates a run, so they belong in one place where a rename is visible.
//
// spawn_us REPLACES the old jailer_us, which named the jailer's work while measuring fork/exec
// returning. sockwait_us is kept unchanged alongside the split so #328's tables and the campaign
// notes stay comparable against new runs.
//
// An unobserved boundary reports -1, never 0: a 0 would aggregate as "the jailer took no time",
// which is the same wrong conclusion the old mis-attribution produced.
func logRestorePhases(id string, p restorePhases) {
	if phaseLog == nil {
		return
	}
	setup, bind := int64(-1), int64(-1)
	if p.boundaryObserved {
		setup, bind = p.jailerSetup.Microseconds(), p.fcBind.Microseconds()
	}
	phaseLog("vmpool: restore phases id=%s prep_us=%d wsimg_us=%d spawn_us=%d jailersetup_us=%d "+
		"fcbind_us=%d sockwait_us=%d loadsnap_us=%d total_us=%d",
		id, p.prep.Microseconds(), p.wsimg.Microseconds(), p.spawn.Microseconds(),
		setup, bind, p.sock.Microseconds(), p.load.Microseconds(), p.total.Microseconds())
}
