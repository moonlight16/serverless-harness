package session_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
	wexec "github.com/kagenti/serverless-harness/remote-worker/internal/exec"
	"github.com/kagenti/serverless-harness/remote-worker/internal/session"
)

// fakeStream is a Stream whose Recv is scripted and whose Sends are recorded.
type fakeStream struct {
	in  chan *pb.ServerFrame
	mu  sync.Mutex
	out []*pb.WorkerFrame
	// closed once Recv should report the stream is gone.
	done chan struct{}
}

func newFakeStream() *fakeStream {
	return &fakeStream{in: make(chan *pb.ServerFrame, 16), done: make(chan struct{})}
}

func (f *fakeStream) Send(fr *pb.WorkerFrame) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.out = append(f.out, fr)
	return nil
}

func (f *fakeStream) Recv() (*pb.ServerFrame, error) {
	select {
	case fr := <-f.in:
		return fr, nil
	case <-f.done:
		return nil, errors.New("stream closed")
	}
}

func (f *fakeStream) exec(e *pb.Exec) { f.in <- &pb.ServerFrame{Msg: &pb.ServerFrame_Exec{Exec: e}} }
func (f *fakeStream) close()          { close(f.done) }
func (f *fakeStream) sent() []*pb.WorkerFrame {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]*pb.WorkerFrame(nil), f.out...)
}

// waitFor polls until cond holds or the deadline passes — no sleep-and-hope.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// scriptedRunner returns a fixed outcome and records the specs it received.
type scriptedRunner struct {
	mu    sync.Mutex
	specs []wexec.Spec
	code  int32
	err   error
	// block, when non-nil, holds Run until closed.
	block chan struct{}
}

func (r *scriptedRunner) Run(ctx context.Context, s wexec.Spec, sink wexec.Sink) (int32, error) {
	r.mu.Lock()
	r.specs = append(r.specs, s)
	r.mu.Unlock()
	if r.block != nil {
		select {
		case <-r.block:
		case <-ctx.Done():
			return -1, wexec.ErrAborted
		}
	}
	return r.code, r.err
}

func (r *scriptedRunner) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.specs)
}

func testConfig() session.Config {
	return session.Config{
		SandboxID:     "sbx-test-1",
		Image:         "img:dev",
		Trust:         "untrusted",
		Capabilities:  []string{"bash"},
		MaxConcurrent: 2,
		Heartbeat:     20 * time.Millisecond, // fast, so the test does not wait 15s
	}
}

// terminalFor finds the End/ExecError frame for reqID among what was sent.
func terminalFor(frames []*pb.WorkerFrame, reqID uint64) *pb.WorkerFrame {
	for _, f := range frames {
		if e := f.GetEnd(); e != nil && e.GetReqId() == reqID {
			return f
		}
		if e := f.GetError(); e != nil && e.GetReqId() == reqID {
			return f
		}
	}
	return nil
}

func TestHelloIsFirstFrameAndHonest(t *testing.T) {
	st := newFakeStream()
	s := session.New(testConfig(), &scriptedRunner{})
	go func() { _ = s.Serve(context.Background(), st) }()

	waitFor(t, "hello", func() bool { return len(st.sent()) >= 1 })
	first := st.sent()[0]
	h := first.GetHello()
	if h == nil {
		t.Fatalf("first frame = %+v, want Hello", first)
	}
	if h.GetSandboxId() != "sbx-test-1" || h.GetTrust() != "untrusted" || h.GetImage() != "img:dev" {
		t.Errorf("hello = %+v, want the config's values", h)
	}
	if h.GetCapacityMax() != 2 {
		t.Errorf("capacity_max = %d, want 2 (the real pool size)", h.GetCapacityMax())
	}
	if len(h.GetCapabilities()) != 1 || h.GetCapabilities()[0] != "bash" {
		t.Errorf("capabilities = %v, want [bash]", h.GetCapabilities())
	}
	st.close()
}

func TestHeartbeatsAreSent(t *testing.T) {
	st := newFakeStream()
	s := session.New(testConfig(), &scriptedRunner{})
	go func() { _ = s.Serve(context.Background(), st) }()

	waitFor(t, "a heartbeat", func() bool {
		for _, f := range st.sent() {
			if f.GetHeartbeat() != nil {
				return true
			}
		}
		return false
	})
	st.close()
}

func TestExecEmitsEndWithExitCode(t *testing.T) {
	st := newFakeStream()
	s := session.New(testConfig(), &scriptedRunner{code: 7})
	go func() { _ = s.Serve(context.Background(), st) }()
	waitFor(t, "hello", func() bool { return len(st.sent()) >= 1 })

	st.exec(&pb.Exec{ReqId: 1, Command: "exit 7", Streaming: true})
	waitFor(t, "terminal frame", func() bool { return terminalFor(st.sent(), 1) != nil })

	got := terminalFor(st.sent(), 1)
	if got.GetEnd() == nil || got.GetEnd().GetExitCode() != 7 {
		t.Errorf("terminal = %+v, want End{exit_code:7}", got)
	}
	st.close()
}

func TestTimeoutBecomesExecError(t *testing.T) {
	st := newFakeStream()
	s := session.New(testConfig(), &scriptedRunner{err: wexec.ErrTimeout})
	go func() { _ = s.Serve(context.Background(), st) }()
	waitFor(t, "hello", func() bool { return len(st.sent()) >= 1 })

	st.exec(&pb.Exec{ReqId: 2, Command: "sleep 30", TimeoutS: 30, Streaming: true})
	waitFor(t, "terminal frame", func() bool { return terminalFor(st.sent(), 2) != nil })

	got := terminalFor(st.sent(), 2).GetError()
	if got == nil {
		t.Fatalf("want ExecError, got %+v", terminalFor(st.sent(), 2))
	}
	// The exact string every other harness transport rejects with (spec §4 D2).
	if got.GetMessage() != "timeout:30" {
		t.Errorf("message = %q, want %q", got.GetMessage(), "timeout:30")
	}
	st.close()
}

func TestErrAbortedMapsToSignalledEnd(t *testing.T) {
	st := newFakeStream()
	s := session.New(testConfig(), &scriptedRunner{err: wexec.ErrAborted})
	go func() { _ = s.Serve(context.Background(), st) }()
	waitFor(t, "hello", func() bool { return len(st.sent()) >= 1 })

	st.exec(&pb.Exec{ReqId: 3, Command: "sleep 30", Streaming: true})
	waitFor(t, "terminal frame", func() bool { return terminalFor(st.sent(), 3) != nil })

	if got := terminalFor(st.sent(), 3).GetEnd(); got == nil || got.GetExitCode() != -1 {
		t.Errorf("terminal = %+v, want End{exit_code:-1}", terminalFor(st.sent(), 3))
	}
	st.close()
}

func TestRunnerErrorBecomesExecError(t *testing.T) {
	st := newFakeStream()
	s := session.New(testConfig(), &scriptedRunner{err: errors.New("start bash: no such file")})
	go func() { _ = s.Serve(context.Background(), st) }()
	waitFor(t, "hello", func() bool { return len(st.sent()) >= 1 })

	st.exec(&pb.Exec{ReqId: 4, Command: "whatever", Streaming: true})
	waitFor(t, "terminal frame", func() bool { return terminalFor(st.sent(), 4) != nil })

	got := terminalFor(st.sent(), 4).GetError()
	if got == nil || got.GetMessage() != "start bash: no such file" {
		t.Errorf("terminal = %+v, want ExecError carrying the runner error", terminalFor(st.sent(), 4))
	}
	st.close()
}

// A redelivered req_id with the same command re-emits the cached frame and the
// runner is NOT invoked a second time.
func TestRedeliveredReqIDReEmitsWithoutRerunning(t *testing.T) {
	st := newFakeStream()
	r := &scriptedRunner{code: 0}
	s := session.New(testConfig(), r)
	go func() { _ = s.Serve(context.Background(), st) }()
	waitFor(t, "hello", func() bool { return len(st.sent()) >= 1 })

	e := &pb.Exec{ReqId: 9, Command: "echo x >> log", Streaming: true}
	st.exec(e)
	waitFor(t, "first terminal", func() bool { return terminalFor(st.sent(), 9) != nil })
	if r.count() != 1 {
		t.Fatalf("runner calls = %d, want 1", r.count())
	}

	st.exec(&pb.Exec{ReqId: 9, Command: "echo x >> log", Streaming: true})
	waitFor(t, "second terminal", func() bool {
		n := 0
		for _, f := range st.sent() {
			if e := f.GetEnd(); e != nil && e.GetReqId() == 9 {
				n++
			}
		}
		return n >= 2
	})
	if r.count() != 1 {
		t.Errorf("runner calls = %d, want 1: the redelivery re-ran the command", r.count())
	}
	st.close()
}

// A reused req_id carrying a DIFFERENT command must run, not return the cached
// result (spec §3.1).
func TestCollidingReqIDRunsFresh(t *testing.T) {
	st := newFakeStream()
	r := &scriptedRunner{code: 0}
	s := session.New(testConfig(), r)
	go func() { _ = s.Serve(context.Background(), st) }()
	waitFor(t, "hello", func() bool { return len(st.sent()) >= 1 })

	st.exec(&pb.Exec{ReqId: 5, Command: "rm -rf /b", Streaming: true})
	waitFor(t, "first terminal", func() bool { return terminalFor(st.sent(), 5) != nil })

	st.exec(&pb.Exec{ReqId: 5, Command: "cat /a", Streaming: true})
	waitFor(t, "second run", func() bool { return r.count() >= 2 })

	r.mu.Lock()
	second := r.specs[1].Command
	r.mu.Unlock()
	if second != "cat /a" {
		t.Errorf("second run command = %q, want %q", second, "cat /a")
	}
	st.close()
}
