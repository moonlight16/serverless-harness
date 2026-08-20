import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { toolChoiceExtension } from "../src/tool-choice-extension";

type Handler = (e: { payload?: unknown }) => unknown;

// Minimal fake `pi` that captures the before_provider_request handler the extension registers.
function makePi(): { pi: unknown; getHandler: () => Handler | undefined } {
  let handler: Handler | undefined;
  const pi = { on: (_event: string, h: Handler) => { handler = h; } };
  return { pi, getHandler: () => handler };
}

const invoke = (h: Handler, tools: unknown, toolChoice?: unknown) =>
  h({ payload: { tools, ...(toolChoice !== undefined ? { tool_choice: toolChoice } : {}) } }) as {
    tool_choice?: unknown;
  };

describe("toolChoiceExtension", () => {
  const saved = { custom: process.env.SH_MODEL_CUSTOM, api: process.env.SH_MODEL_API };
  beforeEach(() => {
    delete process.env.SH_MODEL_CUSTOM;
    delete process.env.SH_MODEL_API;
  });
  afterEach(() => {
    saved.custom === undefined
      ? delete process.env.SH_MODEL_CUSTOM
      : (process.env.SH_MODEL_CUSTOM = saved.custom);
    saved.api === undefined ? delete process.env.SH_MODEL_API : (process.env.SH_MODEL_API = saved.api);
  });

  it("is inert (registers no handler) unless SH_MODEL_CUSTOM=1", () => {
    const { pi, getHandler } = makePi();
    toolChoiceExtension()(pi as never);
    expect(getHandler()).toBeUndefined();
  });

  it("injects the Anthropic object form by default (SH_MODEL_API unset)", () => {
    process.env.SH_MODEL_CUSTOM = "1";
    const { pi, getHandler } = makePi();
    toolChoiceExtension()(pi as never);
    const out = invoke(getHandler()!, [{ name: "bash" }]);
    expect(out.tool_choice).toEqual({ type: "auto" });
  });

  it("injects the OpenAI string form when SH_MODEL_API=openai-completions", () => {
    process.env.SH_MODEL_CUSTOM = "1";
    process.env.SH_MODEL_API = "openai-completions";
    const { pi, getHandler } = makePi();
    toolChoiceExtension()(pi as never);
    const out = invoke(getHandler()!, [{ name: "bash" }]);
    expect(out.tool_choice).toBe("auto");
  });

  it("does not override an already-set tool_choice", () => {
    process.env.SH_MODEL_CUSTOM = "1";
    process.env.SH_MODEL_API = "openai-completions";
    const { pi, getHandler } = makePi();
    toolChoiceExtension()(pi as never);
    const out = invoke(getHandler()!, [{ name: "bash" }], "required");
    expect(out.tool_choice).toBe("required");
  });

  it("leaves tool_choice unset when there are no tools", () => {
    process.env.SH_MODEL_CUSTOM = "1";
    const { pi, getHandler } = makePi();
    toolChoiceExtension()(pi as never);
    const out = invoke(getHandler()!, []);
    expect(out.tool_choice).toBeUndefined();
  });
});
