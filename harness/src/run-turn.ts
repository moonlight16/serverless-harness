import {
  createAgentSession,
  DefaultResourceLoader,
  getAgentDir,
  SessionManager,
  SettingsManager,
  type FileEntry,
} from "@earendil-works/pi-coding-agent";
import { getModel, getModels, getProviders, type AssistantMessage, type Model } from "@earendil-works/pi-ai";
import { RedisSessionBackend } from "@sh/session-backend";
import { BufferedRedisBackend } from "./buffered-redis-backend.js";
import { flushExtension } from "./flush-extension.js";
import { k8sSandboxExtension, resolveSandboxConfig } from "@sh/k8s-sandbox";
import { checkpointExtension } from "./checkpoint-extension.js";
import { budgetVoterExtension, branchSpend } from "./budget-voter.js";
import { toolChoiceExtension } from "./tool-choice-extension.js";

export interface TurnConfig {
  redisUrl?: string;
  cwd?: string;
  anthropicBaseUrl?: string;
  anthropicAuthToken?: string;
  model?: string;
  provider?: string;
}

export interface ModelSelection {
  provider: string;
  modelId: string;
}

/** Resolve model + provider as runtime inputs: config > env > default. */
export function resolveModelSelection(
  config?: { model?: string; provider?: string },
  env: NodeJS.ProcessEnv = process.env,
): ModelSelection {
  return {
    provider: config?.provider ?? env.SH_MODEL_PROVIDER ?? "anthropic",
    modelId: config?.model ?? env.SH_MODEL ?? "claude-opus-4-8",
  };
}

/**
 * Synthesize a model object for an endpoint that speaks the Anthropic Messages wire format
 * but serves a model id NOT in pi-ai's built-in registry — e.g. an in-cluster vLLM/llm-d
 * server whose /v1/messages is Anthropic-compatible but which requires its own served model
 * name (meta-llama/Llama-3.1-8B-Instruct) verbatim in the request body.
 *
 * Opt-in via SH_MODEL_CUSTOM=1. SH_MODEL is used as-is (id + name), ANTHROPIC_BASE_URL is the
 * endpoint. applyModelGateway() still layers Bearer auth + the gateway compat flags on top,
 * so this only supplies the pieces requireModel() otherwise reads from the registry. The
 * cost/context numbers are placeholders (self-hosted, not billed); contextWindow/maxTokens are
 * conservative defaults — override via SH_MODEL_CONTEXT_WINDOW / SH_MODEL_MAX_TOKENS if needed.
 */
/**
 * Parse SH_MODEL_HEADERS — a JSON object of extra request headers to send to a custom endpoint
 * (e.g. `{"RITS_API_KEY":"${RITS_API_KEY}"}`) — into a header map. Empty/absent ⇒ {}. Throws on
 * non-object JSON.
 *
 * String values support `${VAR}` interpolation from `env`, so a secret header value can be supplied
 * via a secretKeyRef env var (e.g. RITS_API_KEY) rather than an inline literal in the manifest.
 * An unset `${VAR}` interpolates to the empty string.
 */
function parseModelHeaders(env: NodeJS.ProcessEnv): Record<string, string> {
  const raw = env.SH_MODEL_HEADERS;
  if (!raw) return {};
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`SH_MODEL_HEADERS must be a JSON object of header name→value pairs (got: ${raw}).`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`SH_MODEL_HEADERS must be a JSON object of header name→value pairs.`);
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
    out[k] =
      typeof v === "string"
        ? v.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_m, name: string) => env[name] ?? "")
        : String(v);
  }
  return out;
}

function synthesizeCustomModel(modelId: string, env: NodeJS.ProcessEnv): Model<"anthropic-messages"> {
  // SH_MODEL_BASE_URL is the protocol-neutral knob; ANTHROPIC_BASE_URL is the back-compat fallback.
  const baseUrl = env.SH_MODEL_BASE_URL || env.ANTHROPIC_BASE_URL;
  if (!baseUrl) {
    throw new Error(
      `SH_MODEL_CUSTOM=1 (anthropic) requires SH_MODEL_BASE_URL or ANTHROPIC_BASE_URL (the Anthropic-compatible endpoint to send "${modelId}" to).`,
    );
  }
  const contextWindow = Number(env.SH_MODEL_CONTEXT_WINDOW) || 131072;
  const maxTokens = Number(env.SH_MODEL_MAX_TOKENS) || 8192;
  // Typed as Model<"anthropic-messages"> (not `as ReturnType<typeof getModel>`) so tsc checks
  // the shape — if pi-ai's Model type gains a required field, this fails to compile instead of
  // silently omitting it.
  const model: Model<"anthropic-messages"> = {
    id: modelId,
    name: modelId,
    api: "anthropic-messages",
    // provider MUST be "anthropic" (not a synthetic tag): pi resolves the request API key by
    // provider name — authStorage.getApiKey(provider) maps "anthropic" -> ANTHROPIC_API_KEY
    // (which applyModelGateway seeds from the auth token), whereas an unknown provider like
    // "custom" has no env-key mapping and fails with `No API key found for "custom"`. Request
    // routing is by baseUrl + api, not provider, so tagging it "anthropic" sends traffic to the
    // custom baseUrl while satisfying the key lookup. Overridable via SH_MODEL_PROVIDER.
    provider: (env.SH_MODEL_PROVIDER ?? "anthropic") as Model<"anthropic-messages">["provider"],
    baseUrl,
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow,
    maxTokens,
  };
  return model;
}

/**
 * Synthesize an OpenAI Chat Completions model for an OpenAI-compatible endpoint (RITS / vLLM /
 * OpenAI / Azure / most OSS gateways), reached via SH_MODEL_CUSTOM=1 +
 * SH_MODEL_API=openai-completions. Pi's openai-completions provider reads `model.baseUrl` and
 * spreads `model.headers` into the request; the API key is resolved from OPENAI_API_KEY.
 *
 * Auth (SH_MODEL_AUTH):
 *   - "bearer" (default): pi sends `Authorization: Bearer <OPENAI_API_KEY>` (standard OpenAI/vLLM).
 *   - "custom-header": the endpoint authenticates via a header in SH_MODEL_HEADERS (e.g. RITS's
 *     `RITS_API_KEY`); strip the default Authorization so the SDK Bearer isn't also sent. pi's
 *     client still requires a non-empty OPENAI_API_KEY, so seed a placeholder when unset.
 *   - "none": no auth header.
 */
function synthesizeOpenAICompletionsModel(
  modelId: string,
  env: NodeJS.ProcessEnv,
): Model<"openai-completions"> {
  const baseUrl = env.SH_MODEL_BASE_URL || env.OPENAI_BASE_URL;
  if (!baseUrl) {
    throw new Error(
      `SH_MODEL_CUSTOM=1 with SH_MODEL_API=openai-completions requires SH_MODEL_BASE_URL or OPENAI_BASE_URL (the OpenAI-compatible endpoint to send "${modelId}" to).`,
    );
  }
  const contextWindow = Number(env.SH_MODEL_CONTEXT_WINDOW) || 131072;
  const maxTokens = Number(env.SH_MODEL_MAX_TOKENS) || 8192;
  const auth = env.SH_MODEL_AUTH ?? "bearer";
  const headers: Record<string, string | null> = { ...parseModelHeaders(env) };
  if (auth === "custom-header" || auth === "none") {
    // Endpoint authenticates via a custom header (already in `headers`) or not at all — strip the
    // SDK's default Authorization Bearer so an unknown/empty Bearer isn't sent. pi's openai client
    // still requires a non-empty api key even when the Bearer is unused, so seed a placeholder.
    headers.Authorization = null;
    if (!env.OPENAI_API_KEY) process.env.OPENAI_API_KEY = "unused";
  }
  const model: Model<"openai-completions"> = {
    id: modelId,
    name: modelId,
    api: "openai-completions",
    // provider "openai" so pi resolves the api key from OPENAI_API_KEY (env-api-keys.ts). Request
    // routing is by baseUrl + api; provider only drives the key lookup. Overridable via SH_MODEL_PROVIDER.
    provider: (env.SH_MODEL_PROVIDER ?? "openai") as Model<"openai-completions">["provider"],
    baseUrl,
    headers: headers as unknown as Record<string, string>,
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow,
    maxTokens,
  };
  return model;
}

/**
 * Resolve a model from the pi-ai registry, throwing a clear error when the id is unknown.
 * getModel() returns undefined for an unknown provider/model (e.g. the dotted
 * "claude-sonnet-4.6" is a github-copilot key, not an anthropic one) — without this guard
 * the caller crashes later on `baseModel.headers`. Returns the model object on success.
 *
 * SH_MODEL_CUSTOM=1 bypasses the registry entirely and synthesizes a model for a custom endpoint.
 * SH_MODEL_API selects the wire protocol (default "anthropic"):
 *   - "anthropic"          → Anthropic Messages via SH_MODEL_BASE_URL/ANTHROPIC_BASE_URL (default;
 *                            covers direct Anthropic + LiteLLM Anthropic-format). synthesizeCustomModel().
 *   - "openai-completions" → OpenAI Chat Completions via SH_MODEL_BASE_URL/OPENAI_BASE_URL + headers/auth
 *                            (RITS/vLLM/OpenAI/Azure). synthesizeOpenAICompletionsModel().
 *   - "openai-responses"   → deferred (see docs/specs/2026-08-20-multi-protocol-model-provider-design.md).
 * See that spec for the config schema.
 */
export function requireModel(
  provider: string,
  modelId: string,
  env: NodeJS.ProcessEnv = process.env,
) {
  if (env.SH_MODEL_CUSTOM === "1") {
    const api = env.SH_MODEL_API ?? "anthropic";
    switch (api) {
      case "anthropic":
      case "anthropic-messages":
        return synthesizeCustomModel(modelId, env);
      case "openai-completions":
        return synthesizeOpenAICompletionsModel(modelId, env);
      case "openai-responses":
        throw new Error(
          `SH_MODEL_API=openai-responses is not yet implemented (deferred; see docs/specs/2026-08-20-multi-protocol-model-provider-design.md §7). Use openai-completions.`,
        );
      default:
        throw new Error(
          `Unknown SH_MODEL_API "${api}". Expected: anthropic | openai-completions | openai-responses.`,
        );
    }
  }
  const model = getModel(provider as never, modelId as never);
  if (model) return model;
  const providers = getProviders() as string[];
  if (!providers.includes(provider)) {
    throw new Error(
      `Unknown model provider "${provider}". Known providers: ${providers.join(", ")}.`,
    );
  }
  const ids = (getModels(provider as never) as Array<{ id: string }>).map((m) => m.id);
  // Surface the dot-vs-dash (or case) twin if one exists — the common mistake.
  const norm = (s: string) => s.replace(/[.\-]/g, "").toLowerCase();
  const suggestions = ids.filter((id) => norm(id) === norm(modelId));
  const hint = suggestions.length
    ? `Did you mean: ${suggestions.join(", ")}?`
    : `Known "${provider}" ids include: ${ids.slice(0, 12).join(", ")}${ids.length > 12 ? ", …" : ""}.`;
  throw new Error(`Unknown model "${provider}/${modelId}" — not in the pi-ai registry. ${hint}`);
}

export interface TurnResult {
  sessionId: string;
  response: string;
  stopReason: string;
  errorMessage?: string;
}

/**
 * Apply the LLM-gateway transform to a pi-ai model object.
 *
 * When a gateway base URL or auth token is in play (config or env), rewrite the model to
 * call the gateway with Bearer auth and strip `x-api-key` (the gateway authenticates via
 * Authorization). Also seeds `ANTHROPIC_API_KEY` from the auth token when unset, since some
 * pi-ai code paths still read the env var. Returns the base model unchanged when neither a
 * gateway base nor a token is configured (direct-key mode).
 *
 * Shared by runTurn (interactive) and runLeaf (job mode) so both honor the same credentials.
 */
export function applyModelGateway<M extends { headers?: Record<string, unknown> }>(
  baseModel: M,
  config?: Pick<TurnConfig, "anthropicBaseUrl" | "anthropicAuthToken">,
): M {
  // The Anthropic gateway rewrite (Bearer + strip x-api-key + seed ANTHROPIC_API_KEY, and the
  // litellm compat-flag disables) applies ONLY to the Anthropic-messages path. OpenAI-compatible
  // models carry their own baseUrl/headers/auth from synthesizeOpenAICompletionsModel — leave
  // them untouched (else we'd clobber baseUrl with ANTHROPIC_BASE_URL and inject a wrong Bearer).
  const api = (baseModel as { api?: string }).api;
  if (api && api !== "anthropic-messages") return baseModel;
  // `||` (not `??`) so an empty-string config value falls back to the env var rather than
  // suppressing it — "" is a "not set" sentinel here, not a meaningful credential.
  const authToken = config?.anthropicAuthToken || process.env.ANTHROPIC_AUTH_TOKEN;
  // Intentional process.env mutation: some pi-ai code paths read ANTHROPIC_API_KEY at
  // invocation time, so seed it from the auth token. This now runs from two call sites
  // (runTurn and runLeaf via applyModelGateway) — do NOT "clean it up" into a local.
  if (authToken && !process.env.ANTHROPIC_API_KEY) {
    process.env.ANTHROPIC_API_KEY = authToken;
  }
  const gatewayBase = config?.anthropicBaseUrl || process.env.ANTHROPIC_BASE_URL;
  if (!gatewayBase && !authToken) return baseModel;
  return {
    ...baseModel,
    ...(gatewayBase ? { baseUrl: gatewayBase } : {}),
    ...(gatewayBase
      ? {
          // Anthropic-compatible gateways (e.g. litellm) reject the per-tool extras the
          // direct Anthropic API accepts. Without this, tool-bearing requests fail with
          // "tools.0.custom.eager_input_streaming: Extra inputs are not permitted". Disable
          // the gateway-incompatible compat flags so convertTools() omits those fields.
          compat: {
            ...(baseModel as { compat?: Record<string, unknown> }).compat,
            supportsEagerToolInputStreaming: false,
            supportsCacheControlOnTools: false,
            supportsLongCacheRetention: false,
          },
        }
      : {}),
    ...(authToken
      ? {
          headers: {
            ...baseModel.headers,
            Authorization: `Bearer ${authToken}`,
            "x-api-key": null, // strip x-api-key when using gateway Bearer auth
          } as unknown as Record<string, string>,
        }
      : {}),
  };
}

export async function runTurn(
  prompt: string,
  sessionId: string | undefined,
  config?: TurnConfig,
): Promise<TurnResult> {
  const redisUrl = config?.redisUrl ?? "redis://localhost:6379";
  const cwd = config?.cwd ?? process.cwd();

  const store = new RedisSessionBackend<FileEntry>(redisUrl);
  const backend = new BufferedRedisBackend(store);

  const sessionManager = sessionId
    ? await SessionManager.openFromCheckpoint(sessionId, backend, cwd)
    : SessionManager.create(cwd, undefined, undefined, backend);

  const agentDir = getAgentDir();
  const settingsManager = SettingsManager.create(cwd, agentDir);

  const budgetLimit = Number(process.env.SH_BUDGET_TOKENS);
  const budgetMargin = Number(process.env.SH_BUDGET_MARGIN);
  const sandboxConfig = await resolveSandboxConfig(process.env, cwd);
  // Surface whether sandbox routing actually resolved: a null config means tool calls run in
  // the harness pod's own filesystem (local), not a sandbox pod — a common cause of "the file
  // never appeared in the sandbox". Cheap one-line signal in container logs.
  if (process.env.SH_MODEL_CUSTOM === "1") {
    console.error(`[sandbox] resolved config: ${sandboxConfig ? "pod/pool" : "NULL (tools run LOCAL)"}`);
  }
  const extensionFactories = [
    flushExtension(backend),
    k8sSandboxExtension({ config: sandboxConfig }),
    checkpointExtension(store, sessionManager),
    toolChoiceExtension(),
  ];
  if (Number.isFinite(budgetLimit) && budgetLimit > 0) {
    // session_start is not emitted in the headless path, so compute the pre-turn baseline
    // (cumulative spend already on the loaded branch) here and inject it into the voter.
    const budgetBaseline = branchSpend(sessionManager) ?? 0;
    extensionFactories.push(
      budgetVoterExtension(sessionManager, {
        limit: budgetLimit,
        baseline: budgetBaseline,
        ...(Number.isFinite(budgetMargin) && budgetMargin > 0 ? { margin: budgetMargin } : {}),
      }),
    );
  }

  const resourceLoader = new DefaultResourceLoader({
    cwd,
    agentDir,
    settingsManager,
    extensionFactories,
  });
  await resourceLoader.reload();

  const { provider, modelId } = resolveModelSelection(config);
  const baseModel = requireModel(provider, modelId);
  const model = applyModelGateway(baseModel, config);

  const { session } = await createAgentSession({
    sessionManager,
    model,
    resourceLoader,
    settingsManager,
  });

  await session.prompt(prompt);

  const lastMessage = session.state.messages.at(-1) as AssistantMessage | undefined;
  let response = "";
  let stopReason = "end_turn";
  let errorMessage: string | undefined;

  if (lastMessage?.role === "assistant") {
    stopReason = lastMessage.stopReason ?? "end_turn";
    if (stopReason === "error" || stopReason === "aborted") {
      errorMessage = lastMessage.errorMessage || `Request ${stopReason}`;
    } else {
      for (const content of lastMessage.content) {
        if (content.type === "text") {
          response += content.text;
        }
      }
    }
  }

  await backend.flush();

  return {
    sessionId: sessionManager.getSessionId(),
    response,
    stopReason,
    ...(errorMessage ? { errorMessage } : {}),
  };
}
