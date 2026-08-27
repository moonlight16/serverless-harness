// Package exec runs one sandbox command per call: a `bash -c` child whose
// stdout and stderr stream back as capped Chunk payloads. It holds no
// credentials, makes no network calls, and knows nothing about the relay — the
// property that makes the "central brain" trust model correct (spec §7).
package exec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
)

// ChunkSize caps one Chunk frame's payload. It is also the pipe read size, so
// backpressure costs no extra buffering layer (spec §8).
const ChunkSize = 32 * 1024

// BufferCap bounds buffered output for non-streaming execs, matching the
// harness's DEFAULT_OUTPUT_CAP (grpc-relay-transport.ts:30). Output past it is
// dropped — the harness applies its own cap and truncation marker anyway.
const BufferCap = 8 * 1024 * 1024

// drainGrace is how long the drain watchdog waits, after runCtx ends, before
// force-closing the pipe readers itself. Wait only closes those readers from
// inside itself once every *Pipe() read has finished, so a grandchild that
// escapes the process group (setsid) or outlives it (TimeoutS == 0) would
// otherwise wedge the pumps — and Run — forever (go.dev/issue/23019: the
// os/exec Cancel/WaitDelay mitigation explicitly excludes *Pipe() users).
const drainGrace = 2 * time.Second

// ErrTimeout means the child outlived Spec.TimeoutS and its process group was
// SIGKILLed. The session maps it to ExecError{"timeout:<n>"} — byte-identical to
// what every other harness transport rejects with (spec §4 D2).
var ErrTimeout = errors.New("timeout")

// ErrAborted means the caller's context was cancelled: an Abort frame, or the
// stream dying. The session maps it to End{exit_code:-1} (signal/none).
var ErrAborted = errors.New("aborted")

// Spec is one command to run. It mirrors pb.Exec minus the wire types, so the
// runner has no dependency on frame plumbing.
type Spec struct {
	ReqID     uint64
	Command   string
	Stdin     []byte
	TimeoutS  uint32
	Streaming bool
}

// Sink receives output as it is produced. data is owned by the callee. Chunk is
// never called concurrently: Run drains stdout and stderr on separate
// goroutines but serializes all calls to the caller's Sink through a single
// lock, so implementations need not synchronize internally.
type Sink interface {
	Chunk(stream pb.Stream, data []byte) error
}

// lockedSink serializes Chunk calls. Run drains stdout and stderr in two
// goroutines, and the runner owns the concurrency it creates rather than
// pushing a thread-safety requirement onto every Sink implementation.
type lockedSink struct {
	mu    sync.Mutex
	inner Sink
}

func (l *lockedSink) Chunk(stream pb.Stream, data []byte) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.inner.Chunk(stream, data)
}

// Runner runs one command. ctx cancellation means Abort: kill the process group.
type Runner interface {
	Run(ctx context.Context, s Spec, sink Sink) (int32, error)
}

// BashRunner is the real Runner: `bash -c <command>` per exec, no persistent
// shell. Every command the harness sends is self-contained (`cd 'cwd' && …`), and
// decisively, `base64 -d > f` only terminates on stdin EOF — which a shared
// long-lived shell cannot deliver per-exec (spec §4 D1).
type BashRunner struct{}

func (BashRunner) Run(ctx context.Context, s Spec, sink Sink) (int32, error) {
	// One lock serializes every call to the caller's Sink: the two pump
	// goroutines below (and the non-streaming emission at exit) must not race
	// on it.
	sink = &lockedSink{inner: sink}
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	if s.TimeoutS > 0 {
		var stop context.CancelFunc
		runCtx, stop = context.WithTimeout(runCtx, time.Duration(s.TimeoutS)*time.Second)
		defer stop()
	}

	cmd := exec.CommandContext(runCtx, "bash", "-c", s.Command)
	// Setpgid + killing -pid takes out the whole group. CommandContext's default
	// signals only the direct bash, but real commands are pipelines with
	// grandchildren (`cd 'x' && rg --files … | head -n 200`), which would
	// otherwise survive an abort or timeout.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	// Best-effort: send the kill, but always report os.ErrProcessDone. Per
	// exec.Cmd.Cancel's doc, if the child happens to have already exited with a
	// success status by the time Cancel runs — exactly the race this fixes,
	// since the drain (and thus our call to cmd.Wait) can run well after the
	// child's own exit when a sink is slow — any other return value makes Wait
	// report a synthetic ctx/Cancel error instead of the real (successful) exit
	// status. A child actually still alive exits with a non-success (signalled)
	// status when the kill lands, and that path is untouched by Cancel's return
	// value, so reporting ErrProcessDone unconditionally is safe either way.
	cmd.Cancel = func() error {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		return os.ErrProcessDone
	}
	// WaitDelay bounds only Wait's own internal I/O cleanup after the process
	// exits or is killed; it does NOT bound reads from the *Pipe() readers
	// below, since those are closed by Wait itself only after all reads from
	// them finish (go.dev/issue/23019 — the *Pipe() case is explicitly excluded
	// from this mitigation). The drain watchdog started below is what actually
	// bounds the pumps.
	cmd.WaitDelay = 2 * time.Second

	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		return -1, fmt.Errorf("stdin pipe: %w", err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return -1, fmt.Errorf("stdout pipe: %w", err)
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return -1, fmt.Errorf("stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return -1, fmt.Errorf("start bash: %w", err)
	}

	// stdin ALWAYS closes. `base64 -d > f` waits for EOF, and a command given no
	// stdin must still see EOF or anything reading it blocks forever.
	go func() {
		if len(s.Stdin) > 0 {
			_, _ = stdinPipe.Write(s.Stdin)
		}
		_ = stdinPipe.Close()
	}()

	var (
		mu      sync.Mutex
		sinkErr error
		outBuf  bytes.Buffer
		errBuf  bytes.Buffer
		wg      sync.WaitGroup
	)
	pump := func(r io.Reader, which pb.Stream, buf *bytes.Buffer) {
		defer wg.Done()
		if err := drain(r, which, s, sink, buf); err != nil {
			mu.Lock()
			if sinkErr == nil {
				sinkErr = err
			}
			mu.Unlock()
			cancel() // the stream is gone; stop the child rather than keep reading
		}
	}
	wg.Add(2)
	go pump(stdoutPipe, pb.Stream_STREAM_STDOUT, &outBuf)
	go pump(stderrPipe, pb.Stream_STREAM_STDERR, &errBuf)

	// Drain watchdog: once runCtx ends (Abort or timeout), give the pumps
	// drainGrace to finish on their own — the SIGKILL above is normally enough
	// — then force-close the pipe readers ourselves so a pump wedged on a Read
	// from a pipe holder that escaped or outlived the process group returns
	// instead of blocking forever. A forced close surfaces as a read error,
	// which drain already swallows, so it is indistinguishable from EOF here.
	// watchdogDone is closed on every return path so a healthy exec never
	// waits out drainGrace for nothing.
	watchdogDone := make(chan struct{})
	defer close(watchdogDone)
	go func() {
		select {
		case <-runCtx.Done():
		case <-watchdogDone:
			return
		}
		select {
		case <-time.After(drainGrace):
			_ = stdoutPipe.Close()
			_ = stderrPipe.Close()
		case <-watchdogDone:
		}
	}()

	// StdoutPipe's contract: Wait closes the pipes, so all reads must finish first.
	wg.Wait()
	waitErr := cmd.Wait()

	if sinkErr != nil {
		return -1, sinkErr
	}
	// Non-streaming means no incremental delivery — nothing leaves before the
	// process exits — not "exactly one frame": the buffered output still has
	// to respect ChunkSize, the wire's per-frame cap (spec §8), so it goes out
	// in slices at exit rather than as one BufferCap-sized Chunk.
	if !s.Streaming {
		if err := emitBuffered(sink, pb.Stream_STREAM_STDOUT, &outBuf); err != nil {
			return -1, err
		}
		if err := emitBuffered(sink, pb.Stream_STREAM_STDERR, &errBuf); err != nil {
			return -1, err
		}
	}

	// A clean exit, or any *exec.ExitError with a non-negative code, proves the
	// child was not SIGKILLed — even if runCtx ended while the pumps were still
	// delivering to a slow sink. That must outrank ctx state, or a command that
	// finished successfully just before the deadline could be misreported as a
	// timeout. ctx state only decides the outcome when the exit was a signal
	// (ExitCode() == -1) or waitErr isn't an ExitError at all.
	var exitErr *exec.ExitError
	hasExitErr := errors.As(waitErr, &exitErr)
	switch {
	case waitErr == nil:
		return 0, nil
	case hasExitErr && exitErr.ExitCode() >= 0:
		return int32(exitErr.ExitCode()), nil
	case errors.Is(runCtx.Err(), context.DeadlineExceeded):
		return -1, ErrTimeout
	case runCtx.Err() != nil:
		return -1, ErrAborted
	case hasExitErr:
		// ExitCode() is -1 when signalled, which is exactly End's "signal/none".
		return int32(exitErr.ExitCode()), nil
	}
	return -1, fmt.Errorf("wait: %w", waitErr)
}

// emitBuffered sends buf's contents as one or more ChunkSize-capped Chunks.
// Called only from the non-streaming exit path, after the process has
// already finished, so slicing buf.Bytes() directly (no copy) is safe: buf is
// never written to again.
func emitBuffered(sink Sink, which pb.Stream, buf *bytes.Buffer) error {
	data := buf.Bytes()
	for len(data) > 0 {
		n := min(len(data), ChunkSize)
		if err := sink.Chunk(which, data[:n]); err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}

// drain reads one pipe to exhaustion. Only SINK errors are returned: once the
// process group is killed the pipes close, and surfacing that read error would
// mask ErrTimeout and suppress the terminal frame the session owes the harness.
func drain(r io.Reader, which pb.Stream, s Spec, sink Sink, buf *bytes.Buffer) error {
	b := make([]byte, ChunkSize)
	for {
		n, err := r.Read(b)
		if n > 0 {
			if s.Streaming {
				// Copy: the payload becomes a proto field the sink may retain.
				if err := sink.Chunk(which, append([]byte(nil), b[:n]...)); err != nil {
					return err
				}
			} else if room := BufferCap - buf.Len(); room > 0 {
				buf.Write(b[:min(n, room)])
			}
		}
		if err != nil {
			return nil // EOF, or pipes closed by the kill: nothing more to read
		}
	}
}
