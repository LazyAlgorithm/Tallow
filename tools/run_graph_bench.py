#!/usr/bin/env python3
"""B21, visual scripting parity (docs/csharp-benchmark-plan.md): the same graphs compiled to Beef (Samples/EcsBench)
and to C# (Samples/CSharpBench).

1. Regeneration: every graph of both samples compiled again by the launcher (--graph-compile to C#,
   --graph-compile-beef to Beef), --runs times each, timed. The output must be the same each time and the same as
   the file in the repository (graph files and their generated code round-trip without drift).
2. Event order: each player in graph mode (TALLOW_BENCH_MODE=graph) logs GraphOrder's events (Awake, OnEnable,
   Start, the first Update and the first LateUpdate); both languages must give the same order.
3. Throughput: run tools/run_csharp_bench.py --modes graph (cubes each running Bobber, 10 nodes) separately.

Works on copies, never on the samples themselves:
    python3 tools/run_graph_bench.py --csharp OUT-CS/CSharpBench --beef OUT-BEEF/EcsBench \
        --projects COPIES --output DIR
where COPIES holds copies of Samples/CSharpBench and Samples/EcsBench (the folders the players were built from).
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

ROOT = Path(__file__).resolve().parent.parent
SAMPLES = {"csharp": ("CSharpBench", "CSharpBench.Graphs", ".cs", "--graph-compile"),
           "beef": ("EcsBench", "EcsBench.Graphs", ".bf", "--graph-compile-beef")}


def regenerate(launcher: Path, copies: Path, runs: int) -> list[dict]:
    rows = []
    for lang, (sample, namespace, extension, switch) in SAMPLES.items():
        for graph in sorted((copies / sample / "src" / "Graphs").glob("*.tgraph")):
            generated = graph.with_suffix(extension)
            committed = ROOT / "Samples" / sample / "src" / "Graphs" / generated.name
            times, outputs = [], set()
            for _ in range(runs):
                started = time.monotonic()
                done = subprocess.run([str(launcher), switch, str(graph), namespace], capture_output=True, text=True,
                                      timeout=300)
                times.append((time.monotonic() - started) * 1000)
                if done.returncode != 0 or not generated.exists():
                    raise RuntimeError(f"{switch} {graph.name} failed:\n{done.stdout}{done.stderr}")
                outputs.add(generated.read_text(encoding="utf-8"))
            # A graph with no checked-in output (EcsSyncedMotionGraph uses EcsBench's own Beef ECS types, which only
            # that project's native build knows, not the precompiled launcher) is listed, not checked.
            same_as_repo = outputs == {committed.read_text(encoding="utf-8")} if committed.exists() else None
            rows.append({"lang": lang, "graph": graph.name, "median_ms": round(statistics.median(times), 1),
                         "stable": len(outputs) == 1, "matches_repo": same_as_repo,
                         "lines": next(iter(outputs)).count("\n")})
    return rows


def event_order(player: Path, output: Path, lang: str) -> list[str]:
    env = dict(os.environ, TALLOW_BENCH_MODE="graph", TALLOW_BENCH_COUNT="10", TALLOW_BENCH_FRAMES="120")
    done = subprocess.run([str(player), "--headless"], env=env, capture_output=True, text=True, timeout=300,
                          cwd=player.parent)
    text = done.stdout + done.stderr
    (output / f"order-{lang}.log").write_text(text)
    return [line.split("GRAPHORDER", 1)[1].strip() for line in text.splitlines() if "GRAPHORDER" in line]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csharp", type=Path, required=True)
    parser.add_argument("--beef", type=Path, required=True)
    parser.add_argument("--projects", type=Path, required=True, help="folder with copies of both samples")
    parser.add_argument("--launcher", type=Path, default=ROOT / "build/Debug_Linux64/TallowLauncher/TallowLauncher")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    failed = False
    rows = regenerate(args.launcher, args.projects, args.runs)
    print(f"Regeneration ({args.runs} runs each, launcher start included):\n")
    print("| graph | language | median ms | lines | same every run | same as the repository |")
    print("|---|---|---:|---:|---|---|")
    for row in rows:
        print(f"| {row['graph']} | {row['lang']} | {row['median_ms']} | {row['lines']} | {row['stable']} "
              f"| {'(none checked in)' if row['matches_repo'] is None else row['matches_repo']} |")
        failed |= not row["stable"] or row["matches_repo"] is False

    orders = {lang: event_order(player, args.output, lang) for lang, player in (("beef", args.beef),
                                                                               ("csharp", args.csharp))}
    print("\nEvent order:")
    for lang, order in orders.items():
        print(f"  {lang}: {', '.join(order) or '(none)'}")
    same = orders["beef"] == orders["csharp"] and len(orders["beef"]) == 5
    print(f"  same in both: {same}")
    failed |= not same

    (args.output / "graph-bench.json").write_text(json.dumps({"regeneration": rows, "order": orders}, indent=1))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
