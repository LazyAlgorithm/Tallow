#!/usr/bin/env python3
"""B06, managed runtime bootstrap and lifecycle (docs/csharp-benchmark-plan.md). Needs a display (the editor).

For 0, 100, 1,000 and 10,000 scripted objects: a new project (TallowLauncher --create, its own scripts removed) gets
one script, `Ticker`, and a scene with that many objects using it. The editor opens it with --play-cycle-test N
(Editor/src/Tools/PlayCycleTest.bf): N Play/Stop cycles of 10 frames each, checking that every Stop detaches every
script. Ticker reports, as errors, a second Awake or Start on one instance, two LocalUpdates in one frame (a
duplicate callback) and an Update after OnDestroy (a callback on a dead handle). Reported per size: Play and Stop
times (median, first, worst), memory before the second and the last cycle, errors, and whether the managed runtime
warned that unloaded game assemblies stayed in memory (retained managed instances keep their game alive).

    python3 tools/run_play_cycle_bench.py --cycles 100 --output DIR
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csharp_editor import LAUNCHER, ROOT, open_editor  # noqa: E402

TICKER = '''using Tallow;

namespace Cycle;

/// <summary>B06's lightweight script: counts its callbacks and reports any that should not happen.</summary>
public class Ticker : Script
{
    public static int Live;
    private bool _awake, _started, _destroyed;
    private long _lastFrame = -1;
    public int Updates;

    public override void Awake()
    {
        if (_awake)
            Log.Error("CYCLE duplicate Awake");
        _awake = true;
        Live++;
    }

    public override void Start()
    {
        if (_started)
            Log.Error("CYCLE duplicate Start");
        _started = true;
    }

    public override void Update(TickInput input, float deltaTime)
    {
        if (_destroyed)
            Log.Error("CYCLE Update after OnDestroy");
        Updates++;
    }

    public override void LocalUpdate(float deltaTime)
    {
        long frame = Time.FrameCount;
        if (frame == _lastFrame)
            Log.Error("CYCLE two LocalUpdates in one frame");
        _lastFrame = frame;
    }

    public override void OnDestroy()
    {
        if (_destroyed)
            Log.Error("CYCLE duplicate OnDestroy");
        _destroyed = true;
        Live--;
    }
}
'''

RESULT_RE = re.compile(r"PLAY CYCLE TEST (PASS|FAIL): (.*)")
NUMBERS_RE = re.compile(r"(\d+) cycles, (\d+) C# scripts each; Play ([\d.]+) ms \(first ([\d.]+)\), Stop ([\d.]+) ms \(medians\); memory (\d+) MB -> (\d+) MB")


def make_project(work: Path, count: int) -> Path:
    project = work / f"Cycle{count}"
    created = subprocess.run([str(LAUNCHER), "--create", str(project)], capture_output=True, text=True)
    if created.returncode != 0:
        raise SystemExit(created.stdout + created.stderr)
    for script in (project / "src").rglob("*.cs"):
        script.unlink()
    (project / "src/Scripts").mkdir(parents=True, exist_ok=True)
    (project / "src/Scripts/Ticker.cs").write_text(TICKER)
    lines = ['scene "Cycle"', 'object 1 parent 0 active 1 name "Main Camera"', "transform 0 2 -20 0 0 0 1 1 1 1",
             "component Tallow.Camera enabled 1"]
    side = max(1, int(count ** 0.5))
    for index in range(count):
        lines += [f'object {index + 2} parent 0 active 1 name "Ticker"',
                  f"transform {index % side} 0 {index // side} 0 0 0 1 1 1 1",
                  "component Tallow.CSharpBehaviour enabled 1", 'field scriptType "Cycle.Ticker"', 'field fieldOverrides ""']
    (project / "src/Scenes").mkdir(parents=True, exist_ok=True)
    (project / "src/Scenes/Cycle.tscene").write_text("\n".join(lines) + "\n")
    text = (project / "project.tallow").read_text()
    text = re.sub(r"(?m)^startScene = .*$", "startScene = Scenes/Cycle.tscene", text)
    if "startScene" not in text:
        text += "startScene = Scenes/Cycle.tscene\n"
    (project / "project.tallow").write_text(text)
    return project


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cycles", type=int, default=100)
    parser.add_argument("--counts", default="0,100,1000,10000")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        print("run_play_cycle_bench.py needs a display.", file=sys.stderr)
        return 2
    args.output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="tallow-b06-"))
    rows = []
    try:
        for count in (int(c) for c in args.counts.split(",")):
            project = make_project(work, count)
            output, ready, total = open_editor(project, "--play-cycle-test", str(args.cycles), timeout=3600,
                                               env={"XDG_DATA_HOME": str(work / "xdg")})
            (args.output / f"cycle-{count}.log").write_text(output)
            result = RESULT_RE.findall(output)
            numbers = NUMBERS_RE.search(result[-1][1]) if result else None
            errors = [l for l in output.splitlines() if re.search(r"CYCLE (duplicate|two LocalUpdates|Update after)", l)]
            row = {
                "scripts": count, "passed": bool(result) and result[-1][0] == "PASS", "report": result[-1][1] if result else None,
                "cycles": int(numbers.group(1)) if numbers else None,
                "scripts_seen": int(numbers.group(2)) if numbers else None,
                "play_median_ms": float(numbers.group(3)) if numbers else None,
                "play_first_ms": float(numbers.group(4)) if numbers else None,
                "stop_median_ms": float(numbers.group(5)) if numbers else None,
                "memory_mb": (int(numbers.group(6)), int(numbers.group(7))) if numbers else None,
                "callback_errors": len(errors),
                "retained_games": "unloaded game assemblies are still in memory" in output,
                "ready_s": round(ready, 1) if ready else None, "total_s": round(total, 1),
            }
            rows.append(row)
            print(json.dumps(row), flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    (args.output / "results.json").write_text(json.dumps(rows, indent=1))
    lines = [f"# B06 Play/Stop cycles ({args.cycles} each)", "",
             "| scripts | pass | cycles | Play median ms | first Play ms | Stop median ms | memory MB (2nd -> last) | callback errors | games retained |",
             "|---:|---|---:|---:|---:|---:|---|---:|---|"]
    for r in rows:
        memory = f"{r['memory_mb'][0]} -> {r['memory_mb'][1]}" if r["memory_mb"] else "-"
        lines.append(f"| {r['scripts']} | {r['passed']} | {r['cycles']} | {r['play_median_ms']} | {r['play_first_ms']} | "
                     f"{r['stop_median_ms']} | {memory} | {r['callback_errors']} | {r['retained_games']} |")
    (args.output / "summary.md").write_text("\n".join(lines) + "\n")
    print((args.output / "summary.md").read_text())
    return 0 if all(r["passed"] and not r["callback_errors"] and not r["retained_games"] for r in rows) else 1


if __name__ == "__main__":
    sys.exit(main())
