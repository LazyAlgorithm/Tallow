#!/usr/bin/env python3
"""Build/stage the isolated Beef IDE worker with the engine, including Linux runtime libraries."""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def build(platform, output, directory=None):
    output.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'tools/BeefLanguageService/main.cpp'
    windows = platform == 'windows'
    executable = output / ('beef-language-service.exe' if windows else 'beef-language-service')
    staging = output / f'.building-{os.getpid()}'
    staging.mkdir(exist_ok=True)
    temporary = staging / executable.name
    if windows:
        obj = output / 'worker.obj'
        command = ['clang-cl', '/nologo', '/std:c++17', '/EHsc', '/MT', '/O2', '/D_CRT_SECURE_NO_WARNINGS',
                   '/c', str(source), '/Fo' + str(obj)]
        cross = os.name != 'nt'
        if cross:
            win = Path(os.environ.get('TALLOW_WIN', Path.home() / '.local/share/tallow-win'))
            xwin = win / 'xwin'
            for path in ('crt/include', 'sdk/include/ucrt', 'sdk/include/um', 'sdk/include/shared'):
                command += ['-imsvc', str(xwin / path)]
            linker = [str(win / 'bin/lld-link')]
            paths = ['/libpath:' + str(xwin / path) for path in ('crt/lib/x86_64', 'sdk/lib/ucrt/x86_64', 'sdk/lib/um/x86_64')]
        else:
            linker, paths = ['lld-link'], []
        subprocess.run(command, check=True)
        subprocess.run([*linker, str(obj), '/out:' + str(temporary), *paths, 'kernel32.lib'], check=True)
        obj.unlink()
    elif platform == 'linux':
        if directory is None:
            compiler = shutil.which(os.environ.get('BEEFBUILD', 'BeefBuild'))
            if not compiler:
                raise RuntimeError('BeefBuild is required to build the language service.')
            directory = Path(compiler).resolve().parent
        libraries = shlex.split((directory / 'IDEHelper_libs.txt').read_text())
        subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++17', '-O2', str(source),
                        str(directory / 'libIDEHelper.a'), str(directory / 'libBeefySysLib.a'),
                        str(directory / 'libhunspell.so'), *libraries, '-lz', '-ldl', '-lpthread',
                        '-Wl,--disable-new-dtags', '-Wl,-rpath,$ORIGIN', f'-Wl,-rpath,{directory}',
                        '-o', str(temporary)], check=True)
        dependencies = subprocess.run(['ldd', str(temporary)], capture_output=True, text=True, check=True).stdout
        system = {'libc.so.6', 'libm.so.6', 'libpthread.so.0', 'libdl.so.2', 'librt.so.1', 'libgcc_s.so.1', 'libstdc++.so.6'}
        for line in dependencies.splitlines():
            match = re.match(r'\s*(\S+) => (/\S+) ', line)
            if match and match[1] not in system:
                shutil.copy2(Path(match[2]).resolve(), output / match[1])
        # Beef's distribution notice covers the compiler and its bundled dependencies.
        license_roots = [directory, *list(directory.parents)[:3]]
        for name in ('LICENSE.TXT', 'LICENSES.TXT'):
            candidate = next((p / name for p in license_roots if (p / name).is_file()), None)
            if candidate:
                shutil.copy2(candidate, output / ('Beef-' + name))
        for name in ('llvm-libs', 'libedit', 'libffi', 'libxml2', 'ncurses-base', 'xz-libs', 'zstd', 'zlib-ng-compat'):
            notices = Path('/usr/share/licenses') / name
            if notices.is_dir():
                shutil.copytree(notices, output / 'licenses' / name, dirs_exist_ok=True)
    else:
        raise RuntimeError('The Beef semantic worker currently supports Linux and Windows.')
    temporary.replace(executable)
    staging.rmdir()
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['linux', 'windows'], default='windows' if os.name == 'nt' else 'linux')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = (args.output or ROOT / 'build/tools/beef-language-service' / args.platform).resolve()
    print(build(args.platform, output))


if __name__ == '__main__':
    main()
