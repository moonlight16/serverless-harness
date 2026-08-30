import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { createRelay } from "../src/relay.js";
import type { RecordStore } from "@sh/harness";

const records: RecordStore = { put: async () => {}, remove: async () => {}, list: async () => [] };

function fakeAttach() {
  const s = new EventEmitter() as EventEmitter & { metadata: { get: () => string[] }; write: (f: any) => void; end: () => void; written: any[]; emitData: (f: any) => void };
  s.metadata = { get: () => [] };
  s.written = [];
  s.write = (f) => s.written.push(f);
  s.end = () => s.emit("end");
  s.emitData = (f) => s.emit("data", f);
  return s;
}

describe("relay Exec/Abort routing", () => {
  it("routes Exec to the worker and yields the worker's ExecEvents back", async () => {
    const relay = createRelay({ records, validateToken: () => true } as never);
    const s = fakeAttach();
    relay.onAttach(s as never);
    s.emitData({ hello: { sandboxId: "sbx-1", labels: {}, capabilities: [], image: "", arch: "amd64", capacityMax: 1, trust: "trusted" } });

    const events: any[] = [];
    const pump = (async () => {
      for await (const ev of relay.routeExec("sbx-1", 1, "echo hi", new Uint8Array(), 0, true)) events.push(ev);
    })();

    // The relay should have sent a ServerFrame{exec} to the worker.
    await vi.waitFor(() => expect(s.written.at(-1)?.exec?.reqId).toBe(1));
    // Worker replies with a chunk then end.
    s.emitData({ chunk: { reqId: 1, data: Buffer.from("hi"), stream: 1 } });
    s.emitData({ end: { reqId: 1, exitCode: 0 } });
    await pump;
    expect(events.map((e) => e.chunk?.data && Buffer.from(e.chunk.data).toString()).filter(Boolean)).toContain("hi");
    expect(events.at(-1).end.exitCode).toBe(0);
  });

  it("Abort sends ServerFrame{abort} to the worker", async () => {
    const relay = createRelay({ records, validateToken: () => true } as never);
    const s = fakeAttach();
    relay.onAttach(s as never);
    s.emitData({ hello: { sandboxId: "sbx-1", labels: {}, capabilities: [], image: "", arch: "amd64", capacityMax: 1, trust: "trusted" } });
    relay.routeAbort("sbx-1", 5);
    expect(s.written.at(-1)?.abort?.reqId).toBe(5);
  });

  it("Exec for an absent sandboxId throws", async () => {
    const relay = createRelay({ records, validateToken: () => true } as never);
    await expect(async () => {
      for await (const _ of relay.routeExec("ghost", 1, "x", new Uint8Array(), 0, true)) void _;
    }).rejects.toThrow(/no live worker/);
  });

  it("worker disconnect mid-exec fails the in-flight routeExec generator fast", async () => {
    const relay = createRelay({ records, validateToken: () => true } as never);
    const s = fakeAttach();
    relay.onAttach(s as never);
    s.emitData({ hello: { sandboxId: "sbx-1", labels: {}, capabilities: [], image: "", arch: "amd64", capacityMax: 1, trust: "trusted" } });

    const events: any[] = [];
    let finished = false;
    const pump = (async () => {
      for await (const ev of relay.routeExec("sbx-1", 1, "sleep 100", new Uint8Array(), 0, true)) events.push(ev);
      finished = true;
    })();

    // Wait until routeExec has registered its sink and written the ServerFrame{exec}
    // to the worker -- i.e. the exec is genuinely in-flight and parked awaiting frames.
    await vi.waitFor(() => expect(s.written.at(-1)?.exec?.reqId).toBe(1));

    // Worker disconnects (stream "end") before ever sending a chunk/end/error frame.
    s.end();

    // Without the fix, nothing ever notifies the parked generator's internal
    // await, so this would hang until the test's own timeout.
    await vi.waitFor(() => expect(finished).toBe(true));

    expect(events.at(-1)?.error?.message).toBe("worker disconnected");
    // The sink must have been cleaned up (routeExec's finally ran) -- no leak.
    expect(relay.parked()).not.toContain("sbx-1");
  });

  it("refuses a second in-flight exec with the same req_id instead of overwriting the first", async () => {
    // Sinks are keyed by req_id per parked session, so an overwrite silently detaches
    // the first caller (it then hangs to its own deadline) and hands its frames to the
    // second. Failing loudly is strictly better than cross-talk (#179).
    const relay = createRelay({ records, validateToken: () => true } as never);
    const s = fakeAttach();
    relay.onAttach(s as never);
    s.emitData({ hello: { sandboxId: "sbx-1", labels: {}, capabilities: [], image: "", arch: "amd64", capacityMax: 1, trust: "trusted" } });

    const events: any[] = [];
    const pump = (async () => {
      for await (const ev of relay.routeExec("sbx-1", 7, "sleep 5", new Uint8Array(), 0, true)) events.push(ev);
    })();

    // Wait until the first exec's sink is registered and its ServerFrame{exec} written,
    // i.e. it is genuinely in-flight, before the duplicate arrives.
    await vi.waitFor(() => expect(s.written.at(-1)?.exec?.reqId).toBe(7));

    await expect(
      (async () => {
        for await (const _ of relay.routeExec("sbx-1", 7, "echo hi", new Uint8Array(), 0, true)) void _;
      })(),
    ).rejects.toThrow(/req_id 7 already in flight/);

    // Clean up the first generator so the test doesn't leak a pending pump.
    s.emitData({ end: { reqId: 7, exitCode: 0 } });
    await pump;
  });
});
