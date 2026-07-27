export interface WorkloadRequest {
  name?: string;
  sandboxes?: number;
  workspace?: {
    shared?: boolean;
    size?: string;
    storageClass?: string;
  };
}

export interface WorkloadRecord {
  workloadId: string;
  status: string;
  replicas: number;
  readyReplicas: number;
  sandboxSelector: string;
  workspace: {
    size: string;
    accessMode: string;
    storageClass?: string;
  };
}

interface ContextPool {
  name: string;
  status: string;
  replicas: number;
  readyReplicas: number;
  sandboxSelector: string;
  workspace: WorkloadRecord["workspace"];
}

const baseUrl = () => (process.env.CONTEXT_SERVICE_URL
  ?? "http://context-service.serverless-harness.svc.cluster.local:8080").replace(/\/$/, "");

async function request(path: string, init?: RequestInit): Promise<Response> {
  const response = await fetch(`${baseUrl()}${path}`, init);
  if (response.ok) return response;
  const body = await response.json().catch(() => ({})) as { message?: string };
  throw new Error(body.message ?? `context service returned ${response.status}`);
}

function workload(pool: ContextPool): WorkloadRecord {
  return {
    workloadId: pool.name,
    status: pool.status,
    replicas: pool.replicas,
    readyReplicas: pool.readyReplicas,
    sandboxSelector: pool.sandboxSelector,
    workspace: pool.workspace,
  };
}

export async function createWorkload(workloadId: string, spec: WorkloadRequest): Promise<WorkloadRecord> {
  const shared = spec.workspace?.shared === true;
  const response = await request("/v1/sandbox-pools", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      name: workloadId,
      replicas: spec.sandboxes ?? (shared ? 2 : 1),
      workspace: {
        size: spec.workspace?.size ?? "1Gi",
        accessMode: shared ? "ReadWriteMany" : "ReadWriteOnce",
        ...(spec.workspace?.storageClass ? { storageClass: spec.workspace.storageClass } : {}),
      },
    }),
  });
  return workload(await response.json() as ContextPool);
}

export async function getWorkload(workloadId: string): Promise<WorkloadRecord> {
  const response = await request(`/v1/sandbox-pools/${encodeURIComponent(workloadId)}`);
  return workload(await response.json() as ContextPool);
}

export async function deleteWorkload(workloadId: string): Promise<void> {
  await request(`/v1/sandbox-pools/${encodeURIComponent(workloadId)}`, { method: "DELETE" });
}
