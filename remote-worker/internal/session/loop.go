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
//
// One dedicated sender goroutine owns st.Send: no mutex serializes it, because
// gRPC-Go's SendMsg blocks on flow control, and if any producer held a lock
// across that call while ALSO trying to refuse work inline (the old design),
// the recv goroutine could stall behind its own refusal frame with an Abort
// queued right behind it in the stream — deadlock, since that Abort is what
// would free the pool that is saturating the send window. Routing every frame
// through a channel instead makes "send" a non-blocking enqueue for the recv
// goroutine and a bounded-blocking enqueue (correct backpressure) for everyone
// else.
func (s *Session) Serve(ctx context.Context, st Stream) error {
	connCtx, cancelConn := context.WithCancel(ctx)
	// Cancelling the connection context kills every in-flight child: their output
	// has nowhere to go, and the relay has already failed them harness-side
	// (relay.ts:89-93), so leaving them running only orphans work (spec §6.2).
	defer cancelConn()

	// Hello goes out directly, before any goroutine exists. No concurrency yet,
	// so there is nothing to race and no need for the outbound channel just to
	// guarantee it is first.
	if err := st.Send(&pb.WorkerFrame{Msg: &pb.WorkerFrame_Hello{Hello: &pb.Hello{
		SandboxId:    s.cfg.SandboxID,
		Capabilities: s.cfg.Capabilities,
		Image:        s.cfg.Image,
		Arch:         runtime.GOARCH,
		CapacityMax:  uint32(s.cfg.MaxConcurrent),
		Trust:        s.cfg.Trust,
	}}}); err != nil {
		return fmt.Errorf("send hello: %w", err)
	}

	outbound := make(chan *pb.WorkerFrame, QueueCap)
	var wgSender sync.WaitGroup
	wgSender.Add(1)
	go func() {
		defer wgSender.Done()
		failed := false
		for f := range outbound {
			if failed {
				// Keep draining rather than returning: if this goroutine exited early,
				// every later blocking enqueue below would block forever once the
				// buffer filled, and wg.Wait() in Serve would never reach zero.
				continue
			}
			if err := st.Send(f); err != nil {
				failed = true
				cancelConn()
			}
		}
	}()

	// enqueue is the blocking sender used by producers (heartbeat, the pool).
	// Backpressure here is correct: neither is the recv goroutine, so blocking
	// them cannot stall a read of an Abort frame. The sender above always keeps
	// draining outbound (forwarding or discarding), so this never blocks forever
	// even after a send failure.
	enqueue := func(f *pb.WorkerFrame) { outbound <- f }
	// trySend is the non-blocking sender used by the recv goroutine (via accept).
	// It must never block: the recv goroutine has to stay free to read the next
	// Abort, so an advisory frame is dropped rather than stalling the stream.
	trySend := func(f *pb.WorkerFrame) bool {
		select {
		case outbound <- f:
			return true
		default:
			log.Printf("session: outbound full, dropping frame for req_id %d", reqIDOf(f))
			return false
		}
	}

	var wg sync.WaitGroup // producers: heartbeat + pool workers
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
				enqueue(&pb.WorkerFrame{Msg: &pb.WorkerFrame_Heartbeat{Heartbeat: &pb.Heartbeat{}}})
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
				s.runOne(sl.ctx, enqueue, e)
				finish(e.GetReqId())
			}
		}()
	}

	recvErr := s.recvLoop(connCtx, st, trySend, queue, inflight, &mu, abortReq)

	// Cancel BEFORE closing the queue: a still-queued exec must see a done ctx
	// once dequeued, so runOne takes its "aborted while queued" branch instead of
	// spawning a real bash child only to kill it immediately.
	cancelConn() // stop heartbeats and kill in-flight/queued children
	close(queue)
	wg.Wait() // producers done: no more enqueues to outbound
	close(outbound)
	wgSender.Wait()
	return recvErr
}

// recvLoop reads server frames until the stream fails. It must NEVER block: if
// dispatch blocked on a full queue — or on sending a refusal frame — an Abort
// queued behind it could never be read, and that abort is what would free the
// pool (spec §6.2). Every send accept makes goes through trySend accordingly.
func (s *Session) recvLoop(
	ctx context.Context,
	st Stream,
	trySend func(*pb.WorkerFrame) bool,
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
			s.accept(ctx, trySend, queue, inflight, mu, m.Exec)
		case *pb.ServerFrame_Abort:
			// Cancel only — do NOT remove the slot. runOne owns the terminal frame in
			// both cases: a running exec's Run returns ErrAborted, and a queued exec
			// sees a done ctx before spawning bash and emits End{-1} without running.
			// Abort for an unknown req_id is a no-op (spec §8).
			abortReq(m.Abort.GetReqId())
		}
	}
}

// accept decides an exec's fate without blocking: cached, queued, coalesced
// into an already-running duplicate, or refused. Every send here uses trySend,
// since this runs on the recv goroutine.
func (s *Session) accept(
	ctx context.Context,
	trySend func(*pb.WorkerFrame) bool,
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
		trySend(frame)
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
		// The original's terminal frame for this req_id is already owed and on
		// its way. Sending a refusal here would be a SECOND terminal frame for
		// one id: a caller keyed on req_id would settle it as failed on this
		// refusal, then receive the real (possibly successful, possibly
		// filesystem-mutating) result and have nowhere to put it. Silently
		// coalesce instead — the exec already owes exactly one terminal frame,
		// and it is coming.
		log.Printf("session: req_id %d already in flight; coalescing duplicate delivery", reqID)
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
		trySend(errFrame(reqID, "busy: queue full"))
	}
}

// frameSink turns runner output into Chunk frames. It only ever enqueues: with
// a dedicated sender goroutine owning st.Send, Chunk itself never observes a
// send failure, so there is nothing to report and nothing to remember.
type frameSink struct {
	reqID uint64
	send  func(*pb.WorkerFrame)
}

func (f *frameSink) Chunk(stream pb.Stream, data []byte) error {
	f.send(&pb.WorkerFrame{Msg: &pb.WorkerFrame_Chunk{Chunk: &pb.Chunk{
		ReqId: f.reqID, Data: data, Stream: stream,
	}}})
	return nil
}

// runOne executes one exec and sends exactly one terminal frame (spec §5).
// send is the blocking enqueue: runOne runs on a pool goroutine, not the recv
// goroutine, so backpressure here is correct rather than dangerous.
func (s *Session) runOne(ctx context.Context, send func(*pb.WorkerFrame), e *pb.Exec) {
	reqID := e.GetReqId()
	if ctx.Err() != nil {
		// Aborted while queued: never spawn bash, but still owe a terminal frame.
		send(endFrame(reqID, -1))
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
	// redelivery of that req_id answer -1 forever (spec §6.2: dedup protects
	// completed execs only).
	if cacheable {
		s.cache.Put(reqID, Fingerprint(e.GetCommand(), e.GetStdin()), frame)
	}
	send(frame)
}

func endFrame(reqID uint64, code int32) *pb.WorkerFrame {
	return &pb.WorkerFrame{Msg: &pb.WorkerFrame_End{End: &pb.End{ReqId: reqID, ExitCode: code}}}
}

func errFrame(reqID uint64, msg string) *pb.WorkerFrame {
	return &pb.WorkerFrame{Msg: &pb.WorkerFrame_Error{Error: &pb.ExecError{ReqId: reqID, Message: msg}}}
}

// reqIDOf extracts the req_id carried by a WorkerFrame, for logging when
// trySend drops a frame. Frames with no req_id (Hello, Heartbeat) report 0.
func reqIDOf(f *pb.WorkerFrame) uint64 {
	switch m := f.Msg.(type) {
	case *pb.WorkerFrame_End:
		return m.End.GetReqId()
	case *pb.WorkerFrame_Error:
		return m.Error.GetReqId()
	case *pb.WorkerFrame_Chunk:
		return m.Chunk.GetReqId()
	default:
		return 0
	}
}
