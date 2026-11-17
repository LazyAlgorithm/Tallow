#!/usr/bin/env python3
"""Benchmark B17: managed allocations of C# scripts, in a Release CSharpBench player (headless).
Each of N objects runs one pattern every Update (Samples/CSharpBench, TALLOW_BENCH_MODE=alloc):
  math          Vector3/Quaternion value math only
  event         a C# event with a class argument and a capturing lambda
  getcomponent  three GetComponent calls (a native hit, a script hit, a native miss)
  string        the object's Name from the engine plus a formatted string
Reports managed bytes per frame, Gen0/1/2 collections and GC pause over the measured frames, script time and peak RSS.
Build the player first: python3 tools/build_player.py <copy of Samples/CSharpBench> --output OUT --config Release
Run: python3 tools/benchmark_csharp_alloc.py --player OUT/CSharpBench [--counts 1000 10000 100000] [--runs 3]
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

PATTERNS = ["math", "event", "getcomponent", "string"]


def run(player: Path, pattern: str, count: int, frames: int) -> dict:
    env = dict(os.environ, TALLOW_BENCH_MODE="alloc", TALLOW_BENCH_ALLOC=pattern, TALLOW_BENCH_COUNT=str(count),
               TALLOW_BENCH_FRAMES=str(frames))
    done = subprocess.run([str(player), "--headless"], env=env, capture_output=True, text=True, timeout=1800,
                          cwd=player.parent)
    for line in reversed((done.stdout + done.stderr).splitlines()):
        if line.strip().startswith("{") and '"mode"' in line:
            return json.loads(line)
    raise RuntimeError(f"{pattern} {count}: no result (exit {done.returncode})\n{(done.stdout + done.stderr)[-3000:]}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--player", type=Path, required=True)
    parser.add_argument("--counts", type=int, nargs="+", default=[1000, 10000, 100000])
    parser.add_argument("--patterns", nargs="+", default=PATTERNS)
    parser.add_argument("--frames", type=int, default=600)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path, help="append every raw JSON line here")
    options = parser.parse_args()
    print(f"Medians of {options.runs} runs x {options.frames} frames after warm-up.\n")
    print("| pattern | scripts | script ms | frame ms (p99) | managed bytes/frame | bytes/script | Gen0/1/2 | GC pause ms | peak RSS MB |")
    print("|---|---:|---:|---:|---:|---:|---|---:|---:|")
    for pattern in options.patterns:
        for count in options.counts:
            results = []
            for _ in range(options.runs):
                result = run(options.player, pattern, count, options.frames)
                results.append(result)
                if options.output:
                    with options.output.open("a") as out:
                        out.write(json.dumps(result) + "\n")
            m = lambda field: statistics.median(r[field] for r in results)
            print(f"| {pattern} | {count} | {m('script_only_avg_ms'):.3f} | {m('frame_avg_ms'):.3f} ({m('frame_p99_ms'):.3f}) "
                  f"| {m('gc_bytes_per_frame'):,.0f} | {m('gc_bytes_per_frame') / count:.1f} "
                  f"| {m('gc_gen0'):.0f}/{m('gc_gen1'):.0f}/{m('gc_gen2'):.0f} | {m('gc_pause_ms'):.1f} "
                  f"| {m('memory_peak') / 1048576:.0f} |", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
