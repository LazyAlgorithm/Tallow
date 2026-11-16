#!/usr/bin/env python3
"""Beef versus C# gameplay benchmark: the same cubes and rules (Samples/EcsBench's Workload) run by Beef scripts
(Samples/EcsBench) and by C# scripts (Samples/CSharpBench), in Release players built from the same engine.

Build both players first (Release, the shipping path; the editor's Play runs C# as a Debug build):
    python3 tools/build_player.py <copy of Samples/CSharpBench> --output OUT-CS --config Release
    python3 tools/build_player.py <copy of Samples/EcsBench> --output OUT-BEEF --config Release
(each copy's project.tallow pointing at this engine). Then:
    python3 tools/run_csharp_bench.py --csharp OUT-CS/CSharpBench --beef OUT-BEEF/EcsBench --runs 3

Runs alternate Beef and C# and report medians of each measure; --output keeps every raw JSON line. Players run
--headless, so frame time is CPU work (scripts, engine systems) without the GPU. "script" is the time from the
benchmark's own Update to a script added after every cube's, i.e. all the cubes' Updates; for ecs it is the query.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

MODES = {m: (m, m) for m in ("gameobject", "ecs", "getcomponent", "physics", "lifecycle")}
FIELDS = ["script_only_avg_ms", "script_only_p99_ms", "frame_avg_ms", "frame_p99_ms", "spawn_ms", "gc_bytes_per_frame"]


def run(executable: Path, mode: str, count: int, frames: int, timeout: int) -> dict:
    env = dict(os.environ, TALLOW_BENCH_MODE=mode, TALLOW_BENCH_COUNT=str(count), TALLOW_BENCH_FRAMES=str(frames))
    done = subprocess.run([str(executable), "--headless"], env=env, capture_output=True, text=True, timeout=timeout,
                          cwd=executable.parent)
    for line in reversed((done.stdout + done.stderr).splitlines()):
        line = line.strip()
        if line.startswith("{") and '"mode"' in line:
            return json.loads(line)
    raise RuntimeError(f"{executable.name} {mode} {count}: no result (exit {done.returncode})\n"
                       + (done.stdout + done.stderr)[-3000:])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csharp", type=Path, required=True, help="the built CSharpBench player")
    parser.add_argument("--beef", type=Path, required=True, help="the built EcsBench player")
    parser.add_argument("--counts", default="1000,10000,50000")
    parser.add_argument("--modes", default="gameobject,ecs")
    parser.add_argument("--frames", type=int, default=600)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--output", type=Path, help="append every raw JSON line here")
    args = parser.parse_args()

    results: dict = {}
    for mode in args.modes.split(","):
        for count in (int(c) for c in args.counts.split(",")):
            for index in range(args.runs):
                # Alternate which goes first, so neither always runs on a cooler (or warmer) machine.
                order = [("beef", args.beef), ("csharp", args.csharp)]
                if index % 2:
                    order.reverse()
                for lang, executable in order:
                    result = run(executable, MODES[mode][0 if lang == "beef" else 1], count, args.frames, args.timeout)
                    result["lang"] = lang
                    results.setdefault((mode, count, lang), []).append(result)
                    if args.output:
                        with args.output.open("a") as out:
                            out.write(json.dumps(result) + "\n")
                    print(f"{mode:10} {count:>6} {lang:6} run {index + 1}: script {result.get('script_only_avg_ms', 0):.3f} ms,"
                          f" frame {result.get('frame_avg_ms', 0):.3f} ms", file=sys.stderr)

    def median(mode, count, lang, field):
        values = [r[field] for r in results.get((mode, count, lang), []) if field in r]
        return statistics.median(values) if values else float("nan")

    print(f"Medians of {args.runs} runs, {args.frames} frames each after warm-up, headless Release players.\n")
    print("| mode | cubes | Beef script ms | C# script ms | C#/Beef | Beef frame ms (p99) | C# frame ms (p99) "
          "| Beef spawn ms | C# spawn ms | C# GC bytes/frame |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for mode in args.modes.split(","):
        for count in (int(c) for c in args.counts.split(",")):
            beef = median(mode, count, "beef", "script_only_avg_ms")
            cs = median(mode, count, "csharp", "script_only_avg_ms")
            print(f"| {mode} | {count} | {beef:.3f} | {cs:.3f} | {cs / beef if beef else float('nan'):.2f}x "
                  f"| {median(mode, count, 'beef', 'frame_avg_ms'):.3f} ({median(mode, count, 'beef', 'frame_p99_ms'):.3f}) "
                  f"| {median(mode, count, 'csharp', 'frame_avg_ms'):.3f} ({median(mode, count, 'csharp', 'frame_p99_ms'):.3f}) "
                  f"| {median(mode, count, 'beef', 'spawn_ms'):.1f} | {median(mode, count, 'csharp', 'spawn_ms'):.1f} "
                  f"| {median(mode, count, 'csharp', 'gc_bytes_per_frame'):.0f} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
