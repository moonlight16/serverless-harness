import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { records, runLeaf, createWorkload, getWorkload, deleteWorkload } = vi.hoisted(() => ({
  records: new Map<string, string>(),
  runLeaf: vi.fn(),
  createWorkload: vi.fn(),
  getWorkload: vi.fn(),
  deleteWorkload: vi.fn(),
}));
vi.mock("@sh/harness/leaf-result-store", async (orig) => {
  const actual = await orig<typeof import("@sh/harness/leaf-result-store")>();
  class FakeStore {
    async set(key: string, value: string) { records.set(key, value); }
    async get(key: string) { return records.get(key) ?? null; }
  }
  return { ...actual, RedisResultStore: FakeStore };
});

vi.mock("@sh/harness/run-leaf", () => ({
  runLeaf: (...args: any[]) => runLeaf(...args),
  validateItem: (item: any) => item,
  leafSessionId: (env: any) => env.sessionId,
}));

vi.mock("../src/context-service.js", () => ({ createWorkload, getWorkload, deleteWorkload }));

import { startServer } from "../src/server.js";

const record = {
  workloadId: "demo-workload",
  status: "ready",
  replicas: 2,
  readyReplicas: 2,
  sandboxSelector: "context.rossoctl.io/pool=demo-workload",
  workspace: { size: "1Gi", accessMode: "ReadWriteMany", storageClass: "ibm-scale-csi" },
};

let server: ReturnType<typeof startServer>;
let base: string;

beforeEach(() => {
  records.clear();
  runLeaf.mockReset();
  createWorkload.mockReset().mockResolvedValue(record);
  getWorkload.mockReset().mockResolvedValue(record);
  deleteWorkload.mockReset().mockResolvedValue(undefined);
  server = startServer(0);
  base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});

afterEach(() => server.close());

async function json(method: string, path: string, body?: unknown) {
  const response = await fetch(base + path, {
    method,
    headers: { "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { status: response.status, body: await response.json().catch(() => null) };
}

describe("workload lifecycle", () => {
  it("creates a workload through Context Service", async () => {
    const response = await json("POST", "/workloads", {
      name: "demo-workload", sandboxes: 2,
      workspace: { shared: true, storageClass: "ibm-scale-csi" },
    });
    expect(response).toEqual({ status: 201, body: record });
    expect(createWorkload).toHaveBeenCalledWith("demo-workload", expect.objectContaining({ sandboxes: 2 }));
  });

  it("routes a run through its workload pool", async () => {
    await json("POST", "/workloads", { name: "demo-workload" });
    runLeaf.mockResolvedValue({ status: "done", verdict: { item_id: "i", verdict: "CLEAR", reason: "ok" } });
    const response = await json("POST", "/runs", {
      workloadId: "demo-workload",
      sessionId: "run/i",
      item: { item_id: "i", file: "f", pattern: "p" },
    });
    expect(response.status).toBe(200);
    expect(runLeaf).toHaveBeenCalledWith(
      expect.objectContaining({
        workloadId: "demo-workload",
        sandboxPoolSelector: "context.rossoctl.io/pool=demo-workload",
      }),
      expect.any(Object),
    );
  });

  it("deletes the workload through Context Service", async () => {
    await json("POST", "/workloads", { name: "demo-workload" });
    const response = await fetch(base + "/workloads/demo-workload", { method: "DELETE" });
    expect(response.status).toBe(204);
    expect(deleteWorkload).toHaveBeenCalledWith("demo-workload");
  });

  it("rejects a run for an unknown workload", async () => {
    const response = await json("POST", "/runs", {
      workloadId: "missing",
      sessionId: "run/i",
      item: { item_id: "i", file: "f", pattern: "p" },
    });
    expect(response).toEqual({ status: 404, body: { error: "workload_not_found" } });
    expect(runLeaf).not.toHaveBeenCalled();
  });
});
