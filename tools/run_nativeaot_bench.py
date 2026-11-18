#!/usr/bin/env python3
"""JIT versus NativeAOT exports of the same C# game (docs/csharp-benchmark-plan.md B25, B26, B27, B28).

Builds Samples/CSharpBench twice from this engine and commit, as a JIT export (assemblies + bundled .NET) and as a
NativeAOT export (tools/csharp_native.py), unless --jit/--native name players built already, then measures:

  B25 sizes: package, game code (native library vs. Managed/ + dotnet/), private symbols, the library's exports.
  B26 cold start and memory: --starts runs each of start-to-exit with one frame (process start to first tick and
      shutdown) and its peak RSS; then the bench modes (run_csharp_bench.run) for frame times and managed allocation.
  B27 replay: the deterministic NetSync bot replay (run_rollback_bench.replay) --runs times each; every hash must
      match within and across runtimes.
  B28 cross-play: a JIT server with a NativeAOT bot client and the reverse, with no loss: the server's end hash must
      equal the replay hash, and neither side may log an error or a code-ID warning.

    python3 tools/run_nativeaot_bench.py --output DIR [--jit OUT/CSharpBench --native OUT/CSharpBench]

Linux only (the players run here); a Windows pair can be measured the same way on Windows.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import resource
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from run_csharp_bench import run as bench_run  # noqa: E402
from run_rollback_bench import env as net_env, hash_of, replay  # noqa: E402


def build(kind: str, work: Path) -> Path:
    project = work / f"Bench-{kind}"
    if not project.exists():
        shutil.copytree(ROOT / "Samples/CSharpBench", project, ignore=shutil.ignore_patterns(".tallow-*", "build", "Builds"))
        text = (project / "project.tallow").read_text().replace("engine = ../..", f"engine = {ROOT.as_posix()}")
        (project / "project.tallow").write_text(text)
    output = work / f"out-{kind}"
    done = subprocess.run([sys.executable, str(ROOT / "tools/build_player.py"), str(project), "--output", str(output),
                           "--config", "Release", "--replace", "--csharp-runtime", kind], capture_output=True, text=True)
    if done.returncode != 0:
        raise SystemExit(f"The {kind} export failed:\n{(done.stdout + done.stderr)[-4000:]}")
    return output / "CSharpBench"


def size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if path.exists() else 0


def sizes(kind: str, player: Path) -> dict:
    folder = player.parent
    code = size(folder / "Managed") + size(folder / "dotnet")
    symbols = folder.parent / (folder.name + "-symbols")
    exports: list[str] = []
    library = folder / "Managed/Native/libTallowGame.so"
    if library.is_file():
        listing = subprocess.run(["nm", "-D", "--defined-only", str(library)], capture_output=True, text=True).stdout
        exports = sorted({line.split()[-1].split("@")[0] for line in listing.splitlines() if " T " in line})
    shipped_symbols = [str(p.relative_to(folder)) for p in folder.rglob("*") if p.suffix in (".pdb", ".dbg")]
    return {"kind": kind, "package_mb": round(size(folder) / 2**20, 1), "game_code_mb": round(code / 2**20, 1),
            "player_mb": round(size(player) / 2**20, 1), "private_symbols_mb": round(size(symbols) / 2**20, 1),
            "exports": exports, "symbols_in_package": shipped_symbols}


def cold_start(kind: str, player: Path) -> dict:
    """Process start to exit with one frame (start-up, first tick, shut-down) and the peak RSS of that run."""
    env = dict(os.environ, TALLOW_BENCH_MODE="gameobject", TALLOW_BENCH_COUNT="1000", TALLOW_BENCH_FRAMES="1")
    env = {k: v for k, v in env.items() if not k.startswith("DOTNET")} | {"TALLOW_BENCH_MODE": "gameobject"}
    started = time.perf_counter()
    process = subprocess.Popen([str(player), "--headless", "--frames", "1"], cwd=player.parent, env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    _, status, usage = os.wait4(process.pid, 0)
    seconds = time.perf_counter() - started
    return {"kind": kind, "seconds": round(seconds, 3), "peak_rss_mb": round(usage.ru_maxrss / 1024, 1),
            "exit": os.waitstatus_to_exitcode(status)}


def crossplay(server_kind: str, server: Path, client_kind: str, client: Path, ticks: int, output: Path, port: int) -> dict:
    seconds = ticks / 60
    common = ["--headless", "--port", str(port)]
    tag = f"cross-{server_kind}-server-{client_kind}-client"
    with open(output / f"{tag}-server.log", "w") as server_log, open(output / f"{tag}-client.log", "w") as client_log:
        host = subprocess.Popen([str(server), "--server", *common], env=net_env("nethash", seconds + 35, ticks, keep=True),
                                cwd=server.parent, stdout=server_log, stderr=subprocess.STDOUT)
        time.sleep(2)
        bot = subprocess.Popen([str(client), "--connect", "127.0.0.1", "--bot", *common],
                               env=net_env("netsync", seconds + 15, ticks), cwd=client.parent,
                               stdout=client_log, stderr=subprocess.STDOUT)
        for process in (bot, host):
            try:
                process.wait(timeout=seconds + 120)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    server_text = (output / f"{tag}-server.log").read_text(errors="replace")
    client_text = (output / f"{tag}-client.log").read_text(errors="replace")
    errors = [l for l in (server_text + client_text).splitlines()
              if "[error]" in l or "Exception" in l or "FATAL" in l or "other C# code" in l]
    return {"server": server_kind, "client": client_kind, "server_hash": hash_of(server_text),
            "errors": len(errors), "first_error": errors[0] if errors else ""}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jit", type=Path, help="a JIT CSharpBench player built already")
    parser.add_argument("--native", type=Path, help="a NativeAOT CSharpBench player built already")
    parser.add_argument("--starts", type=int, default=5)
    parser.add_argument("--modes", default="gameobject,ecs,getcomponent,physics,alloc")
    parser.add_argument("--count", type=int, default=10000)
    parser.add_argument("--frames", type=int, default=600)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--ticks", type=int, default=10000)
    parser.add_argument("--port", type=int, default=47860)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = out / "build"
    players = {"jit": args.jit or build("jit", work), "native": args.native or build("native", work)}
    results: dict = {"commit": subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True,
                                              text=True).stdout.strip()}

    results["sizes"] = [sizes(kind, player) for kind, player in players.items()]
    for row in results["sizes"]:
        print(f"B25 {row['kind']:6} package {row['package_mb']} MB, game code {row['game_code_mb']} MB, player "
              f"{row['player_mb']} MB, private symbols {row['private_symbols_mb']} MB, exports {row['exports'] or '-'}, "
              f"symbols shipped {row['symbols_in_package'] or 'none'}")

    starts = {kind: [] for kind in players}
    for _ in range(args.starts):
        for kind, player in players.items():
            starts[kind].append(cold_start(kind, player))
    results["cold_start"] = starts
    for kind, rows in starts.items():
        print(f"B26 {kind:6} start-to-exit median {statistics.median(r['seconds'] for r in rows):.3f} s "
              f"(min {min(r['seconds'] for r in rows):.3f}), peak RSS median "
              f"{statistics.median(r['peak_rss_mb'] for r in rows):.0f} MB, exits {sorted({r['exit'] for r in rows})}")

    modes = [m for m in args.modes.split(",") if m]
    bench: dict = {}
    for mode in modes:
        for kind, player in players.items():
            rows = [bench_run(player, mode, args.count, args.frames, 600) for _ in range(args.runs)]
            bench[f"{mode}-{kind}"] = rows
            median = lambda key: statistics.median(r.get(key, 0) or 0 for r in rows)
            print(f"B26 {mode:12} {kind:6} script {median('script_only_avg_ms'):.3f} ms, frame {median('frame_avg_ms'):.3f} "
                  f"ms (p99 {median('frame_p99_ms'):.3f}), spawn {median('spawn_ms'):.1f} ms, GC "
                  f"{median('gc_bytes_per_frame'):.0f} B/frame")
    results["bench"] = bench

    replays = []
    for run in range(args.runs):
        for kind, player in players.items():
            replays.append(replay(kind, player, args.ticks, run, out, args.port))
    results["replay"] = replays
    hashes = {r["hash"] for r in replays}
    print(f"B27 replay {args.ticks} ticks x{args.runs}: " + ", ".join(f"{r['lang']}={r['hash']}" for r in replays)
          + ("  SAME" if len(hashes) == 1 and None not in hashes else "  DIFFER"))

    cross = [crossplay("jit", players["jit"], "native", players["native"], args.ticks, out, args.port + 1),
             crossplay("native", players["native"], "jit", players["jit"], args.ticks, out, args.port + 2)]
    results["crossplay"] = cross
    for row in cross:
        print(f"B28 {row['server']} server + {row['client']} client: server hash {row['server_hash']}, "
              f"errors {row['errors']}{' (' + row['first_error'] + ')' if row['errors'] else ''}")
    (out / "results.json").write_text(json.dumps(results, indent=1))
    ok = (len(hashes) == 1 and None not in hashes and all(r["errors"] == 0 for r in cross)
          and all(not row["symbols_in_package"] for row in results["sizes"]))
    print(f"Results in {out / 'results.json'}: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
