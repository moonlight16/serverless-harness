import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

/**
 * For custom (non-Anthropic) model endpoints reached via SH_MODEL_CUSTOM=1, nudge tool use.
 *
 * The agent's simple-provider path never sets `tool_choice` on the outgoing Anthropic-messages
 * request, so the endpoint defaults to "auto". Claude reliably calls tools under "auto", but
 * open models served by vLLM (e.g. Llama-3.3-70B) frequently answer in plain text instead of
 * emitting a tool call — so sandbox tools never fire and the agent narrates a fabricated result.
 *
 * This extension hooks `before_provider_request` and, when tools are present but no tool_choice
 * was set, injects the protocol-appropriate `tool_choice` (Anthropic object `{type:"auto"}` vs
 * OpenAI string `"auto"`, selected by SH_MODEL_API). It also logs the tool names and
 * chosen tool_choice on the first request so the outgoing payload is observable (there is no
 * built-in request-body logging). Opt-in via SH_MODEL_CUSTOM=1 so the built-in Anthropic path is
 * untouched.
 */
export function toolChoiceExtension(): ExtensionFactory {
  return (pi) => {
    if (process.env.SH_MODEL_CUSTOM !== "1") return;
    let logged = false;
    // Handler receives the event { type, payload }; returning a value replaces the payload
    // (runner.ts before_provider_request contract). Mutate + return event.payload.
    pi.on("before_provider_request", (event: { payload?: unknown }) => {
      const params = event.payload as Record<string, unknown> | undefined;
      if (!params || typeof params !== "object") return undefined;
      const tools = params.tools as Array<{ name?: string }> | undefined;
      if (Array.isArray(tools) && tools.length > 0 && params.tool_choice == null) {
        // Emit the form the wire protocol accepts: Anthropic wants the object `{type:"auto"}`;
        // OpenAI Chat Completions (vLLM/RITS/OpenAI) wants the bare string "auto" and rejects the
        // object ("Invalid value for `function`: `None`"). Select on SH_MODEL_API (default anthropic).
        const api = process.env.SH_MODEL_API ?? "anthropic";
        params.tool_choice = api.startsWith("openai") ? "auto" : { type: "auto" };
      }
      if (!logged) {
        logged = true;
        // stderr so it always reaches container logs regardless of log level.
        console.error(
          `[tool-choice] tools=${JSON.stringify((tools ?? []).map((t) => t.name))} tool_choice=${JSON.stringify(params.tool_choice)}`,
        );
      }
      return params;
    });
  };
}
