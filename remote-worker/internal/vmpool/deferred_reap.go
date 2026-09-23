package vmpool

import (
	"log"
	"sync"
	"sync/atomic"
)

// DefaultDeferReapWorkers sizes the reaper when deferral is on but unsized. At the measured
// peak the pipeline turns over ~870 VMs/s and a reap is ~53 ms, so ~46 are in flight at any
// instant; 64 covers that with headroom and matches the slot count the peak runs at. Reaps
// are pure blocking latency -- the kernel absorbs them concurrently, Destroy throughput going
// 49/s at c=1 to 1131/s at c=64 -- so these goroutines cost almost no CPU.
const DefaultDeferReapWorkers = 64

// deferredReaper is implemented by a VM whose teardown splits at an OBSERVABLE barrier: a
// point after which it can no longer touch the run's workspace, reached long before the
// kernel has finished reclaiming it.
//
// Only firecrackerVM implements it, and only that arm has a gate to open (Cloud Hypervisor's
// SerializesExecsPerRun is false: virtio-fs makes the host filesystem the concurrency
// authority). VM.Destroy remains the whole synchronous teardown for every other caller --
// Close, the reclaim goroutine, replenishOne's post-warm branch, DestroyAllStandbys -- so
// nothing outside the hot path changes shape.
type deferredReaper interface {
	// KillAndBarrier SIGKILLs the VMM and returns once it provably holds no file descriptor,
	// so it cannot write to workspace.img. Measured at 1.41 ms median / 4.62 ms p95 at c=64,
	// against a 52.88 ms reap (#307).
	KillAndBarrier() error
	// Reap finishes what KillAndBarrier started: cmd.Wait, the jail unlink, and the cgroup
	// release, in that order and unchanged. Safe to run on any goroutine.
	Reap() error
}

// reaper runs deferred reap tails on a BOUNDED worker set.
//
// Bounded because an unbounded backlog of exiting VMMs is a new failure mode: each holds a
// pid, a jail directory, a cgroup not yet returned to cgroupPool, and its fds until __fput.
// spec §6 requires a cold-acquire storm to stay "counted, never queued unboundedly", and this
// is the same obligation on the teardown side.
//
// A FULL QUEUE REAPS INLINE rather than blocking or dropping. Dropping leaks a jail directory
// and a cgroup per VM, which is #255's 5.3x degradation by another route; blocking would put
// the backlog back on the gate it exists to free. Reaping inline is EXACTLY today's behaviour,
// which makes the degenerate case a return to the old cost rather than a new failure -- and
// reapsInline counts it, so a saturated reaper is visible in Stats rather than inferred from a
// throughput number that came out flat.
type reaper struct {
	queue chan deferredReaper
	wg    sync.WaitGroup

	inline atomic.Uint64

	closeOnce sync.Once
}

// newReaper starts workers goroutines draining a queue of the same depth. Depth equals the
// worker count deliberately: a deeper queue only buys latency-hiding for a burst the workers
// cannot absorb, and the inline fallback already handles that without unbounded growth.
func newReaper(workers int) *reaper {
	if workers <= 0 {
		return nil
	}
	r := &reaper{queue: make(chan deferredReaper, workers)}
	r.wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func() {
			defer r.wg.Done()
			for vm := range r.queue {
				r.run(vm)
			}
		}()
	}
	return r
}

// run performs one reap, reporting a failure the way pool.destroy does: logged and counted,
// never returned. It cannot change what the command already did.
func (r *reaper) run(vm deferredReaper) {
	if err := vm.Reap(); err != nil {
		log.Printf("vmpool: deferred reap: %v", err)
	}
}

// submit hands a reap to the pool, falling back to running it here when the queue is full.
// Nil-safe: a pool with deferral off has no reaper and never calls this.
func (r *reaper) submit(vm deferredReaper) {
	select {
	case r.queue <- vm:
	default:
		r.inline.Add(1)
		r.run(vm)
	}
}

// close stops accepting work and waits for every queued reap to finish. Called from
// pool.Close beside inFlightWarms.Wait and reclaimDone.Wait, and for the same reason the
// comment there gives: a teardown cut short leaves state behind that only the NEXT process's
// startup sweep would collect, and SweepOrphans runs at startup only.
//
// Idempotent, because Close itself is.
func (r *reaper) close() {
	if r == nil {
		return
	}
	r.closeOnce.Do(func() { close(r.queue) })
	r.wg.Wait()
}

func (r *reaper) inlineCount() uint64 {
	if r == nil {
		return 0
	}
	return r.inline.Load()
}
