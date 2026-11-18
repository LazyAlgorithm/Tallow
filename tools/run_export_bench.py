#!/usr/bin/env python3
"""B22, game export portability (docs/csharp-benchmark-plan.md): exported Release players run where no Beef, no .NET
SDK, no project and no home folder exist.

On Linux each player runs in a bubblewrap sandbox: the system's /usr and /etc read-only, the system .NET hidden
(/usr/lib64/dotnet, /usr/share/dotnet and /usr/lib/dotnet are empty there), an empty home, only the player's own
folder, and a PATH whose compilers (BeefBuild, dotnet, clang, cc, gcc, ld, cmake, ninja...) are stand-ins that write
down that they were called and fail. So a C# player can only start on its bundled .NET runtime, and any attempt to
compile is caught. A Windows player (--windows, built on Linux) runs under Wine, without the sandbox.

Per player: the package's size (and its parts), launch to exit after one frame (--frames 1: the first run, then the
median of the rest), --stability runs of 300 frames with 1,000 scripted cubes (exits that were not 0, crashes,
error lines), and every compiler call.

    python3 tools/run_export_bench.py --player OUT-CS/CSharpBench --player OUT-BEEF/EcsBench \
        [--windows OUT-WIN/CSharpBench.exe] --output DIR
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

COMPILERS = ["BeefBuild", "BeefBuild_d", "dotnet", "clang", "clang++", "clang-cl", "cc", "c++", "gcc", "g++", "ld",
             "ld.lld", "lld", "cmake", "ninja", "make", "msbuild", "csc"]
ERROR_RE = re.compile(r"\b(error|exception|fatal|segmentation|unhandled)\b", re.IGNORECASE)


def folder_size(path: Path) -> int:
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file() and not f.is_symlink())


def sizes(player: Path) -> dict:
    folder = player.parent
    parts = {"total": folder_size(folder)}
    for name in ("dotnet", "Managed"):
        if (folder / name).is_dir():
            parts[name] = folder_size(folder / name)
    for name in ("game.tpak",):
        if (folder / name).exists():
            parts[name] = (folder / name).stat().st_size
    parts["executable"] = player.stat().st_size
    parts["native libraries"] = sum(f.stat().st_size for f in folder.iterdir() if f.suffix in (".so", ".dll"))
    return parts


def stand_ins(folder: Path, log: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    for name in COMPILERS:
        script = folder / name
        script.write_text(f"#!/bin/sh\necho \"{name} $*\" >> {log}\nexit 1\n")
        script.chmod(0o755)


def sandboxed(player: Path, arguments: list[str], environment: dict, scratch: Path) -> list[str]:
    folder = player.parent
    command = ["bwrap", "--ro-bind", "/usr", "/usr", "--ro-bind", "/etc", "/etc",
               "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
               "--symlink", "usr/bin", "/bin", "--symlink", "usr/sbin", "/sbin",
               "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/home",
               "--bind", str(folder), "/game", "--bind", str(scratch), "/scratch",
               "--clearenv", "--setenv", "PATH", "/scratch/bin:/usr/bin", "--setenv", "HOME", "/home/player",
               "--chdir", "/game"]
    for hidden in ("/usr/lib64/dotnet", "/usr/share/dotnet", "/usr/lib/dotnet"):
        if Path(hidden).is_dir():
            command += ["--tmpfs", hidden]
    for key, value in environment.items():
        command += ["--setenv", key, value]
    return command + ["--", f"/game/{player.name}"] + arguments


def run(player: Path, arguments: list[str], environment: dict, scratch: Path | None, wine_prefix: Path | None,
        timeout: int) -> tuple[int, float, str]:
    if scratch is not None:
        command = sandboxed(player, arguments, environment, scratch)
        env = None
    else:
        command = ["wine", str(player)] + arguments
        env = {k: v for k, v in os.environ.items() if not k.startswith("DOTNET")}
        env.update(environment, WINEDEBUG="-all")
        if wine_prefix:
            env["WINEPREFIX"] = str(wine_prefix)
    started = time.monotonic()
    try:
        done = subprocess.run(command, env=env, cwd=player.parent, capture_output=True, text=True, timeout=timeout)
        return done.returncode, time.monotonic() - started, done.stdout + done.stderr
    except subprocess.TimeoutExpired as expired:
        output = (expired.stdout or b"").decode(errors="replace") + (expired.stderr or b"").decode(errors="replace")
        return -999, time.monotonic() - started, output


def measure(player: Path, label: str, args, scratch: Path | None) -> dict:
    wine_prefix = Path(os.environ.get("TALLOW_WIN", Path.home() / ".local/share/tallow-win")) / "wine"
    quiet = {"TALLOW_BENCH_MODE": "gameobject", "TALLOW_BENCH_COUNT": "1", "TALLOW_BENCH_FRAMES": "100000"}
    starts, first_output = [], ""
    for index in range(args.starts):
        code, seconds, text = run(player, ["--headless", "--frames", "1"], quiet, scratch, wine_prefix, 300)
        if index == 0:
            first_output = text
        starts.append({"exit": code, "seconds": round(seconds, 3)})
    (args.output / f"{label}-first-start.log").write_text(first_output)

    loaded = {"TALLOW_BENCH_MODE": "gameobject", "TALLOW_BENCH_COUNT": "1000", "TALLOW_BENCH_FRAMES": "100000"}
    failures, error_lines = [], []
    for index in range(args.stability):
        code, seconds, text = run(player, ["--headless", "--frames", "300"], loaded, scratch, wine_prefix, 600)
        if code != 0:
            failures.append({"run": index, "exit": code})
            (args.output / f"{label}-failed-{index}.log").write_text(text)
        error_lines += [line for line in text.splitlines() if ERROR_RE.search(line)]
    timings = [s["seconds"] for s in starts]
    return {
        "player": label,
        "sizes_mb": {k: round(v / 1e6, 1) for k, v in sizes(player).items()},
        "first_start_s": timings[0],
        "start_median_s": round(statistics.median(timings[1:] or timings), 3),
        "start_exits": sorted({s["exit"] for s in starts}),
        "stability_runs": args.stability,
        "stability_failures": failures,
        "error_lines": sorted(set(error_lines))[:20],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--player", type=Path, action="append", default=[], help="a Linux player executable")
    parser.add_argument("--windows", type=Path, action="append", default=[], help="a Windows player .exe (Wine)")
    parser.add_argument("--starts", type=int, default=6)
    parser.add_argument("--stability", type=int, default=20)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    if args.player and not shutil.which("bwrap"):
        sys.exit("bwrap (bubblewrap) is needed for the sandbox.")

    results, failed = [], False
    for player in args.player:
        player = player.resolve()
        with tempfile.TemporaryDirectory(prefix="tallow-export-bench-") as temp:
            scratch = Path(temp)
            log = scratch / "compiler-calls.log"
            stand_ins(scratch / "bin", Path("/scratch") / log.name)
            result = measure(player, f"linux-{player.name}", args, scratch)
            result["compiler_calls"] = log.read_text().splitlines() if log.exists() else []
        results.append(result)
    for player in args.windows:
        result = measure(player.resolve(), f"windows-{player.stem}", args, None)
        result["compiler_calls"] = "not watched under Wine"
        results.append(result)

    for result in results:
        bad = (result["start_exits"] != [0] or result["stability_failures"]
               or (isinstance(result["compiler_calls"], list) and result["compiler_calls"]))
        failed |= bool(bad)
        print(json.dumps(result))
    (args.output / "export-bench.json").write_text(json.dumps(results, indent=1))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
