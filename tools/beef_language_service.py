#!/usr/bin/env python3
"""Run Beef IDE semantic queries against a snapshot of a Tallow workspace.

Request/response records are tab separated; offsets and columns are UTF-8 byte offsets.
The worker never writes project sources. All open buffers must be supplied as overlays.
"""
import argparse
from collections import Counter
import hashlib
import json
import queue
import secrets
import socket
import threading
import time
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parent.parent
_PROCESS = None
_PROCESS_OUTPUT = None
_READ_CACHE = {}
_SNAPSHOT_ROOT = None
_SNAPSHOTS = set()


def read_source(path):
    stat = path.stat()
    signature = (stat.st_mtime_ns, stat.st_ctime_ns, stat.st_size)
    cached = _READ_CACHE.get(path)
    if cached is not None and cached[0] == signature:
        return cached[1]
    data = path.read_bytes()
    if _SNAPSHOT_ROOT is not None:
        _READ_CACHE[path] = (signature, data)
    return data


def source_snapshot(data, folder):
    directory = _SNAPSHOT_ROOT or folder / 'sources'
    directory.mkdir(exist_ok=True, parents=True)
    snapshot = directory / (hashlib.sha256(data).hexdigest() + '.bf')
    if not snapshot.exists():
        snapshot.write_bytes(data)
    return snapshot


def stop_worker():
    global _PROCESS
    if _PROCESS is not None:
        _PROCESS.terminate()
        try:
            _PROCESS.wait(timeout=3)
        except subprocess.TimeoutExpired:
            _PROCESS.kill()
            _PROCESS.wait()
        _PROCESS.stdin.close()
        _PROCESS.stdout.close()
        _PROCESS = None


def native_query(executable, manifest, mode, path, cursor, output, isolated=False):
    global _PROCESS, _PROCESS_OUTPUT
    if _SNAPSHOT_ROOT is None or isolated:
        result = subprocess.run([str(executable), str(manifest), mode, str(path), str(cursor), str(output)],
                                capture_output=True, text=True, timeout=90,
                                env=dict(os.environ, BEEF_IDE_DIR=str(toolchain()[0])))
        if result.returncode:
            raise RuntimeError(f'Beef semantic query failed ({result.returncode}): ' + result.stderr[-1200:])
        return
    for attempt in range(2):
        if _PROCESS is None or _PROCESS.poll() is not None:
            _PROCESS_OUTPUT = queue.Queue()
            _PROCESS = subprocess.Popen([str(executable), '--serve'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        text=True, env=dict(os.environ, BEEF_IDE_DIR=str(toolchain()[0])))
            def read_results(process, results):
                for line in process.stdout:
                    if line.startswith('TALLOW_RESULT\t'):
                        results.put(int(line.split('\t')[1]))
                results.put(-1)
            threading.Thread(target=read_results, args=(_PROCESS, _PROCESS_OUTPUT), daemon=True).start()
        _PROCESS.stdin.write('\t'.join([str(manifest), mode, str(path), str(cursor), str(output)]) + '\n')
        _PROCESS.stdin.flush()
        try:
            status = _PROCESS_OUTPUT.get(timeout=90)
        except queue.Empty:
            stop_worker()
            raise RuntimeError('Beef semantic query timed out.')
        if status == 0:
            return
        stop_worker()
        if status != 2:
            raise RuntimeError(f'Beef semantic query failed ({status}); the compiler worker will restart.')
    raise RuntimeError('Workspace changed while the compiler was being restarted.')


def clean(value):
    return ''.join(c if ord(c) >= 32 else ' ' for c in str(value)).strip()


def toolchain():
    executable = shutil.which(os.environ.get('BEEFBUILD', 'BeefBuild'))
    if not executable:
        raise RuntimeError('BeefBuild is unavailable; install the Beef toolchain for IntelliSense.')
    directory = Path(executable).resolve().parent
    config = tomllib.loads((directory / 'BeefConfig.toml').read_text())
    for location in config.get('UnversionedLibDirs', []):
        corlib = (directory / location / 'corlib').resolve()
        if (corlib / 'src').is_dir():
            return directory, corlib
    raise RuntimeError('The Beef toolchain does not contain corlib sources.')


def helper(directory):
    if sys.platform not in ('linux', 'win32'):
        raise RuntimeError('Beef-backed IntelliSense is currently supported on Linux and Windows.')
    platform = 'windows' if os.name == 'nt' else 'linux'
    name = 'beef-language-service.exe' if os.name == 'nt' else 'beef-language-service'
    packaged = ROOT / 'tools/beef-language-service' / name
    if packaged.is_file():
        return packaged
    source = ROOT / 'tools/BeefLanguageService/main.cpp'
    api = source.with_name('api.inc')
    built = ROOT / 'build/tools/beef-language-service' / platform / name
    if built.is_file() and built.stat().st_mtime >= max(source.stat().st_mtime, api.stat().st_mtime):
        return built
    archive = directory / ('IDEHelper64.dll' if os.name == 'nt' else 'libIDEHelper.a')
    if sys.platform not in ('linux', 'win32') or not archive.exists():
        raise RuntimeError('Beef IDE compiler libraries are unavailable. Supported platforms: Linux and Windows.')
    identity = hashlib.sha256(source.read_bytes() + api.read_bytes() + str(directory).encode() + str(archive.stat().st_mtime_ns).encode()).hexdigest()[:16]
    folder = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'tallow/beef-language-service' / identity
    executable = folder / name
    if not executable.is_file():
        from build_beef_language_service import build
        build(platform, folder, directory)
    return executable


def read_request(folder):
    values, overlays = {}, {}
    for line in (folder / 'request.tsv').read_text().splitlines():
        fields = line.split('\t')
        if fields[0] == 'overlay' and len(fields) == 3:
            overlays[Path(fields[1]).resolve()] = Path(fields[2]).resolve()
        elif len(fields) == 2:
            values[fields[0]] = fields[1]
        else:
            raise RuntimeError('Malformed language-service request.')
    return values, overlays


def workspace(project, corlib, overlays, folder):
    global _SNAPSHOTS
    snapshots = folder / 'sources'
    snapshots.mkdir(exist_ok=True)
    space = tomllib.loads((project / 'BeefSpace.toml').read_text())
    projects = [('corlib', corlib)]
    pending = {}
    for name, value in space['Projects'].items():
        if name != 'corlib':
            pending[name] = (project / value['Path']).resolve()
    # Dependencies must be defined before projects that use them.
    while pending:
        for name, directory in list(pending.items()):
            metadata = tomllib.loads((directory / 'BeefProj.toml').read_text())
            if not any(dependency in pending for dependency in metadata.get('Dependencies', {})):
                projects.append((name, directory))
                del pending[name]
                break
        else:
            raise RuntimeError('Cyclic or unsupported workspace dependencies.')
    rows, contents = [], {}
    for index, (name, directory) in enumerate(projects):
        metadata = tomllib.loads((directory / 'BeefProj.toml').read_text())
        platform = 'Win64' if os.name == 'nt' else 'Linux64'
        config = metadata.get('Configs', {}).get('Debug', {}).get(platform, {})
        defines = ['BF_PLATFORM_WINDOWS' if os.name == 'nt' else 'BF_PLATFORM_LINUX', 'BF_64_BIT', 'DEBUG', *config.get('PreprocessorMacros', [])]
        dependencies = metadata.get('Dependencies', {})
        indexes = {n: i for i, (n, _) in enumerate(projects[:index])}
        missing = [n for n in dependencies if n not in indexes]
        if missing:
            raise RuntimeError('Unresolved workspace dependency: ' + ', '.join(missing))
        rows.append(['project', name, str(directory), '|'.join(defines), ','.join(str(indexes[n]) for n in dependencies) or '-'])
        for path in sorted((directory / 'src').rglob('*.bf')):
            path = path.resolve()
            snapshot = overlays.get(path, path)
            contents[path] = read_source(snapshot) if snapshot == path else snapshot.read_bytes()
            snapshot = source_snapshot(contents[path], folder)
            rows.append(['source', str(index), str(path), str(snapshot)])
    # A newly-created, unsaved project script may not yet exist on disk.
    for path, snapshot in overlays.items():
        if path not in contents and path.is_relative_to(project / 'src') and path.suffix == '.bf':
            index = next(i for i, (_, directory) in enumerate(projects) if directory == project)
            contents[path] = read_source(snapshot) if snapshot == path else snapshot.read_bytes()
            snapshot = source_snapshot(contents[path], folder)
            rows.append(['source', str(index), str(path), str(snapshot)])
    if _SNAPSHOT_ROOT is not None:
        current = {Path(row[3]) for row in rows if row[0] == 'source'}
        for snapshot in _SNAPSHOTS - current:
            snapshot.unlink(missing_ok=True)
        _SNAPSHOTS = current
        for path in list(_READ_CACHE):
            if path not in contents:
                del _READ_CACHE[path]
    return rows, contents


def query(executable, rows, folder, mode, path, cursor, label):
    manifest = folder / (label + '.manifest.tsv')
    manifest.write_text('\n'.join('\t'.join(row) for row in rows))
    output = folder / (label + '.raw')
    for suffix in ('', '.diagnostics', '.references'):
        Path(str(output) + suffix).unlink(missing_ok=True)
    native_query(executable, manifest, mode, path, cursor, output, isolated=label == 'rename-check')
    info = output.read_text() if output.exists() else ''
    diagnostics = Path(str(output) + '.diagnostics').read_text()
    refs_file = Path(str(output) + '.references')
    return info, diagnostics, refs_file.read_text() if refs_file.exists() else ''


def references(raw, contents):
    result = []
    for line in raw.splitlines():
        if not line:
            continue
        filename, positions = line.split('\t', 1)
        path = Path(filename).resolve()
        positions = list(map(int, positions.split()))
        for start, length in zip(positions[::2], positions[1::2]):
            text = contents[path][start:start + length].decode('utf-8')
            result.append((path, start, length, text))
    return sorted(set(result))


def error_counts(diagnostics):
    return Counter(line.split('\t', 5)[-1] for line in diagnostics.splitlines() if '\terror\t' in line)


def rename(executable, rows, contents, folder, project, path, cursor, new_name, initial):
    if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', new_name):
        raise RuntimeError('Enter a valid Beef identifier.')
    info, before, raw = initial
    refs = references(raw, contents)
    if not refs or not any(p == path and start <= cursor <= start + length for p, start, length, _ in refs):
        raise RuntimeError('The compiler could not identify this symbol consistently.')
    for filename, _, _, _ in refs:
        if not filename.is_relative_to(project / 'src'):
            raise RuntimeError('This symbol has declarations or references outside this project; rename it in its owning workspace.')
        if filename.with_suffix('.tgraph').exists():
            raise RuntimeError('This symbol occurs in generated graph code. Convert the graph to a script before renaming.')
    replacement = new_name.encode()
    changed, expected = {}, set()
    for filename in sorted({r[0] for r in refs}):
        source = contents[filename]
        offset = 0
        for _, start, length, old in (r for r in refs if r[0] == filename):
            expected.add((filename, start + offset, len(replacement)))
            offset += len(replacement) - length
        for _, start, length, old in sorted((r for r in refs if r[0] == filename), reverse=True):
            source = source[:start] + replacement + source[start + length:]
        snapshot = folder / f'renamed-{len(changed)}.bf'
        snapshot.write_bytes(source)
        changed[filename] = snapshot
    new_rows = [row[:3] + [str(changed[Path(row[2])])] if row[0] == 'source' and Path(row[2]) in changed else row for row in rows]
    first_path, first_start, _ = min(expected)
    after_info, after, after_raw = query(executable, new_rows, folder, 'references', first_path, first_start + 1, 'rename-check')
    new_errors = error_counts(after) - error_counts(before)
    if new_errors:
        raise RuntimeError('Rename would introduce a compiler error: ' + next(iter(new_errors)))
    new_contents = {p: changed[p].read_bytes() if p in changed else data for p, data in contents.items()}
    actual = {(p, start, length) for p, start, length, _ in references(after_raw, new_contents)}
    if actual != expected:
        raise RuntimeError('Rename would change symbol binding or collide with another declaration.')
    return refs


def execute(project, folder):
    request, overlays = read_request(folder)
    mode = request['operation']
    if mode not in {'completion', 'signature', 'definition', 'symbol', 'diagnostics', 'references', 'rename'}:
        raise RuntimeError('Unknown semantic operation.')
    path = Path(request['file']).resolve()
    cursor = int(request.get('cursor', '0'))
    directory, corlib = toolchain()
    rows, contents = workspace(project, corlib, overlays, folder)
    if path not in contents or cursor < 0 or cursor > len(contents[path]):
        raise RuntimeError('The source file or cursor is outside the workspace snapshot.')
    executable = helper(directory)
    initial = query(executable, rows, folder, mode, path, cursor, 'query')
    info, diagnostics, raw_refs = initial
    output = []
    for line in info.splitlines():
        fields = line.split('\t')
        kind = fields[0]
        if kind == 'defLoc' and len(fields) >= 4:
            output.append(['definition', *fields[1:4]])
        elif kind == 'invoke' and len(fields) >= 2:
            output.append(['signature', clean(fields[1])])
        elif kind == 'insertRange' and len(fields) >= 2:
            start, end = map(int, fields[1].split())
            output.append(['range', str(max(0, start)), str(cursor if end < 0 else end)])
        elif mode == 'completion' and kind in {
            'method', 'value', 'type', 'namespace', 'keyword', 'generic', 'interface',
            'struct', 'class', 'field', 'property', 'object', 'pointer', 'token',
            'valuetype', 'label', 'this', 'local', 'parameter', 'param', 'argument',
            'constant', 'const', 'enumCase', 'enumValue', 'enum', 'delegate', 'function',
        } and len(fields) >= 2:
            label, _, detail = fields[1].partition('\x03')
            label = label.partition('\x02')[0]
            output.append(['completion', clean(label), clean(detail or kind)])
        elif mode == 'symbol' and line:
            output.append(['signature', clean(line)])
    if mode == 'rename':
        refs = rename(executable, rows, contents, folder, project, path, cursor, request.get('new_name', ''), initial)
    else:
        refs = references(raw_refs, contents)
    for filename in sorted({r[0] for r in refs}):
        snapshot = folder / f'reference-source-{len(output)}.bf'
        snapshot.write_bytes(contents[filename])
        output.append(['snapshot', str(filename), str(snapshot)])
    for filename, start, length, old in refs:
        output.append(['reference', str(filename), str(start), str(length), old])
    output += [line.split('\t') for line in diagnostics.splitlines()]
    return output


def write_response(project, folder):
    try:
        result = execute(project, folder)
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        result = [['error', clean(error)]]
    temporary = folder / 'response.tmp'
    temporary.write_text('\n'.join('\t'.join(clean(field) for field in row) for row in result) + '\n', newline='\n')
    temporary.replace(folder / 'response.tsv')
    return 1 if any(row[0] == 'error' for row in result) else 0


def receive(connection):
    data = bytearray()
    while b'\n' not in data:
        part = connection.recv(4096)
        if not part or len(data) > 1024 * 1024:
            raise RuntimeError('Invalid language-service message.')
        data.extend(part)
    return json.loads(data.split(b'\n', 1)[0])


def contact(endpoint, message):
    with socket.create_connection(('127.0.0.1', endpoint['port']), timeout=2) as connection:
        connection.settimeout(120)
        message = dict(message, token=endpoint['token'])
        connection.sendall(json.dumps(message).encode() + b'\n')
        return receive(connection)['status']


def serve(endpoint_path, version):
    global _SNAPSHOT_ROOT
    # The endpoint directory and token are private to this OS user. Only loopback is accepted.
    endpoint_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    _SNAPSHOT_ROOT = endpoint_path.with_suffix(f'.sources-{os.getpid()}')
    _SNAPSHOT_ROOT.mkdir(exist_ok=True, mode=0o700)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(8)
    listener.settimeout(600)
    endpoint = dict(port=listener.getsockname()[1], token=secrets.token_hex(32), version=version)
    temporary = endpoint_path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(endpoint, stream)
    temporary.replace(endpoint_path)
    try:
        while True:
            try:
                connection, _ = listener.accept()
            except socket.timeout:
                break
            with connection:
                connection.settimeout(5)
                try:
                    request = receive(connection)
                    if request.get('token') != endpoint['token']:
                        continue
                    if request.get('stop'):
                        connection.sendall(b'{"status":0}\n')
                        break
                    status = write_response(Path(request['project']), Path(request['folder']))
                    connection.sendall(json.dumps(dict(status=status)).encode() + b'\n')
                except (OSError, RuntimeError, ValueError, KeyError):
                    continue
    finally:
        stop_worker()
        listener.close()
        # A newer daemon may already have published its endpoint.
        if endpoint_path.exists() and json.loads(endpoint_path.read_text()).get('token') == endpoint['token']:
            endpoint_path.unlink()
        shutil.rmtree(_SNAPSHOT_ROOT, ignore_errors=True)


def dispatch(project, folder):
    cache = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'tallow/beef-language-service/sessions'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    identity = hashlib.sha256((str(ROOT) + str(project)).encode()).hexdigest()[:24]
    endpoint_path = cache / (identity + '.json')
    worker = ROOT / ('tools/beef-language-service' if (ROOT / 'tools/beef-language-service').exists() else
                     'build/tools/beef-language-service/' + ('windows' if os.name == 'nt' else 'linux')) / (
                     'beef-language-service.exe' if os.name == 'nt' else 'beef-language-service')
    version_paths = [Path(__file__), worker, ROOT / 'tools/BeefLanguageService/main.cpp', ROOT / 'tools/BeefLanguageService/api.inc']
    version = ':'.join(str(path.stat().st_mtime_ns) for path in version_paths if path.exists())
    lock = endpoint_path.with_suffix('.starting')
    for attempt in range(120):
        if endpoint_path.exists():
            try:
                endpoint = json.loads(endpoint_path.read_text())
                if endpoint['version'] == version:
                    return contact(endpoint, dict(project=str(project), folder=str(folder)))
                contact(endpoint, dict(stop=True))
            except (OSError, RuntimeError, ValueError, KeyError):
                pass
        try:
            fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            if time.time() - lock.stat().st_mtime > 30:
                lock.unlink(missing_ok=True)
            time.sleep(0.05)
            continue
        os.close(fd)
        try:
            with open(cache / (identity + '.log'), 'ab') as log:
                subprocess.Popen([sys.executable, str(Path(__file__)), '--serve', str(endpoint_path), '--version', version],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=os.name != 'nt')
            for _ in range(100):
                if endpoint_path.exists():
                    endpoint = json.loads(endpoint_path.read_text())
                    if endpoint['version'] == version:
                        return contact(endpoint, dict(project=str(project), folder=str(folder)))
                time.sleep(0.03)
            raise RuntimeError('Beef language-service startup timed out.')
        finally:
            lock.unlink(missing_ok=True)
    raise RuntimeError('Beef language service is busy starting.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path)
    parser.add_argument('--request', type=Path)
    parser.add_argument('--serve', type=Path, help=argparse.SUPPRESS)
    parser.add_argument('--version', help=argparse.SUPPRESS)
    parser.add_argument('--once', action='store_true', help='Run without the persistent workspace cache (validation).')
    args = parser.parse_args()
    if args.serve:
        serve(args.serve, args.version)
        return 0
    if not args.project or not args.request:
        parser.error('--project and --request are required.')
    project, folder = args.project.resolve(), args.request.resolve()
    if args.once:
        return write_response(project, folder)
    try:
        return dispatch(project, folder)
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        (folder / 'response.tsv').write_text('error\t' + clean(error) + '\n', newline='\n')
        return 1


if __name__ == '__main__':
    sys.exit(main())
