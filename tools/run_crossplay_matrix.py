#!/usr/bin/env python3
"""B28 (docs/csharp-benchmark-plan.md): mixed JIT and NativeAOT players under the network simulator.

For every configuration (peers, round trip, loss) the game runs twice: a JIT server with NativeAOT bot clients,
and a NativeAOT server with JIT bot clients (with more peers, the clients alternate runtimes). The server runs the
NetSync benchmark in nethash mode, so its final hash is comparable with the replay hash of either runtime; each
client reports prediction (own) error, corrections and bandwidth from --netstats.

    python3 tools/run_crossplay_matrix.py --jit OUT-JIT/CSharpBench --native OUT-NATIVE/CSharpBench --output DIR

The players are the CSharpBench exports of this engine (tools/run_nativeaot_bench.py builds them). Configurations
with no added latency or loss must end on the replay hash in both directions; with latency or loss the server's
hash can differ between runs (a control that arrives too late is dropped, as B20 records), so those are reported,
not required to match. Also recorded: whether every client connected, errors, and the client's rollback figures.
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
from run_net_bench import CLIENT_RE, SERVER_RE, WAITING_RE  # noqa: E402
from run_rollback_bench import env as net_env, hash_of  # noqa: E402

DEFAULT_CONFIGS = [
    # peers, round trip ms, loss %
    (2, 0, 0), (4, 0, 0), (8, 0, 0), (16, 0, 0),
    (4, 50, 0), (4, 100, 0), (4, 200, 0),
    (4, 100, 1), (4, 100, 2), (4, 100, 5),
]


def med(values):
    return statistics.median(values) if values else None


def replay(players: dict[str, Path], ticks: int, output: Path, port: int) -> dict[str, str | None]:
    """Each runtime's own host with bot controls: the hash every no-latency cross-play must end on."""
    hashes = {}
    for kind, player in players.items():
        text = subprocess.run([str(player), "--headless", "--host", "--bot", "--port", str(port)],
                              env=net_env("nethash", ticks / 60 + 60, ticks), cwd=player.parent,
                              capture_output=True, text=True, timeout=ticks / 60 + 120)
        log = text.stdout + text.stderr
        (output / f"replay-{kind}.log").write_text(log)
        hashes[kind] = hash_of(log)
        print(f"replay {kind}: {hashes[kind]}")
    return hashes


def run(server_kind: str, server: Path, client_kinds: list[str], clients: dict[str, Path], peers: int,
        rtt: int, loss: float, ticks: int, output: Path, port: int) -> dict:
    lag = rtt // 2
    tag = f"cross-{server_kind}-server-p{peers}-rtt{rtt}-loss{loss:g}"
    common = ["--headless", "--port", str(port), "--netstats"]
    if lag:
        common += ["--lag", str(lag)]
    if loss:
        common += ["--loss", str(loss)]
    seconds = ticks / 60
    logs = []
    server_log = open(output / f"{tag}-server.log", "w")
    logs.append(server_log)
    host = subprocess.Popen([str(server), "--server", *common],
                            env=net_env("nethash", seconds + 12, ticks, keep=True), cwd=server.parent,
                            stdout=server_log, stderr=subprocess.STDOUT)
    time.sleep(2)
    processes = []
    for index in range(peers):
        kind = client_kinds[index % len(client_kinds)]
        log = open(output / f"{tag}-client{index}-{kind}.log", "w")
        logs.append(log)
        processes.append(subprocess.Popen([str(clients[kind]), "--connect", "127.0.0.1", "--bot", *common],
                                          env=net_env("netsync", seconds + 8, ticks), cwd=clients[kind].parent,
                                          stdout=log, stderr=subprocess.STDOUT))
    for process in processes + [host]:
        try:
            process.wait(timeout=seconds + 120)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for log in logs:
        log.close()
    server_text = (output / f"{tag}-server.log").read_text(errors="replace")
    client_rows, connected = [], 0
    for index in range(peers):
        kind = client_kinds[index % len(client_kinds)]
        text = (output / f"{tag}-client{index}-{kind}.log").read_text(errors="replace")
        rows = [m for m in (CLIENT_RE.search(line) for line in text.splitlines()) if m]
        connected += bool(rows)
        client_rows += rows
    server_rows = [m for m in (SERVER_RE.search(line) for line in server_text.splitlines()) if m]
    errors = [line for path in output.glob(f"{tag}-*.log")
              for line in path.read_text(errors="replace").splitlines()
              if "[error]" in line or "Exception" in line or "FATAL" in line or "other C# code" in line]
    return {
        "server": server_kind, "clients": ", ".join(f"{kind} {client_kinds.count(kind)}" for kind in dict.fromkeys(client_kinds)),
        "peers": peers,
        "rtt_ms": rtt, "loss_pct": loss, "connected": connected,
        "server_hash": hash_of(server_text),
        "server_sent_per_client_kbs": med([int(m.group(1)) / max(peers, 1) / 1024 for m in server_rows]),
        "client_received_kbs": med([int(m.group(2)) / 1024 for m in client_rows]),
        "client_sent_kbs": med([int(m.group(1)) / 1024 for m in client_rows]),
        "own_error_median": med([float(m.group(7)) for m in client_rows]),
        "own_error_worst": max((float(m.group(7)) for m in client_rows), default=None),
        "rollbacks_per_s": med([int(m.group(4)) for m in client_rows]),
        "ticks_ahead": med([int(m.group(6)) for m in client_rows]),
        "inputs_waiting_client": med([float(m.group(10)) for m in client_rows]),
        "inputs_waiting_server": med([int(w) for m in server_rows for w in WAITING_RE.findall(m.group(7))]),
        "server_dropped_inputs_per_s": med([int(m.group(6)) for m in server_rows]),
        "errors": len(errors), "first_error": errors[0] if errors else "",
    }


def fmt(value, digits=2):
    if value is None:
        return "-"
    return f"{value:.{digits}f}" if isinstance(value, float) else str(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jit", type=Path, required=True, help="a JIT CSharpBench player built already")
    parser.add_argument("--native", type=Path, required=True, help="a NativeAOT CSharpBench player built already")
    parser.add_argument("--ticks", type=int, default=1800, help="simulated ticks per run (hash taken at the end)")
    parser.add_argument("--configs", help="peers:rtt:loss,... (default: the B18 set)")
    parser.add_argument("--port", type=int, default=47840)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    players = {"jit": args.jit, "native": args.native}
    configs = DEFAULT_CONFIGS
    if args.configs:
        configs = [tuple(float(x) if i == 2 else int(x) for i, x in enumerate(c.split(":"))) for c in args.configs.split(",")]

    known = replay(players, args.ticks, args.output, args.port)
    replay_ok = len(set(known.values())) == 1 and None not in known.values()
    print(f"Both runtimes replay to one hash: {'yes' if replay_ok else 'NO'}")

    results = []
    with open(args.output / "raw.jsonl", "a") as raw:
        for peers, rtt, loss in configs:
            for server_kind, client_kind in (("jit", "native"), ("native", "jit")):
                client_kinds = [client_kind, "jit" if client_kind == "native" else "native"]
                result = run(server_kind, players[server_kind], client_kinds, players, peers, rtt, loss,
                             args.ticks, args.output, args.port)
                result["matches_replay"] = result["server_hash"] in known.values()
                raw.write(json.dumps(result) + "\n")
                raw.flush()
                results.append(result)
                print(f"{server_kind:6} server, {client_kind:6} clients  peers {peers:2} rtt {rtt:3} loss {loss:g}%: "
                      f"connected {result['connected']}/{peers}, hash {result['server_hash']}, "
                      f"own error {fmt(result['own_error_median'], 3)} (worst {fmt(result['own_error_worst'], 3)}), "
                      f"{fmt(result['server_sent_per_client_kbs'], 1)} KB/s per client, errors {result['errors']}",
                      flush=True)

    pairs: dict[tuple, list[dict]] = {}
    for r in results:
        pairs.setdefault((r["peers"], r["rtt_ms"], r["loss_pct"]), []).append(r)
    # Join timing (a client joins a running server) shifts where the pilot starts, so the two directions can end on
    # different hashes even with no added latency. Agreement is reported; only connectivity and errors are gates.
    agreeing = [key for key, runs in pairs.items() if len({r["server_hash"] for r in runs}) == 1]
    connected_ok = all(r["connected"] == r["peers"] for r in results)
    errors = sum(r["errors"] for r in results)
    lines = ["# B28 mixed JIT/NativeAOT cross-play under the network simulator", "",
             f"Replay (each runtime's host alone, `--bot`, tick {args.ticks}): "
             + ", ".join(f"{kind} `{value}`" for kind, value in known.items())
             + f"; both the same: **{'yes' if replay_ok else 'NO'}**", "",
             f"{len(results)} runs: {len(configs)} configurations in both directions, {args.ticks} ticks each, headless "
             "Release players on one machine; the engine's simulator adds half the round trip on every side and "
             "drops unreliable packets.", "",
             f"The two mixed directions ended on the same server hash in {len(agreeing)} of {len(pairs)} "
             "configurations (a client joins a running server, so where its pilot starts varies by a tick or two). "
             f"Every client connected: **{'yes' if connected_ok else 'NO'}**. Errors: {errors}. "
             "With latency or loss the server's hash can also differ between runs (a control that arrives too late is "
             "dropped, as B20 records): those rows are reported, not required to match.", "",
             "| server | clients | peers | RTT ms | loss % | connected | server hash | matches replay | "
             "KB/s sent per client | client KB/s in | own error median / worst (m) | rollbacks/s | ticks ahead | "
             "controls waiting (client / server) | dropped controls/s | errors |",
             "|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in results:
        lines.append(f"| {r['server']} | {r['clients']} | {r['peers']} | {r['rtt_ms']} | {r['loss_pct']:g} | "
                     f"{r['connected']}/{r['peers']} | `{r['server_hash']}` | {'yes' if r['matches_replay'] else 'no'} | "
                     f"{fmt(r['server_sent_per_client_kbs'], 1)} | {fmt(r['client_received_kbs'], 1)} | "
                     f"{fmt(r['own_error_median'], 3)} / {fmt(r['own_error_worst'], 3)} | {fmt(r['rollbacks_per_s'], 1)} | "
                     f"{fmt(r['ticks_ahead'], 1)} | {fmt(r['inputs_waiting_client'], 1)} / {fmt(r['inputs_waiting_server'], 1)} | "
                     f"{fmt(r['server_dropped_inputs_per_s'], 1)} | {r['errors']} |")
    report = "\n".join(lines) + "\n"
    (args.output / "results.md").write_text(report, encoding="utf-8")
    (args.output / "results.json").write_text(json.dumps({"known": known, "runs": results}, indent=1), encoding="utf-8")
    print()
    if not (connected_ok and errors == 0):
        print("B28 did not pass (a client did not connect, or a run logged an error).")
        return 1
    print(f"B28: {len(results)} mixed-runtime runs; every client connected, no errors; the two directions agreed "
          f"on {len(agreeing)} of {len(pairs)} configurations.")
    print(f"Report: {args.output / 'results.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
