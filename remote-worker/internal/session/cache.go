package session

import (
	"crypto/sha256"
	"sync"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
)

// CacheSize bounds the dedup cache (spec §6.3).
const CacheSize = 256

// Fingerprint hashes what makes an exec the same exec. The zero-byte separator
// keeps ("a","b") from colliding with ("ab","").
func Fingerprint(command string, stdin []byte) [32]byte {
	h := sha256.New()
	h.Write([]byte(command))
	h.Write([]byte{0})
	h.Write(stdin)
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}

type entry struct {
	fingerprint [32]byte
	frame       *pb.WorkerFrame
}

// Cache dedups redelivered execs so a redelivery re-emits its terminal frame
// rather than re-running the command (spec §8).
//
// Keyed on req_id but GUARDED by a fingerprint, because req_id is not unique per
// worker: grpc-relay-transport.ts seeds its counter at module scope (per harness
// process) while select-sandbox deliberately shares sandboxes across replicas,
// so two replicas both send req_id 1, 2, 3… to the same worker (spec §3.1).
// Without the guard, one replica's exec could be answered with another's output.
type Cache struct {
	mu    sync.Mutex
	max   int
	order []uint64 // least-recently-used first
	items map[uint64]entry
}

func NewCache(max int) *Cache {
	if max <= 0 {
		max = CacheSize
	}
	return &Cache{max: max, items: make(map[uint64]entry, max)}
}

// Lookup reports a cached terminal frame for reqID when the fingerprint matches.
// (nil, false, true) means the id was reused for a DIFFERENT command: run it
// fresh, and warn.
func (c *Cache) Lookup(reqID uint64, fp [32]byte) (*pb.WorkerFrame, bool, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.items[reqID]
	if !ok {
		return nil, false, false
	}
	if e.fingerprint != fp {
		return nil, false, true
	}
	c.touch(reqID)
	return e.frame, true, false
}

func (c *Cache) Put(reqID uint64, fp [32]byte, frame *pb.WorkerFrame) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.items[reqID]; !exists {
		c.order = append(c.order, reqID)
	} else {
		c.touch(reqID)
	}
	c.items[reqID] = entry{fingerprint: fp, frame: frame}
	for len(c.order) > c.max {
		oldest := c.order[0]
		c.order = c.order[1:]
		delete(c.items, oldest)
	}
}

// touch moves reqID to the most-recent end. O(n) over at most 256 entries.
func (c *Cache) touch(reqID uint64) {
	for i, id := range c.order {
		if id == reqID {
			c.order = append(append(c.order[:i:i], c.order[i+1:]...), reqID)
			return
		}
	}
}
