#!/usr/bin/env python3
"""Benchmark the actual server-style AI crowd (tree + perception + navigation per agent).

Requires the EcsBench Release/Linux64 executable built by tools/test_ecs_ai_linux.sh.
This is an offline authority-side CPU measurement: NetworkIdentity in this
workload does NOT establish a server/client session or measure packet bandwidth.

Examples:
    python3 tools/run_ai_bench.py --counts 100 1000 5000 --runs 3 --output ai-results.jsonl
    python3 tools/run_ai_bench.py --counts 10000 --frames 300
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    project = root / "Samples/EcsBench"
    default_exe = project / "build/Release_Linux64/EcsBench/EcsBench"
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--executable", type=Path, default=default_exe)
    parser.add_argument("--counts", type=int, nargs="+", default=[100, 1000, 5000])
    parser.add_argument("--frames", type=int, default=180)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path, help="Save all raw benchmark JSON lines")
    args = parser.parse_args()
    if not args.executable.is_file():
        parser.error(f"Missing EcsBench executable: {args.executable}. Run tools/test_ecs_ai_linux.sh first.")
    if args.runs < 1 or args.frames < 30 or any(n < 1 for n in args.counts):
        parser.error("Runs/counts must be positive and --frames must be at least 30.")

    rows = []
    with tempfile.TemporaryDirectory() as temp:
        result_file = Path(temp) / "ai-result.jsonl"
        for n in args.counts:
            for repeat in range(args.runs):
                result_file.unlink(missing_ok=True)
                env = dict(os.environ,
                           TALLOW_BENCH_MODE="ai",
                           TALLOW_BENCH_COUNT=str(n),
                           TALLOW_BENCH_FRAMES=str(args.frames),
                           TALLOW_BENCH_OUT=str(result_file))
                print(f"AI agents {n:,}: run {repeat + 1}/{args.runs}", flush=True)
                result = subprocess.run([str(args.executable.resolve()), "--project", str(project)],
                                        env=env, cwd=project, capture_output=True, text=True, timeout=1800)
                if result.returncode:
                    print((result.stdout + result.stderr)[-6000:], file=sys.stderr)
                    return result.returncode or 1
                if not result_file.is_file():
                    print("AI benchmark produced no JSON result:\n" + (result.stdout + result.stderr)[-6000:],
                          file=sys.stderr)
                    return 1
                run_rows = [json.loads(line) for line in result_file.read_text().splitlines() if line.strip()]
                if len(run_rows) != 1 or run_rows[0].get("mode") != "ai" or run_rows[0].get("ai_agents") != n:
                    print(f"Invalid AI benchmark output for {n} agents: {run_rows!r}", file=sys.stderr)
                    return 1
                row = run_rows[0]
                row["run"] = repeat + 1
                if row.get("ai_tree_ticks", 0) <= 0:
                    print(f"ERROR: no behavior-tree ticks ran with {n} agents", file=sys.stderr)
                    return 1
                rows.append(row)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text("".join(json.dumps(row) + "\n" for row in rows))

    def median(n, key):
        return statistics.median(r[key] for r in rows if r["ai_agents"] == n)

    print("\nAuthority-side AI crowd scaling (median across repeated runs):")
    print("| AI agents | Frame avg / p99 (ms) | Update avg / p99 (ms) | Tree ticks | Perception candidates / query | Nav bake (ms) | Mem growth |")
    print("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for n in args.counts:
        queries = median(n, "ai_object_queries")
        candidate_ratio = median(n, "ai_object_candidates") / queries if queries else 0
        growth = statistics.median((r["memory_after"] - r["memory_before"]) / 1048576
                                    for r in rows if r["ai_agents"] == n)
        print(f"| {n:,} | {median(n, 'frame_avg_ms'):.3f} / {median(n, 'frame_p99_ms'):.3f} | "
              f"{median(n, 'update_avg_ms'):.3f} / {median(n, 'update_p99_ms'):.3f} | "
              f"{int(median(n, 'ai_tree_ticks')):,} | {candidate_ratio:.1f} | "
              f"{median(n, 'navigation_bake_ms'):.1f} | {growth:.1f} MB |")
    print("\nThis excludes active network traffic and client rendering/animation; test those separately.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
