#!/usr/bin/env python3
"""Builds native/tallow_navigation.cpp with Recast and Detour under AddressSanitizer and UndefinedBehaviorSanitizer,
together with native_smoke.cpp, and runs it.

    python3 Tests/NavigationMesh/sanitize.py

Needs clang++ (or CXX) and the native build in build/native (for the Jolt headers and archives). Exits non-zero when
the build fails or the sanitizers report anything.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RECAST = ROOT / 'third_party/recastnavigation'
# The definitions tallow_native compiles Jolt with, so its headers lay types out the same way as the archives.
JOLT_DEFINES = ['JPH_OBJECT_LAYER_BITS=32', 'JPH_CROSS_PLATFORM_DETERMINISTIC', 'JPH_OBJECT_STREAM', 'JPH_USE_CPU_COMPUTE']


def command(binary):
    """The compile and link command for the smoke test."""
    args = [os.environ.get('CXX', 'clang++'), '-std=c++17', '-O1', '-g', '-DNDEBUG', '-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    args += ['-D' + define for define in JOLT_DEFINES]
    for include in [RECAST / 'Recast/Include', RECAST / 'Detour/Include', ROOT / 'third_party/joltc/include', ROOT / 'build/native/_deps/joltphysics-src']:
        args.append('-I' + str(include))
    args += [str(ROOT / 'native/tallow_navigation.cpp'), str(ROOT / 'Tests/NavigationMesh/native_smoke.cpp')]
    for library in ['Recast', 'Detour']:
        args += [str(source) for source in sorted((RECAST / library / 'Source').glob('*.cpp'))]
    args += ['-Wl,--start-group', str(ROOT / 'build/native/joltc/libjoltc.a'), str(ROOT / 'build/native/_deps/joltphysics-build/libJolt.a'), '-Wl,--end-group']
    args += ['-pthread', '-ldl', '-lm', '-o', str(binary)]
    return args


def main():
    with tempfile.TemporaryDirectory(prefix='tallow-navmesh-sanitize-') as directory:
        binary = Path(directory) / 'native-smoke'
        if subprocess.run(command(binary)).returncode != 0:
            print('FAIL: the sanitized smoke test did not build')
            return 1
        # Stop at the first report rather than carrying on past it.
        env = dict(os.environ, UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1')
        if subprocess.run([str(binary)], env=env).returncode != 0:
            print('FAIL: the sanitized smoke test reported a problem')
            return 1
    print('PASS: native navigation under ASan and UBSan')
    return 0


if __name__ == '__main__':
    sys.exit(main())
