#!/usr/bin/env python3
"""B30: a release export ships no symbols, and its private ones read a crash.

Builds Tests/CSharpInGame as a NativeAOT Linux export (tools/build_player.py --csharp-runtime native), then:
  1. the package's player has no debug sections and the package holds no .dbg/.pdb;
  2. <output>-symbols holds the player's .dbg, the game library's .dbg, its map and build-info.txt;
  3. build-info names the exact identifiers of the shipped modules (SHA-256, and the ELF build ID of the library);
  4. the package runs with no .NET, Beef or dotnet on PATH and passes its in-game checks;
  5. a run with --crash-test crashes on purpose, and gdb names
     bf::Tallow::CrashReports::DeliberateCrash() only through the private player symbols.

Local only (it needs gdb and a full NativeAOT build; gdb is the "crash tool" here). Windows does the same with a
.pdb and a Windows debugger; the Windows symbols are written by the same build (TallowPlayer_lld.pdb).

    python3 tools/test_csharp_crash.py [--keep]
"""
from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

ROOT = Path(__file__).resolve().parents[1]


def read_info(symbols: Path) -> dict[str, str]:
    info: dict[str, str] = {}
    for line in (symbols / "build-info.txt").read_text(encoding="utf-8").splitlines():
        if ":" in line and not line.startswith(" "):
            key, value = line.split(":", 1)
            info[key.strip()] = value.strip()
    return info


def has_debug_sections(executable: Path) -> bool:
    result = subprocess.run(["readelf", "-S", str(executable)], capture_output=True, text=True)
    return any(name in result.stdout for name in (".debug_info", ".debug_line", ".debug_str"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="keep the temporary project and build")
    args = parser.parse_args()
    if platform.system() != "Linux":
        print("This check runs on Linux (gdb reads the ELF symbols).", file=sys.stderr)
        return 2
    tools = {}
    for tool in ("gdb", "readelf", "objcopy"):
        tools[tool] = shutil.which(tool)
        if not tools[tool]:
            print(f"This check needs {tool}.", file=sys.stderr)
            return 2
    work = Path(tempfile.mkdtemp(prefix="tallow-csharp-crash-"))
    checks = 0
    try:
        project = work / "InGame"
        shutil.copytree(ROOT / "Tests/CSharpInGame", project, ignore=shutil.ignore_patterns(".tallow-*", "build"))
        template = (ROOT / "Editor/templates/empty/Scripts/FirstPersonCharacter.cs.txt").read_text(encoding="utf-8")
        (project / "src/Scripts/FirstPersonCharacter.cs").write_text(template.replace("{NAMESPACE}", "InGame"), encoding="utf-8")
        (project / "project.tallow").write_text(
            f"name = InGame\nstartScene = Scenes/Main.tscene\nengine = {ROOT.as_posix()}\n", encoding="utf-8")
        output = work / "Built"
        built = subprocess.run([sys.executable, str(ROOT / "tools/build_player.py"), str(project), "--output", str(output),
                                "--config", "Release", "--platform", "linux", "--csharp-runtime", "native"],
                               capture_output=True, text=True)
        if built.returncode != 0:
            print(built.stdout[-6000:] + built.stderr[-6000:])
            print("The NativeAOT export did not build.", file=sys.stderr)
            return 1
        executable = output / "InGame"
        symbols = output.parent / (output.name + "-symbols")
        print("\n".join(line for line in built.stdout.splitlines() if "NativeAOT" in line or "Player: stripped" in line or "Build information" in line))

        checks += 1
        shipped = [str(path.relative_to(output)) for path in output.rglob("*")
                   if path.suffix in (".dbg", ".pdb", ".map")]
        if shipped or has_debug_sections(executable):
            print(f"The package ships symbols ({shipped}) or its player keeps debug sections.", file=sys.stderr)
            return 1
        print("The package ships no debug sections, .dbg, .pdb or map files.")

        checks += 1
        expected = ["InGame.dbg", "libTallowGame.so.dbg", "libTallowGame.so.dbg.map", "build-info.txt"]
        missing = [name for name in expected if not (symbols / name).is_file()]
        if missing:
            print(f"The private symbols are missing: {missing} (in {symbols}).", file=sys.stderr)
            return 1
        print(f"The private symbols are in {symbols}: {', '.join(expected)}.")

        checks += 1
        info = read_info(symbols)
        import hashlib
        sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
        library = output / "Managed/Native/libTallowGame.so"
        problems = []
        for title, path in (("player", executable), ("game library", library)):
            if info.get(f"{title} sha256") != sha(path):
                problems.append(f"{title}: SHA-256 in build-info.txt does not match the shipped file")
        build_id = re.search(r"Build ID: ([0-9a-f]+)",
                             subprocess.run(["readelf", "-n", str(library)], capture_output=True, text=True).stdout)
        if not build_id or info.get("game library build id") != build_id.group(1):
            problems.append("the library's ELF build ID in build-info.txt does not match the shipped library")
        if info.get("game code id", "none") == "(none)":
            problems.append("build-info.txt does not name the game code ID")
        if problems:
            print("\n".join(problems), file=sys.stderr)
            return 1
        print(f"Build information matches the shipped files (player {sha(executable)[:12]}, "
              f"library {sha(library)[:12]} and its ELF build ID).")

        # A machine with no .NET, Beef or dotnet: only the package itself.
        clean = {"HOME": str(work / "home"), "PATH": "/usr/bin:/bin", "XDG_DATA_HOME": str(work / "data")}
        Path(clean["HOME"]).mkdir()

        checks += 1
        run = subprocess.run([str(executable), "--headless", "--fixed-step", "--frames", "300"],
                             cwd=output, env=clean, capture_output=True, text=True, timeout=600)
        if run.returncode != 0 or "INGAME DONE" not in run.stdout:
            print((run.stdout + run.stderr)[-4000:])
            print(f"The clean-room run failed (exit {run.returncode}).", file=sys.stderr)
            return 1
        print("The package ran with no .NET, Beef or dotnet on PATH and passed its in-game checks.")

        checks += 1
        crash = subprocess.run([tools["gdb"], "-batch", "-q", "-ex", f"set debug-file-directory {symbols}", "-ex", "run",
                                "-ex", "bt 8", "--args", str(executable), "--headless", "--fixed-step", "--crash-test",
                                "--frames", "600"],
                               cwd=output, env=clean, capture_output=True, text=True, timeout=600)
        text = crash.stdout + crash.stderr
        fault = "SIGSEGV" in text
        named = "bf::Tallow::CrashReports::DeliberateCrash()" in text
        if not (fault and named):
            print(text[-5000:])
            print(f"The crash was {'raised' if fault else 'NOT raised'} and the private symbols "
                  f"{'named' if named else 'did NOT name'} DeliberateCrash.", file=sys.stderr)
            return 1
        print("The deliberate crash reads through the private player symbols: "
              + next(line.strip() for line in text.splitlines() if "DeliberateCrash()" in line))
        print(f"{checks} checks pass: a release export ships no symbols, and its private ones read a crash.")
        return 0
    finally:
        if args.keep:
            print(f"Kept {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
