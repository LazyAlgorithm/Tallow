#!/usr/bin/env python3
"""Compile a private game-code library against the running debug host (Linux or Windows)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import struct
import tomllib
import time

TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|=>|[A-Za-z_][A-Za-z_0-9]*|[^\s]', re.S)


def reload_workspace(project, platform):
    """Persist Beef's incremental cache across editor launches on both OSes."""
    return project / '.tallow-reload' / ('workspace-win64' if platform == 'windows' else 'workspace-linux64')


def partition_link_objects(objects, prepared, game_objects):
    """Keep game objects explicit and package only resident dependencies."""
    game = set(game_objects)
    game_links, dependency_links = [], []
    for original, linked in zip(objects, prepared):
        (game_links if original in game else dependency_links).append(linked)
    return game_links, dependency_links


def cached_dependency_archive(objects, archive):
    """Cache an indexed library of host-aware dependency objects.

    Prepared objects are rewritten when their contents or matching host
    exports change, so a file stamp is sufficient for archive invalidation.
    """
    if not objects:
        return None, False
    stamp = archive.with_suffix(archive.suffix + '.stamp')
    digest = hashlib.sha256()
    for obj in objects:
        stat = obj.stat()
        digest.update(os.fsencode(obj))
        digest.update(b'\0')
        digest.update(f'{stat.st_size}:{stat.st_mtime_ns}\n'.encode())
    signature = digest.hexdigest()
    if archive.is_file() and stamp.is_file() and stamp.read_text() == signature:
        return archive, True
    temp = archive.with_name(archive.name + '.tmp')
    if temp.exists():
        temp.unlink()
    try:
        subprocess.run(['ar', 'rcs', str(temp), *map(str, objects)], check=True)
        temp.replace(archive)
        stamp.write_text(signature)
    finally:
        if temp.exists():
            temp.unlink()
    return archive, False


def beef_build_artifacts(workspace, name, platform):
    """Compiler outputs: distinguish game code from resident dependency code.

    The linker input list is also our best available inventory of emitted
    Linux object files. For Windows, BeefBuild uses indexed .lib archives.
    """
    root = workspace / 'build' / ('Debug_Win64' if platform == 'windows' else 'Debug_Linux64') / name
    if platform == 'linux':
        args = root / 'ObjectArgs.txt'
        try:
            paths = [Path(item) for item in shlex.split(args.read_text())
                     if item.endswith('.o') and Path(item).name != 'vdata.o']
        except OSError:
            paths = []
        return {
            'game': [path for path in paths if path.parent == root],
            'dependencies': [path for path in paths if path.parent != root],
            'reflection': [root / 'vdata.o'],
        }
    build = root.parent
    return {
        'game': [root / (name + '__.lib')],
        'dependencies': [path for path in build.rglob('*__.lib') if path.parent != root]
                        if build.is_dir() else [],
        'reflection': [root / 'vdata.obj'],
    }


def build_output_state(workspace, name, platform):
    """Record cheap file timestamps; changed means rewritten, not necessarily recompiled."""
    buckets = {}
    for category, paths in beef_build_artifacts(workspace, name, platform).items():
        stamps = {}
        for path in paths:
            try:
                stat = path.stat()
                stamps[str(path)] = (stat.st_size, stat.st_mtime_ns)
            except OSError:
                pass
        buckets[category] = stamps
    return buckets


def build_output_activity(before, after):
    """Count compiler outputs added/rewritten for both Linux and Windows."""
    results = {}
    for category in ('game', 'dependencies', 'reflection'):
        old, new = before.get(category, {}), after.get(category, {})
        results[category] = {
            'total': len(new),
            'rewritten': sum(1 for path, stamp in new.items() if path in old and old[path] != stamp),
            'new': sum(1 for path in new if path not in old),
        }
    return results


def build_activity_label(activity):
    return ', '.join(
        f'{name} {values["rewritten"]} rewritten/{values["new"]} new/{values["total"]} present'
        for name, values in activity.items())


def write_if_changed(path, content):
    """Preserve modification time when a generated Beef workspace config is unchanged.

    BeefBuild uses file timestamps for its incremental cache. Rewriting these
    files on every script save can invalidate that cache and trigger needless work.
    """
    if path.is_file() and path.read_text() == content:
        return False
    path.write_text(content)
    return True


def schema(text):
    """Conservatively keep declarations and discard only method/accessor bodies."""
    tokens = [m.group() for m in TOKEN.finditer(text) if not m.group().startswith(('//', '/*'))]
    result = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        previous = tokens[i - 1] if i else ''
        if token == '{' and previous in (')', 'get', 'set'):
            result += ['{', '}']
            depth = 1
            i += 1
            while i < len(tokens) and depth:
                depth += (tokens[i] == '{') - (tokens[i] == '}')
                i += 1
            continue
        if token == '=>' and previous in (')', 'get', 'set'):
            result += ['=>', ';']
            i += 1
            depth = 0
            while i < len(tokens):
                if tokens[i] == ';' and depth == 0:
                    i += 1
                    break
                depth += (tokens[i] in ('(', '[', '{')) - (tokens[i] in (')', ']', '}'))
                i += 1
            continue
        result.append(token)
        i += 1
    return hashlib.sha256(' '.join(result).encode()).hexdigest()


def normalized_source(text):
    """Conservative token fingerprint for whitespace-only changes.

    Keep comments and string/character literals exactly, including whitespace
    inside them. Complex multiline strings and preprocessor directives use
    their original bytes because their layout can affect compilation.
    """
    if ('"""' in text or '@"' in text or re.search(r'(?m)^\s*#', text)):
        return hashlib.sha256(text.encode()).hexdigest()
    digest = hashlib.sha256()
    for token in TOKEN.finditer(text):
        digest.update(token.group().encode('utf-8'))
        digest.update(b'\0')
    return digest.hexdigest()


def classify_changes(baseline, current):
    """Classify edits against the last activated version without invoking BeefBuild.

    Return 0 for unchanged, 10 for method-only, 11 for structural and
    3 when the resident engine or build configuration changed.
    """
    if baseline['resident'] != current['resident']:
        return 3
    if baseline['schemas'] != current['schemas']:
        return 11
    if baseline['code'] != current['code']:
        # No build is necessary when only insignificant whitespace changed.
        # Old snapshots without normalized fingerprints remain conservative.
        if (baseline.get('normalized_code') is not None and
                baseline['normalized_code'] == current.get('normalized_code')):
            return 0
        return 10
    return 0


def reload_strategy(mode, baseline, current, platform):
    """Use method patching only while metadata still belongs to the original host.

    Structural activation replaces reflected class metadata, which the old
    method patcher's resident class lookup cannot reliably recognize afterward.
    Avoid another doomed patch attempt until the editor restarts.
    """
    if (mode == 'automatic' and platform == 'linux'
            and baseline.get('method_patch_eligible', True)
            and current['code'] != baseline['code']
            and current['schemas'] == baseline['schemas']):
        return 'methods'
    return 'structural'


def project_path(project, text):
    """A path from a workspace file. Under Wine a Windows workspace names this system's folders as Z:/..."""
    if os.name != 'nt' and re.match(r'^[zZ]:[\\/]', text):
        return Path(text[2:].replace('\\', '/')).resolve()
    return (project / text).resolve()


def snapshot(project):
    config = tomllib.loads((project / 'BeefSpace.toml').read_text())
    engine = project_path(project, config['Projects']['Tallow']['Path']).parent
    sources = {str(p.relative_to(project / 'src')): schema(p.read_text()) for p in sorted((project / 'src').rglob('*.bf'))}
    digest = hashlib.sha256()
    files = list((engine / 'Engine' / 'src').rglob('*.bf')) + list((engine / 'Editor' / 'src').rglob('*.bf'))
    files += list((engine / 'native').glob('*.cpp')) + list((engine / 'native').glob('*.h')) + [engine / 'native' / 'CMakeLists.txt']
    files += [project / 'BeefSpace.toml', project / 'BeefProj.toml']
    # Extra libraries currently remain resident; changes to them need a full rebuild.
    for name, entry in config['Projects'].items():
        if name not in ('Tallow', 'TallowEditor', tomllib.loads((project / 'BeefProj.toml').read_text())['Project']['Name']):
            folder = project_path(project, entry['Path'])
            files += list(folder.rglob('*.bf')) + [folder / 'BeefProj.toml']
    for file in sorted(set(files)):
        if file.is_file():
            digest.update(str(file).encode()); digest.update(file.read_bytes())
    code = hashlib.sha256()
    normalized = hashlib.sha256()
    for file in sorted((project / 'src').rglob('*.bf')):
        relative = str(file.relative_to(project / 'src')).encode()
        data = file.read_bytes()
        code.update(relative); code.update(data)
        normalized.update(relative)
        normalized.update(normalized_source(data.decode('utf-8')).encode())
    return {'schemas': sources, 'resident': digest.hexdigest(),
            'code': code.hexdigest(), 'normalized_code': normalized.hexdigest()}


def symbols(objects):
    output = subprocess.check_output(['nm', '-g', '-S', '--defined-only', *map(str, objects)], text=True)
    values = {}
    force = set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].startswith('FORCELINKMOD_'):
            force.add(parts[-1][len('FORCELINKMOD_'):])
        if len(parts) == 4 and parts[2] in ('B', 'D'):
            values[parts[3]] = int(parts[1], 16)
    return force, values


def alias_host_globals(source, target, names):
    """Leave mutable script data in the host: make its ELF symbols undefined in the module."""
    data = bytearray(source.read_bytes())
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Reload requires little-endian ELF64 object files.')
    shoff = struct.unpack_from('<Q', data, 40)[0]
    shsize, shcount = struct.unpack_from('<HH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shsize) for i in range(shcount)]
    removed_functions = []
    matched = set()
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        strings = sections[section[6]]
        string_table = data[strings[4]:strings[4] + strings[5]]
        for offset in range(section[4], section[4] + section[5], section[9]):
            name_index, info, other, index, value, size = struct.unpack_from('<IBBHQQ', data, offset)
            end = string_table.find(b'\0', name_index)
            name = string_table[name_index:end].decode()
            if name in names and index != 0:
                matched.add(name)
                if info & 15 == 2 and index < len(sections):
                    removed_functions.append((index, value, value + size))
                    body = sections[index][4] + value
                    data[body:body + size] = b'\x90' * size
                struct.pack_into('<HQQ', data, offset + 6, 0, 0, 0)
    for section in sections:
        if section[1] != 4:  # SHT_RELA
            continue
        ranges = [(a, b) for index, a, b in removed_functions if index == section[7]]
        if not ranges:
            continue
        for offset in range(section[4], section[4] + section[5], section[9]):
            position = struct.unpack_from('<Q', data, offset)[0]
            if any(a <= position < b for a, b in ranges):
                struct.pack_into('<Qq', data, offset + 8, 0, 0)
    target.write_bytes(data)
    return sorted(matched)


def affected_host_symbols(data, names):
    """Find host definitions actually present in an ELF object.

    The broad host export list grows after script reloads; only symbols defined
    by this particular object can change its rewritten output. This is a
    conservative exact check, never a heuristic substring search.
    """
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Reload requires little-endian ELF64 object files.')
    shoff = struct.unpack_from('<Q', data, 40)[0]
    shsize, shcount = struct.unpack_from('<HH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shsize) for i in range(shcount)]
    matched = set()
    for section in sections:
        if section[1] != 2:  # SHT_SYMTAB
            continue
        strings = sections[section[6]]
        table = data[strings[4]:strings[4] + strings[5]]
        for offset in range(section[4], section[4] + section[5], section[9]):
            name_index, info, other, index, value, size = struct.unpack_from('<IBBHQQ', data, offset)
            if index == 0:
                continue
            end = table.find(b'\0', name_index)
            name = table[name_index:end].decode()
            if name in names:
                matched.add(name)
    return sorted(matched)


def alias_objects(objects, game_objects, aliases, resident, shared):
    """Reuse unchanged ELF symbol rewrites across hot-reload generations.

    A cached object is valid only when its exact bytes and affected host
    definitions are unchanged. This avoids invalidating thousands of engine
    objects just because a reload introduced an unrelated export. Cache files
    belong to this editor session.
    """
    aliases.mkdir(exist_ok=True)
    cache_path = aliases / 'object-cache.json'
    try:
        previous = json.loads(cache_path.read_text())
        if not isinstance(previous, dict):
            previous = {}
    except (OSError, ValueError):
        previous = {}

    # The game and dependency objects intentionally use different host scopes.
    def names_digest(names):
        digest = hashlib.sha256()
        for name in sorted(names):
            digest.update(name.encode('utf-8'))
            digest.update(b'\0')
        return digest.hexdigest()

    resident_digest = names_digest(resident)
    shared_digest = names_digest(shared)
    game_objects = set(game_objects)
    # BeefBuild lists objects in link order, which is NOT stable when adding a
    # script/component: one insertion may renumber thousands of unrelated files.
    # Reuse the prepared ELF object by source path, not its current list index.
    # Migrate legacy index-keyed caches in place so upgrading the editor does
    # not force every existing object through alias_host_globals again.
    by_source = {}
    for old_key, old_record in previous.items():
        if not isinstance(old_record, dict) or not isinstance(old_record.get('source'), str):
            continue
        source = old_record['source']
        saved_target = old_record.get('target')
        if isinstance(saved_target, str) and Path(saved_target).name == saved_target:
            prepared = aliases / saved_target
        elif old_key.isdecimal():
            prepared = aliases / f'{old_key}-{Path(source).name}'
        else:
            continue
        by_source[source] = (old_record, prepared)

    updated = {}
    result = []
    reused = 0
    reasons = {'cold': 0, 'changed': 0, 'symbols': 0}
    for obj in objects:
        source = str(obj)
        cached = by_source.get(source)
        if cached is not None:
            last, target = cached
        else:
            # The full path is the identity; the short hash keeps aliases
            # portable across filesystem limits and avoids same-name clashes.
            token = hashlib.sha256(os.fsencode(obj)).hexdigest()[:24]
            target = aliases / f'{token}-{obj.name}'
            last = None
        is_game = obj in game_objects
        host_names = shared if is_game else resident
        scope_digest = shared_digest if is_game else resident_digest
        data = obj.read_bytes()
        object_digest = hashlib.sha256(data).hexdigest()
        record = {'source': source, 'target': target.name,
                  'object': object_digest, 'host': scope_digest}
        same_object = (isinstance(last, dict) and last.get('source') == source
                       and last.get('object') == object_digest and target.is_file())
        matching_symbols = None
        if same_object and last.get('host') == scope_digest:
            matching_symbols = last.get('matched')
        elif same_object and isinstance(last.get('matched'), list):
            # Newly exported symbols matter only if this specific object
            # defines them. Compare the precise affected-symbol set.
            candidate = affected_host_symbols(data, host_names)
            if candidate == last['matched']:
                matching_symbols = candidate
        if same_object and matching_symbols is not None:
            reused += 1
        else:
            if not isinstance(last, dict) or not target.is_file():
                reasons['cold'] += 1
            elif not same_object:
                reasons['changed'] += 1
            else:
                reasons['symbols'] += 1
            matching_symbols = alias_host_globals(obj, target, host_names)
        record['matched'] = matching_symbols
        updated[source] = record
        result.append(target)

    # A failed or interrupted cache write must not leave an incomplete index.
    temporary = cache_path.with_suffix('.tmp')
    temporary.write_text(json.dumps(updated))
    temporary.replace(cache_path)
    return result, reused, reasons


def exported_symbols(path):
    command = ['nm', '-g', '-S', '--defined-only', str(path)]
    values = {}
    for line in subprocess.check_output(command, text=True).splitlines():
        parts = line.split()
        if len(parts) == 4:
            values[parts[3]] = int(parts[1], 16)
    return values


# ---------------------------------------------------------------------------------------------------------------
# Windows.
#
# A Windows program does not share its symbols with a library loaded into it the way a Linux one linked with
# -rdynamic does, and there is no room in an export table for all of the engine. So the script library is not
# loaded by Windows at all. It is linked at an exact address just below the running program, against a stand-in
# object that says where everything in that program is (taken from its link map), and the editor copies its
# sections into place itself. Every reference to the engine is then an ordinary one the linker resolved.
#
#   address space:   [ newest library ][ older libraries ] ... [ the running program ]
#                    ^ image base      \________ the stand-in's one empty section ___/
#
# The stand-in section is never loaded: it only makes the addresses of the program, and of the libraries
# loaded before this one, come out right.

HOST_SECTION = b'.hostimg'
MAP_LINE = re.compile(r'^ ([0-9a-fA-F]{4}):[0-9a-fA-F]{8}\s+(\S+)\s+([0-9a-fA-F]{16})\s')
# Symbols the linker makes for every image itself, or that only mean something inside their own image.
PRIVATE_TO_IMAGE = ('__ImageBase', '__guard_', '__enclave_config', '__safe_se_handler', '__CTOR_LIST__', '__DTOR_LIST__',
                    '__dso_handle', '__RUNTIME_PSEUDO_RELOC', '__NULL_IMPORT_DESCRIPTOR', '__IMPORT_DESCRIPTOR_', '_tls_used',
                    '__tls_', '_tls_index', '__xl_', '__dyn_tls', '__rtc_', '_load_config_used', '\x7f')
PAGE = 0x1000
GRAIN = 0x10000


def cross():
    """Targeting Windows from another system: the Windows compiler runs under Wine."""
    return os.name != 'nt'


def toolchain():
    return Path(os.environ.get('TALLOW_WIN', Path.home() / '.local/share/tallow-win'))


def windows_path(path):
    return 'Z:' + str(path).replace('/', '\\') if cross() else str(path)


def local_path(text):
    """A path as the Windows compiler wrote it, as this system knows it."""
    if cross() and re.match(r'^[zZ]:[\\/]', text):
        return Path(text[2:].replace('\\', '/'))
    return Path(text.replace('\\', '/')) if cross() else Path(text)


def beef_command(workspace):
    if cross():
        return (['wine', str(toolchain() / 'beef/bin/BeefBuild.exe'), '-workspace=' + windows_path(workspace), '-config=Debug', '-platform=Win64', '-verbosity=minimal'],
                dict(os.environ, WINEPREFIX=str(toolchain() / 'wine'), WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml='))
    return [os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={workspace}', '-config=Debug', '-platform=Win64', '-verbosity=minimal'], os.environ.copy()


def linker():
    if cross():
        return str(toolchain() / 'bin/lld-link')
    beef = shutil.which(os.environ.get('BEEFBUILD', 'BeefBuild'))
    candidate = Path(beef).parent / 'llvm/bin/lld-link.exe' if beef else None
    if candidate is None or not candidate.is_file():
        raise ValueError('lld-link.exe was not found beside BeefBuild (bin/llvm/bin); script reload needs it.')
    return str(candidate)


def archive_members(path):
    """The object files in a .lib, as (name, bytes)."""
    data = path.read_bytes()
    if data[:8] != b'!<arch>\n':
        raise ValueError(f'Not an object archive: {path}')
    position, names, members = 8, b'', []
    while position + 60 <= len(data):
        header = data[position:position + 60]
        name = header[:16].decode('latin-1').rstrip()
        size = int(header[48:58])
        body = data[position + 60:position + 60 + size]
        position += 60 + size + (size & 1)
        if name == '/' or name == '/SYM64/':
            continue
        if name == '//':
            names = body
            continue
        if name.startswith('/') and name[1:].isdigit():
            start = int(name[1:])
            ends = [e for e in (names.find(b'\0', start), names.find(b'/\n', start)) if e >= 0]
            name = names[start:min(ends) if ends else len(names)].decode('latin-1')
        else:
            name = name.rstrip('/')
        members.append((name, body))
    return members


class Coff:
    """Just enough of an x64 object file: its sections and its symbol table."""

    def __init__(self, data, label='object'):
        self.data = data
        machine, self.section_count, _, self.symbol_offset, self.symbol_count, optional, _ = struct.unpack_from('<HHIIIHH', data, 0)
        if machine != 0x8664:
            raise ValueError(f'{label} is not a plain x64 object file.')
        self.sections = [struct.unpack_from('<8sIIIIIIHHI', data, 20 + optional + 40 * i) for i in range(self.section_count)]
        self.strings = self.symbol_offset + self.symbol_count * 18
        self.symbols = []   # (index, name, value, section number, storage class)
        index = 0
        while index < self.symbol_count:
            raw, value, section, _, storage, extra = struct.unpack_from('<8sIhHBB', data, self.symbol_offset + 18 * index)
            self.symbols.append((index, self.name(raw), value, section, storage))
            index += 1 + extra

    def name(self, raw):
        if raw[:4] == b'\0\0\0\0':
            start = self.strings + struct.unpack('<I', raw[4:])[0]
            return self.data[start:self.data.find(b'\0', start)].decode('latin-1')
        return raw.rstrip(b'\0').decode('latin-1')

    def defined(self):
        """External symbols this object defines: name -> (section number, value)."""
        return {name: (section, value) for _, name, value, section, storage in self.symbols if storage == 2 and section > 0}

    def state(self):
        """Its writable data: name -> size, the size being the room up to the next symbol in the section."""
        result = {}
        for name, (section, value) in self.defined().items():
            flags = self.sections[section - 1][9]
            if not flags & 0x80000000 or flags & 0x20:
                continue
            raw_size = self.sections[section - 1][3]
            later = [v for _, _, v, s, _ in self.symbols if s == section and v > value]
            result[name] = (min(later) if later else raw_size) - value
        return result

    def renamed(self, mapping):
        """The same object with some symbols given other names, wherever they are defined or used."""
        table = bytearray(self.data[self.strings:])
        if len(table) < 4:
            table = bytearray(struct.pack('<I', 4))
        data = bytearray(self.data[:self.strings])
        for index, name, _, _, _ in self.symbols:
            if name in mapping:
                struct.pack_into('<II', data, self.symbol_offset + 18 * index, 0, len(table))
                table += mapping[name].encode('latin-1') + b'\0'
        struct.pack_into('<I', table, 0, len(table))
        return bytes(data + table)


def read_map(path):
    """A link map's public symbols: name -> address, and the address the image was linked for."""
    base, symbols, started = 0, {}, False
    with open(path, errors='replace') as file:
        for line in file:
            if not started:
                found = re.search(r'Preferred load address is ([0-9a-fA-F]+)', line)
                if found:
                    base = int(found.group(1), 16)
                started = 'Publics by Value' in line
                continue
            if 'Static symbols' in line:
                break
            found = MAP_LINE.match(line)
            if found and found.group(1) != '0000':
                symbols[found.group(2)] = int(found.group(3), 16)
    return base, symbols


def image_layout(path):
    """An image's preferred base, its size in memory and its sections as (name, address offset, size in memory)."""
    data = path.read_bytes()
    header = struct.unpack_from('<I', data, 0x3C)[0]
    count, optional_size = struct.unpack_from('<H', data, header + 6)[0], struct.unpack_from('<H', data, header + 20)[0]
    optional = header + 24
    base = struct.unpack_from('<Q', data, optional + 24)[0]
    size = struct.unpack_from('<I', data, optional + 56)[0]
    sections = []
    for i in range(count):
        name, virtual_size, address, raw_size, _, _, _, _, _, flags = struct.unpack_from('<8sIIIIIIHHI', data, optional + optional_size + 40 * i)
        sections.append((name.rstrip(b'\0'), address, max(virtual_size, raw_size), flags))
    return base, size, sections


def write_stand_in(path, size, symbols):
    """An object with one empty section of the given size and a symbol at each given offset in it."""
    table = bytearray(struct.pack('<I', 4))
    records = bytearray()
    for name, offset in symbols.items():
        raw = name.encode('latin-1')
        if len(raw) <= 8:
            head = raw.ljust(8, b'\0')
        else:
            head = struct.pack('<II', 0, len(table))
            table += raw + b'\0'
        records += head + struct.pack('<IhHBB', offset, 1, 0, 2, 0)
    struct.pack_into('<I', table, 0, len(table))
    header = struct.pack('<HHIIIHH', 0x8664, 1, 0, 20 + 40, len(symbols), 0, 0)
    # Uninitialised data, readable and writable, byte aligned: it takes no room in the file.
    section = struct.pack('<8sIIIIIIHHI', HOST_SECTION, 0, 0, size, 0, 0, 0, 0, 0, 0xC0100080)
    path.write_bytes(header + section + bytes(records) + bytes(table))


def class_key(symbol):
    """?sBfClassVData@Player@Game@bf@@... -> Game_Player, the name of the object file its code is in."""
    found = re.match(r'^\?sBfClassVData@((?:[A-Za-z_][A-Za-z_0-9]*@)+)bf@@', symbol)
    return '_'.join(reversed(found.group(1).rstrip('@').split('@'))) if found else None


def windows_host(project, name):
    folder = project / 'build' / 'Debug_Win64' / name
    return folder / (name + '.exe'), folder / (name + '.map'), folder / (name + '__.lib')


def windows_snapshot(project, name, current):
    exe, link_map, library = windows_host(project, name)
    if not exe.is_file():
        raise ValueError(f'The project is not built: {exe}')
    if not link_map.is_file():
        raise ValueError('The project was linked without a map of its symbols. Add /MAP to the Debug Win64 link flags '
                         '(the editor does this for its own projects) and use File > Full Rebuild & Restart once.')
    preferred, symbols = read_map(link_map)
    _, size, _ = image_layout(exe)
    current['host'] = {symbol: address - preferred for symbol, address in symbols.items() if 0 <= address - preferred < size}
    current['host_size'] = size
    current['loaded'] = {}      # symbols of libraries loaded since, at the addresses they were loaded at
    current['state'] = {}
    for _, body in archive_members(library):
        current['state'].update(Coff(body).state())
    current['top'] = None       # where the next library ends; the running program says where the first one does
    return current


def host_info(path):
    """What the running program wrote about itself: where it is loaded, and the room it keeps for libraries."""
    values = {}
    for line in path.read_text().split('\n'):
        parts = line.split()
        if len(parts) == 2:
            values[parts[0]] = int(parts[1], 16)
    if not {'base', 'top', 'bottom'} <= values.keys():
        raise ValueError(f'The running program has not said where it is loaded ({path.name}).')
    return values


def windows_build(project, name, args, baseline, current, snapshot_seconds, reload_started):
    info = host_info(args.host_info or args.baseline.with_suffix('.host'))
    workspace = reload_workspace(project, 'windows')
    workspace.mkdir(parents=True, exist_ok=True)
    source = workspace / 'src'
    if cross():
        if not source.exists():
            source.symlink_to(project / 'src', target_is_directory=True)
    else:
        # Windows keeps links to folders for administrators, so keep a copy in step instead.
        wanted = {p.relative_to(project / 'src') for p in (project / 'src').rglob('*') if p.is_file()}
        if source.exists():
            for old in sorted(source.rglob('*'), reverse=True):
                if old.is_file() and old.relative_to(source) not in wanted:
                    old.unlink()
        for relative in wanted:
            target = source / relative
            original = project / 'src' / relative
            if not target.is_file() or target.stat().st_mtime_ns != original.stat().st_mtime_ns or target.stat().st_size != original.stat().st_size:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, target)
    config = tomllib.loads((project / 'BeefSpace.toml').read_text())
    entries = []
    for key, entry in config['Projects'].items():
        path = '.' if key == name else (entry['Path'] if re.match(r'^[A-Za-z]:', entry['Path']) else windows_path((project / entry['Path']).resolve()))
        entries.append(f'{key} = {{Path = {json.dumps(path)}}}')
    write_if_changed(workspace / 'BeefSpace.toml',
                     'FileVersion = 1\nProjects = {' + ', '.join(entries) + '}\n[Workspace]\nStartupProject = ' + json.dumps(name)
                     + '\n\n[Configs.Debug.Win64]\nToolset = "LLVM"\n')
    # The compiler is only wanted for its object files. Its own link is given what it needs to pass quickly.
    quick = '[Configs.Debug.Win64]\nBuildKind = "DynamicLib"\nCLibType = "Static"\nOtherLinkFlags = "/DLL /NOENTRY /FORCE /DEBUG:NONE /NODEFAULTLIB"\n'
    proj_text = (project / 'BeefProj.toml').read_text()
    proj_text, replaced = re.subn(r'\[Configs\.Debug\.Win64\]\n(?:[^\[\n][^\n]*\n|\n(?!\[))*', lambda _: quick + '\n', proj_text, count=1)
    if not replaced:
        proj_text += '\n' + quick
    write_if_changed(workspace / 'BeefProj.toml', proj_text)
    command, environment = beef_command(workspace)
    log = workspace / 'compiler.log'
    outputs_before = build_output_state(workspace, name, 'windows')
    compile_started = time.perf_counter()
    if os.environ.get('TALLOW_RELOAD_TRACE_COMPILER') == '1':
        command = [arg if not arg.startswith('-verbosity=') else '-verbosity=diagnostic' for arg in command]
    with open(log, 'w') as output:
        completed = subprocess.run(command, env=environment, stdout=output, stderr=subprocess.STDOUT)
    compile_seconds = time.perf_counter() - compile_started
    outputs_after = build_output_state(workspace, name, 'windows')
    print(f'Reload timings: source scan {snapshot_seconds:.2f}s, BeefBuild {compile_seconds:.2f}s', flush=True)
    print(f'Reload compiler cache: {workspace}', flush=True)
    print('BeefBuild outputs: ' + build_activity_label(
        build_output_activity(outputs_before, outputs_after)), flush=True)
    text = log.read_text(errors='replace')
    # The throwaway link reports everything it could not find, which is everything; only the compiler's word counts.
    shown = [line for line in text.split('\n') if line.strip() and not re.match(r'^(lld-link: warning|>>>|MESA|pci id|\s)', line)]
    if completed.returncode:
        print('\n'.join(shown).replace(str(source), str(project / 'src')).replace(windows_path(source), windows_path(project / 'src')), flush=True)
        return completed.returncode
    if current != snapshot(project):
        print('ERROR: Source declarations or resident code changed during compilation; build again.', flush=True)
        return 4

    root = workspace / 'build' / 'Debug_Win64' / name
    tokens = shlex.split((root / (name + '.dll.build.txt')).read_text().split('\n')[-1].replace('\\', '/'))
    libraries = [local_path(t) for t in tokens if t.endswith('__.lib')]
    game_library = root / (name + '__.lib')
    others = [p for p in libraries if p.resolve() != game_library.resolve()]
    vdata = Coff((root / 'vdata.obj').read_bytes(), 'vdata.obj')

    resident = set(baseline['host']) | set(baseline['loaded'])
    game_defined, state, force = set(), {}, set()
    for member, body in archive_members(game_library):
        obj = Coff(body, member)
        defined = obj.defined()
        game_defined |= defined.keys()
        state.update(obj.state())
        force.add(Path(member.replace('\\', '/')).stem)
        force |= {symbol[len('FORCELINKMOD_'):] for symbol in defined if symbol.startswith('FORCELINKMOD_')}
    shared = {symbol: size for symbol, size in state.items() if symbol in resident and size > 0 and not symbol.startswith('FORCELINKMOD_')}
    for symbol, size in shared.items():
        if baseline['state'].get(symbol, size) != size:
            raise ValueError('Static field layout changed; change its name or full rebuild: ' + symbol)

    vdata_defined = vdata.defined()
    classes = [symbol for symbol in vdata_defined if class_key(symbol) in force]
    if not classes:
        print('ERROR: No reloadable class metadata found.', flush=True)
        return 5
    # The library keeps its own copy of the description of every type that the program already has; the editor
    # works out afterwards which of its types are which of the program's.
    renames = {symbol: 'reload_private_' + symbol for symbol in vdata_defined if symbol in resident
               and (symbol.startswith('?sBfTypeData@') or (symbol.startswith('?sBfClassVData@') and symbol not in classes))}
    work = workspace / 'link'
    work.mkdir(exist_ok=True)
    metadata_object = work / 'vdata.obj'
    metadata_object.write_bytes(vdata.renamed(renames))
    # The program's own definition is used for everything it has, except what the scripts define afresh (their
    # code, and the tables in vdata), which is used from the library. Static fields the program already has
    # stay where they are, so their values carry over.
    mine = (game_defined - shared.keys()) | (vdata_defined.keys() - renames.keys()) | set(renames.values())

    def stand_in(pad):
        low = info['base'] - pad
        symbols = {}
        for symbol, offset in baseline['host'].items():
            if symbol not in mine and not symbol.startswith(PRIVATE_TO_IMAGE):
                symbols[symbol] = pad + offset
        for symbol, address in baseline['loaded'].items():
            if symbol not in mine and not symbol.startswith(PRIVATE_TO_IMAGE) and address >= low:
                symbols[symbol] = address - low
        write_stand_in(work / 'host.obj', pad + baseline['host_size'], symbols)

    module = project / '.tallow-reload' / f'scripts-{time.time_ns()}.dll'
    link_map = work / 'module.map'

    def link(base):
        command = [linker(), '/DLL', '/NOENTRY', '/NODEFAULTLIB', '/FORCE:MULTIPLE', '/FIXED', '/DYNAMICBASE:NO', '/OPT:NOREF', '/OPT:NOICF',
                   '/DEBUG:NONE', '/INCREMENTAL:NO', '/NOLOGO', f'/BASE:{base:#x}', f'/OUT:{module}', f'/MAP:{link_map}', str(work / 'host.obj'),
                   f'/WHOLEARCHIVE:{game_library}', str(metadata_object), *map(str, others)]
        done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
        if done.returncode or not module.is_file():
            # Everything the program has is defined twice on purpose; those lines only hide the real complaint.
            lines, skip = [], False
            for line in done.stdout.split('\n'):
                if 'duplicate symbol' in line:
                    skip = True
                    continue
                if skip and (line.startswith('>>>') or not line.strip()):
                    continue
                skip = False
                lines.append(line)
            raise ValueError('The script library did not link. Something it needs is in neither the scripts nor the running '
                             'program, so use File > Full Rebuild & Restart.\n' + '\n'.join(lines[:40]))

    def host_section():
        base, _, sections = image_layout(module)
        found = [s for s in sections if s[0] == HOST_SECTION]
        if len(found) != 1:
            raise ValueError('The linker did not keep the stand-in for the running program.')
        after = [s[0].decode('latin-1') for s in sections if s[1] > found[0][1] and not s[3] & 0x02000000]
        if after:
            raise ValueError('Sections the loader has no place for: ' + ', '.join(after))
        return base, found[0][1]

    # Once to see how much room the library takes, then for real, ending exactly where the room for it ends.
    stand_in(0)
    link(0x180000000)
    _, span = host_section()
    top = baseline['top'] or info['top']
    base = top - ((span + GRAIN - 1) & ~(GRAIN - 1))
    if base < info['bottom']:
        raise ValueError('The room kept for reloaded scripts is used up. Restart the editor (File > Full Rebuild & Restart).')
    stand_in(info['base'] - base - span)
    link(base)
    linked_base, linked_span = host_section()
    if linked_base != base or linked_span != span:
        raise ValueError('The script library changed size between two identical links.')

    _, placed = read_map(link_map)
    low, high = base, base + span
    needed = {'types': '?sTypes@Type@System@bf@@2PEAPEAV123@A', 'count': '?sTypeCount@Type@System@bf@@2HA'}
    for key, symbol in needed.items():
        if not low <= placed.get(symbol, 0) < high:
            raise ValueError('The script library has no type table of its own.')
    hooks = {'gettype': '?GetType@Type@System@bf@@KAPEAV123@VTypeId@Reflection@23@@Z', 'gettype_': '?GetType_@Type@System@bf@@KAPEAV123@H@Z'}
    lines = ['module ' + json.dumps(str(module) if cross() else str(module).replace('\\', '/')), 'mode structural',
             f'image {base:x} {span:x}']
    for key, symbol in needed.items():
        lines.append(f'{key} {placed[symbol]:x}')
    for key, symbol in hooks.items():
        if symbol not in baseline['host']:
            raise ValueError('The running program has no ' + symbol)
        lines.append(f'{key} {baseline["host"][symbol]:x}')
    for symbol in classes:
        if not low <= placed.get(symbol, 0) < high:
            raise ValueError('Script class left out of the library: ' + symbol)
        lines.append(f'class {symbol} {placed[symbol]:x}')
    manifest = args.manifest.resolve()
    manifest.parent.mkdir(parents=True, exist_ok=True)
    # What a later reload needs to know about this one, if it is taken up.
    Path(str(manifest) + '.json').write_text(json.dumps({
        'top': base, 'state': state, 'schemas': current['schemas'], 'code': current['code'],
        'normalized_code': current['normalized_code'],
        'loaded': {symbol: address for symbol, address in placed.items()
                   if low <= address < high and not symbol.startswith(PRIVATE_TO_IMAGE) and not symbol.startswith('reload_private_')}}))
    temporary = manifest.with_suffix('.tmp')
    temporary.write_text('\n'.join(lines) + '\n')
    temporary.replace(manifest)
    print(f'Compiled script library: {module}. Engine implementations remain in the host.', flush=True)
    total_seconds = time.perf_counter() - reload_started
    print(f'Reload total: {total_seconds:.2f}s '
          f'(BeefBuild {compile_seconds:.2f}s, other stages '
          f'{total_seconds - compile_seconds:.2f}s)', flush=True)
    return 0


def windows_commit(args, baseline):
    record = json.loads(Path(str(args.manifest.resolve()) + '.json').read_text())
    baseline['loaded'].update(record['loaded'])
    baseline['state'].update(record['state'])
    baseline['schemas'] = record['schemas']
    baseline['code'] = record['code']
    baseline['normalized_code'] = record['normalized_code']
    baseline['top'] = record['top']
    args.baseline.write_text(json.dumps(baseline))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', type=Path)
    parser.add_argument('--snapshot', action='store_true')
    parser.add_argument('--classify', action='store_true',
                        help='Exit 0 unchanged, 10 method-only, 11 declarations, 3 incompatible resident code.')
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--commit', action='store_true', help='Record symbols of an activated generation.')
    parser.add_argument('--mode', choices=('automatic', 'conservative'), default='automatic',
                        help='Automatic uses lightweight method patching for compatible Linux edits.')
    parser.add_argument('--platform', choices=('linux', 'windows'), default='windows' if os.name == 'nt' else 'linux')
    parser.add_argument('--host-info', type=Path, help='Windows: the file the running program wrote about where it is loaded (default: the baseline with .host).')
    args = parser.parse_args()
    if os.name != 'nt':
        # Started by a Windows editor running under Wine: its paths are Z:\\..., this system's are not.
        for key in ('project', 'baseline', 'manifest', 'host_info'):
            value = getattr(args, key)
            if value is not None and re.match(r'^[zZ]:[\\/]', str(value)):
                setattr(args, key, Path(str(value)[2:].replace('\\', '/')))
                args.platform = 'windows'
    project = args.project.resolve()
    reload_started = time.perf_counter()
    current = snapshot(project)
    snapshot_seconds = time.perf_counter() - reload_started
    if args.classify:
        baseline = json.loads(args.baseline.read_text())
        return classify_changes(baseline, current)
    if args.platform == 'windows':
        name = tomllib.loads((project / 'BeefProj.toml').read_text())['Project']['Name']
        if args.commit:
            return windows_commit(args, json.loads(args.baseline.read_text()))
        if args.snapshot:
            args.baseline.parent.mkdir(parents=True, exist_ok=True)
            args.baseline.write_text(json.dumps(windows_snapshot(project, name, current)))
            return 0
        baseline = json.loads(args.baseline.read_text())
        if baseline['resident'] != current['resident']:
            print('ERROR: Engine, editor, build configuration or resident library changed. Use File > Full Rebuild & Restart.', flush=True)
            return 3
        if args.manifest is None:
            parser.error('--manifest is required for builds')
        return windows_build(project, name, args, baseline, current, snapshot_seconds, reload_started)
    if args.commit:
        baseline = json.loads(args.baseline.read_text())
        module = Path(json.loads(args.manifest.read_text().splitlines()[0].removeprefix('module ')))
        built = json.loads(Path(str(args.manifest) + '.source.json').read_text())
        baseline['exports'].update(exported_symbols(module))
        baseline['schemas'] = built['schemas']
        baseline['code'] = built['code']
        baseline['normalized_code'] = built['normalized_code']
        if 'mode structural' in args.manifest.read_text():
            baseline['method_patch_eligible'] = False
        args.baseline.write_text(json.dumps(baseline))
        return 0
    if args.snapshot:
        args.baseline.parent.mkdir(parents=True, exist_ok=True)
        name = tomllib.loads((project / 'BeefProj.toml').read_text())['Project']['Name']
        host = project / 'build' / 'Debug_Linux64' / name / name
        current['exports'] = exported_symbols(host)
        args.baseline.write_text(json.dumps(current))
        return 0
    baseline = json.loads(args.baseline.read_text())
    if baseline['resident'] != current['resident']:
        print('ERROR: Engine, editor, build configuration or resident library changed. Use File > Full Rebuild & Restart.', flush=True)
        return 3
    if args.manifest is None:
        parser.error('--manifest is required for builds')
    name = tomllib.loads((project / 'BeefProj.toml').read_text())['Project']['Name']
    strategy = reload_strategy(args.mode, baseline, current, 'linux')
    print(f'Reload strategy: {strategy}', flush=True)
    workspace = reload_workspace(project, 'linux')
    workspace.mkdir(parents=True, exist_ok=True)
    source = workspace / 'src'
    if not source.exists():
        source.symlink_to(project / 'src', target_is_directory=True)
    config = tomllib.loads((project / 'BeefSpace.toml').read_text())
    entries = []
    for key, entry in config['Projects'].items():
        path = '.' if key == name else str((project / entry['Path']).resolve())
        entries.append(f'{key} = {{Path = {json.dumps(path)}}}')
    write_if_changed(workspace / 'BeefSpace.toml',
                     'FileVersion = 1\nProjects = {' + ', '.join(entries) + '}\n[Workspace]\nStartupProject = ' + json.dumps(name) + '\n')
    proj_text = (project / 'BeefProj.toml').read_text()
    proj_text = proj_text.replace('[Configs.Debug.Linux64]', '[Configs.Debug.Linux64]\nBuildKind = "DynamicLib"', 1)
    write_if_changed(workspace / 'BeefProj.toml', proj_text)
    outputs_before = build_output_state(workspace, name, 'linux')
    compile_started = time.perf_counter()
    verbosity = 'diagnostic' if os.environ.get('TALLOW_RELOAD_TRACE_COMPILER') == '1' else 'minimal'
    completed = subprocess.run([os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={workspace}',
                                '-config=Debug', f'-verbosity={verbosity}'])
    compile_seconds = time.perf_counter() - compile_started
    outputs_after = build_output_state(workspace, name, 'linux')
    print(f'Reload timings: source scan {snapshot_seconds:.2f}s, BeefBuild {compile_seconds:.2f}s', flush=True)
    print(f'Reload compiler cache: {workspace}', flush=True)
    print('BeefBuild outputs: ' + build_activity_label(
        build_output_activity(outputs_before, outputs_after)), flush=True)
    if completed.returncode:
        return completed.returncode
    # A save during compilation must never activate a stale or mixed revision.
    if current != snapshot(project):
        print('ERROR: Source declarations or resident code changed during compilation; build again.', flush=True)
        return 4
    object_stage_started = time.perf_counter()
    root = workspace / 'build' / 'Debug_Linux64' / name
    tokens = shlex.split((root / 'ObjectArgs.txt').read_text())
    objects = [Path(p) for p in tokens if p.endswith('.o') and Path(p).name != 'vdata.o']
    game_objects = [p for p in objects if p.parent == root]
    vdata = root / 'vdata.o'
    force, state = symbols(game_objects)
    force.update(obj.stem for obj in game_objects)
    _, metadata = symbols([vdata])
    classes = []
    class_symbols = [(symbol, size) for symbol, size in metadata.items()
                     if symbol.endswith('13sBfClassVDataE')]
    # Demangle all class names in one process instead of launching c++filt per class.
    if class_symbols:
        names = subprocess.run(['c++filt'], input='\n'.join(symbol for symbol, _ in class_symbols) + '\n',
                               text=True, stdout=subprocess.PIPE, check=True).stdout.splitlines()
        for (symbol, size), demangled in zip(class_symbols, names):
            key = demangled.removeprefix('bf::').removesuffix('::sBfClassVData').replace('::', '_')
            if key in force:
                classes.append((symbol, size))
    if not classes:
        print('ERROR: No reloadable class metadata found.', flush=True)
        return 5
    module = project / '.tallow-reload' / f'scripts-{time.time_ns()}.so'
    resident = baseline['exports']
    shared = {symbol: size for symbol, size in state.items() if symbol in resident and size > 0 and not symbol.startswith('FORCELINKMOD_')}
    for symbol, size in shared.items():
        if resident[symbol] != size:
            raise ValueError('Static field layout changed; change its name or full rebuild: ' + symbol)
    objects_scanned_seconds = time.perf_counter() - object_stage_started
    aliases = workspace / 'aliased-objects'
    # Existing runtime functions/data stay in the host. New generic implementations
    # emitted for game code can be included without duplicating engine state.
    alias_started = time.perf_counter()
    linked_objects, reused, reuse_reasons = alias_objects(objects, game_objects, aliases, resident, shared)
    game_links, dependency_links = partition_link_objects(objects, linked_objects, game_objects)
    alias_seconds = time.perf_counter() - alias_started
    renamed = {symbol: 'reload_private_' + symbol for symbol in metadata
               if symbol in resident and (symbol.endswith('11sBfTypeDataE')
                   or (symbol.endswith('13sBfClassVDataE') and symbol not in {s for s, _ in classes}))}
    # nm's data list excludes read-only metadata on some toolchains.
    for symbol in exported_symbols(vdata):
        if symbol in resident and symbol.endswith('11sBfTypeDataE'):
            renamed[symbol] = 'reload_private_' + symbol
    mapping = aliases / 'metadata-renames.txt'
    mapping.write_text(''.join(f'{a} {b}\n' for a, b in renamed.items()))
    metadata_object = aliases / 'vdata.o'
    link_started = time.perf_counter()
    subprocess.run(['objcopy', '--redefine-syms=' + str(mapping), str(vdata), str(metadata_object)], check=True)
    archive_started = time.perf_counter()
    archive_failed = False
    try:
        dependency_archive, archive_reused = cached_dependency_archive(
            dependency_links, aliases / 'resident-dependencies.a')
    except (OSError, subprocess.CalledProcessError) as error:
        # A missing archiver or unsupported dependency object must not prevent
        # Play. The original full-object linker remains an operational fallback.
        print(f'WARNING: Dependency archive unavailable ({error}); using the full-object linker.', flush=True)
        dependency_archive, archive_reused, archive_failed = None, False, True
    archive_seconds = time.perf_counter() - archive_started
    # Game implementations and complete type metadata are mandatory. Resident
    # dependencies are indexed, so ld extracts only genuinely missing code.
    full_link = ['c++', '-shared', '-Wl,-Bsymbolic', '-o', str(module),
                 *map(str, linked_objects), str(metadata_object)]
    fast_link = ['c++', '-shared', '-Wl,-Bsymbolic', '-o', str(module),
                 *map(str, game_links), str(metadata_object)]
    if dependency_archive is not None:
        fast_link.append(str(dependency_archive))
    fallback = False
    if archive_failed or os.environ.get('TALLOW_RELOAD_FLAT_LINK') == '1':
        fallback = True
        subprocess.run(full_link, check=True)
    else:
        try:
            subprocess.run(fast_link, check=True)
        except subprocess.CalledProcessError:
            print('WARNING: Archive link failed; retrying the full-object linker.', flush=True)
            fallback = True
            subprocess.run(full_link, check=True)
    link_seconds = time.perf_counter() - link_started
    lines = ['module ' + json.dumps(str(module)), 'mode ' + strategy]
    lines += [f'class {symbol} {size}' for symbol, size in classes]
    # The method patcher copies mutable state from the current module, while
    # structural reload uses its own shared-state migration implementation.
    field = 'state' if strategy == 'methods' else 'shared'
    lines += [f'{field} {symbol} {size}' for symbol, size in shared.items()]
    manifest = args.manifest.resolve()
    manifest.parent.mkdir(parents=True, exist_ok=True)
    temporary = manifest.with_suffix('.tmp')
    temporary.write_text('\n'.join(lines) + '\n')
    temporary.replace(manifest)
    Path(str(manifest) + '.source.json').write_text(json.dumps({
        'schemas': current['schemas'], 'code': current['code'],
        'normalized_code': current['normalized_code']}))
    total_seconds = time.perf_counter() - reload_started
    print(f'Compiled script library: {module}. Engine implementations remain in the host.', flush=True)
    print(f'Reload total: {total_seconds:.2f}s '
          f'(BeefBuild {compile_seconds:.2f}s, other stages {total_seconds - compile_seconds:.2f}s)', flush=True)
    print(f'Reload stages: inspect objects {objects_scanned_seconds:.2f}s, '
          f'prepare objects {alias_seconds:.2f}s ({reused}/{len(objects)} reused), '
          f'link {link_seconds:.2f}s (archive {archive_seconds:.2f}s)', flush=True)
    print(f'Reload link inputs: game {len(game_links)}, dependencies {len(dependency_links)}, '
          f'archive reused {archive_reused}, flat fallback {fallback}', flush=True)
    print(f'Reload object cache: cold/missing {reuse_reasons["cold"]}, '
          f'object changed {reuse_reasons["changed"]}, '
          f'relevant host symbols changed {reuse_reasons["symbols"]}', flush=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f'ERROR: Script library build failed: {error}', flush=True)
        sys.exit(1)
