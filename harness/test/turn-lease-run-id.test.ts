import { describe, it, expect, vi } from 'vitest';
import { turnRunId } from '../src/run-turn.js';

/**
 * The lease runId must be unique per TURN. It used to be `input.sessionId ?? randomUUID()`, which is
 * the negation of that: a session id is stable across every turn of a session, so the `??` reached
 * `randomUUID()` only for ANONYMOUS turns while every turn carrying a session id — the resume path —
 * ran under a runId shared with every other turn of that session.
 *
 * Sharing it is not benign, because the runId is the ZSET member in ACQUIRE_LUA rather than a
 * payload. `ZADD` on an existing member refreshes its score and leaves `ZCARD` unchanged, so N
 * concurrent turns of one session occupy ONE lease slot: the cap undercounts (deflating the
 * saturation accounting this PR's 503 is computed from) and the first turn to finish `zRem`s the
 * member its siblings are still executing under.
 *
 * `run-turn-sandbox.test.ts` covers `acquireTurnSandbox` with explicit unique runIds, so it could
 * not see this — the defect was in the ONE expression feeding that seam, inside `executeTurn`, which
 * no test drove. Hence the wiring case below.
 */
const { seen, FakeRedisSessionBackend } = vi.hoisted(() => {
  class FakeRedisSessionBackend {
    async read() {
      return [];
    }
    async latestWhere() {
      return null;
    }
    async append() {
      return {};
    }
    async list() {
      return [];
    }
    async close() {}
  }
  return { seen: [] as string[], FakeRedisSessionBackend };
});

// The session is opened BEFORE the sandbox is acquired (so a missing session 404s ahead of any pool
// work — turn-session-before-lease.test.ts pins that ordering), which is why this test has to stand a
// session up at all: it is on the path to the seam being observed here. Both fakes are inert; no Redis.
vi.mock('@sh/session-backend', () => ({
  RedisSessionBackend: FakeRedisSessionBackend,
  swallowRedisErrors: () => {},
}));
vi.mock('@earendil-works/pi-coding-agent', () => ({
  createAgentSession: async () => ({ session: { prompt: async () => {} } }),
  DefaultResourceLoader: class {},
  getAgentDir: () => '/fake/agent-dir',
  SessionManager: {
    create: (_cwd: string, _snapshot: unknown, opts?: { id: string }) => ({
      getSessionId: () => opts?.id ?? 'sess-created',
    }),
    openFromCheckpoint: async (sid: string) => ({ getSessionId: () => sid }),
  },
  SettingsManager: { create: () => ({}) },
}));

// Intercept at selectPoolSandbox so executeTurn's real derivation runs and is observable, while the
// turn stops before executeTurnCore — no model, no prompt.
vi.mock('../src/select-sandbox.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/select-sandbox.js')>();
  return {
    ...actual,
    selectPoolSandbox: async (
      _env: NodeJS.ProcessEnv,
      _headCwd: string,
      runId: string,
    ): Promise<never> => {
      seen.push(runId);
      throw new Error('stop: the runId is all this test needs');
    },
  };
});

describe('turnRunId', () => {
  it('is distinct for two turns of the SAME session', () => {
    expect(turnRunId('sess-1')).not.toBe(turnRunId('sess-1'));
  });

  it('is distinct for two anonymous turns', () => {
    expect(turnRunId()).not.toBe(turnRunId());
  });

  it('prefixes the session id so a held lease can be traced back to a conversation', () => {
    expect(turnRunId('sess-1')).toMatch(/^sess-1:[0-9a-f-]{36}$/);
    expect(turnRunId()).toMatch(/^anon:[0-9a-f-]{36}$/);
  });
});

describe('executeTurn lease runId', () => {
  it('leases under a distinct runId on every turn of one session', async () => {
    const { executeTurn } = await import('../src/run-turn.js');
    const turn = () =>
      executeTurn({
        prompt: 'hi',
        sessionId: 'sess-1',
        createIfAbsent: false,
      }).catch(() => {});

    await turn();
    await turn();

    // This is the assertion that failed on the old expression: both turns arrived as 'sess-1'.
    expect(seen).toHaveLength(2);
    expect(seen[0]).not.toBe(seen[1]);
    expect(seen.every((id) => id.startsWith('sess-1:'))).toBe(true);
  });
});
