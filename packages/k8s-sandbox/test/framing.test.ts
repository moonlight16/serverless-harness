import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { FrameParser, wrapCommand } from "../src/framing.js";

const SOH = "\x01";

describe("wrapCommand", () => {
  // The cap is applied IN THE POD, on the raw stream before base64. Counting bytes
  // client-side would cap content at cap × 3/4 (base64 inflation), so the trip point
  // would differ from the per-call transports — a weaker form of exactly the
  // distinguishability #180 is about. `head -c` also bounds FrameParser.push's
  // quadratic buffer growth, and keeps PIPESTATUS[0] indexing the command.
  it("brackets base64 output with nonce markers, caps raw bytes, and reports the command's exit code", () => {
    const line = wrapCommand("n1", "cat '/workspace/a.txt'", undefined, 8);
    expect(line).toBe(
      `printf '${SOH}B%s\\n' n1; { cat '/workspace/a.txt'; } | head -c 9 | base64; ` +
        `printf '${SOH}E%s %d\\n' n1 "\${PIPESTATUS[0]}"\n`,
    );
  });

  it("delivers stdin to the command via a nonce-delimited heredoc, still capped", () => {
    const line = wrapCommand("n2", "base64 -d > '/workspace/a.txt'", Buffer.from("aGk="), 8);
    expect(line).toBe(
      `printf '${SOH}B%s\\n' n2; { base64 -d > '/workspace/a.txt' <<'KAGENTI_EOF_n2'\n` +
        `aGk=\nKAGENTI_EOF_n2\n} | head -c 9 | base64; ` +
        `printf '${SOH}E%s %d\\n' n2 "\${PIPESTATUS[0]}"\n`,
    );
  });

  it("asks for cap+1 bytes so the client can distinguish 'exactly at the cap' from 'over it'", () => {
    // At exactly `cap` bytes the read is complete and must NOT be flagged; the client
    // detects truncation as `stdout.length > cap`, which needs one byte of evidence.
    expect(wrapCommand("n3", "cat f", undefined, 100)).toContain("| head -c 101 |");
  });
});

describe("FrameParser", () => {
  const SOHb = SOH;
  function frame(nonce: string, payload: string, code: number): string {
    const b64 = Buffer.from(payload).toString("base64");
    return `${SOHb}B${nonce}\n${b64}\n${SOHb}E${nonce} ${code}\n`;
  }

  it("emits a complete frame in one chunk, base64-decoded", () => {
    const p = new FrameParser();
    const frames = p.push(Buffer.from(frame("n1", "hello", 0)));
    expect(frames).toHaveLength(1);
    expect(frames[0]).toMatchObject({ nonce: "n1", exitCode: 0 });
    expect(frames[0].stdout.toString()).toBe("hello");
  });

  it("waits for the end marker (no emit on a partial frame)", () => {
    const p = new FrameParser();
    const full = frame("n1", "hello", 0);
    expect(p.push(Buffer.from(full.slice(0, 10)))).toHaveLength(0);
    const rest = p.push(Buffer.from(full.slice(10)));
    expect(rest).toHaveLength(1);
    expect(rest[0].stdout.toString()).toBe("hello");
  });

  it("handles a split in the middle of the begin marker", () => {
    const p = new FrameParser();
    const full = frame("n7", "x", 0);
    const cut = 1; // mid "\x01B..."
    expect(p.push(Buffer.from(full.slice(0, cut)))).toHaveLength(0);
    expect(p.push(Buffer.from(full.slice(cut)))).toHaveLength(1);
  });

  it("emits multiple frames present in one chunk, preserving exit codes", () => {
    const p = new FrameParser();
    const frames = p.push(Buffer.from(frame("a", "one", 0) + frame("b", "two", 2)));
    expect(frames.map((f) => [f.nonce, f.stdout.toString(), f.exitCode])).toEqual([
      ["a", "one", 0],
      ["b", "two", 2],
    ]);
  });

  it("round-trips binary payloads (NUL and high bytes)", () => {
    const p = new FrameParser();
    const bin = Buffer.from([0x00, 0xff, 0x01, 0x42, 0x0a]);
    const b64 = bin.toString("base64");
    const frames = p.push(Buffer.from(`${SOHb}Bn1\n${b64}\n${SOHb}En1 0\n`));
    expect(frames[0].stdout.equals(bin)).toBe(true);
  });
});

describe("wrapCommand executed by a real bash (integration)", () => {
  const hasBash = spawnSync("bash", ["-c", "true"]).status === 0;
  const maybe = hasBash ? it : it.skip;

  maybe("writes a file through the heredoc-stdin path and frames exit 0", () => {
    const dir = mkdtempSync(join(tmpdir(), "framing-bash-"));
    try {
      const target = join(dir, "out.txt");
      const content = Buffer.from('hello\nworld\nspecial "q" $x `b`\n');
      const line = wrapCommand("n1", `base64 -d > '${target}'`, Buffer.from(content.toString("base64")), 8 * 1024 * 1024);
      const res = spawnSync("bash", { input: line });
      expect(res.status).toBe(0);
      const frames = new FrameParser().push(res.stdout);
      expect(frames).toHaveLength(1);
      expect(frames[0]).toMatchObject({ nonce: "n1", exitCode: 0 });
      expect(existsSync(target)).toBe(true);
      expect(readFileSync(target).equals(content)).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  maybe("frames a non-zero exit code from a failing write", () => {
    const line = wrapCommand("n2", "base64 -d > '/no_such_dir_xyz/out.txt'", Buffer.from("eA=="), 8 * 1024 * 1024);
    const res = spawnSync("bash", { input: line });
    const frames = new FrameParser().push(res.stdout);
    expect(frames).toHaveLength(1);
    expect(frames[0].nonce).toBe("n2");
    expect(frames[0].exitCode).not.toBe(0);
  });

  maybe("caps raw stdout at capBytes + 1 through a real pipeline", () => {
    // 5000 bytes offered, cap 100 → the pod hands back exactly 101, so the client sees
    // one byte past the cap and knows the output was cut. Proving this against a real
    // bash matters: the hermetic conformance fake simulates the cap, so it can only
    // confirm the client half of the contract.
    const line = wrapCommand("n3", "yes AAAAAAAA | head -c 5000", undefined, 100);
    const res = spawnSync("bash", { input: line });
    const frames = new FrameParser().push(res.stdout);
    expect(frames).toHaveLength(1);
    expect(frames[0].stdout.length).toBe(101);
  });

  maybe("passes output through untouched when it lands under the cap", () => {
    const line = wrapCommand("n4", "printf 'abc'", undefined, 100);
    const res = spawnSync("bash", { input: line });
    const frames = new FrameParser().push(res.stdout);
    expect(frames[0].stdout.toString()).toBe("abc");
    expect(frames[0].exitCode).toBe(0);
  });

  maybe("PIPESTATUS[0] still reports the command, not head or base64", () => {
    // The cap adds a pipeline stage; if it were inserted before the group, or if the
    // printf read a different PIPESTATUS index, a failing command would frame as 0.
    const line = wrapCommand("n5", "exit 42", undefined, 100);
    const res = spawnSync("bash", { input: line });
    const frames = new FrameParser().push(res.stdout);
    expect(frames[0].exitCode).toBe(42);
  });

  maybe("still writes a file through the capped heredoc-stdin path", () => {
    // A write produces no stdout, so head passes 0 bytes and the cap is inert — but the
    // heredoc must survive having a stage appended after the closing brace.
    const dir = mkdtempSync(join(tmpdir(), "framing-bash-cap-"));
    try {
      const target = join(dir, "out.txt");
      const content = Buffer.from("payload\nwith newline\n");
      const line = wrapCommand("n6", `base64 -d > '${target}'`, Buffer.from(content.toString("base64")), 100);
      const res = spawnSync("bash", { input: line });
      expect(res.status).toBe(0);
      const frames = new FrameParser().push(res.stdout);
      expect(frames[0].exitCode).toBe(0);
      expect(readFileSync(target).equals(content)).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
