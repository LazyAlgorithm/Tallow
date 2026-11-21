#!/usr/bin/env python3
"""NativeAOT export of a C# game (tools/build_player.py --csharp-runtime native).

Tallow's managed runtime, Tallow.API and the game's assemblies (already compiled by Tallow.Build into
build/csharp/<config>) are compiled ahead of time into ONE native library: Managed/Native/libTallowGame.so on Linux,
Managed/Native/TallowGame.dll on Windows. The precompiled player loads it instead of starting .NET
(CSharpRuntime.StartPackagedGame -> tn_csharp_init_native). The package then holds no .NET runtime, no IL assemblies
and no game source; native symbols (.dbg / .pdb) go to a private folder beside the build, never into it.

The game code is the same as a JIT export's: the same compiled assemblies, the same generated registry, the same
entrypoint table (NativeEntrypoints.Table) behind one generated export, tallow_native_register.

A Windows library is built here on Linux too: ILCompiler targets Windows and lld-link links it against the Windows
SDK and CRT that tools/windows/setup.sh downloads (xwin, in TALLOW_WIN), so no Windows machine or Wine is needed.

    python3 tools/csharp_native.py check            # can this machine build NativeAOT exports? (Linux, Windows)
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)

DOTNET_MAJOR = 11
# Trim/AOT analysis warnings that point at real problems in a NativeAOT game (IL2026: code that needs unreferenced
# metadata, IL2070-IL2075/IL2080/IL2090: reflection the trimmer cannot see through, IL3050/IL3051: code generated at
# run time). They are listed in the build's report; tools/test_csharp_export.py --runtime native runs the game's
# checks on the result.
ANALYSIS = re.compile(r'warning (IL[23]\d{3}):\s*(.*?)(?: \[[^\]]*\])?$')
ALLOWLIST = Path(__file__).resolve().parent / 'nativeaot_allowlist.txt'
FRAMEWORK = ('System.', 'Microsoft.', 'Internal.', 'Interop.', 'ILCompiler.')


def allowlist() -> list[tuple[set[str] | None, str, str]]:
    """The engine warnings the export accepts: (codes or None for any, origin, reason)."""
    entries = []
    for line in ALLOWLIST.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        codes, origin, *reason = line.split(None, 2)
        entries.append((None if codes == '*' else set(codes.split(',')), origin, reason[0].strip() if reason else ''))
    return entries


def origin_of(message: str) -> str:
    """The method a warning comes from: 'Ns.Type.Method(Args): text' -> 'Ns.Type.Method'."""
    ends = [i for i in (message.find('('), message.find(': ')) if i > 0]
    return message[:min(ends)] if ends else message


def allowed(code: str, origin: str, entries) -> bool:
    for codes, key, _ in entries:
        if codes is not None and code not in codes:
            continue
        if origin == key or origin.startswith(key + '.') or (key.endswith('>') and origin.startswith(key)):
            return True
    return False


def game_namespaces(project: Path) -> tuple[set[str], set[str]]:
    """Namespaces the game's own C# declares (src/, editor scripts left out), and its types outside any namespace."""
    namespaces: set[str] = set()
    global_types: set[str] = set()
    for source in (project / 'src').rglob('*.cs'):
        if 'Editor' in source.relative_to(project / 'src').parts[:-1]:
            continue
        text = source.read_text(encoding='utf-8', errors='replace')
        declared = re.findall(r'^\s*namespace\s+([A-Za-z_][\w.]*)', text, re.M)
        namespaces.update(declared)
        if not declared:
            global_types.update(re.findall(r'\b(?:class|struct|record|interface)\s+([A-Za-z_]\w*)', text))
    return namespaces, global_types


def classify(warnings: list[str], project: Path) -> dict[str, list[str]]:
    """Sorts warnings into game (fail), engine (allowlisted or fail), and packages/.NET (reported)."""
    namespaces, global_types = game_namespaces(project)
    entries = allowlist()
    groups: dict[str, list[str]] = {'game': [], 'engine-unreviewed': [], 'engine-allowed': [], 'packages': [], 'dotnet': []}
    for warning in warnings:
        code, _, message = warning.partition(': ')
        origin = origin_of(message)
        if any(origin == ns or origin.startswith(ns + '.') for ns in namespaces) or origin.split('.')[0] in global_types:
            groups['game'].append(warning)
        elif origin.startswith('Tallow.'):
            groups['engine-allowed' if allowed(code, origin, entries) else 'engine-unreviewed'].append(warning)
        elif origin.startswith(FRAMEWORK):
            groups['dotnet'].append(warning)
        else:
            groups['packages'].append(warning)
    return groups


GAME_HELP = """These are in the game's own code and can break it in a NativeAOT build (code made at run time, or
members trimming removes). Change the code (avoid MakeGenericType/MakeGenericMethod, Activator on types found by name,
Type.GetType of strings), or, if you have checked it works when exported as NativeAOT, keep it with
  [System.Diagnostics.CodeAnalysis.UnconditionalSuppressMessage("AOT", "<code>", Justification = "<why it is safe>")]
on the method. Or export with the JIT runtime (Build window: JIT; tools/build_player.py --csharp-runtime jit)."""


def library_name(windows: bool) -> str:
    return 'TallowGame.dll' if windows else 'libTallowGame.so'


def windows_toolchain() -> Path:
    return Path(os.environ.get('TALLOW_WIN', Path.home() / '.local/share/tallow-win'))


def windows_link_setup(cache: Path) -> tuple[dict[str, str], list[str]]:
    """Environment and MSBuild properties for linking a win-x64 NativeAOT library on Linux with lld-link and the
    xwin Windows SDK + CRT. xwin stores library names in lower case; the ILCompiler names one with capitals."""
    toolchain = windows_toolchain()
    xwin = toolchain / 'xwin'
    linker = toolchain / 'bin' / 'lld-link'
    if not linker.is_file():
        linker = Path(shutil.which('lld-link') or '')
    if not (xwin / 'sdk' / 'lib' / 'um' / 'x86_64').is_dir() or not linker.is_file():
        raise SystemExit(f'A Windows NativeAOT build on Linux needs lld-link and the Windows SDK in {toolchain} '
                         f'(xwin). Run tools/windows/setup.sh once, or set TALLOW_WIN to where they are.')
    aliases = cache / 'winlibs'
    aliases.mkdir(parents=True, exist_ok=True)
    for name in ('Synchronization.lib',):
        target = xwin / 'sdk' / 'lib' / 'um' / 'x86_64' / name.lower()
        alias = aliases / name
        if target.is_file() and not alias.exists():
            alias.symlink_to(target)
    folders = [aliases, xwin / 'crt' / 'lib' / 'x86_64', xwin / 'sdk' / 'lib' / 'um' / 'x86_64', xwin / 'sdk' / 'lib' / 'ucrt' / 'x86_64']
    env = {'LIB': ';'.join(str(folder) for folder in folders)}
    properties = ['-p:DisableUnsupportedError=true', '-p:IlcUseEnvironmentalTools=true',
                  # lld-link has no /SOURCELINK.
                  '-p:EnableSourceLink=false', f'-p:CppLinker={linker}']
    return env, properties


def wine_link_setup(cache: Path, work: Path) -> tuple[Path, dict[str, str]] | None:
    """The Windows lld-link Beef's toolchain carries, run under Wine, for a Linux lld that crashes building the
    Windows PDB (lld 22.1.8 segfaults in its GSI hash writer for a large symbol set; lld 22.1.0 links it). Returns
    the wrapper to pass as CppLinker and the environment it needs, or None when Wine or that linker is missing."""
    toolchain = windows_toolchain()
    linker = toolchain / 'beef' / 'bin' / 'llvm' / 'bin' / 'lld-link.exe'
    if not linker.is_file() or not shutil.which('wine'):
        return None
    wrapper = work / 'lld-link-wine'
    wrapper.write_text(
        '#!/bin/sh\n'
        # lld-link opens the response file before handling the paths inside it.
        'for argument do\n'
        '    shift\n'
        '    case "$argument" in @/*) argument="@Z:${argument#@}" ;; esac\n'
        '    set -- "$@" "$argument"\n'
        'done\n'
        f'exec wine {shlex.quote(str(linker))} "$@"\n',
        encoding='utf-8',
    )
    wrapper.chmod(0o755)
    xwin = toolchain / 'xwin'
    folders = [cache / 'winlibs', xwin / 'crt' / 'lib' / 'x86_64', xwin / 'sdk' / 'lib' / 'um' / 'x86_64',
               xwin / 'sdk' / 'lib' / 'ucrt' / 'x86_64']
    # Wine reads a Unix path as Z:\...; the response file's own absolute paths work as they are.
    return wrapper, {'LIB': ';'.join('Z:' + str(folder).replace('/', '\\') for folder in folders),
                     'WINEPREFIX': str(toolchain / 'wine'), 'WINEDEBUG': '-all'}


def game_assemblies(project: Path, config: str) -> list[Path]:
    """The game's own compiled assemblies (Tallow.Game, its .tasmdef assemblies and NuGet packages), not Tallow's."""
    built = project / 'build' / 'csharp' / config
    result: list[Path] = []
    for folder in sorted(built.iterdir()) if built.is_dir() else []:
        for dll in sorted(folder.glob('*.dll')):
            if dll.stem not in ('Tallow.API', 'Tallow.ManagedRuntime') and dll.name not in (path.name for path in result):
                result.append(dll)
    if not any(path.name == 'Tallow.Game.dll' for path in result):
        raise SystemExit(f"The game's C# is not built ({built}/Tallow.Game/Tallow.Game.dll is missing).")
    return result


EXPORTS = '''// Generated by tools/csharp_native.py: the one export of a NativeAOT game library.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

public static unsafe class TallowNativeExports
{
    [UnmanagedCallersOnly(EntryPoint = "tallow_native_register", CallConvs = [typeof(CallConvCdecl)])]
    public static int Register(delegate* unmanaged[Cdecl]<byte*, nint, int> register, int hostAbi, byte* error, int errorCapacity) =>
        global::Tallow.ManagedRuntime.NativeHost.Register(register, hostAbi,
            new global::Tallow.Generated.TallowGeneratedGameRegistry(), error, errorCapacity);
}
'''


def project_file(engine: Path, assemblies: list[Path]) -> str:
    x = lambda text: str(text).replace('&', '&amp;').replace('"', '&quot;').replace('<', '&lt;')
    references = ''.join(f'    <Reference Include="{x(dll.stem)}"><HintPath>{x(dll)}</HintPath></Reference>\n'
                         f'    <TrimmerRootAssembly Include="{x(dll.stem)}" />\n' for dll in assemblies)
    return f'''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net{DOTNET_MAJOR}.0</TargetFramework>
    <OutputType>Library</OutputType>
    <AssemblyName>TallowGame</AssemblyName>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <Nullable>enable</Nullable>
    <PublishAot>true</PublishAot>
    <NativeLib>Shared</NativeLib>
    <!-- Native symbols are made (and kept out of the package by csharp_native.py). -->
    <NativeDebugSymbols>true</NativeDebugSymbols>
    <StripSymbols>true</StripSymbols>
    <!-- Exception reports keep their method names and source lines (as on .NET). -->
    <StackTraceSupport>true</StackTraceSupport>
    <!-- Every warning of the trim/AOT analysis is shown, one by one, so the build's report can list them. -->
    <TrimmerSingleWarn>false</TrimmerSingleWarn>
    <SuppressTrimAnalysisWarnings>false</SuppressTrimAnalysisWarnings>
    <!-- No IlcInstructionSet: the library runs on every x64 CPU the JIT export runs on, with the same float maths. -->
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="{x(engine / 'Managed' / 'Tallow.ManagedRuntime' / 'Tallow.ManagedRuntime.csproj')}" />
    <!-- Kept whole: the runtime reads the game's fields, [Rpc] methods and callbacks by reflection. -->
    <TrimmerRootAssembly Include="Tallow.ManagedRuntime" />
    <TrimmerRootAssembly Include="Tallow.API" />
{references}  </ItemGroup>
</Project>
'''


def build(engine: Path, project: Path, config: str, staging: Path, windows: bool, symbols: Path,
          warnings_mode: str = 'error') -> list[str]:
    """Compiles the NativeAOT library into staging/Managed/Native and its native symbols into `symbols`.
    Returns the trim/AOT analysis warnings (code, message). With warnings_mode 'error' (the default), a warning in
    the game's own code, or an engine warning not in tools/nativeaot_allowlist.txt, fails the export (after the
    report is written); 'report' only lists them."""
    if windows and os.name != 'nt' and not sys.platform.startswith('linux'):
        raise SystemExit('A Windows NativeAOT library is built on Linux or Windows.')
    rid = 'win-x64' if windows else 'linux-x64'
    assemblies = game_assemblies(project, config)
    cache = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'tallow' / 'nativeaot'
    env = dict(os.environ, DOTNET_NOLOGO='1')
    properties: list[str] = []
    if windows and os.name != 'nt':
        extra, properties = windows_link_setup(cache)
        env.update(extra)
    with tempfile.TemporaryDirectory(prefix='tallow-native-') as temporary:
        work = Path(temporary)
        (work / 'TallowGame.csproj').write_text(project_file(engine, assemblies), encoding='utf-8')
        (work / 'Exports.cs').write_text(EXPORTS, encoding='utf-8')
        published = work / 'out'
        print(f'Compiling the game to native code ({rid}, NativeAOT)...')
        retry = [p for p in properties if not p.startswith('-p:CppLinker=')]
        first_output = ''
        # Keep the API/runtime PDBs and restore files private to this publish while other projects build.
        command = ['dotnet', 'publish', str(work / 'TallowGame.csproj'), '-c', config, '-r', rid,
                   '-o', str(published), '--artifacts-path', str(work / 'artifacts'), '--nologo', '-v', 'minimal']
        result = subprocess.run([*command, *properties], env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True)
        if (result.returncode != 0 and windows and os.name != 'nt' and
                ('exited with code 139' in result.stdout or 'Segmentation fault' in result.stdout)):
            # A crash in the linker itself, not the game: the Linux lld's Windows PDB writer segfaults on a large
            # symbol set (22.1.8); the Windows lld Beef's toolchain carries links the same input.
            fallback = wine_link_setup(cache, work)
            if fallback is not None:
                wrapper, extra = fallback
                print('note: lld-link crashed; linking again with the toolchain\'s lld-link under Wine.')
                first_output = result.stdout
                result = subprocess.run([*command, *retry, f'-p:CppLinker={wrapper}'],
                                        env=dict(env, **extra), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # The retry reuses ILCompiler's cache, so its output has no analysis warnings: read both runs'.
        warning_text = first_output + '\n' + result.stdout
        warnings: list[str] = []
        for line in warning_text.splitlines():
            match = ANALYSIS.search(line)
            if match:
                entry = f'{match.group(1)}: {match.group(2).strip()}'
                if entry not in warnings:
                    warnings.append(entry)
        library = published / library_name(windows)
        if result.returncode != 0 or not library.is_file():
            problems = [line for line in result.stdout.splitlines() if ' error ' in line or 'error:' in line]
            hint = ''
            if 'linker' in result.stdout.lower() and 'not found' in result.stdout.lower():
                hint = ('\n\nNativeAOT links with the system\'s C/C++ tools: on Windows, Visual Studio (or its Build Tools) with '
                        '"Desktop development with C++"; on Linux, clang (or gcc) and zlib\'s development files. '
                        'Install them, or export with the JIT runtime (Build window: JIT; --csharp-runtime jit).')
            raise SystemExit('The NativeAOT build failed:\n' + '\n'.join(problems[-30:] or result.stdout.splitlines()[-40:]) + hint)
        target = staging / 'Managed' / 'Native'
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(library, target / library.name)
        if not windows:
            (target / library.name).chmod(0o755)
        # Which code this is (network sessions compare it; see CSharpNetReload).
        code_id = project / 'build' / 'csharp' / config / 'Tallow.Game' / 'Tallow.Game.codeid'
        if code_id.is_file():
            shutil.copy2(code_id, target / code_id.name)
        notices = project / 'build' / 'csharp' / config / 'THIRD-PARTY-NOTICES.txt'
        if notices.is_file():
            shutil.copy2(notices, staging / 'THIRD-PARTY-NOTICES.txt')
        # Private: matching native symbols for crash reports, never shipped.
        if symbols.exists():
            shutil.rmtree(symbols)
        symbols.mkdir(parents=True)
        # The library's own native symbols (Linux: the .dbg split off by strip; Windows: the linker's .pdb, which stays
        # in the native build folder). The assemblies' IL .pdb files say nothing about native code and are left out.
        wanted = library.name + '.dbg' if not windows else library.stem + '.pdb'
        found = [file for file in [published / wanted, *work.glob(f'artifacts/**/native/{wanted}')] if file.is_file()]
        if found:
            shutil.copy2(found[0], symbols / wanted)
        else:
            print(f'warning: the native symbols ({wanted}) were not made; crash reports of this build cannot be read.')
        groups = classify(warnings, project)
        titles = {'game': "in the game's own code (fail the export)",
                  'engine-unreviewed': 'in the engine, not in tools/nativeaot_allowlist.txt (fail the export)',
                  'engine-allowed': 'in the engine, reviewed (tools/nativeaot_allowlist.txt)',
                  'packages': 'in third-party packages (reported only)', 'dotnet': 'in .NET itself (reported only)'}
        report = [f'NativeAOT build of {project.name} ({rid}, {config})', f'library: {library.name} '
                  f'({library.stat().st_size // 1024} KB)', f'trim/AOT analysis warnings: {len(warnings)}']
        for key, title in titles.items():
            report += ['', f'{len(groups[key])} {title}', *groups[key]]
        (symbols / 'nativeaot-report.txt').write_text('\n'.join(report) + '\n', encoding='utf-8')
    size = (staging / 'Managed' / 'Native' / library_name(windows)).stat().st_size
    print(f'NativeAOT: {library_name(windows)} {size // (1024 * 1024)} MB; symbols in {symbols}; '
          f'{len(warnings)} trim/AOT warning(s): {len(groups["game"])} in the game, '
          f'{len(groups["engine-allowed"]) + len(groups["engine-unreviewed"])} in the engine '
          f'({len(groups["engine-unreviewed"])} not reviewed), {len(groups["packages"])} in packages, '
          f'{len(groups["dotnet"])} in .NET (listed in {symbols / "nativeaot-report.txt"})')
    failing = groups['game'] + groups['engine-unreviewed']
    if failing and warnings_mode == 'error':
        lines = ['The NativeAOT export stopped on trim/AOT warnings:']
        if groups['game']:
            lines += ['', *groups['game'], '', GAME_HELP]
        if groups['engine-unreviewed']:
            lines += ['', 'Engine warnings nobody has reviewed (add each to tools/nativeaot_allowlist.txt with its '
                      'reason once it is known to be safe, or change the engine code):', *groups['engine-unreviewed']]
        lines += ['', 'tools/build_player.py --aot-warnings report exports anyway.']
        raise SystemExit('\n'.join(lines))
    return warnings


def check() -> int:
    ok = True
    if not shutil.which('dotnet'):
        print('dotnet: missing (install the .NET SDK)')
        return 1
    compiler = shutil.which('clang') or shutil.which('gcc')
    print(f'Linux: {"ok" if compiler else "needs clang or gcc"}')
    ok &= bool(compiler)
    try:
        windows_link_setup(Path(tempfile.gettempdir()) / 'tallow-native-check')
        print('Windows (cross): ok')
    except SystemExit as reason:
        print(f'Windows (cross): {reason}')
    return 0 if ok else 1


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == 'check':
        sys.exit(check())
    print(__doc__)
    sys.exit(2)
