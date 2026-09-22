//go:build unix

package vmpool

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A short /tmp base, not t.TempDir(): sun_path caps at 104 bytes on darwin (108 on linux),
// and t.TempDir() on darwin is already ~70 before any suffix -- the same reason
// launcher_firecracker_collision_unix_test.go's collisionLauncher does this.
func sockBase(t *testing.T) string {
	t.Helper()
	base, err := os.MkdirTemp("/tmp", "sockwait")
	if err != nil {
		t.Fatalf("MkdirTemp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	return base
}

// Issue #304. waitForUnixSocket retried on a FIXED 20 ms sleep, so every restore paid at
// least one full quantum however fast Firecracker actually bound its socket.
//
// Measured on srv-r16b14s16 over 1,625 restores on an idle box: sockwait 24.92 ms of a
// 27.73 ms restore -- 89.9% -- over 2.80 ms of real work (prep 0.22 + wsimg 0.05 + jailer
// 0.39 + loadsnap 2.14). The distribution was quantized with no tail below the quantum:
// min 20.06 ms, ZERO of 1,625 under 20 ms, 78.2% in [20,40), 21.8% in [40,60).
//
// The quantum was a measurement FLOOR, and removing it was worth ~11% on the mean (24.92 ->
// 22.24 ms), NOT the ~5x #304 predicted: the socket genuinely takes ~10-40 ms to bind on that
// host, so most of sockwait was never our sleep. This test pins that the floor is gone, which
// is a real and separate property -- it must not be read as having removed a throughput ceiling.
func TestWaitForUnixSocketReturnsWellInsideOneOldQuantum(t *testing.T) {
	path := filepath.Join(sockBase(t), "fc.sock")

	// Stands in for Firecracker binding its API socket a couple of ms after the jailer
	// execs it. The bind error comes BACK rather than being swallowed: a failed bind (an
	// unwritable /tmp, a sun_path overflow -- the hazard sockBase exists to avoid) would
	// otherwise surface as a 5 s timeout and read as "the production poll is broken", which
	// is exactly the wrong diagnosis. Close happens inside this goroutine too: t.Cleanup
	// registered from a non-test goroutine races the test's return, and waitForUnixSocket can
	// return the instant the bind is visible, so a cleanup registered after tRunner drained
	// the list never runs and the listener fd leaks for the life of the test binary.
	bindErr := make(chan error, 1)
	done := make(chan struct{})
	defer close(done)
	go func() {
		time.Sleep(2 * time.Millisecond)
		l, err := net.Listen("unix", path)
		bindErr <- err
		if err == nil {
			defer func() { _ = l.Close() }()
			<-done
		}
	}()

	start := time.Now()
	err := waitForUnixSocket(context.Background(), path, 5*time.Second)
	elapsed := time.Since(start)
	if be := <-bindErr; be != nil {
		t.Fatalf("FIXTURE failed to bind %s: %v (not a failure of waitForUnixSocket)", path, be)
	}
	if err != nil {
		t.Fatalf("waitForUnixSocket: %v", err)
	}
	// Under HALF a quantum. The old code could not beat 20 ms for any socket, however fast,
	// so this is the property under test rather than a performance nicety.
	if elapsed >= 10*time.Millisecond {
		t.Fatalf("took %v for a socket that appeared in ~2ms; the fixed 20ms poll is still the floor", elapsed)
	}
}

// The overall timeout is a refusal path and must not be loosened by finer polling. It is
// also reachable in practice: the c=64 rung behind #255 took 396 of these.
func TestWaitForUnixSocketStillHonoursItsOverallTimeout(t *testing.T) {
	path := filepath.Join(sockBase(t), "never.sock")
	start := time.Now()
	err := waitForUnixSocket(context.Background(), path, 80*time.Millisecond)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("waitForUnixSocket succeeded against a socket that never appeared")
	}
	// Names the budget and the path, so a run log says what was waited for.
	for _, want := range []string{"80ms", path} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("timeout error omits %q: %v", want, err)
		}
	}
	if elapsed < 80*time.Millisecond {
		t.Fatalf("returned after %v, before its own %v budget", elapsed, 80*time.Millisecond)
	}
	// A loose sanity bound only. It CANNOT detect a coarse cap and does not claim to: with
	// 1.5x growth the last sleep is at most ~0.5x the elapsed time, so elapsed stays within
	// ~1.5x the budget for ANY cap value -- setting socketPollMax to 2s (2000x coarser) still
	// passes this. TestWaitForUnixSocketBackoffGrowsAndIsCapped is what pins the schedule.
	if elapsed > 400*time.Millisecond {
		t.Fatalf("elapsed %v against an 80ms budget: far beyond the ~1.5x the schedule allows", elapsed)
	}
}

// ctx cancellation is the other refusal path: Restore's cleanup() depends on it to unwind
// promptly rather than sitting out the full timeout.
func TestWaitForUnixSocketStillHonoursContextCancellation(t *testing.T) {
	path := filepath.Join(sockBase(t), "never.sock")
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(5 * time.Millisecond); cancel() }()

	start := time.Now()
	err := waitForUnixSocket(ctx, path, 10*time.Second)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("waitForUnixSocket succeeded despite a cancelled context")
	}
	if !strings.Contains(err.Error(), context.Canceled.Error()) {
		t.Fatalf("want a context error, got: %v", err)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("took %v to notice cancellation", elapsed)
	}
}

// It must DIAL, not stat. Firecracker creates the socket file before it accept()s, and
// fcJailOccupied's id-collision guard rests on the same distinction -- so a path that
// exists but answers nothing must NOT read as ready, or a restore proceeds against a
// socket no VMM is serving.
func TestWaitForUnixSocketDialsRatherThanStats(t *testing.T) {
	path := filepath.Join(sockBase(t), "plain-file.sock")
	if err := os.WriteFile(path, []byte("not a socket"), 0o600); err != nil {
		t.Fatal(err)
	}
	// Non-vacuousness: stat must succeed, or this proves nothing about dial-vs-stat.
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("fixture: the path must exist for stat: %v", err)
	}
	if err := waitForUnixSocket(context.Background(), path, 60*time.Millisecond); err == nil {
		t.Fatal("a plain file at the socket path was accepted as ready -- this stats instead of dialling")
	}
}

// The backoff schedule itself, pinned by counting PROBES rather than by wall clock. Wall-clock
// assertions provably cannot do this: deleting the growth and the cap outright (a flat 250 us
// poll) left every other test in this file green at -count=2, and setting socketPollMax to 2s
// left the timeout test green at -count=3. So without this, a future edit that removes the cap
// and burns ~4,000 probes/s per waiter -- the exact cost the pacing rationale says the growth
// exists to prevent -- would ship green.
func TestWaitForUnixSocketBackoffGrowsAndIsCapped(t *testing.T) {
	path := filepath.Join(sockBase(t), "never.sock")

	var probes int
	restore := socketProbe
	socketProbe = func(string) bool { probes++; return false }
	t.Cleanup(func() { socketProbe = restore })

	const budget = 200 * time.Millisecond
	if err := waitForUnixSocket(context.Background(), path, budget); err == nil {
		t.Fatal("waitForUnixSocket succeeded against a probe that never answers")
	}

	// The schedule: 8 growing sleeps cover the first 12.31 ms in 9 probes, then socketPollMax
	// governs. Over 200 ms that is 9 + (200-12.31)/1 ~= 197 probes.
	//
	// The bounds are what discriminate, so they are stated as the failures they catch:
	//   - growth removed (flat socketPollMin of 250 us) -> ~800 probes, above the upper bound;
	//   - cap raised to 5 ms -> ~47 probes, below the lower bound;
	//   - cap removed entirely -> growth runs away, ~12 probes, far below.
	const lo, hi = 120, 400
	if probes < lo || probes > hi {
		t.Fatalf("%d probes over %v; want %d..%d for socketPollMin=%v growing %d/%d to a %v cap. "+
			"Far more means the growth is gone (a flat fine poll); far fewer means the cap is coarser "+
			"than %v or absent.",
			probes, budget, lo, hi, socketPollMin, socketPollGrowthNum, socketPollGrowthDen,
			socketPollMax, socketPollMax)
	}

	// And the FIRST retry must stay fine, which is the property the measured distribution
	// actually cares about: a socket binding inside the first millisecond must not wait a
	// coarse interval for its second look.
	if socketPollMin > 500*time.Microsecond {
		t.Fatalf("socketPollMin = %v: the first retry is no longer fine-grained", socketPollMin)
	}
	if socketPollMax > 2*time.Millisecond {
		t.Fatalf("socketPollMax = %v: coarser than this re-inflates every sockwait measurement "+
			"by up to the cap, which is what made the 5 ms version read as a continuous distribution",
			socketPollMax)
	}
}
