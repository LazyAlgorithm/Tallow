#!/usr/bin/env python3
"""Measure BeefBuild's fixed warm-build overhead in Tallow's existing reload workspace.

Run while the Tallow editor is closed, after at least one successful script reload.
This benchmark does not edit source files, clear caches, or link replacement modules.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time
import tomllib

import reload_scripts


def command_for(workspace, platform, verbose):
    if platform == 'windows':
        args, env = reload_scripts.beef_command(workspace)
        args = [f'-verbosity={verbose}' if arg.startswith('-verbosity=') else arg for arg in args]
        return args, env
    return ([os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={workspace}',
             '-config=Debug', f'-verbosity={verbose}'], os.environ.copy())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', type=Path, help='Game project containing BeefProj.toml')
    parser.add_argument('--platform', choices=('linux', 'windows'),
                        default='windows' if os.name == 'nt' else 'linux')
    parser.add_argument('--runs', type=int, default=2,
                        help='Repeat unchanged BeefBuild invocations to measure fixed overhead (default: 2)')
    args = parser.parse_args()
    if args.runs < 1 or args.runs > 5:
        parser.error('--runs must be between 1 and 5')
    project = args.project.resolve()
    config = project / 'BeefProj.toml'
    if not config.is_file():
        parser.error(f'No BeefProj.toml at {config}; open the game project in Tallow first.')
    name = tomllib.loads(config.read_text())['Project']['Name']
    workspace = reload_scripts.reload_workspace(project, args.platform)
    if not (workspace / 'BeefSpace.toml').is_file():
        parser.error(f'No warm script workspace at {workspace}; reload a script in Tallow first.')
    command, env = command_for(workspace, args.platform, 'diagnostic')
    print('Close the Tallow editor before running this profile to avoid concurrent builds.', flush=True)
    print(f'Game: {name}; platform: {args.platform}; workspace: {workspace}', flush=True)
    for index in range(1, args.runs + 1):
        log = workspace / f'beef-profile-{index}.log'
        before = reload_scripts.build_output_state(workspace, name, args.platform)
        start = time.perf_counter()
        with log.open('w', encoding='utf-8', errors='replace') as output:
            done = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT)
        duration = time.perf_counter() - start
        after = reload_scripts.build_output_state(workspace, name, args.platform)
        activity = reload_scripts.build_output_activity(before, after)
        print(f'Run {index}: BeefBuild {duration:.3f}s; exit {done.returncode}', flush=True)
        print('  ' + reload_scripts.build_activity_label(activity), flush=True)
        print(f'  Detailed compiler output: {log}', flush=True)
        if done.returncode:
            print('Compiler failed; see the diagnostic log above.', file=sys.stderr)
            return done.returncode
    print('Compare warm no-change times with the BeefBuild number in build/script-reload.log.')
    print('No-change latency indicates a fixed compiler/workspace cost; changed dependency outputs indicate incremental rebuild work.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
