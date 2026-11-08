#!/usr/bin/env python3
"""Build Tallow from a source checkout on Linux or native Windows (Python 3.11+).

On Windows run from an x64 Visual Studio developer shell with clang-cl installed.
Cross-building Windows from Linux is handled by tools/windows/setup.sh instead.
"""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

NATIVE_TARGETS = ['tallow_native', 'bgfx', 'bimg', 'bimg_decode', 'bx', 'SDL3-static', 'joltc', 'Jolt', 'enet',
                  'shaderc', 'texturec', 'tallow_modelsettings', 'tallow_modelconv']


def ensure_source_identity(root: Path) -> None:
    """Give source worktrees a valid engine identity without changing packaged releases.

    Engine Manager's installed builds carry their own immutable manifest.
    A git worktree has no packaged manifest, but the project builder still
    requires one to pin projects and validate version compatibility.
    """
    if (root / 'tallow-package.txt').exists():
        return
    git = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root,
                         capture_output=True, text=True, check=False)
    build = git.stdout.strip() if git.returncode == 0 else ''
    if not re.fullmatch(r'[0-9a-f]{40}', build):
        return  # A non-git source bundle needs its own packaged manifest.

    manifest = root / 'tallow-version.json'
    if manifest.exists():
        try:
            current = json.loads(manifest.read_text(encoding='utf-8'))
        except (OSError, ValueError) as exc:
            raise RuntimeError(f'Invalid engine identity at {manifest}: {exc}') from exc
        if current.get('version') != '0.0.0-dev':
            return  # Never overwrite a release / installed engine identity.
        if current.get('build') == build:
            return
    manifest.write_text(json.dumps({
        'engine': 'Tallow', 'version': '0.0.0-dev', 'build': build,
        'project_format': 1
    }, indent=2) + '\n', encoding='utf-8')
    print(f'Source engine identity: 0.0.0-dev ({build[:12]})', flush=True)


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
    ensure_source_identity(root)
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
    run([sys.executable, root / 'tools/build_beef_language_service.py', '--platform', 'windows' if windows else 'linux'])
    print(f'Done. Launcher: {executable}')


if __name__ == '__main__':
    main()
