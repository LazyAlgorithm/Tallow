#!/usr/bin/env python3
"""A C# game built for release runs on its own.

Builds Tests/CSharpInGame with tools/build_player.py (Release: the precompiled
player, optimised assemblies, the .NET runtime bundled), then runs the built
executable from its folder, outside the project, and passes when every in-engine
check passes and the CLR it loaded is the bundled one.

    python3 tools/test_csharp_export.py [--keep] [--platform windows] [--runtime native]

--runtime native builds the NativeAOT export (tools/csharp_native.py): the game compiled into
Managed/Native/(lib)TallowGame, no .NET runtime and no IL assemblies in the package, native symbols kept
beside it, not in it. The same in-engine checks must pass.

A Windows build made on Linux (tools/windows/setup.sh once; it bundles Microsoft's
Windows .NET runtime of the same version) is run under Wine, in the toolchain's
prefix (TALLOW_WIN, default ~/.local/share/tallow-win).
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
    parser.add_argument("--platform", choices=("linux", "windows"),
                        default="windows" if platform.system() == "Windows" else "linux")
    parser.add_argument("--runtime", choices=("jit", "native"), default="jit")
    args = parser.parse_args()
    native = args.runtime == "native"
    windows = args.platform == "windows"
    if not windows and platform.system() == "Windows":
        print("A Linux build is built and run on Linux.", file=sys.stderr)
        return 2
    wine = windows and platform.system() != "Windows"
    toolchain = Path(os.environ.get("TALLOW_WIN", Path.home() / ".local/share/tallow-win"))
    if wine and not shutil.which("wine"):
        print("Running a Windows build here needs Wine.", file=sys.stderr)
        return 2
    executable = "InGame.exe" if windows else "InGame"

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
                                "--config", "Release", "--platform", args.platform, "--csharp-runtime", args.runtime],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print(built.stdout[-6000:] + built.stderr[-6000:])
            print("The C# game did not build.", file=sys.stderr)
            return 1
        print("\n".join(line for line in built.stdout.splitlines() if "bundled" in line or "packaged" in line or "NativeAOT" in line))
        library = "Managed/Native/" + ("TallowGame.dll" if windows else "libTallowGame.so")
        required_files = (executable, "game.tpak", library, "Managed/Native/Tallow.Game.codeid") if native else (
            executable, "game.tpak", "Managed/Runtime/Tallow.ManagedRuntime.dll", "Managed/Runtime/Tallow.API.dll",
            "Managed/Game/Tallow.Game/Tallow.Game.dll", "dotnet/host/fxr")
        for required in required_files:
            if not (output / required).exists():
                print(f"The build lacks {required}.", file=sys.stderr)
                return 1
        if native:
            # Nothing of .NET's or the game's IL ships, and no symbols or source maps.
            shipped = [str(path.relative_to(output)) for path in output.rglob("*")
                       if path.is_file() and (path.suffix in (".pdb", ".dbg", ".map", ".deps.json", ".runtimeconfig.json")
                                             or (path.suffix == ".dll" and path.name != "TallowGame.dll"
                                                 and "Managed" in path.relative_to(output).parts))]
            if (output / "dotnet").exists() or (output / "Managed/Game").exists() or (output / "Managed/Runtime").exists() or shipped:
                print(f"The NativeAOT build ships .NET, IL assemblies or symbols: {shipped or 'dotnet/ or Managed/Game|Runtime'}",
                      file=sys.stderr)
                return 1
            symbols = output.parent / (output.name + "-symbols")
            if not (symbols / ("TallowGame.pdb" if windows else "libTallowGame.so.dbg")).is_file():
                print(f"The private native symbols are missing from {symbols}.", file=sys.stderr)
                return 1
        sources = [str(path.relative_to(output)) for path in output.rglob("*") if path.suffix in (".cs", ".csproj", ".tasmdef")]
        if sources:
            print(f"The build contains C# sources: {sources}", file=sys.stderr)
            return 1
        # Run from the build's own folder, with no DOTNET_ROOT and no project beside it.
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DOTNET")}
        if wine:
            environment.update(WINEPREFIX=str(toolchain / "wine"), WINEDEBUG="-all")
        command = (["wine"] if wine else []) + [str(output / executable)]
        run = subprocess.run(command + ["--headless", "--fixed-step", "--csharp-field-test", "--frames", "600"],
                             cwd=output, env=environment, capture_output=True, text=True, timeout=480 if wine else 240)
        text = run.stdout + run.stderr
        lines = [line for line in text.splitlines() if "INGAME" in line or "[Tallow C#]" in line]
        passed = sum("INGAME PASS" in line for line in lines)
        failed = [line for line in lines if "INGAME FAIL" in line or ("[Tallow C#]" in line and "thrown on purpose" not in line
                  # RunFieldTest's refused Inspector edit (see tools/test_csharp_ingame.py).
                  and "'not a number' was not in a correct format" not in line)]
        runtime = next((line.split("INGAME RUNTIME ", 1)[1].strip() for line in lines if "INGAME RUNTIME " in line), "")
        # Under Wine the game sees the folder as Z:\\... with backslashes.
        expected = ("Z:" + str(output / "dotnet").replace("/", "\\")) if wine else str(output / "dotnet")
        # NativeAOT has no runtime folder: .NET reports the game's own folder; never an installed or bundled .NET.
        bundled = ("dotnet" not in runtime.lower()) if native else runtime.lower().startswith(expected.lower())
        print("\n".join(failed))
        print(f"CLR loaded from: {runtime or '(not reported)'}{' (NativeAOT: the game folder)' if native else ''}")
        if run.returncode != 0 or failed or not any("INGAME DONE" in line for line in lines) or not bundled:
            if not lines:
                print(text[-4000:])
            print(f"The built C# game failed (exit {run.returncode}, {passed} passed, {len(failed)} failed, "
                  f"{'no .NET' if native else 'bundled runtime'} {'used' if bundled else 'NOT used'}).", file=sys.stderr)
            return 1
        notices = output / "THIRD-PARTY-NOTICES.txt"
        if not notices.exists() or "Newtonsoft.Json 13.0.4" not in notices.read_text():
            print("The build lacks THIRD-PARTY-NOTICES.txt naming its NuGet package.", file=sys.stderr)
            return 1
        where = "as NativeAOT, with no .NET" if native else "on its bundled .NET runtime"
        print(f"The built C# game ({args.platform}{', under Wine' if wine else ''}) passed {passed} checks {where}, with its third-party notices.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
