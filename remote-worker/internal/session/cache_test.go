package session_test

import (
	"fmt"
	"testing"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
	"github.com/kagenti/serverless-harness/remote-worker/internal/session"
)

func endFrame(reqID uint64, code int32) *pb.WorkerFrame {
	return &pb.WorkerFrame{Msg: &pb.WorkerFrame_End{End: &pb.End{ReqId: reqID, ExitCode: code}}}
}

func TestCacheMissOnUnknownReqID(t *testing.T) {
	c := session.NewCache(4)
	_, hit, collision := c.Lookup(1, session.Fingerprint("cat f", nil))
	if hit || collision {
		t.Fatalf("hit=%v collision=%v, want false/false for an unseen req_id", hit, collision)
	}
}

// A genuine redelivery is byte-identical, so it re-emits the cached frame.
func TestCacheHitOnMatchingFingerprint(t *testing.T) {
	c := session.NewCache(4)
	fp := session.Fingerprint("cat f", []byte("payload"))
	c.Put(7, fp, endFrame(7, 0))

	frame, hit, collision := c.Lookup(7, fp)
	if !hit || collision {
		t.Fatalf("hit=%v collision=%v, want true/false", hit, collision)
	}
	if frame.GetEnd().GetExitCode() != 0 || frame.GetEnd().GetReqId() != 7 {
		t.Errorf("cached frame = %+v, want End{7,0}", frame)
	}
}

// req_id is NOT unique per worker: the harness counter is module-scoped per
// process and sandboxes are shared across replicas (spec §3.1). A reused id with
// a different command must run fresh, never return the other command's output.
func TestCacheCollisionOnDifferentFingerprint(t *testing.T) {
	c := session.NewCache(4)
	c.Put(1, session.Fingerprint("rm -rf /b", nil), endFrame(1, 0))

	frame, hit, collision := c.Lookup(1, session.Fingerprint("cat /a", nil))
	if hit {
		t.Fatal("hit=true: a colliding req_id must not return the other command's result")
	}
	if !collision {
		t.Error("collision=false, want true so the session can warn")
	}
	if frame != nil {
		t.Errorf("frame = %+v, want nil on collision", frame)
	}
}

// Same stdin, different command — and the reverse — must not collide. Guards
// against a naive concatenation where ("a","b") and ("ab","") hash alike.
func TestFingerprintSeparatesCommandFromStdin(t *testing.T) {
	if session.Fingerprint("a", []byte("b")) == session.Fingerprint("ab", nil) {
		t.Error("fingerprint does not separate command from stdin")
	}
	if session.Fingerprint("cat f", []byte("x")) == session.Fingerprint("cat f", []byte("y")) {
		t.Error("fingerprint ignores stdin")
	}
}

func TestCacheEvictsOldestBeyondMax(t *testing.T) {
	c := session.NewCache(3)
	for i := uint64(1); i <= 4; i++ {
		c.Put(i, session.Fingerprint(fmt.Sprintf("cmd%d", i), nil), endFrame(i, 0))
	}
	if _, hit, _ := c.Lookup(1, session.Fingerprint("cmd1", nil)); hit {
		t.Error("req_id 1 still cached: nothing was evicted at max=3")
	}
	for i := uint64(2); i <= 4; i++ {
		if _, hit, _ := c.Lookup(i, session.Fingerprint(fmt.Sprintf("cmd%d", i), nil)); !hit {
			t.Errorf("req_id %d missing: wrong entry evicted", i)
		}
	}
}

// A hit refreshes recency, so the touched entry outlives an older neighbour.
func TestCacheLookupRefreshesRecency(t *testing.T) {
	c := session.NewCache(2)
	fp1, fp2, fp3 := session.Fingerprint("c1", nil), session.Fingerprint("c2", nil), session.Fingerprint("c3", nil)
	c.Put(1, fp1, endFrame(1, 0))
	c.Put(2, fp2, endFrame(2, 0))
	if _, hit, _ := c.Lookup(1, fp1); !hit { // touch 1 so 2 becomes oldest
		t.Fatal("setup: req_id 1 should be cached")
	}
	c.Put(3, fp3, endFrame(3, 0))

	if _, hit, _ := c.Lookup(1, fp1); !hit {
		t.Error("req_id 1 evicted despite being touched most recently")
	}
	if _, hit, _ := c.Lookup(2, fp2); hit {
		t.Error("req_id 2 survived: it was the least recently used")
	}
}
