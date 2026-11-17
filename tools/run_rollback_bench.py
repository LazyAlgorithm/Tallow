#!/usr/bin/env python3
"""B20, prediction/rollback determinism (docs/csharp-benchmark-plan.md), with the NetSync workload of B18
(tools/run_net_bench.py; build the same two players).

1. Replay: each language's host runs alone with the deterministic bot controls (--bot) to tick --ticks (default
   10,000) and prints a hash of the player's and the 200 drones' positions to the millimetre. Three runs each: every
   run of a language must give the same hash, and Beef and C# must give the same hash.
2. Rollback: a server and one bot client under --rtt ms round trip and --loss % loss for the same number of ticks,
   three runs each language. From the client: corrections (rollbacks), ticks replayed and the time each took (the
   engine's ROLLBACK report), prediction error (own error from --netstats), the worst frame and p99 after the join
   (the catch-up cost), and the server's hash at the end. Under loss the server's hash may differ between runs (a
   control that arrives too late is dropped and the server repeats the last one), so it is reported, not required.

    python3 tools/run_rollback_bench.py --csharp OUT-CS/CSharpBench --beef OUT-BEEF/EcsBench --output DIR
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_net_bench import CLIENT_RE  # noqa: E402

ROLLBACK_RE = re.compile(r"ROLLBACK (\d+) corrections .*?, (\d+) ticks run again at ([\d.]+) microseconds each")
FRAME_RE = re.compile(r"NETFRAME worst ([\d.]+) p99 ([\d.]+) frames (\d+)")


def env(mode: str, seconds: float, ticks: int, keep: bool = False) -> dict:
    return dict(os.environ, TALLOW_BENCH_MODE=mode, TALLOW_NET_SECONDS=str(seconds), TALLOW_NET_HASH_TICK=str(ticks),
                TALLOW_NET_KEEP="1" if keep else "0")


def hash_of(text: str) -> str | None:
    line = next((l for l in text.splitlines() if l.startswith("NETHASH")), None)
    return line.split()[2] if line else None


def replay(lang: str, player: Path, ticks: int, run: int, output: Path, port: int) -> dict:
    started = time.monotonic()
    done = subprocess.run([str(player), "--headless", "--host", "--bot", "--port", str(port)],
                          env=env("nethash", ticks / 60 + 60, ticks), cwd=player.parent,
                          capture_output=True, text=True, timeout=ticks / 60 + 120)
    text = done.stdout + done.stderr
    (output / f"replay-{lang}-{run}.log").write_text(text)
    return {"lang": lang, "run": run, "hash": hash_of(text), "seconds": round(time.monotonic() - started, 1)}


def rollback(lang: str, player: Path, ticks: int, rtt: int, loss: float, run: int, output: Path, port: int) -> dict:
    seconds = ticks / 60
    common = ["--headless", "--port", str(port), "--netstats", "--lag", str(rtt // 2)]
    if loss:
        common += ["--loss", str(loss)]
    tag = f"rollback-{lang}-{run}"
    with open(output / f"{tag}-server.log", "w") as server_log, open(output / f"{tag}-client.log", "w") as client_log:
        # The server hashes at the same tick (its pilot ticks count from the client's player spawning) and keeps
        # running until the client has left, so the client's report is taken while it is still connected.
        server = subprocess.Popen([str(player), "--server", *common], env=env("nethash", seconds + 35, ticks, keep=True),
                                  cwd=player.parent, stdout=server_log, stderr=subprocess.STDOUT)
        time.sleep(2)
        client = subprocess.Popen([str(player), "--connect", "127.0.0.1", "--bot", *common],
                                  env=env("netsync", seconds + 15, ticks), cwd=player.parent,
                                  stdout=client_log, stderr=subprocess.STDOUT)
        for process in (client, server):
            try:
                process.wait(timeout=seconds + 120)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    client_text = (output / f"{tag}-client.log").read_text(errors="replace")
    server_text = (output / f"{tag}-server.log").read_text(errors="replace")
    rows = [m for m in (CLIENT_RE.search(l) for l in client_text.splitlines()) if m][5:]
    report = ROLLBACK_RE.search(client_text)
    frame = FRAME_RE.search(client_text)
    errors = sum(("[error]" in l or "Exception" in l or "FATAL" in l) for l in (client_text + server_text).splitlines())
    return {
        "lang": lang, "run": run, "rtt_ms": rtt, "loss_pct": loss,
        "server_hash": hash_of(server_text),
        "corrections": int(report.group(1)) if report else 0,
        "replayed_ticks": int(report.group(2)) if report else 0,
        "replay_us_per_tick": float(report.group(3)) if report else None,
        "own_error_median": statistics.median(float(m.group(7)) for m in rows) if rows else None,
        "own_error_worst": max((float(m.group(7)) for m in rows), default=None),
        "worst_frame_ms": float(frame.group(1)) if frame else None,
        "p99_frame_ms": float(frame.group(2)) if frame else None,
        "errors": errors,
    }


def fmt(value, digits=2):
    if value is None:
        return "-"
    return f"{value:.{digits}f}" if isinstance(value, float) else str(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csharp", type=Path, required=True)
    parser.add_argument("--beef", type=Path, required=True)
    parser.add_argument("--ticks", type=int, default=10000)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--rtt", type=int, default=100)
    parser.add_argument("--loss", type=float, default=2)
    parser.add_argument("--port", type=int, default=47830)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    players = {"beef": args.beef, "csharp": args.csharp}

    replays = []
    for lang, player in players.items():
        for run in range(args.runs):
            result = replay(lang, player, args.ticks, run, args.output, args.port)
            replays.append(result)
            print(f"replay {lang} run {run}: {result['hash']} ({result['seconds']} s)", flush=True)
    hashes = {r["hash"] for r in replays}
    replay_ok = len(hashes) == 1 and None not in hashes

    rollbacks = []
    for lang, player in players.items():
        for run in range(args.runs):
            result = rollback(lang, player, args.ticks, args.rtt, args.loss, run, args.output, args.port)
            rollbacks.append(result)
            print(f"rollback {lang} run {run}: {json.dumps(result)}", flush=True)
    (args.output / "results.json").write_text(json.dumps({"replays": replays, "rollbacks": rollbacks}, indent=1))

    lines = ["# B20 prediction/rollback determinism", "",
             f"## Replay: host alone, bot controls, hash at tick {args.ticks}, {args.runs} runs each", "",
             f"All runs of both languages give one hash: **{'yes' if replay_ok else 'NO'}**", "",
             "| lang | run | hash | seconds |", "|---|---:|---|---:|"]
    lines += [f"| {r['lang']} | {r['run']} | `{r['hash']}` | {r['seconds']} |" for r in replays]
    lines += ["", f"## Rollback: server + one bot client, {args.rtt} ms RTT, {args.loss:g}% loss, {args.ticks} ticks", "",
              "| lang | run | corrections | ticks replayed | µs per replayed tick | own error median / worst (m) | worst frame ms | p99 frame ms | server hash | errors |",
              "|---|---:|---:|---:|---:|---:|---:|---:|---|---:|"]
    for r in rollbacks:
        lines.append(f"| {r['lang']} | {r['run']} | {r['corrections']} | {r['replayed_ticks']} | {fmt(r['replay_us_per_tick'], 1)} | "
                     f"{fmt(r['own_error_median'], 3)} / {fmt(r['own_error_worst'], 3)} | {fmt(r['worst_frame_ms'])} | "
                     f"{fmt(r['p99_frame_ms'])} | `{r['server_hash']}` | {r['errors']} |")
    (args.output / "summary.md").write_text("\n".join(lines) + "\n")
    print((args.output / "summary.md").read_text())
    return 0 if replay_ok and not any(r["errors"] for r in rollbacks) else 1


if __name__ == "__main__":
    sys.exit(main())
