#!/usr/bin/env python3
"""Create and compile a renamed Tallow Gallery from a distributed engine package.

Optional --play also runs all exhibit checks using the generated project.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--wine', action='store_true')
    parser.add_argument('--play', action='store_true')
    parser.add_argument('--work', type=Path)
    args = parser.parse_args()
    package = args.package.resolve()
    work = args.work.resolve() if args.work else Path(tempfile.mkdtemp(prefix='tallow-showcase-test-'))
    work.mkdir(parents=True, exist_ok=True)
    project = work / 'Projects With Spaces' / 'RenamedGallery'
    windows = args.wine or os.name == 'nt'
    launcher = package / ('Tallow.exe' if windows else 'Tallow')
    prefix = ['wine'] if args.wine else []
    env = dict(os.environ)
    env.pop('TALLOW_ROOT', None)

    def path(value):
        return 'Z:' + str(value).replace('/', '\\') if args.wine else str(value)

    def run(command, name):
        result = subprocess.run(prefix + list(map(str, command)), cwd=package, env=env, text=True, capture_output=True, timeout=600)
        log = result.stdout + result.stderr
        (work / (name + '.log')).write_text(log)
        if result.returncode != 0:
            raise RuntimeError(f'{name} exited {result.returncode}; see {work}:\n{log[-4000:]}')
        return log

    run([launcher, '--create', path(project), '--showcase'], 'create')
    source = project / 'src'
    scene = (source / 'Scenes/Gallery.tscene').read_text()
    assert 'component RenamedGallery.Gallery enabled 1' in scene
    assert scene.count('component Tallow.ReflectionProbe enabled 1') == 2
    assert 'TallowShowcase.' not in scene and '{NAMESPACE}' not in scene
    assert 'startScene = Scenes/Gallery.tscene' in (project / 'project.tallow').read_text()
    for name in ['cloth16.glb', 'soft_box.glb', 'van_shell.glb', 'Person_Rigged.glb']:
        assert (source / 'Models' / name).is_file(), name
    for file in source.rglob('*.bf'):
        text = file.read_text()
        assert '{NAMESPACE}' not in text and 'namespace TallowShowcase;' not in text, file
    # Confirm binary assets were copied without text conversion.
    template = package / 'Editor/templates/showcase/src'
    for file in template.rglob('*'):
        if file.is_file() and file.suffix not in {'.bf', '.tscene', '.tprefab'}:
            assert file.read_bytes() == (source / file.relative_to(template)).read_bytes(), file
    # Packaged projects must pin the package's exact immutable identity.
    lock = project / 'tallow-engine.lock.json'
    assert lock.is_file(), 'New packaged project was not pinned'
    run([launcher, '--build-project', path(project)], 'compile-pinned')
    # Exercise source-project relocation separately; pinned projects never relocate.
    lock.unlink()
    # Relocation writes project settings again: window size and Escape menu must survive.
    settings = project / 'project.tallow'
    settings.write_text('\n'.join('engine = /missing-showcase-engine' if line.startswith('engine =') else line
                                  for line in settings.read_text().splitlines()) + '\n')
    run([launcher, '--build-project', path(project)], 'compile')
    for expected in ['windowWidth = 1600', 'windowHeight = 900', 'escapeQuits = 0']:
        assert expected in settings.read_text(), expected
    assert '/missing-showcase-engine' not in settings.read_text()
    platform = 'Win64' if windows else 'Linux64'
    player = project / f'build/Debug_{platform}/RenamedGallery' / ('RenamedGallery.exe' if windows else 'RenamedGallery')
    assert player.is_file(), player
    if args.play:
        log = run([player, '--project', path(project), '--self-test', '--frames', '1500'], 'play')
        assert 'SHOWCASE_READY rooms=8 probes=2' in log
        assert '[error]' not in log.lower()
    print(f'PASS: packaged Tallow Gallery creation, renamed scripts/scene, eight rooms, mesh/binary assets, compilation' + (' and all exhibit checks' if args.play else '') + f'; evidence: {work}')


if __name__ == '__main__':
    main()
