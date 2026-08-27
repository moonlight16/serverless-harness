package session

import (
	"context"
	"errors"
	"fmt"
	"log"
	"runtime"
	"sync"
	"time"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
	wexec "github.com/kagenti/serverless-harness/remote-worker/internal/exec"
)

const (
	// QueueCap bounds queued execs. Overflow is refused rather than blocking the
	// recv loop — see Serve.
	QueueCap = 64
	// DefaultConcurrency is the pool size, advertised as Hello.capacity_max.
	DefaultConcurrency = 4
	// DefaultHeartbeat is liveness plus NAT/proxy keepalive (spec §7 item 4).
	DefaultHeartbeat = 15 * time.Second
)

// Config is everything the session needs that does not come off the wire.
type Config struct {
	SandboxID     string
	Image         string
	Trust         string
	Capabilities  []string
	MaxConcurrent int
	Heartbeat     time.Duration
}

// Stream is one Attach connection. pb.SandboxWorker_AttachClient satisfies it
// directly, so production needs no adapter.
type Stream interface {
	Send(*pb.WorkerFrame) error
	Recv() (*pb.ServerFrame, error)
}

// Session holds state that must outlive any single connection — above all the
// dedup cache, so a reconnect does not forget what already ran (spec §5).
type Session struct {
	cfg    Config
	runner wexec.Runner
	cache  *Cache
}

func New(cfg Config, r wexec.Runner) *Session {
	if cfg.MaxConcurrent <= 0 {
		cfg.MaxConcurrent = DefaultConcurrency
	}
	if cfg.Heartbeat <= 0 {
		cfg.Heartbeat = DefaultHeartbeat
	}
	return &Session{cfg: cfg, runner: r, cache: NewCache(CacheSize)}
}

// slot tracks one accepted exec so an Abort can reach it whether it is running
// or still queued.
type slot struct {
	ctx    context.Context
	cancel context.CancelFunc
}

// Serve runs one connection to exhaustion and returns why it ended. The caller
// re-dials and calls Serve again; the cache survives because it lives on Session.
func (s *Session) Serve(ctx context.Context, st Stream) error {
	connCtx, cancelConn := context.WithCancel(ctx)
	// Cancelling the connection context kills every in-flight child: their output
	// has nowhere to go, and the relay has already failed them harness-side
	// (relay.ts:89-93), so leaving them running only orphans work (spec §6.2).
	defer cancelConn()

	// gRPC streams are not safe for concurrent Send, and the heartbeat goroutine
	// plus every pool goroutine share this one.
	var sendMu sync.Mutex
	send := func(f *pb.WorkerFrame) error {
		sendMu.Lock()
		defer sendMu.Unlock()
		return st.Send(f)
	}

	if err := send(&pb.WorkerFrame{Msg: &pb.WorkerFrame_Hello{Hello: &pb.Hello{
		SandboxId:    s.cfg.SandboxID,
		Capabilities: s.cfg.Capabilities,
		Image:        s.cfg.Image,
		Arch:         runtime.GOARCH,
		CapacityMax:  uint32(s.cfg.MaxConcurrent),
		Trust:        s.cfg.Trust,
	}}}); err != nil {
		return fmt.Errorf("send hello: %w", err)
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(s.cfg.Heartbeat)
		defer t.Stop()
		for {
			select {
			case <-connCtx.Done():
				return
			case <-t.C:
				if err := send(&pb.WorkerFrame{Msg: &pb.WorkerFrame_Heartbeat{Heartbeat: &pb.Heartbeat{}}}); err != nil {
					return
				}
			}
		}
	}()

	var (
		mu       sync.Mutex
		inflight = map[uint64]*slot{}
	)
	// abortReq cancels an exec but deliberately LEAVES it in the map. A queued
	// exec must still be dequeued so runOne can emit its terminal frame; deleting
	// here would make the pool skip it (sl == nil) and the harness would wait for
	// a frame that never arrives.
	abortReq := func(reqID uint64) {
		mu.Lock()
		defer mu.Unlock()
		if sl, ok := inflight[reqID]; ok {
			sl.cancel()
		}
	}
	// finish releases the slot once its terminal frame has been sent.
	finish := func(reqID uint64) {
		mu.Lock()
		defer mu.Unlock()
		if sl, ok := inflight[reqID]; ok {
			sl.cancel()
			delete(inflight, reqID)
		}
	}

	queue := make(chan *pb.Exec, QueueCap)
	for i := 0; i < s.cfg.MaxConcurrent; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for e := range queue {
				mu.Lock()
				sl := inflight[e.GetReqId()]
				mu.Unlock()
				if sl == nil {
					// Defensive only: the sole path that removes a slot before dequeue
					// is accept's queue-full branch, and that branch never enqueues.
					continue
				}
				s.runOne(sl.ctx, send, e)
				finish(e.GetReqId())
			}
		}()
	}

	recvErr := s.recvLoop(connCtx, st, send, queue, inflight, &mu, abortReq)

	close(queue)
	cancelConn() // stop heartbeats and kill in-flight children
	wg.Wait()
	return recvErr
}

// recvLoop reads server frames until the stream fails. It must NEVER block: if
// dispatch blocked on a full queue, an Abort queued behind it could never be
// read — and that abort is what would free the queue (spec §6.2).
func (s *Session) recvLoop(
	ctx context.Context,
	st Stream,
	send func(*pb.WorkerFrame) error,
	queue chan *pb.Exec,
	inflight map[uint64]*slot,
	mu *sync.Mutex,
	abortReq func(uint64),
) error {
	for {
		sf, err := st.Recv()
		if err != nil {
			return err
		}
		switch m := sf.Msg.(type) {
		case *pb.ServerFrame_Exec:
			s.accept(ctx, send, queue, inflight, mu, m.Exec)
		case *pb.ServerFrame_Abort:
			// Cancel only — do NOT remove the slot. runOne owns the terminal frame in
			// both cases: a running exec's Run returns ErrAborted, and a queued exec
			// sees a done ctx before spawning bash and emits End{-1} without running.
			// Abort for an unknown req_id is a no-op (spec §8).
			abortReq(m.Abort.GetReqId())
		}
	}
}

// accept decides an exec's fate without blocking: cached, queued, or refused.
func (s *Session) accept(
	ctx context.Context,
	send func(*pb.WorkerFrame) error,
	queue chan *pb.Exec,
	inflight map[uint64]*slot,
	mu *sync.Mutex,
	e *pb.Exec,
) {
	reqID := e.GetReqId()
	fp := Fingerprint(e.GetCommand(), e.GetStdin())

	// Consulted before enqueue: a redelivery must not consume a queue slot or a
	// pool goroutine.
	if frame, hit, collision := s.cache.Lookup(reqID, fp); hit {
		_ = send(frame)
		return
	} else if collision {
		log.Printf("session: req_id %d reused for a different command; running it fresh "+
			"(req_id is not unique across harness replicas — see spec §3.1)", reqID)
	}

	slotCtx, cancel := context.WithCancel(ctx)
	mu.Lock()
	if _, running := inflight[reqID]; running {
		mu.Unlock()
		cancel()
		_ = send(errFrame(reqID, fmt.Sprintf("req_id %d already in flight", reqID)))
		return
	}
	inflight[reqID] = &slot{ctx: slotCtx, cancel: cancel}
	mu.Unlock()

	select {
	case queue <- e:
	default:
		mu.Lock()
		delete(inflight, reqID)
		mu.Unlock()
		cancel()
		_ = send(errFrame(reqID, "busy: queue full"))
	}
}

// frameSink turns runner output into Chunk frames, remembering a send failure so
// runOne knows the stream is gone.
type frameSink struct {
	reqID  uint64
	send   func(*pb.WorkerFrame) error
	failed bool
}

func (f *frameSink) Chunk(stream pb.Stream, data []byte) error {
	if err := f.send(&pb.WorkerFrame{Msg: &pb.WorkerFrame_Chunk{Chunk: &pb.Chunk{
		ReqId: f.reqID, Data: data, Stream: stream,
	}}}); err != nil {
		f.failed = true
		return err
	}
	return nil
}

// runOne executes one exec and sends exactly one terminal frame (spec §5).
func (s *Session) runOne(ctx context.Context, send func(*pb.WorkerFrame) error, e *pb.Exec) {
	reqID := e.GetReqId()
	if ctx.Err() != nil {
		// Aborted while queued: never spawn bash, but still owe a terminal frame.
		_ = send(endFrame(reqID, -1))
		return
	}

	sink := &frameSink{reqID: reqID, send: send}
	code, err := s.runner.Run(ctx, wexec.Spec{
		ReqID:     reqID,
		Command:   e.GetCommand(),
		Stdin:     e.GetStdin(),
		TimeoutS:  e.GetTimeoutS(),
		Streaming: e.GetStreaming(),
	}, sink)

	if sink.failed {
		// The stream is gone; there is nowhere to send a terminal frame.
		return
	}

	var frame *pb.WorkerFrame
	cacheable := false
	switch {
	case err == nil:
		frame, cacheable = endFrame(reqID, code), true
	case errors.Is(err, wexec.ErrTimeout):
		frame, cacheable = errFrame(reqID, fmt.Sprintf("timeout:%d", e.GetTimeoutS())), true
	case errors.Is(err, wexec.ErrAborted):
		frame = endFrame(reqID, -1)
	default:
		frame = errFrame(reqID, err.Error())
	}

	// Only completed determinations are cached — a normal exit or a timeout, both
	// of which the worker would reproduce. Caching an abort would make every later
	// redelivery of that req_id answer -1 forever, and a stream-gone failure says
	// nothing about the command (spec §6.2: dedup protects completed execs only).
	if cacheable {
		s.cache.Put(reqID, Fingerprint(e.GetCommand(), e.GetStdin()), frame)
	}
	_ = send(frame)
}

func endFrame(reqID uint64, code int32) *pb.WorkerFrame {
	return &pb.WorkerFrame{Msg: &pb.WorkerFrame_End{End: &pb.End{ReqId: reqID, ExitCode: code}}}
}

func errFrame(reqID uint64, msg string) *pb.WorkerFrame {
	return &pb.WorkerFrame{Msg: &pb.WorkerFrame_Error{Error: &pb.ExecError{ReqId: reqID, Message: msg}}}
}
