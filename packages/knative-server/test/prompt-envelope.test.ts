import { describe, it, expect } from "vitest";
import { isPromptEnvelope, isRunEnvelope } from "../src/server.js";

describe("isPromptEnvelope", () => {
  const ok = { sessionId: "s", kind: "prompt", prompt: "summarize the repo" };
  it("accepts a well-formed prompt envelope", () => { expect(isPromptEnvelope(ok)).toBe(true); });
  it("rejects a missing/empty prompt", () => {
    expect(isPromptEnvelope({ sessionId: "s", kind: "prompt" })).toBe(false);
    expect(isPromptEnvelope({ sessionId: "s", kind: "prompt", prompt: 123 })).toBe(false);
  });
  it("rejects the wrong kind", () => {
    expect(isPromptEnvelope({ sessionId: "s", kind: "solve", prompt: "x" })).toBe(false);
  });
  it("rejects a missing sessionId", () => {
    expect(isPromptEnvelope({ kind: "prompt", prompt: "x" })).toBe(false);
  });
});

describe("isRunEnvelope accepts a prompt envelope", () => {
  it("accepts a well-formed prompt envelope", () => {
    expect(isRunEnvelope({ sessionId: "s", kind: "prompt", prompt: "x" })).toBe(true);
  });
  it("still rejects junk", () => { expect(isRunEnvelope({ foo: 1 })).toBe(false); });
});
