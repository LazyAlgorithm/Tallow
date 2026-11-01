#!/usr/bin/env python3
"""Builds small asset packs with tools/pack_assets.py and has the engine read them back (Tests/AssetPack/src)."""
from pathlib import Path
import math
import os
import struct
import subprocess
import sys
import tempfile
import zlib

root = Path(__file__).resolve().parent
engine = root.parents[1]
sys.path.insert(0, str(engine / 'tools'))
import pack_assets


def png(width, height, rgba):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)
    rows = b''.join(b'\0' + bytes(rgba) * width for _ in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def wav(seconds, rate=8000):
    samples = b''.join(struct.pack('<h', int(12000 * math.sin(i * 0.3))) for i in range(int(seconds * rate)))
    return b'RIFF' + struct.pack('<I', 36 + len(samples)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16) + b'data' + struct.pack('<I', len(samples)) + samples


with tempfile.TemporaryDirectory(prefix='tallow-pack-test-') as temporary:
    work = Path(temporary)
    source = work / 'source' / 'Assets'
    (source / 'Sub').mkdir(parents=True)
    (source / 'notes.txt').write_text('packed notes\n')
    (source / 'Sub' / 'numbers.bin').write_bytes(bytes((i * 7) % 251 for i in range(70000)))
    (source / 'Sub' / 'empty.txt').write_bytes(b'')
    (source / 'dot.png').write_bytes(png(4, 2, (255, 128, 0, 255)))
    (source / 'beep.wav').write_bytes(wav(0.25))
    (source / 'block.glb').write_bytes((engine / 'Editor/templates/common/Models/rigged_sample.glb').read_bytes())
    (work / 'source' / 'game.tallow').write_text('name = Test\n')
    files = [(file.relative_to(work / 'source').as_posix(), str(file)) for file in (work / 'source').rglob('*') if file.is_file()]
    pack = work / 'game.tpak'
    pack_assets.write_pack(pack, files)
    # The tool reads its own packs back, and notices a changed byte.
    with open(pack, 'rb') as handle:
        seed, entries = pack_assets.read_index(handle)
        assert len(entries) == 7 and all(pack_assets.read_file(handle, seed, entry) == (work / 'source' / entry[0]).read_bytes() for entry in entries)
        numbers = next(entry for entry in entries if entry[0].endswith('numbers.bin'))
    assert b'packed notes' not in pack.read_bytes() and b'RIFF' not in pack.read_bytes(), 'file contents can be seen in the pack'
    damaged = bytearray(pack.read_bytes())
    damaged[numbers[1] + numbers[2] // 2] ^= 0x40
    (work / 'damaged.tpak').write_bytes(damaged)
    assert subprocess.run([sys.executable, str(engine / 'tools/pack_assets.py'), '--verify', str(pack)], capture_output=True).returncode == 0
    assert subprocess.run([sys.executable, str(engine / 'tools/pack_assets.py'), '--verify', str(work / 'damaged.tpak')], capture_output=True).returncode == 1
    print('PASS: the pack tool writes, lists and verifies packs, and hides what is in them')
    # Loose files that a pack must not hide, and must not be replaced by.
    (work / 'loose' / 'Assets').mkdir(parents=True)
    (work / 'loose' / 'Assets' / 'notes.txt').write_text('loose notes\n')

    subprocess.run([os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={root}', '-config=Debug', '-verbosity=minimal'], check=True, stdout=subprocess.DEVNULL)
    result = subprocess.run([str(root / 'build/Debug_Linux64/AssetPackTests/AssetPackTests'), str(pack), str(work / 'game'), str(work / 'damaged.tpak'), str(work / 'loose')])
    sys.exit(result.returncode)
