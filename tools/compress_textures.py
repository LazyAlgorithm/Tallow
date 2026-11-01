#!/usr/bin/env python3
"""Compress a game's pictures for the graphics card (docs/textures.md): each becomes `<picture>.ktx` beside it, BC1
(opaque, an eighth of the memory) or BC3 (with transparency, a quarter) with all its mip levels, made with bgfx's
texturec. The engine uses the .ktx in place of the picture; the picture stays for code that reads its pixels.

    python3 tools/compress_textures.py <folder> [--exclude 'UI/*;Fonts/*'] [--materials <folder>]

Normal maps are left alone (the formats' 5-6-5 colours band directions badly); pictures named as a material's
metallicRoughnessMap or occlusionMap are compressed as data, without colour correction.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import fnmatch
import os
from pathlib import Path
import struct
import subprocess
import sys

PICTURES = ('.png', '.jpg', '.jpeg', '.tga', '.bmp')
DEFAULT_EXCLUDE = 'UI/*;Fonts/*'
# texturec marks colour pictures as sRGB. Tallow's shaders decode sRGB themselves, so the graphics card must not as
# well: the KTX header's internal format is set to the plain one (the mip levels stay made in linear light).
PLAIN_FORMAT = {0x8C4C: 0x83F0, 0x8C4D: 0x83F1, 0x8C4E: 0x83F2, 0x8C4F: 0x83F3}


def texturec_path(engine):
    """The texturec built with the engine's native libraries, or None."""
    for folder in ('native-win', 'native') if os.name == 'nt' else ('native',):
        candidate = engine / 'build' / folder / 'bgfx/cmake/bimg' / ('texturec.exe' if os.name == 'nt' else 'texturec')
        if candidate.is_file():
            return candidate
    return None


def has_alpha(path):
    """Whether a picture can be see-through, from its header: PNG with an alpha channel or a tRNS chunk, TGA with alpha
    bits. JPEG and BMP pictures here are taken as opaque."""
    data = path.read_bytes()
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        color_type = data[25]
        if color_type in (4, 6):
            return True
        return b'tRNS' in data[:data.find(b'IDAT')] if b'IDAT' in data else False
    if path.suffix.lower() == '.tga' and len(data) > 17:
        return (data[17] & 0x0F) > 0
    return False


def kinds_from_materials(folder):
    """Pictures the project's materials name as normal maps, and as data (metal / roughness, occlusion)."""
    normal, data = set(), set()
    for material in folder.rglob('*.tmat'):
        for line in material.read_text(errors='replace').splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and parts[1].startswith('"'):
                value = parts[1].strip().strip('"')
                if parts[0] == 'normalMap':
                    normal.add(value)
                elif parts[0] in ('metallicRoughnessMap', 'occlusionMap'):
                    data.add(value)
    return normal, data


def plain_srgb(path):
    """Rewrites a KTX file's sRGB internal format to the plain one."""
    with open(path, 'r+b') as file:
        header = file.read(32)
        if header[:12] != b'\xabKTX 11\xbb\r\n\x1a\n':
            return
        (internal,) = struct.unpack('<I', header[28:32])
        if internal in PLAIN_FORMAT:
            file.seek(28)
            file.write(struct.pack('<I', PLAIN_FORMAT[internal]))


def compress(texturec, picture, linear):
    """Makes picture + '.ktx'. Returns an error message, or None."""
    output = picture.with_name(picture.name + '.ktx')
    format_ = 'BC3' if has_alpha(picture) else 'BC1'
    command = [str(texturec), '-f', str(picture), '-o', str(output), '-t', format_, '-m', '--as', 'ktx']
    if linear:
        command.append('--linear')
    run = subprocess.run(command, capture_output=True, text=True)
    if run.returncode != 0 or not output.is_file():
        output.unlink(missing_ok=True)
        return f'{picture.name}: {(run.stderr or run.stdout).strip()}'
    plain_srgb(output)
    return None


def compress_folder(folder, engine, exclude=DEFAULT_EXCLUDE, materials=None):
    """Compresses every picture under folder. Returns (made, skipped, errors)."""
    texturec = texturec_path(engine)
    if texturec is None:
        return 0, 0, ['texturec is not built (cmake --build build/native --target texturec); pictures are left uncompressed']
    patterns = [pattern.strip() for pattern in exclude.split(';') if pattern.strip()]
    normal, data = kinds_from_materials(materials or folder)
    jobs, skipped = [], 0
    for picture in sorted(folder.rglob('*')):
        if not picture.is_file() or picture.suffix.lower() not in PICTURES:
            continue
        relative = picture.relative_to(folder).as_posix()
        # Baked lightmaps (docs/baked-lighting.md) are RGBM: block compression would spoil the range in alpha.
        if any(fnmatch.fnmatch(relative, pattern) for pattern in patterns) or relative in normal or 'normal' in picture.name.lower() \
                or picture.name.startswith('Lightmap-'):
            skipped += 1
            continue
        jobs.append((picture, relative in data))
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        errors = [error for error in pool.map(lambda job: compress(texturec, *job), jobs) if error]
    return len(jobs) - len(errors), skipped, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('folder', type=Path)
    parser.add_argument('--exclude', default=DEFAULT_EXCLUDE, help='semicolon-separated patterns of pictures to leave alone')
    parser.add_argument('--materials', type=Path, help='folder of the .tmat files (default: the folder itself)')
    args = parser.parse_args()
    engine = Path(__file__).resolve().parent.parent
    made, skipped, errors = compress_folder(args.folder.resolve(), engine, args.exclude, args.materials)
    print(f'Compressed {made} pictures, left {skipped} alone' + (f'; {len(errors)} failed' if errors else ''))
    for error in errors:
        print('  ' + error)
    return 1 if errors and made == 0 else 0


if __name__ == '__main__':
    sys.exit(main())
