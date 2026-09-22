package vmpool

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// pooledCgroupPrefix names the reusable cgroups. Deliberately NOT vm-<n>: jailer's --id must stay
// monotonic (a live VMM holding a jail id is what the collision guard refuses on), so a pooled
// cgroup named vm-3 would not correspond to VM vm-3 and the two namespaces would silently diverge.
// isPoolVMCgroupDirName recognises this form so SweepOrphans still sees a dead VMM inside one.
const pooledCgroupPrefix = "pool-"

// cgroupPool hands out reusable per-VM cgroups instead of creating and destroying one per VM.
//
// WHY. Task 3.1 decomposed Destroy and found the per-VM cgroup rmdir at 2.15 ms / 15.53 ms /
// 195.52 ms for 4 / 16 / 64 concurrency slots -- 91x growth, and 77% of Destroy at the top,
// because cgroup removal is kernel-serialised. Two cheaper fixes were measured and rejected:
// deferring the rmdir conserves the time into Acquire and makes 64 slots worse, and reclaiming
// charges before rmdir hangs worker startup. The churn also parks 12,400+ dying cgroups, which
// degraded the rig ~24% at 64 slots over one session. Not creating them addresses both.
//
// HOW IT IS POSSIBLE. jailer's --cgroup memory.max= is what CREATES the per-VM cgroup;
// --parent-cgroup alone only relocates the jailed process into a cgroup that already exists. So
// the pool creates the cgroup and writes the bound, and jailer is given only --parent-cgroup.
//
// A FREE LIST, NOT A SIZED POOL. There is no slot concept in this package to size one from --
// nextIDLocked mints ids from a monotonic counter and concurrency is bounded by admitLocked -- so
// acquire pops or mints and release pushes back, which makes the high-water mark exactly the peak
// concurrent VM count (~68 at 64 slots, against ~26,000 create/destroy cycles per rung) without
// anything having to predict it.
//
// THE MEMORY BOUND IS KEPT (design note §4, option D). A live VM cgroup charges ~1 MiB against a
// 288 MiB memory.max -- measured, 0 of 306 samples anywhere near the limit -- because the golden
// snapshot's memfile is mlocked by the WORKER at startup and hardlinked so it stays one shared
// page-cache object. A reused cgroup therefore inherits ~1 MiB, not ~400 MiB, and D1's bound
// survives reuse unchanged.
type cgroupPool struct {
	// root is the cgroupfs mount point, overridable so the whole pool is testable without root.
	// Empty means Cgroup2Root, which is every production path.
	root   string
	parent string // slice-relative, e.g. "microvm.slice/microvm-vms.slice"
	memMax int64

	mu     sync.Mutex
	free   []string // slice-relative paths of idle cgroups
	minted int
	leaked atomic.Int64
}

func newCgroupPool(parent string, memMax int64, root string) *cgroupPool {
	return &cgroupPool{root: root, parent: parent, memMax: memMax}
}

func (p *cgroupPool) fsRoot() string {
	if p.root != "" {
		return p.root
	}
	return Cgroup2Root
}

// abs turns a slice-relative cgroup path into a filesystem path.
func (p *cgroupPool) abs(rel string) string { return filepath.Join(p.fsRoot(), rel) }

// acquire returns a slice-RELATIVE cgroup path for jailer's --parent-cgroup, reusing an idle one
// when there is one. Relative because jailer refuses an absolute --parent-cgroup outright.
func (p *cgroupPool) acquire() (string, error) {
	p.mu.Lock()
	if n := len(p.free); n > 0 {
		rel := p.free[n-1]
		p.free = p.free[:n-1]
		p.mu.Unlock()
		return rel, nil
	}
	seq := p.minted
	p.minted++
	p.mu.Unlock()

	rel := filepath.Join(p.parent, pooledCgroupPrefix+strconv.Itoa(seq))
	dir := p.abs(rel)
	if err := mkdirAllCgroup(dir); err != nil {
		p.mu.Lock()
		p.minted-- // not created, so do not claim the name
		p.mu.Unlock()
		return "", fmt.Errorf("vmpool: cgroup pool: create %s: %w", dir, err)
	}
	// The bound jailer's --cgroup used to write. Kept here so D1's figure still applies to every
	// VM (design note §4): the same PerVMBytes admission control charges.
	if err := writeMemoryMax(dir, p.memMax); err != nil {
		return "", err
	}
	return rel, nil
}

// release returns rel for reuse -- unless something is still inside it.
//
// THE GUARD IS LOAD-BEARING. Destroy's kill + cmd.Wait reaps the jailer, but a stray child that
// escaped the process group would otherwise be handed to the NEXT tenant: running inside that
// tenant's memory bound, and inside a cgroup a later SweepOrphans would attribute to whoever holds
// it then. Leaking one cgroup is the behaviour this change replaces; handing over a live
// stranger's process is not. A leak is counted so it cannot be silent, and the directory is left
// alone precisely because something is running in it.
func (p *cgroupPool) release(rel string) {
	// The directory must still BE there. readCgroupProcs reports a missing path as (nil, nil) --
	// indistinguishable from "empty" -- so without this check a cgroup that vanished underneath us
	// would go back on the free list and acquire would later hand out a path jailer cannot
	// relocate into ("--parent-cgroup ... if that path already exists"), failing every restore that
	// drew it. Reachable in practice: an operator clearing the slice by hand is step 3a of the
	// metal runbook, and SweepOrphans now recognises these names too. Dropping the entry is
	// correct and is NOT a leak -- there is nothing left to leak -- so acquire simply mints anew.
	if _, statErr := os.Stat(p.abs(rel)); statErr != nil {
		log.Printf("vmpool: cgroup pool: dropping %s, its directory is gone (%v); a fresh one will "+
			"be created on the next acquire", rel, statErr)
		return
	}
	pids, err := readCgroupProcs(filepath.Join(p.abs(rel), "cgroup.procs"))
	switch {
	case err != nil:
		// Cannot tell, so do not reuse. Same posture as the PSS sampler's refusal: "cannot tell"
		// is not "empty".
		p.leaked.Add(1)
		log.Printf("vmpool: cgroup pool: leaking %s, cannot read cgroup.procs: %v", rel, err)
		return
	case len(pids) > 0:
		p.leaked.Add(1)
		log.Printf("vmpool: cgroup pool: leaking %s, %d process(es) still inside after Destroy "+
			"(a child escaped the process group); it will not be reused", rel, len(pids))
		return
	}
	p.mu.Lock()
	p.free = append(p.free, rel)
	p.mu.Unlock()
}

func (p *cgroupPool) idle() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.free)
}

func (p *cgroupPool) mintedCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.minted
}

func (p *cgroupPool) leaks() int64 { return p.leaked.Load() }

// isPooledCgroupDirName reports whether name is one of this pool's directories. Kept beside
// isPoolVMID and isPoolVMCgroupDirName, which that file documents as "the single authority on what
// a VM's cgroup DIRECTORY is called".
func isPooledCgroupDirName(name string) bool {
	rest, ok := strings.CutPrefix(name, pooledCgroupPrefix)
	if !ok || rest == "" {
		return false
	}
	for _, r := range rest {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}
