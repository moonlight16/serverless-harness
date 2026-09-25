import { describe, it, expect, vi } from 'vitest';
import { readConfig } from '../src/config.js';

/**
 * W's default must come from the CPU count this DEPLOYMENT may use, not from the host's core list.
 *
 * `os.cpus()` enumerates the host's physical CPUs and never consults a cgroup CPU quota, so under
 * `docker run --cpus=2`, a Kubernetes CPU limit, or any other quota-based cap it reports the whole
 * machine. Node's own documentation for `os.cpus()` says so outright -- "`os.cpus().length` should
 * not be used to calculate the amount of parallelism available to an application. Use
 * `availableParallelism` for this purpose" -- because `availableParallelism()` wraps libuv's
 * `uv_available_parallelism()`, which reads `cpu.max` (cgroup v2) / `cpu.cfs_quota_us` (v1) and
 * clamps to the quota.
 *
 * The two sources AGREE on an unconstrained host -- both are 10 on the laptop this was written on --
 * which is why the default-value test in config.test.ts cannot catch this, and why this file forces
 * them apart. Only a disagreement can say which one `readConfig` is reading.
 *
 * `vi.hoisted` because a `vi.mock` factory runs before the module body's own `const`s exist: the two
 * counts have to be assigned somewhere the factory and the assertions can both see them, or they
 * drift apart and the fixture stops discriminating.
 */
const { HOST_CORES, QUOTA_CORES } = vi.hoisted(() => ({
  /** What `os.cpus()` sees: the whole machine. */
  HOST_CORES: 8,
  /** What the cgroup quota allows: `--cpus=2`. */
  QUOTA_CORES: 2,
}));

vi.mock('node:os', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:os')>();
  // A complete CpuInfo rather than a bare `{}`, so a future reader of a field other than `.length`
  // fails on the value it read instead of on `undefined`.
  const cpu = { model: 'mock', speed: 2926, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } };
  return {
    ...actual,
    cpus: () => Array.from({ length: HOST_CORES }, () => ({ ...cpu })),
    availableParallelism: () => QUOTA_CORES,
  };
});

// S is neither count, so no assertion below can be satisfied by reading the wrong field.
const env = (extra: Record<string, string> = {}) =>
  ({ SH_TURNS_PER_WORKER: '3', ...extra }) as NodeJS.ProcessEnv;

describe("readConfig's default W under a CPU quota smaller than the host", () => {
  it('reads the quota, not the host core count', () => {
    // Guard the fixture before trusting it: were these equal, the assertions below would pass
    // whichever source `readConfig` read, and this file would silently test nothing.
    expect(QUOTA_CORES).not.toBe(HOST_CORES);
    // Pre-fix this was HOST_CORES: a supervisor in a 2-CPU container forked 8 workers and
    // oversubscribed its own quota with no error and no warning, and any P6 density number
    // gathered there described the host rather than the deployment being measured (§5.1; E8/E9).
    expect(readConfig(env()).workers).toBe(QUOTA_CORES);
    expect(readConfig(env()).workers).not.toBe(HOST_CORES);
  });

  it('still takes an explicit SH_WORKERS above the quota', () => {
    // The quota is the DEFAULT's source, not a ceiling. Clamping an operator's value to it would be
    // a different change, and it would break pinning W across an E8 ladder on a quota'd host.
    expect(readConfig(env({ SH_WORKERS: '5' })).workers).toBe(5);
  });
});
