#!/usr/bin/env python3
"""Immutable Tallow engine identities, project pins, and side-by-side installs."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

MANIFEST = 'tallow-version.json'
LOCK = 'tallow-engine.lock.json'
BUILD = re.compile(r'^[a-f0-9]{40}$')
VERSION = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9.+-]*$')


def identity(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    if (data.get('engine') != 'Tallow'
            or not isinstance(data.get('version'), str)
            or not VERSION.fullmatch(data['version'])
            or not isinstance(data.get('build'), str)
            or not BUILD.fullmatch(data['build'])
            or type(data.get('project_format')) is not int
            or data['project_format'] < 1):
        raise ValueError('Invalid immutable Tallow engine identity')
    return {key: data[key] for key in ('engine', 'version', 'build', 'project_format')}


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', encoding='utf-8', dir=path.parent,
                                         prefix='.tallow-', delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(data, stream, sort_keys=True, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def pin(project, manifest):
    project = Path(project)
    if not project.is_dir():
        raise ValueError('Project directory does not exist')
    new = identity(manifest)
    lock = project / LOCK
    if lock.exists() and identity(lock) != new:
        raise ValueError('Different engine pinned; explicit project migration required')
    write_json(lock, new)
    return lock



def verify(project, engine):
    """Check that the selected engine exactly matches the project's lock."""
    lock = Path(project) / LOCK
    if not lock.exists():
        return False  # Legacy projects are not silently pinned.
    expected = identity(lock)
    actual = identity(Path(engine) / MANIFEST)
    if expected != actual:
        raise ValueError('Project requires a different engine build; migration is explicit')
    return True


def pin_new(project, engine):
    """Pin a newly created project; never overwrite an existing pin."""
    lock = Path(project) / LOCK
    if lock.exists():
        return verify(project, engine)
    return pin(project, Path(engine) / MANIFEST)


def registry(root):
    path = Path(root) / 'versions.json'
    if not path.exists():
        return {'schema': 1, 'installations': []}
    data = json.loads(path.read_text(encoding='utf-8'))
    if data.get('schema') != 1 or not isinstance(data.get('installations'), list):
        raise ValueError('Unsupported version registry')
    return data


def install(package, root):
    """Install a previously checksum-verified, extracted portable package.

    Archive download, verification and dependency installation reuse Hub code.
    """
    package, root = Path(package).resolve(), Path(root).resolve()
    version = identity(package / MANIFEST)
    target = root / 'versions' / version['version'] / version['build']
    data = registry(root)
    if target.exists():
        raise FileExistsError(f'Already installed: {target}')
    if any(all(item.get(key) == value for key, value in version.items())
           for item in data['installations']):
        raise ValueError('Engine already registered')
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.tallow-stage-', dir=target.parent))
    try:
        shutil.copytree(package, stage, dirs_exist_ok=True, symlinks=False)
        if identity(stage / MANIFEST) != version:
            raise ValueError('Staged manifest mismatch')
        stage.rename(target)
        try:
            data['installations'].append({**version, 'path': str(target)})
            write_json(root / 'versions.json', data)
        except BaseException:
            shutil.rmtree(target)
            raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return target


def resolve(project, root):
    version = identity(Path(project) / LOCK)
    base = (Path(root).resolve() / 'versions')
    for item in registry(root)['installations']:
        if all(item.get(key) == value for key, value in version.items()):
            path = Path(item['path']).resolve()
            if path.is_relative_to(base) and path.is_dir():
                if identity(path / MANIFEST) == version:
                    return path
    raise FileNotFoundError('Pinned engine build missing; install or locate it explicitly')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command, names in (('pin', ('project', 'manifest')),
                           ('install', ('package', 'root')),
                           ('resolve', ('project', 'root')),
                           ('verify', ('project', 'engine')),
                           ('pin-new', ('project', 'engine'))):
        action = sub.add_parser(command)
        for name in names:
            action.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        result = {'pin': pin, 'install': install, 'resolve': resolve, 'verify': verify,
                  'pin-new': pin_new}[args.command](
            *[getattr(args, name) for name in
              {'pin': ('project', 'manifest'), 'install': ('package', 'root'),
               'resolve': ('project', 'root'), 'verify': ('project', 'engine'),
               'pin-new': ('project', 'engine')}[args.command]])
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f'Error: {error}\n')
    print(result)


if __name__ == '__main__':
    main()
