package exec_test

import (
	"context"
	"encoding/base64"
	"errors"
	"os"
	osexec "os/exec"
	"strings"
	"testing"
	"time"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
	wexec "github.com/kagenti/serverless-harness/remote-worker/internal/exec"
)

// recorder is a Sink that keeps every chunk, tagged by stream.
type recorder struct {
	stdout []byte
	stderr []byte
	calls  int
	failAt int // when >0, return an error on that call number (1-based)
}

func (r *recorder) Chunk(stream pb.Stream, data []byte) error {
	r.calls++
	if r.failAt > 0 && r.calls >= r.failAt {
		return errStreamGone
	}
	switch stream {
	case pb.Stream_STREAM_STDERR:
		r.stderr = append(r.stderr, data...)
	default:
		r.stdout = append(r.stdout, data...)
	}
	return nil
}

var errStreamGone = errStr("stream gone")

type errStr string

func (e errStr) Error() string { return string(e) }

func TestSplitsStdoutAndStderr(t *testing.T) {
	var r recorder
	code, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID:     1,
		Command:   "echo hi; echo oops >&2; exit 7",
		Streaming: true,
	}, &r)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if code != 7 {
		t.Errorf("exit code = %d, want 7", code)
	}
	if got := string(r.stdout); got != "hi\n" {
		t.Errorf("stdout = %q, want %q", got, "hi\n")
	}
	if got := string(r.stderr); got != "oops\n" {
		t.Errorf("stderr = %q, want %q", got, "oops\n")
	}
}

func TestExitZero(t *testing.T) {
	var r recorder
	code, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID: 2, Command: "true", Streaming: true,
	}, &r)
	if err != nil || code != 0 {
		t.Fatalf("got code=%d err=%v, want 0/nil", code, err)
	}
}

// A single frame must stay small (spec §8): output larger than ChunkSize
// arrives as several chunks, and every one is at most ChunkSize.
func TestChunkCapSplitsLargeOutput(t *testing.T) {
	var sizes []int
	sink := sinkFunc(func(_ pb.Stream, data []byte) error {
		sizes = append(sizes, len(data))
		return nil
	})
	want := 40 * 1024
	code, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID:     3,
		Command:   "head -c 40960 /dev/zero | tr '\\0' 'a'",
		Streaming: true,
	}, sink)
	if err != nil || code != 0 {
		t.Fatalf("got code=%d err=%v", code, err)
	}
	total := 0
	for _, n := range sizes {
		if n > wexec.ChunkSize {
			t.Errorf("chunk of %d bytes exceeds cap %d", n, wexec.ChunkSize)
		}
		total += n
	}
	if total != want {
		t.Errorf("total bytes = %d, want %d", total, want)
	}
	if len(sizes) < 2 {
		t.Errorf("got %d chunk(s), want >=2 for %d bytes", len(sizes), want)
	}
}

// A sink failure means the stream is gone: Run reports it so the session knows
// not to try sending a terminal frame.
func TestSinkErrorPropagates(t *testing.T) {
	r := recorder{failAt: 1}
	_, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID: 4, Command: "echo hi", Streaming: true,
	}, &r)
	if err == nil || !strings.Contains(err.Error(), "stream gone") {
		t.Fatalf("err = %v, want it to carry the sink failure", err)
	}
}

type sinkFunc func(pb.Stream, []byte) error

func (f sinkFunc) Chunk(s pb.Stream, d []byte) error { return f(s, d) }

// A pipe holder that escapes the process group survives the SIGKILL, so only
// the drain watchdog can unblock Run. Without it, this test hangs.
func TestRunReturnsWhenPipeHolderEscapesGroup(t *testing.T) {
	if _, err := osexec.LookPath("setsid"); err != nil {
		t.Skip("no setsid: cannot detach a pipe holder from the process group")
	}
	start := time.Now()
	var r recorder
	_, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID: 30, Command: "setsid sleep 30 & exit 0", TimeoutS: 1, Streaming: true,
	}, &r)
	if err == nil {
		t.Log("Run returned nil; the point of this test is that it RETURNS")
	}
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Fatalf("Run took %v: the drain was not bounded", elapsed)
	}
}

// streaming:false means no incremental delivery, not "exactly one frame":
// buffered output at exit still has to respect the wire's ChunkSize cap.
func TestNonStreamingChunksAtExit(t *testing.T) {
	var sizes []int
	sink := sinkFunc(func(_ pb.Stream, data []byte) error {
		sizes = append(sizes, len(data))
		return nil
	})
	want := 40 * 1024
	code, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID:     32,
		Command:   "head -c 40960 /dev/zero | tr '\\0' 'a'",
		Streaming: false,
	}, sink)
	if err != nil || code != 0 {
		t.Fatalf("got code=%d err=%v", code, err)
	}
	total := 0
	for _, n := range sizes {
		if n > wexec.ChunkSize {
			t.Errorf("chunk of %d bytes exceeds cap %d", n, wexec.ChunkSize)
		}
		total += n
	}
	if total != want {
		t.Errorf("total bytes = %d, want %d", total, want)
	}
	if len(sizes) < 2 {
		t.Errorf("got %d chunk(s), want >=2 for %d bytes", len(sizes), want)
	}
}

// A small non-streaming exec still yields exactly one Chunk per stream: the
// slicing in emitBuffered must not fragment output that already fits.
func TestNonStreamingSmallOutputIsOneChunkPerStream(t *testing.T) {
	var r recorder
	code, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID:     33,
		Command:   "echo hi; echo oops >&2",
		Streaming: false,
	}, &r)
	if err != nil || code != 0 {
		t.Fatalf("got code=%d err=%v", code, err)
	}
	if got := string(r.stdout); got != "hi\n" {
		t.Errorf("stdout = %q, want %q", got, "hi\n")
	}
	if got := string(r.stderr); got != "oops\n" {
		t.Errorf("stderr = %q, want %q", got, "oops\n")
	}
	if r.calls != 2 {
		t.Errorf("calls = %d, want 2 (one Chunk per stream)", r.calls)
	}
}

// The child exits 0 immediately; the sink is slow enough that the deadline
// fires mid-drain. The exit code must win over the expired context.
func TestSlowSinkDoesNotTurnSuccessIntoTimeout(t *testing.T) {
	slow := sinkFunc(func(pb.Stream, []byte) error {
		time.Sleep(1500 * time.Millisecond)
		return nil
	})
	code, err := wexec.BashRunner{}.Run(context.Background(), wexec.Spec{
		ReqID: 31, Command: "echo hi", TimeoutS: 1, Streaming: true,
	}, slow)
	if err != nil {
		t.Fatalf("err = %v, want nil: the command exited 0 before the deadline", err)
	}
	if code != 0 {
		t.Errorf("code = %d, want 0", code)
	}
}

// The harness writes files as `base64 -d > 'path'` with the payload on stdin.
// base64 only terminates at EOF, so this is the test that catches a regression
// where stdin is written but never closed.
func TestStdinRoundTripsThroughBase64(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/out.txt"
	content := "hello from stdin\n"
	payload := base64.StdEncoding.EncodeToString([]byte(content))

	// Bound the run. If stdin is ever written-but-not-closed, `base64 -d` never
	// sees EOF — the exact regression this test exists to catch — and without a
	// deadline that hangs the whole test binary until `go test`'s 10-minute
	// timeout instead of failing here in seconds.
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	var r recorder
	code, err := wexec.BashRunner{}.Run(ctx, wexec.Spec{
		ReqID:     10,
		Command:   "base64 -d > " + path,
		Stdin:     []byte(payload),
		Streaming: true,
	}, &r)
	if errors.Is(err, wexec.ErrTimeout) || errors.Is(err, wexec.ErrAborted) {
		t.Fatalf("run did not finish (%v): stdin was written but never closed, so base64 -d never saw EOF", err)
	}
	if err != nil || code != 0 {
		t.Fatalf("got code=%d err=%v, want 0/nil", code, err)
	}
	got, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("ReadFile: %v", readErr)
	}
	if string(got) != content {
		t.Errorf("file = %q, want %q", got, content)
	}
}

// A command that reads stdin but is given none must still terminate, or every
// such exec hangs until the harness deadline.
func TestNoStdinStillTerminates(t *testing.T) {
	// Two deliberate choices. The context bounds Run so a regression cannot leak
	// this goroutine (or its `cat` child) past the test. And the result comes back
	// over a buffered channel rather than via t.Errorf from inside the goroutine:
	// calling t after the test has completed panics the entire test binary, which
	// destroys every other result in the run.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	type result struct {
		code int32
		err  error
	}
	done := make(chan result, 1) // buffered: the goroutine never blocks on send
	go func() {
		var r recorder
		code, err := wexec.BashRunner{}.Run(ctx, wexec.Spec{
			ReqID: 11, Command: "cat", Streaming: true,
		}, &r)
		done <- result{code: code, err: err}
	}()

	select {
	case got := <-done:
		if errors.Is(got.err, wexec.ErrTimeout) || errors.Is(got.err, wexec.ErrAborted) {
			t.Fatalf("`cat` with no stdin did not terminate on its own (%v): stdin was not closed", got.err)
		}
		if got.err != nil {
			t.Fatalf("Run: %v", got.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("`cat` with no stdin did not terminate within 5s: stdin was not closed")
	}
}

// NOTE: the non-streaming coverage originally planned here (small output -> one
// Chunk per stream; 40 KiB -> chunked at ChunkSize) already landed in Task 2's
// fix round as TestNonStreamingChunksAtExit and
// TestNonStreamingSmallOutputIsOneChunkPerStream. Do NOT re-add it here —
// duplicate coverage of the same behavior is a review defect. This task adds the
// stdin tests only.
