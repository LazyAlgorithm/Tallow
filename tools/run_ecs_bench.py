#!/usr/bin/env python3
"""Run the ECS Phase 1 benchmark (Samples/EcsBench, docs/ecs-plan.md) and print its results table.

Build the sample first (Release is what the table in docs/ecs-plan.md uses):
    Tallow --build-project Samples/EcsBench
    BeefBuild -workspace=Samples/EcsBench -config=Release -platform=Linux64

Each run opens the game window, spawns the cubes, measures, writes one JSON line and quits.
For a comparison, save the baseline player before rebuilding, then pass --baseline-executable PATH --runs 3.
The runner alternates baseline/current order and reports medians; --output retains every labelled raw run.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile

MODES = ['gameobject', 'ecs', 'ecs-mt']
COUNTS = [1000, 10000, 50000, 100000]


def main():
    root = Path(__file__).resolve().parent.parent
    project = root / 'Samples/EcsBench'
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--config', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--frames', type=int, default=600)
    parser.add_argument('--counts', type=int, nargs='+', default=COUNTS)
    parser.add_argument('--modes', nargs='+', choices=[*MODES, 'mixed', 'ai'], default=MODES)
    parser.add_argument('--output', type=Path, help='Keep the JSON lines here as well.')
    parser.add_argument('--runs', type=int, default=1, help='Repeat each case; tables show medians of the runs.')
    parser.add_argument('--executable', type=Path, help='Use this player instead of the sample build.')
    parser.add_argument('--baseline-executable', type=Path, help='Interleave runs with this saved baseline player.')
    args = parser.parse_args()
    if args.runs < 1 or args.frames < 1 or any(count < 1 for count in args.counts):
        parser.error('--runs, --frames and --counts must be positive.')
    platform = 'Win64' if os.name == 'nt' else 'Linux64'
    exe = args.executable or project / f'build/{args.config}_{platform}/EcsBench' / ('EcsBench.exe' if os.name == 'nt' else 'EcsBench')
    if not exe.is_file():
        parser.error(f'{exe} not found; build the sample first (see --help).')
    players = [('current', exe.resolve())]
    if args.baseline_executable:
        if not args.baseline_executable.is_file():
            parser.error(f'{args.baseline_executable} not found.')
        players.insert(0, ('baseline', args.baseline_executable.resolve()))

    results = []
    with tempfile.TemporaryDirectory() as work:
        out = Path(work) / 'results.jsonl'
        for count in args.counts:
            for mode in args.modes:
                for repeat in range(args.runs):
                    # Reverse each pair on alternate runs to balance warm-up and machine drift.
                    for variant, player in players if repeat % 2 == 0 else players[::-1]:
                        out.unlink(missing_ok=True)
                        env = dict(os.environ, TALLOW_BENCH_MODE=mode, TALLOW_BENCH_COUNT=str(count),
                                   TALLOW_BENCH_FRAMES=str(args.frames), TALLOW_BENCH_OUT=str(out))
                        print(f'{variant}: {mode} x {count}, run {repeat + 1}/{args.runs}...', flush=True)
                        run = subprocess.run([str(player), '--project', str(project)], env=env, cwd=project, timeout=1800,
                                             capture_output=True, text=True)
                        if run.returncode != 0:
                            sys.exit(f'{variant}: {mode} x {count} exited {run.returncode}:\n{(run.stdout + run.stderr)[-3000:]}')
                        if not out.is_file():
                            sys.exit(f'{variant}: {mode} x {count} produced no benchmark result:\n'
                                     f'{(run.stdout + run.stderr)[-3000:]}')
                        rows = [json.loads(line) for line in out.read_text().splitlines() if line.strip()]
                        if len(rows) != 1 or rows[0]['mode'] != mode or rows[0]['count'] != count:
                            sys.exit(f'{variant}: expected one result for {mode} x {count}, got {rows!r}')
                        result = rows[0]
                        result['variant'] = variant
                        result['run'] = repeat + 1
                        results.append(result)
    if args.output:
        args.output.write_text(''.join(json.dumps(r) + '\n' for r in results))

    def median_row(variant, mode, count):
        rows = [r for r in results if (r['variant'], r['mode'], r['count']) == (variant, mode, count)]
        return {key: statistics.median(r[key] for r in rows) if isinstance(value, (int, float)) else value
                for key, value in rows[0].items()}

    by = {(mode, count): median_row('current', mode, count) for mode in args.modes for count in args.counts}
    threads = next((r['threads'] for r in results if r['mode'] == 'ecs-mt'), 'N')

    def cell(mode, count, key):
        r = by.get((mode, count))
        return f"{r[key + '_avg_ms']:.2f} / {r[key + '_p99_ms']:.2f}" if r else ''

    def memory(count):
        def grown(mode):
            r = by.get((mode, count))
            return f"{(r['memory_after'] - r['memory_before']) / 2**20:.0f} MB" if r else '?'
        return f"{grown('gameobject')} / {grown('ecs')}"

    for key, title in (('frame', 'Frame time'), ('update', 'Update time (scripts or system)')):
        print(f'\n{title}, avg / p99 (ms):\n')
        print(f'| Objects | GameObject | ECS 1 thread | ECS {threads} threads | Memory growth GameObject / ECS |')
        print('| --- | --- | --- | --- | --- |')
        for count in args.counts:
            print(f'| {count:,} | {cell("gameobject", count, key)} | {cell("ecs", count, key)} | '
                  f'{cell("ecs-mt", count, key)} | {memory(count)} |')

    if args.baseline_executable:
        print('\nInterleaved comparison, median of runs (p99 is the median per-run p99):\n')
        print('| Mode | Objects | Measure | Baseline avg / p99 (ms) | Current avg / p99 (ms) | Avg change |')
        print('| --- | --- | --- | --- | --- | --- |')
        for count in args.counts:
            for mode in args.modes:
                baseline = median_row('baseline', mode, count)
                current = by[mode, count]
                for key in ('frame', 'update'):
                    avg, p99 = key + '_avg_ms', key + '_p99_ms'
                    change = f"{(current[avg] / baseline[avg] - 1) * 100:+.1f}%" if baseline[avg] else 'n/a'
                    print(f'| {mode} | {count:,} | {key} | {baseline[avg]:.3f} / {baseline[p99]:.3f} | '
                          f'{current[avg]:.3f} / {current[p99]:.3f} | {change} |')


if __name__ == '__main__':
    main()
