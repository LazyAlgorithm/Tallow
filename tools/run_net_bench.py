#!/usr/bin/env python3
"""B18, multiplayer sync (docs/csharp-benchmark-plan.md): the same networked workload in Beef (Samples/EcsBench,
NetSync.bf) and C# (Samples/CSharpBench, NetSync.cs), in exported Release players on this machine. A headless server
and N headless bot clients (--bot: deterministic controls) run for a while under the engine's own network condition
simulator (--lag on every side, so the round trip is twice it; --loss drops unreliable packets) with --netstats,
whose once-a-second lines are the measurements.

Build both players first (copies whose project.tallow points at this engine; the Beef copy needs
`TallowLauncher --build-native-project COPY` first), then:
    python3 tools/run_net_bench.py --csharp OUT-CS/CSharpBench --beef OUT-BEEF/EcsBench --output DIR

First a parity check: each language's host runs alone with --bot to tick 600 and prints a hash of where the
player and the 200 drones are, to the millimetre; the two must match (the same controls give the same authoritative
result). Then every configuration (peers, round trip, loss) for both languages. Reported per configuration and
language (after a warm-up): server bytes sent per client per second, client bytes received per second, the
client's prediction error (own error, the worst each second: median and worst), rollbacks per second, controls
waiting on the server and ticks the client runs ahead (input latency), ticks the server ran without a client's
controls and controls it dropped, server CPU time per tick (from /proc), and whether every client connected.
The tick rate is fixed at 60 Hz in the engine (Time.TickRate), so 30 and 120 Hz are reported as unsupported.
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

DEFAULT_CONFIGS = [
    # peers, round trip ms, loss %
    (2, 0, 0), (4, 0, 0), (8, 0, 0), (16, 0, 0),
    (4, 50, 0), (4, 100, 0), (4, 200, 0),
    (4, 100, 1), (4, 100, 2), (4, 100, 5),
]

SERVER_RE = re.compile(r"netstats server: sent (\d+) bytes in (\d+) packets, received (\d+), (\d+) objects, (\d+) ticks without input, (\d+) inputs dropped(.*)")
WAITING_RE = re.compile(r"\[client \d+: (\d+) inputs waiting\]")
CLIENT_RE = re.compile(r"netstats client: sent (\d+) bytes, received (\d+), (\d+) snapshots, (\d+) rollbacks replaying (\d+) ticks, (-?\d+) ticks ahead, own error ([\d.]+), (\d+) bodies predicted \(error ([\d.]+)\), ([\d.]+) of ([\d.]+) inputs waiting")


def cpu_seconds(pid: int) -> float | None:
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, IndexError, ValueError):
        return None


def player_env(mode: str, seconds: float) -> dict:
    return dict(os.environ, TALLOW_BENCH_MODE=mode, TALLOW_NET_SECONDS=str(seconds))


def parity(players: dict, output: Path, port: int) -> dict:
    hashes = {}
    for lang, player in players.items():
        done = subprocess.run([str(player), "--headless", "--host", "--bot", "--port", str(port)], env=player_env("nethash", 60),
                              cwd=player.parent, capture_output=True, text=True, timeout=120)
        text = done.stdout + done.stderr
        (output / f"nethash-{lang}.log").write_text(text)
        line = next((l for l in text.splitlines() if l.startswith("NETHASH")), None)
        hashes[lang] = line
    parts = {lang: (line.split()[2] if line else None) for lang, line in hashes.items()}
    return {"lines": hashes, "match": len(set(parts.values())) == 1 and None not in parts.values()}


def run_config(lang: str, player: Path, peers: int, rtt: int, loss: float, seconds: float, warmup: float,
               output: Path, port: int) -> dict:
    lag = rtt // 2
    tag = f"{lang}-p{peers}-rtt{rtt}-loss{loss:g}"
    common = ["--headless", "--port", str(port), "--netstats"]
    if lag:
        common += ["--lag", str(lag)]
    if loss:
        common += ["--loss", str(loss)]
    logs = []
    server_log = open(output / f"{tag}-server.log", "w")
    logs.append(server_log)
    server = subprocess.Popen([str(player), "--server", *common], env=player_env("netsync", seconds + 8),
                              cwd=player.parent, stdout=server_log, stderr=subprocess.STDOUT)
    time.sleep(2)
    clients = []
    for index in range(peers):
        log = open(output / f"{tag}-client{index}.log", "w")
        logs.append(log)
        clients.append(subprocess.Popen([str(player), "--connect", "127.0.0.1", "--bot", *common],
                                        env=player_env("netsync", seconds), cwd=player.parent,
                                        stdout=log, stderr=subprocess.STDOUT))
    time.sleep(warmup)
    cpu_start, wall_start = cpu_seconds(server.pid), time.monotonic()
    time.sleep(max(seconds - warmup - 2, 1))
    cpu_end, wall_end = cpu_seconds(server.pid), time.monotonic()
    for process in clients + [server]:
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for log in logs:
        log.close()

    skip = int(warmup)
    server_text = (output / f"{tag}-server.log").read_text(errors="replace")
    server_rows = [m for m in (SERVER_RE.search(l) for l in server_text.splitlines()) if m][skip:]
    client_rows, connected = [], 0
    for index in range(peers):
        text = (output / f"{tag}-client{index}.log").read_text(errors="replace")
        rows = [m for m in (CLIENT_RE.search(l) for l in text.splitlines()) if m]
        if rows:
            connected += 1
        client_rows += rows[skip:]
    errors = sum(("[error]" in l or "Exception" in l or "FATAL" in l)
                 for p in output.glob(f"{tag}-*.log") for l in p.read_text(errors="replace").splitlines())

    def med(values):
        return statistics.median(values) if values else None

    waiting = [int(w) for m in server_rows for w in WAITING_RE.findall(m.group(7))]
    ticks = (wall_end - wall_start) * 60
    return {
        "lang": lang, "peers": peers, "rtt_ms": rtt, "loss_pct": loss, "connected": connected,
        "server_sent_per_client_kbs": med([int(m.group(1)) / max(peers, 1) / 1024 for m in server_rows]),
        "client_received_kbs": med([int(m.group(2)) / 1024 for m in client_rows]),
        "client_sent_kbs": med([int(m.group(1)) / 1024 for m in client_rows]),
        "own_error_median": med([float(m.group(7)) for m in client_rows]),
        "own_error_worst": max((float(m.group(7)) for m in client_rows), default=None),
        "rollbacks_per_s": med([int(m.group(4)) for m in client_rows]),
        "replayed_ticks_per_s": med([int(m.group(5)) for m in client_rows]),
        "ticks_ahead": med([int(m.group(6)) for m in client_rows]),
        "inputs_waiting_client": med([float(m.group(10)) for m in client_rows]),
        "inputs_waiting_server": med(waiting),
        "server_starved_ticks_per_s": med([int(m.group(5)) for m in server_rows]),
        "server_dropped_inputs_per_s": med([int(m.group(6)) for m in server_rows]),
        "server_cpu_ms_per_tick": ((cpu_end - cpu_start) * 1000 / ticks) if cpu_start is not None and cpu_end is not None and ticks > 0 else None,
        "server_samples": len(server_rows), "client_samples": len(client_rows), "errors": errors,
    }


def fmt(value, digits=2):
    if value is None:
        return "-"
    return f"{value:.{digits}f}" if isinstance(value, float) else str(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csharp", type=Path, required=True)
    parser.add_argument("--beef", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=40)
    parser.add_argument("--warmup", type=float, default=10)
    parser.add_argument("--port", type=int, default=47820)
    parser.add_argument("--configs", help="peers:rtt:loss,... (default: the B18 set)")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    configs = DEFAULT_CONFIGS
    if args.configs:
        configs = [tuple(float(x) if i == 2 else int(x) for i, x in enumerate(c.split(":"))) for c in args.configs.split(",")]
    players = {"beef": args.beef, "csharp": args.csharp}

    check = parity(players, args.output, args.port)
    print(f"Parity (host alone, bot controls, tick 600): {'MATCH' if check['match'] else 'DIFFER'}")
    for lang, line in check["lines"].items():
        print(f"  {lang}: {line}")

    results = []
    with open(args.output / "raw.jsonl", "a") as raw:
        for peers, rtt, loss in configs:
            for lang in ("beef", "csharp"):
                result = run_config(lang, players[lang], peers, rtt, loss, args.seconds, args.warmup, args.output, args.port)
                raw.write(json.dumps(result) + "\n")
                raw.flush()
                results.append(result)
                print(f"{lang:6} peers {peers:2} rtt {rtt:3} loss {loss:g}%: connected {result['connected']}/{peers}, "
                      f"own error {fmt(result['own_error_median'], 3)} (worst {fmt(result['own_error_worst'], 3)}), "
                      f"{fmt(result['server_sent_per_client_kbs'], 1)} KB/s per client, server {fmt(result['server_cpu_ms_per_tick'], 3)} ms/tick", flush=True)

    lines = ["# B18 multiplayer sync", "",
             f"Parity (host alone, --bot, tick 600): **{'match' if check['match'] else 'DIFFER'}**", ""]
    lines += [f"- {lang}: `{line}`" for lang, line in check["lines"].items()]
    lines += ["", f"{args.seconds:g} s per run, first {args.warmup:g} s left out; headless Release players on one machine; "
              "the engine's simulator adds the latency (half the round trip on every side) and loss. 30 and 120 Hz: "
              "unsupported (the tick rate is fixed at 60 Hz).", "",
              "| peers | RTT ms | loss % | lang | connected | KB/s sent per client | client KB/s in | own error median / worst (m) | rollbacks/s | ticks ahead | controls waiting (server) | starved ticks/s | dropped controls/s | server ms/tick | errors |",
              "|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in results:
        lines.append(f"| {r['peers']} | {r['rtt_ms']} | {r['loss_pct']:g} | {r['lang']} | {r['connected']}/{r['peers']} | "
                     f"{fmt(r['server_sent_per_client_kbs'], 1)} | {fmt(r['client_received_kbs'], 1)} | "
                     f"{fmt(r['own_error_median'], 3)} / {fmt(r['own_error_worst'], 3)} | {fmt(r['rollbacks_per_s'], 1)} | "
                     f"{fmt(r['ticks_ahead'], 1)} | {fmt(r['inputs_waiting_server'], 1)} | {fmt(r['server_starved_ticks_per_s'], 1)} | "
                     f"{fmt(r['server_dropped_inputs_per_s'], 1)} | {fmt(r['server_cpu_ms_per_tick'], 3)} | {r['errors']} |")
    (args.output / "summary.md").write_text("\n".join(lines) + "\n")
    print((args.output / "summary.md").read_text())
    failed = not check["match"] or any(r["connected"] < r["peers"] or r["errors"] for r in results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
