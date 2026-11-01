#!/usr/bin/env python3
"""Compile a packaged editor project with spaces in engine, compiler and project paths.

Uses real Windows executables, on Windows or through --wine. No graphics required.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import struct
import tempfile
import tomllib


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
    # A moved project remembers an engine from another computer. Opening must relocate it.
    # Source-project relocation is separate from immutable package pins.
    (project / 'tallow-engine.lock.json').unlink(missing_ok=True)
    settings = project / 'project.tallow'
    settings.write_text('\n'.join('engine = Z:/missing-engine' if line.startswith('engine =') else line
                                  for line in settings.read_text().splitlines()) + '\n')
    run(['--build-project', target(project)], 'compile')
    executable = project / 'build/Debug_Win64/OpenProjectSmoke/OpenProjectSmoke.exe'
    assert_gui(executable)
    flags = tomllib.loads((project / 'BeefProj.toml').read_text())['Configs']['Debug']['Win64']['OtherLinkFlags']
    assert '"' in flags and 'Tallow Hub' in flags, flags
    assert 'missing-engine' not in settings.read_text(), 'Moved project did not relocate its engine'
    # The existing executable is moved aside during rebuild. Verify the second build succeeds too.
    run(['--build-project', target(project)], 'rebuild')
    assert executable.is_file()
    # Failed compilation must keep both its log and the last working editor executable.
    previous = executable.read_bytes()
    broken = project / 'src/Scripts/IntentionallyBroken.bf'
    broken.write_text('this is deliberately invalid Beef source;\n')
    result = run(['--build-project', target(project)], 'compile-failure', success=False)
    assert 'The project did not compile:' in result.stdout, 'GUI launcher lost redirected CLI errors'
    assert 'ERROR' in (project / 'build/build.log').read_text(), 'Compiler failure log was lost'
    assert executable.read_bytes() == previous, 'Failed rebuild lost the working executable'
    broken.unlink()
    print(f'PASS: GUI subsystem, packaged Windows create/relocate/compile/rebuild with spaces, failure output and executable recovery; evidence: {work}')


if __name__ == '__main__':
    main()
