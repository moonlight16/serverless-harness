package vmpool

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const testPerVM = (256 + 32) << 20

// newTestPool builds a pool rooted in a temp dir, so the whole thing is testable without root
// and without touching the host's cgroupfs.
func newTestPool(t *testing.T) (*cgroupPool, string) {
	t.Helper()
	root := t.TempDir()
	parent := "microvm.slice/microvm-vms.slice"
	if err := os.MkdirAll(filepath.Join(root, parent), 0o755); err != nil {
		t.Fatal(err)
	}
	return newCgroupPool(parent, testPerVM, root), root
}

// #258. The point of the whole change: a cgroup is REUSED rather than created and destroyed per
// VM. Measured cost of the per-VM churn was 195.52 ms of a 253 ms Destroy at 64 slots, growing
// 91x across a 16x concurrency range because cgroup removal is kernel-serialised.
func TestCgroupPoolReusesRatherThanMinting(t *testing.T) {
	p, root := newTestPool(t)

	first, err := p.acquire()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if p.mintedCount() != 1 || p.idle() != 0 {
		t.Fatalf("after one acquire: minted=%d idle=%d, want 1 and 0", p.mintedCount(), p.idle())
	}
	// Non-vacuousness: the directory must really exist, or "reuse" proves nothing.
	if _, err := os.Stat(filepath.Join(root, first)); err != nil {
		t.Fatalf("acquired cgroup does not exist: %v", err)
	}

	p.release(first)
	if p.idle() != 1 {
		t.Fatalf("release did not return it: idle=%d", p.idle())
	}
	again, err := p.acquire()
	if err != nil {
		t.Fatalf("second acquire: %v", err)
	}
	if again != first {
		t.Fatalf("acquire minted %q instead of reusing %q", again, first)
	}
	if p.mintedCount() != 1 {
		t.Fatalf("minted %d cgroups; reuse must not mint a second", p.mintedCount())
	}

	// Concurrent demand DOES mint: the high-water mark is the peak concurrent VM count, which
	// is the property that makes a free list correct without predicting a pool size.
	second, err := p.acquire()
	if err != nil {
		t.Fatalf("concurrent acquire: %v", err)
	}
	if second == again {
		t.Fatal("two live VMs were handed the same cgroup")
	}
	if p.mintedCount() != 2 {
		t.Fatalf("minted=%d, want 2 for two simultaneously held cgroups", p.mintedCount())
	}
}

// D1 preserved: the bound is PerVMBytes, and it moves from jailer's --cgroup to the pool, because
// --cgroup is what would CREATE a per-VM cgroup. §4 of the design note establishes by measurement
// that reuse is compatible with keeping this limit -- a live VM cgroup charges ~1 MiB against it.
func TestCgroupPoolWritesTheMemoryBound(t *testing.T) {
	p, root := newTestPool(t)
	rel, err := p.acquire()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(root, rel, "memory.max"))
	if err != nil {
		t.Fatalf("memory.max not written: %v", err)
	}
	if got := strings.TrimSpace(string(b)); got != strconv.FormatInt(testPerVM, 10) {
		t.Fatalf("memory.max = %q, want PerVMBytes %d", got, testPerVM)
	}
	// And it survives reuse: a recycled cgroup must still be bounded.
	p.release(rel)
	if _, err := p.acquire(); err != nil {
		t.Fatalf("re-acquire: %v", err)
	}
	if b2, err := os.ReadFile(filepath.Join(root, rel, "memory.max")); err != nil ||
		strings.TrimSpace(string(b2)) != strconv.FormatInt(testPerVM, 10) {
		t.Fatalf("memory.max did not survive reuse: %q err=%v", b2, err)
	}
}

// Raised in review of #318. kill + cmd.Wait reaps the jailer, but a stray child that escaped the
// process group would otherwise be handed to the NEXT tenant -- inside its memory bound, and
// inside a cgroup a later SweepOrphans would attribute to whoever holds it then. Leaking one
// cgroup is the old behaviour; handing over a live stranger's process is not.
func TestCgroupPoolLeaksRatherThanReusingANonEmptyCgroup(t *testing.T) {
	p, root := newTestPool(t)
	rel, err := p.acquire()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	// A survivor listed in cgroup.procs. Pid 1 is used only as a value that parses -- release
	// must not signal anything, only refuse to reuse.
	procs := filepath.Join(root, rel, "cgroup.procs")
	if err := os.WriteFile(procs, []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	p.release(rel)

	if p.idle() != 0 {
		t.Fatalf("a cgroup with a live member was returned for reuse (idle=%d)", p.idle())
	}
	if p.leaks() != 1 {
		t.Fatalf("leaks=%d, want 1 -- a leak must be counted, not silent", p.leaks())
	}
	// Left in place, not removed: something is still running in it.
	if _, err := os.Stat(filepath.Join(root, rel)); err != nil {
		t.Fatalf("leaked cgroup was removed while a member was live: %v", err)
	}
	// And the next acquire mints a fresh one rather than the leaked one.
	next, err := p.acquire()
	if err != nil {
		t.Fatalf("acquire after leak: %v", err)
	}
	if next == rel {
		t.Fatalf("handed out the leaked cgroup %q", rel)
	}
}

// An empty cgroup.procs is the normal case and must reuse. Guards against the guard being
// inverted, which would turn every release into a leak and silently restore the old churn.
func TestCgroupPoolReusesWhenCgroupProcsIsEmpty(t *testing.T) {
	p, root := newTestPool(t)
	rel, _ := p.acquire()
	if err := os.WriteFile(filepath.Join(root, rel, "cgroup.procs"), []byte("\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p.release(rel)
	if p.idle() != 1 || p.leaks() != 0 {
		t.Fatalf("an empty cgroup must be reused: idle=%d leaks=%d", p.idle(), p.leaks())
	}
}

// jailer refuses an absolute --parent-cgroup ("Path should not be absolute or contain a dot
// component"), so what the pool hands out must be slice-relative and under the configured parent.
func TestCgroupPoolHandsOutASliceRelativePathUnderTheParent(t *testing.T) {
	p, _ := newTestPool(t)
	rel, err := p.acquire()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	if filepath.IsAbs(rel) {
		t.Fatalf("acquire returned an absolute path %q; jailer refuses those", rel)
	}
	if err := ValidateParentCgroup(rel); err != nil {
		t.Fatalf("acquire returned a path jailer would refuse: %v", err)
	}
	if !strings.HasPrefix(rel, "microvm.slice/microvm-vms.slice/") {
		t.Fatalf("acquired %q is not under the configured parent", rel)
	}
}

// SweepOrphans must SEE pooled cgroups, or a crashed worker's dead VMM keeps running inside one.
// isPoolVMCgroupDirName is documented as the single authority on the name, and this is a third
// recognised form alongside vm-<n> and the CHV scope.
func TestPooledCgroupNamesAreRecognisedBySweepOrphans(t *testing.T) {
	for _, name := range []string{"pool-0", "pool-7", "pool-1234"} {
		if !isPoolVMCgroupDirName(name) {
			t.Errorf("%q not recognised; SweepOrphans would ignore a dead VMM inside it", name)
		}
	}
	// And the negatives still hold -- the sweep kills what it matches, so over-matching is worse
	// than under-matching.
	for _, name := range []string{"pool", "pool-", "pool-x", "poolish-1", "microvm-worker.service", "vm-"} {
		if isPoolVMCgroupDirName(name) {
			t.Errorf("%q must NOT be recognised: the sweep kills members of what it matches", name)
		}
	}
}

// readCgroupProcs reports a MISSING path as (nil, nil), which is indistinguishable from "empty" --
// so a cgroup that vanished underneath us would otherwise go back on the free list, and a later
// acquire would hand jailer a --parent-cgroup that does not exist, failing every restore that drew
// it. Reachable in practice: clearing the slice by hand is step 3a of the metal runbook, and
// SweepOrphans now recognises these names too.
func TestCgroupPoolDropsAVanishedCgroupInsteadOfReusingIt(t *testing.T) {
	p, root := newTestPool(t)
	rel, err := p.acquire()
	if err != nil {
		t.Fatalf("acquire: %v", err)
	}
	// Someone removed it under us.
	if err := os.RemoveAll(filepath.Join(root, rel)); err != nil {
		t.Fatal(err)
	}

	p.release(rel)

	if p.idle() != 0 {
		t.Fatalf("a vanished cgroup was returned for reuse (idle=%d); acquire would hand jailer a "+
			"--parent-cgroup that does not exist", p.idle())
	}
	// Not a leak: there is nothing left to leak.
	if p.leaks() != 0 {
		t.Fatalf("leaks=%d; a directory that is already gone has not leaked", p.leaks())
	}
	// And the next acquire produces something that really exists.
	next, err := p.acquire()
	if err != nil {
		t.Fatalf("acquire after a drop: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, next)); err != nil {
		t.Fatalf("acquire handed out a non-existent cgroup %q: %v", next, err)
	}
}
