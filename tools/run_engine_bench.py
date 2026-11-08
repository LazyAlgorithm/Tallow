#!/usr/bin/env python3
"""Run Tallow's existing EcsBench cases and record reproducible, per-run results.

Requires a built Samples/EcsBench player. Run from any directory:
    python3 tools/run_full_bench.py --preset quick
    python3 tools/run_full_bench.py --preset standard --runs 3
    python3 tools/run_full_bench.py --executable /path/to/EcsBench --baseline-executable /path/to/older/EcsBench

Writes results.jsonl, summary.csv, summary.md, profiles.jsonl, checks.json and
metadata.json into a timestamped folder under build/benchmark-results/.
The physics/render/network/AI saturation scenarios in docs/benchmarks/README.md
are proposals, not implemented EcsBench modes yet.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys

MODES = ("gameobject", "ecs", "ecs-mt", "mixed")
PRESETS = {
    "quick": {"counts": [1_000, 10_000], "frames": 240, "runs": 1, "profiles": [1_000]},
    "standard": {"counts": [1_000, 10_000, 50_000, 100_000], "frames": 600, "runs": 3, "profiles": [1_000, 10_000]},
    "stress": {"counts": [10_000, 50_000, 100_000, 200_000], "frames": 1_200, "runs": 5, "profiles": [10_000, 100_000]},
}
METRICS = (
    "frame_avg_ms", "frame_p99_ms", "update_avg_ms", "update_p99_ms",
    "script_only_avg_ms", "script_only_p99_ms", "process_cpu_ms_per_frame",
    "spawn_ms", "despawn_ms", "draw_calls_avg", "memory_growth_mib",
    "allocation_count", "ref_slow_per_frame", "physics_bodies", "behavior_trees", "network_identities",
)


def command_output(args: list[str], cwd: Path | None = None) -> str | None:
    try:
        proc = subprocess.run(args, cwd=cwd, text=True, capture_output=True, timeout=5, check=False)
        return proc.stdout.strip() if proc.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def metadata(root: Path, args: argparse.Namespace) -> dict:
    cpu = platform.processor()
    if sys.platform == "linux":
        try:
            cpu = next((line.partition(":")[2].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
                        if line.startswith("model name")), cpu)
        except OSError:
            pass
    gpu = command_output(["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"])
    if not gpu and sys.platform == "linux":
        gpu = "\n".join(line for line in (command_output(["lspci"]) or "").splitlines()
                        if any(word in line.lower() for word in ("vga", "3d controller", "display controller"))) or None
    return {
        "utc_start": datetime.now(timezone.utc).isoformat(),
        "git_commit": command_output(["git", "rev-parse", "HEAD"], cwd=root),
        "git_branch": command_output(["git", "branch", "--show-current"], cwd=root),
        "git_dirty": bool(command_output(["git", "status", "--porcelain"], cwd=root)),
        "os": platform.platform(), "python": platform.python_version(),
        "cpu": cpu, "logical_cpu_count": os.cpu_count(), "gpu": gpu,
        "preset": args.preset, "modes": args.modes, "counts": args.counts,
        "frames": args.frames, "runs": args.runs,
        "note": "GPU driver, display resolution and power mode may vary; keep them constant between runs.",
    }


def execute(command: list[str], env: dict, cwd: Path, timeout: int) -> tuple[int, str]:
    try:
        proc = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout, check=False, errors="replace")
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as error:
        data = error.stdout or b""
        if isinstance(data, bytes):
            data = data.decode(errors="replace")
        return 124, data + f"\nTIMEOUT after {timeout} seconds"
    except OSError as error:
        return 127, str(error)


def write_json(path: Path, record: dict):
    path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_jsonl(path: Path, record: dict):
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(record, sort_keys=True) + "\n")


def profile_records(output: str, variant: str, count: int) -> list[dict]:
    result = []
    for line in output.splitlines():
        if not line.startswith("PROFILE "):
            continue
        tokens = line.split()
        if len(tokens) < 3:
            continue
        row: dict = {"variant": variant, "name": tokens[1], "count": count}
        for key, value in re.findall(r"([a-zA-Z_][a-zA-Z_0-9]*)=(-?\d+(?:\.\d+)?)", line):
            row[key] = float(value) if "." in value else int(value)
        result.append(row)
    return result


def summarize(rows: list[dict], output: Path) -> None:
    grouped: dict[tuple[str, str, int], list[dict]] = {}
    for row in rows:
        grouped.setdefault((row["variant"], row["mode"], row["count"]), []).append(row)
    medians: dict[tuple[str, str, int], dict] = {}
    for key, batch in grouped.items():
        summary = {"variant": key[0], "mode": key[1], "count": key[2], "runs": len(batch)}
        for metric in METRICS:
            samples = [item[metric] for item in batch
                       if isinstance(item.get(metric), (int, float)) and not isinstance(item.get(metric), bool)]
            summary[metric] = round(statistics.median(samples), 4) if samples else None
        medians[key] = summary
    with (output / "summary.csv").open("w", encoding="utf-8", newline="") as file:
        writer = csv.DictWriter(file, fieldnames=["variant", "mode", "count", "runs", *METRICS])
        writer.writeheader()
        writer.writerows(medians[key] for key in sorted(medians))

    lines = ["# Tallow benchmark summary", "", "Median of completed runs; p99 is the median of each run's p99.",
             "Lower frame/update milliseconds is better. Results depend on machine, GPU and window settings.", "",
             "| Variant | Mode | Objects | Runs | Frame avg / p99 (ms) | Update avg / p99 (ms) | Spawn (ms) | Memory growth (MiB) |",
             "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    def fmt(row: dict, key: str) -> str:
        value = row.get(key)
        return f"{value:.3f}" if value is not None else "n/a"
    for key in sorted(medians):
        row = medians[key]
        lines.append(f"| {row['variant']} | {row['mode']} | {row['count']:,} | {row['runs']} | "
                     f"{fmt(row, 'frame_avg_ms')} / {fmt(row, 'frame_p99_ms')} | "
                     f"{fmt(row, 'update_avg_ms')} / {fmt(row, 'update_p99_ms')} | "
                     f"{fmt(row, 'spawn_ms')} | {fmt(row, 'memory_growth_mib')} |")
    if any(key[0] == "baseline" for key in medians):
        lines += ["", "## Baseline comparison", "", "Negative change means the current build is faster.", "",
                  "| Mode | Objects | Frame average change | Update average change |", "| --- | ---: | ---: | ---: |"]
        for (variant, mode, count), row in sorted(medians.items()):
            if variant != "current":
                continue
            base = medians.get(("baseline", mode, count))
            if not base:
                continue
            def change(metric: str) -> str:
                old, new = base.get(metric), row.get(metric)
                return f"{(new / old - 1) * 100:+.1f}%" if old and new is not None else "n/a"
            lines.append(f"| {mode} | {count:,} | {change('frame_avg_ms')} | {change('update_avg_ms')} |")
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    project = root / "Samples" / "EcsBench"
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--preset", choices=PRESETS, default="standard")
    parser.add_argument("--config", choices=("Debug", "Release"), default="Release")
    parser.add_argument("--executable", type=Path, help="Path to built EcsBench player")
    parser.add_argument("--baseline-executable", type=Path, help="Optional earlier EcsBench player for A/B testing")
    parser.add_argument("--output-dir", type=Path, default=root / "build" / "benchmark-results")
    parser.add_argument("--modes", nargs="+", choices=MODES, default=list(MODES))
    parser.add_argument("--counts", nargs="+", type=int)
    parser.add_argument("--profile-counts", nargs="*", type=int)
    parser.add_argument("--runs", type=int)
    parser.add_argument("--frames", type=int)
    parser.add_argument("--timeout", type=int, default=1800, help="Seconds allowed per player launch")
    parser.add_argument("--no-checks", action="store_true", help="Skip correctness checks")
    parser.add_argument("--no-profiles", action="store_true", help="Skip script path profiles")
    parser.add_argument("--headless-only", action="store_true", help="Run --check-scripts and --profile-scripts only")
    parser.add_argument("--fail-fast", action="store_true", help="Stop on first failure (partial files stay saved)")
    args = parser.parse_args()
    defaults = PRESETS[args.preset]
    args.counts = args.counts if args.counts is not None else defaults["counts"]
    args.frames = args.frames if args.frames is not None else defaults["frames"]
    args.runs = args.runs if args.runs is not None else defaults["runs"]
    args.profile_counts = args.profile_counts if args.profile_counts is not None else defaults["profiles"]
    if args.frames <= 0 or args.runs <= 0 or args.timeout <= 0 or any(n <= 0 for n in [*args.counts, *args.profile_counts]):
        parser.error("Counts, frames, runs and timeout must be positive")
    platform_name = "Win64" if os.name == "nt" else "Linux64"
    binary_name = "EcsBench.exe" if os.name == "nt" else "EcsBench"
    exe = (args.executable or project / f"build/{args.config}_{platform_name}/EcsBench" / binary_name).resolve()
    if not exe.is_file():
        parser.error(f"Missing {exe}; first build with Tallow --build-project Samples/EcsBench and BeefBuild -workspace=Samples/EcsBench -config={args.config} -platform={platform_name}")
    players = [("current", exe)]
    if args.baseline_executable:
        baseline = args.baseline_executable.resolve()
        if not baseline.is_file():
            parser.error(f"Missing baseline executable: {baseline}")
        players.insert(0, ("baseline", baseline))
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = args.output_dir.resolve() / stamp
    # Avoid overwriting other sessions, even if launched within the same second.
    serial = 2
    while out.exists():
        out = args.output_dir.resolve() / f"{stamp}-{serial}"
        serial += 1
    out.mkdir(parents=True)
    meta = metadata(root, args)
    meta["executables"] = {variant: str(player) for variant, player in players}
    write_json(out / "metadata.json", meta)
    print(f"Results: {out}", flush=True)
    results: list[dict] = []
    checks: list[dict] = []
    failures: list[dict] = []
    env0 = dict(os.environ)

    def run_case(label: str, variant: str, player: Path, cmd: list[str], env: dict, result_file: Path | None = None) -> tuple[int, str]:
        print(f"Running {variant}: {label}", flush=True)
        if result_file is not None:
            result_file.unlink(missing_ok=True)
        code, output_text = execute(cmd, env, project, args.timeout)
        if code != 0:
            issue = {"variant": variant, "case": label, "exit_code": code, "output_tail": output_text[-4000:]}
            failures.append(issue)
            append_jsonl(out / "failures.jsonl", issue)
            print(f"  FAILED: exit {code}. See failures.jsonl", flush=True)
            if args.fail_fast:
                raise RuntimeError(f"Benchmark failed: {label}")
        return code, output_text

    try:
        if not args.no_checks:
            for variant, player in players:
                code, log = run_case("script correctness", variant, player, [str(player), "--check-scripts"], env0)
                checks.append({"variant": variant, "test": "check-scripts", "exit_code": code, "output": log[-12000:]})
            if not args.headless_only:
                for variant, player in players:
                    check_out = out / ".check.jsonl"
                    env = {**env0, "TALLOW_BENCH_MODE": "check", "TALLOW_BENCH_OUT": str(check_out)}
                    code, log = run_case("ECS/integration correctness", variant, player,
                                         [str(player), "--project", str(project)], env)
                    checks.append({"variant": variant, "test": "ecs-check", "exit_code": code, "output": log[-12000:]})
                    check_out.unlink(missing_ok=True)
            write_json(out / "checks.json", {"checks": checks})
        if not args.no_profiles:
            for count in args.profile_counts:
                for variant, player in players:
                    code, log = run_case(f"script dispatch profile x {count}", variant, player,
                                         [str(player), "--profile-scripts", str(count)], env0)
                    (out / f"profile-{variant}-{count}.log").write_text(log, encoding="utf-8")
                    if code == 0:
                        for profile in profile_records(log, variant, count):
                            append_jsonl(out / "profiles.jsonl", profile)
        if not args.headless_only:
            total = len(args.counts) * len(args.modes) * args.runs * len(players)
            run_number = 0
            for count in args.counts:
                for mode in args.modes:
                    for repeat in range(1, args.runs + 1):
                        order = players if repeat % 2 else list(reversed(players))
                        for variant, player in order:
                            run_number += 1
                            result_file = out / ".one-result.jsonl"
                            env = {**env0, "TALLOW_BENCH_MODE": mode, "TALLOW_BENCH_COUNT": str(count),
                                   "TALLOW_BENCH_FRAMES": str(args.frames), "TALLOW_BENCH_OUT": str(result_file)}
                            print(f"[{run_number}/{total}] ", end="", flush=True)
                            code, log = run_case(f"{mode} x {count} (repeat {repeat}/{args.runs})", variant,
                                                 player, [str(player), "--project", str(project)], env, result_file)
                            if code != 0:
                                continue
                            try:
                                lines = [json.loads(line) for line in result_file.read_text(encoding="utf-8").splitlines() if line.strip()]
                                assert len(lines) == 1 and lines[0]["mode"] == mode and lines[0]["count"] == count
                                row = lines[0]
                            except (OSError, ValueError, KeyError, AssertionError) as error:
                                issue = {"variant": variant, "case": f"{mode} x {count}", "error": str(error),
                                         "output_tail": log[-4000:]}
                                failures.append(issue)
                                append_jsonl(out / "failures.jsonl", issue)
                                print("  FAILED: missing or invalid JSON result", flush=True)
                                if args.fail_fast:
                                    raise RuntimeError(str(issue))
                                continue
                            row.update({"variant": variant, "run": repeat})
                            if isinstance(row.get("memory_before"), (int, float)) and isinstance(row.get("memory_after"), (int, float)):
                                row["memory_growth_mib"] = round((row["memory_after"] - row["memory_before"]) / (1024 ** 2), 3)
                            results.append(row)
                            append_jsonl(out / "results.jsonl", row)
                            print(f"  avg {row.get('frame_avg_ms')} ms; p99 {row.get('frame_p99_ms')} ms", flush=True)
            summarize(results, out)
    except (KeyboardInterrupt, RuntimeError) as error:
        if isinstance(error, RuntimeError):
            print(str(error), file=sys.stderr)
        print("Interrupted; completed raw results are still saved.", file=sys.stderr)
        if results:
            summarize(results, out)
        return 130 if isinstance(error, KeyboardInterrupt) else 1
    finally:
        (out / ".one-result.jsonl").unlink(missing_ok=True)
        write_json(out / "status.json", {"completed_performance_runs": len(results),
                                          "checks": len(checks), "failures": len(failures),
                                          "utc_end": datetime.now(timezone.utc).isoformat()})
    print(f"Finished: {len(results)} performance runs, {len(failures)} failures. Files in {out}", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())