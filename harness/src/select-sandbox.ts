import { credentials } from '@grpc/grpc-js';
import {
  listPoolPods,
  resolveSandboxConfig,
  GrpcRelayTransport,
  SandboxExecClient,
  type RunKubectl,
  type K8sSandboxConfig,
  type SandboxTransport,
  type ExecClientLike,
} from '@sh/k8s-sandbox';
import { RedisLeaseStore, type LeaseStore } from './sandbox-lease.js';
import { RedisRecordStore, type RecordStore, type SandboxRecord } from './pool-records.js';

/**
 * Process-wide Redis-backed stores, reused across selections instead of built per call.
 *
 * Both stores used to be constructed inside `selectPoolSandbox` on every call. That was harmless
 * while only prompt leaves reached this code — a leaf is a process, so "per call" was "once". The
 * moment `/turn` began selecting from the pool it became per TURN, and the two failed differently:
 *
 *  - `RedisRecordStore` was constructed AND closed, so it churned: measured on a real run, ~10k
 *    turns produced **35,654** connections.
 *  - `RedisLeaseStore` was constructed and **never closed** (its constructor connects eagerly), so
 *    it LEAKED one live connection per turn — monotonically, to the `maxclients 10000` ceiling.
 *
 * Redis then answered `ERR max number of clients reached`, node-redis raised that as an `'error'`
 * event on a client with no listener, and all four workers exited code 1 **simultaneously**,
 * mid-rung, stranding every in-flight turn (the driver's own curl has no timeout, so those turns
 * hung indefinitely rather than failing). It took ~13 minutes at 27-54 turns/s to accumulate, which
 * is why two complete E8 ladders passed before it appeared.
 *
 * Each memo holds the STORE, not a promise of one, and is dropped when a call through it rejects:
 * caching a broken client would turn one transient Redis blip into a permanent failure for the life
 * of the process — for the record store a permanent "no sandboxes", for the lease store a permanent
 * inability to acquire. Neither is closed on the happy path; they are process-lived by design and
 * the process exiting is what releases them.
 */
type Closable = { close(): Promise<void> };
let recordsMemo: { url: string | undefined; store: RecordStore & Closable } | null = null;
let leaseMemo: { url: string | undefined; store: LeaseStore & Closable } | null = null;

function sharedRecords(url: string | undefined): RecordStore {
  if (!recordsMemo || recordsMemo.url !== url) {
    // A changed REDIS_URL means a different Redis; drop the old client rather than silently talking
    // to the wrong one. Closing is best-effort — it is being replaced either way.
    if (recordsMemo) void recordsMemo.store.close().catch(() => {});
    recordsMemo = { url, store: new RedisRecordStore(url) };
  }
  const store = recordsMemo.store;
  const drop = () => {
    recordsMemo = null;
  };
  return {
    put: (rec) => guard(store.put(rec), drop),
    remove: (id) => guard(store.remove(id), drop),
    list: () => guard(store.list(), drop),
  };
}

function sharedLease(url: string | undefined): LeaseStore {
  if (!leaseMemo || leaseMemo.url !== url) {
    if (leaseMemo) void leaseMemo.store.close().catch(() => {});
    leaseMemo = { url, store: new RedisLeaseStore(url) };
  }
  const store = leaseMemo.store;
  const drop = () => {
    leaseMemo = null;
  };
  return {
    load: (pod) => guard(store.load(pod), drop),
    acquire: (pod, cap, runId, ttlMs) => guard(store.acquire(pod, cap, runId, ttlMs), drop),
    heartbeat: (pod, runId, ttlMs) => guard(store.heartbeat(pod, runId, ttlMs), drop),
    release: (pod, runId) => guard(store.release(pod, runId), drop),
  };
}

/** Run `p`, and drop the shared store's memo if it rejects so the next call rebuilds it. */
async function guard<T>(p: Promise<T>, drop: () => void): Promise<T> {
  try {
    return await p;
  } catch (err) {
    drop();
    throw err;
  }
}

/** Test-only: drop the cached stores so a test can inject its own or force a reconnect. */
export function resetSharedRecords(): void {
  if (recordsMemo) void recordsMemo.store.close().catch(() => {});
  if (leaseMemo) void leaseMemo.store.close().catch(() => {});
  recordsMemo = null;
  leaseMemo = null;
}

/** Pure: pods ordered ascending by active load (stable — ties keep input order). */
export function orderByLoad(loads: { pod: string; active: number }[]): string[] {
  return loads
    .map((l, i) => ({ ...l, i }))
    .sort((a, b) => a.active - b.active || a.i - b.i)
    .map((l) => l.pod);
}

/** Which sandbox inventories `selectPoolSandbox` consults. */
export type DiscoverySource = 'pods' | 'records' | 'both';

/**
 * Resolve `SH_SANDBOX_DISCOVERY`. Unset ⇒ `both`, which is byte-for-byte today's behaviour
 * (pods always listed; records only read when the remote flag is on).
 *  - `pods`    — kubectl listing only; mirrored grpc records are ignored even with the flag on.
 *  - `records` — mirrored grpc records only; never shells out to kubectl. This is what lets a
 *                bare VM (no cluster, no kubeconfig) reach a relay-fronted sandbox.
 *  - `both`    — the historical default.
 */
export function resolveDiscoverySource(
  env: NodeJS.ProcessEnv,
  remoteSandbox: boolean,
): DiscoverySource {
  const raw = env.SH_SANDBOX_DISCOVERY?.trim();
  if (!raw) return 'both';
  if (raw !== 'pods' && raw !== 'records' && raw !== 'both') {
    throw new Error(`SH_SANDBOX_DISCOVERY='${raw}' is not one of pods|records|both`);
  }
  if (raw === 'records' && !remoteSandbox) {
    // Blame the flag, not the pool: without this the caller sees "no Running pods for pool
    // selector '…'", which sends them debugging a healthy pool.
    throw new Error(
      'SH_SANDBOX_DISCOVERY=records requires SH_REMOTE_SANDBOX=1 (records are only read when the remote flag is on)',
    );
  }
  return raw;
}

/** Thrown when a pool is configured but every pod is at the soft cap. */
export class SandboxPoolSaturatedError extends Error {
  constructor(selector: string) {
    super(`sandbox pool '${selector}' saturated: all pods at capacity`);
    this.name = 'SandboxPoolSaturatedError';
  }
}

export interface SelectedSandbox {
  config: K8sSandboxConfig;
  /** Present ONLY for a leased grpc presence record; undefined for pods. */
  transport?: SandboxTransport;
  heartbeat: () => Promise<void>;
  release: () => Promise<void>;
}

export interface SelectDeps {
  listPods?: (
    selector: string,
    namespace: string,
    context?: string,
    run?: RunKubectl,
  ) => Promise<string[]>;
  lease?: LeaseStore;
  run?: RunKubectl;
  /** Mirrored grpc presence records; defaults to a RedisRecordStore. Only consulted when opts.remoteSandbox is true. */
  records?: RecordStore;
  /** Builds the exec client for a leased grpc record; defaults to a real SandboxExecClient at SH_RELAY_ADDR. */
  makeExecClient?: (sandboxId: string) => ExecClientLike;
  /**
   * Builds the transport for a leased grpc record; defaults to GrpcRelayTransport.
   * Injectable so a test can assert what the leased transport was built with — there
   * is no other way to observe it without a real gRPC client.
   */
  makeTransport?: (
    sandboxId: string,
    client: ExecClientLike,
    opts?: { workspaceKey?: string },
  ) => SandboxTransport;
}

/** Lazily builds a real gRPC exec client — only reached on the grpc branch when the flag is on. */
function defaultExecClient(_sandboxId: string, env: NodeJS.ProcessEnv): ExecClientLike {
  const addr = env.SH_RELAY_ADDR ?? 'sandbox-relay.default.svc.cluster.local:8443';
  return new SandboxExecClient(addr, credentials.createInsecure()) as unknown as ExecClientLike;
}

/**
 * Choose a sandbox pod for a leaf.
 *  - No `KAGENTI_SANDBOX_POOL_SELECTOR` ⇒ fall back to single-pod resolution
 *    (`KAGENTI_SANDBOX_POD`/`_NAME`); returns null if that too is unset (run local tools).
 *  - Pool configured ⇒ list Running pods (plus mirrored grpc records when `opts.remoteSandbox`
 *    is true), pick least-loaded under the soft cap, acquire a lease. Throws
 *    SandboxPoolSaturatedError if every candidate is full.
 *  - `SH_SANDBOX_DISCOVERY` narrows which inventories are consulted (see resolveDiscoverySource).
 */
export async function selectPoolSandbox(
  env: NodeJS.ProcessEnv,
  headCwd: string,
  sessionId: string,
  opts: { cap: number; ttlMs: number; remoteSandbox?: boolean },
  deps: SelectDeps = {},
): Promise<SelectedSandbox | null> {
  const selector = env.KAGENTI_SANDBOX_POOL_SELECTOR;
  if (!selector) {
    const config = await resolveSandboxConfig(env, headCwd, deps.run);
    return config ? { config, heartbeat: async () => {}, release: async () => {} } : null;
  }

  const namespace = env.KAGENTI_SANDBOX_NAMESPACE ?? 'default';
  const context = env.KAGENTI_SANDBOX_CONTEXT || undefined;
  const podCwd = env.KAGENTI_SANDBOX_CWD ?? '/workspace';
  const list = deps.listPods ?? listPoolPods;
  const lease = deps.lease ?? sharedLease(env.REDIS_URL);

  const source = resolveDiscoverySource(env, opts.remoteSandbox === true);
  const pods = source === 'records' ? [] : await list(selector, namespace, context, deps.run);

  // Inertness: when the flag is off, never construct a RedisRecordStore or call .list() —
  // the pod path must stay byte-for-byte identical to today (no extra Redis connection).
  const remoteOn = opts.remoteSandbox === true && source !== 'pods';
  let grpcRecs: SandboxRecord[] = [];
  if (remoteOn) {
    const injected = deps.records;
    grpcRecs = injected ? await injected.list() : await sharedRecords(env.REDIS_URL).list();
  }
  const grpcById = new Map(grpcRecs.map((r) => [r.sandboxId, r]));

  const candidates = [...pods, ...grpcRecs.map((r) => r.sandboxId)];
  if (candidates.length === 0) throw new Error(`no Running pods for pool selector '${selector}'`);

  const loads = await Promise.all(
    candidates.map(async (name) => ({ pod: name, active: await lease.load(name) })),
  );
  for (const name of orderByLoad(loads)) {
    if (await lease.acquire(name, opts.cap, sessionId, opts.ttlMs)) {
      const config: K8sSandboxConfig = { pod: name, namespace, context, podCwd, headCwd };
      const rec = grpcById.get(name);
      const make = deps.makeTransport ?? GrpcRelayTransport;
      const transport = rec
        ? make(
            name,
            (deps.makeExecClient ?? ((id: string) => defaultExecClient(id, env)))(name),
            // The lease's session id becomes the Exec's workspace_key. This is the ONLY
            // harness change the microVM tier needs, and it is required for
            // correctness rather than convenience: without it, consecutive
            // leaseholders of one sandbox_id inherit the previous session's workspace
            // (spec §3.4).
            { workspaceKey: sessionId },
          )
        : undefined;
      return {
        config,
        transport,
        heartbeat: () => lease.heartbeat(name, sessionId, opts.ttlMs),
        release: () => lease.release(name, sessionId),
      };
    }
  }
  throw new SandboxPoolSaturatedError(selector);
}
