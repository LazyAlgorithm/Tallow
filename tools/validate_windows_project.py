#!/usr/bin/env python3
"""Build a packaged editor's C# project with spaces in engine, compiler and project paths.

0.3 removed Beef gameplay: a new project is C#, and its game ships as a player
(tools/build_player.py) on the package's precompiled Windows player, so no Beef compiler is
needed to build the game. Uses real Windows executables, on Windows or through --wine. No graphics required.
"""
import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile


def link_or_copy(source, target):
    try:
        os.link(source, target)
    except OSError:
        shutil.copy2(source, target)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--beef', type=Path, required=True, help='BeefBuild.exe, with its installed toolchain')
    parser.add_argument('--wine', action='store_true')
    parser.add_argument('--work', type=Path, help='Keep all test files and logs in this new directory')
    args = parser.parse_args()
    work = args.work.resolve() if args.work else Path(tempfile.mkdtemp(prefix='tallow-project-test-'))
    work.mkdir(parents=True, exist_ok=True)
    package = work / 'Tallow Hub' / 'Engine' / 'tallow' / 'Tallow-Windows'
    compiler = work / 'Compiler Tools' / 'beef'
    shutil.copytree(args.package.resolve(), package, copy_function=link_or_copy)
    shutil.copytree(args.beef.resolve().parent.parent, compiler, copy_function=link_or_copy)
    beef = compiler / 'bin' / args.beef.name
    project = work / 'Projects With Spaces' / 'OpenProjectSmoke'
    environment = dict(os.environ)

    def target(path):
        return 'Z:' + str(path).replace('/', '\\') if args.wine else str(path)

    environment['BEEFBUILD'] = target(beef)
    # Exercise engine discovery from the installed launcher, without a developer override.
    environment.pop('TALLOW_ROOT', None)
    launcher = (['wine'] if args.wine else []) + [str(package / 'Tallow.exe')]

    def assert_gui(executable):
        data = executable.read_bytes()
        assert data[:2] == b'MZ', f'Not a Windows executable: {executable}'
        pe = struct.unpack_from('<I', data, 0x3C)[0]
        assert struct.unpack_from('<H', data, pe + 24 + 68)[0] == 2, f'External console subsystem: {executable}'

    assert_gui(package / 'Tallow.exe')

    def run(arguments, name, success=True):
        result = subprocess.run(launcher + arguments, env=environment, text=True, capture_output=True, timeout=600)
        (work / (name + '.log')).write_text(result.stdout + result.stderr)
        if (result.returncode == 0) != success:
            print(result.stdout + result.stderr)
            raise RuntimeError(f'{name} had unexpected exit status {result.returncode}; evidence: {work}')
        return result

    run(['--create', target(project)], 'create')
    # The empty template's start scene is built on first editor open, which this headless test never does; write a minimal one.
    (project / 'src' / 'Scenes').mkdir(parents=True, exist_ok=True)
    (project / 'src' / 'Scenes' / 'Main.tscene').write_text('scene "Main"\n', encoding='utf-8')
    # A moved project remembers an engine from another computer. Opening must relocate it.
    (project / 'tallow-engine.lock.json').unlink(missing_ok=True)
    settings = project / 'project.tallow'
    settings.write_text('\n'.join('engine = Z:/missing-engine' if line.startswith('engine =') else line
                                  for line in settings.read_text().splitlines()) + '\n')
    run(['--build-project', target(project)], 'compile')

    # The game is a C# player (tools/build_player.py) on the package's precompiled Windows player.
    build_player = [sys.executable, str(package / 'tools' / 'build_player.py'), str(project),
                    '--output', str(work / 'Built'), '--platform', 'windows', '--csharp-runtime', 'jit']
    result = subprocess.run(build_player, env=environment, text=True, capture_output=True, timeout=600)
    (work / 'build-game.log').write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        print(result.stdout + result.stderr)
        raise RuntimeError(f'build_player failed; evidence: {work}')
    executable = work / 'Built' / 'OpenProjectSmoke.exe'
    assert_gui(executable)
    assert 'missing-engine' not in settings.read_text(), 'Moved project did not relocate its engine'

    # A second build replaces the first; it must succeed too.
    result = subprocess.run(build_player + ['--replace'], env=environment, text=True, capture_output=True, timeout=600)
    (work / 'rebuild-game.log').write_text(result.stdout + result.stderr)
    if result.returncode != 0:
        print(result.stdout + result.stderr)
        raise RuntimeError(f'rebuild failed; evidence: {work}')
    assert executable.is_file()

    # Failed compilation must keep its log and the last working game executable.
    previous = executable.read_bytes()
    broken = project / 'src/Scripts/IntentionallyBroken.cs'
    broken.write_text('this is deliberately invalid C# source;\n', encoding='utf-8')
    result = run(['--build-project', target(project)], 'compile-failure', success=False)
    assert 'compilation failed' in result.stdout, 'GUI launcher lost redirected CLI errors'
    assert executable.read_bytes() == previous, 'Failed rebuild lost the working executable'
    broken.unlink()
    print(f'PASS: GUI subsystem, packaged Windows C# create/relocate/compile/game-build/rebuild with spaces; evidence: {work}')


if __name__ == '__main__':
    main()
