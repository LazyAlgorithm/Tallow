#!/usr/bin/env python3
"""B03's editor part, Save-to-Play (docs/csharp-benchmark-plan.md). Needs a display (the editor).

Opens the editor (--save-to-play-test N, Editor/src/Tools/SaveToPlayTest.bf) on a copy of each project. Each round
adds a comment line to one C# script in the code editor and saves it. Even rounds press Play in the same frame
(save, then Play: the build in between included); odd rounds wait for the build to finish (Play permitted), then
press Play. Each Play runs 10 frames. Reports the medians and every round's times.

    python3 tools/run_save_to_play_bench.py --rounds 10 --output DIR [--project Samples/Sandbox ...]
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_csharp_editor import ROOT, open_editor, project_copy  # noqa: E402

RESULT_RE = re.compile(r"SAVE TO PLAY TEST (PASS|FAIL): (.*)")
THEN_PLAY_RE = re.compile(r"SAVE TO PLAY ROUND (\d+) save then Play (\d+) ms")
BUILT_RE = re.compile(r"SAVE TO PLAY ROUND (\d+) save to build done (\d+) ms, then Play (\d+) ms")


def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--project", type=Path, action="append",
                        help="projects to copy (default: Samples/Sandbox)")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        print("run_save_to_play_bench.py needs a display.", file=sys.stderr)
        return 2
    projects = args.project or [ROOT / "Samples/Sandbox"]
    args.output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="tallow-save-to-play-"))
    rows, failed = [], False
    try:
        for source in projects:
            source = source.resolve()
            project = project_copy(work, source.name, source)
            output, _, total = open_editor(project, "--save-to-play-test", str(args.rounds), timeout=1800,
                                           env={"XDG_DATA_HOME": str(work / "xdg")})
            (args.output / f"save-to-play-{source.name}.log").write_text(output)
            result = RESULT_RE.findall(output)
            then_play = [float(m[1]) for m in THEN_PLAY_RE.findall(output)]
            built = [(float(m[1]), float(m[2])) for m in BUILT_RE.findall(output)]
            row = {"project": source.name, "passed": bool(result) and result[-1][0] == "PASS",
                   "report": result[-1][1] if result else None, "total_s": round(total, 1),
                   "save_then_play_ms": then_play, "save_to_build_ms": [b[0] for b in built],
                   "build_to_play_ms": [b[1] for b in built],
                   "median_save_then_play_ms": median(then_play),
                   "median_save_to_build_ms": median([b[0] for b in built]),
                   "median_build_to_play_ms": median([b[1] for b in built])}
            rows.append(row)
            failed |= not row["passed"]
            print(f"{source.name}: {'PASS' if row['passed'] else 'FAIL'} {row['report']}")
            if not row["passed"]:
                print(output[-3000:])
    finally:
        shutil.rmtree(work, ignore_errors=True)
    (args.output / "save-to-play.json").write_text(json.dumps(rows, indent=1))
    print("\n| project | save, then Play (median ms) | save to build done | build done to Play |")
    print("|---|---:|---:|---:|")
    for row in rows:
        print(f"| {row['project']} | {row['median_save_then_play_ms']} | {row['median_save_to_build_ms']} "
              f"| {row['median_build_to_play_ms']} |")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
