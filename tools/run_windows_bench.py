#!/usr/bin/env python3
"""B25/B26/B27 for Windows (docs/csharp-benchmark-plan.md), with the Windows players run under Wine on Linux.

These are the Windows x64 binaries, not a Windows kernel: start-up times, memory and frame times include Wine's
overhead and must not be read as native-Windows numbers. They are useful for comparing the JIT and NativeAOT
deployments of the same Windows build, and a replay hash that differs from Linux's says the simulation is not
portable (Jolt/float differences), which the plan asks to find and document rather than paper over.

    python3 tools/run_windows_bench.py --jit OUT-JIT/CSharpBench.exe --native OUT-NATIVE/TallowGame... \\
        --output DIR [--ticks 10000] [--runs 3] [--starts 5]

The players are the CSharpBench Windows exports of this engine (tools/build_player.py --platform windows). Wine
comes from TALLOW_WIN (default ~/.local/share/tallow-win; its wine prefix is TALLOW_WIN/wine).
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_csharp_bench import FIELDS, MODES  # noqa: E402
from run_rollback_bench import env as net_env, hash_of  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def wine_toolchain() -> Path:
    return Path(os.environ.get("TALLOW_WIN", Path.home() / ".local/share/tallow-win"))


def wine_env() -> dict[str, str]:
    return dict(os.environ, WINEPREFIX=str(wine_toolchain() / "wine"), WINEDEBUG="-all")


def size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if path.exists() else 0


def sizes(kind: str, player: Path) -> dict:
    folder = player.parent
    symbols = folder.parent / (folder.name + "-symbols")
    library = folder / "Managed/Native/TallowGame.dll"
    exports: list[str] = []
    if library.is_file():
        listing = subprocess.run(["llvm-readobj", "--coff-exports", str(library)],
                                 capture_output=True, text=True).stdout
        exports = sorted({line.split("Name: ", 1)[1].strip() for line in listing.splitlines() if "Name: " in line})
    shipped = [str(p.relative_to(folder)) for p in folder.rglob("*") if p.suffix in (".pdb", ".dbg")]
    private = {p.name: p.stat().st_size for p in symbols.glob("*") if p.is_file()}
    return {"kind": kind, "package_mb": round(size(folder) / 2**20, 1),
            "game_code_mb": round((size(folder / "Managed") + size(folder / "dotnet")) / 2**20, 1),
            "player_mb": round(player.stat().st_size / 2**20, 1),
            "private_symbols_mb": round(size(symbols) / 2**20, 1), "private_files": private,
            "exports": exports, "symbols_in_package": shipped}


def bench_mode(kind: str, player: Path, mode: str, count: int, frames: int, timeout: int) -> dict:
    env = wine_env() | {"TALLOW_BENCH_MODE": mode, "TALLOW_BENCH_COUNT": str(count),
                        "TALLOW_BENCH_FRAMES": str(frames)}
    done = subprocess.run(["wine", str(player), "--headless"], env=env, capture_output=True, text=True,
                          timeout=timeout, cwd=player.parent)
    for line in reversed((done.stdout + done.stderr).splitlines()):
        line = line.strip()
        if line.startswith("{") and '"mode"' in line:
            result = json.loads(line)
            result["kind"] = kind
            return result
    raise RuntimeError(f"{kind} {mode}: no result (exit {done.returncode})\n"
                       + (done.stdout + done.stderr)[-3000:])


def cold_start(kind: str, player: Path) -> dict:
    env = wine_env() | {"TALLOW_BENCH_MODE": "gameobject", "TALLOW_BENCH_COUNT": "1000",
                        "TALLOW_BENCH_FRAMES": "1"}
    started = time.perf_counter()
    process = subprocess.Popen(["wine", str(player), "--headless", "--frames", "1"], cwd=player.parent, env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, status, usage = os.wait4(process.pid, 0)
    return {"kind": kind, "seconds": round(time.perf_counter() - started, 3),
            "peak_rss_mb": round(usage.ru_maxrss / 1024, 1), "exit": os.waitstatus_to_exitcode(status)}


def replay(kind: str, player: Path, ticks: int, run: int) -> dict:
    started = time.monotonic()
    done = subprocess.run(["wine", str(player), "--headless", "--host", "--bot", "--port", "47870"],
                          env=wine_env() | net_env("nethash", ticks / 60 + 60, ticks), cwd=player.parent,
                          capture_output=True, text=True, timeout=ticks / 60 + 240)
    text = done.stdout + done.stderr
    return {"kind": kind, "run": run, "hash": hash_of(text), "seconds": round(time.monotonic() - started, 1),
            "exit": done.returncode}


def fmt(value, digits=2):
    if value is None:
        return "-"
    return f"{value:.{digits}f}" if isinstance(value, float) else str(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jit", type=Path, required=True, help="a JIT CSharpBench Windows player")
    parser.add_argument("--native", type=Path, required=True, help="a NativeAOT CSharpBench Windows player")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ticks", type=int, default=10000)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--starts", type=int, default=5)
    parser.add_argument("--modes", default="gameobject,ecs,getcomponent,physics")
    parser.add_argument("--count", type=int, default=10000)
    parser.add_argument("--mode-counts", default="",
                        help="per-mode cube counts, e.g. physics=4000 (default: --count for every mode)")
    parser.add_argument("--frames", type=int, default=600)
    args = parser.parse_args()
    mode_counts = {mode: int(count) for mode, count in
                   (part.split("=", 1) for part in args.mode_counts.split(",") if part)}
    args.output.mkdir(parents=True, exist_ok=True)
    players = {"jit": args.jit, "native": args.native}

    sizes_by_kind = {kind: sizes(kind, player) for kind, player in players.items()}
    print("B25 sizes:", json.dumps(sizes_by_kind))

    starts = []
    for kind, player in players.items():
        for index in range(args.starts):
            result = cold_start(kind, player)
            result["run"] = index
            starts.append(result)
    print("B26 cold start:", json.dumps([{k: r[k] for k in ("kind", "seconds", "peak_rss_mb")} for r in starts]))

    modes = []
    for mode in args.modes.split(","):
        count = mode_counts.get(mode, args.count)
        for kind, player in players.items():
            try:
                result = bench_mode(kind, player, MODES[mode][0], count, args.frames, 900)
            except RuntimeError as error:
                modes.append({"mode": mode, "kind": kind, "count": count, "error": str(error).splitlines()[0]})
                print(f"B26 {mode:11} {kind:6}: FAILED ({str(error).splitlines()[0]})")
                continue
            modes.append({"mode": mode, "count": count, **{field: result.get(field) for field in FIELDS},
                          "kind": kind})
            print(f"B26 {mode:11} {kind:6} ({count}): script {fmt(result.get('script_only_avg_ms'), 3)} ms, "
                  f"frame {fmt(result.get('frame_avg_ms'), 3)} ms")

    replays = []
    for kind, player in players.items():
        for run in range(args.runs):
            result = replay(kind, player, args.ticks, run)
            replays.append(result)
            print(f"B27 {kind:6} run {run}: {result['hash']} ({result['seconds']} s, exit {result['exit']})")
    hashes = {kind: {r["hash"] for r in replays if r["kind"] == kind} for kind in players}
    windows_match = all(len(h) == 1 and None not in h for h in hashes.values())
    common = set.intersection(*[h for h in hashes.values() if h]) if windows_match else set()

    lines = ["# B25/B26/B27 Windows players under Wine", "",
             "Windows x64 exports run with Wine on Linux x64: the game code and deployment are the Windows ones, the "
             "kernel is not. Times and memory include Wine and are not native-Windows figures; hashes are exact.",
             "", "## B25 sizes", "",
             "| kind | package MB | game code MB | player MB | private symbols MB | exports | symbols in package |",
             "|---|---:|---:|---:|---:|---|---|"]
    for kind, s in sizes_by_kind.items():
        lines.append(f"| {kind} | {s['package_mb']} | {s['game_code_mb']} | {s['player_mb']} | {s['private_symbols_mb']} "
                     f"| {', '.join(s['exports']) or '-'} | {', '.join(s['symbols_in_package']) or 'none'} |")
    lines += ["", "## B26 cold start (5 runs: start, one frame, exit)", "",
              "| kind | runs | median s | peak RSS MB |", "|---|---:|---:|---:|"]
    for kind in players:
        runs = [r for r in starts if r["kind"] == kind]
        lines.append(f"| {kind} | {len(runs)} | {statistics.median(r['seconds'] for r in runs):.3f} "
                     f"| {statistics.median(r['peak_rss_mb'] for r in runs):.1f} |")
    lines += ["", f"## B26 script and frame times ({args.frames} frames; mode counts as listed)", "",
              "| mode | cubes | kind | script ms | frame ms | GC bytes/frame |", "|---|---:|---|---:|---:|---:|"]
    for result in modes:
        if "error" in result:
            lines.append(f"| {result['mode']} | {result.get('count', args.count)} | {result['kind']} | "
                         f"failed: {result['error']} | | |")
            continue
        lines.append(f"| {result['mode']} | {result['count']} | {result['kind']} | "
                     f"{fmt(result.get('script_only_avg_ms'), 3)} | {fmt(result.get('frame_avg_ms'), 3)} "
                     f"| {fmt(result.get('gc_bytes_per_frame'), 0)} |")
    lines += ["", f"## B27 replay, {args.ticks} ticks, {args.runs} runs each", "",
              "| kind | run | hash | seconds |", "|---|---:|---|---:|"]
    lines += [f"| {r['kind']} | {r['run']} | `{r['hash']}` | {r['seconds']} |" for r in replays]
    lines += ["", f"Same hash within each runtime: **{'yes' if windows_match else 'NO'}**"
              + (f"; the two runtimes agree: **{'yes' if len(common) == 1 else 'NO'}** "
                 f"(`{next(iter(common)) if common else '-'}`)." if windows_match else "."),
              "Linux's hash for the same replay is recorded in docs/csharp-benchmark-plan.md (B27); a difference "
              "means the simulation is not portable and must be investigated, not assumed."]
    (args.output / "results.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (args.output / "results.json").write_text(json.dumps({"sizes": sizes_by_kind, "starts": starts, "modes": modes,
                                                          "replays": replays}, indent=1), encoding="utf-8")
    print(f"B27 within-runtime hashes match: {'yes' if windows_match else 'NO'}"
          f"; both runtimes agree: {'yes' if len(common) == 1 else 'NO'}")
    print(f"Report: {args.output / 'results.md'}")
    return 0 if windows_match else 1


if __name__ == "__main__":
    sys.exit(main())
