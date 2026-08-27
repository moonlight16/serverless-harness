// Command worker is the SandboxTransport reference worker (spec §7). It dials the
// relay's SandboxWorker.Attach stream and runs each Exec it receives in a local
// `bash -c`, streaming stdout and stderr back as Chunks and terminating every exec
// with End or ExecError.
//
// It holds no LLM key and performs no orchestration — it only executes commands and
// returns bytes, which is the property that makes the "central brain" trust model
// correct. See DESIGN.md for how to run it against a cluster.
package main

import (
	"context"
	"crypto/tls"
	"log"
	"math/rand/v2"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"

	pb "github.com/kagenti/serverless-harness/gen/go/sandbox/v1"
	wexec "github.com/kagenti/serverless-harness/remote-worker/internal/exec"
	"github.com/kagenti/serverless-harness/remote-worker/internal/session"
)

const (
	backoffMin = 500 * time.Millisecond
	backoffMax = 30 * time.Second
)

// probed is the fixed list checked against PATH for Hello.capabilities. The pool
// will eventually match on these (relay.ts:74 defers it), so they must be true.
var probed = []string{"bash", "rg", "base64", "file", "python3", "git"}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// envInt falls back to def on anything unparseable or non-positive: a zero pool
// would accept execs and never run them.
func envInt(k string, def int) int {
	v, err := strconv.Atoi(os.Getenv(k))
	if err != nil || v <= 0 {
		return def
	}
	return v
}

func capabilities() []string {
	var out []string
	for _, c := range probed {
		if _, err := exec.LookPath(c); err == nil {
			out = append(out, c)
		}
	}
	return out
}

func nextBackoff(d time.Duration) time.Duration { return min(d*2, backoffMax) }

// jitter spreads reconnects so a relay restart does not get a synchronized herd.
func jitter(d time.Duration) time.Duration {
	return d + time.Duration(rand.Int64N(int64(d/2)+1))
}

func main() {
	relayAddr := env("RELAY_ADDR", "localhost:8443")
	token := env("SANDBOX_TOKEN", "dev-token")
	useTLS := env("RELAY_TLS", "0") == "1"

	cfg := session.Config{
		SandboxID:     env("SANDBOX_ID", "sbx-laptop-1"),
		Image:         env("SANDBOX_IMAGE", ""),
		Trust:         env("SANDBOX_TRUST", "untrusted"),
		Capabilities:  capabilities(),
		MaxConcurrent: envInt("WORKER_MAX_CONCURRENT", session.DefaultConcurrency),
	}

	// Plaintext h2c for an in-cluster ClusterIP or an `oc port-forward` tunnel;
	// TLS for a relay exposed on :443 (spec §9 mode A).
	var creds credentials.TransportCredentials
	if useTLS {
		creds = credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12})
	} else {
		creds = insecure.NewCredentials()
	}

	conn, err := grpc.NewClient(relayAddr, grpc.WithTransportCredentials(creds))
	if err != nil {
		log.Fatalf("dial %s: %v", relayAddr, err)
	}
	defer conn.Close()
	client := pb.NewSandboxWorkerClient(conn)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; log.Println("signal received, shutting down"); cancel() }()

	// One Session across every connection: its dedup cache must survive reconnects,
	// or a redelivered req_id re-runs the command (spec §5).
	sess := session.New(cfg, wexec.BashRunner{})
	log.Printf("worker: relay=%s sandbox_id=%s tls=%v capacity=%d caps=%v",
		relayAddr, cfg.SandboxID, useTLS, cfg.MaxConcurrent, cfg.Capabilities)

	backoff := backoffMin
	for ctx.Err() == nil {
		attachCtx := metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+token)
		stream, err := client.Attach(attachCtx)
		if err == nil {
			backoff = backoffMin
			log.Printf("worker: attached, serving execs")
			err = sess.Serve(attachCtx, stream)
		}
		if ctx.Err() != nil {
			break
		}
		wait := jitter(backoff)
		log.Printf("worker: stream ended (%v); reconnecting in %s", err, wait.Round(time.Millisecond))
		select {
		case <-ctx.Done():
		case <-time.After(wait):
		}
		backoff = nextBackoff(backoff)
	}
	log.Println("worker: stopped")
}
