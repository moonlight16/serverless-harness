package session

import (
	"crypto/sha256"
	"encoding/binary"
	"sync"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
)

// CacheSize bounds the dedup cache (spec §6.3).
const CacheSize = 256

// Fingerprint hashes what makes an exec the same exec: command, stdin, timeout_s,
// and streaming, each LENGTH-PREFIXED (command and stdin) or fixed-width (timeout_s,
// streaming). A bare separator byte is not injective — with only a NUL between two
// string fields, ("a\x00b", nil) and ("a", "b\x00") hash alike. That is not
// exploitable here (a NUL-bearing command cannot survive cmd.Start(), so it can
// never be the source of a cached entry), but this scheme is the reference other
// language ports will copy, and a length prefix makes the encoding unambiguous for
// any input rather than only for the inputs bash accepts.
//
// timeout_s and streaming are in scope for the same reason command and stdin are:
// a genuine redelivery carries the same Exec message, so all four fields are stable
// across it and including them costs nothing on the path dedup exists for. Excluding
// either lets a cross-replica req_id collision that differs only in budget or
// delivery mode be answered from the wrong entry — a second replica's "sleep 3" at
// timeout_s=30 failed off a first replica's cached timeout_s=1 ExecError in under a
// millisecond, never running, ten times inside its own budget.
func Fingerprint(command string, stdin []byte, timeoutS uint32, streaming bool) [32]byte {
	h := sha256.New()
	var n [8]byte
	binary.BigEndian.PutUint64(n[:], uint64(len(command)))
	h.Write(n[:])
	h.Write([]byte(command))
	binary.BigEndian.PutUint64(n[:], uint64(len(stdin)))
	h.Write(n[:])
	h.Write(stdin)
	binary.BigEndian.PutUint64(n[:], uint64(timeoutS))
	h.Write(n[:])
	if streaming {
		h.Write([]byte{1})
	} else {
		h.Write([]byte{0})
	}
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
