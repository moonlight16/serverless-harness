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

// Sink receives output as it is produced. data is owned by the callee.
type Sink interface {
	Chunk(stream pb.Stream, data []byte) error
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
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	// Bound the post-kill pipe drain so a wedged grandchild cannot hang Wait.
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

	// StdoutPipe's contract: Wait closes the pipes, so all reads must finish first.
	wg.Wait()
	waitErr := cmd.Wait()

	if sinkErr != nil {
		return -1, sinkErr
	}
	// Non-streaming: one Chunk per stream at exit. End cannot carry stdout in
	// sandbox/v1, so a single buffered Chunk is the only expressible shape for
	// "no incremental delivery" (spec §3.2).
	if !s.Streaming {
		if outBuf.Len() > 0 {
			if err := sink.Chunk(pb.Stream_STREAM_STDOUT, outBuf.Bytes()); err != nil {
				return -1, err
			}
		}
		if errBuf.Len() > 0 {
			if err := sink.Chunk(pb.Stream_STREAM_STDERR, errBuf.Bytes()); err != nil {
				return -1, err
			}
		}
	}

	switch {
	case errors.Is(runCtx.Err(), context.DeadlineExceeded):
		return -1, ErrTimeout
	case runCtx.Err() != nil:
		return -1, ErrAborted
	case waitErr == nil:
		return 0, nil
	}
	var exitErr *exec.ExitError
	if errors.As(waitErr, &exitErr) {
		// ExitCode() is -1 when signalled, which is exactly End's "signal/none".
		return int32(exitErr.ExitCode()), nil
	}
	return -1, fmt.Errorf("wait: %w", waitErr)
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
