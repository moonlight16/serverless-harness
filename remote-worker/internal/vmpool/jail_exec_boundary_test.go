package vmpool

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// #328. The `jailer` phase times time.Since AFTER cmd.Start() returns, so it measures
// fork/exec RETURNING -- 0.34-1.62 ms across a whole ladder -- while the jailer's 6-8 ms of
// chroot construction lands in the sockwait bucket. That mis-attribution is why the pre-socket
// wait read as "Firecracker is slow to bind" for two rounds of analysis, and it would equally
// obscure whether jail pooling worked.
//
// Measured on srv-r16b14s16, n=8 cold, from the jailer being spawned: the comm flip is at
// 4.86 ms and the socket is bound at 5.23 ms, so jailer_setup is 93% of the pre-socket window
// and fc_bind is 0.37 ms. These tests pin the instrument, not those numbers.
func TestExecBoundaryRecordsTheCommFlipAndThenStopsReading(t *testing.T) {
	reads := 0
	restore := fcProcComm
	fcProcComm = func(int) (string, bool) {
		reads++
		if reads < 3 {
			return "jailer", true
		}
		return "firecracker", true
	}
	t.Cleanup(func() { fcProcComm = restore })

	b := newFCExecBoundary(1234, "/usr/local/bin/firecracker", time.Now())
	b.observe() // jailer
	b.observe() // jailer
	if at, ok := b.elapsed(); ok {
		t.Fatalf("boundary fired while comm was still jailer (at=%s)", at)
	}
	b.observe() // firecracker -- the execve
	at, ok := b.elapsed()
	if !ok {
		t.Fatal("boundary did not fire when comm flipped to firecracker")
	}
	if at <= 0 {
		t.Fatalf("boundary elapsed must be positive, got %s", at)
	}

	// Self-disabling: the remaining poll iterations of a ~20 ms sockwait must not each pay a
	// procfs read, and a LATER flip must not overwrite the first observation.
	before := reads
	b.observe()
	b.observe()
	if reads != before {
		t.Fatalf("observe kept reading comm after the flip: %d extra reads", reads-before)
	}
	if again, _ := b.elapsed(); again != at {
		t.Fatalf("elapsed moved after the flip: %s -> %s", at, again)
	}
}

// Unobservable is reported as unobservable, never as a plausible zero: a 0 in this field would
// aggregate as "the jailer took no time", which is the same wrong conclusion the mis-attribution
// above produced. Reachable on any platform without procfs, and whenever the jailer dies before
// it execs.
func TestExecBoundaryReportsUnobservedWhenCommNeverFlips(t *testing.T) {
	restore := fcProcComm
	fcProcComm = func(int) (string, bool) { return "", false }
	t.Cleanup(func() { fcProcComm = restore })

	b := newFCExecBoundary(1234, "/usr/local/bin/firecracker", time.Now())
	for i := 0; i < 5; i++ {
		b.observe()
	}
	if at, ok := b.elapsed(); ok {
		t.Fatalf("boundary claimed an observation with no procfs, at=%s", at)
	}
}

// comm is TASK_COMM_LEN-1 = 15 characters, so a longer exec-file basename arrives TRUNCATED and
// an equality test against the full name silently never matches -- the instrument would then
// report -1 forever and read as "this platform has no procfs".
func TestExecBoundaryMatchesATruncatedComm(t *testing.T) {
	const long = "firecracker-v1.17.0-custom" // 26 chars; comm will hold 15
	restore := fcProcComm
	fcProcComm = func(int) (string, bool) { return long[:15], true }
	t.Cleanup(func() { fcProcComm = restore })

	b := newFCExecBoundary(1234, "/opt/bin/"+long, time.Now())
	b.observe()
	if _, ok := b.elapsed(); !ok {
		t.Fatalf("boundary missed a comm truncated to 15 chars (want prefix of %q)", long)
	}
}

// The split must reuse waitForUnixSocket's poll rather than adding a second loop: #304's
// schedule is the RESOLUTION at which sockwait can be measured, and two loops with two
// schedules would make jailer_setup and fc_bind accurate to different quanta.
func TestWaitForUnixSocketRunsTheObserverOnEveryPoll(t *testing.T) {
	probes, observed := 0, 0
	restore := socketProbe
	socketProbe = func(string) bool {
		probes++
		return probes >= 4
	}
	t.Cleanup(func() { socketProbe = restore })

	err := waitForUnixSocketObserved(context.Background(), "/nonexistent.sock",
		time.Second, func() { observed++ })
	if err != nil {
		t.Fatalf("waitForUnixSocketObserved: %v", err)
	}
	if observed != probes {
		t.Fatalf("observer ran %d times for %d probes; it must run once per poll", observed, probes)
	}
}

// A nil observer is the production path, and it must stay exactly the old loop -- the point of
// gating the observation on phaseLog is that no restore pays a procfs read when diagnostics are
// off.
func TestWaitForUnixSocketToleratesNoObserver(t *testing.T) {
	restore := socketProbe
	socketProbe = func(string) bool { return true }
	t.Cleanup(func() { socketProbe = restore })

	if err := waitForUnixSocket(context.Background(), "/nonexistent.sock", time.Second); err != nil {
		t.Fatalf("waitForUnixSocket with no observer: %v", err)
	}
}

// The field names are parsed by whatever aggregates a run, so they are asserted here: a silently
// renamed field reads downstream as a missing phase rather than as an error. jailer_us is
// deliberately GONE -- it named the jailer's work while measuring fork/exec returning, which is
// the mis-attribution this change exists to remove; spawn_us measures that honestly.
func TestRestorePhaseLineNamesEveryField(t *testing.T) {
	var got string
	restore := phaseLog
	phaseLog = func(format string, args ...any) { got = fmt.Sprintf(format, args...) }
	t.Cleanup(func() { phaseLog = restore })

	logRestorePhases("vm-1", restorePhases{
		prep: time.Millisecond, wsimg: 2 * time.Millisecond, spawn: 3 * time.Millisecond,
		jailerSetup: 4 * time.Millisecond, boundaryObserved: true,
		fcBind: 5 * time.Millisecond, sock: 9 * time.Millisecond,
		load: 6 * time.Millisecond, total: 21 * time.Millisecond,
	})
	for _, want := range []string{
		"id=vm-1", "prep_us=1000", "wsimg_us=2000", "spawn_us=3000",
		"jailersetup_us=4000", "fcbind_us=5000", "sockwait_us=9000",
		"loadsnap_us=6000", "total_us=21000",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("restore phase line missing %q\ngot: %s", want, got)
		}
	}
	if strings.Contains(got, "jailer_us=") {
		t.Errorf("jailer_us must be gone -- it mis-named fork/exec as the jailer's work\ngot: %s", got)
	}
}

// sockwait_us is KEPT alongside the split so #328's tables and the campaign notes stay
// comparable, and it must keep meaning the whole pre-socket window even when the boundary could
// not be observed.
func TestRestorePhaseLineReportsAnUnobservedBoundaryAsMinusOne(t *testing.T) {
	var got string
	restore := phaseLog
	phaseLog = func(format string, args ...any) { got = fmt.Sprintf(format, args...) }
	t.Cleanup(func() { phaseLog = restore })

	logRestorePhases("vm-2", restorePhases{
		sock: 9 * time.Millisecond, boundaryObserved: false, total: 9 * time.Millisecond,
	})
	if !strings.Contains(got, "jailersetup_us=-1") || !strings.Contains(got, "fcbind_us=-1") {
		t.Errorf("an unobserved boundary must report -1, not 0\ngot: %s", got)
	}
	if !strings.Contains(got, "sockwait_us=9000") {
		t.Errorf("sockwait_us must survive an unobserved boundary\ngot: %s", got)
	}
}
