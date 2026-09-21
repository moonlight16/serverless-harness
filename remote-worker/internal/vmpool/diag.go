package vmpool

import (
	"log"
	"os"
)

// Opt-in phase logging. #305 and #307 were both found by decomposing an Exec into
// Acquire/Resume/Run/Destroy and a restore into its own phases — but that decomposition
// existed only on the vmpoolctl path, so nothing the RELAYED path did was visible. The
// numbers that mattered (Destroy at 55% of an Exec; 90% of a restore spent asleep in
// waitForUnixSocket) could not be obtained without rebuilding the worker by hand.
//
// phaseLog is nil unless SH_DIAG_PHASES=1, so the cost when off is one nil check per Exec.
// It is a variable rather than a bool so tests can capture the lines instead of asserting
// against a logger's side effects.
var phaseLog func(format string, args ...any)

func init() {
	if os.Getenv("SH_DIAG_PHASES") == "1" {
		phaseLog = log.Printf
	}
}

// logPhases emits one line per Exec. Kept here rather than inline in Runner.Run so the
// field names are in one place: they are parsed by whatever is aggregating a run, and a
// silently renamed field reads as a missing phase rather than as an error.
func logPhases(ph *Phases) {
	if phaseLog == nil {
		return
	}
	phaseLog("vmpool: exec phases acquire_us=%d resume_us=%d run_us=%d destroy_us=%d cold=%q",
		ph.Acquire.Microseconds(), ph.Resume.Microseconds(),
		ph.Run.Microseconds(), ph.Destroy.Microseconds(), string(ph.Cold))
}
