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


def load_mem_timeline(path):
    samples = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            ts, avail = line.split()
            samples.append((float(ts), int(avail)))
    samples.sort()
    return samples


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
    mem_samples = load_mem_timeline(mem_timeline_path)
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
