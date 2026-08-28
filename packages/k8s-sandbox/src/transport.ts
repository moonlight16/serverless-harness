/**
 * The exec seam Pi sees (spec §3). Everything above `select-sandbox`
 * (`run-leaf`, `run-turn`, `converge`) depends only on `SandboxTransport` and
 * never learns how bytes reach the sandbox. Implementations: `KubectlTransport`
 * (per-call kubectl exec), `GrpcRelayTransport` (added in ST3), and
 * `persistentExecInPod` (one long-lived channel, serving the file tools).
 */

/**
 * One command run in the sandbox (`bash -c <command>`). stdout is collected and
 * returned; stderr is streamed to `onData` (with stdout) but NOT included in the
 * returned `stdout`, so file ops get clean bytes. `stdin` feeds data (e.g. base64
 * for writes); `onData` streams output for bash; `signal` aborts; `timeout` is seconds.
 */
export type ExecInPod = (
  command: string,
  opts?: {
    stdin?: Buffer;
    onData?: (chunk: Buffer) => void;
    signal?: AbortSignal;
    timeout?: number; // seconds
  },
) => Promise<{ stdout: Buffer; exitCode: number | null }>;

/** A transport-blind exec channel to one sandbox (spec §3). */
export interface SandboxTransport {
  exec: ExecInPod;
  /** Release any long-lived resource (persistent channel, connection). Idempotent. */
  close(): Promise<void>;
}

/**
 * Total returned-stdout cap per exec (spec §8, "poisoned-output defense"). Enforced by
 * both PER-CALL transports — `KubectlTransport` and `GrpcRelayTransport` — each of which
 * also stops the producer (SIGKILL / `Abort`); test/conformance.ts holds both to that.
 *
 * NOT yet a property of the whole seam: `persistentExecInPod` is uncapped, and
 * extension.ts gives it Read/Write/Edit/Ls/Find, so Pi can still tell the backends apart
 * on output volume. Capping the Read path is a production behaviour change, tracked
 * separately (spec §8, "Accepted divergences"). The damaging consequence is closed:
 * `createPodReadOps.readFile` throws on a truncated read rather than let Pi's Edit tool
 * write the truncation back over the file.
 *
 * The Go worker's BufferCap (remote-worker/internal/exec/runner.go) is pinned to this
 * value — change one and change the other; test/output-cap-coupling.test.ts enforces it.
 */
export const DEFAULT_OUTPUT_CAP = 8 * 1024 * 1024; // 8 MiB

/** Appended to returned stdout when the cap trips, so Pi sees the truncation. */
export const OUTPUT_TRUNCATED_MARKER = "\n[output truncated]";
