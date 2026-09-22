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
// Restores are how the standby pool replenishes, so this sets the replenishment rate and
// therefore an aggregate throughput ceiling -- it is not merely per-restore latency.
func TestWaitForUnixSocketReturnsWellInsideOneOldQuantum(t *testing.T) {
	path := filepath.Join(sockBase(t), "fc.sock")

	// Stands in for Firecracker binding its API socket a couple of ms after the jailer
	// execs it -- which is what the 2.80 ms of real work above actually is.
	go func() {
		time.Sleep(2 * time.Millisecond)
		l, err := net.Listen("unix", path)
		if err != nil {
			return
		}
		t.Cleanup(func() { _ = l.Close() })
	}()

	start := time.Now()
	if err := waitForUnixSocket(context.Background(), path, 5*time.Second); err != nil {
		t.Fatalf("waitForUnixSocket: %v", err)
	}
	elapsed := time.Since(start)
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
	// Finer polling must not overshoot either: the backoff cap bounds how late the last
	// sleep can push the deadline check.
	if elapsed > 400*time.Millisecond {
		t.Fatalf("overshot its 80ms budget by too much (%v) -- the backoff cap is too coarse", elapsed)
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
