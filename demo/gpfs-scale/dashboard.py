#!/usr/bin/env python3
"""Live Rich dashboard for the BugStone shared-GPFS demo."""

from __future__ import annotations

import asyncio
import json
import os
import re
import signal
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
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


def kubernetes_age(timestamp: str | None) -> str:
    """Format an RFC 3339 creation time like kubectl's compact AGE column."""
    if not timestamp:
        return "-"
    try:
        created = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return "-"
    seconds = max(0, int((datetime.now(timezone.utc) - created).total_seconds()))
    if seconds < 60:
        return f"{seconds}s"
    minutes = seconds // 60
    if minutes < 60:
        return f"{minutes}m"
    hours = minutes // 60
    if hours < 24:
        return f"{hours}h"
    return f"{hours // 24}d"


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
                # Kubernetes leaves status.phase=Running while graceful pod
                # deletion is in progress; deletionTimestamp is authoritative.
                "phase": "Terminating" if meta.get("deletionTimestamp") else status.get("phase", "?"),
                "ready": ready,
                "age": kubernetes_age(meta.get("creationTimestamp")),
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
    table.add_column("Phase", width=18, style="bold cyan", no_wrap=True)
    table.add_column("Purpose", ratio=1)

    def add(state: str, phase: str, purpose: str) -> None:
        icon, style = {
            "done": ("✓", "green"),
            "active": ("▶", "bold yellow"),
            "pending": ("○", "dim"),
            "not-run": ("—", "dim"),
        }[state]
        table.add_row(f"[{style}]{icon}[/]", phase, f"[{style}]{purpose}[/]")

    add("done" if phase_b_started else "active", "Phase A", "Deterministic candidate scan")
    add(
        "done" if phase_b_done else "active" if phase_b_started else "pending",
        "Phase B",
        "LLM verification in isolated leaf sessions",
    )
    # The serverless-harness demo stops after Phase B. Keep the remainder visible
    # so viewers see where this experiment sits in the complete BugStone pipeline.
    add("not-run", "Phase C Triage", "Filter false positives (not run)")
    add("not-run", "Phase C Validation", "Validate exploitability (not run)")
    add("not-run", "Phase D", "Reports and patches (not run)")

    report_state = "done" if run_state == "complete" and phase_b_done else "active" if run_state == "complete" else "pending"
    report_icon = {"done": "[green]✓[/]", "active": "[yellow]▶[/]", "pending": "[dim]○[/]"}[report_state]
    footer = Text.from_markup(f"  {report_icon}  [bold cyan]Report[/]  Demo Phase A/B HTML report")
    return Panel(Group(table, footer), title="BugStone pipeline", border_style="green")


async def gather(
    context: str, namespace: str, service: str, pool_selector: str, log_file: Path
) -> dict[str, Any]:
    storage_script = r"""
for entry in /workspace/* /workspace/.[!.]*; do
  [ -e "$entry" ] || continue
  name=${entry#/workspace/}; [ -d "$entry" ] && name="$name/"
  printf 'ENTRY|%s\n' "$name"
done
printf 'DISK|%s\n' "$(df -h /workspace 2>/dev/null | awk 'NR==2 {print $2 " total · " $3 " used · " $4 " free"}')"
printf 'REPO_BEGIN\n'
ls -la /workspace/repo 2>&1 | head -n 12 | sed 's/^/REPO|/'
printf 'WORKTREES_BEGIN\n'
git -C /workspace/repo worktree list --porcelain 2>&1 | head -n 40 | sed 's/^/WORKTREE|/'
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
    table = Table(box=box.SIMPLE, expand=True, show_header=True, header_style="bold cyan", padding=(0, 1))
    table.add_column("Pod", ratio=1, no_wrap=True, overflow="ellipsis")
    table.add_column("Phase", width=10, no_wrap=True)
    table.add_column("Ready", width=5, no_wrap=True)
    table.add_column("Age", width=5, no_wrap=True)
    table.add_column("Node", width=14, no_wrap=True, overflow="ellipsis")
    if rows:
        for row in rows:
            color = "green" if row["phase"] == "Running" else "red" if row["phase"] == "Terminating" else "yellow"
            table.add_row(row["name"], f"[{color}]{row['phase']}[/]", row["ready"], row["age"], row["node"])
    else:
        table.add_row(f"[dim]{empty}[/]", "", "", "", "")
    return Panel(table, title=title, border_style="cyan")


def storage_panel(lines: list[str]) -> Panel:
    entries: list[str] = []
    disk = "unavailable"
    for line in lines:
        kind, _, value = line.partition("|")
        if kind == "ENTRY":
            entries.append(value)
        elif kind == "DISK":
            disk = value or "unavailable"
    stats = Table.grid(expand=True, padding=(0, 1))
    stats.add_column(style="bold magenta", width=12, no_wrap=True)
    stats.add_column(ratio=1, no_wrap=True, overflow="ellipsis")
    stats.add_row("Filesystem", "IBM Storage Scale / GPFS")
    stats.add_row("Capacity", disk)
    tree = Text("\n/workspace/\n", style="bold", overflow="ellipsis", no_wrap=True)
    for entry in entries[:12]:
        tree.append(f"  ├── {entry}\n", style="bright_blue" if entry.endswith("/") else "white")
    return Panel(Group(stats, tree), title="Shared GPFS filesystem — live", border_style="magenta")


def git_panel(lines: list[str]) -> Panel:
    repo = [line.partition("|")[2] for line in lines if line.startswith("REPO|")]
    raw_worktrees = [line.partition("|")[2] for line in lines if line.startswith("WORKTREE|")]
    text = Text()
    text.append("$ ls -la /workspace/repo\n", style="bold cyan")
    text.append("\n".join(repo) or "repository not initialized", style="white")
    text.append("\n\n$ git -C /workspace/repo worktree list\n", style="bold cyan")

    records: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in raw_worktrees + [""]:
        if not line:
            if current:
                records.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value or "yes"

    table = Table(box=None, expand=True, show_header=True, header_style="bold yellow", padding=(0, 1))
    table.add_column("Kind", width=7, no_wrap=True)
    table.add_column("Checkout / candidate", ratio=1, no_wrap=True, overflow="ellipsis")
    table.add_column("Commit", width=8, no_wrap=True)
    table.add_column("State", width=13, no_wrap=True)
    for record in records:
        path = record.get("worktree", "?")
        commit = record.get("HEAD", "-")[:7]
        if path == "/workspace/repo":
            label = "/workspace/repo (.git object store)"
            state = "initializing" if commit == "0000000" else record.get("branch", "base").removeprefix("refs/heads/")
            kind = "Base"
        else:
            leaf = path.removeprefix("/workspace/leaves/")
            label = re.sub(r"^run-\d+-", "", leaf).replace("--", " · ")
            state = "detached" if "detached" in record else record.get("branch", "worktree").removeprefix("refs/heads/")
            kind = "Leaf"
        table.add_row(kind, label, commit, state)
    if not records:
        table.add_row("—", "No repository/worktrees yet", "—", "waiting")
    return Panel(Group(text, table), title="Shared Git repository + leaf worktrees", border_style="cyan")


def pvc_panel(pvcs: list[dict[str, Any]], sandboxes: list[dict[str, str]]) -> Panel:
    mounted: dict[str, list[str]] = {}
    for sandbox in sandboxes:
        mounted.setdefault(sandbox["claim"], []).append(sandbox["name"])
    table = Table(box=box.SIMPLE, expand=True, header_style="bold magenta", padding=(0, 1))
    table.add_column("PVC", ratio=3, no_wrap=True, overflow="ellipsis")
    table.add_column("Mode", width=4, no_wrap=True)
    table.add_column("Class", width=13, no_wrap=True, overflow="ellipsis")
    table.add_column("Size", width=5, no_wrap=True)
    table.add_column("Sandboxes", ratio=2, no_wrap=True, overflow="ellipsis")
    workspace_claims = {row["claim"] for row in sandboxes if row["claim"] != "-"}
    shown = 0
    for pvc in pvcs:
        meta, spec, status = pvc.get("metadata", {}), pvc.get("spec", {}), pvc.get("status", {})
        name = meta.get("name", "?")
        if workspace_claims and name not in workspace_claims:
            continue
        table.add_row(
            name,
            ",".join({"ReadWriteMany": "RWX", "ReadWriteOnce": "RWO", "ReadOnlyMany": "ROX"}.get(mode, mode) for mode in spec.get("accessModes", [])) or "-",
            spec.get("storageClassName", "-"),
            status.get("capacity", {}).get("storage", "-"),
            ", ".join(
                sandbox.removeprefix("sandbox-") if sandbox.startswith("sandbox-") else sandbox
                for sandbox in mounted.get(name, [])
            ) or "-",
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
    layout.split_column(
        Layout(name="header", size=3),
        Layout(name="pipeline", size=4),
        Layout(name="body"),
        Layout(name="logs", size=9),
    )
    layout["body"].split_row(Layout(name="compute", ratio=11), Layout(name="storage", ratio=9))
    layout["compute"].split_column(
        Layout(name="harness", ratio=3),
        Layout(name="workers", ratio=3),
        Layout(name="sandboxes", ratio=2),
    )
    layout["storage"].split_column(
        Layout(name="workspace", ratio=1),
        Layout(name="git", ratio=1),
        Layout(name="pvcs", size=9),
    )
    layout["logs"].split_row(Layout(name="phases", ratio=11), Layout(name="tail", ratio=9))

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
                f"[bold]BugStone + GPFS[/]  [cyan]{act_label}[/]  {duration}  "
                f"[dim]{run.model}[/]  {status}"
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
    layout["harness"].update(pod_table(f"Knative harness — {len(state['harness'])} now / {peak_harness} peak", state["harness"][:6], "scaled to zero"))
    layout["workers"].update(pod_table(f"KEDA workers — {len(state['workers'])} now / {peak_workers} peak / queue {state['queue']}", state["workers"][:6], "none (expected during Act 1)"))

    sandboxes = Table(box=box.SIMPLE, expand=True)
    sandboxes.add_column("Sandbox", width=10, style="cyan", no_wrap=True, overflow="ellipsis")
    sandboxes.add_column("Node", width=14, no_wrap=True, overflow="ellipsis")
    sandboxes.add_column("Shared claim", ratio=1, style="magenta", no_wrap=True, overflow="ellipsis")
    for row in state["sandboxes"]:
        sandboxes.add_row(row["name"], row["node"], row["claim"])
    layout["sandboxes"].update(Panel(sandboxes, title="Sandbox pool", border_style="blue"))
    layout["workspace"].update(storage_panel(state["storage"]))
    layout["git"].update(git_panel(state["storage"]))
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
    watch: bool,
) -> None:
    active_log: Path | None = None
    peak_harness = 0
    peak_workers = 0
    source_file = Path(__file__)
    source_mtime = source_file.stat().st_mtime_ns
    with Live(screen=True, auto_refresh=False, redirect_stdout=False, redirect_stderr=False) as live:
        while True:
            if watch and source_file.stat().st_mtime_ns != source_mtime:
                raise ReloadDashboard
            run = latest_run(log_dir)
            if run.log_file != active_log:
                active_log = run.log_file
                peak_harness = 0
                peak_workers = 0
            state = await gather(context, namespace, service, pool_selector, run.log_file)
            peak_harness = max(peak_harness, len(state["harness"]))
            peak_workers = max(peak_workers, len(state["workers"]))
            live.update(
                render(state, run, peak_harness, peak_workers),
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
@click.option("--watch/--no-watch", default=True, show_default=True, help="Reload when dashboard.py changes.")
def main(**kwargs: Any) -> None:
    """Watch for BugStone runs and render them in a persistent dashboard."""
    signal.signal(signal.SIGTERM, lambda *_: raise_keyboard_interrupt())
    try:
        asyncio.run(run_dashboard(**kwargs))
    except ReloadDashboard:
        os.execv(sys.executable, [sys.executable, *sys.argv])
    except KeyboardInterrupt:
        pass


def raise_keyboard_interrupt() -> None:
    raise KeyboardInterrupt


class ReloadDashboard(Exception):
    """Request a clean process reload after the dashboard source changes."""


if __name__ == "__main__":
    main()
