#!/usr/bin/env python3
"""A C# game built for release runs on its own.

Builds Tests/CSharpInGame with tools/build_player.py (Release: the precompiled
player, optimised assemblies, the .NET runtime bundled), then runs the built
executable from its folder, outside the project, and passes when every in-engine
check passes and the CLR it loaded is the bundled one.

    python3 tools/test_csharp_export.py [--keep]
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

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="keep the temporary project and build")
    args = parser.parse_args()
    if platform.system() == "Windows":
        print("Run this on Linux for now.", file=sys.stderr)
        return 2

    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-export-"))
    try:
        project = work / "InGame"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project, ignore=shutil.ignore_patterns(".tallow-*", "build"))
        template = (ROOT / "Editor/templates/empty/Scripts/FirstPersonCharacter.cs.txt").read_text(encoding="utf-8")
        (project / "src/Scripts/FirstPersonCharacter.cs").write_text(template.replace("{NAMESPACE}", "InGame"), encoding="utf-8")
        (project / "project.tallow").write_text(
            f"name = InGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        output = work / "Built"
        built = subprocess.run([sys.executable, str(ROOT / "tools/build_player.py"), str(project), "--output", str(output),
                                "--config", "Release"], capture_output=True, text=True)
        if built.returncode != 0:
            print(built.stdout[-6000:] + built.stderr[-6000:])
            print("The C# game did not build.", file=sys.stderr)
            return 1
        print("\n".join(line for line in built.stdout.splitlines() if "bundled" in line or "packaged" in line))
        for required in ("InGame", "game.tpak", "Managed/Runtime/Tallow.ManagedRuntime.dll", "Managed/Runtime/Tallow.API.dll",
                         "Managed/Game/Tallow.Game/Tallow.Game.dll", "dotnet/host/fxr"):
            if not (output / required).exists():
                print(f"The build lacks {required}.", file=sys.stderr)
                return 1
        sources = [str(path.relative_to(output)) for path in output.rglob("*") if path.suffix in (".cs", ".csproj", ".tasmdef")]
        if sources:
            print(f"The build contains C# sources: {sources}", file=sys.stderr)
            return 1
        # Run from the build's own folder, with no DOTNET_ROOT and no project beside it.
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DOTNET")}
        run = subprocess.run([str(output / "InGame"), "--headless", "--fixed-step", "--csharp-field-test", "--frames", "600"],
                             cwd=output, env=environment, capture_output=True, text=True, timeout=240)
        text = run.stdout + run.stderr
        lines = [line for line in text.splitlines() if "INGAME" in line or "[Tallow C#]" in line]
        passed = sum("INGAME PASS" in line for line in lines)
        failed = [line for line in lines if "INGAME FAIL" in line or "[Tallow C#]" in line]
        runtime = next((line.split("INGAME RUNTIME ", 1)[1].strip() for line in lines if "INGAME RUNTIME " in line), "")
        bundled = runtime.startswith(str(output / "dotnet"))
        print("\n".join(failed))
        print(f"CLR loaded from: {runtime or '(not reported)'}")
        if run.returncode != 0 or failed or not any("INGAME DONE" in line for line in lines) or not bundled:
            if not lines:
                print(text[-4000:])
            print(f"The built C# game failed (exit {run.returncode}, {passed} passed, {len(failed)} failed, "
                  f"bundled runtime {'used' if bundled else 'NOT used'}).", file=sys.stderr)
            return 1
        print(f"The built C# game passed {passed} checks on its bundled .NET runtime.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
