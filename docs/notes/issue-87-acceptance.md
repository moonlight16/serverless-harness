## ST4 acceptance — where each criterion is covered

All tests below live under `remote-worker/` and were re-run for this
write-up: `go test -race ./...` — `EXIT:0`, 46 passed, 2 skipped (both
skips explained below; neither is a failure). Contract tests run over a
real gRPC connection to an in-process fake relay
(`remote-worker/internal/relaytest`) driving a real `bash`, not mocks.

| Criterion | Test |
|---|---|
| round-trips **read** | `TestContractRead` (`internal/session/contract_test.go`) — `cat <file>` |
| round-trips **write** | `TestContractWrite` (`internal/session/contract_test.go`) — `base64 -d > <file>` with stdin, asserts file content on disk |
| round-trips **bash** | `TestContractBash` (`internal/session/contract_test.go`) — stdout/stderr split across streams + `exit 7` |
| round-trips **grep** | `TestContractGrepStreamsMultipleChunks` (`internal/session/contract_test.go`) — ~149 KiB of matches, asserts ≥2 chunks and every chunk ≤ `ChunkSize` |
| **abort mid-stream** | `TestContractAbortMidStream` (`internal/session/contract_test.go`) — aborts after a real chunk arrives; asserts `End{exit_code:-1}` **and** that a sentinel file the child was appending to stops growing (proves the whole process group died, not just that reads stopped) |
| **timeout** (worker SIGKILLs child) | `TestContractTimeout` (`internal/session/contract_test.go`) — `sleep 30` with `timeout_s: 1` → `ExecError{message:"timeout:1"}`, asserts it took under 10s |
| **reconnect → dedup** | `TestContractReconnectDedup` (`internal/session/contract_test.go`) — runs `req_id 7`, drops the stream, reattaches on the same `Session`, resends `req_id 7`; asserts the cached `End{0}` comes back **and** that a marker file the command appends to still has exactly one line (the command did not re-run) |
| static binary, no runtime deps | `remote-worker/Dockerfile`'s build stage: `CGO_ENABLED=0 go build -trimpath -ldflags "-s -w"`. Both runtime images (`Dockerfile`, `Dockerfile.runtime`) were built and run, with `bash`, `base64`, and `file` checked present and `USER 1001` confirmed, when the base image was swapped — a one-time build+run check done for that change, not a repeatable CI gate |
| chunk size capped | `TestChunkCapSplitsLargeOutput` (`internal/exec/runner_test.go`, unit) + `TestContractGrepStreamsMultipleChunks` above (contract-level) |

All nine rows above run in CI with no Redis, node, or pnpm — they are pure
Go and need only a real `bash` on PATH.

Two things intentionally **not** counted as passing evidence yet:

- **`SH_LIVE_RELAY=1` gated interop has never been run in this work.**
  `TestLiveRelayInterop` (`internal/session/live_test.go`) drives read,
  write, and bash through the real TypeScript relay via
  `SandboxExec.Exec` — the one thing the self-authored fake relay cannot
  vouch for. It skips (`t.Skip("SH_LIVE_RELAY!=1: ...")`) unless that env
  var is set, and it was not set for any run in this task. It exists and
  compiles; it has not exercised the real relay. Full interop remains
  ST5 (#88)'s gate.
- **The escaped-process-group unit test skips on this platform.**
  `TestRunReturnsWhenPipeHolderEscapesGroup` (`internal/exec/runner_test.go`)
  covers a pipe holder (e.g. a backgrounded grandchild) that detaches from
  the process group and survives the group's `SIGKILL`; it needs the
  `setsid` binary to simulate that, and skips with `t.Skip("no setsid: ...")`
  when `setsid` is not on PATH — which is the case on macOS, where this
  worker was built and tested. It has run only in principle here; CI
  (`.github/workflows/ci.yml`'s "Build and test remote-worker" step, on
  `ubuntu-latest`, which ships `setsid`) is where it actually executes.
  This is distinct from
  `TestContractAbortMidStream` and `TestContractTimeout` above, both of
  which kill the *whole* process group via `Setpgid` + `Kill(-pid, ...)`
  directly and do run (and pass) on macOS — the escape test is specifically
  about a pipe holder that has *left* that group.

Two behaviors worth flagging as deliberate, both argued in the design doc
(`docs/specs/2026-08-26-st4-go-reference-worker-design.md`):

- **timeout → `ExecError{"timeout:<n>"}`**, not `End{-1}`. All three
  existing harness transports reject with exactly that string
  (`packages/k8s-sandbox/src/exec.ts:79`,
  `packages/k8s-sandbox/src/persistent-exec.ts:129`, and
  `GrpcRelayTransport`'s own deadline path), and the worker's own timer
  normally fires first, so its choice is what the caller sees. `End{-1}`
  would make a timeout resolve as a success with partial output.
- **only completed determinations are cached** — a normal exit and a
  timeout, not an abort (`internal/session/loop.go`'s `runOne`: the
  `cacheable` flag is set for the `err == nil` and `ErrTimeout` branches
  only, not for `ErrAborted`). Caching `End{-1}` for an abort would make
  every later redelivery of that `req_id` answer `-1` forever, even though
  the command never actually ran to completion.

_Assisted-By: Claude (Anthropic AI) <noreply@anthropic.com>_
