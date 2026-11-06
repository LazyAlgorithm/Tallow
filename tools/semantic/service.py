#!/usr/bin/env python3
"""Persistent compiler-backed analysis for the editor. stdin/stdout carry JSON lines."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import queue
import shlex
import shutil
import subprocess
import sys
import threading
import time
import tomllib

PROTOCOL = 1
REVISION = 'b62833e327d6b08f3566b31102c57646de6916b0'
KINDS = {'diagnostics': 1, 'completion': 3, 'definition': 5, 'hover': 3}
ENTRIES = {'class', 'interface', 'valuetype', 'namespace', 'generic', 'method', 'property',
           'field', 'value', 'object', 'pointer', 'this', 'token', 'label'}


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def hex_text(value):
    return value.encode('utf-8').hex()


def decode(value):
    return bytes.fromhex(value).decode('utf-8')


class Worker:
    def __init__(self, executable, timeout=30):
        self.timeout = timeout
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=sys.stderr, text=True, encoding='utf-8', bufsize=1)
        self.lines = queue.Queue()
        def read():
            try:
                for line in self.process.stdout:
                    self.lines.put(line.rstrip('\n'))
            finally:
                self.lines.put(None)
        threading.Thread(target=read, daemon=True).start()
        if self.receive() != f'TALLOW_HELLO {PROTOCOL} {REVISION}':
            self.close()
            raise RuntimeError('Incompatible Beef analysis helper')

    def send(self, line):
        self.process.stdin.write(line + '\n')
        self.process.stdin.flush()

    def receive(self):
        try:
            line = self.lines.get(timeout=self.timeout)
        except queue.Empty:
            self.close()
            raise RuntimeError('Beef analysis timed out; helper stopped')
        if line is None:
            self.process.wait(timeout=1)
            raise RuntimeError(f'Beef analysis helper exited ({self.process.returncode})')
        return line

    def until(self, prefix):
        lines = []
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            line = self.receive()
            lines.append(shlex.split(line))
            if line.startswith(prefix):
                return lines
        self.close()
        raise RuntimeError('Beef analysis exceeded its deadline')

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait()
        if self.process.stdin:
            self.process.stdin.close()
        if self.process.stdout:
            self.process.stdout.close()


def project_graph(workspace, beef_root, config, platform):
    """Read generated build files; reject unsupported layouts instead of inventing a build context."""
    if platform not in ('Linux64', 'Win64'):
        raise ValueError('This helper build supports Linux64 and Win64')
    space = tomllib.loads((workspace / 'BeefSpace.toml').read_text())
    if space.get('ConfigSelections'):
        raise ValueError('Per-project configuration selections are not supported by this helper yet')
    paths = {name: (workspace / item['Path']).resolve() for name, item in space['Projects'].items()}
    projects = {}
    pending = list(paths)
    while pending:
        name = pending.pop()
        if name in projects:
            continue
        path = paths[name]
        data = tomllib.loads((path / 'BeefProj.toml').read_text())
        if 'ProjectFolder' in data or 'Sources' in data:
            raise ValueError(f'Custom source layout in {name} is not yet supported')
        dependencies = list(data.get('Dependencies', {}))
        for dep in dependencies:
            if dep not in paths:
                candidate = beef_root / 'BeefLibs' / dep
                if not (candidate / 'BeefProj.toml').is_file():
                    raise ValueError(f'Cannot resolve the build dependency {dep} for {name}')
                paths[dep] = candidate
            pending.append(dep)
        options = data.get('Configs', {}).get(config, {}).get(platform, {})
        workspace_options = space.get('Configs', {}).get(config, {}).get(platform, {})
        defines = ['BF_64_BIT', 'BF_LITTLE_ENDIAN', 'BF_MACHINE_X64']
        defines += ['BF_PLATFORM_WINDOWS'] if platform == 'Win64' else ['BF_PLATFORM_LINUX', 'BF_PLATFORM_POSIX']
        if config == 'Debug':
            defines.append('DEBUG')
        elif config != 'Release':
            raise ValueError(f'Unsupported build configuration {config}')
        defines += workspace_options.get('PreprocessorMacros', []) + options.get('PreprocessorMacros', [])
        settings = data['Project']
        target = {'BeefConsoleApplication': 0, 'BeefGUIApplication': 1, 'BeefLib': 2}.get(settings.get('TargetType', 'BeefLib'))
        if target is None:
            raise ValueError(f'Unsupported target type for {name}')
        files = sorted((path / 'src').rglob('*.bf'))
        if not files:
            raise ValueError(f'No authoritative src tree for {name}')
        projects[name] = dict(path=path, dependencies=dependencies, defines='\n'.join(dict.fromkeys(defines)),
                              startup=settings.get('StartupObject', ''), target=target, files=files)
    return projects


class Session:
    def __init__(self, worker, projects, platform='Linux64'):
        self.worker = worker
        self.sources = {}
        self.worker.send('CONFIG ' + ('x86_64-pc-windows-msvc' if platform == 'Win64' else 'x86_64-unknown-linux-gnu'))
        for name, project in projects.items():
            self.worker.send(f'PROJECT {quote(name)} {quote(project["path"])} {quote(hex_text(project["defines"]))} '
                             f'{quote(project["startup"])} {project["target"]}')
        for name, project in projects.items():
            for dependency in project['dependencies']:
                self.worker.send(f'DEPEND {quote(name)} {quote(dependency)}')
        for name, project in projects.items():
            for path in project['files']:
                path = str(path.resolve())
                text = Path(path).read_text(encoding='utf-8-sig')
                self.sources[path] = dict(project=name, text=text, revision=0, disk_stamp=Path(path).stat().st_mtime_ns)
                self.source(path)
        self.ready()

    def source(self, path):
        source = self.sources[path]
        self.worker.send(f'SOURCE {quote(source["project"])} {quote(path)} {source["revision"]} {quote(hex_text(source["text"]))}')

    def ready(self):
        self.worker.send('READY')
        return self.worker.until('TALLOW_READY ')

    def resolve(self, request):
        started = time.monotonic()
        path = str(Path(request['path']).resolve())
        # Preserve the editor's spelling (including Windows short paths and symlinked workspaces).
        aliases = {os.path.normcase(str(Path(buffer['path']).resolve())): buffer['path']
                   for buffer in request.get('buffers', [])}
        aliases[os.path.normcase(path)] = request['path']
        def editor_path(value):
            return aliases.get(os.path.normcase(str(Path(value).resolve())), value)
        if path not in self.sources:
            raise ValueError('The document is outside the configured project source graph')
        changed = False
        opened = {str(Path(buffer['path']).resolve()) for buffer in request.get('buffers', [])}
        for name, source in self.sources.items():
            if name in opened:
                continue
            stamp = Path(name).stat().st_mtime_ns
            if stamp != source['disk_stamp']:
                source['disk_stamp'] = stamp
                text = Path(name).read_text(encoding='utf-8-sig')
                if text != source['text']:
                    source.update(text=text, revision=source['revision'] + 1)
                    self.source(name)
                    changed = True
        for buffer in request.get('buffers', []):
            name = str(Path(buffer['path']).resolve())
            if name not in self.sources:
                raise ValueError('A source file was added or moved; restart project analysis')
            source = self.sources[name]
            revision = buffer['revision']
            if not isinstance(revision, int) or revision < 0 or revision > 2147483647:
                raise ValueError('Invalid document revision')
            if source['text'] != buffer['text'] or source['revision'] != revision:
                source.update(text=buffer['text'], revision=revision)
                self.source(name)
                changed = True
        kind = request.get('kind', 'completion')
        if kind not in KINDS:
            raise ValueError('Unknown analysis request')
        if changed and kind != 'diagnostics':
            self.ready()
        cursor = request.get('cursor', -1)
        if not isinstance(cursor, int) or not -1 <= cursor <= len(self.sources[path]['text'].encode('utf-8')):
            raise ValueError('Cursor must be a UTF-8 byte offset in the supplied buffer')
        identifier = request['id']
        if not isinstance(identifier, int) or not 0 <= identifier <= 2147483647:
            raise ValueError('Invalid request id')
        documentation = ''
        if kind == 'hover' and cursor >= 0:
            encoded = self.sources[path]['text'].encode('utf-8')
            start = end = cursor
            def identifier_byte(value):
                return value >= 128 or chr(value).isalnum() or value == 95
            while start > 0 and identifier_byte(encoded[start - 1]):
                start -= 1
            while end < len(encoded) and identifier_byte(encoded[end]):
                end += 1
            documentation = encoded[start:end].decode('utf-8')
        self.worker.send(f'RESOLVE {quote(path)} {cursor} {KINDS[kind]} {identifier} {quote(documentation)}')
        rows = self.worker.until('TALLOW_RESULT ')
        result = dict(id=identifier, generation=request.get('generation'), path=request['path'], cursor=cursor, kind=kind,
                      revision=self.sources[path]['revision'], versions={b['path']: b['revision'] for b in request.get('buffers', [])},
                      completions=[], signatures=[], diagnostics=[], definition=None, documentation=[], raw='')
        for row in rows:
            if row[0] == 'TALLOW_DIAG':
                result['diagnostics'].append(dict(warning=row[3] == '1', file=editor_path(decode(row[4])), start=int(row[5]),
                                                  end=int(row[6]), line=int(row[7]), column=int(row[8]), message=decode(row[9])))
            elif row[0] == 'TALLOW_RESULT':
                result['raw'] = decode(row[4])
                result['success'] = row[3] == '1'
        for line in result['raw'].split('\n'):
            parts = line.split('\t')
            if len(parts) >= 2 and parts[0] in ENTRIES:
                display, _, documentation = parts[1].partition('\x03')
                display = display.split('\x02', 1)[0]
                result['completions'].append(display)
                if documentation:
                    result['documentation'].append(documentation.replace('\x01', '').replace('\x04', '\n'))
            elif len(parts) >= 2 and parts[0] == 'invoke':
                result['signatures'].append(parts[1].replace('\x01', ''))
            elif len(parts) >= 4 and parts[0] == 'defLoc':
                result['definition'] = dict(path=editor_path(parts[1]), line=int(parts[2]), column=int(parts[3]))
        result['elapsed_ms'] = (time.monotonic() - started) * 1000
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', type=Path, required=True)
    parser.add_argument('--beef-root', type=Path)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--config', default='Debug')
    parser.add_argument('--platform', default='Win64' if os.name == 'nt' else 'Linux64')
    args = parser.parse_args()
    worker = None
    try:
        if args.beef_root is None:
            compiler = os.environ.get('BEEFBUILD') or shutil.which('BeefBuild') or shutil.which('BeefBuild.sh')
            if not compiler:
                raise ValueError('Cannot locate the project Beef compiler')
            args.beef_root = Path(compiler).resolve().parent.parent if os.name == 'nt' else Path(compiler).resolve().parent.parent.parent
        dist = args.beef_root / ('bin' if os.name == 'nt' else 'IDE/dist')
        os.environ['TALLOW_BEEF_DIST'] = str(dist)
        runtime_paths = [str(dist / 'shared'), str(dist)]
        if os.environ.get('LD_LIBRARY_PATH'):
            runtime_paths.append(os.environ['LD_LIBRARY_PATH'])
        os.environ['LD_LIBRARY_PATH'] = os.pathsep.join(runtime_paths)
        metadata = json.loads(args.helper.with_suffix('.json').read_text())
        compiler_hash = hashlib.sha256((dist / ('IDEHelper64.dll' if os.name == 'nt' else 'libIDEHelper.a')).read_bytes()).hexdigest()
        if metadata['protocol'] != PROTOCOL or metadata['compiler_library_sha256'] != compiler_hash:
            raise ValueError('Analysis helper does not match this compiler; rebuild the helper')
        graph = project_graph(args.project.resolve(), args.beef_root.resolve(), args.config, args.platform)
        worker = Worker(args.helper.resolve())
        session = Session(worker, graph, args.platform)
        print(json.dumps(dict(ready=True, protocol=PROTOCOL)), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            try:
                current_graph = project_graph(args.project.resolve(), args.beef_root.resolve(), args.config, args.platform)
                if current_graph != graph:
                    worker.close()
                    worker = Worker(args.helper.resolve())
                    session = Session(worker, current_graph, args.platform)
                    graph = current_graph
                result = session.resolve(request)
            except (ValueError, KeyError) as error:
                result = dict(id=request.get('id'), generation=request.get('generation'), error=str(error))
            print(json.dumps(result), flush=True)
    except Exception as error:
        print(json.dumps(dict(ready=False, error=str(error))), flush=True)
        return 1
    finally:
        if worker:
            worker.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
