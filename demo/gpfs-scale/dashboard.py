#!/usr/bin/env python3
"""Live Rich dashboard for the BugStone shared-GPFS demo."""

from __future__ import annotations

import asyncio
import json
import re
import signal
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import click
from rich import box
from rich.align import Align
from rich.console import Group
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text


async def command(*args: str, timeout: float = 8) -> str:
    """Run a command quietly and return stdout, or a compact error marker."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout)
    except TimeoutError:
        return "<timed out>"
    except OSError as exc:
        return f"<unavailable: {exc}>"
    if proc.returncode:
        detail = stderr.decode(errors="replace").strip().splitlines()
        return f"<error: {detail[-1] if detail else proc.returncode}>"
    return stdout.decode(errors="replace").strip()


async def kubectl_json(context: str, namespace: str, *args: str) -> Any:
    raw = await command("kubectl", "--context", context, "-n", namespace, *args)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"error": raw}


def pod_rows(payload: Any) -> list[dict[str, str]]:
    rows = []
    for pod in payload.get("items", []) if isinstance(payload, dict) else []:
        meta = pod.get("metadata", {})
        status = pod.get("status", {})
        containers = status.get("containerStatuses") or []
        ready = f"{sum(bool(c.get('ready')) for c in containers)}/{len(containers)}"
        rows.append(
            {
                "name": meta.get("name", "?"),
                "phase": status.get("phase", "?"),
                "ready": ready,
                "node": pod.get("spec", {}).get("nodeName", "-"),
                "claim": next(
                    (
                        v.get("persistentVolumeClaim", {}).get("claimName", "-")
                        for v in pod.get("spec", {}).get("volumes", [])
                        if v.get("name") == "workspace"
                    ),
                    "-",
                ),
            }
        )
    return rows


def read_log(path: Path) -> dict[str, Any]:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        lines = []
    stage_line = next(
        (
            line
            for line in reversed(lines)
            if re.search(
                r"^\[(?:poc|async)\] (?:Phase A|prepare|stage|run Phase B|enqueue|reconcile|finalize|done)",
                line,
            )
        ),
        "",
    )
    stages = [
        ("done.", "COMPLETE", "Results and report are ready"),
        ("finalize", "FINALIZE", "Audit results and build the report"),
        ("reconcile", "RECONCILE", "Collect asynchronous leaf verdicts"),
        ("run Phase B", "PHASE B", "Synchronous leaf verification"),
        ("enqueue", "PHASE B", "Queue leaves for KEDA workers"),
        ("stage", "PUBLISH", "Publish the target repository through gitd"),
        ("prepare", "PREPARE", "Create one verification task per candidate"),
        ("Phase A", "PHASE A", "Deterministic candidate scan"),
    ]
    stage = ("STARTING", "Initialize the BugStone run")
    for needle, name, detail in stages:
        if needle in stage_line:
            stage = (name, detail)
            break
    return {"tail": lines[-14:], "tail_full": lines, "stage": stage}


def phases_panel(lines: list[str], run_state: str) -> Panel:
    """Show BugStone's canonical phases as a fixed status display."""
    log = "\n".join(lines)
    phase_b_started = bool(re.search(r"prepare Phase B|run Phase B|enqueue", log, re.I))
    phase_b_done = bool(re.search(r"phase_b_audit_passed[\"']?\s*:\s*true|done\.", log, re.I))

    table = Table(box=None, expand=True, show_header=False, padding=(0, 1))
    table.add_column("State", width=3, justify="center")
    table.add_column("Phase", width=20, style="bold cyan", no_wrap=True)
    table.add_column("Purpose", ratio=1)

    def add(state: str, phase: str, purpose: str) -> None:
        icon, style = {
            "done": ("✓", "green"),
            "active": ("▶", "bold yellow"),
            "pending": ("○", "dim"),
            "not-run": ("—", "dim"),
        }[state]
        table.add_row(f"[{style}]{icon}[/]", phase, f"[{style}]{purpose}[/]")

    add("done" if phase_b_started else "active", "Phase A", "Find candidates with deterministic static analysis")
    add(
        "done" if phase_b_done else "active" if phase_b_started else "pending",
        "Phase B",
        "Use LLM agents to verify candidates in isolated leaf sessions",
    )
    # The serverless-harness demo stops after Phase B. Keep the remainder visible
    # so viewers see where this experiment sits in the complete BugStone pipeline.
    add("not-run", "Phase C Triage", "Re-check findings and filter false positives — not run in this demo")
    add("not-run", "Phase C Validation", "Validate exploitability per finding — not run in this demo")
    add("not-run", "Phase D", "Produce reports and patches — not run in this demo")

    report_state = "done" if run_state == "complete" and phase_b_done else "active" if run_state == "complete" else "pending"
    report_icon = {"done": "[green]✓[/]", "active": "[yellow]▶[/]", "pending": "[dim]○[/]"}[report_state]
    footer = Text.from_markup(f"  {report_icon}  [bold cyan]Report[/]  Build the demo's Phase A/B HTML report")
    return Panel(Group(table, footer), title="BugStone pipeline", border_style="green")


async def gather(
    context: str, namespace: str, service: str, pool_selector: str, log_file: Path
) -> dict[str, Any]:
    storage_script = r"""
repo=no; [ -d /workspace/repo ] && repo=yes
leaves=0; [ -d /workspace/leaves ] && leaves=$(find /workspace/leaves -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
lock=no; [ -f /workspace/.sh-fetch.lock ] && lock=yes
size=-; head=-; objects=-
if [ "$repo" = yes ]; then
  size=$(du -sh /workspace/repo 2>/dev/null | awk '{print $1}')
  head=$(git -C /workspace/repo rev-parse --short FETCH_HEAD 2>/dev/null || echo initializing)
  objects=$(git -C /workspace/repo count-objects 2>/dev/null | awk '{print $1}' || echo -)
fi
printf 'SUMMARY|%s|%s|%s|%s|%s\n' "$repo" "$head" "$objects" "$size" "$lock"
printf 'LEAVES|%s\n' "$leaves"
for entry in /workspace/* /workspace/.[!.]*; do
  [ -e "$entry" ] || continue
  name=${entry#/workspace/}; [ -d "$entry" ] && name="$name/"
  printf 'ENTRY|%s\n' "$name"
done
if [ -d /workspace/leaves ]; then
  find /workspace/leaves -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n 10 | sed 's#^/workspace/leaves/#WORKTREE|#'
fi
"""
    sandboxes, pvcs, harness, workers, queue, storage, log = await asyncio.gather(
        kubectl_json(context, namespace, "get", "pods", "-l", pool_selector, "-o", "json"),
        kubectl_json(context, namespace, "get", "pvc", "-o", "json"),
        kubectl_json(
            context,
            namespace,
            "get",
            "pods",
            "-l",
            f"serving.knative.dev/service={service}",
            "-o",
            "json",
        ),
        kubectl_json(context, namespace, "get", "pods", "-l", "app=leaf-worker", "-o", "json"),
        command(
            "kubectl",
            "--context",
            context,
            "-n",
            namespace,
            "exec",
            "deploy/redis",
            "--",
            "redis-cli",
            "XLEN",
            "leaf-queue",
        ),
        command(
            "kubectl",
            "--context",
            context,
            "-n",
            namespace,
            "exec",
            "sandbox-0",
            "-c",
            "sandbox",
            "--",
            "sh",
            "-c",
            storage_script,
        ),
        asyncio.to_thread(read_log, log_file),
    )
    return {
        "sandboxes": pod_rows(sandboxes),
        "pvcs": pvcs.get("items", []) if isinstance(pvcs, dict) else [],
        "harness": pod_rows(harness),
        "workers": pod_rows(workers),
        "queue": queue,
        "storage": storage.splitlines(),
        "log": log,
    }


def pod_table(title: str, rows: list[dict[str, str]], empty: str) -> Panel:
    table = Table(box=box.SIMPLE, expand=True, show_header=True, header_style="bold cyan")
    table.add_column("Pod", ratio=4, no_wrap=True)
    table.add_column("Phase", ratio=1)
    table.add_column("Ready", ratio=1)
    table.add_column("Node", ratio=2, no_wrap=True)
    if rows:
        for row in rows:
            color = "green" if row["phase"] == "Running" else "yellow"
            table.add_row(row["name"], f"[{color}]{row['phase']}[/]", row["ready"], row["node"])
    else:
        table.add_row(f"[dim]{empty}[/]", "", "", "")
    return Panel(table, title=title, border_style="cyan")


def storage_panel(lines: list[str]) -> Panel:
    summary: dict[str, str] = {}
    entries: list[str] = []
    worktrees: list[str] = []
    for line in lines:
        parts = line.split("|")
        if parts[0] == "SUMMARY" and len(parts) >= 6:
            summary = dict(zip(("repo", "head", "objects", "size", "lock"), parts[1:6]))
        elif parts[0] == "LEAVES" and len(parts) == 2:
            summary["leaves"] = parts[1]
        elif parts[0] == "ENTRY" and len(parts) == 2:
            entries.append(parts[1])
        elif parts[0] == "WORKTREE" and len(parts) == 2:
            worktrees.append(parts[1])
    stats = Table.grid(expand=True)
    stats.add_column(style="bold magenta")
    stats.add_column()
    stats.add_row("Repository", summary.get("repo", "unavailable"))
    stats.add_row("HEAD", summary.get("head", "-"))
    stats.add_row("Git objects / size", f"{summary.get('objects', '-')} / {summary.get('size', '-')}")
    stats.add_row("Active worktrees", summary.get("leaves", "-"))
    stats.add_row("Fetch lock file", summary.get("lock", "-"))
    tree = Text("\n/workspace/\n", style="bold")
    for entry in entries[:12]:
        tree.append(f"  ├── {entry}\n", style="bright_blue" if entry.endswith("/") else "white")
    for worktree in worktrees[:8]:
        tree.append(f"  │   └── leaves/{worktree}\n", style="yellow")
    return Panel(Group(stats, tree), title="Shared GPFS workspace — live", border_style="magenta")


def pvc_panel(pvcs: list[dict[str, Any]], sandboxes: list[dict[str, str]]) -> Panel:
    mounted: dict[str, list[str]] = {}
    for sandbox in sandboxes:
        mounted.setdefault(sandbox["claim"], []).append(sandbox["name"])
    table = Table(box=box.SIMPLE, expand=True, header_style="bold magenta")
    table.add_column("PVC", ratio=3, no_wrap=True)
    table.add_column("Mode", ratio=1)
    table.add_column("Class", ratio=2)
    table.add_column("Size", ratio=1)
    table.add_column("Mounted by", ratio=3)
    workspace_claims = {row["claim"] for row in sandboxes if row["claim"] != "-"}
    shown = 0
    for pvc in pvcs:
        meta, spec, status = pvc.get("metadata", {}), pvc.get("spec", {}), pvc.get("status", {})
        name = meta.get("name", "?")
        if workspace_claims and name not in workspace_claims:
            continue
        table.add_row(
            name,
            ",".join(spec.get("accessModes", [])) or "-",
            spec.get("storageClassName", "-"),
            status.get("capacity", {}).get("storage", "-"),
            ", ".join(mounted.get(name, [])) or "-",
        )
        shown += 1
    if not shown:
        table.add_row("No mounted workspace PVCs found", "", "", "", "")
    topology = "SHARED" if len(workspace_claims) == 1 and len(sandboxes) > 1 else "PER-SANDBOX"
    return Panel(table, title=f"Workspace PVC topology — {topology}", border_style="bright_magenta")


def log_panel(title: str, lines: list[str], style: str) -> Panel:
    text = Text("\n".join(lines) or "Waiting for output…", style=style, overflow="ellipsis")
    return Panel(text, title=title, border_style=style)


@dataclass(frozen=True)
class RunInfo:
    log_file: Path
    act: str
    model: str
    started: int | None
    ended: int | None
    state: str
    exit_code: int | None = None

    @property
    def elapsed(self) -> int:
        if self.started is None:
            return 0
        return max(0, (self.ended or int(time.time())) - self.started)


def render(
    state: dict[str, Any], run: RunInfo, peak_harness: int, peak_workers: int,
) -> Layout:
    layout = Layout()
    layout.split_column(Layout(name="header", size=3), Layout(name="pipeline", size=4), Layout(name="body", size=28), Layout(name="logs"))
    layout["body"].split_row(Layout(name="compute", ratio=3), Layout(name="storage", ratio=2))
    layout["compute"].split_column(Layout(name="harness", size=9), Layout(name="workers", size=9), Layout(name="sandboxes", size=10))
    layout["storage"].split_column(Layout(name="workspace"), Layout(name="pvcs", size=9))
    layout["logs"].split_row(Layout(name="phases", ratio=3), Layout(name="tail", ratio=2))

    status = {
        "waiting": "[bold cyan]WAITING FOR NEXT RUN[/]",
        "running": "[bold yellow]RUNNING[/]",
        "complete": "[bold green]RUN COMPLETE[/]",
        "failed": f"[bold red]RUN FAILED (exit {run.exit_code if run.exit_code is not None else '?'})[/]",
    }[run.state]
    duration = f"{run.elapsed}s" if run.started is not None else "—"
    act_label = {
        "act1": "ACT 1 · synchronous leaves",
        "act2": "ACT 2 · KEDA-scaled leaves",
    }.get(run.act, run.act.upper())
    layout["header"].update(
        Panel(
            Align.center(
                f"[bold]BugStone + Shared GPFS[/]   [cyan]{act_label}[/]   elapsed {duration}   "
                f"[dim]{run.model}[/]   {status}"
            ),
            style="white on dark_blue",
        )
    )
    stage, detail = state["log"]["stage"]
    flow = (
        "Phase A  →  Prepare  →  Publish  →  Queue  →  KEDA verify  →  Reconcile  →  Report"
        if run.act == "act2"
        else "Phase A  →  Prepare  →  Publish  →  Synchronous leaf verification  →  Report"
    )
    stage_status = {
        "waiting": f"[bold cyan]○ READY[/]  {detail}",
        "running": f"[bold yellow]▶ {stage}[/]  {detail}",
        "complete": f"[bold green]✓ {stage}[/]  {detail}",
        "failed": f"[bold red]✗ FAILED during {stage}[/]  {detail}",
    }[run.state]
    layout["pipeline"].update(Panel(f"[dim]{flow}[/]\n{stage_status}", title=f"{act_label} pipeline"))
    layout["harness"].update(pod_table(f"Knative harness pods — current {len(state['harness'])}, peak {peak_harness}", state["harness"][:5], "scaled to zero"))
    layout["workers"].update(pod_table(f"KEDA leaf workers — current {len(state['workers'])}, peak {peak_workers}, queue {state['queue']}", state["workers"][:5], "none (expected during Act 1)"))

    sandboxes = Table(box=box.SIMPLE, expand=True)
    sandboxes.add_column("Sandbox", style="cyan")
    sandboxes.add_column("Node")
    sandboxes.add_column("Shared claim", style="magenta")
    for row in state["sandboxes"]:
        sandboxes.add_row(row["name"], row["node"], row["claim"])
    layout["sandboxes"].update(Panel(sandboxes, title="Sandbox pool", border_style="blue"))
    layout["workspace"].update(storage_panel(state["storage"]))
    layout["pvcs"].update(pvc_panel(state["pvcs"], state["sandboxes"]))
    layout["phases"].update(phases_panel(state["log"]["tail_full"], run.state))
    layout["tail"].update(log_panel(f"BugStone log — {run.log_file.name}", state["log"]["tail"], "white"))
    return layout


def latest_run(log_dir: Path) -> RunInfo:
    """Return the newest run log and the metadata written by the runner."""
    logs = list(log_dir.glob("act[12]-*.log"))
    if not logs:
        return RunInfo(log_dir / "waiting.log", "no active run", "start Act 1 or Act 2", None, None, "waiting")
    log_file = max(logs, key=lambda path: path.stat().st_mtime)
    metadata: dict[str, str] = {}
    try:
        for line in Path(f"{log_file}.meta").read_text().splitlines():
            key, value = line.split("=", 1)
            metadata[key] = value
    except (OSError, ValueError):
        pass
    act = metadata.get("act", log_file.name.split("-", 1)[0])
    model = metadata.get("model", "unknown")
    started = int(metadata.get("started", int(log_file.stat().st_mtime)))
    status_file = Path(f"{log_file}.status")
    exit_code: int | None = None
    if status_file.exists():
        try:
            exit_code = int(status_file.read_text().strip())
        except (OSError, ValueError):
            pass
    state = metadata.get("state", "running")
    if exit_code is not None:
        state = "complete" if exit_code == 0 else "failed"
    ended = int(metadata["ended"]) if metadata.get("ended", "").isdigit() else None
    if state in {"complete", "failed"} and ended is None:
        ended = int(status_file.stat().st_mtime)
    return RunInfo(log_file, act, model, started, ended, state, exit_code)


async def run_dashboard(
    log_dir: Path,
    context: str,
    namespace: str,
    service: str,
    pool_selector: str,
    interval: float,
) -> None:
    active_log: Path | None = None
    peak_harness = 0
    peak_workers = 0
    with Live(screen=True, auto_refresh=False, redirect_stdout=False, redirect_stderr=False) as live:
        while True:
            run = latest_run(log_dir)
            if run.log_file != active_log:
                active_log = run.log_file
                peak_harness = 0
                peak_workers = 0
            state = await gather(context, namespace, service, pool_selector, run.log_file)
            peak_harness = max(peak_harness, len(state["harness"]))
            peak_workers = max(peak_workers, len(state["workers"]))
            live.update(
                render(
                    state, run, peak_harness, peak_workers,
                ),
                refresh=True,
            )
            await asyncio.sleep(interval)


@click.command()
@click.option("--log-dir", type=click.Path(path_type=Path), required=True)
@click.option("--context", default="agentic-cloud", show_default=True)
@click.option("--namespace", default="serverless-harness", show_default=True)
@click.option("--service", default="serverless-harness", show_default=True)
@click.option("--pool-selector", default="sh.kagenti.io/sandbox-pool=default", show_default=True)
@click.option("--interval", type=click.FloatRange(min=0.5), default=2.0, show_default=True)
def main(**kwargs: Any) -> None:
    """Watch for BugStone runs and render them in a persistent dashboard."""
    signal.signal(signal.SIGTERM, lambda *_: raise_keyboard_interrupt())
    try:
        asyncio.run(run_dashboard(**kwargs))
    except KeyboardInterrupt:
        pass


def raise_keyboard_interrupt() -> None:
    raise KeyboardInterrupt


if __name__ == "__main__":
    main()
