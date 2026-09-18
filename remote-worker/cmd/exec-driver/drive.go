package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/connectivity"
	"google.golang.org/grpc/credentials/insecure"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
)

// dialReady returns a connection that is already READY.
//
// This is the whole point of the binary (#294): grpcurl opened a fresh TCP connection and
// HTTP/2 session per Exec, and that cost sat inside every measured latency. Bringing the
// connection up BEFORE any slot starts means the first Exec of the rung pays no more than the
// last one does.
func dialReady(ctx context.Context, target string) (*grpc.ClientConn, error) {
	cc, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("creating a client for %s: %w", target, err)
	}
	cc.Connect()
	for {
		s := cc.GetState()
		if s == connectivity.Ready {
			return cc, nil
		}
		if !cc.WaitForStateChange(ctx, s) {
			_ = cc.Close()
			return nil, fmt.Errorf("connection to %s never reached READY (last state %s): refusing to time Execs over a connection that is not up, because every one of them would record a client-side error as a latency: %w", target, s, ctx.Err())
		}
	}
}

// execOutcome is one line of a times file, before it is formatted. errMsg is kept separately
// from cause so the operator gets the original text in the slot's err file while the record
// gets the classified key.
type execOutcome struct {
	ms     int64
	status string
	cause  string
	errMsg string
}

func (o execOutcome) line() string { return fmt.Sprintf("%d %s %s", o.ms, o.status, o.cause) }

// oneExec issues a single Exec and times it host-side, which is what grpc_exec_record does
// with $EPOCHREALTIME either side of its grpcurl call.
//
// The stream is drained to io.EOF rather than stopped at End, because grpcurl drains it:
// returning early would shorten the measured latency for a reason that has nothing to do
// with the change being measured.
//
// An in-stream ExecEvent.error is a FAILED Exec. The relay
// (packages/sandbox-relay/src/relay.ts routeExec) yields that event and then returns a gRPC
// OK status, so grpcurl exits 0 and the bash path records it as ok -- counting a failed Exec
// toward throughput and into the p95 distribution. The null-responder never sends one, so
// being correct here costs the driver-control comparison nothing.
func oneExec(ctx context.Context, client pb.SandboxExecClient, p *plan, s slot, reqID uint64, cmd string) execOutcome {
	callCtx, cancel := context.WithTimeout(ctx, time.Duration(p.CallDeadlineS)*time.Second)
	defer cancel()

	t0 := time.Now()
	fail := func(msg string) execOutcome {
		return execOutcome{ms: time.Since(t0).Milliseconds(), status: "err", cause: causeFor(msg), errMsg: msg}
	}

	stream, err := client.Exec(callCtx, &pb.ExecRequest{
		SandboxId: p.SandboxID,
		Exec: &pb.Exec{
			ReqId:        reqID,
			Command:      cmd,
			TimeoutS:     p.ExecTimeoutS,
			WorkspaceKey: s.WorkspaceKey,
		},
	})
	if err != nil {
		return fail(err.Error())
	}

	var inStream string
	for {
		ev, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fail(err.Error())
		}
		if e := ev.GetError(); e != nil && inStream == "" {
			inStream = e.GetMessage()
		}
	}
	ms := time.Since(t0).Milliseconds()
	if inStream != "" {
		return execOutcome{ms: ms, status: "err", cause: causeFor(inStream), errMsg: inStream}
	}
	return execOutcome{ms: ms, status: "ok", cause: "-"}
}

// runSlot is one slot's whole timed loop: the goroutine that replaces one bash subshell.
//
// Writes are BUFFERED and flushed once at the end. The alternative -- a write syscall per
// Exec -- is driver cost inside the measured window, which is the thing being removed. A rung
// killed mid-flight loses its tail, and that is fine: run_density_rung refuses a rung whose
// child exited non-zero rather than recording a partial one.
func runSlot(ctx context.Context, client pb.SandboxExecClient, p *plan, s slot) error {
	times, err := os.OpenFile(s.TimesFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("opening times file %s: %w", s.TimesFile, err)
	}
	defer func() { _ = times.Close() }()
	errFile, err := os.OpenFile(s.ErrFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return fmt.Errorf("opening err file %s: %w", s.ErrFile, err)
	}
	defer func() { _ = errFile.Close() }()

	w := bufio.NewWriter(times)
	calls := p.callsPerSlot()
	for i := 0; i < calls; i++ {
		// reqBase itself is converge's, so Execs start one past it -- the same arithmetic
		// run_density_rung does with `req=$req_base` then `req=$((req + 1))` before each call.
		o := oneExec(ctx, client, p, s, s.ReqBase+1+uint64(i), p.Mix[i%len(p.Mix)])
		if _, err := fmt.Fprintln(w, o.line()); err != nil {
			return fmt.Errorf("writing to times file %s: %w", s.TimesFile, err)
		}
		if o.errMsg != "" {
			// Best effort: losing the diagnostic text must not fail a rung whose timings are fine.
			_, _ = fmt.Fprintf(errFile, "req %d: %s\n", s.ReqBase+1+uint64(i), o.errMsg)
		}
	}
	if err := w.Flush(); err != nil {
		return fmt.Errorf("flushing times file %s: %w", s.TimesFile, err)
	}
	return nil
}

// drive runs one whole rung: one connection, one goroutine per slot.
//
// ONE ClientConn for every slot is the change #294 asks for. Its known bound is not a
// concurrent-stream cap -- neither server caps streams by default on the pinned versions --
// but that a single connection has one loopyWriter goroutine and one connection-level
// flow-control window, so all c slots' framing serializes through one writer. Nothing has
// measured that binding; if the Go client's throughput plateaus while coresBusy stays low,
// sharding slots across N connections is the first thing to try.
func drive(ctx context.Context, p *plan) error {
	cc, err := dialReady(ctx, p.Target)
	if err != nil {
		return err
	}
	defer func() { _ = cc.Close() }()
	client := pb.NewSandboxExecClient(cc)

	errs := make([]error, len(p.Slots))
	var wg sync.WaitGroup
	for i, s := range p.Slots {
		wg.Add(1)
		// Go 1.22+ gives each iteration its own i and s, so the closure captures this slot.
		go func() {
			defer wg.Done()
			errs[i] = runSlot(ctx, client, p, s)
		}()
	}
	wg.Wait()

	for i, e := range errs {
		if e != nil {
			return fmt.Errorf("slot %d (reqBase %d): %w", i+1, p.Slots[i].ReqBase, e)
		}
	}
	return nil
}
