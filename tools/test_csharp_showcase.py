#!/usr/bin/env python3
"""The Tallow Gallery template, all C#: creates a project from it, compiles its scripts and plays it headless with
its test switches (fire, cut, net report). Passes on SHOWCASE_READY with eight rooms and two probes, robots that
move, and no errors. tools/validate_showcase.py checks the same template from a release package.

    python3 tools/test_csharp_showcase.py [--config Debug] [--keep]
"""
from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="Debug")
    parser.add_argument("--keep", action="store_true", help="keep the temporary project")
    args = parser.parse_args()
    windows = platform.system() == "Windows"
    target = f"{args.config}_{'Win64' if windows else 'Linux64'}"
    launcher = ROOT / "build" / target / "TallowLauncher" / ("TallowLauncher.exe" if windows else "TallowLauncher")
    if not launcher.is_file():
        print(f"Build the engine first: {launcher} is missing.", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-showcase-"))
    try:
        project = work / "GalleryGame"

        def run(command: list[str], timeout: int = 600) -> str:
            result = subprocess.run([str(launcher)] + command, capture_output=True, text=True, timeout=timeout)
            return result.stdout + result.stderr if result.returncode == 0 else f"EXIT {result.returncode}\n" + result.stdout + result.stderr

        created = run(["--create", str(project), "--showcase"])
        if created.startswith("EXIT"):
            print(created)
            return 1
        if (project / "BeefProj.toml").exists() or list((project / "src").rglob("*.bf")):
            print("The Gallery template still writes Beef files.", file=sys.stderr)
            return 1
        built = run(["--build-project", str(project)])
        if built.startswith("EXIT") or ": warning CS" in built:
            print(built[-4000:])
            print("The Gallery's C# did not compile cleanly.", file=sys.stderr)
            return 1
        game = ["--game", "--project", str(project), "--headless"]
        log = run(game + ["--self-test", "--view", "4", "--fire-test", "6", "--cut-test", "20", "--net-report", "300", "--frames", "320"])
        early = run(game + ["--net-report", "30", "--frames", "40"])
        (work / "game.log").write_text(log, encoding="utf-8")
        failures = []
        if "SHOWCASE_READY rooms=8 probes=2" not in log:
            failures.append("no SHOWCASE_READY with eight rooms and two probes")
        errors = [line for line in log.splitlines() if "[error]" in line.lower() or "[Tallow C#]" in line]
        if errors or log.startswith("EXIT"):
            failures.append("errors while playing: " + "; ".join(errors[:5]))
        robots_late = [line for line in log.splitlines() if line.startswith("ROBOT ")]
        robots_early = [line for line in early.splitlines() if line.startswith("ROBOT ")]
        if len(robots_late) != 2 or robots_late == robots_early:
            failures.append(f"the patrol robots did not move ({robots_early} -> {robots_late})")
        for line in log.splitlines():
            if "SHOWCASE" in line or line.startswith("ROBOT"):
                print(line)
        if failures:
            print(log[-3000:])
            print("C# Gallery checks failed: " + "; ".join(failures), file=sys.stderr)
            return 1
        print("C# Gallery checks passed: created, compiled, eight rooms, two probes, firing, cutting, robots moving, no errors.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
