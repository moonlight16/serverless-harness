import { EventEmitter } from "node:events";
import { vi } from "vitest";
import type { K8sSandboxConfig } from "../src/config.js";
import { KubectlTransport } from "../src/exec.js";
import { runConformance, type TransportFactory } from "./conformance.js";

type SpawnFn = typeof import("node:child_process").spawn;

const cfg: K8sSandboxConfig = {
  pod: "sbx-0",
  namespace: "team1",
  context: undefined,
  podCwd: "/workspace",
  headCwd: "/head",
};

/** Build a KubectlTransport whose child process is a scripted fake. */
const kubectlFactory: TransportFactory = (b, opts) => {
  let stdin: Buffer | undefined;
  // The producer here is the `kubectl exec` child; "stopped" means the transport
  // signalled it. The fake emits `close` on its own, so nothing else in the run
  // reveals whether the kill actually happened — this flag is the only witness.
  let killed = false;
  const spawn = ((_cmd: string, _args: string[]) => {
    const child = new EventEmitter() as any;
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.stdin = { end: (d?: Buffer) => { stdin = d; } };
    // kill() drives a `close` event, exactly as a real SIGKILL would.
    child.kill = vi.fn(() => {
      killed = true;
      child.emit("close", null);
    });
    // Emit after the transport has attached its handlers (still synchronous
    // relative to the awaiting test via a microtask).
    queueMicrotask(() => {
      for (const s of b.stdout ?? []) child.stdout.emit("data", Buffer.from(s));
      for (const s of b.stderr ?? []) child.stderr.emit("data", Buffer.from(s));
      if (!b.hang) child.emit("close", b.exitCode ?? 0);
    });
    return child;
  }) as unknown as SpawnFn;
  const transport = KubectlTransport(cfg, { spawn, outputCapBytes: opts?.outputCapBytes });
  return { transport, stdinSeen: () => stdin, producerStopped: () => killed };
};

runConformance("KubectlTransport", kubectlFactory);
