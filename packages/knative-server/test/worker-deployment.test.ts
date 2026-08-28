import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { parse, parseAllDocuments } from "yaml";

type EnvVar = { name: string; value?: string };

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const DEPLOY = resolve(REPO_ROOT, "deploy/knative");
const WORKER = resolve(REPO_ROOT, "remote-worker");

const example = () => parse(readFileSync(resolve(DEPLOY, "worker-example.yaml"), "utf8"));
const template = () => parse(readFileSync(resolve(WORKER, "worker-deployment.yaml"), "utf8"));
const envOf = (dep: any): EnvVar[] => dep.spec.template.spec.containers[0].env;
const get = (dep: any, name: string) => envOf(dep).find((e) => e.name === name)?.value;

describe("worker-example.yaml (the third-party copy-and-edit surface)", () => {
  it("is a single-replica Deployment with matching selector and labels", () => {
    const dep = example();
    expect(dep.kind).toBe("Deployment");
    // One worker per SANDBOX_ID: the relay rejects a second live Attach for the same id,
    // so replicas > 1 would leave every extra pod crash-looping on a rejected Attach.
    expect(dep.spec.replicas).toBe(1);
    expect(dep.spec.selector.matchLabels.app).toBe(dep.spec.template.metadata.labels.app);
  });

  it("carries the three env vars a worker cannot start without", () => {
    const dep = example();
    for (const k of ["SANDBOX_ID", "RELAY_ADDR", "SANDBOX_TOKEN"]) {
      expect(get(dep, k), `${k} is read at startup by remote-worker/cmd/worker/main.go`).toBeTruthy();
    }
  });

  it("points RELAY_ADDR at the port the relay Service actually publishes", () => {
    // A drifted port here is the failure mode with the worst diagnostics: the worker
    // dials, gets connection-refused, backs off, and never appears in presence.
    const relayDocs = parseAllDocuments(readFileSync(resolve(DEPLOY, "relay-deployment.yaml"), "utf8")).map((d) => d.toJS());
    const svc = relayDocs.find((o) => o.kind === "Service");
    const port = svc.spec.ports[0].port;
    expect(get(example(), "RELAY_ADDR")).toContain(`:${port}`);
  });

  it("is restricted-v2 compatible: non-root, no privilege escalation, all caps dropped", () => {
    const sc = example().spec.template.spec.containers[0].securityContext;
    expect(sc.runAsNonRoot).toBe(true);
    expect(sc.allowPrivilegeEscalation).toBe(false);
    expect(sc.capabilities.drop).toContain("ALL");
    // OpenShift assigns a UID from the namespace range; a hardcoded one breaks the
    // copy-and-edit path for anyone whose image does not use that exact UID.
    expect(sc.runAsUser, "worker-example.yaml must not pin runAsUser").toBeUndefined();
  });
});

describe("remote-worker/worker-deployment.yaml (the sed-filled gate template)", () => {
  it("keeps every placeholder deploy-incluster.sh substitutes", () => {
    const raw = readFileSync(resolve(WORKER, "worker-deployment.yaml"), "utf8");
    // deploy-incluster.sh seds these by exact string; a rename here fails silently and
    // ships a pod with a literal __IMAGE__ reference.
    for (const p of ["__NS__", "__IMAGE__", "__SANDBOX_ID__", "__TOKEN__"]) {
      expect(raw, `${p} is substituted by remote-worker/deploy-incluster.sh`).toContain(p);
    }
  });

  it("sets a memory limit that covers the worker's worst-case buffering", () => {
    // runner.go's BufferCap is a PER-STREAM cap on non-streaming execs, and
    // Exec.streaming=false is the proto3 default (relay-supplied), so a buggy relay
    // reaches the worst case with no privilege. Both files carry this arithmetic in a
    // comment and say "change either side and change the other" — this is the check
    // that makes that true (#173 item 7).
    const runnerGo = readFileSync(resolve(WORKER, "internal/exec/runner.go"), "utf8");
    const loopGo = readFileSync(resolve(WORKER, "internal/session/loop.go"), "utf8");
    const bufferCapMatch = /BufferCap = (\d+) \* 1024 \* 1024/.exec(runnerGo);
    const concurrencyMatch = /DefaultConcurrency = (\d+)/.exec(loopGo);
    if (!bufferCapMatch) throw new Error("could not find `BufferCap = N * 1024 * 1024` in runner.go — constant reformatted?");
    if (!concurrencyMatch) throw new Error("could not find `DefaultConcurrency = N` in loop.go — constant reformatted?");
    const bufferCapMiB = Number(bufferCapMatch[1]);
    const concurrency = Number(concurrencyMatch[1]);
    const worstCaseMiB = 2 * concurrency * bufferCapMiB; // stdout + stderr per exec

    const limit = template().spec.template.spec.containers[0].resources.limits.memory;
    const limitMatch = /^(\d+)Mi$/.exec(limit);
    if (!limitMatch) throw new Error(`resources.limits.memory "${limit}" is not in the expected "<N>Mi" form`);
    const limitMiB = Number(limitMatch[1]);
    expect(
      limitMiB,
      `limit ${limit} must cover 2 x ${concurrency} x ${bufferCapMiB}MiB = ${worstCaseMiB}MiB of buffering; a smaller limit is an OOMKill the relay can trigger at will`,
    ).toBeGreaterThanOrEqual(worstCaseMiB);
  });

  it("does not raise WORKER_MAX_CONCURRENT above what the memory limit funds", () => {
    // The template does not set it today; if someone adds it, the arithmetic above
    // silently stops holding, because the Go default is no longer what runs.
    const override = get(template(), "WORKER_MAX_CONCURRENT");
    if (override === undefined) return;
    const runnerGo = readFileSync(resolve(WORKER, "internal/exec/runner.go"), "utf8");
    const bufferCapMatch = /BufferCap = (\d+) \* 1024 \* 1024/.exec(runnerGo);
    if (!bufferCapMatch) throw new Error("could not find `BufferCap = N * 1024 * 1024` in runner.go — constant reformatted?");
    const bufferCapMiB = Number(bufferCapMatch[1]);
    const limit = template().spec.template.spec.containers[0].resources.limits.memory;
    const limitMatch = /^(\d+)Mi$/.exec(limit);
    if (!limitMatch) throw new Error(`resources.limits.memory "${limit}" is not in the expected "<N>Mi" form`);
    const limitMiB = Number(limitMatch[1]);
    expect(2 * Number(override) * bufferCapMiB).toBeLessThanOrEqual(limitMiB);
  });
});
