#!/usr/bin/env python3
"""Builds the asset packs the anti-cheat's file check is tried with, then runs the fixture (Tests/AntiCheat/src)."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent
engine = root.parents[1]
sys.path.insert(0, str(engine / 'tools'))
import pack_assets

with tempfile.TemporaryDirectory(prefix='tallow-anticheat-test-') as temporary:
    work = Path(temporary)
    for name, extra_engine_file, level in (('game', False, b'level one\n'), ('repacked', True, b'level one\n'), ('changed', False, b'level 0ne\n')):
        source = work / name
        (source / 'Assets' / 'Maps').mkdir(parents=True)
        (source / 'Engine').mkdir()
        (source / 'Assets' / 'Maps' / 'one.txt').write_bytes(level)
        (source / 'Assets' / 'weapons.txt').write_text('rifle 12\nshotgun 60\n')
        (source / 'Engine' / 'shader.bin').write_bytes(b'\x01\x02\x03' if not extra_engine_file else b'\x09\x09')
        if extra_engine_file:
            (source / 'Engine' / 'other-system.bin').write_bytes(b'only on the other system')
        (source / 'game.tallow').write_text('name = Test\n' + ('fullscreen = 1\n' if extra_engine_file else ''))
        files = [(file.relative_to(source).as_posix(), str(file)) for file in source.rglob('*') if file.is_file()]
        pack_assets.write_pack(work / f'{name}.tpak', files)
    # A library that does not belong to the system or the game, to load into the fixture as an injector would:
    # any harmless one, copied to where such things are not kept.
    import ctypes.util, shutil
    harmless = next(str(path) for folder in ('/usr/lib64', '/usr/lib', '/lib64', '/usr/lib/x86_64-linux-gnu') for path in sorted(Path(folder).glob('libz.so.1*')) if path.is_file())
    shutil.copy(harmless, work / 'injected.so')
    subprocess.run(['BeefBuild', f'-workspace={root}', '-config=Debug', '-verbosity=minimal'], check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run([str(root / 'build/Debug_Linux64/AntiCheatTests/AntiCheatTests'), str(work / 'game.tpak'), str(work / 'repacked.tpak'), str(work / 'changed.tpak'), str(work / 'injected.so')])
    sys.exit(result.returncode)
