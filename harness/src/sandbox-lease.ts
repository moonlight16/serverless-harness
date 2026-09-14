import { createClient, type RedisClientType } from 'redis';
import { swallowRedisErrors } from '@sh/session-backend';

/** Redis key holding the per-pod lease set (member = leaf id, score = expiry ms). */
export function leaseKey(pod: string): string {
  return `sh:sandbox:${pod}:leases`;
}

/** Pure: count members whose expiry (score, ms) is still in the future. */
export function activeCount(members: { value: string; score: number }[], now: number): number {
  return members.filter((m) => m.score > now).length;
}

/**
 * Atomic acquire. KEYS[1]=leaseKey. ARGV = [now, cap, sessionId, expiry].
 * Sweeps expired members, then adds {sessionId -> expiry} iff active < cap.
 * Returns 1 (acquired) or 0 (full). Crash reclaim is implicit: a dead leaf's
 * member ages past its expiry and is swept by the next acquire (spec §4.1).
 */
export const ACQUIRE_LUA = `
redis.call('ZREMRANGEBYSCORE', KEYS[1], '-inf', ARGV[1])
if redis.call('ZCARD', KEYS[1]) < tonumber(ARGV[2]) then
  redis.call('ZADD', KEYS[1], ARGV[4], ARGV[3])
  return 1
end
return 0`;

export interface LeaseStore {
  /** Active (non-expired) lease count for a pod; sweeps expired as a side effect. */
  load(pod: string): Promise<number>;
  /** Try to take a lease under the soft cap. */
  acquire(pod: string, cap: number, sessionId: string, ttlMs: number): Promise<boolean>;
  /** Refresh a held lease's expiry (called on an interval while the leaf runs). */
  heartbeat(pod: string, sessionId: string, ttlMs: number): Promise<void>;
  /** Drop a held lease. */
  release(pod: string, sessionId: string): Promise<void>;
}

/** Real node-redis-backed lease store. Connects lazily; reuses REDIS_URL. */
export class RedisLeaseStore implements LeaseStore {
  private client: RedisClientType;
  private ready: Promise<void>;
  constructor(
    url = process.env.REDIS_URL ?? 'redis://127.0.0.1:6379',
    private now: () => number = Date.now,
  ) {
    this.client = createClient({ url }) as RedisClientType;
    // A socket error on an established connection is re-emitted on the client, and no listener means
    // the process exits 1. See swallowRedisErrors (@sh/session-backend) for the proof and why this
    // store's process-lifetime memoisation is what makes it reachable with no turn in flight.
    swallowRedisErrors(this.client, 'sandbox lease store');
    this.ready = this.client.connect().then(() => undefined);
  }
  async load(pod: string): Promise<number> {
    await this.ready;
    await this.client.zRemRangeByScore(leaseKey(pod), '-inf', this.now());
    return this.client.zCard(leaseKey(pod));
  }
  async acquire(pod: string, cap: number, sessionId: string, ttlMs: number): Promise<boolean> {
    await this.ready;
    const now = this.now();
    const res = await this.client.eval(ACQUIRE_LUA, {
      keys: [leaseKey(pod)],
      arguments: [String(now), String(cap), sessionId, String(now + ttlMs)],
    });
    return res === 1;
  }
  async heartbeat(pod: string, sessionId: string, ttlMs: number): Promise<void> {
    await this.ready;
    await this.client.zAdd(leaseKey(pod), { score: this.now() + ttlMs, value: sessionId });
  }
  async release(pod: string, sessionId: string): Promise<void> {
    await this.ready;
    await this.client.zRem(leaseKey(pod), sessionId);
  }
  async close(): Promise<void> {
    await this.ready;
    await this.client.close();
  }
}
