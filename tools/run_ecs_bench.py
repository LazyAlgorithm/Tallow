#!/usr/bin/env python3
"""Run EcsBench checks or repeated, interleaved measurements of built checkouts.

Build each sample first; see docs/ecs-phase7-validation.md. No builds happen here.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

MODES = ['gameobject', 'ecs', 'ecs-mt']
COUNTS = [1000, 10000, 50000, 100000]
METRICS = ['frame_avg_ms', 'frame_p99_ms', 'update_avg_ms', 'update_p99_ms', 'spawn_ms']


def positive(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError('must be positive')
    return result


def git_value(project, *args):
    result = subprocess.run(['git', '-C', str(project), *args], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def identify(project, config):
    target = {'Windows': 'Win64', 'Linux': 'Linux64', 'Darwin': 'macOS'}.get(platform.system())
    if target is None:
        raise ValueError(f'Unsupported platform: {platform.system()}')
    exe = project / f'build/{config}_{target}/EcsBench' / ('EcsBench.exe' if os.name == 'nt' else 'EcsBench')
    if not exe.is_file():
        raise ValueError(f'{exe} not found; build this sample first.')
    digest = hashlib.sha256()
    with exe.open('rb') as binary:
        for block in iter(lambda: binary.read(1024 * 1024), b''):
            digest.update(block)
    return exe, dict(project=str(project), revision=git_value(project, 'rev-parse', 'HEAD'),
                     dirty=bool(git_value(project, 'status', '--porcelain')),
                     executable_sha256=digest.hexdigest(), config=config, platform=platform.platform(),
                     processor=platform.processor(), logical_cpus=os.cpu_count())


def schedule(labels, counts, modes, repeats):
    # Pair each workload across builds, reversing order on alternate repetitions.
    for repeat in range(repeats):
        for count in counts:
            for mode in modes:
                for label in labels[::1 if repeat % 2 == 0 else -1]:
                    yield label, count, mode, repeat + 1


def read_result(path, mode, count, frames):
    lines = path.read_text().splitlines() if path.exists() else []
    rows = [json.loads(line) for line in lines if line.strip()]
    if len(rows) != 1:
        raise ValueError(f'Expected one result, received {len(rows)}')
    row = rows[0]
    if (row.get('mode'), row.get('count'), row.get('frames')) != (mode, count, frames):
        raise ValueError('Result does not match requested mode, count and measured frames')
    for key in METRICS + ['memory_before', 'memory_after', 'threads']:
        value = row.get(key)
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value < 0:
            raise ValueError(f'Invalid or missing result metric: {key}')
    return row


def run_one(exe, project, mode, count, frames, timeout):
    with tempfile.TemporaryDirectory() as work:
        out = Path(work) / 'result.jsonl'
        env = dict(os.environ, TALLOW_BENCH_MODE=mode, TALLOW_BENCH_COUNT=str(count),
                   TALLOW_BENCH_FRAMES=str(frames), TALLOW_BENCH_OUT=str(out), TALLOW_BENCH_EXPLORER='0')
        result = subprocess.run([str(exe), '--project', str(project)], env=env, cwd=project,
                                timeout=timeout, capture_output=True, text=True)
        if result.returncode != 0:
            raise ValueError(f'Exit {result.returncode}:\n{(result.stdout + result.stderr)[-4000:]}')
        if mode == 'check':
            if 'EcsBench checks: all passed' not in result.stdout:
                raise ValueError('Process exited without reporting successful ECS checks')
            return None
        return read_result(out, mode, count, frames)


def report(rows):
    print('\nMedian across runs; p99 columns are medians of per-run p99s, not pooled percentiles.\n')
    print('| Build | Mode | Objects | Runs | Frame avg / p99 ms | Update avg / p99 ms | Spawn ms | Memory growth MiB |')
    print('| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |')
    groups = {}
    for row in rows:
        groups.setdefault((row['build'], row['mode'], row['count']), []).append(row)
    for (label, mode, count), runs in groups.items():
        med = lambda key: statistics.median(r[key] for r in runs)
        memory = statistics.median(r['memory_after'] - r['memory_before'] for r in runs) / 2**20
        print(f"| {label} | {mode} | {count:,} | {len(runs)} | {med('frame_avg_ms'):.3f} / {med('frame_p99_ms'):.3f} | "
              f"{med('update_avg_ms'):.3f} / {med('update_p99_ms'):.3f} | {med('spawn_ms'):.2f} | {memory:.1f} |")


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, default=root / 'Samples/EcsBench')
    parser.add_argument('--baseline-project', type=Path, help='Built EcsBench in another checkout; alternates with current.')
    parser.add_argument('--config', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--frames', type=positive, default=600)
    parser.add_argument('--counts', type=positive, nargs='+', default=COUNTS)
    parser.add_argument('--modes', nargs='+', choices=MODES, default=MODES)
    parser.add_argument('--repeats', type=positive, default=3)
    parser.add_argument('--timeout', type=positive, default=1800)
    parser.add_argument('--check', action='store_true', help='Run ECS correctness checks instead of timing workloads.')
    parser.add_argument('--output', type=Path, help='New JSONL file, checkpointed after every successful run.')
    args = parser.parse_args()
    projects = {'current': args.project.resolve()}
    if args.baseline_project:
        projects = {'baseline': args.baseline_project.resolve(), **projects}
        if projects['baseline'] == projects['current']:
            parser.error('Baseline and current projects must be different checkouts.')
    if args.check and args.output:
        parser.error('--output is for benchmark measurements, not --check.')
    try:
        builds = {label: identify(project, args.config) for label, project in projects.items()}
        if args.check:
            for label, (exe, _) in builds.items():
                run_one(exe, projects[label], 'check', 1, 1, args.timeout)
                print(f'{label}: EcsBench checks: all passed', flush=True)
            return
        # Refuse to overwrite measurements. Retain completed runs if a later run fails.
        output = args.output.open('x', encoding='utf-8') if args.output else None
        rows = []
        try:
            for label, count, mode, repeat in schedule(list(projects), args.counts, args.modes, args.repeats):
                print(f'{label}: {mode} x {count}, run {repeat}/{args.repeats}...', flush=True)
                exe, metadata = builds[label]
                row = run_one(exe, projects[label], mode, count, args.frames, args.timeout)
                row.update(build=label, repeat=repeat, metadata=metadata, recorded_at=datetime.now(timezone.utc).isoformat())
                rows.append(row)
                if output:
                    output.write(json.dumps(row, allow_nan=False) + '\n')
                    output.flush()
        finally:
            if output:
                output.close()
        report(rows)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f'EcsBench failed: {error}\n')


if __name__ == '__main__':
    main()
