import { DEFAULT_OUTPUT_CAP, OUTPUT_TRUNCATED_MARKER, type SandboxTransport } from "./transport.js";
import { makeReqIdSource } from "./req-id.js";
import {
  Stream,
  type AbortRequest,
  type ExecEvent,
  type ExecRequest,
} from "./gen/sandbox/v1/sandbox.js";

/** Minimal surface of the generated SandboxExecClient the transport needs. */
export interface ExecClientLike {
  exec(request: ExecRequest): {
    on(event: "data", cb: (ev: ExecEvent) => void): unknown;
    on(event: "end", cb: () => void): unknown;
    on(event: "error", cb: (err: Error) => void): unknown;
    cancel(): void;
  };
  abort(request: AbortRequest, cb: (err: Error | null) => void): unknown;
  /** Closes the underlying gRPC channel. Optional: scripted test fakes omit it. */
  close?(): void;
}

/**
 * One source per process, so every transport instance in this replica draws from the
 * same salted space. Injectable via opts.reqIdSource for tests.
 */
const defaultReqIdSource = makeReqIdSource();

const DEFAULT_DEADLINE_MS = 120_000;

export function GrpcRelayTransport(
  sandboxId: string,
  client: ExecClientLike,
  opts: { deadlineMs?: number; outputCapBytes?: number; reqIdSource?: () => number } = {},
): SandboxTransport {
  const deadlineMs = opts.deadlineMs ?? DEFAULT_DEADLINE_MS;
  const outputCap = opts.outputCapBytes ?? DEFAULT_OUTPUT_CAP;
  const nextReqId = opts.reqIdSource ?? defaultReqIdSource;
  let closed = false;

  const exec: SandboxTransport["exec"] = (command, execOpts = {}) =>
    new Promise((resolve, reject) => {
      const reqId = nextReqId();
      const call = client.exec({
        sandboxId,
        exec: {
          reqId,
          command,
          stdin: execOpts.stdin ? new Uint8Array(execOpts.stdin) : new Uint8Array(),
          timeoutS: execOpts.timeout ?? 0,
          streaming: true,
        },
      });

      const stdout: Buffer[] = [];
      let bytes = 0;
      let settled = false;
      let truncated = false;

      const finish = (fn: () => void) => {
        if (settled) return; // dedup: drop late frames for a settled reqId
        settled = true;
        clearTimeout(timer);
        if (execOpts.signal) execOpts.signal.removeEventListener("abort", onAbort);
        fn();
      };

      const timer = setTimeout(() => {
        call.cancel();
        client.abort({ sandboxId, reqId }, () => {});
        finish(() => reject(new Error(`timeout:${execOpts.timeout ?? Math.round(deadlineMs / 1000)}`)));
      }, execOpts.timeout ? execOpts.timeout * 1000 : deadlineMs);

      const onAbort = () => {
        call.cancel();
        client.abort({ sandboxId, reqId }, () => {});
        finish(() => reject(new Error("aborted")));
      };
      if (execOpts.signal) {
        if (execOpts.signal.aborted) return onAbort();
        execOpts.signal.addEventListener("abort", onAbort);
      }

      call.on("data", (ev: ExecEvent) => {
        if (settled) return;
        if (ev.chunk) {
          const data = Buffer.from(ev.chunk.data);
          execOpts.onData?.(data);
          if (ev.chunk.stream !== Stream.STREAM_STDERR) {
            if (!truncated) {
              stdout.push(data);
              bytes += data.length;
              if (bytes > outputCap) {
                truncated = true;
                stdout.push(Buffer.from(OUTPUT_TRUNCATED_MARKER));
                call.cancel();
                client.abort({ sandboxId, reqId }, () => {});
                finish(() => resolve({ stdout: Buffer.concat(stdout), exitCode: null }));
              }
            }
          }
        } else if (ev.end) {
          const code = ev.end.exitCode < 0 ? null : ev.end.exitCode;
          finish(() => resolve({ stdout: Buffer.concat(stdout), exitCode: code }));
        } else if (ev.error) {
          finish(() => reject(new Error(ev.error!.message)));
        }
      });
      call.on("error", (err: Error) => finish(() => reject(err)));
      call.on("end", () => finish(() => resolve({ stdout: Buffer.concat(stdout), exitCode: null })));
    });

  return {
    exec,
    async close() {
      if (closed) return; // idempotent; per-exec calls own their own stream lifecycle
      closed = true;
      client.close?.(); // safe no-op for scripted fakes that don't implement close()
    },
  };
}
