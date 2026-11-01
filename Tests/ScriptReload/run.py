#!/usr/bin/env python3
"""Exercise a real compiler and six reload generations while one host process stays alive."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import sys
import contextlib

import os
import re

root = Path(__file__).resolve().parent
engine = root.parents[1]
builder = engine / 'tools' / 'reload_scripts.py'
# --windows: the same test against a Windows host. On Linux that host and its compiler run under Wine.
windows = '--windows' in sys.argv or os.name == 'nt'
wine = windows and os.name != 'nt'
toolchain = Path(os.environ.get('TALLOW_WIN', Path.home() / '.local/share/tallow-win'))
wine_environment = dict(os.environ, WINEPREFIX=str(toolchain / 'wine'), WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=')
platform = ['--platform', 'windows'] if windows else []


def relocate_project(project):
    """A copied fixture resolves the engine from its original checkout, not from its temporary folder."""
    def place(path):
        return ('Z:' if wine else '') + str(path).replace('\\', '/')
    for name in ('BeefProj.toml', 'BeefSpace.toml'):
        file = project / name
        text = file.read_text().replace('$(WorkspaceDir)/../..', place(engine))
        text = text.replace('../../Engine', place(engine / 'Engine'))
        file.write_text(text)


def compile_host(project):
    if not windows:
        subprocess.run([os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={project}', '-config=Debug', '-verbosity=minimal'], check=True)
        return [str(project / 'build/Debug_Linux64/ReloadTests/ReloadTests'), str(project)], None
    if wine:
        subprocess.run(['wine', str(toolchain / 'beef/bin/BeefBuild.exe'), '-workspace=Z:' + str(project).replace('/', '\\'), '-config=Debug', '-platform=Win64', '-verbosity=minimal'],
                       check=True, env=wine_environment, stderr=subprocess.DEVNULL)
        return ['wine', str(project / 'build/Debug_Win64/ReloadTests/ReloadTests.exe'), 'Z:' + str(project).replace('/', '\\')], wine_environment
    subprocess.run([os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={project}', '-config=Debug', '-platform=Win64', '-verbosity=minimal'], check=True)
    return [str(project / 'build/Debug_Win64/ReloadTests/ReloadTests.exe'), str(project)], None


def wait_for(path, process):
    deadline = time.monotonic() + 60
    while not path.exists():
        if process.poll() is not None:
            raise RuntimeError(f'Host exited early: {process.returncode}\n{process.stdout.read()}')
        if time.monotonic() > deadline:
            raise RuntimeError(f'Timed out waiting for {path.name}')
        time.sleep(.02)


with (contextlib.nullcontext(tempfile.mkdtemp(prefix='tallow-live-reload-test-')) if '--keep' in sys.argv else tempfile.TemporaryDirectory(prefix='tallow-live-reload-test-')) as temporary:
    if '--keep' in sys.argv: print('Test workspace: ' + temporary, flush=True)
    project = Path(temporary)
    shutil.copytree(root / 'src', project / 'src')
    for name in ('BeefProj.toml', 'BeefSpace.toml'):
        shutil.copy2(root / name, project / name)
    relocate_project(project)
    command, environment = compile_host(project)
    baseline = project / 'baseline.json'
    subprocess.run([sys.executable, str(builder), str(project), *platform, '--snapshot', '--baseline', str(baseline)], check=True)
    host = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        wait_for(project / 'ready', host)
        probe = project / 'src/ReloadProbe.bf'
        original = probe.read_text()
        probe.write_text(original.replace('mTotal += amount;', 'mTotal += ;'))
        failed = subprocess.run([sys.executable, str(builder), str(project), *platform, '--baseline', str(baseline), '--manifest', str(project / 'failed.manifest')], capture_output=True, text=True)
        assert failed.returncode != 0 and not (project / 'failed.manifest').exists()
        assert host.poll() is None
        print('PASS: compile error leaves host alive and no new module published', flush=True)
        latest = original
        for generation in range(1, 7):
            if generation <= 2:
                factor = generation * 10
                latest = original.replace('mTotal += amount;', f'mTotal += amount * {factor};').replace('Vector3.Right * amount;', f'Vector3.Right * amount * {factor};')
            if generation == 3:
                latest = latest.replace('float mTotal;', '[ShowInInspector, Range(0,100)] private float mVisiblePrivate=7;\n    [HideInInspector] public int32 addedField=42;\n    float mTotal;')
            if generation == 4:
                latest = latest.replace("public float amount = 1;", "[HideInInspector] public float amount = 1;")
                (project / 'src/Added.bf').write_text('using Tallow; namespace ReloadTests; [Component] class Added : Component { public int32 ticks; public override void Update() { ticks++; } }')
            if generation == 5:
                latest = latest.replace('public float amount = 1;', 'public int32 amount = 1;').replace('[HideInInspector] public int32 amount = 1;', 'public int32 amount = 1;')
            if generation == 6:
                latest = latest.replace('[HideInInspector] public int32 addedField=42;', '')
            probe.write_text(latest)
            manifest = project / f'generation-{generation}.manifest'
            subprocess.run([sys.executable, str(builder), str(project), *platform, '--baseline', str(baseline), '--manifest', str(manifest)], check=True)
            wait_for(project / f'applied-{generation}', host)
            subprocess.run([sys.executable, str(builder), str(project), *platform, '--commit', '--baseline', str(baseline), '--manifest', str(manifest)], check=True)
        try:
            output, _ = host.communicate(timeout=20)
        except subprocess.TimeoutExpired as error:
            output = error.stdout or b''
            print(output.decode(errors='replace') if isinstance(output, bytes) else output, flush=True)
            raise
        print(output, end='')
        assert host.returncode == 0
        print('PASS: adding script, adding/retyping/removing fields, and ShowInInspector reload without restarting host', flush=True)
    finally:
        if host.poll() is None:
            host.kill(); host.wait()
