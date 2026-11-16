#!/usr/bin/env python3
"""Benchmark B09: Inspector fields of many C# scripts, through the editor (--inspector-scale-test N, see
Editor/src/Tools/InspectorScaleTest.bf) on a scratch copy of Samples/CSharpBench. Needs a display.
For each count: make N scripted objects and edit two fields each, save, open again, Play (every Awake must see the
saved values), Stop. Run: python3 tools/benchmark_inspector_scale.py [--counts 1000 10000]
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LAUNCHER = ROOT / "build/Debug_Linux64/TallowLauncher/TallowLauncher"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--counts", type=int, nargs="+", default=[1000, 10000])
    options = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="tallow-inspector-scale-"))
    failed = 0
    try:
        # The editor's layout and settings go to the scratch folder, not the user's.
        env = {**os.environ, "XDG_DATA_HOME": str(work / "data")}
        for count in options.counts:
            project = work / f"Bench{count}"
            shutil.copytree(ROOT / "Samples/CSharpBench", project,
                            ignore=shutil.ignore_patterns(".tallow-*", "build", "bin", "obj"))
            text = (project / "project.tallow").read_text(encoding="utf-8")
            (project / "project.tallow").write_text(
                re.sub(r"(?m)^engine = .*$", f"engine = {ROOT.as_posix()}", text), encoding="utf-8")
            result = subprocess.run([str(LAUNCHER), "--editor", "--project", str(project),
                                     "--inspector-scale-test", str(count)],
                                    capture_output=True, text=True, errors="replace", env=env, timeout=1800)
            output = result.stdout + result.stderr
            line = next((l for l in output.splitlines() if "INSPECTOR SCALE TEST" in l), "no result")
            awake = next((l for l in output.splitlines() if "SCALE AWAKE" in l), "")
            # N probes + a prefab copy, one probe with an unreadable value refused (and named in the log).
            named = f"'Probe {count - 1}': a saved field of ScaleProbe could not be read" in output
            ok = "PASS" in line and f"checked={count} wrong=0" in awake and named
            print(f"{'PASS' if ok else 'FAIL'}: {line.split('TEST ')[-1].split(': ', 1)[-1]} | {awake.split('] ')[-1].strip()}")
            failed += not ok
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
