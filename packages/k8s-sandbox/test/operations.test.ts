import { describe, expect, it, vi } from "vitest";
import type { ExecInPod } from "../src/exec.js";
import type { K8sSandboxConfig } from "../src/config.js";
import { OUTPUT_TRUNCATED_MARKER } from "../src/transport.js";
import {
  createPodReadOps,
  createPodWriteOps,
  createPodEditOps,
  createPodBashOps,
  createPodLsOps,
  createPodFindOps,
} from "../src/operations.js";

const cfg: K8sSandboxConfig = {
  pod: "sbx-0",
  namespace: "default",
  context: undefined,
  podCwd: "/workspace",
  headCwd: "/head",
};

/** Build a fake ExecInPod that returns scripted results and records calls. */
function fakeExec(result: { stdout?: string; exitCode?: number | null; truncated?: boolean }) {
  const calls: Array<{ command: string; stdin?: string }> = [];
  const fn: ExecInPod = async (command, opts) => {
    calls.push({ command, stdin: opts?.stdin?.toString() });
    // `?? 0` would swallow a deliberate null (the truncation signal), so branch on undefined.
    const exitCode = result.exitCode === undefined ? 0 : result.exitCode;
    return { stdout: Buffer.from(result.stdout ?? ""), exitCode, truncated: result.truncated ?? false };
  };
  return { fn, calls };
}

describe("read ops", () => {
  it("reads a file via cat with the mapped path", async () => {
    const { fn, calls } = fakeExec({ stdout: "hello" });
    const ops = createPodReadOps(fn, cfg);
    const buf = await ops.readFile("/head/a.txt");
    expect(buf.toString()).toBe("hello");
    expect(calls[0].command).toBe("cat '/workspace/a.txt'");
  });

  it("readFile refuses a truncated read instead of returning partial bytes", async () => {
    // The seam caps returned stdout and signals it as exitCode null (spec §8). Pi's
    // Edit tool writes back whatever readFile returns, so returning these bytes would
    // truncate the file in the sandbox AND write "[output truncated]" into it.
    const { fn } = fakeExec({
      stdout: "a".repeat(64) + OUTPUT_TRUNCATED_MARKER,
      exitCode: null,
    });
    const ops = createPodReadOps(fn, cfg);
    await expect(ops.readFile("/head/big.txt")).rejects.toThrow(/truncated in pod.*big\.txt/);
  });

  it("readFile rejects when the cat itself fails", async () => {
    const { fn } = fakeExec({ stdout: "", exitCode: 1 });
    const ops = createPodReadOps(fn, cfg);
    await expect(ops.readFile("/head/missing.txt")).rejects.toThrow(/Read failed in pod.*missing\.txt/);
  });

  it("access rejects when test -r exits non-zero", async () => {
    const { fn } = fakeExec({ exitCode: 1 });
    const ops = createPodReadOps(fn, cfg);
    await expect(ops.access("/head/a.txt")).rejects.toThrow();
  });

  it("detectImageMimeType returns the type for an image, null otherwise", async () => {
    const img = createPodReadOps(fakeExec({ stdout: "image/png\n" }).fn, cfg);
    expect(await img.detectImageMimeType!("/head/x.png")).toBe("image/png");
    const txt = createPodReadOps(fakeExec({ stdout: "text/plain\n" }).fn, cfg);
    expect(await txt.detectImageMimeType!("/head/x.txt")).toBeNull();
  });
});

describe("write ops", () => {
  it("writes via base64 -d on stdin", async () => {
    const { fn, calls } = fakeExec({});
    const ops = createPodWriteOps(fn, cfg);
    await ops.writeFile("/head/a.txt", "hi");
    expect(calls[0].command).toBe("base64 -d > '/workspace/a.txt'");
    expect(calls[0].stdin).toBe(Buffer.from("hi").toString("base64"));
  });

  it("mkdir -p with the mapped dir", async () => {
    const { fn, calls } = fakeExec({});
    await createPodWriteOps(fn, cfg).mkdir("/head/sub");
    expect(calls[0].command).toBe("mkdir -p '/workspace/sub'");
  });
});

describe("edit ops", () => {
  it("access requires read AND write", async () => {
    const { fn, calls } = fakeExec({});
    await createPodEditOps(fn, cfg).access("/head/a.txt");
    expect(calls[0].command).toBe("test -r '/workspace/a.txt' && test -w '/workspace/a.txt'");
  });
});

describe("bash ops", () => {
  it("cds into the mapped cwd then runs the command, returning exitCode", async () => {
    const { fn, calls } = fakeExec({ exitCode: 0 });
    const ops = createPodBashOps(fn, cfg);
    const onData = vi.fn();
    const r = await ops.exec("echo hi", "/head", { onData });
    expect(calls[0].command).toBe("cd '/workspace' && echo hi");
    expect(r).toEqual({ exitCode: 0 });
  });

  it("injects env as a non-leaking, per-invocation prefix when env is provided", async () => {
    const { fn, calls } = fakeExec({ exitCode: 0 });
    const ops = createPodBashOps(fn, cfg);
    await ops.exec("echo $FOO", "/head", { onData: vi.fn(), env: { FOO: "bar baz" } });
    expect(calls[0].command).toBe("cd '/workspace' && env FOO='bar baz' bash -c 'echo $FOO'");
  });

  it("skips env keys whose value is undefined", async () => {
    const { fn, calls } = fakeExec({ exitCode: 0 });
    const ops = createPodBashOps(fn, cfg);
    await ops.exec("true", "/head", { onData: vi.fn(), env: { A: "1", B: undefined } });
    expect(calls[0].command).toBe("cd '/workspace' && env A='1' bash -c 'true'");
  });

  it("emits the M2 form (no prefix) when env is absent or empty", async () => {
    const { fn, calls } = fakeExec({ exitCode: 0 });
    const ops = createPodBashOps(fn, cfg);
    await ops.exec("echo hi", "/head", { onData: vi.fn(), env: {} });
    expect(calls[0].command).toBe("cd '/workspace' && echo hi");
  });

  it("drops env keys that are not valid POSIX names (no injection)", async () => {
    const { fn, calls } = fakeExec({ exitCode: 0 });
    const ops = createPodBashOps(fn, cfg);
    await ops.exec("true", "/head", {
      onData: vi.fn(),
      env: { GOOD: "1", "BAD KEY": "x", "PATH=/evil; rm -rf /": "y" },
    });
    expect(calls[0].command).toBe("cd '/workspace' && env GOOD='1' bash -c 'true'");
  });

  it("reports a cap-truncated command as exit 137 rather than success", async () => {
    // Pi's bash tool treats a null exit code as non-failing
    // (pi-fork/.../tools/bash.ts:397: `exitCode !== 0 && exitCode !== null`), so
    // passing the seam's null through told the model a SIGKILLed flood had completed
    // normally (#181). 137 is 128+9, the conventional SIGKILL status — not a
    // fabricated code: the command really was killed by signal 9 at the cap. Pi then
    // throws with the streamed output tail attached, so the model gets both facts.
    const { fn } = fakeExec({ stdout: "", exitCode: null, truncated: true });
    const ops = createPodBashOps(fn, cfg);
    const r = await ops.exec("yes", "/head", {});
    expect(r.exitCode).toBe(137);
  });

  it("passes a null exit code through untouched when it is NOT a cap trip", async () => {
    // truncated: false with a null code means "signalled, no status" — not our cap.
    // Mapping that to 137 too would invent a cause, so it stays null and Pi keeps
    // treating it as it does today.
    const { fn } = fakeExec({ stdout: "", exitCode: null, truncated: false });
    const ops = createPodBashOps(fn, cfg);
    const r = await ops.exec("something-signalled", "/head", {});
    expect(r.exitCode).toBeNull();
  });

  it("passes a genuine non-zero exit code through unchanged", async () => {
    const { fn } = fakeExec({ stdout: "", exitCode: 3, truncated: false });
    const ops = createPodBashOps(fn, cfg);
    const r = await ops.exec("false", "/head", {});
    expect(r.exitCode).toBe(3);
  });
});

describe("ls ops", () => {
  it("readdir splits lines and drops blanks", async () => {
    const { fn, calls } = fakeExec({ stdout: "a.txt\nb\n\n" });
    const entries = await createPodLsOps(fn, cfg).readdir("/head");
    expect(entries).toEqual(["a.txt", "b"]);
    expect(calls[0].command).toBe("ls -1A '/workspace'");
  });

  it("stat reports directory vs file", async () => {
    const dir = await createPodLsOps(fakeExec({ stdout: "DIR\n" }).fn, cfg).stat("/head/d");
    expect((await dir).isDirectory()).toBe(true);
    const file = await createPodLsOps(fakeExec({ stdout: "FILE\n" }).fn, cfg).stat("/head/f");
    expect((await file).isDirectory()).toBe(false);
  });
});

describe("find ops", () => {
  it("globs via rg --files, honouring the ignore list and stripping ./", async () => {
    const { fn, calls } = fakeExec({ stdout: "src/a.ts\nb.ts\n" });
    const ops = createPodFindOps(fn, cfg);
    const results = await ops.glob("*.ts", "/head", {
      ignore: ["**/node_modules/**", "**/.git/**"],
      limit: 100,
    });
    expect(results).toEqual(["src/a.ts", "b.ts"]);
    expect(calls[0].command).toBe(
      "cd '/workspace' && rg --files --hidden -g '*.ts' " +
        "-g '!**/node_modules/**' -g '!**/.git/**' | head -n 100",
    );
  });

  it("emits no ignore globs when the ignore list is empty", async () => {
    const { fn, calls } = fakeExec({ stdout: "" });
    const ops = createPodFindOps(fn, cfg);
    await ops.glob("*.go", "/head", { ignore: [], limit: 50 });
    expect(calls[0].command).toBe("cd '/workspace' && rg --files --hidden -g '*.go' | head -n 50");
  });

  it("glob refuses a truncated listing instead of returning a partial list with the marker as a path", async () => {
    // Same class as the readFile fix above: exitCode null means the output cap tripped
    // (or rg was signalled) mid-list, so what came back is not a trustworthy file list —
    // it may even contain OUTPUT_TRUNCATED_MARKER as a bogus "path" entry.
    const { fn } = fakeExec({
      stdout: "src/a.ts\nb.ts\n" + OUTPUT_TRUNCATED_MARKER,
      exitCode: null,
    });
    const ops = createPodFindOps(fn, cfg);
    await expect(ops.glob("*.ts", "/head", { ignore: [], limit: 5 })).rejects.toThrow(
      /glob (failed|truncated) in pod/,
    );
  });

  it("glob rejects when rg itself fails (e.g. a bad pattern) instead of returning an empty list", async () => {
    const { fn } = fakeExec({ stdout: "", exitCode: 2 });
    const ops = createPodFindOps(fn, cfg);
    await expect(ops.glob("[", "/head", { ignore: [], limit: 100 })).rejects.toThrow(/glob failed in pod/);
  });

  it("exists uses test -e on the mapped path", async () => {
    const { fn, calls } = fakeExec({ exitCode: 0 });
    expect(await createPodFindOps(fn, cfg).exists("/head/x")).toBe(true);
    expect(calls[0].command).toBe("test -e '/workspace/x'");
  });
});
