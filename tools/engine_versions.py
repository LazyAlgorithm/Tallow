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
# The engine's old namespace, in code and in saved component names; never a game's own TesseraIntro or a sentence.
LEGACY_NAME = re.compile(r'\bTessera(?=\.[A-Z]|;|::)')


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


def recorded_engine(project):
    """The engine folder a project file names, or None."""
    for name in ('project.tallow', 'project.tessera'):
        path = project / name
        if path.is_file():
            for line in path.read_text(encoding='utf-8').splitlines():
                key, _, value = line.partition('=')
                if key.strip() == 'engine':
                    return (project / value.strip()).resolve()
    return None


def check(project, engine):
    """Say what opening a project with this engine means: one tab-separated line for the launcher.

    same: open it as it is. upgrade: it needs moving to this engine first. newer: this engine cannot read it.
    """
    project, engine = Path(project), Path(engine)
    current = identity(engine / MANIFEST)
    if not (project / 'project.tallow').exists():
        return f"upgrade\tTessera\t{current['version']}"
    lock = project / LOCK
    if not lock.exists():
        return 'same'
    pinned = identity(lock)
    if pinned == current:
        return 'same'
    if pinned['project_format'] > current['project_format']:
        return f"newer\t{pinned['version']}\t{current['version']}"
    recorded = recorded_engine(project)
    if recorded is not None and (recorded / MANIFEST).is_file() and identity(recorded / MANIFEST) == pinned:
        return 'same'  # The engine it is pinned to is still installed.
    return f"upgrade\t{pinned['version']}\t{current['version']}"


def keep_copy(project, backup, file):
    target = backup / file.relative_to(project)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(file, target)


def upgrade(project, engine):
    """Move a project to this engine, keeping every file it changes in .tallow-upgrade-backup."""
    project, engine = Path(project).resolve(), Path(engine).resolve()
    if check(project, engine).startswith('newer'):
        raise ValueError('Project needs a newer Tallow engine')
    backup = project / '.tallow-upgrade-backup' / identity(engine / MANIFEST)['build']
    legacy = project / 'project.tessera'
    settings = project / 'project.tallow'
    if legacy.exists() and not settings.exists():
        keep_copy(project, backup, legacy)
        legacy.rename(settings)
        for file in (project / 'src').rglob('*'):
            if not file.is_file():
                continue
            data = file.read_bytes()
            if b'\0' in data or b'Tessera' not in data:
                continue
            try:
                text = data.decode('utf-8')
            except UnicodeDecodeError:
                continue
            updated = LEGACY_NAME.sub('Tallow', text)
            if updated != text:
                keep_copy(project, backup, file)
                file.write_bytes(updated.encode('utf-8'))
    else:
        keep_copy(project, backup, settings)
    lines = settings.read_text(encoding='utf-8').splitlines()
    entry = f'engine = {engine.as_posix()}'
    lines = [entry if line.partition('=')[0].strip() == 'engine' else line for line in lines]
    if entry not in lines:
        lines.append(entry)
    settings.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    if (project / LOCK).exists():
        keep_copy(project, backup, project / LOCK)
    write_json(project / LOCK, identity(engine / MANIFEST))
    return project / LOCK


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
                           ('pin-new', ('project', 'engine')),
                           ('check', ('project', 'engine')),
                           ('upgrade', ('project', 'engine'))):
        action = sub.add_parser(command)
        for name in names:
            action.add_argument(name, type=Path)
    args = parser.parse_args()
    try:
        result = {'pin': pin, 'install': install, 'resolve': resolve, 'verify': verify,
                  'pin-new': pin_new, 'check': check, 'upgrade': upgrade}[args.command](
            *[getattr(args, name) for name in
              {'pin': ('project', 'manifest'), 'install': ('package', 'root'),
               'resolve': ('project', 'root'), 'verify': ('project', 'engine'),
               'pin-new': ('project', 'engine'), 'check': ('project', 'engine'),
               'upgrade': ('project', 'engine')}[args.command]])
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f'Error: {error}\n')
    print(result)


if __name__ == '__main__':
    main()
