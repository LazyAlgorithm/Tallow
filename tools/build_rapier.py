#!/usr/bin/env python3
"""Builds the pinned Rapier C bindings into third_party/rapier/prebuilt/<platform>.

Normal source builds do not need this: without an archive the engine builds without Rapier and lists only Jolt.
The release workflow runs it (Rust required here only) so the downloads include Rapier. See
third_party/rapier/VERSION.

  python3 tools/build_rapier.py --platform linux
  python3 tools/build_rapier.py --platform linux --source ~/rapier-src   # reuse a clone
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / 'third_party' / 'rapier'
VERSION = VENDOR / 'VERSION'
# Tallow's changes to Rapier's C bindings only (bindings/c). Rapier itself stays stock so it is compared with Jolt
# out of the box; a patch touching anything else is refused.
BINDINGS_CHANGES = VENDOR / 'bindings-changes'
PLATFORMS = {
    'linux': ('linux-x86_64', 'librapier3d_ffi.a', None),
    'windows': ('windows-x86_64', 'rapier3d_ffi.lib', 'x86_64-pc-windows-msvc'),
    'macos': ('macos-x86_64', 'librapier3d_ffi.a', None),
}


def pinned():
    lines = [line.strip() for line in VERSION.read_text().splitlines() if line.strip()]
    commit = next(line.split(None, 1)[1] for line in lines if line.startswith('commit '))
    return commit


def run(command, cwd=None, env=None):
    print('+', subprocess.list2cmdline([str(c) for c in command]), flush=True)
    subprocess.run([str(c) for c in command], cwd=cwd, check=True, env=env)


def apply_bindings_changes(source):
    """Applies bindings-changes/*.patch (name order) on top of the pinned commit, once each."""
    for patch in sorted(BINDINGS_CHANGES.glob('*.patch')):
        touched = subprocess.run(['git', '-C', str(source), 'apply', '--numstat', str(patch)],
                                 capture_output=True, text=True, check=True).stdout.split('\n')
        outside = [line.split('\t')[-1] for line in touched if line and not line.split('\t')[-1].startswith('bindings/c/')]
        if outside:
            raise SystemExit(f'{patch.name} changes Rapier outside bindings/c: {outside}')
        applied = subprocess.run(['git', '-C', str(source), 'apply', '--reverse', '--check', str(patch)],
                                 capture_output=True)
        if applied.returncode == 0:
            print(f'bindings change already applied: {patch.name}')
            continue
        run(['git', '-C', str(source), 'apply', str(patch)])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=sorted(PLATFORMS), default='linux')
    parser.add_argument('--source', help='an existing Rapier clone (pinned commit is checked out in it)')
    parser.add_argument('--serial', action='store_true',
                        help="build without Rapier's multithreaded step (rayon). Parallel is the default: results are "
                             'bit-identical at any thread count (checked with --bench-physics and --test-physics-rapier)')
    parser.add_argument('--cache', default=str(Path.home() / '.cache' / 'tallow-rapier'))
    args = parser.parse_args()

    commit = pinned()
    source = Path(args.source).expanduser() if args.source else Path(args.cache) / 'rapier'
    if args.source:
        have = subprocess.run(['git', '-C', str(source), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        if have.stdout.strip() != commit:
            print(f'{source} is at {have.stdout.strip()}, expected {commit}; check it out first.', file=sys.stderr)
            return 1
    else:
        if not source.exists():
            run(['git', 'clone', 'https://github.com/dimforge/rapier', str(source)])
        run(['git', '-C', str(source), 'fetch', '--depth', '1', 'origin', commit])
        run(['git', '-C', str(source), 'checkout', '--detach', commit])

    apply_bindings_changes(source)

    folder, library, target = PLATFORMS[args.platform]
    build = source / 'build' / ('tallow-c3' if not target else f'tallow-c3-{args.platform}')
    env = os.environ.copy()
    # One codegen unit with fat LTO across Rapier, parry and nalgebra: no effect on results, a faster step.
    env['CARGO_PROFILE_RELEASE_LTO'] = 'fat'
    env['CARGO_PROFILE_RELEASE_CODEGEN_UNITS'] = '1'
    configure = ['cmake', '-S', str(source / 'bindings' / 'c'), '-B', str(build),
                 '-DCMAKE_BUILD_TYPE=Release', '-DRAPIER_SHARED=OFF',
                 '-DRAPIER_BUILD_TESTS=OFF', '-DRAPIER_BUILD_EXAMPLES=OFF',
                 '-DRAPIER_FEATURES=enhanced-determinism',
                 f'-DRAPIER_ENABLE_PARALLEL={"OFF" if args.serial else "ON"}']
    if target:
        configure.append(f'-DRAPIER_TARGET={target}')
    if target == 'x86_64-pc-windows-msvc' and os.name == 'nt':
        # On Windows itself Rust's MSVC target uses Visual Studio's linker and libraries (a developer shell).
        run(['rustup', 'target', 'add', target])
    elif target == 'x86_64-pc-windows-msvc':
        # Cross-built from Linux, Rust's MSVC target links with the engine's Windows toolchain (clang-cl/lld-link +
        # the xwin SDK/CRT).
        tool = Path(os.environ.get('TALLOW_WIN', Path.home() / '.local/share/tessera-win')).expanduser()
        xwin = tool / 'xwin'
        libs = [xwin / 'crt/lib/x86_64', xwin / 'sdk/lib/um/x86_64', xwin / 'sdk/lib/ucrt/x86_64']
        run(['rustup', 'target', 'add', target])
        env['CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER'] = str(tool / 'bin' / 'lld-link')
        env['LIB'] = ';'.join(str(path) for path in libs)
        env['RUSTFLAGS'] = ' '.join(f'-C link-arg=/LIBPATH:{path}' for path in libs)
    run(configure, env=env)
    run(['cmake', '--build', str(build), '--target', 'rapier_cargo_build', '--parallel',
         str(min(os.cpu_count() or 4, 12))],
        cwd=source, env=env)

    output = VENDOR / 'prebuilt' / folder
    output.mkdir(parents=True, exist_ok=True)
    archive = build / 'cargo' / (f'{target}/' if target else '') / 'release' / library
    if not archive.is_file():
        print(f'missing {archive}', file=sys.stderr)
        return 1
    shutil.copy2(archive, output / library)
    include = output / 'include'
    if include.exists():
        shutil.rmtree(include)
    shutil.copytree(source / 'bindings' / 'c' / 'include', include)
    print(f'Wrote {output / library} and {include}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
