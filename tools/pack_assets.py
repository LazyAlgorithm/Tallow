#!/usr/bin/env python3
"""Writes and checks Tallow asset packs (.tpak): a game's assets in one file. build_player.py uses this.

  pack_assets.py --list game.tpak          the files in a pack, with sizes
  pack_assets.py --verify game.tpak        reads every file back and checks it; exit status 1 if any is damaged

The format is described at the top of native/tallow_pack.c, which reads it. Files are deflated when that makes
them smaller and then scrambled, so they cannot be opened or edited with ordinary tools, and each carries a checksum
so that a changed file is refused. It is not encryption."""
import argparse
import fnmatch
import os
import re
import struct
import sys
import zlib

KEY = 0x7E55E2A5
BLOCK = 4096
MAGIC = b'TPAK1\0\0\0'
# Already compressed: deflating again gains nothing.
STORED = {'.png', '.jpg', '.jpeg', '.ogg', '.mp3', '.flac', '.tpak'}


def _block(seed, salt):
    state = (seed ^ KEY ^ ((salt * 2654435761) & 0xFFFFFFFF)) & 0xFFFFFFFF
    if state == 0:
        state = KEY
    out = bytearray(BLOCK)
    for i in range(BLOCK):
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        out[i] = (state >> 11) & 0xFF
    return bytes(out)


def _scramble(data, seed, salt):
    """XOR with the repeating block; the same call undoes it."""
    if not data:
        return data
    block = _block(seed, salt)
    stream = (block * (len(data) // BLOCK + 1))[:len(data)]
    return (int.from_bytes(data, 'little') ^ int.from_bytes(stream, 'little')).to_bytes(len(data), 'little')


def write_pack(path, files, compress=True, name=None):
    """files: (name inside the pack, path of the file on disk) pairs. Names use forward slashes.
    compress=False stores every file at its full size (still scrambled and checksummed).
    name (the game's name) fixes the scrambling, so that a file that has not changed comes out the same in every
    build: a store such as Steam then sends players only what did change. Without it each build is scrambled anew."""
    seed = zlib.crc32(('tallow-pack:' + name).encode('utf-8')) if name else int.from_bytes(os.urandom(4), 'little')
    index = bytearray()
    with open(path, 'wb') as out:
        out.write(b'\0' * 32)
        for name, source in sorted(files):
            with open(source, 'rb') as handle:
                plain = handle.read()
            crc = zlib.crc32(plain) & 0xFFFFFFFF
            stored, flags = plain, 0
            if compress and os.path.splitext(name)[1].lower() not in STORED:
                deflated = zlib.compress(plain, 9)
                if len(deflated) < len(plain):
                    stored, flags = deflated, 1
            encoded = name.encode('utf-8')
            index += struct.pack('<H', len(encoded)) + encoded + struct.pack('<QIIIB', out.tell(), len(stored), len(plain), crc, flags)
            out.write(_scramble(stored, seed, crc))
        index_offset = out.tell()
        out.write(_scramble(bytes(index), seed, 0xFFFFFFFF))
        out.seek(0)
        out.write(MAGIC + struct.pack('<IIQII', 1, len(files), index_offset, len(index), seed))
    return len(files)


# Text formats whose contents may name other assets.
_TEXT = {'.tscene', '.tcell', '.tprefab', '.tmat', '.tui', '.tcss', '.tcontroller', '.tanim', '.tshader', '.tcompute', '.tinput',
         '.tbt', '.gltf', '.json', '.txt', '.tallow'}
_PATHLIKE = re.compile(r'[A-Za-z0-9_./\\-]+\.[A-Za-z0-9]+')
# A scene's own pack is only worth its own file above this size; smaller ones stay in the shared pack.
SPLIT_MINIMUM = 64 * 1024


def _references(text, base, assets):
    """The assets a text file names: as an asset path, or relative to the file's own folder."""
    found = set()
    for token in _PATHLIKE.findall(text):
        token = token.replace('\\', '/').lstrip('./')
        if token.startswith('Assets/'):
            token = token[7:]
        for candidate in (token, (base + '/' + token) if base else token):
            if candidate in assets:
                found.add(candidate)
            elif candidate + '.glb' in assets:
                # A converted model (docs/model-import.md): named as the FBX, OBJ, ... and built as <file>.glb.
                found.add(candidate + '.glb')
            elif candidate.endswith('.terrain'):
                # A terrain's sculpting folder: every tile's file in it.
                found.update(path for path in assets if path.startswith(candidate + '/'))
    return found


def plan_split(assets, code_texts, start_scene, shared_patterns=()):
    """Shares a game's assets out among packs: one per scene for what only that scene uses, and the shared pack
    (game.tpak) for everything else.

    assets: {asset-relative path: file path}. code_texts: the game's script sources, whose string literals name
    assets they load. start_scene: the asset-relative scene the game opens with. shared_patterns: wildcards
    (Models/prop_*.glb) for files the scripts load by a name they put together, which reading cannot find: those
    always go into the shared pack.

    A file goes into a scene's pack only when that scene is the one thing that reaches it: not the start scene,
    not another scene, not the scripts, and not a file that something else reaches. What a scene names comes from
    reading it (and the prefabs, materials and documents it names, and so on), plus files beside it with the same
    name, such as a terrain's .voxels file. Returns {pack file name: [asset paths]} for the scene packs and
    {pack file name: scene path}; whatever is in neither belongs in the shared pack."""
    def reach(roots):
        seen, todo = set(), list(roots)
        while todo:
            path = todo.pop()
            if path in seen or path not in assets:
                continue
            seen.add(path)
            stem, _ = os.path.splitext(path)
            for other in assets:
                if other != path and os.path.splitext(other)[0] == stem:
                    todo.append(other)
            if path.endswith('.tscene'):
                # A streamed world (docs/world-streaming.md): its cells, in the folder beside it.
                todo.extend(other for other in assets if other.startswith(stem + '.cells/'))
            if os.path.splitext(path)[1].lower() in _TEXT:
                try:
                    with open(assets[path], 'r', encoding='utf-8') as handle:
                        text = handle.read()
                except (UnicodeDecodeError, OSError):
                    continue
                todo.extend(_references(text, os.path.dirname(path), assets))
        return seen

    scenes = sorted(path for path in assets if path.endswith('.tscene'))
    shared_roots = set()
    # A scene named in the scripts is a map to load, not something every scene needs.
    for text in code_texts:
        shared_roots |= {path for path in _references(text, '', assets) if not path.endswith('.tscene')}
    shared_roots.add(start_scene)
    shared_roots |= {path for path in assets for pattern in shared_patterns if pattern and fnmatch.fnmatchcase(path, pattern)}
    shared = reach(shared_roots)
    users = {}
    for scene in scenes:
        if scene in shared:
            continue
        for path in reach([scene]):
            users.setdefault(path, set()).add(scene)
    packs, served = {}, {}
    for scene in scenes:
        own = sorted(path for path, by in users.items() if by == {scene} and path not in shared)
        if scene not in own or sum(os.path.getsize(assets[path]) for path in own) < SPLIT_MINIMUM:
            continue
        name = 'scene-' + re.sub(r'[^a-z0-9]+', '-', os.path.splitext(os.path.basename(scene))[0].lower()).strip('-') + '.tpak'
        if name in packs:
            name = 'scene-' + re.sub(r'[^a-z0-9]+', '-', os.path.splitext(scene)[0].lower()).strip('-') + '.tpak'
        packs[name] = own
        served[name] = scene
    return packs, served


def read_index(handle):
    header = handle.read(32)
    if len(header) != 32 or header[:8] != MAGIC:
        raise ValueError('not a Tallow asset pack')
    version, count, index_offset, index_size, seed = struct.unpack('<IIQII', header[8:])
    if version != 1:
        raise ValueError(f'pack version {version} is not supported')
    handle.seek(index_offset)
    index = _scramble(handle.read(index_size), seed, 0xFFFFFFFF)
    entries, at = [], 0
    for _ in range(count):
        length, = struct.unpack_from('<H', index, at)
        name = index[at + 2:at + 2 + length].decode('utf-8')
        offset, stored, size, crc, flags = struct.unpack_from('<QIIIB', index, at + 2 + length)
        entries.append((name, offset, stored, size, crc, flags))
        at += 2 + length + 21
    return seed, entries


def read_file(handle, seed, entry):
    name, offset, stored, size, crc, flags = entry
    handle.seek(offset)
    data = _scramble(handle.read(stored), seed, crc)
    if flags & 1:
        data = zlib.decompress(data)
    if len(data) != size or (zlib.crc32(data) & 0xFFFFFFFF) != crc:
        raise ValueError(f'{name} is damaged')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--list', metavar='PACK')
    parser.add_argument('--verify', metavar='PACK')
    args = parser.parse_args()
    if not args.list and not args.verify:
        parser.error('give --list or --verify')
    with open(args.list or args.verify, 'rb') as handle:
        seed, entries = read_index(handle)
        bad = 0
        for entry in entries:
            if args.verify:
                try:
                    read_file(handle, seed, entry)
                except (ValueError, zlib.error) as error:
                    print(f'DAMAGED {entry[0]}: {error}')
                    bad += 1
            else:
                print(f'{entry[3]:>10}  {entry[2]:>10}  {entry[0]}')
        print(f'{len(entries)} files' + (f', {bad} damaged' if args.verify else ''))
        return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
