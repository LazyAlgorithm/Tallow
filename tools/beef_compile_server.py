#!/usr/bin/env python3
"""The Beef compiler kept loaded between builds, as the Beef IDE keeps it (Linux).

BeefBuild starts cold each time: it parses and checks every source of the engine, the editor and the game before it
knows what changed (about 2 s for the engine alone). tools/BeefCompileServer is BeefBuild's own code with a loop
around it: it stays running, and each build after the first recompiles only what changed, in well under a second.

It is built once from the Beef install's own sources (BeefBuild and the IDE, which a Linux install of Beef is built
from) into ~/.cache/tallow/beef-compile-server, and started per workspace by build(). Whenever it cannot be used
(another platform, no sources, still being built, it crashed) build() returns None and the caller runs BeefBuild
as before. TALLOW_COMPILE_SERVER=0 turns it off.

    beef_compile_server.py --build      build the server now (otherwise the first reload starts it building)
"""
import argparse
try:
    import fcntl
except ImportError:  # Windows: the server is Linux only.
    fcntl = None
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools/BeefCompileServer/Serve.bf'
NAME = 'BeefCompileServer'


def enabled():
    return sys.platform.startswith('linux') and os.environ.get('TALLOW_COMPILE_SERVER', '1') != '0'


def beef_folders():
    """The folder BeefBuild is in (IDE/dist) and the Beef source tree around it, or None without the sources."""
    found = shutil.which(os.environ.get('BEEFBUILD', 'BeefBuild'))
    if not found:
        return None
    dist = Path(found).resolve().parent
    root = dist.parent.parent
    needed = [root / 'BeefBuild/src/BuildApp.bf', root / 'IDE/src/IDEApp.bf', root / 'BeefLibs/Beefy2D/BeefProj.toml',
              dist / 'libIDEHelper.a', dist / 'IDEHelper_libs.txt']
    return (dist, root) if all(path.exists() for path in needed) else None


def cache_folder(dist, root):
    """Where the server built from this Beef install and this Serve.bf lives."""
    identity = hashlib.sha256(SOURCE.read_bytes())
    for path in (dist / 'libIDEHelper.a', root / 'BeefBuild/src/BuildApp.bf', root / 'IDE/src/IDEApp.bf'):
        identity.update(f'{path}:{path.stat().st_mtime_ns}'.encode())
    base = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache'))
    return base / 'tallow/beef-compile-server' / identity.hexdigest()[:16]


def executable():
    """The built server, or None when it is not built (yet)."""
    if not enabled():
        return None
    folders = beef_folders()
    if folders is None:
        return None
    path = cache_folder(*folders) / NAME
    return path if path.is_file() else None


def build_server(log=sys.stdout):
    """Builds the server (a minute or two, once per Beef install). Its folder mirrors IDE/dist, since BeefBuild
    finds its configuration, runtime libraries and standard library beside itself."""
    folders = beef_folders()
    if folders is None:
        raise RuntimeError('The Beef install has no BeefBuild/IDE sources; the compile server cannot be built.')
    dist, root = folders
    folder = cache_folder(dist, root)
    folder.mkdir(parents=True, exist_ok=True)
    with open(folder / '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (folder / NAME).is_file():
            return folder / NAME
        for entry in dist.iterdir():
            mirrored = folder / entry.name
            if entry.name.startswith(('BeefBuild', 'BeefServe', 'BeefIDE', NAME)) or entry.name == 'BeefConfig.toml':
                continue
            if not mirrored.exists() and not mirrored.is_symlink():
                mirrored.symlink_to(entry)
        (folder / 'BeefConfig.toml').write_text(f'Version = 1\nUnversionedLibDirs = [{json.dumps(str(root / "BeefLibs"))}]\n')
        project = folder / 'project'
        (project / 'src').mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE, project / 'src/Serve.bf')
        # Beef includes extra source folders by paths inside the project.
        for link, target in (('ide', root / 'IDE/src'), ('beefbuild', root / 'BeefBuild/src')):
            if not (project / link).is_symlink():
                (project / link).symlink_to(target, target_is_directory=True)
        projects = {'Beefy2D': root / 'BeefLibs/Beefy2D', 'IDEHelper': root / 'IDEHelper', 'Debugger64': root / 'Debugger64',
                    'BeefySysLib': root / 'BeefySysLib'}
        entries = ', '.join([f'{NAME} = {{Path = "."}}', 'corlib = "*"'] + [f'{key} = {{Path = {json.dumps(str(path))}}}' for key, path in projects.items()])
        (project / 'BeefSpace.toml').write_text(f'FileVersion = 1\nProjects = {{{entries}}}\nUnlocked = ["corlib"]\n\n[Workspace]\nStartupProject = "{NAME}"\n')
        libs = ' '.join(str(dist / name) for name in ('libIDEHelper.a', 'libBeefySysLib.a', 'libhunspell.so'))
        (project / 'BeefProj.toml').write_text(f'''FileVersion = 1
Dependencies = {{Beefy2D = "*", corlib = "*"}}

[Project]
Name = "{NAME}"
StartupObject = "BeefBuild.CompileServerProgram"

[Configs.Release.Linux64]
TargetDirectory = {json.dumps(str(folder))}
OtherLinkFlags = "$(LinkFlags) {libs} $(Var IDEHelperLibs) -Wl,-rpath -Wl,$ORIGIN -Wl,-rpath -Wl,{dist}"
CLibType = "Dynamic"
PreBuildCmds = ["ReadFile(\\"{dist / 'IDEHelper_libs.txt'}\\", \\"IDEHelperLibs\\")"]
PreprocessorMacros = ["CLI"]

[[ProjectFolder.Items]]
Type = "Folder"
Path = "ide"
Name = "ide"
AutoInclude = true

[[ProjectFolder.Items]]
Type = "Folder"
Path = "beefbuild"
Name = "beefbuild"
AutoInclude = true
''')
        completed = subprocess.run([str(dist / 'BeefBuild'), f'-workspace={project}', '-config=Release', '-platform=Linux64',
                                    '-verbosity=minimal'], stdout=log, stderr=subprocess.STDOUT)
        if completed.returncode or not (folder / NAME).is_file():
            # Not tried again in the background for this Beef install; --build tries again.
            (folder / 'failed').write_text(f'exit {completed.returncode}\n')
            raise RuntimeError(f'Building the compile server failed (exit {completed.returncode}); see {folder}/build.log.')
        (folder / 'failed').unlink(missing_ok=True)
        remove_other_builds(folder)
        shutil.rmtree(project / 'build', ignore_errors=True)
        return folder / NAME


def remove_other_builds(keep):
    """Deletes servers built for an earlier Beef install or Serve.bf (100 MB each) that are not running."""
    running = set()
    for process in Path('/proc').iterdir():
        try:
            running.add(Path(os.readlink(process / 'exe')).parent)
        except OSError:
            pass
    for folder in keep.parent.iterdir():
        if folder != keep and folder.is_dir() and folder not in running:
            shutil.rmtree(folder, ignore_errors=True)


def build_in_background():
    """Starts building the server in a process of its own, unless it is being built already."""
    folders = beef_folders()
    if folders is None:
        return
    folder = cache_folder(*folders)
    folder.mkdir(parents=True, exist_ok=True)
    if (folder / 'failed').exists():
        return
    try:
        lock = open(folder / '.lock', 'w')
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        lock.close()
    except OSError:
        return
    subprocess.Popen([sys.executable, str(Path(__file__)), '--build'], stdin=subprocess.DEVNULL,
                     stdout=open(folder / 'build.log', 'w'), stderr=subprocess.STDOUT, start_new_session=True)


def editor_pid():
    """The program that started this script through a shell (the editor): the server leaves when it does."""
    pid = os.getppid()
    for _ in range(4):
        try:
            stat = Path(f'/proc/{pid}/stat').read_text()
        except OSError:
            return 0
        command = stat[stat.index('(') + 1:stat.rindex(')')]
        if command not in ('sh', 'bash', 'dash', 'zsh', 'timeout', 'env'):
            return pid
        pid = int(stat[stat.rindex(')') + 2:].split()[1])
    return pid


def alive(pid, server):
    try:
        return Path(os.readlink(f'/proc/{pid}/exe')) == server
    except OSError:
        return False


def key_of(server, workspace, args):
    """What a running server must match to be reused: itself, its arguments and the workspace's configuration."""
    identity = hashlib.sha256(f'{server}\n{args}\n'.encode())
    for name in ('BeefSpace.toml', 'BeefProj.toml'):
        path = workspace / name
        identity.update(path.read_bytes() if path.exists() else b'')
    return identity.hexdigest()


def stop(folder, wait=2.0):
    """Asks a server to leave, then makes it."""
    state_path = folder / 'server.json'
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        return
    state_path.unlink(missing_ok=True)
    pid = state.get('pid', 0)
    server = Path(state.get('server', ''))
    if not alive(pid, server):
        return
    request = folder / 'request'
    request.with_suffix('.tmp').write_text('quit\n')
    request.with_suffix('.tmp').replace(request)
    deadline = time.monotonic() + wait
    while alive(pid, server) and time.monotonic() < deadline:
        time.sleep(0.01)
    if alive(pid, server):
        try:
            os.kill(pid, 9)
        except OSError:
            pass


def wait_done(folder, request_id, pid, server, log_path, offset, output):
    """Waits for the server to finish the request; its exit code, or None if the server went away."""
    done = folder / 'done'
    checks = 0
    while True:
        try:
            fields = done.read_text().split()
        except OSError:
            fields = []
        if len(fields) >= 2 and fields[0] == request_id:
            with open(log_path, 'rb') as log:
                log.seek(offset)
                text = log.read().decode(errors='replace')
            output.write(text)
            output.flush()
            return 0 if fields[1] == 'ok' else 1
        checks += 1
        if checks % 50 == 0 and not alive(pid, server):
            return None
        time.sleep(0.002)


def tool_shims(folder):
    """A folder of do-nothing archivers. A dynamic library on Linux is "linked" by archiving every object (5,000
    objects, 78 MB, 0.3-2 s); script reload links its own module from the objects and never reads that archive."""
    shims = folder / 'bin'
    shims.mkdir(exist_ok=True)
    for name in ('ar', 'llvm-ar'):
        shim = shims / name
        if not shim.exists():
            shim.write_text('#!/bin/sh\nexit 0\n')
            shim.chmod(0o755)
    return shims


def build(workspace, args, output=sys.stdout, start=True, wait=True, skip_archive=False):
    """Builds the workspace through its server (starting one if none is running). BeefBuild's exit code, or None
    when the server cannot be used and the caller should run BeefBuild itself. wait=False only makes sure a server
    is running (and building) for the next build; skip_archive leaves out the archive of a dynamic library."""
    server = executable()
    if server is None:
        if enabled() and start:
            build_in_background()
        return None
    workspace = Path(workspace).resolve()
    folder = workspace / '.compile-server'
    folder.mkdir(exist_ok=True)
    log_path = folder / 'server.log'
    parent = editor_pid()
    # A server belongs to the editor that started it (it leaves with it): a restarted editor starts its own.
    key = key_of(server, workspace, [*args, f'skip_archive={skip_archive}', f'parent={parent}'])
    try:
        state = json.loads((folder / 'server.json').read_text())
    except (OSError, ValueError):
        state = {}
    pid = state.get('pid', 0)
    if state.get('key') == key and alive(pid, server):
        if not wait:
            return None
        request_id = f'{os.getpid()}-{time.time_ns()}'
        offset = log_path.stat().st_size if log_path.exists() else 0
        temporary = folder / 'request.tmp'
        temporary.write_text(request_id + '\n')
        temporary.replace(folder / 'request')
        result = wait_done(folder, request_id, pid, server, log_path, offset, output)
        if result is not None:
            return result
        print('Compile server stopped; building with BeefBuild.', file=output, flush=True)
        stop(folder)
        return None
    if not start:
        return None
    stop(folder)
    for name in ('done', 'request'):
        (folder / name).unlink(missing_ok=True)
    if log_path.exists():
        log_path.replace(folder / 'server.previous.log')
    environment = os.environ.copy()
    if skip_archive:
        environment['PATH'] = str(tool_shims(folder)) + os.pathsep + environment.get('PATH', '')
    process = subprocess.Popen([str(server), f'-workspace={workspace}', *args, f'-serve-dir={folder}',
                                f'-serve-parent={parent}'], cwd=workspace, stdin=subprocess.DEVNULL, env=environment,
                               stdout=open(log_path, 'wb'), stderr=subprocess.STDOUT, start_new_session=True)
    (folder / 'server.json').write_text(json.dumps({'pid': process.pid, 'server': str(server), 'key': key}))
    if not wait:
        return None
    result = wait_done(folder, 'start', process.pid, server, log_path, 0, output)
    if result is None:
        print('Compile server stopped while starting; building with BeefBuild.', file=output, flush=True)
        stop(folder)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--build', action='store_true', help='build the server')
    args = parser.parse_args()
    if args.build:
        print(build_server())
    return 0


if __name__ == '__main__':
    sys.exit(main())
