package exec_test

import (
	"context"
	"strings"
	"testing"

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
