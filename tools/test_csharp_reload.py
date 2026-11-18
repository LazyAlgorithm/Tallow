#!/usr/bin/env python3
"""C# hot reload while playing: builds Tests/CSharpReload (version 1), builds it again with v2/Scripts in place of
src/Scripts into another folder, plays version 1 headless and reloads version 2 into it on frame 120
(--csharp-reload-test). Version 2's Counter reports RELOAD PASS/FAIL lines on what the reload kept.

    python3 tools/test_csharp_reload.py [--config Debug] [--keep]
"""
from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = 33


def build(project: Path, *extra: str) -> bool:
    run = subprocess.run(["dotnet", "run", "--project", str(ROOT / "Managed/Tallow.Build/Tallow.Build.csproj"), "--",
                          "--project", str(project), "--engine-root", str(ROOT), *extra], capture_output=True, text=True)
    if run.returncode != 0:
        print(run.stdout + run.stderr)
    return run.returncode == 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default="Debug")
    parser.add_argument("--keep", action="store_true", help="keep the temporary projects")
    args = parser.parse_args()
    windows = platform.system() == "Windows"
    target = f"{args.config}_{'Win64' if windows else 'Linux64'}"
    launcher = ROOT / "build" / target / "TallowLauncher" / ("TallowLauncher.exe" if windows else "TallowLauncher")
    if not launcher.is_file():
        print(f"Build the engine first: {launcher} is missing.", file=sys.stderr)
        return 2
    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-reload-"))
    try:
        project = work / "Reload"
        shutil.copytree(ROOT / "Tests/CSharpReload", project, ignore=shutil.ignore_patterns(".tallow-*", "build", "v2"))
        (project / "project.tallow").write_text(
            f"name = Reload\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        second = work / "Reload2"
        shutil.copytree(project, second)
        shutil.rmtree(second / "src/Scripts")
        shutil.copytree(ROOT / "Tests/CSharpReload/v2/Scripts", second / "src/Scripts")
        if not build(project) or not build(second, "--output", str(work / "v2bin")):
            print("The reload test project did not compile.", file=sys.stderr)
            return 1
        subprocess.run(["dotnet", "build", str(ROOT / "Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj"),
                        "--configuration", "Debug", "--nologo", "--verbosity", "quiet"], check=True)
        run = subprocess.run([str(launcher), "--game", "--project", str(project), "--headless", "--fixed-step",
                              "--csharp-reload-test", str(work / "v2bin/Tallow.Game/Tallow.Game.dll"), "--frames", "400"],
                             capture_output=True, text=True, timeout=180,
                             env={**os.environ, "TALLOW_RELOAD_UNLOAD_CHECK": "1"})
        output = run.stdout + run.stderr
        lines = [line for line in output.splitlines() if "RELOAD" in line or "[Tallow C#]" in line or "is gone after" in line
                 or "Hot reload:" in line]
        print("\n".join(lines))
        passed = sum("RELOAD PASS" in line for line in lines)
        if any("is gone after the reload" in line for line in lines):
            passed += 1
            print("RELOAD PASS the editor is told which script stopped")
        dropped = next((line for line in lines if "Hot reload:" in line and "field(s)" in line), "")
        if "Counter._kind" in dropped and "Counter._removed" in dropped and "_callback" not in dropped:
            passed += 1
            print("RELOAD PASS the warning names the fields that started again (not delegates)")
        awaits = next((line for line in lines if "Hot reload: awaits of the old code ended" in line), "")
        if "(Partner)" in awaits and "OnReload" in awaits:
            passed += 1
            print("RELOAD PASS the warning names the script whose await ended")
        failed = [line for line in lines if "RELOAD FAIL" in line or "[Tallow C#]" in line]
        if "RELOAD kept 2 scripts" not in output:
            failed.append("RELOAD FAIL two of three scripts kept")
        if "RELOAD DONE" not in output:
            failed.append("RELOAD FAIL version 2 never finished its checks")
        if failed or passed != EXPECTED:
            print("\n".join(failed) or output[-3000:])
            print(f"C# reload checks failed ({passed} of {EXPECTED} passed).", file=sys.stderr)
            return 1
        print(f"C# reload checks passed: {passed}.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
