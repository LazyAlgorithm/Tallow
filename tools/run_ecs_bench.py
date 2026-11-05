#!/usr/bin/env python3
"""Run the ECS Phase 1 benchmark (Samples/EcsBench, docs/ecs-plan.md) and print its results table.

Build the sample first (Release is what the table in docs/ecs-plan.md uses):
    Tallow --build-project Samples/EcsBench
    BeefBuild -workspace=Samples/EcsBench -config=Release -platform=Linux64

Each run opens the game window, spawns the cubes, measures, writes one JSON line and quits.
"""
import argparse
import json
import os
from pathlib import Path
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
    parser.add_argument('--modes', nargs='+', choices=MODES, default=MODES)
    parser.add_argument('--output', type=Path, help='Keep the JSON lines here as well.')
    args = parser.parse_args()
    platform = 'Win64' if os.name == 'nt' else 'Linux64'
    exe = project / f'build/{args.config}_{platform}/EcsBench' / ('EcsBench.exe' if os.name == 'nt' else 'EcsBench')
    if not exe.is_file():
        parser.error(f'{exe} not found; build the sample first (see --help).')

    results = []
    with tempfile.TemporaryDirectory() as work:
        out = Path(work) / 'results.jsonl'
        for count in args.counts:
            for mode in args.modes:
                env = dict(os.environ, TALLOW_BENCH_MODE=mode, TALLOW_BENCH_COUNT=str(count),
                           TALLOW_BENCH_FRAMES=str(args.frames), TALLOW_BENCH_OUT=str(out))
                print(f'{mode} x {count}...', flush=True)
                run = subprocess.run([str(exe), '--project', str(project)], env=env, cwd=project, timeout=1800,
                                     capture_output=True, text=True)
                if run.returncode != 0:
                    sys.exit(f'{mode} x {count} exited {run.returncode}:\n{(run.stdout + run.stderr)[-3000:]}')
        results = [json.loads(line) for line in out.read_text().splitlines() if line.strip()]
    if args.output:
        args.output.write_text(''.join(json.dumps(r) + '\n' for r in results))

    by = {(r['mode'], r['count']): r for r in results}
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


if __name__ == '__main__':
    main()
