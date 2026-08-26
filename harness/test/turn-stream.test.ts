import { describe, it, expect } from "vitest";
import { sseExtension, clip, terminalFrame, type TurnStreamFrame } from "../src/turn-stream.js";
import type { TurnResult } from "../src/run-turn.js";

// A fake Pi that captures the handler registered per event NAME, plus emit() to fire one.
// sseExtension registers multiple handlers (message_update / tool_execution_start /
// tool_execution_end), so — unlike a single-handler extension fake — we key by event name.
function makePi() {
  const handlers = new Map<string, (e: any) => void>();
  const pi = {
    on: (event: string, h: (e: any) => void) => {
      handlers.set(event, h);
    },
  };
  return {
    pi,
    emit(event: string, e: any) {
      const h = handlers.get(event);
      if (!h) throw new Error(`no handler registered for ${event}`);
      h(e);
    },
  };
}

// Apply sseExtension against a captured sink; return the emitter and the frames it produced.
function drive(opts?: { previewBytes?: number }) {
  const frames: TurnStreamFrame[] = [];
  const { pi, emit } = makePi();
  sseExtension((f) => frames.push(f), opts)(pi as any);
  return { emit, frames };
}

describe("sseExtension frame translation", () => {
  it("translates text_delta / thinking_delta / tool start+end into the frame sequence", () => {
    const { emit, frames } = drive();
    emit("message_update", { assistantMessageEvent: { type: "text_delta", delta: "Hel" } });
    emit("message_update", { assistantMessageEvent: { type: "thinking_delta", delta: "hmm" } });
    emit("tool_execution_start", { toolCallId: "t1", toolName: "bash", args: { cmd: "ls" } });
    emit("tool_execution_end", { toolCallId: "t1", toolName: "bash", result: "file.txt", isError: false });
    expect(frames).toEqual([
      { type: "text", delta: "Hel" },
      { type: "thinking", delta: "hmm" },
      { type: "tool_use", id: "t1", name: "bash", args: { cmd: "ls" } },
      { type: "tool_result", id: "t1", isError: false, preview: "file.txt" },
    ]);
  });

  it("drops empty deltas (no frame for delta === '')", () => {
    const { emit, frames } = drive();
    emit("message_update", { assistantMessageEvent: { type: "text_delta", delta: "" } });
    emit("message_update", { assistantMessageEvent: { type: "thinking_delta", delta: "" } });
    expect(frames).toEqual([]);
  });

  it("propagates isError verbatim on tool_result", () => {
    const { emit, frames } = drive();
    emit("tool_execution_end", { toolCallId: "t2", toolName: "bash", result: "boom", isError: true });
    expect(frames[0]).toEqual({ type: "tool_result", id: "t2", isError: true, preview: "boom" });
  });
});

describe("clip / fidelity-B truncation", () => {
  it("returns short results unchanged", () => {
    expect(clip("hi", 2048)).toBe("hi");
  });

  it("clips an oversized result to the byte cap and marks it truncated", () => {
    const big = "x".repeat(5000);
    const out = clip(big, 2048);
    expect(out.startsWith("x".repeat(2048))).toBe(true);
    expect(out.endsWith("…[truncated]")).toBe(true);
    // the un-suffixed head is exactly the cap in bytes
    expect(Buffer.from(out.slice(0, -"…[truncated]".length), "utf8").byteLength).toBe(2048);
  });

  it("coerces non-string results via JSON before clipping", () => {
    expect(clip({ a: 1 }, 2048)).toBe('{"a":1}');
  });
});

describe("terminalFrame selection & parity", () => {
  it("clean stop-reason → done carrying sessionId/stopReason/usage", () => {
    const r: TurnResult = {
      sessionId: "s1",
      response: "hi",
      stopReason: "end_turn",
      usage: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0, total: 3 },
    };
    expect(terminalFrame(r)).toEqual({
      type: "done",
      sessionId: "s1",
      stopReason: "end_turn",
      usage: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0, total: 3 },
    });
  });

  it("error stop-reason → error carrying the same errorMessage a sync caller reads", () => {
    const r: TurnResult = { sessionId: "s2", response: "", stopReason: "error", errorMessage: "boom" };
    expect(terminalFrame(r)).toEqual({
      type: "error",
      sessionId: "s2",
      stopReason: "error",
      errorMessage: "boom",
    });
  });

  it("max_tokens is a clean finish → done", () => {
    const r: TurnResult = { sessionId: "s3", response: "partial", stopReason: "max_tokens" };
    expect(terminalFrame(r)).toEqual({ type: "done", sessionId: "s3", stopReason: "max_tokens" });
  });
});
