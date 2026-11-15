#!/usr/bin/env python3
"""Run the C# gameplay API checks inside the real engine.

Builds Tests/CSharpInGame with the .NET SDK, then starts it in the built
player without a window. The scripts log one "INGAME PASS/FAIL" line per check
and "INGAME DONE" at the end. Unlike the native-host smoke test, nothing is
mocked: the scene, Jolt and Flecs are the engine's own.

    python3 tools/test_csharp_ingame.py [--config Debug]
"""
from __future__ import annotations

import argparse
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

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

    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-ingame-"))
    try:
        project = work / "InGame"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project,
                        ignore=shutil.ignore_patterns(".tallow-*", "build"))
        template = (ROOT / "Editor/templates/empty/Scripts/FirstPersonCharacter.cs.txt").read_text(encoding="utf-8")
        (project / "src/Scripts/FirstPersonCharacter.cs").write_text(
            template.replace("{NAMESPACE}", "InGame"), encoding="utf-8")
        (project / "project.tallow").write_text(
            f"name = InGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")

        build = subprocess.run(
            ["dotnet", "run", "--project", str(ROOT / "Managed/Tallow.Build/Tallow.Build.csproj"),
             "--", "--project", str(project), "--engine-root", str(ROOT)],
            capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            print("C# test project did not compile.", file=sys.stderr)
            return 1
        subprocess.run(["dotnet", "build", str(ROOT / "Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj"),
                        "--configuration", "Debug", "--nologo", "--verbosity", "quiet"], check=True)

        run = subprocess.run(
            [str(launcher), "--game", "--project", str(project), "--headless", "--fixed-step", "--csharp-field-test", "--frames", "600"],
            capture_output=True, text=True, timeout=180)
        output = run.stdout + run.stderr
        lines = [line for line in output.splitlines() if "INGAME" in line or "[Tallow C#]" in line]
        print("\n".join(lines))
        passed = sum("INGAME PASS" in line for line in lines)
        # Thrower throws on purpose: allowed, but it must be logged once, naming the file and line it threw on.
        expected = "thrown on purpose by Thrower"
        failed = [line for line in lines if "INGAME FAIL" in line or ("[Tallow C#]" in line and "thrown on purpose" not in line)]
        thrown = [line for line in output.splitlines() if line.startswith("[error] System.InvalidOperationException: " + expected)]
        source = (project / "src/Scripts/ApiChecks.cs").read_text().splitlines()
        throw_line = next(i + 1 for i, text in enumerate(source) if expected in text and "throw" in text)
        if len(thrown) == 1 and f"InGame.Thrower.Update" in thrown[0] and f"at ApiChecks.cs:{throw_line})" in thrown[0]:
            passed += 1
            print("INGAME PASS a script exception is logged once with the game file and line it was thrown on")
        else:
            failed.append(f"INGAME FAIL script exception report: {thrown or 'not logged'}")
            print(failed[-1])
        boom = [line for line in output.splitlines()
                if line.startswith("[error] System.InvalidOperationException: thrown on purpose by async code (in async code")]
        if len(boom) == 1 and "AsyncProbe" in boom[0] and "ApiChecks.cs:" in boom[0]:
            passed += 1
            print("INGAME PASS an exception after an await is logged with its script's line")
        else:
            failed.append(f"INGAME FAIL async exception report: {boom or 'not logged'}")
            print(failed[-1])
        if run.returncode != 0 or failed or not any("INGAME DONE" in line for line in lines):
            if not lines:
                print(output[-4000:])
            print(f"In-engine C# checks failed (exit {run.returncode}, {passed} passed, {len(failed)} failed).",
                  file=sys.stderr)
            return 1
        print(f"In-engine C# checks passed: {passed}.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
