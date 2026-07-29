import { afterEach, describe, expect, it, vi } from "vitest";

import { createWorkload } from "../src/context-service.js";

afterEach(() => vi.unstubAllGlobals());

describe("Context Service workload requests", () => {
  it("passes an existing read-only claim without managed-workspace fields", async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      name: "readers", status: "provisioning", replicas: 4, readyReplicas: 0,
      sandboxSelector: "context.rossoctl.io/pool=readers",
      workspace: { claimName: "mosaic", readOnly: true, size: "5Gi", accessMode: "ReadWriteMany" },
    }), { status: 201 }));
    vi.stubGlobal("fetch", fetch);

    await createWorkload("readers", {
      sandboxes: 4,
      workspace: { claimName: "mosaic", readOnly: true },
    });

    const init = fetch.mock.calls[0][1] as RequestInit;
    expect(JSON.parse(String(init.body))).toEqual({
      name: "readers",
      replicas: 4,
      workspace: { claimName: "mosaic", readOnly: true },
    });
  });

  it("passes an existing read-write claim explicitly", async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      name: "writer", status: "provisioning", replicas: 1, readyReplicas: 0,
      sandboxSelector: "context.rossoctl.io/pool=writer",
      workspace: { claimName: "mosaic", readOnly: false, size: "5Gi", accessMode: "ReadWriteMany" },
    }), { status: 201 }));
    vi.stubGlobal("fetch", fetch);

    await createWorkload("writer", {
      workspace: { claimName: "mosaic", readOnly: false },
    });

    const init = fetch.mock.calls[0][1] as RequestInit;
    expect(JSON.parse(String(init.body)).workspace).toEqual({ claimName: "mosaic", readOnly: false });
  });
});
