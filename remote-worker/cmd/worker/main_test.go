package main

import (
	"testing"
	"time"
)

func TestEnvIntFallsBackOnGarbage(t *testing.T) {
	t.Setenv("WORKER_MAX_CONCURRENT", "not-a-number")
	if got := envInt("WORKER_MAX_CONCURRENT", 4); got != 4 {
		t.Errorf("envInt = %d, want the default 4 for unparseable input", got)
	}
	t.Setenv("WORKER_MAX_CONCURRENT", "8")
	if got := envInt("WORKER_MAX_CONCURRENT", 4); got != 8 {
		t.Errorf("envInt = %d, want 8", got)
	}
	// A zero or negative pool would wedge the dispatch loop; fall back instead.
	t.Setenv("WORKER_MAX_CONCURRENT", "0")
	if got := envInt("WORKER_MAX_CONCURRENT", 4); got != 4 {
		t.Errorf("envInt = %d, want the default for 0", got)
	}
}

// Hello must advertise what is actually installed, not a hardcoded list.
func TestCapabilitiesProbesRealBinaries(t *testing.T) {
	caps := capabilities()
	found := false
	for _, c := range caps {
		if c == "bash" {
			found = true
		}
		if c == "definitely-not-installed-xyz" {
			t.Errorf("capabilities included %q, which was never probed", c)
		}
	}
	if !found {
		t.Error("capabilities did not include bash, which the runner requires")
	}
}

func TestNextBackoffDoublesAndCaps(t *testing.T) {
	got := nextBackoff(backoffMin)
	if got != 2*backoffMin {
		t.Errorf("nextBackoff(%v) = %v, want %v", backoffMin, got, 2*backoffMin)
	}
	if got := nextBackoff(20 * time.Second); got != backoffMax {
		t.Errorf("nextBackoff(20s) = %v, want the cap %v", got, backoffMax)
	}
	if got := nextBackoff(backoffMax); got != backoffMax {
		t.Errorf("nextBackoff(cap) = %v, want it to stay at %v", got, backoffMax)
	}
}

func TestJitterStaysWithinHalfTheInterval(t *testing.T) {
	d := 2 * time.Second
	for i := 0; i < 100; i++ {
		got := jitter(d)
		if got < d || got > d+d/2 {
			t.Fatalf("jitter(%v) = %v, want within [%v, %v]", d, got, d, d+d/2)
		}
	}
}
