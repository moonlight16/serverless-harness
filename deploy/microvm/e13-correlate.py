#!/usr/bin/env python3
"""deploy/microvm/e13-correlate.py

Cross-references per-VM result-file and `.boot.log` file MTIMES (a free
proxy for "when did this VM finish" - neither e12-vsock-egress-probe.sh nor
e13-restore-capacity-control.sh is modified to add explicit per-VM
timestamps, per this plan's Global Constraints) against the memory timeline
and OOM-killer events e13-mem-telemetry.sh captured. Pure function of its
inputs - no VM, no root, no KVM needed - so it is fully covered by a
fixture-file unit test (deploy/microvm/tests/e13-correlate.test.sh).

--results-glob must match ONLY per-VM record files (e.g.
"rung-C-128-*.json" or "control-128-*.json"), never an aggregate record
(rung-C-128.json / control-128.json) or the top-level answer file - those
lack a per-VM "ok" at the expected shape and would be misread as one event
with an arbitrary mtime.
"""
import argparse
import glob
import json
import os
import sys


def load_mem_timeline(path):
    # Every line must be exactly "epoch bytes". A malformed one is REFUSED,
    # not skipped: this file is the sole evidence for the memory hypothesis,
    # and a silently dropped sample is the same class of defect as issue
    # #291's post-load host signals - an instrument reporting nothing while
    # looking like it reported something.
    #
    # The one exception is a torn FINAL line, which this file's own producer
    # can legitimately leave behind: e13-mem-telemetry.sh's sampler is killed
    # by the wrapper's EXIT trap, and a kill landing inside one write can
    # truncate the last line mid-flush. That case is tolerated, because the
    # analysis over every preceding sample is still sound - but it is
    # recorded in the summary and announced on stderr, never absorbed.
    #
    # The test for it is the missing "\n", NOT a parse failure, and the line
    # is discarded even when it parses. A truncated write can leave a
    # perfectly well-formed line carrying a truncated integer - "101.0 8"
    # where "101.0 8589934592" was intended - which would otherwise enter the
    # timeline as a real 8-byte MemAvailable reading and manufacture the
    # memory pressure this script exists to test for. A complete sample
    # always ends in "\n", so an unterminated last line cannot be trusted on
    # its face. A malformed line anywhere else, or a malformed last line that
    # IS newline-terminated, means the file is not what the caller says it is,
    # and that refuses.
    samples = []
    torn_final_line = False
    with open(path) as f:
        lines = f.readlines()
    for lineno, raw in enumerate(lines, start=1):
        is_final_unterminated = lineno == len(lines) and not raw.endswith("\n")
        line = raw.strip()
        if not line:
            continue
        if is_final_unterminated:
            torn_final_line = True
            print(
                f"e13-correlate: {path}:{lineno}: discarding unterminated final line "
                f"{line!r} (sampler killed mid-write; a truncated integer would parse); "
                f"{len(samples)} complete samples kept",
                file=sys.stderr,
            )
            continue
        parts = line.split()
        sample = None
        if len(parts) == 2:
            try:
                sample = (float(parts[0]), int(parts[1]))
            except ValueError:
                sample = None
        if sample is None:
            raise SystemExit(f"e13-correlate: {path}:{lineno}: expected 'epoch bytes', got {line!r}")
        samples.append(sample)
    samples.sort()
    return samples, torn_final_line


def nearest_mem_sample(samples, t):
    if not samples:
        return None
    return min(samples, key=lambda s: abs(s[0] - t))


def load_oom_timestamps(path):
    # journalctl -o short-unix lines start with an epoch(.micros) token. A
    # dmesg -T watcher's lines ("[Mon Jan  2 03:04:05 2026] ...") are not
    # parsed here - an oom_watcher="dmesg" in telemetry-meta.json is the
    # caller's signal to treat an empty result as "not observed", never as
    # "no OOM events happened".
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            head = line.split()[0]
            try:
                out.append(float(head))
            except ValueError:
                continue
    return sorted(out)


def near_any(t, oom_ts, window_s=2.0):
    return any(abs(t - o) <= window_s for o in oom_ts)


def collect_vm_events(results_glob, boot_log_glob):
    events = []
    for path in sorted(glob.glob(results_glob)):
        with open(path) as f:
            record = json.load(f)
        events.append({"path": path, "ok": record.get("ok"), "mtime": os.path.getmtime(path)})
    for path in sorted(glob.glob(boot_log_glob)):
        events.append({"path": path, "ok": False, "mtime": os.path.getmtime(path)})
    return events


def build_summary(results_glob, boot_log_glob, mem_timeline_path, oom_events_path, low_water_bytes):
    mem_samples, mem_timeline_torn_final_line = load_mem_timeline(mem_timeline_path)
    oom_ts = load_oom_timestamps(oom_events_path)
    events = collect_vm_events(results_glob, boot_log_glob)

    def below_low_water(avail):
        return avail is not None and avail < low_water_bytes

    rows = []
    for e in events:
        sample = nearest_mem_sample(mem_samples, e["mtime"])
        avail = sample[1] if sample else None
        rows.append(
            {
                "path": e["path"],
                "ok": e["ok"],
                "mtime": e["mtime"],
                "mem_available_bytes_nearest": avail,
                "mem_sample_age_s": abs(sample[0] - e["mtime"]) if sample else None,
                "near_oom_event": near_any(e["mtime"], oom_ts),
                "below_low_water": below_low_water(avail),
            }
        )

    failed = [r for r in rows if r["ok"] is False]
    ok = [r for r in rows if r["ok"] is True]

    return {
        "total_events": len(rows),
        "failed_count": len(failed),
        "ok_count": len(ok),
        "mem_samples_total": len(mem_samples),
        "mem_timeline_torn_final_line": mem_timeline_torn_final_line,
        "oom_events_total": len(oom_ts),
        "failed_near_oom_event": sum(1 for r in failed if r["near_oom_event"]),
        "failed_below_low_water": sum(1 for r in failed if r["below_low_water"]),
        "ok_near_oom_event": sum(1 for r in ok if r["near_oom_event"]),
        "ok_below_low_water": sum(1 for r in ok if r["below_low_water"]),
        "rows": rows,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--results-glob", required=True)
    p.add_argument("--boot-log-glob", required=True)
    p.add_argument("--mem-timeline", required=True)
    p.add_argument("--oom-events", required=True)
    p.add_argument("--low-water-bytes", type=int, default=500 * 1024 * 1024)
    p.add_argument("--out", required=True)
    args = p.parse_args()

    summary = build_summary(
        args.results_glob, args.boot_log_glob, args.mem_timeline, args.oom_events, args.low_water_bytes
    )
    with open(args.out, "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
