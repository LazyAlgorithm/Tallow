#!/usr/bin/env python3
"""Build Tallow from a source checkout on Linux or native Windows (Python 3.11+).

On Windows run from an x64 Visual Studio developer shell with clang-cl installed.
Cross-building Windows from Linux is handled by tools/windows/setup.sh instead.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

NATIVE_TARGETS = ['tessera_native', 'bgfx', 'bimg', 'bimg_decode', 'bx', 'SDL3-static', 'joltc', 'Jolt', 'enet',
                  'shaderc', 'texturec', 'tessera_modelsettings', 'tessera_modelconv']


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', choices=['Debug', 'Release'], default='Debug')
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 1, 12))
    parser.add_argument('--skip-native', action='store_true', help='Reuse native dependencies built for this checkout.')
    parser.add_argument('--skip-shaders', action='store_true', help='Reuse the shipped/previously compiled engine shaders.')
    args = parser.parse_args()
    if sys.version_info < (3, 11):
        parser.error('Python 3.11 or later is required.')
    if args.jobs < 1:
        parser.error('--jobs must be positive.')
    if sys.platform not in ('linux', 'win32'):
        parser.error('This entry point supports Linux and Windows; see docs/macos.md for macOS.')
    windows = os.name == 'nt'
    beef = os.environ.get('BEEFBUILD', 'BeefBuild')
    required = [beef] + ([] if args.skip_native else ['cmake', 'ninja', 'clang-cl' if windows else 'c++'])
    missing = [tool for tool in required if not shutil.which(tool)]
    if missing:
        parser.error('Missing build tools: ' + ', '.join(missing) + '. See docs/building-from-source.md.')

    def run(command):
        print('+', subprocess.list2cmdline(list(map(str, command))), flush=True)
        subprocess.run(list(map(str, command)), cwd=root, check=True)

    if not args.skip_native:
        run([sys.executable, root / 'tools/patch_textedit.py'])
        native = root / 'build' / ('native-win' if windows else 'native')
        configure = ['cmake', '-S', root / 'native', '-B', native, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release']
        if windows:
            configure += ['-DCMAKE_C_COMPILER=clang-cl', '-DCMAKE_CXX_COMPILER=clang-cl',
                          '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded', '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW']
        run(configure)
        run(['cmake', '--build', native, '--target', *NATIVE_TARGETS, '-j', args.jobs])
    if not args.skip_shaders:
        run([sys.executable, root / 'tools/compile_shaders.py'])
    run([sys.executable, root / 'tools/make_licenses.py'])
    platform = 'Win64' if windows else 'Linux64'
    executable = root / f'build/{args.config}_{platform}/TallowLauncher' / ('TallowLauncher.exe' if windows else 'TallowLauncher')
    # Beef does not track native archive changes. Restore the last executable if the relink fails.
    previous = executable.with_name(executable.name + '.build-backup')
    if previous.exists():
        parser.error(f'Interrupted build backup exists: {previous}; restore it before retrying.')
    if executable.exists():
        executable.rename(previous)
    try:
        run([beef, f'-workspace={root}', f'-config={args.config}', f'-platform={platform}', '-verbosity=minimal'])
        if not executable.is_file():
            raise RuntimeError('Compiler did not produce the launcher.')
    except BaseException:
        if previous.exists():
            executable.unlink(missing_ok=True)
            previous.rename(executable)
        raise
    previous.unlink(missing_ok=True)
    print(f'Done. Launcher: {executable}')


if __name__ == '__main__':
    main()
