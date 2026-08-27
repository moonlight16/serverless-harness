package main

import (
	"os"
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
	}
	if !found {
		t.Error("capabilities did not include bash, which the runner requires")
	}
	// And nothing outside the probed list may appear: capabilities is a PATH probe,
	// not a hardcoded advertisement. (The check this replaces looked for a literal
	// that was never in probed, so no code path could have produced it.)
	inProbed := func(c string) bool {
		for _, p := range probed {
			if p == c {
				return true
			}
		}
		return false
	}
	for _, c := range caps {
		if !inProbed(c) {
			t.Errorf("capabilities included %q, which is not in the probed list %v", c, probed)
		}
	}
}

// RELAY_TLS decides whether the bearer token crosses the wire in cleartext, so an
// unparseable value must be an error the caller can fail on — never a silent
// fallback to plaintext.
func TestEnvBoolRejectsGarbageRatherThanFailingOpen(t *testing.T) {
	for _, v := range []string{"yes", "TLS", "1 ", "on"} {
		t.Setenv("RELAY_TLS", v)
		if got, err := envBool("RELAY_TLS", false); err == nil {
			t.Errorf("envBool(%q) = %v, nil; want an error rather than a silent plaintext default", v, got)
		}
	}
	for v, want := range map[string]bool{"1": true, "true": true, "TRUE": true, "0": false, "false": false} {
		t.Setenv("RELAY_TLS", v)
		got, err := envBool("RELAY_TLS", false)
		if err != nil || got != want {
			t.Errorf("envBool(%q) = %v, %v; want %v, nil", v, got, err, want)
		}
	}
	os.Unsetenv("RELAY_TLS")
	if got, err := envBool("RELAY_TLS", true); err != nil || !got {
		t.Errorf("envBool(unset) = %v, %v; want the default true, nil", got, err)
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
