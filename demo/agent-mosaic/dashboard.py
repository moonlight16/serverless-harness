#!/usr/bin/env python3
"""Live terminal dashboard for the Agent Mosaic producer/consumer demo."""

from __future__ import annotations

import asyncio
import json
import os
import signal
import sys
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
from rich.progress_bar import ProgressBar
from rich.table import Table
from rich.text import Text


async def command(*args: str, timeout: float = 8) -> str:
    try:
        proc = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
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


def age(timestamp: str | None) -> str:
    if not timestamp:
        return "-"
    try:
        created = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return "-"
    seconds = max(0, int((datetime.now(timezone.utc) - created).total_seconds()))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    return f"{seconds // 3600}h"


def latest_run(output_dir: Path) -> tuple[Path | None, dict[str, Any]]:
    runs = [path for path in output_dir.glob("*") if path.is_dir()]
    if not runs:
        return None, {"state": "waiting", "stage": "waiting"}
    run = max(runs, key=lambda path: path.stat().st_mtime)
    try:
        state = json.loads((run / "state.json").read_text())
    except (OSError, json.JSONDecodeError):
        state = {
            "runId": run.name,
            "state": "complete" if (run / "mosaic.html").exists() else "unknown",
            "stage": "complete" if (run / "mosaic.html").exists() else "unknown",
            "claim": "agent-mosaic-workspace",
            "count": len(list((run / "responses").glob("*.json"))),
            "sandboxes": "-",
            "parallel": "-",
            "model": "unknown",
            "writerId": f"{run.name}-writer",
            "readerId": f"{run.name}-readers",
        }
    return run, state


def selector(state: dict[str, Any]) -> str:
    ids = [state.get("writerId"), state.get("readerId")]
    ids = [value for value in ids if value]
    return f"context.rossoctl.io/pool in ({','.join(ids)})" if ids else "context.rossoctl.io/pool=mosaic-none"


def pod_rows(payload: Any) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for pod in payload.get("items", []) if isinstance(payload, dict) else []:
        meta, spec, status = pod.get("metadata", {}), pod.get("spec", {}), pod.get("status", {})
        containers = status.get("containerStatuses") or []
        mount = next(
            (
                mount
                for container in spec.get("containers", [])
                for mount in container.get("volumeMounts", [])
                if mount.get("name") == "workspace"
            ),
            {},
        )
        claim = next(
            (
                volume.get("persistentVolumeClaim", {}).get("claimName", "-")
                for volume in spec.get("volumes", [])
                if volume.get("name") == "workspace"
            ),
            "-",
        )
        rows.append(
            {
                "name": meta.get("name", "?"),
                "phase": "Terminating" if meta.get("deletionTimestamp") else status.get("phase", "?"),
                "ready": f"{sum(bool(c.get('ready')) for c in containers)}/{len(containers)}",
                "node": spec.get("nodeName", "-"),
                "claim": claim,
                "access": "RO" if mount.get("readOnly") else "RW",
                "age": age(meta.get("creationTimestamp")),
            }
        )
    return rows


def sandbox_rows(payload: Any) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for item in payload.get("items", []) if isinstance(payload, dict) else []:
        meta = item.get("metadata", {})
        annotations = meta.get("annotations", {})
        rows.append(
            {
                "name": meta.get("name", "?"),
                "pool": meta.get("labels", {}).get("context.rossoctl.io/pool", "-"),
                "claim": annotations.get("context.rossoctl.io/workspace-claim", "managed"),
                "access": "RO" if annotations.get("context.rossoctl.io/workspace-read-only") == "true" else "RW",
                "age": age(meta.get("creationTimestamp")),
            }
        )
    return rows


async def gather(context: str, namespace: str, run: Path | None, state: dict[str, Any]) -> dict[str, Any]:
    label = selector(state)
    claim = str(state.get("claim") or "agent-mosaic-workspace")
    pods_task = kubectl_json(context, namespace, "get", "pods", "-l", label, "-o", "json")
    sandboxes_task = kubectl_json(context, namespace, "get", "sandboxes", "-l", label, "-o", "json")
    pvcs_task = kubectl_json(context, namespace, "get", "pvc", "-o", "json")
    pvs_task = kubectl_json(context, namespace, "get", "pv", "-o", "json")
    harness_task = kubectl_json(
        context, namespace, "get", "pods", "-l", "serving.knative.dev/service=serverless-harness", "-o", "json"
    )
    pods, sandboxes, pvcs, pvs, harness = await asyncio.gather(
        pods_task, sandboxes_task, pvcs_task, pvs_task, harness_task
    )
    rows = pod_rows(pods)
    storage_pod = rows[0]["name"] if rows else "agent-mosaic-storage-viewer"
    storage_script = r"""
printf 'DISK|%s\n' "$(df -h /workspace 2>/dev/null | awk 'NR==2 {print $2 " total · " $3 " used · " $4 " free"}')"
find /workspace -maxdepth 2 -mindepth 1 -print 2>/dev/null | sort | head -n 28 | while read -r path; do
  if [ -d "$path" ]; then kind=d; else kind=f; fi
  printf '%s|%s|%s\n' "$kind" "$path" "$(stat -c %s "$path" 2>/dev/null || echo 0)"
done
"""
    storage = await command(
        "kubectl", "--context", context, "-n", namespace, "exec", storage_pod, "--", "sh", "-c", storage_script
    )
    response_count = len(list((run / "responses").glob("*.json"))) if run else 0
    events = []
    if run:
        try:
            events = (run / "events.log").read_text(errors="replace").splitlines()[-8:]
        except OSError:
            pass
    return {
        "pods": rows,
        "sandboxes": sandbox_rows(sandboxes),
        "pvcs": pvcs.get("items", []) if isinstance(pvcs, dict) else [],
        "storage_meta": storage_metadata(pvcs, pvs, claim),
        "harness": pod_rows(harness),
        "storage": storage.splitlines(),
        "responses": response_count,
        "events": events,
    }


def storage_metadata(pvcs: Any, pvs: Any, claim: str) -> dict[str, str]:
    pvc_items = pvcs.get("items", []) if isinstance(pvcs, dict) else []
    pv_items = pvs.get("items", []) if isinstance(pvs, dict) else []
    volume = next(
        (
            item.get("spec", {}).get("volumeName", "")
            for item in pvc_items
            if item.get("metadata", {}).get("name") == claim
        ),
        "",
    )
    pv = next((item for item in pv_items if item.get("metadata", {}).get("name") == volume), {})
    csi = pv.get("spec", {}).get("csi", {})
    attributes = csi.get("volumeAttributes", {})
    handle_parts = dict(
        part.split("=", 1) for part in csi.get("volumeHandle", "").split(";") if "=" in part
    )
    return {
        "pv": volume or "-",
        "driver": csi.get("driver", "-"),
        "filesystem": attributes.get("volBackendFs", "-"),
        "fileset": handle_parts.get("filesetName", "-"),
        "path": handle_parts.get("path", "-"),
    }


def pods_panel(rows: list[dict[str, str]], harness: list[dict[str, str]]) -> Panel:
    table = Table(box=box.SIMPLE, expand=True, header_style="bold cyan", padding=(0, 1))
    table.add_column("Pod", ratio=3, overflow="ellipsis", no_wrap=True)
    table.add_column("Phase", width=11)
    table.add_column("Access", width=6)
    table.add_column("Node", ratio=2, overflow="ellipsis", no_wrap=True)
    table.add_column("Age", width=5)
    for row in rows:
        color = "green" if row["phase"] == "Running" else "yellow"
        table.add_row(row["name"], f"[{color}]{row['phase']}[/]", row["access"], row["node"], row["age"])
    if not rows:
        table.add_row("[dim]No active mosaic pods[/]", "", "", "", "")
    subtitle = f"Knative harness: {len(harness)} active"
    return Panel(table, title=f"Sandbox Pods — {len(rows)} active", subtitle=subtitle, border_style="cyan")


def sandboxes_panel(rows: list[dict[str, str]]) -> Panel:
    table = Table(box=box.SIMPLE, expand=True, header_style="bold blue", padding=(0, 1))
    table.add_column("Sandbox CR", ratio=3, overflow="ellipsis", no_wrap=True)
    table.add_column("Pool", ratio=2, overflow="ellipsis", no_wrap=True)
    table.add_column("Access", width=6)
    table.add_column("Age", width=5)
    for row in rows:
        table.add_row(row["name"], row["pool"], row["access"], row["age"])
    if not rows:
        table.add_row("[dim]Released after workload completion[/]", "", "", "")
    return Panel(table, title=f"Sandbox resources — {len(rows)}", border_style="blue")


def pvc_panel(pvcs: list[dict[str, Any]], claim: str) -> Panel:
    table = Table(box=box.SIMPLE, expand=True, header_style="bold magenta", padding=(0, 1))
    table.add_column("PVC", ratio=3, overflow="ellipsis", no_wrap=True)
    table.add_column("Status", width=8)
    table.add_column("Mode", width=5)
    table.add_column("Class", ratio=2)
    table.add_column("Size", width=6)
    found = False
    for pvc in pvcs:
        meta, spec, status = pvc.get("metadata", {}), pvc.get("spec", {}), pvc.get("status", {})
        if meta.get("name") != claim:
            continue
        modes = {"ReadWriteMany": "RWX", "ReadWriteOnce": "RWO", "ReadOnlyMany": "ROX"}
        table.add_row(
            claim, status.get("phase", "-"),
            ",".join(modes.get(mode, mode) for mode in spec.get("accessModes", [])),
            spec.get("storageClassName", "-"), status.get("capacity", {}).get("storage", "-"),
        )
        found = True
    if not found:
        table.add_row(claim or "No claim selected", "-", "-", "-", "-")
    return Panel(table, title="Durable Context Service workspace", border_style="magenta")


def filesystem_panel(lines: list[str], metadata: dict[str, str]) -> Panel:
    disk = "unavailable"
    entries: list[tuple[str, str, str]] = []
    for line in lines:
        parts = line.split("|", 2)
        if len(parts) == 2 and parts[0] == "DISK":
            disk = parts[1] or "unavailable"
        elif len(parts) == 3 and parts[0] in {"d", "f", "l"}:
            entries.append((parts[0], parts[1].removeprefix("/workspace/"), parts[2]))
    text = Text()
    text.append(
        f"Filesystem: {metadata.get('filesystem', '-')}  ·  Fileset: {metadata.get('fileset', '-')}\n",
        style="bold magenta",
    )
    text.append(f"Mounted capacity: {disk}\n", style="magenta")
    text.append("/workspace/\n", style="bold")
    for kind, path, size in entries[:18]:
        icon = "📁" if kind == "d" else "◆"
        style = "bright_blue" if kind == "d" else "white"
        suffix = "/" if kind == "d" else f"  [dim]{size} B[/]"
        text.append(f"  {icon} {path}{suffix}\n", style=style)
    if not entries:
        text.append("  waiting for a mounted workspace…", style="dim")
    return Panel(text, title="GPFS filesystem — live", border_style="bright_magenta")


def settings_panel(state: dict[str, Any], context: str, namespace: str) -> Panel:
    table = Table.grid(expand=True, padding=(0, 1))
    table.add_column(style="bold cyan", width=13)
    table.add_column(ratio=1, overflow="ellipsis", no_wrap=True)
    settings = [
        ("Run", state.get("runId", "waiting")),
        ("Context", context), ("Namespace", namespace),
        ("PVC", state.get("claim", "-")),
        ("Consumers", str(state.get("count", "-"))),
        ("Sandboxes", str(state.get("sandboxes", "-"))),
        ("Parallel", str(state.get("parallel", "-"))),
        ("Model", state.get("model", "-")),
    ]
    for key, value in settings:
        table.add_row(key, str(value))
    return Panel(table, title="Run settings", border_style="cyan")


def progress_panel(state: dict[str, Any], gathered: dict[str, Any], run: Path | None) -> Panel:
    total = int(state.get("count", 0) or 0)
    done = gathered["responses"]
    grid = Table.grid(expand=True)
    grid.add_column(ratio=1)
    grid.add_column(width=13, justify="right")
    grid.add_row(ProgressBar(total=max(1, total), completed=min(done, max(1, total)), width=None), f"{done}/{total} agents")
    artifacts = []
    if run:
        for name in ("world-brief.md", "responses.json", "mosaic.html"):
            artifacts.append(("✓" if (run / name).exists() else "○") + " " + name)
    detail = Text("   ".join(artifacts), style="green" if state.get("state") == "complete" else "yellow")
    return Panel(Group(grid, detail), title="Agent fan-out and artifacts", border_style="green")


def render(run: Path | None, state: dict[str, Any], gathered: dict[str, Any], context: str, namespace: str) -> Layout:
    layout = Layout()
    layout.split_column(Layout(name="header", size=3), Layout(name="flow", size=5), Layout(name="body"), Layout(name="bottom", size=10))
    layout["body"].split_row(Layout(name="compute", ratio=11), Layout(name="context", ratio=9))
    layout["compute"].split_column(Layout(name="pods"), Layout(name="sandboxes"))
    layout["context"].split_column(Layout(name="pvc", size=8), Layout(name="filesystem"), Layout(name="settings", size=12))
    layout["bottom"].split_row(Layout(name="progress", ratio=3), Layout(name="events", ratio=2))

    status_style = {"running": "bold yellow", "complete": "bold green", "failed": "bold red", "waiting": "bold cyan"}.get(state.get("state"), "bold white")
    layout["header"].update(Panel(Align.center(Text.from_markup(
        f"[bold]Agent Mosaic[/]  ·  [cyan]Serverless Harness + Context Service + GPFS[/]  ·  [{status_style}]{str(state.get('state', 'waiting')).upper()}[/]"
    )), style="white on dark_blue"))
    stages = ["producer", "handoff", "consumers", "render", "complete"]
    current = state.get("stage", "waiting")
    current_index = stages.index(current) if current in stages else -1
    labels = ["Producer (RW)", "Release + handoff", "Consumers (RO)", "Render mosaic", "Complete"]
    flow = []
    for index, label in enumerate(labels):
        if state.get("state") == "failed" and index == current_index:
            flow.append(f"[red]✗ {label}[/]")
        elif index < current_index or state.get("state") == "complete":
            flow.append(f"[green]✓ {label}[/]")
        elif index == current_index:
            flow.append(f"[bold yellow]▶ {label}[/]")
        else:
            flow.append(f"[dim]○ {label}[/]")
    layout["flow"].update(Panel("  →  ".join(flow) + "\n[dim]One agent writes durable context; many agents consume it without modification.[/]", title="Context lifecycle"))
    layout["pods"].update(pods_panel(gathered["pods"], gathered["harness"]))
    layout["sandboxes"].update(sandboxes_panel(gathered["sandboxes"]))
    layout["pvc"].update(pvc_panel(gathered["pvcs"], state.get("claim", "")))
    layout["filesystem"].update(filesystem_panel(gathered["storage"], gathered["storage_meta"]))
    layout["settings"].update(settings_panel(state, context, namespace))
    layout["progress"].update(progress_panel(state, gathered, run))
    events = "\n".join(gathered["events"]) or "Waiting for the next run…"
    layout["events"].update(Panel(Text(events, overflow="ellipsis"), title="Lifecycle events", border_style="yellow"))
    return layout


class ReloadDashboard(Exception):
    pass


async def run_dashboard(output_dir: Path, context: str, namespace: str, interval: float, watch: bool) -> None:
    source = Path(__file__)
    mtime = source.stat().st_mtime_ns
    with Live(screen=True, auto_refresh=False, redirect_stdout=False, redirect_stderr=False) as live:
        while True:
            if watch and source.stat().st_mtime_ns != mtime:
                raise ReloadDashboard
            run, state = latest_run(output_dir)
            gathered = await gather(context, namespace, run, state)
            live.update(render(run, state, gathered, context, namespace), refresh=True)
            await asyncio.sleep(interval)


@click.command()
@click.option("--output-dir", type=click.Path(path_type=Path), required=True)
@click.option("--context", default="agentic-cloud", show_default=True)
@click.option("--namespace", default="serverless-harness", show_default=True)
@click.option("--interval", type=click.FloatRange(min=0.5), default=1.5, show_default=True)
@click.option("--watch/--no-watch", default=True, show_default=True)
def main(**kwargs: Any) -> None:
    signal.signal(signal.SIGTERM, raise_keyboard_interrupt)
    try:
        asyncio.run(run_dashboard(**kwargs))
    except ReloadDashboard:
        os.execv(sys.executable, [sys.executable, *sys.argv])
    except KeyboardInterrupt:
        pass


def raise_keyboard_interrupt(*_: Any) -> None:
    raise KeyboardInterrupt


if __name__ == "__main__":
    main()
