#!/usr/bin/env python3
"""Test project Libraries lookup with a fake Linux Steam API; never contacts Steam."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('achievement_tests', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tallow-steam-lookup-') as folder:
        project = Path(folder) / 'Project With Spaces'
        (project / 'Libraries').mkdir(parents=True)
        (project / 'src').mkdir()
        library = project / 'Libraries/libsteam_api.so'
        source = '''#include <string.h>
int SteamAPI_InitFlat(char *error) { strcpy(error, "library lookup fixture"); return 2; }
void SteamAPI_RunCallbacks(void) {}
'''
        subprocess.run(['cc', '-shared', '-fPIC', '-x', 'c', '-', '-o', str(library)], input=source, text=True, check=True)
        environment = dict(os.environ)
        environment.pop('TALLOW_STEAM_LIB', None)
        for assets in (project / 'src', project):
            subprocess.run([str(args.achievement_tests.resolve()), '--steam-library-check', str(assets)],
                           env=environment, check=True)
        print('PASS: project Libraries lookup from src and project roots; fake runtime only')


if __name__ == '__main__':
    main()
