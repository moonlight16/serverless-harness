package session_test

import (
	"context"
	"encoding/base64"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
	wexec "github.com/kagenti/serverless-harness/remote-worker/internal/exec"
	"github.com/kagenti/serverless-harness/remote-worker/internal/relaytest"
	"github.com/kagenti/serverless-harness/remote-worker/internal/session"
)

const testToken = "dev-token"

// harness is one Session (so its dedup cache persists) plus a fake relay. attach()
// can be called more than once to model a reconnect.
type harness struct {
	relay *relaytest.Relay
	sess  *session.Session
	cfg   session.Config
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	cfg := session.Config{
		SandboxID:     "sbx-contract-1",
		Image:         "contract:test",
		Trust:         "untrusted",
		Capabilities:  []string{"bash"},
		MaxConcurrent: 2,
		Heartbeat:     time.Second,
	}
	return &harness{
		relay: relaytest.Start(t),
		sess:  session.New(cfg, wexec.BashRunner{}),
		cfg:   cfg,
	}
}

// attach dials the relay, opens Attach, and serves the SAME session over it.
func (h *harness) attach(t *testing.T) *relaytest.Conn {
	t.Helper()
	cc, err := grpc.NewClient(h.relay.Addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatalf("dial %s: %v", h.relay.Addr, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+testToken)
	stream, err := pb.NewSandboxWorkerClient(cc).Attach(ctx)
	if err != nil {
		cancel()
		t.Fatalf("attach: %v", err)
	}
	go func() { _ = h.sess.Serve(ctx, stream) }()
	t.Cleanup(func() { cancel(); _ = cc.Close() })
	return h.relay.WaitAttach(t)
}

// grepCmd prefers rg (what the harness's find ops use) and falls back to grep,
// which is all CI runners are guaranteed to have.
func grepCmd(pattern, path string) string {
	if _, err := exec.LookPath("rg"); err == nil {
		return "rg " + pattern + " " + path
	}
	return "grep " + pattern + " " + path
}

func TestContractHelloCarriesTokenAndIdentity(t *testing.T) {
	h := newHarness(t)
	conn := h.attach(t)

	if got := conn.Token(); got != "Bearer "+testToken {
		t.Errorf("authorization = %q, want %q", got, "Bearer "+testToken)
	}
	hello := conn.Hello()
	if hello.GetSandboxId() != "sbx-contract-1" {
		t.Errorf("sandbox_id = %q, want sbx-contract-1", hello.GetSandboxId())
	}
	if hello.GetCapacityMax() != 2 {
		t.Errorf("capacity_max = %d, want 2", hello.GetCapacityMax())
	}
	if hello.GetArch() == "" {
		t.Error("arch is empty, want the worker's GOARCH")
	}
}

// read: `cat <file>` — the shape createPodReadOps issues (operations.ts:22).
func TestContractRead(t *testing.T) {
	h := newHarness(t)
	conn := h.attach(t)

	dir := t.TempDir()
	path := dir + "/README.md"
	if err := os.WriteFile(path, []byte("hello contract\n"), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	conn.SendExec(t, &pb.Exec{ReqId: 1, Command: "cat " + path, TimeoutS: 10, Streaming: true})
	stdout, _, terminal := conn.Collect(t, 1)

	if got := string(stdout); got != "hello contract\n" {
		t.Errorf("stdout = %q, want %q", got, "hello contract\n")
	}
	if e := terminal.GetError(); e != nil {
		t.Fatalf("ExecError: %s", e.GetMessage())
	}
	if terminal.GetEnd().GetExitCode() != 0 {
		t.Errorf("terminal = %+v, want End{0}", terminal)
	}
}

// write: `base64 -d > <file>` with the payload on stdin (operations.ts:40).
func TestContractWrite(t *testing.T) {
	h := newHarness(t)
	conn := h.attach(t)

	dir := t.TempDir()
	path := dir + "/out.txt"
	content := "written through the wire\n"

	conn.SendExec(t, &pb.Exec{
		ReqId:     2,
		Command:   "base64 -d > " + path,
		Stdin:     []byte(base64.StdEncoding.EncodeToString([]byte(content))),
		TimeoutS:  10,
		Streaming: true,
	})
	_, _, terminal := conn.Collect(t, 2)

	if e := terminal.GetError(); e != nil {
		t.Fatalf("ExecError: %s", e.GetMessage())
	}
	if terminal.GetEnd().GetExitCode() != 0 {
		t.Fatalf("terminal = %+v, want End{0}", terminal)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != content {
		t.Errorf("file = %q, want %q", got, content)
	}
}

// bash: stdout and stderr must arrive on distinct streams, with the real exit code.
func TestContractBash(t *testing.T) {
	h := newHarness(t)
	conn := h.attach(t)

	conn.SendExec(t, &pb.Exec{
		ReqId:     3,
		Command:   "echo hi; echo oops >&2; exit 7",
		TimeoutS:  10,
		Streaming: true,
	})
	stdout, stderr, terminal := conn.Collect(t, 3)

	if got := string(stdout); got != "hi\n" {
		t.Errorf("stdout = %q, want %q", got, "hi\n")
	}
	if got := string(stderr); got != "oops\n" {
		t.Errorf("stderr = %q, want %q", got, "oops\n")
	}
	if e := terminal.GetError(); e != nil {
		t.Fatalf("ExecError: %s", e.GetMessage())
	}
	if terminal.GetEnd().GetExitCode() != 7 {
		t.Errorf("terminal = %+v, want End{7}", terminal)
	}
}

// grep: a streaming op whose output exceeds one chunk, so it must arrive as several.
func TestContractGrepStreamsMultipleChunks(t *testing.T) {
	h := newHarness(t)
	conn := h.attach(t)

	dir := t.TempDir()
	path := dir + "/haystack.txt"
	var b strings.Builder
	for i := 0; i < 3000; i++ { // ~149 KiB of matching lines, well over 4x the 32 KiB cap
		b.WriteString("needle in line with padding to make it wide enough\n")
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	conn.SendExec(t, &pb.Exec{
		ReqId:     4,
		Command:   grepCmd("needle", path),
		TimeoutS:  30,
		Streaming: true,
	})

	// Count chunks explicitly rather than using Collect, since the point is the split.
	var chunks int
	var total int
	for {
		f := conn.Next(t)
		if ch := f.GetChunk(); ch != nil && ch.GetReqId() == 4 {
			chunks++
			total += len(ch.GetData())
			if len(ch.GetData()) > wexec.ChunkSize {
				t.Errorf("chunk of %d bytes exceeds cap %d", len(ch.GetData()), wexec.ChunkSize)
			}
			continue
		}
		if e := f.GetEnd(); e != nil && e.GetReqId() == 4 {
			if e.GetExitCode() != 0 {
				t.Errorf("exit code = %d, want 0", e.GetExitCode())
			}
			break
		}
		if e := f.GetError(); e != nil && e.GetReqId() == 4 {
			t.Fatalf("ExecError: %s", e.GetMessage())
		}
	}
	if chunks < 2 {
		t.Errorf("chunks = %d, want >=2 for ~149 KiB of output", chunks)
	}
	if total < 100*1024 {
		t.Errorf("total output = %d bytes, want >=100 KiB", total)
	}
}

// abort mid-stream: kill an emitter after its first chunk and get a signalled End.
func TestContractAbortMidStream(t *testing.T) {
	h := newHarness(t)
	conn := h.attach(t)

	dir := t.TempDir()
	sentinel := dir + "/ticks"
	conn.SendExec(t, &pb.Exec{
		ReqId: 5,
		// Emits forever on stdout AND records ticks on disk, so the test can prove
		// the process group actually died rather than merely stopped being read.
		Command:   "while true; do echo streaming; echo tick >> " + sentinel + "; sleep 0.05; done",
		TimeoutS:  60,
		Streaming: true,
	})

	// Wait for real output before aborting, so this is genuinely mid-stream.
	first := conn.Next(t)
	if ch := first.GetChunk(); ch == nil || ch.GetReqId() != 5 {
		t.Fatalf("first frame = %+v, want a Chunk for req_id 5", first)
	}

	conn.SendAbort(t, 5)
	_, _, terminal := conn.Collect(t, 5)
	if got := terminal.GetEnd(); got == nil || got.GetExitCode() != -1 {
		t.Fatalf("terminal = %+v, want End{exit_code:-1}", terminal)
	}

	// The whole group must be gone: the sentinel stops growing.
	before := countLines(t, sentinel)
	time.Sleep(time.Second)
	if after := countLines(t, sentinel); after != before {
		t.Errorf("sentinel grew %d → %d after abort: the process group survived", before, after)
	}
}

// timeout: the worker kills its own child at timeout_s and reports the exact
// string every other harness transport rejects with (spec §4 D2).
func TestContractTimeout(t *testing.T) {
	h := newHarness(t)
	conn := h.attach(t)

	start := time.Now()
	conn.SendExec(t, &pb.Exec{ReqId: 6, Command: "sleep 30", TimeoutS: 1, Streaming: true})
	_, _, terminal := conn.Collect(t, 6)

	got := terminal.GetError()
	if got == nil {
		t.Fatalf("terminal = %+v, want ExecError", terminal)
	}
	if got.GetMessage() != "timeout:1" {
		t.Errorf("message = %q, want %q", got.GetMessage(), "timeout:1")
	}
	if elapsed := time.Since(start); elapsed > 10*time.Second {
		t.Errorf("took %v: the child was not killed at timeout_s", elapsed)
	}
}

// reconnect → dedup: a redelivered req_id re-emits the cached End, and the marker
// file proves the command did not run twice (spec §8).
func TestContractReconnectDedup(t *testing.T) {
	h := newHarness(t)
	first := h.attach(t)

	dir := t.TempDir()
	marker := dir + "/log"
	cmd := "echo x >> " + marker

	first.SendExec(t, &pb.Exec{ReqId: 7, Command: cmd, TimeoutS: 10, Streaming: true})
	_, _, terminal := first.Collect(t, 7)
	if e := terminal.GetError(); e != nil {
		t.Fatalf("first terminal was ExecError: %s", e.GetMessage())
	}
	if terminal.GetEnd().GetExitCode() != 0 {
		t.Fatalf("first terminal = %+v, want End{0}", terminal)
	}
	if n := countLines(t, marker); n != 1 {
		t.Fatalf("marker has %d lines after one exec, want 1", n)
	}

	// Drop the parked stream; the same Session (and cache) reattaches.
	first.Drop()
	second := h.attach(t)

	second.SendExec(t, &pb.Exec{ReqId: 7, Command: cmd, TimeoutS: 10, Streaming: true})
	_, _, redelivered := second.Collect(t, 7)
	if got := redelivered.GetEnd(); got == nil || got.GetExitCode() != 0 {
		t.Errorf("redelivered terminal = %+v, want the cached End{0}", redelivered)
	}
	// The assertion that matters: same frame is not enough, it must not have re-run.
	if n := countLines(t, marker); n != 1 {
		t.Errorf("marker has %d lines, want 1: the redelivered req_id re-ran the command", n)
	}
}

func countLines(t *testing.T, path string) int {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return strings.Count(string(b), "\n")
}
