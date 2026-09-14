// packages/session-backend/src/redis-backend.ts
import { createClient, type RedisClientType } from 'redis';
import { makeStoredEntry, type StoredEntry } from './entry';
import type { LogStore } from './backend';

const streamKey = (sid: string) => `session:${sid}`;
const seqKey = (sid: string) => `session:${sid}:seq`;

/**
 * Redis Streams implementation of LogStore. Single-writer-per-session: a session is
 * owned by one harness instance at a time (mobility is sequential handoff, never
 * concurrent), so INCR(position) then XADD is safe without a transaction.
 *
 * Stream-id scheme (M5 cutover): each entry is stored with the explicit id
 * `"<position>-0"` (e.g. `"3-0"`), enabling O(tail) seeks in `read(fromPosition)`.
 * Sessions written by pre-M5 code used `"*"` (auto-generated ids) and are NOT
 * back-compatible; treat them as throwaway / reset before use.
 */
export class RedisSessionBackend<E = unknown> implements LogStore<E> {
  private client: RedisClientType;
  private ready: Promise<void> | null;
  constructor(url = process.env.REDIS_URL ?? 'redis://127.0.0.1:6379') {
    this.client = createClient({ url });
    this.ready = this.arm();
  }

  /**
   * Connect, and RE-ARM on failure so a transient outage costs one call rather than the process.
   *
   * `ready` used to be assigned once here and never reassigned, so a single rejected `connect()` left
   * a permanently REJECTED promise that every method awaited. Redis coming back changed nothing; only
   * a restart cleared it.
   *
   * Worth being precise about which failures reach that path, because it is not the obvious one. With
   * node-redis's defaults a REFUSED connect does not reject at all -- `defaultReconnectStrategy`
   * answers with an exponential backoff, so the attempt retries forever and callers simply wait. The
   * rejecting shape is the 5s default `connectTimeout`, which raises `SocketTimeoutError`: the one
   * cause that strategy answers `false` to, abandoning the attempt. In a cluster that is the COMMON
   * transient shape -- a Service with no ready endpoints, or a NetworkPolicy drop, black-holes the SYN
   * rather than refusing it.
   *
   * That was survivable while callers built one backend per turn: a blip cost exactly one turn and
   * the next turn built a fresh client that connected. It stops being survivable the moment one is
   * memoised process-wide (run-turn.ts's `sharedSessionStore`), where the same unlucky moment --
   * most likely the FIRST turn after boot, the window the old per-turn leak never mattered in --
   * would poison every remaining turn for the worker's lifetime. The async path makes that worse
   * than a stall: the failure classifies as retryable (classify-outcome.ts), so the queue entry is
   * redelivered to the same poisoned process and fails instantly again -- a hot retry loop with no
   * backoff and no terminal state.
   *
   * Clearing the memo on rejection is what lets the next call retry instead of replaying the
   * original error. The identity check keeps a late failure from clearing a NEWER attempt, and the
   * side `.catch` is bookkeeping only -- callers still see the real rejection through the promise
   * they awaited, while a rejected connect that nobody is awaiting yet can no longer surface as an
   * unhandled rejection (node-redis raising `'error'` on a client with no listener is how four
   * workers exited code 1 simultaneously).
   */
  private arm(): Promise<void> {
    const attempt = this.client.connect().then(() => undefined);
    void attempt.catch(() => {
      if (this.ready === attempt) this.ready = null;
    });
    return attempt;
  }

  /** Await the live connect attempt, starting a fresh one if the last one failed. */
  private open(): Promise<void> {
    return (this.ready ??= this.arm());
  }

  async nextPosition(sid: string): Promise<number> {
    await this.open();
    return this.client.incr(seqKey(sid));
  }

  async append(sid: string, entry: E, piType: string): Promise<StoredEntry<E>> {
    await this.open();
    const position = await this.nextPosition(sid);
    const stored = makeStoredEntry({
      position,
      session_id: sid,
      piType,
      entry,
      timestamp: Date.now(),
    });
    await this.client.xAdd(streamKey(sid), `${stored.position}-0`, {
      position: String(stored.position),
      timestamp: String(stored.timestamp),
      piType: stored.piType,
      entry: JSON.stringify(stored.entry),
      content_sha256: stored.content_sha256,
    });
    return stored;
  }

  async read(sid: string, fromPosition = 1): Promise<StoredEntry<E>[]> {
    await this.open();
    const start = fromPosition <= 1 ? '-' : `${fromPosition}-0`;
    const rows = await this.client.xRange(streamKey(sid), start, '+');
    return rows.map((r): StoredEntry<E> => ({
      position: Number(r.message.position),
      timestamp: Number(r.message.timestamp),
      session_id: sid,
      piType: r.message.piType,
      entry: JSON.parse(r.message.entry) as E,
      content_sha256: r.message.content_sha256,
    }));
  }

  async latestWhere(sid: string, predicate: (entry: E) => boolean): Promise<StoredEntry<E> | null> {
    const all = await this.read(sid);
    const matches = all.filter((e) => predicate(e.entry));
    return matches.length ? matches[matches.length - 1] : null;
  }

  async positionOfId(sid: string, id: string): Promise<number | null> {
    const rows = await this.read(sid);
    for (const r of rows) {
      if ((r.entry as { id?: unknown } | null)?.id === id) return r.position;
    }
    return null;
  }

  async list(): Promise<string[]> {
    await this.open();
    const keys = await this.client.keys('session:*');
    return keys.filter((k) => !k.endsWith(':seq')).map((k) => k.slice('session:'.length));
  }

  /** Test helper: delete a session's stream + sequence counter. */
  async reset(sid: string): Promise<void> {
    await this.open();
    await this.client.del([streamKey(sid), seqKey(sid)]);
  }

  /**
   * Close the connection (call in test teardown).
   *
   * Deliberately does NOT propagate a failed connect: `await this.ready` meant a client that never
   * connected could not be closed AT ALL -- close() rejected, callers swallowed it with
   * `.catch(() => {})`, and the socket was left dangling. Swallow it here and close what is open.
   */
  async close(): Promise<void> {
    await this.ready?.catch(() => {});
    if (this.client.isOpen) await this.client.quit();
  }
}
