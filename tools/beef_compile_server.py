#!/usr/bin/env python3
"""The Beef compiler kept loaded between builds, as the Beef IDE keeps it (Linux and Windows).

BeefBuild starts cold each time: it parses and checks every source of the engine, the editor and the game before it
knows what changed (about 2 s for the engine alone). tools/BeefCompileServer is BeefBuild's own code with a loop
around it: it stays running, and each build after the first recompiles only what changed, in well under a second.

Linux: it is built once from the Beef install's own sources (BeefBuild and the IDE, which a Linux install of Beef is
built from) into ~/.cache/tallow/beef-compile-server, and started per workspace by build().

Windows (build_windows(); natively, or under Wine when building for Windows from Linux): a Windows install of Beef
has the compiler only as IDEHelper64.dll, and the server's own code must be the IDE and BeefBuild sources that DLL
was built with. They are found, in order: beside the install when Beef was built from source; in a folder
`compile-server-src` beside its bin folder; in a git clone of Beef named by TALLOW_BEEF_SOURCE; or else in a
partial clone fetched from GitHub once (fetch_beef(), about 30 MB; TALLOW_BEEF_FETCH=0 turns that off). In a clone
the commit is the newest one before the DLL was built whose corlib and Beefy2D sources are the install's
(windows_sources()). The server is built into the cache and put beside BeefBuild.exe, which it
needs (its configuration, linker and runtime are found beside it).

Whenever it cannot be used (no sources, still being built, it crashed) the build functions return None and the
caller runs BeefBuild as before. TALLOW_COMPILE_SERVER=0 turns it off.

    beef_compile_server.py --build                          build the Linux server now
    beef_compile_server.py --build-windows <Beef bin> [--wine]   build the Windows server now
    beef_compile_server.py --windows-sources <Beef bin> <Beef git clone> <out>
                                                            copy the matching IDE and BeefBuild sources to <out>
"""
import argparse
try:
    import fcntl
except ImportError:  # Windows
    fcntl = None
    import msvcrt
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import time

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'tools/BeefCompileServer/Serve.bf'
NAME = 'BeefCompileServer'


def enabled():
    return (sys.platform.startswith('linux') or os.name == 'nt') and os.environ.get('TALLOW_COMPILE_SERVER', '1') != '0'


def cache_base():
    if os.name == 'nt':
        return Path(os.environ.get('LOCALAPPDATA', Path.home() / 'AppData/Local'))
    return Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache'))


def lock(file, wait=True):
    """Locks an open file for this process (raises OSError when wait is False and another process has it)."""
    if fcntl is not None:
        fcntl.flock(file, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        return
    while True:
        try:
            msvcrt.locking(file.fileno(), msvcrt.LK_NBLCK, 1)
            return
        except OSError:
            if not wait:
                raise
            time.sleep(0.1)


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
    return cache_base() / 'tallow/beef-compile-server' / identity.hexdigest()[:16]


def executable():
    """The built server, or None when it is not built (yet)."""
    if not enabled() or os.name == 'nt':
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
    with open(folder / '.lock', 'w') as held:
        lock(held)
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
        with open(folder / '.lock', 'w') as held:
            lock(held, wait=False)
    except OSError:
        return
    subprocess.Popen([sys.executable, str(Path(__file__)), '--build'], stdin=subprocess.DEVNULL,
                     stdout=open(folder / 'build.log', 'w'), stderr=subprocess.STDOUT, start_new_session=True)


def windows_processes():
    """Every running Windows process: {pid: (parent pid, program file name)}."""
    import ctypes
    from ctypes import wintypes

    class Entry(ctypes.Structure):  # PROCESSENTRY32W
        _fields_ = [('size', wintypes.DWORD), ('usage', wintypes.DWORD), ('pid', wintypes.DWORD),
                    ('heap', ctypes.c_size_t), ('module', wintypes.DWORD), ('threads', wintypes.DWORD),
                    ('parent', wintypes.DWORD), ('priority', ctypes.c_long), ('flags', wintypes.DWORD),
                    ('name', ctypes.c_wchar * 260)]
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)  # TH32CS_SNAPPROCESS
    processes = {}
    if snapshot in (None, wintypes.HANDLE(-1).value):
        return processes
    try:
        entry = Entry()
        entry.size = ctypes.sizeof(Entry)
        more = kernel.Process32FirstW(snapshot, ctypes.byref(entry))
        while more:
            processes[entry.pid] = (entry.parent, entry.name.lower())
            more = kernel.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel.CloseHandle(snapshot)
    return processes


def editor_pid():
    """The program that started this script through a shell (the editor): the server leaves when it does."""
    if os.name == 'nt':
        # The editor runs commands through cmd (Terminal.Run), which leaves as soon as the reload is done.
        processes = windows_processes()
        pid = processes.get(os.getpid(), (0, ''))[0]
        for _ in range(4):
            parent, name = processes.get(pid, (0, ''))
            if name not in ('cmd.exe', 'conhost.exe', 'py.exe', 'python.exe', 'python3.exe', 'powershell.exe', 'pwsh.exe'):
                return pid
            pid = parent
        return pid
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


def windows_process_image(pid):
    """The executable a running Windows process was started from, or None if it is not running."""
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.restype = wintypes.HANDLE
    handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return None
    try:
        code = wintypes.DWORD()
        if not kernel.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value != 259:  # STILL_ACTIVE
            return None
        size = wintypes.DWORD(1024)
        name = ctypes.create_unicode_buffer(size.value)
        if not kernel.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(size)):
            return None
        return Path(name.value)
    finally:
        kernel.CloseHandle(handle)


def alive(pid, server):
    """Whether process pid is still the server (a process id can be reused)."""
    if pid <= 0:
        return False
    if os.name == 'nt':
        image = windows_process_image(pid)
        return image is not None and image.name.lower() == Path(server).name.lower()
    try:
        if Path(os.readlink(f'/proc/{pid}/exe')) == server:
            return True
        # A Windows server under Wine: the process is Wine's, its command line names the program.
        first = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')[0].decode(errors='replace')
        return first.replace('\\', '/').rsplit('/', 1)[-1].lower() == Path(server).name.lower()
    except OSError:
        return False


def kill(pid):
    try:
        os.kill(pid, 9 if os.name != 'nt' else 15)
    except OSError:
        pass


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
        kill(pid)


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


def serve(server, workspace, args, output, start, wait, environment, prefix=(), translate=str, parent=None, key_extra=''):
    """Builds the workspace through its server (starting one if none is running): the build's exit code, or None
    when the server cannot be used. prefix runs the server (Wine), translate gives paths as the server sees them,
    parent is the process id the server leaves with (0 for none)."""
    workspace = Path(workspace).resolve()
    folder = workspace / '.compile-server'
    folder.mkdir(exist_ok=True)
    log_path = folder / 'server.log'
    owner = editor_pid()
    if parent is None:
        parent = owner
    # A server belongs to the editor that started it (it leaves with it): a restarted editor starts its own.
    key = key_of(server, workspace, [*args, key_extra, f'parent={owner}'])
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
    detach = {'creationflags': 0x00000200 | 0x08000000} if os.name == 'nt' else {'start_new_session': True}  # new group, no window
    with open(log_path, 'wb') as log:
        process = subprocess.Popen([*prefix, str(server), f'-workspace={translate(workspace)}', *args,
                                    f'-serve-dir={translate(folder)}', f'-serve-parent={parent}'],
                                   cwd=workspace, stdin=subprocess.DEVNULL, env=environment, stdout=log,
                                   stderr=subprocess.STDOUT, **detach)
    (folder / 'server.json').write_text(json.dumps({'pid': process.pid, 'server': str(server), 'key': key}))
    if not wait:
        return None
    result = wait_done(folder, 'start', process.pid, server, log_path, 0, output)
    if result is None:
        print('Compile server stopped while starting; building with BeefBuild.', file=output, flush=True)
        stop(folder)
    return result


def build(workspace, args, output=sys.stdout, start=True, wait=True, skip_archive=False):
    """Builds a Linux workspace through its server (starting one if none is running). BeefBuild's exit code, or
    None when the server cannot be used and the caller should run BeefBuild itself. wait=False only makes sure a
    server is running (and building) for the next build; skip_archive leaves out the archive of a dynamic library."""
    server = executable()
    if server is None:
        if enabled() and start and os.name != 'nt':
            build_in_background()
        return None
    environment = os.environ.copy()
    if skip_archive:
        folder = Path(workspace).resolve() / '.compile-server'
        folder.mkdir(exist_ok=True)
        environment['PATH'] = str(tool_shims(folder)) + os.pathsep + environment.get('PATH', '')
    return serve(server, workspace, args, output, start, wait, environment, key_extra=f'skip_archive={skip_archive}')


class WindowsBeef:
    """A Windows install of Beef (its bin folder), run natively or, from Linux, under Wine (wine is then Wine's
    environment: WINEPREFIX and so on)."""

    def __init__(self, bin_folder, wine=None):
        self.bin = Path(bin_folder)
        self.wine = wine

    def path(self, path):
        """A path as the Windows programs see it."""
        return 'Z:' + str(path).replace('/', '\\') if self.wine is not None else str(path)

    def prefix(self):
        return ['wine'] if self.wine is not None else []

    def environment(self):
        return dict(self.wine) if self.wine is not None else os.environ.copy()

    def run(self, program, *args, log=None):
        return subprocess.run([*self.prefix(), str(program), *args], env=self.environment(), stdin=subprocess.DEVNULL,
                              stdout=log or subprocess.DEVNULL, stderr=subprocess.STDOUT).returncode

    def identity(self):
        """Changes with the installed compiler and with Serve.bf."""
        digest = hashlib.sha256(SOURCE.read_bytes())
        for name in ('IDEHelper64.dll', 'BeefySysLib64.dll', 'BeefBuild.exe'):
            stat = (self.bin / name).stat()
            digest.update(f'{name}:{stat.st_size}:{stat.st_mtime_ns}'.encode())
        return digest.hexdigest()[:16]

    def server(self):
        return self.bin / f'{NAME}-{self.identity()}.exe'


def pe_exports(path):
    """The names a Windows DLL exports."""
    data = Path(path).read_bytes()
    header = struct.unpack_from('<I', data, 0x3C)[0]
    sections = struct.unpack_from('<H', data, header + 6)[0]
    optional_size = struct.unpack_from('<H', data, header + 20)[0]
    optional = header + 24
    export_rva = struct.unpack_from('<I', data, optional + (112 if struct.unpack_from('<H', data, optional)[0] == 0x20B else 96))[0]
    table = optional + optional_size
    def offset(rva):
        for i in range(sections):
            size, address, _, pointer = struct.unpack_from('<IIII', data, table + i * 40 + 8)
            if address <= rva < address + max(size, 1):
                return rva - address + pointer
        raise ValueError(f'{path}: address {rva:#x} is in no section')
    directory = offset(export_rva)
    count = struct.unpack_from('<I', data, directory + 24)[0]  # NumberOfNames
    names = offset(struct.unpack_from('<I', data, directory + 32)[0])  # AddressOfNames
    result = []
    for i in range(count):
        start = offset(struct.unpack_from('<I', data, names + i * 4)[0])
        result.append(data[start:data.index(b'\0', start)].decode())
    return result


def pe_time(path):
    """When a Windows executable says it was linked (seconds since 1970)."""
    data = Path(path).read_bytes()[:4096]
    return struct.unpack_from('<I', data, struct.unpack_from('<I', data, 0x3C)[0] + 8)[0]


def git_blob_id(data):
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def git_program(beef):
    found = shutil.which('git')
    if found:
        return found
    bundled = beef.bin / 'Git/cmd/git.exe'  # Beef's Windows release brings its own
    return str(bundled) if os.name == 'nt' and bundled.is_file() else None


def fetch_beef(beef):
    """A partial clone of Beef (its history and folder listings, no file contents until they are read) from a few
    weeks before this compiler was built: about 30 MB, seconds."""
    git = git_program(beef)
    if git is None:
        raise RuntimeError('git was not found; the compile server needs it once to fetch the Beef sources.')
    clone = cache_base() / 'tallow/beef-compile-server/beef.git'
    since = time.strftime('%Y-%m-%d', time.gmtime(pe_time(beef.bin / 'IDEHelper64.dll') - 45 * 86400))
    if (clone / 'HEAD').exists():
        subprocess.run([git, '-C', str(clone), 'fetch', '-q', '--filter=blob:none', f'--shallow-since={since}', 'origin', 'master:master'],
                       check=True, stdin=subprocess.DEVNULL)
    else:
        shutil.rmtree(clone, ignore_errors=True)
        subprocess.run([git, 'clone', '-q', '--bare', '--filter=blob:none', '--single-branch', '--branch', 'master',
                        f'--shallow-since={since}', 'https://github.com/beefytech/Beef.git', str(clone)], check=True, stdin=subprocess.DEVNULL)
    return clone


def windows_sources(beef, checkout, out):
    """Finds the commit of the Beef git clone `checkout` that the Windows install was built from, and copies its IDE
    and BeefBuild sources to out/IDE/src and out/BeefBuild/src. The commit is the newest one on the main line,
    before the compiler was built, whose corlib and Beefy2D sources are the install's. Returns the commit."""
    libs = beef.bin.parent / 'BeefLibs'
    wanted = {}
    for library in ('corlib', 'Beefy2D'):
        for file in (libs / library / 'src').rglob('*'):
            if file.is_file():
                data = file.read_bytes()
                wanted[f'BeefLibs/{library}/src/' + file.relative_to(libs / library / 'src').as_posix()] = {git_blob_id(data), git_blob_id(data.replace(b'\r\n', b'\n'))}
    git = [git_program(beef) or 'git', '-C', str(checkout)]
    branch = 'HEAD'
    for name in ('origin/master', 'master'):
        if subprocess.run([*git, 'rev-parse', '-q', '--verify', name], capture_output=True).returncode == 0:
            branch = name
            break
    built = pe_time(beef.bin / 'IDEHelper64.dll')
    commits = subprocess.run([*git, 'rev-list', '--first-parent', '--max-count=500', f'--before={built + 600}', branch],
                             capture_output=True, text=True, check=True).stdout.split()
    for commit in commits:
        listing = subprocess.run([*git, 'ls-tree', '-r', commit, 'BeefLibs/corlib/src', 'BeefLibs/Beefy2D/src'],
                                 capture_output=True, text=True, check=True).stdout
        found = {}
        for line in listing.splitlines():
            info, path = line.split('\t', 1)
            found[path] = info.split()[2]
        if found.keys() == wanted.keys() and all(found[path] in ids for path, ids in wanted.items()):
            out = Path(out)
            shutil.rmtree(out, ignore_errors=True)
            out.mkdir(parents=True)
            archive = subprocess.run([*git, 'archive', '--format=tar', commit, 'IDE/src', 'BeefBuild/src'], capture_output=True, check=True).stdout
            with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
                tar.extractall(out, filter='data')
            (out / 'commit.txt').write_text(commit + '\n')
            return commit
    raise RuntimeError(f'No commit of {checkout} has the corlib and Beefy2D sources of {libs}; fetch the Beef clone, or it is too old.')


def windows_source_folder(beef, prepare=True):
    """A folder with IDE/src and BeefBuild/src matching the install, or None. prepare=False only says whether there
    will be one, without looking for the commit in a git clone yet."""
    for candidate in (beef.bin.parent.parent, beef.bin.parent / 'compile-server-src'):
        if (candidate / 'IDE/src/IDEApp.bf').is_file() and (candidate / 'BeefBuild/src/BuildApp.bf').is_file():
            return candidate
    out = cache_base() / 'tallow/beef-compile-server' / f'src-{beef.identity()}'
    if (out / 'commit.txt').is_file():
        return out
    checkout = os.environ.get('TALLOW_BEEF_SOURCE')
    if checkout and (Path(checkout) / '.git').exists():
        checkout = Path(checkout)
    elif git_program(beef) is not None and os.environ.get('TALLOW_BEEF_FETCH', '1') != '0':
        checkout = None  # fetched from GitHub when the server is built
    else:
        return None
    if prepare:
        windows_sources(beef, checkout or fetch_beef(beef), out)
    return out


def build_windows_server(beef, log=sys.stdout):
    """Builds the Windows server (a minute or two, once per Beef install and Serve.bf) and puts it beside
    BeefBuild.exe."""
    server = beef.server()
    if server.is_file():
        return server
    sources = windows_source_folder(beef)
    if sources is None:
        raise RuntimeError('No IDE/BeefBuild sources for this Windows Beef; set TALLOW_BEEF_SOURCE to a git clone of Beef.')
    folder = cache_base() / 'tallow/beef-compile-server' / f'win-{beef.identity()}'
    folder.mkdir(parents=True, exist_ok=True)
    with open(folder / '.lock', 'w') as held:
        lock(held)
        if server.is_file():
            return server
        project = folder / 'project'
        shutil.rmtree(project, ignore_errors=True)
        (project / 'src').mkdir(parents=True)
        shutil.copy2(SOURCE, project / 'src/Serve.bf')
        # Copies, not links: Windows makes links only for administrators.
        shutil.copytree(sources / 'IDE/src', project / 'ide')
        shutil.copytree(sources / 'BeefBuild/src', project / 'beefbuild')
        # The import library for the compiler's DLL, which the install does not have.
        (project / 'IDEHelper64.def').write_text('LIBRARY IDEHelper64.dll\nEXPORTS\n' + '\n'.join(pe_exports(beef.bin / 'IDEHelper64.dll')) + '\n')
        if beef.run(beef.bin / 'llvm/bin/lld-link.exe', '/lib', '/machine:x64', f'/def:{beef.path(project / "IDEHelper64.def")}',
                    f'/out:{beef.path(project / "IDEHelper64.lib")}', log=log):
            raise RuntimeError('Making the import library of IDEHelper64.dll failed.')
        (project / 'BeefSpace.toml').write_text(f'FileVersion = 1\nProjects = {{{NAME} = {{Path = "."}}, corlib = "*", Beefy2D = "*"}}\n'
                                                f'Unlocked = ["corlib"]\n\n[Workspace]\nStartupProject = "{NAME}"\n\n'
                                                '[Configs.Release.Win64]\nToolset = "LLVM"\n')
        (project / 'BeefProj.toml').write_text(f"""FileVersion = 1
Dependencies = {{Beefy2D = "*", corlib = "*"}}

[Project]
Name = "{NAME}"
StartupObject = "BeefBuild.CompileServerProgram"

[Configs.Release.Win64]
TargetDirectory = "$(WorkspaceDir)/out"
OtherLinkFlags = "$(LinkFlags) Comdlg32.lib kernel32.lib user32.lib advapi32.lib shell32.lib \\"$(WorkspaceDir)/IDEHelper64.lib\\""
CLibType = "Dynamic"
PreprocessorMacros = ["RELEASE", "CLI"]

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
""")
        code = beef.run(beef.bin / 'BeefBuild.exe', f'-workspace={beef.path(project)}', '-config=Release', '-platform=Win64',
                        '-verbosity=minimal', log=log)
        built = project / 'out' / f'{NAME}.exe'
        if code or not built.is_file():
            (folder / 'failed').write_text(f'exit {code}\n')
            raise RuntimeError(f'Building the Windows compile server failed (exit {code}).')
        (folder / 'failed').unlink(missing_ok=True)
        temporary = server.with_suffix('.tmp')
        shutil.copy2(built, temporary)
        temporary.replace(server)
        # Servers built for an earlier Serve.bf or Beef; one still running stays until it has gone.
        for old in beef.bin.glob(f'{NAME}-*.exe'):
            if old != server:
                try:
                    old.unlink()
                except OSError:
                    pass
        shutil.rmtree(project, ignore_errors=True)
        return server


def build_windows_in_background(beef):
    folder = cache_base() / 'tallow/beef-compile-server' / f'win-{beef.identity()}'
    folder.mkdir(parents=True, exist_ok=True)
    if (folder / 'failed').exists() or windows_source_folder(beef, prepare=False) is None:
        return
    try:
        with open(folder / '.lock', 'w') as held:
            lock(held, wait=False)
    except OSError:
        return
    command = [sys.executable, str(Path(__file__)), '--build-windows', str(beef.bin)] + (['--wine'] if beef.wine is not None else [])
    detach = {'creationflags': 0x00000200 | 0x08000000} if os.name == 'nt' else {'start_new_session': True}
    with open(folder / 'build.log', 'w') as log:
        subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                         env=beef.environment() if beef.wine is not None else None, **detach)


def build_windows(beef, workspace, args, output=sys.stdout, start=True, wait=True):
    """build() for a Windows workspace, with the Windows compiler `beef` (a WindowsBeef)."""
    if not enabled():
        return None
    server = beef.server()
    if not server.is_file():
        if start:
            build_windows_in_background(beef)
        return None
    # Under Wine the editor's process is not one Wine knows; the server then leaves after an hour without requests,
    # or when the next editor starts its own.
    return serve(server, workspace, args, output, start, wait, beef.environment(), prefix=beef.prefix(),
                 translate=beef.path, parent=0 if beef.wine is not None else None)

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--build', action='store_true', help='build the Linux server')
    parser.add_argument('--build-windows', type=Path, metavar='BIN', help="build the Windows server for the Beef install's bin folder")
    parser.add_argument('--wine', action='store_true', help='run the Windows programs under Wine (WINEPREFIX from the environment)')
    parser.add_argument('--windows-sources', nargs=3, type=Path, metavar=('BIN', 'CLONE', 'OUT'),
                        help='copy the IDE and BeefBuild sources matching the install from a Beef git clone')
    args = parser.parse_args()
    wine = os.environ.copy() if args.wine else None
    if args.build:
        print(build_server())
    if args.build_windows:
        print(build_windows_server(WindowsBeef(args.build_windows, wine)))
    if args.windows_sources:
        print(windows_sources(WindowsBeef(args.windows_sources[0], wine), *args.windows_sources[1:]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
