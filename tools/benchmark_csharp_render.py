#!/usr/bin/env python3
"""Benchmark B16: render throughput, Beef vs C#, in a real window (needs a display).

Runs the `render` mode of the built CSharpBench and EcsBench players (tools/build_player.py ... --config Release)
with --profile-report, and reads from each report the frame interval, the main thread's Rendering and Scripts time,
the GPU frame time, draws, instances, visible renderers and memory. Rendering CPU and GPU time are the engine's;
the scripts row is where the two languages differ.

  python3 tools/benchmark_csharp_render.py --csharp OUT/cs/CSharpBench --beef OUT/beef/EcsBench \\
      [--cases 10000:0:0,100000:0:0,100000:10000:0,100000:10000:1] [--runs 2] [--output raw.jsonl]

A case is static:moving:chunks[:effects] (chunks 1 streams a 1,000-cube chunk out and another in every 30 frames;
effects N adds N quads running the ripple compute graph and puts every 10th static cube on the glow shader's material,
and checks both languages dispatch and draw the same).
"""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import tempfile


def read_report(text: str) -> dict:
    out = {}

    def row(label):
        m = re.search(r"^\| " + re.escape(label) + r" \| ([\d.]+) ms \| ([\d.]+) ms \| ([\d.]+) ms \| ([\d.]+) ms", text, re.M)
        return [float(x) for x in m.groups()] if m else None

    interval, cpu, gpu = row("Frame interval (what players see)"), row("CPU main thread"), row("GPU")
    if interval:
        out["frame_avg_ms"], out["frame_p99_ms"] = interval[0], interval[3]
    if cpu:
        out["cpu_avg_ms"] = cpu[0]
    if gpu:
        out["gpu_avg_ms"], out["gpu_p99_ms"] = gpu[0], gpu[3]
    for category in ("Rendering", "Scripts", "Waiting"):
        m = re.search(r"^- " + category + r": ([\d.]+) ms", text, re.M)
        if m:
            out[category.lower() + "_ms"] = float(m.group(1))
    for marker in ("Culling", "Sorting", "Opaque", "Destroy", "Mover.Update()", "InGame"):
        m = re.search(r"^\| " + re.escape(marker) + r" \| \w+ \| ([\d.]+) ms", text, re.M)
        if m:
            out["marker " + marker] = float(m.group(1))
    for counter, key in (("Draw Calls", "draw_calls"), ("GPU Draws (all passes)", "gpu_draws"), ("Instances", "instances"),
                         ("Visible Renderers", "visible"), ("GPU Compute Dispatches", "compute"), ("Game Objects", "objects"),
                         ("Process Memory in bytes", "process_bytes"), ("GPU Memory Used in bytes", "gpu_bytes")):
        m = re.search(r"^- " + re.escape(counter) + r": ([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)", text, re.M)
        if m:
            out[key] = float(m.group(3)) if key != "process_bytes" else float(m.group(4))
    return out


def run(player: Path, static: int, moving: int, chunks: int, effects: int, frames: int, timeout: int) -> dict:
    with tempfile.TemporaryDirectory(prefix="tallow-render-bench-") as work:
        report = Path(work) / "profile.txt"
        env = {**os.environ, "TALLOW_BENCH_MODE": "render", "TALLOW_BENCH_COUNT": str(static),
               "TALLOW_BENCH_MOVING": str(moving), "TALLOW_BENCH_CHUNKS": str(chunks), "TALLOW_BENCH_EFFECTS": str(effects),
               "TALLOW_BENCH_FRAMES": str(frames)}
        result = subprocess.run([str(player), "--profile-report", str(report)], cwd=player.parent, env=env,
                                capture_output=True, text=True, timeout=timeout)
        line = next((l for l in result.stdout.splitlines() if l.startswith("{")), None)
        if line is None or not report.exists():
            raise RuntimeError(f"{player.name} {static}:{moving}:{chunks} gave no result:\n{result.stdout[-2000:]}{result.stderr[-2000:]}")
        record = json.loads(line)
        record.update(read_report(report.read_text()))
        return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csharp", type=Path, required=True)
    parser.add_argument("--beef", type=Path, required=True)
    parser.add_argument("--cases", default="10000:0:0,10000:0:0:8,100000:0:0,100000:10000:0,100000:10000:1,100000:10000:1:8")
    parser.add_argument("--frames", type=int, default=600)
    parser.add_argument("--runs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY") and os.name != "nt":
        print("B16 needs a display (it measures the GPU).", file=sys.stderr)
        return 2
    results = {}
    for case in options.cases.split(","):
        static, moving, chunks, effects = ([int(x) for x in case.split(":")] + [0])[:4]
        for _ in range(options.runs):
            for lang, player in (("beef", options.beef), ("cs", options.csharp)):
                record = run(player.resolve(), static, moving, chunks, effects, options.frames, options.timeout)
                record["lang"] = lang
                results.setdefault((case, lang), []).append(record)
                if options.output:
                    with options.output.open("a") as out:
                        out.write(json.dumps(record) + "\n")

    def med(case, lang, key):
        values = [r[key] for r in results[(case, lang)] if r.get(key) is not None]
        return statistics.median(values) if values else float("nan")

    print("| static:moving:chunks | frame avg ms Beef / C# | frame p99 | GPU ms | rendering CPU ms | scripts ms | draws | visible | compute |")
    print("|---|---|---|---|---|---|---|---|---|")
    for case in options.cases.split(","):
        cells = [f"{med(case, 'beef', k):.2f} / {med(case, 'cs', k):.2f}" for k in
                 ("frame_avg_ms", "frame_p99_ms", "gpu_avg_ms", "rendering_ms", "scripts_ms")]
        print(f"| {case} | " + " | ".join(cells) +
              f" | {med(case, 'beef', 'draw_calls'):.0f} / {med(case, 'cs', 'draw_calls'):.0f}"
              f" | {med(case, 'beef', 'visible'):.0f} / {med(case, 'cs', 'visible'):.0f}"
              f" | {med(case, 'beef', 'compute'):.0f} / {med(case, 'cs', 'compute'):.0f} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
