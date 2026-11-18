#!/usr/bin/env python3
"""B22, game export portability (docs/csharp-benchmark-plan.md): exported Release players run on clean Linux machines
(podman containers of stock distribution images: no Beef, no .NET SDK or runtime, no Python on PATH for the game, no
Tallow) and, for Windows exports, under Wine.

For each export (a folder made by tools/build_player.py) and each image, the export is mounted read-only and run
headless --runs times, in a fresh container each time. The first run is the coldest one available; it is not
fully cold, because containers share the host's page cache. Recorded: packaged size (and
the bundled .NET runtime's part), wall time to exit, the exit code, whether the log shows the bundled runtime was
used, errors in the log, and whether anything tried to build: `BeefBuild`, `dotnet`, `beefbuild`, `python3`,
`python`, `clang`, `cc`, `gcc` and `ld` on the container's PATH are stand-ins that record being started (then fail).

    python3 tools/test_export_portability.py --export NAME=DIR[:ENVVAR=VALUE,...] ... --output OUT

An export runs as `<DIR>/<NAME> --headless` (or NAME.exe under Wine when --wine is given for it), with the given
environment, and must exit 0 by itself (a bench mode that quits, or an in-game check run).
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

IMAGES = ["docker.io/library/ubuntu:22.04", "registry.fedoraproject.org/fedora:43"]
WATCHED = ["BeefBuild", "beefbuild", "dotnet", "python3", "python", "clang", "cc", "gcc", "ld"]


def folder_size(path: Path) -> int:
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


def make_traps(folder: Path) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    for name in WATCHED:
        trap = folder / name
        trap.write_text(f"#!/bin/sh\necho \"{name} $*\" >> /trap/calls.log\nexit 127\n")
        trap.chmod(0o755)


def run_linux(name: str, folder: Path, env: dict, image: str, run: int, output: Path, timeout: float) -> dict:
    work = Path(tempfile.mkdtemp(prefix="b22-", dir=output))
    traps = work / "bin"
    make_traps(traps)
    calls = work / "trap"
    calls.mkdir()
    (calls / "calls.log").write_text("")
    command = ["podman", "run", "--rm", "--network", "none", "-v", f"{folder}:/game:ro,Z", "-v", f"{traps}:/traps:ro,Z",
               "-v", f"{calls}:/trap:Z", "-w", "/game", "-e", "PATH=/traps:/usr/bin:/bin", "-e", "HOME=/tmp/home"]
    for key, value in env.items():
        command += ["-e", f"{key}={value}"]
    command += [image, "sh", "-c", f"mkdir -p /tmp/home && exec /game/{name} --headless"]
    started = time.monotonic()
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        code, text = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as expired:
        code, text = "timeout", (expired.stdout or b"").decode(errors="replace") + (expired.stderr or b"").decode(errors="replace")
    seconds = time.monotonic() - started
    log = output / f"{name}-{image.rsplit('/', 1)[-1].replace(':', '-')}-{run}.log"
    log.write_text(text)
    tried = [line for line in (calls / "calls.log").read_text().splitlines() if line.strip()]
    shutil.rmtree(work, ignore_errors=True)
    return result_row(name, image, run, code, seconds, text, tried)


def run_wine(name: str, folder: Path, env: dict, run: int, output: Path, timeout: float) -> dict:
    exe = folder / f"{name}.exe"
    prefix = Path(tempfile.mkdtemp(prefix="b22-wine-", dir=output))
    started = time.monotonic()
    try:
        done = subprocess.run(["wine", str(exe), "--headless"], cwd=folder, capture_output=True, text=True, timeout=timeout,
                              env=dict(os.environ, WINEPREFIX=str(prefix), WINEDEBUG="-all", **env))
        code, text = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as expired:
        code, text = "timeout", ""
    seconds = time.monotonic() - started
    (output / f"{name}-wine-{run}.log").write_text(text)
    shutil.rmtree(prefix, ignore_errors=True)
    return result_row(name, "wine (fresh prefix, no .NET installed in it)", run, code, seconds, text, [])


def result_row(name, image, run, code, seconds, text, tried) -> dict:
    lines = text.splitlines()
    errors = [l for l in lines if "[error]" in l or "Unhandled exception" in l or "FATAL" in l or "Segmentation" in l]
    bundled = any("dotnet" in l and ("bundled" in l.lower() or "/dotnet/" in l or "\\dotnet\\" in l) for l in lines)
    return {"export": name, "image": image, "run": run, "exit": code, "seconds": round(seconds, 2),
            "build_attempts": tried, "errors": errors[:5], "error_count": len(errors),
            "bundled_runtime_seen": bundled, "last_line": lines[-1][:200] if lines else ""}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--export", action="append", required=True, help="NAME=DIR[:KEY=VALUE,...]")
    parser.add_argument("--wine", action="append", default=[], help="NAME=DIR[:KEY=VALUE,...] of a Windows export")
    parser.add_argument("--image", action="append", help=f"container images (default {IMAGES})")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    images = args.image or IMAGES

    def parse(spec: str):
        name, rest = spec.split("=", 1)
        folder, _, extra = rest.partition(":")
        env = dict(item.split("=", 1) for item in extra.split(",") if item)
        return name, Path(folder).resolve(), env

    rows, sizes = [], {}
    for spec in args.export:
        name, folder, env = parse(spec)
        dotnet = folder / "dotnet"
        sizes[name] = {"total_mb": folder_size(folder) / 2**20, "dotnet_mb": folder_size(dotnet) / 2**20 if dotnet.exists() else 0}
        for image in images:
            for run in range(args.runs):
                row = run_linux(name, folder, env, image, run, args.output, args.timeout)
                rows.append(row)
                print(json.dumps(row), flush=True)
    for spec in args.wine:
        name, folder, env = parse(spec)
        dotnet = folder / "dotnet"
        sizes[name + " (Windows)"] = {"total_mb": folder_size(folder) / 2**20, "dotnet_mb": folder_size(dotnet) / 2**20 if dotnet.exists() else 0}
        for run in range(args.runs):
            row = run_wine(name, folder, env, run, args.output, args.timeout)
            rows.append(row)
            print(json.dumps(row), flush=True)
    (args.output / "results.json").write_text(json.dumps({"sizes": sizes, "runs": rows}, indent=1))

    lines = ["# B22 game export portability", "", "| export | size MB | bundled .NET MB |", "|---|---:|---:|"]
    lines += [f"| {name} | {s['total_mb']:.1f} | {s['dotnet_mb']:.1f} |" for name, s in sizes.items()]
    lines += ["", "| export | machine | run | exit | seconds | build tools started | errors |", "|---|---|---:|---:|---:|---|---:|"]
    for r in rows:
        lines.append(f"| {r['export']} | {r['image']} | {r['run']} | {r['exit']} | {r['seconds']} | "
                     f"{', '.join(r['build_attempts']) or 'none'} | {r['error_count']} |")
    (args.output / "summary.md").write_text("\n".join(lines) + "\n")
    print((args.output / "summary.md").read_text())
    failed = [r for r in rows if r["exit"] != 0 or r["build_attempts"] or r["error_count"]]
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
