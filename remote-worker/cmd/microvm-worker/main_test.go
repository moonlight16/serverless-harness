package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/kagenti/serverless-harness/remote-worker/internal/session"
	"github.com/kagenti/serverless-harness/remote-worker/internal/vmpool"
)

func envFrom(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestPoolConfigFromEnvironment(t *testing.T) {
	cfg, err := poolConfig(envFrom(map[string]string{
		"SH_VMM":               "firecracker",
		"SH_SNAPSHOT_DIR":      "/srv/snapshots",
		"SH_WORKSPACE_ROOT":    "/srv/workspaces",
		"SH_STANDBY_DEPTH":     "3",
		"SH_GUEST_RAM_MB":      "512",
		"SH_MAX_RUNS":          "48",
		"SH_MAX_COMMITTED_MB":  "20480",
		"SH_MEMORY_RESERVE_MB": "2048",
	}))
	if err != nil {
		t.Fatalf("poolConfig: %v", err)
	}
	if cfg.VMM != vmpool.Firecracker || cfg.StandbyDepth != 3 || cfg.GuestRAMBytes != 512<<20 {
		t.Fatalf("cfg = %+v", cfg)
	}
	if cfg.MaxRuns != 48 || cfg.MaxCommittedBytes != 20480<<20 || cfg.MemoryReserveBytes != 2048<<20 {
		t.Fatalf("cfg = %+v", cfg)
	}
}

// Spec §6: "KVM unavailable at startup ... Fail the unit at start with an explicit
// message; never fall back to running commands on the host." The strongest form of
// that is having no code path that could: --vmm=fake exists in vmpoolctl and must
// not be reachable here.
func TestThereIsNoHostFallbackLauncher(t *testing.T) {
	get := envFrom(map[string]string{})
	if _, err := launcherFor(vmpool.VMMKind("fake"), get, t.TempDir(), testPerVMBytes); err == nil {
		t.Fatal("launcherFor accepted the host-bash fake — §3.5's privilege argument rests on " +
			"nothing agent-influenced ever executing outside a VM")
	}
	for _, k := range []vmpool.VMMKind{"", "qemu", "gvisor"} {
		if _, err := launcherFor(k, get, t.TempDir(), testPerVMBytes); err == nil {
			t.Fatalf("launcherFor(%q) accepted an unknown VMM", k)
		}
	}
}

// testPerVMBytes stands in for vmpool.PerVMBytes(cfg) in tests that call launcherFor
// directly without going through poolConfig/main — any positive value works for these
// tests, since none of them assert the SPECIFIC memory.max/MemoryMax value reaches the
// launcher (that agreement is asserted at the vmpool package level: see
// TestFirecrackerJailerCgroupMemoryMaxAgreesWithPerVMBytes and
// TestCloudHypervisorSystemdRunScopeAgreesWithPerVMBytes in internal/vmpool). What
// matters here is only that it is > 0, so CHVOptions.validate()/FirecrackerOptions.
// validate() do not refuse the ParentCgroup default launcherFor always sets
// (hardware-corrections D1).
const testPerVMBytes = int64(256 << 20)

// Fix round 3: launcherFor must actually route vmpool.CloudHypervisor to
// NewCloudHypervisorLauncher. Before this, the switch case was a hardcoded "not
// implemented" error, so SH_VMM=cloud-hypervisor failed at worker startup and the
// CH arm — fully implemented and tested inside the vmpool package — was called
// from nothing but its own tests. This call passes no SH_VIRTIOFSD_UID/GID
// override, so a non-nil error here also covers a virtiofsd UID/GID default that
// regressed to 0 (CHVOptions.validate refuses VirtiofsdUID/GID == 0) — in
// particular a regression to copying the Firecracker case's os.Getuid()/
// os.Getgid(), which is 0 on the privileged worker this process actually runs as.
func TestLauncherForWiresCloudHypervisor(t *testing.T) {
	get := envFrom(map[string]string{})
	lc, err := launcherFor(vmpool.CloudHypervisor, get, t.TempDir(), testPerVMBytes)
	if err != nil {
		t.Fatalf("launcherFor(CloudHypervisor): %v", err)
	}
	if lc.Kind() != vmpool.CloudHypervisor {
		t.Fatalf("Kind() = %v, want %v", lc.Kind(), vmpool.CloudHypervisor)
	}
	if lc.SerializesExecsPerRun() {
		t.Fatal("the Cloud Hypervisor arm must not serialize execs per run (spec §4.3): " +
			"virtio-fs makes the host filesystem, not a guest-owned block device, the " +
			"concurrency authority — see TestCloudHypervisorDoesNotSerializeExecsPerRun in " +
			"the vmpool package for the same invariant enforced at the source")
	}
}

// TestLauncherForRefusesAnExplicitZeroVirtiofsdUID guards the SH_VIRTIOFSD_UID
// override path itself, distinct from the built-in-default path covered by
// TestLauncherForWiresCloudHypervisor above: it must reach validation, not be
// silently dropped by some fallback (e.g. a stray os.Getuid()) that would mask an
// explicit 0 override too.
func TestLauncherForRefusesAnExplicitZeroVirtiofsdUID(t *testing.T) {
	get := envFrom(map[string]string{"SH_VIRTIOFSD_UID": "0"})
	if _, err := launcherFor(vmpool.CloudHypervisor, get, t.TempDir(), testPerVMBytes); err == nil {
		t.Fatal("launcherFor(CloudHypervisor) accepted SH_VIRTIOFSD_UID=0 — virtiofsd is " +
			"spec §3.5's confinement boundary and must never run as root")
	}
}

func TestPoolConfigRefusesAMissingSnapshotDir(t *testing.T) {
	_, err := poolConfig(envFrom(map[string]string{
		"SH_VMM":              "firecracker",
		"SH_WORKSPACE_ROOT":   "/srv/workspaces",
		"SH_MAX_COMMITTED_MB": "1024",
	}))
	if err == nil || !strings.Contains(err.Error(), "SH_SNAPSHOT_DIR") {
		t.Fatalf("err = %v, want it to name SH_SNAPSHOT_DIR", err)
	}
}

func TestPoolConfigRefusesAMissingMemoryBudget(t *testing.T) {
	_, err := poolConfig(envFrom(map[string]string{
		"SH_VMM":            "firecracker",
		"SH_SNAPSHOT_DIR":   "/srv/snapshots",
		"SH_WORKSPACE_ROOT": "/srv/workspaces",
	}))
	// Spec §6 makes the memory gate mandatory: without it pressure goes straight to
	// the OOM killer, whose size-ranked favourites include microvm-worker itself.
	if err == nil || !strings.Contains(err.Error(), "SH_MAX_COMMITTED_MB") {
		t.Fatalf("err = %v, want it to name SH_MAX_COMMITTED_MB", err)
	}
}

// Fix-round item 5: the manifest's InstanceType must be verified against the
// running host, additively alongside the existing verify+pin+probe block.

func fixedHost(t string) func(context.Context) string {
	return func(context.Context) string { return t }
}

func TestVerifyInstanceTypeAcceptsAMatch(t *testing.T) {
	get := envFrom(map[string]string{})
	if err := verifyInstanceType(get, "c6i.large", fixedHost("c6i.large")); err != nil {
		t.Fatalf("matching instance types should not be refused: %v", err)
	}
}

func TestVerifyInstanceTypeRefusesAMismatchNamingBothValues(t *testing.T) {
	get := envFrom(map[string]string{})
	err := verifyInstanceType(get, "c6i.large", fixedHost("m5.xlarge"))
	if err == nil {
		t.Fatal("a mismatched instance type must be refused")
	}
	if !strings.Contains(err.Error(), "c6i.large") || !strings.Contains(err.Error(), "m5.xlarge") {
		t.Fatalf("err = %v, want it to name both the manifest and host instance types", err)
	}
}

func TestVerifyInstanceTypeOverrideEnvBypassesAMismatch(t *testing.T) {
	get := envFrom(map[string]string{"SH_ALLOW_INSTANCE_TYPE_MISMATCH": "true"})
	if err := verifyInstanceType(get, "c6i.large", fixedHost("m5.xlarge")); err != nil {
		t.Fatalf("the override env var should bypass a mismatch: %v", err)
	}
}

func TestVerifyInstanceTypeSkipsWhenManifestHasNoRecordedType(t *testing.T) {
	get := envFrom(map[string]string{})
	// An older manifest with no InstanceType recorded: nothing to compare, so this
	// must fail open, not closed.
	if err := verifyInstanceType(get, "", fixedHost("m5.xlarge")); err != nil {
		t.Fatalf("an empty manifest InstanceType must not be refused: %v", err)
	}
}

func TestVerifyInstanceTypeSkipsWhenHostIsUndetectable(t *testing.T) {
	get := envFrom(map[string]string{})
	// No metadata service and no stable host identity available: fail open rather
	// than block every worker's startup on an environment this check cannot reach.
	if err := verifyInstanceType(get, "c6i.large", fixedHost("")); err != nil {
		t.Fatalf("an undetectable host must not be refused: %v", err)
	}
}

// stableHostIdentity itself is exercised only for "never returns empty" -- the
// metadata-service probes need real network access this test suite must not
// depend on, and are covered by design (fail-open on every non-2xx/timeout/error)
// rather than by hitting real cloud endpoints from a unit test.
func TestStableHostIdentityNeverReturnsEmpty(t *testing.T) {
	if got := stableHostIdentity(); got == "" {
		t.Fatal("stableHostIdentity must always return a non-empty fallback")
	}
}

// #306. e11-density.sh's coldAcquireRate is a LATENCY-CLASSIFICATION PROXY: it counts
// Execs whose end-to-end latency exceeded SH_E11_COLD_LATENCY_MS. Measured against
// vmpool.Phases.Cold on the same runs it was wrong by 13x at c=8 (0.76 reported vs 0.056
// true) and by ~250x at c=16. It cannot be repaired by tuning the threshold, because
// Acquire is 0.3% of an Exec -- no threshold on end-to-end latency separates warm from
// cold.
//
// vmpool already maintains the real counters (Stats.WarmAcquires / .ColdAcquires), but
// nothing outside vmpoolctl could ever read them: the worker never exposed Stats at all.
// This is that transport, chosen over parsing SH_DIAG_PHASES log lines because the
// counters are already authoritative and a log format is not a contract.
func TestDiagStatsMuxServesTheRealWarmAndColdCounters(t *testing.T) {
	statsFn := func() vmpool.Stats {
		return vmpool.Stats{
			InFlight:         3,
			StandbysResident: 5,
			WarmAcquires:     4096,
			ColdAcquires: map[vmpool.ColdCause]uint64{
				vmpool.ColdFirstExec: 8,
				vmpool.ColdExhausted: 16,
			},
		}
	}
	srv := httptest.NewServer(diagStatsMux(statsFn, 16))
	defer srv.Close()

	res, err := http.Get(srv.URL + "/stats")
	if err != nil {
		t.Fatalf("GET /stats: %v", err)
	}
	defer func() { _ = res.Body.Close() }()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("GET /stats status = %d, want 200", res.StatusCode)
	}

	var got struct {
		InFlight      int               `json:"inFlight"`
		WarmAcquires  uint64            `json:"warmAcquires"`
		ColdAcquires  map[string]uint64 `json:"coldAcquires"`
		MaxConcurrent int               `json:"maxConcurrent"`
	}
	if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.WarmAcquires != 4096 {
		t.Errorf("warmAcquires = %d, want 4096", got.WarmAcquires)
	}
	// Keyed by cause, not just a total: "exhausted" is the one that means replenishment
	// is behind the Exec rate, and it is the only cold cause a density knee can be
	// attributed to. first-exec is a session's unavoidable first restore.
	if got.ColdAcquires["exhausted"] != 16 {
		t.Errorf("coldAcquires[exhausted] = %d, want 16", got.ColdAcquires["exhausted"])
	}
	if got.ColdAcquires["first-exec"] != 8 {
		t.Errorf("coldAcquires[first-exec] = %d, want 8", got.ColdAcquires["first-exec"])
	}
	if got.InFlight != 3 {
		t.Errorf("inFlight = %d, want 3", got.InFlight)
	}
	// #306 step 4. Reported by the WORKER, not recorded by the driver from what it
	// believes it set. Every E11 microVM rung ever recorded swept c to 64 against a
	// 4-slot cap the driver never set and never wrote down, and at every point measured
	// it was MaxConcurrent -- not the pool -- that set throughput. A rung record must
	// not be readable without its slot count, and the only figure that cannot disagree
	// with reality is the one the worker itself is using.
	if got.MaxConcurrent != 16 {
		t.Errorf("maxConcurrent = %d, want 16", got.MaxConcurrent)
	}
}

// The stats listener must NOT be http.DefaultServeMux. This package imports
// _ "net/http/pprof", which registers its handlers on the default mux at import time, so
// serving stats there would mean that enabling counters ALSO served goroutine dumps, heap
// contents and command lines to anyone who can reach the address. #308's reviewer note
// already flagged that exposure for SH_DIAG_PPROF, which is opt-in and documented for it;
// the counters must not smuggle it in behind a different variable.
func TestDiagStatsMuxDoesNotAlsoExposePprof(t *testing.T) {
	srv := httptest.NewServer(diagStatsMux(func() vmpool.Stats { return vmpool.Stats{} }, 4))
	defer srv.Close()

	for _, path := range []string{"/debug/pprof/heap", "/debug/pprof/goroutine", "/debug/pprof/cmdline"} {
		res, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatalf("GET %s: %v", path, err)
		}
		_ = res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Errorf("GET %s status = %d, want 404 - the stats mux is exposing pprof", path, res.StatusCode)
		}
	}
}

// Issue #305, Task 1.2. session.DefaultConcurrency is 4, and it sizes a FIXED pool of
// goroutines -- one per concurrency slot -- so a worker left at it serves 4 Execs at once
// however many are dispatched. 4 is defensible for the container worker, whose
// worker-deployment.yaml limit is 256Mi and whose per-slot cost is 2 x 8 MiB of stream
// buffer (internal/exec/runner.go's MEMORY BUDGET note: raising slots to 16 would put the
// worst case AT that limit, reinstating an OOMKill a relay can trigger at will). It is
// wrong for this tier: the microVM worker has no pod limit, its memory is gated by the
// MANDATORY SH_MAX_COMMITTED_MB over 256 MiB guests, and 16 slots measured 172.88 Exec/s
// against 62.99 at 4 on the same host -- 2.74x.
//
// So the default belongs per tier, not in the shared library constant.
func TestWorkerMaxConcurrentDefaultsToTheMicrovmTierNotTheLibrary(t *testing.T) {
	got, err := workerMaxConcurrent(envFrom(map[string]string{}))
	if err != nil {
		t.Fatalf("workerMaxConcurrent: %v", err)
	}
	if got != microvmDefaultConcurrency {
		t.Fatalf("default slots = %d, want the microVM tier default %d", got, microvmDefaultConcurrency)
	}
	// The point of the change: this tier must NOT inherit the container tier's 4.
	if got == session.DefaultConcurrency {
		t.Fatalf("default slots = %d, which is still session.DefaultConcurrency -- the tier default is not in force", got)
	}
	// 16 is the largest slot count actually MEASURED (172.88 Exec/s). Anything above it is
	// an extrapolation, and finding where slots stop paying is its own sweep (Task 1.3), so
	// the default must not wander past the evidence.
	if microvmDefaultConcurrency != 16 {
		t.Fatalf("microvmDefaultConcurrency = %d; 16 is the largest measured slot count, so a change needs its own measurement", microvmDefaultConcurrency)
	}
}

func TestWorkerMaxConcurrentHonoursTheEnvironment(t *testing.T) {
	got, err := workerMaxConcurrent(envFrom(map[string]string{"WORKER_MAX_CONCURRENT": "32"}))
	if err != nil {
		t.Fatalf("workerMaxConcurrent: %v", err)
	}
	if got != 32 {
		t.Fatalf("slots = %d, want 32", got)
	}
}

// The pre-existing inline form was `if v, e := envInt64(...); e == nil { maxConcurrent = int(v) }`,
// which DISCARDED the error: WORKER_MAX_CONCURRENT=abc silently ran at 4 slots. That is the
// same silent fallback e11-density.sh now refuses, and it is worse here, because the whole
// campaign turns on knowing a run's slot count. A malformed value must refuse.
func TestWorkerMaxConcurrentRefusesAMalformedValueInsteadOfSilentlyUsingTheDefault(t *testing.T) {
	for _, bad := range []string{"abc", "0", "-1", "4.5", "16 32", " "} {
		got, err := workerMaxConcurrent(envFrom(map[string]string{"WORKER_MAX_CONCURRENT": bad}))
		if err == nil {
			t.Fatalf("WORKER_MAX_CONCURRENT=%q was accepted as %d slots; it must refuse", bad, got)
		}
		if !strings.Contains(err.Error(), "WORKER_MAX_CONCURRENT") {
			t.Fatalf("WORKER_MAX_CONCURRENT=%q: error %q does not name the variable", bad, err)
		}
	}
}
