#!/usr/bin/env python3
"""Private symbols and build identifiers for release exports (roadmap B30, "stripped binaries").

A Release export ships a player with no debug information. The matching symbols (Linux .dbg, Windows .pdb),
a map file and a build record naming every module's exact identifier go to `<output>-symbols/` beside the build,
never inside it. tools/test_csharp_crash.py crashes such a build on purpose and reads the crash with those symbols.

Two identifiers matter for a crash:
  Linux  ELF: the GNU build ID (readelf -n) plus the .gnu_debuglink name and CRC (objcopy writes it), and the
         SHA-256 of the shipped file.
  Windows PE: the PDB GUID and age in the image's debug directory (what a crash tool matches a .pdb by), plus the
         SHA-256 of the shipped file. The .pdb itself stays here, private.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess


def symbols_folder(output: Path) -> Path:
    """Where a build's private symbols and build record go: beside the build folder, never inside it."""
    return output.parent / (output.name + '-symbols')


def digest(path: Path) -> str:
    sha = hashlib.sha256()
    with open(path, 'rb') as file:
        while chunk := file.read(1 << 20):
            sha.update(chunk)
    return sha.hexdigest()


def elf_build_id(path: Path) -> str:
    """The GNU build ID of an ELF file (linker and Beef both write one), or an empty string."""
    readelf = shutil.which('readelf')
    if not readelf:
        return ''
    result = subprocess.run([readelf, '-n', str(path)], capture_output=True, text=True)
    match = re.search(r'Build ID: ([0-9a-fA-F]+)', result.stdout)
    return match.group(1).lower() if match else ''


def pe_debug_id(path: Path) -> str:
    """The PE debug identifier a .pdb is matched by: the CodeView GUID and age, as `GUID age`."""
    readobj = shutil.which('llvm-readobj') or shutil.which('llvm-readobj-18') or shutil.which('llvm-readobj-19')
    if not readobj:
        return ''
    result = subprocess.run([readobj, '--coff-debug-directory', str(path)], capture_output=True, text=True)
    guid = re.search(r'PDBGUID: \{([0-9A-Fa-f-]+)\}', result.stdout)
    age = re.search(r'PDBAge: (0x[0-9A-Fa-f]+|\d+)', result.stdout)
    if not guid:
        return ''
    return f'{guid.group(1).lower()} {int(age.group(1), 0) if age else 0}'


def strip_release_player(executable: Path, symbols: Path, windows: bool, source: Path | None = None) -> None:
    """Take a Release player's debug information out of the package and keep it (and a Windows .pdb) in `symbols`.
    A missing objcopy only warns: the export carries on, without symbols for the player."""
    symbols.mkdir(parents=True, exist_ok=True)
    if windows:
        # A COFF image keeps nothing itself; the linker's .pdb is the symbols. It sits beside the player Beef built.
        if source is None:
            print('note: the Windows player\'s source folder is unknown, so no .pdb was kept.')
            return
        candidates = [source.with_name(source.stem + '_lld.pdb'), *sorted(source.parent.glob('*.pdb'))]
        for candidate in candidates:
            if candidate.is_file():
                shutil.copy2(candidate, symbols / candidate.name)
                return
        print(f'note: no .pdb was found beside {source}; a crash of this build cannot be read.')
        return
    objcopy = shutil.which('objcopy')
    if not objcopy:
        print('note: objcopy (binutils) is missing; the player keeps its debug information in the package.')
        return
    debug_file = symbols / (executable.name + '.dbg')
    subprocess.run([objcopy, '--only-keep-debug', str(executable), str(debug_file)], check=True)
    if debug_file.stat().st_size < 4096:
        # The player was already stripped (a packaged engine can ship one): there is nothing to keep.
        debug_file.unlink()
        print(f'note: {executable.name} carries no debug information, so no .dbg was kept for it. '
              'Build Player/ with debug info to get crash symbols.')
        return
    before = executable.stat().st_size
    subprocess.run([objcopy, '--strip-debug', str(executable)], check=True)
    # What a debugger follows from the shipped file to the private one (the CRC is of the .dbg).
    subprocess.run([objcopy, f'--add-gnu-debuglink={debug_file}', str(executable)], check=True)
    after = executable.stat().st_size
    print(f'Player: stripped of debug information ({before // (1024 * 1024)} MB -> {after // (1024 * 1024)} MB); '
          f'symbols in {debug_file}')


def write_map(symbols: Path, binary: Path) -> Path | None:
    """A name map for crash addresses read without a debugger: code symbols only (a stack never lands in data),
    address sorted, demangled, in the `nm` BSD format (address, type, name)."""
    nm = shutil.which('llvm-nm') or shutil.which('nm')
    if not nm:
        return None
    result = subprocess.run([nm, '--defined-only', '--numeric-sort', '--demangle', str(binary)],
                            capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        return None
    kept = [line for line in result.stdout.splitlines()
            # t/T: code, w/W: weak code (a plain line has no type when the format differs; keep those too).
            if len(parts := line.split(None, 2)) < 2 or len(parts[1]) != 1 or parts[1] in 'tTwW']
    if not kept:
        return None
    target = symbols / (binary.name + '.map')
    target.write_text('\n'.join(kept) + '\n', encoding='utf-8')
    return target


def write_build_info(output: Path, symbols: Path, engine: Path, project: str, config: str, platform_name: str,
                     runtime: str, code_id: str | None, library: Path | None, player: Path) -> Path:
    """The private record of a build: each shipped module's exact identifier, the symbol files kept for it and,
    for NativeAOT, a map of the game library. Matches a crash to these files; never shipped."""
    lines = [
        '# Tallow build information. Private: kept beside the build, never shipped in it.',
        f'project: {project}',
        f'config: {config}',
        f'platform: {platform_name}',
        f'runtime: {runtime}',
        f'engine commit: {engine_commit(engine)}',
        f'game code id: {code_id or "(none)"}',
    ]
    windows = platform_name == 'windows'
    def module(title: str, path: Path) -> list[str]:
        rows = [f'{title}: {path.name}',
                f'{title} sha256: {digest(path)}',
                f'{title} size: {path.stat().st_size}']
        identifier = pe_debug_id(path) if windows else elf_build_id(path)
        if identifier:
            rows.append(f'{title} {"pdb id" if windows else "build id"}: {identifier}')
        return rows
    lines += module('player', player)
    if library is not None and library.is_file():
        lines += module('game library', library)
    lines += ['', 'symbols kept here (private):']
    for file in sorted(symbols.iterdir()):
        if file.is_file() and file.name != 'build-info.txt' and file.suffix in ('.dbg', '.pdb', '.map'):
            lines.append(f'  {file.name} sha256 {digest(file)} ({file.stat().st_size} bytes)')
    text = '\n'.join(lines) + '\n'
    target = symbols / 'build-info.txt'
    target.write_text(text, encoding='utf-8')
    return target


def engine_commit(engine: Path) -> str:
    try:
        result = subprocess.run(['git', '-C', str(engine), 'rev-parse', '--short=12', 'HEAD'],
                                capture_output=True, text=True)
        commit = result.stdout.strip()
        branch = subprocess.run(['git', '-C', str(engine), 'rev-parse', '--abbrev-ref', 'HEAD'],
                                capture_output=True, text=True).stdout.strip()
        return f'{branch} @ {commit}' if result.returncode == 0 and commit else '(not a git checkout)'
    except OSError:
        return '(not a git checkout)'
