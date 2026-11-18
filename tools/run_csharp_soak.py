#!/usr/bin/env python3
"""B23, the C# stability soak (docs/csharp-benchmark-plan.md): an exported Release player of Samples/CSharpBench
runs its soak mode (Samples/CSharpBench/src/Scripts/Soak.cs) for a long time: Mover cubes, physics balls, soft
bodies torn down and made again, scripted objects made and destroyed every few frames, network crates spawned and
despawned, and the scene reloaded every cycle. With --net (the default) a host and a client run together; the host's
session restarts with every reload, so the client is dropped and joins again each time.

Build the player first (a copy of Samples/CSharpBench whose project.tallow points at this engine):
    python3 tools/build_player.py COPY --output OUT --config Release --csharp-runtime jit
Then:
    python3 tools/run_csharp_soak.py --player OUT/CSharpBench --minutes 45 --output DIR

DIR gets host.jsonl / client.jsonl (the players' one-a-second samples), host.log / client.log, proc.jsonl (each
process's RSS from /proc every 5 s, as the OS sees it) and summary.md / summary.json: frame time per 5-minute
window, the slope of RSS, managed heap, open files and threads after the warm-up, scene loads, reconnects, and
whether either player crashed or logged an exception. Exit 1 when a player crashed, logged an error, failed to
join, or memory grew past --max-rss-slope MB an hour.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time


def rss_mb(pid: int) -> float | None:
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024
    except OSError:
        return None
    return None


def slope_per_hour(points: list[tuple[float, float]]) -> float:
    """Least-squares slope of (seconds, value), in value per hour."""
    if len(points) < 3:
        return 0.0
    n = len(points)
    mx = sum(p[0] for p in points) / n
    my = sum(p[1] for p in points) / n
    sxx = sum((p[0] - mx) ** 2 for p in points)
    if sxx == 0:
        return 0.0
    return sum((p[0] - mx) * (p[1] - my) for p in points) / sxx * 3600


def read_rows(path: Path) -> tuple[list[dict], dict | None]:
    rows, done = [], None
    if not path.exists():
        return rows, done
    for line in path.read_text().splitlines():
        if not line.startswith("{"):
            continue
        row = json.loads(line)
        if "soak_done" in row:
            done = row
        elif "soak" in row:
            rows.append(row)
    return rows, done


def summarize(role: str, rows: list[dict], done: dict | None, proc: list[tuple[float, float]], warmup: float, log: str) -> dict:
    after = [r for r in rows if r["t"] >= warmup]
    windows = []
    if rows:
        end = rows[-1]["t"]
        start = 0.0
        while start < end:
            part = [r for r in rows if start <= r["t"] < start + 300]
            if part:
                windows.append({
                    "from_min": start / 60,
                    "frame_median_ms": statistics.median(r["frame_median_ms"] for r in part),
                    "frame_p95_ms": statistics.median(r["frame_p95_ms"] for r in part),
                    "frame_p99_ms": statistics.median(r["frame_p99_ms"] for r in part),
                    "frame_worst_ms": max(r["frame_max_ms"] for r in part),
                    "rss_mb": part[-1]["rss_mb"],
                    "managed_mb_median": statistics.median(r["managed_mb"] for r in part),
                    "files": part[-1]["files"],
                    "threads": part[-1]["threads"],
                })
            start += 300
    proc_after = [p for p in proc if p[0] >= warmup]
    errors = [line for line in log.splitlines() if "[error]" in line or "Exception" in line or "FATAL" in line]
    return {
        "role": role,
        "samples": len(rows),
        "finished": done is not None,
        "done": done,
        "windows": windows,
        "rss_slope_mb_per_hour": slope_per_hour([(r["t"], r["rss_mb"]) for r in after]),
        "proc_rss_slope_mb_per_hour": slope_per_hour(proc_after),
        "managed_slope_mb_per_hour": slope_per_hour([(r["t"], r["managed_mb"]) for r in after]),
        "files_slope_per_hour": slope_per_hour([(r["t"], r["files"]) for r in after]),
        "threads_first_last": (after[0]["threads"], after[-1]["threads"]) if after else None,
        "files_first_last": (after[0]["files"], after[-1]["files"]) if after else None,
        "rss_first_last": (after[0]["rss_mb"], after[-1]["rss_mb"]) if after else None,
        "objects_min_max": (min(r["objects"] for r in after), max(r["objects"] for r in after)) if after else None,
        "disconnected_samples": sum(1 for r in rows if not r["connected"]),
        "errors": errors[:20],
        "error_count": len(errors),
    }


def write_markdown(path: Path, summaries: list[dict], args: argparse.Namespace, codes: dict) -> None:
    out = [f"# B23 stability soak ({args.minutes:g} min, reload every {args.cycle:g} s, warm-up {args.warmup:g} s excluded from slopes)", ""]
    for s in summaries:
        out.append(f"## {s['role']} (exit {codes.get(s['role'])})")
        done = s["done"] or {}
        out.append("")
        out.append(f"- finished: {s['finished']}; frames {done.get('frames')}; scene loads {done.get('loads')} "
                   f"(median {done.get('load_median_ms')} ms, p95 {done.get('load_p95_ms')} ms); reconnects {done.get('reconnects')}; "
                   f"failed joins {done.get('join_failures')}; Lifer Awake/OnDestroy {done.get('lifer_awakes')}/{done.get('lifer_destroys')}")
        out.append(f"- RSS {s['rss_first_last']} MB after warm-up; slope {s['rss_slope_mb_per_hour']:.1f} MB/h "
                   f"(from /proc: {s['proc_rss_slope_mb_per_hour']:.1f} MB/h); managed heap slope {s['managed_slope_mb_per_hour']:.2f} MB/h")
        out.append(f"- open files {s['files_first_last']} (slope {s['files_slope_per_hour']:.1f}/h); threads {s['threads_first_last']}; "
                   f"scene objects {s['objects_min_max']}; samples not connected {s['disconnected_samples']}")
        out.append(f"- errors/exceptions logged: {s['error_count']}")
        for line in s["errors"][:5]:
            out.append(f"  - `{line.strip()[:200]}`")
        out.append("")
        out.append("| from (min) | frame median ms | p95 | p99 | worst | RSS MB | managed MB | files | threads |")
        out.append("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for w in s["windows"]:
            out.append(f"| {w['from_min']:.0f} | {w['frame_median_ms']:.2f} | {w['frame_p95_ms']:.2f} | {w['frame_p99_ms']:.2f} | "
                       f"{w['frame_worst_ms']:.1f} | {w['rss_mb']:.1f} | {w['managed_mb_median']:.1f} | {w['files']} | {w['threads']} |")
        out.append("")
    out.append("Headless players: frame time is CPU work; GPU memory is not measured (no GPU in a headless run).")
    path.write_text("\n".join(out) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--player", type=Path, required=True, help="the exported CSharpBench player")
    parser.add_argument("--minutes", type=float, default=45)
    parser.add_argument("--cycle", type=float, default=25, help="seconds between scene reloads")
    parser.add_argument("--warmup", type=float, default=180, help="seconds left out of the slopes")
    parser.add_argument("--no-net", action="store_true", help="one offline player instead of a host and a client")
    parser.add_argument("--port", type=int, default=47810)
    parser.add_argument("--max-rss-slope", type=float, default=30, help="MB an hour of RSS growth that fails the run")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)
    seconds = args.minutes * 60
    roles = ["offline"] if args.no_net else ["host", "client"]
    processes: dict[str, subprocess.Popen] = {}
    logs = {}
    for role in roles:
        (args.output / f"{role}.jsonl").unlink(missing_ok=True)
        env = dict(os.environ, TALLOW_BENCH_MODE="soak", TALLOW_SOAK_ROLE=role, TALLOW_SOAK_PORT=str(args.port),
                   TALLOW_SOAK_SECONDS=str(seconds if role != "client" else seconds - 10), TALLOW_SOAK_CYCLE=str(args.cycle),
                   TALLOW_BENCH_OUT=str(args.output / f"{role}.jsonl"))
        logs[role] = open(args.output / f"{role}.log", "w")
        processes[role] = subprocess.Popen([str(args.player), "--headless"], env=env, cwd=args.player.parent,
                                           stdout=logs[role], stderr=subprocess.STDOUT)
        if role == "host":
            time.sleep(3)
    proc: dict[str, list[tuple[float, float]]] = {role: [] for role in roles}
    start = time.monotonic()
    deadline = start + seconds + 120
    with open(args.output / "proc.jsonl", "w") as proc_file:
        while any(p.poll() is None for p in processes.values()) and time.monotonic() < deadline:
            t = time.monotonic() - start
            for role, p in processes.items():
                if p.poll() is None and (value := rss_mb(p.pid)) is not None:
                    proc[role].append((t, value))
                    proc_file.write(json.dumps({"role": role, "t": round(t, 1), "rss_mb": round(value, 1)}) + "\n")
            proc_file.flush()
            time.sleep(5)
    codes = {}
    for role, p in processes.items():
        if p.poll() is None:
            p.kill()
            p.wait()
            codes[role] = "killed (timed out)"
        else:
            codes[role] = p.returncode
        logs[role].close()

    summaries = []
    for role in roles:
        rows, done = read_rows(args.output / f"{role}.jsonl")
        log = (args.output / f"{role}.log").read_text(errors="replace")
        summaries.append(summarize(role, rows, done, proc[role], args.warmup, log))
    (args.output / "summary.json").write_text(json.dumps({"codes": codes, "summaries": summaries}, indent=1))
    write_markdown(args.output / "summary.md", summaries, args, codes)
    print((args.output / "summary.md").read_text())

    failed = []
    for s in summaries:
        role = s["role"]
        if codes[role] != 0:
            failed.append(f"{role} exited {codes[role]}")
        if not s["finished"]:
            failed.append(f"{role} did not finish")
        if s["error_count"]:
            failed.append(f"{role} logged {s['error_count']} errors")
        if (s["done"] or {}).get("join_failures"):
            failed.append(f"{role} failed to join {s['done']['join_failures']} times")
        if s["rss_slope_mb_per_hour"] > args.max_rss_slope:
            failed.append(f"{role} RSS grew {s['rss_slope_mb_per_hour']:.1f} MB/h")
    if failed:
        print("Soak failed: " + "; ".join(failed), file=sys.stderr)
        return 1
    print("Soak passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
