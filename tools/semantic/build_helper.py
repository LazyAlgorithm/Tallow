#!/usr/bin/env python3
"""Build the isolated helper against the installed Beef compiler on Windows or Linux."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--beef-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.beef_root.resolve()
    dist = root / ('bin' if os.name == 'nt' else 'IDE/dist')
    archive = dist / ('IDEHelper64.dll' if os.name == 'nt' else 'libIDEHelper.a')
    if not archive.is_file():
        parser.error(f'Missing compiler library: {archive}')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if os.name == 'nt':
        command = [os.environ.get('CXX', 'cl'), '/nologo', '/std:c++17', '/EHsc', '/O2',
                   str(Path(__file__).with_name('beef_resolve.cpp')), '/Fe:' + str(args.output.resolve()),
                   '/Fo:' + str(args.output.with_suffix('.obj').resolve())]
    else:
        flags = shlex.split((dist / 'IDEHelper_libs.txt').read_text())
        command = [os.environ.get('CXX', 'c++'), '-std=c++17', '-O2', '-g',
                   str(Path(__file__).with_name('beef_resolve.cpp')), str(archive),
                   str(dist / 'libBeefySysLib.a'), str(dist / 'libhunspell.so'),
                   *flags, '-ldl', '-lpthread', '-lz', '-o', str(args.output)]
    subprocess.run(command, check=True)
    metadata = {'protocol': 1, 'compiler_library_sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
    args.output.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')


if __name__ == '__main__':
    main()
