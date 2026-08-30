import { spawn as nodeSpawn } from "node:child_process";
import type { K8sSandboxConfig } from "./config.js";
import type { ExecInPod, SandboxTransport } from "./transport.js";
import { DEFAULT_OUTPUT_CAP, OUTPUT_TRUNCATED_MARKER } from "./transport.js";

// Re-export so existing `./exec.js` importers of ExecInPod keep working.
export type { ExecInPod } from "./transport.js";

type SpawnFn = typeof nodeSpawn;

/** Pure argv builder for `kubectl exec` (unit-tested). */
export function buildKubectlArgs(config: K8sSandboxConfig, command: string): string[] {
  const args = ["exec", "-i", "-n", config.namespace];
  if (config.context) args.push("--context", config.context);
  args.push(config.pod, "--", "bash", "-c", command);
  return args;
}

/** True only when exec timing is explicitly enabled (off by default). */
export function shouldEmitExecTiming(env: NodeJS.ProcessEnv): boolean {
  return env.KAGENTI_EXEC_TIMING === "1";
}

/** One stable, newline-terminated timing line for a single exec. */
export function formatExecTiming(pod: string, ms: number, command: string): string {
  const cmd = command.slice(0, 60).replace(/\s+/g, " ");
  return `[exec-timing] pod=${pod} ms=${ms} cmd=${cmd}\n`;
}

/**
 * Default transport: each `exec()` shells out to a fresh `kubectl exec`. There is
 * no long-lived resource, so `close()` is a no-op. `deps.spawn` is injectable for
 * tests (defaults to node's spawn); real callers pass only `config`.
 */
export function KubectlTransport(
  config: K8sSandboxConfig,
  deps: { spawn?: SpawnFn; outputCapBytes?: number } = {},
): SandboxTransport {
  const spawnFn = deps.spawn ?? nodeSpawn;
  const outputCap = deps.outputCapBytes ?? DEFAULT_OUTPUT_CAP;
  const exec: ExecInPod = (command, opts = {}) =>
    new Promise((resolve, reject) => {
      const child = spawnFn("kubectl", buildKubectlArgs(config, command), {
        stdio: ["pipe", "pipe", "pipe"],
      });
      const startMs = Date.now();
      const out: Buffer[] = [];
      let timedOut = false;
      let settled = false;
      const timer =
        opts.timeout && opts.timeout > 0
          ? setTimeout(() => {
              timedOut = true;
              child.kill("SIGKILL");
            }, opts.timeout * 1000)
          : undefined;

      let bytes = 0;
      let truncated = false;
      child.stdout.on("data", (d: Buffer) => {
        opts.onData?.(d); // streaming is uncapped; the cap is on what Pi gets back
        if (truncated) return;
        out.push(d);
        bytes += d.length;
        if (bytes > outputCap) {
          truncated = true;
          out.push(Buffer.from(OUTPUT_TRUNCATED_MARKER));
          // Not parity with the gRPC Abort: that kills the *remote* worker process.
          // This only kills the local kubectl client; the in-pod process is stopped
          // (if at all) by EPIPE on its next write to the now-closed stream — fine for
          // cat/grep, but a hostile producer that traps or ignores SIGPIPE keeps
          // running in the pod after this returns (spec §8 "Accepted divergences").
          child.kill("SIGKILL");
        }
      });
      child.stderr.on("data", (d: Buffer) => {
        opts.onData?.(d);
      });

      const onAbort = () => child.kill("SIGKILL");
      opts.signal?.addEventListener("abort", onAbort, { once: true });

      child.on("error", (e) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        reject(e);
      });
      child.on("close", (code) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        opts.signal?.removeEventListener("abort", onAbort);
        if (opts.signal?.aborted) return reject(new Error("aborted"));
        if (truncated) return resolve({ stdout: Buffer.concat(out), exitCode: null });
        if (timedOut) return reject(new Error(`timeout:${opts.timeout}`));
        if (shouldEmitExecTiming(process.env)) {
          process.stderr.write(formatExecTiming(config.pod, Date.now() - startMs, command));
        }
        resolve({ stdout: Buffer.concat(out), exitCode: code });
      });

      if (opts.stdin) child.stdin.end(opts.stdin);
      else child.stdin.end();
    });
  return { exec, close: async () => {} };
}
