#!/usr/bin/env python3
"""Build and package the Tallow editor for Linux, Windows or macOS, without build caches."""
import argparse
import json
import os
import platform
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
if sys.version_info < (3, 11):
    sys.exit(f'Tallow\'s build scripts need Python 3.11 or later; this is {sys.version.split()[0]} ({sys.executable}). '
             'On a Mac: brew install python (or python.org), then start Tallow again.')
import tomllib

WEB_NATIVE_LIBS = ('libtallow_native.a', 'bgfx/cmake/bgfx/libbgfx.a', 'bgfx/cmake/bimg/libbimg.a', 'bgfx/cmake/bimg/libbimg_decode.a',
                   'bgfx/cmake/bx/libbx.a', 'SDL/libSDL3.a', 'joltc/libjoltc.a', '_deps/joltphysics-build/libJolt.a', 'enet/libenet.a')
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))  # noqa: E402
import dotnet_sdk  # noqa: E402,F401  (the released .NET SDK Tallow pins, when installed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('linux', 'windows', 'macos'), required=True)
    parser.add_argument('--folder', type=Path, required=True)
    parser.add_argument('--config', choices=('Debug', 'Release'), default='Release')
    parser.add_argument('--skip-build', action='store_true', help='Package an existing launcher explicitly')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.folder.resolve()
    if output == root or output in root.parents or output.is_relative_to(root / 'Engine') or output.is_relative_to(root / 'Editor'):
        parser.error('Choose a separate output folder.')
    if output.exists() and (not output.is_dir() or (any(output.iterdir()) and not (output / 'tallow-package.txt').is_file())):
        parser.error('Output is not an earlier Tallow package; choose another folder.')
    windows = args.platform == 'windows'
    macos = args.platform == 'macos'
    if os.name == 'nt' and not windows:
        parser.error('Linux packages must be built on Linux.')
    if macos != (sys.platform == 'darwin'):
        parser.error('macOS packages are built on a Mac, and a Mac builds only them.')
    target = 'Win64' if windows else 'macOS' if macos else 'Linux64'
    native = 'native-win' if windows else 'native'
    config = tomllib.loads((root / 'Launcher/BeefProj.toml').read_text())['Configs'][args.config][target]
    extension = 'lib' if windows else 'a'
    archives = sorted(set(re.findall(r'build/' + native + r'/[A-Za-z0-9_./-]+\.' + extension, config['OtherLinkFlags'])))
    launcher = root / f'build/{args.config}_{target}/TallowLauncher' / ('TallowLauncher.exe' if windows else 'TallowLauncher')
    shaderc = Path(f'build/{native}/bgfx/cmake/bgfx/shaderc' + ('.exe' if windows else ''))
    # texturec compresses a game's pictures when File > Build makes it.
    texturec = Path(f'build/{native}/bgfx/cmake/bimg/texturec' + ('.exe' if windows else ''))
    # tallow_modelsettings applies the import settings of converted models (tallowengine.com/docs/model-import) in a build.
    modelsettings = Path(f'build/{native}/tallow_modelsettings' + ('.exe' if windows else ''))
    # tallow_modelconv converts FBX, OBJ, DAE, STL, PLY and 3DS files for the editor and builds (Assimp).
    modelconv = Path(f'build/{native}/tallow_modelconv' + ('.exe' if windows else ''))
    for relative in [*archives, shaderc, texturec, modelsettings, modelconv]:
        if not (root / relative).is_file():
            parser.error(f'Missing {relative}; build native dependencies first.')
    if not args.skip_build:
        # Source checkouts rebuild native changes; distributed packages already
        # contain the archives and do not need CMake or third-party source.
        if (root / 'build' / native / 'CMakeCache.txt').is_file():
            subprocess.run(['cmake', '--build', str(root / 'build' / native), '--target', 'tallow_native', 'shaderc', 'texturec', 'tallow_modelsettings', 'tallow_modelconv', '-j', '4'], check=True)
        if windows and os.name != 'nt':
            toolchain = Path(os.environ.get('TALLOW_WIN', Path.home() / '.local/share/tallow-win'))
            command = ['wine', str(toolchain / 'beef/bin/BeefBuild.exe'), '-workspace=.', f'-config={args.config}', '-platform=Win64', '-verbosity=minimal']
            environment = dict(os.environ, WINEPREFIX=str(toolchain / 'wine'), WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=')
        else:
            command = [os.environ.get('BEEFBUILD', 'BeefBuild'), '-workspace=.', f'-config={args.config}', f'-platform={target}', '-verbosity=minimal']
            environment = os.environ.copy()
        # The C# API bindings (Managed/Tallow.API/Generated/CSharpBindings.g.cs and the matching Beef source) are
        # generated from the checked-in [CSharpExpose] manifest and are gitignored, so a fresh checkout has none.
        # Generate them before the launcher is built: the wrappers are native exports, and a launcher built without
        # them fails the managed bindings' version check the first time a C# script runs (play mode never starts).
        (root / 'Engine/src/Scripting/CSharpBindings.Generated.bf').unlink(missing_ok=True)
        (root / 'Managed/Tallow.API/Generated/CSharpBindings.g.cs').unlink(missing_ok=True)
        subprocess.run(['dotnet', 'run', '--project', 'Managed/Tallow.BindingGen/Tallow.BindingGen.csproj',
                        '--', '--manifest', 'Managed/Tallow.BindingGen/csharp-api-manifest.tsv', '--engine-root', '.'],
                       cwd=root, env=environment, check=True)
        # Beef does not track changed native archives: force a fresh link, and
        # restore the previous executable if the compiler fails.
        previous = launcher.with_suffix(launcher.suffix + '.packaging-backup')
        if previous.exists():
            parser.error(f'An interrupted build backup exists: {previous}')
        if launcher.exists():
            launcher.rename(previous)
        try:
            subprocess.run(command, cwd=root, env=environment, check=True)
            if not launcher.is_file():
                raise RuntimeError('Compiler did not produce the launcher.')
        except BaseException:
            if previous.exists():
                if launcher.exists():
                    launcher.unlink()
                previous.rename(launcher)
            raise
        previous.unlink(missing_ok=True)
    if not launcher.is_file():
        parser.error(f'Launcher is not built: {launcher}')
    # The precompiled player C# games ship as their executable (Tallow.Build export), in Release; and Tallow's
    # managed runtime, built, so that C# works without first compiling the engine's own C#.
    player = root / 'Player' / 'build' / f'Release_{target}' / 'TallowPlayer' / ('TallowPlayer.exe' if windows else 'TallowPlayer')
    if not args.skip_build:
        if windows and os.name != 'nt':
            player_command = ['wine', str(toolchain / 'beef/bin/BeefBuild.exe'), '-workspace=Player', '-config=Release', '-platform=Win64', '-verbosity=minimal']
        else:
            player_command = [os.environ.get('BEEFBUILD', 'BeefBuild'), '-workspace=Player', '-config=Release', f'-platform={target}', '-verbosity=minimal']
        player.unlink(missing_ok=True)  # Beef does not notice changed native archives
        subprocess.run(player_command, cwd=root, env=environment, check=True)
        for project in ('Tallow.ManagedRuntime', 'Tallow.Editor'):
            subprocess.run(['dotnet', 'build', str(root / f'Managed/{project}/{project}.csproj'),
                            '--configuration', 'Debug', '--nologo', '--verbosity', 'minimal'], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.tallow-package-', dir=output.parent))
    try:
        ignore = shutil.ignore_patterns('build', '__pycache__', '*.pyc', 'recovery', '.reload', 'imgui.ini')
        for name in ('Engine', 'Editor', 'Launcher', 'Player'):
            shutil.copytree(root / name, stage / name, ignore=ignore)
        # The Windows player too, when it was built (tools/windows/setup.sh, then this script with --platform windows
        # or Tallow.Build export --platform windows): then the package makes Windows C# games without Wine or Beef.
        windows_player = root / 'Player' / 'build' / 'Release_Win64' / 'TallowPlayer' / 'TallowPlayer.exe'
        for built in dict.fromkeys([player] + ([windows_player] if not windows else [])):
            if built.is_file():
                destination = stage / built.relative_to(root)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(built, destination)
        # The other systems' players and the web player's pieces, when built here; the release workflow adds the ones
        # built on the other machines to every package (Tallow.Build export ships them).
        linux_player = root / 'Player' / 'build' / 'Release_Linux64' / 'TallowPlayer' / 'TallowPlayer'
        web_pieces = [*sorted((root / 'build/web-player').glob('libTallowPlayer_*.a')), *sorted((root / 'build/web-player').glob('Beef*_dotnet.a')),
                      *[root / 'build/native-web-dotnet' / lib for lib in WEB_NATIVE_LIBS]]
        for built in [linux_player, *web_pieces]:
            if built.is_file() and built != player:
                destination = stage / built.relative_to(root)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(built, destination)
        # C# gameplay: the API and runtime projects games compile against, the build tool, the editor scripts' API
        # (Tallow.Editor), and the runtime and editor API built.
        managed_ignore = shutil.ignore_patterns('bin', 'obj', '__pycache__')
        for name in ('Tallow.API', 'Tallow.ManagedRuntime', 'Tallow.Editor', 'Tallow.Build', 'Tallow.LanguageService', 'Tallow.Analyzers'):
            if (root / 'Managed' / name).is_dir():
                shutil.copytree(root / 'Managed' / name, stage / 'Managed' / name, ignore=managed_ignore)
        for name in ('Tallow.ManagedRuntime', 'Tallow.Editor'):
            built = root / 'Managed' / name / 'bin/Debug'
            if built.is_dir():
                shutil.copytree(built, stage / 'Managed' / name / 'bin/Debug')
        for name in ('Directory.Build.props', 'Directory.Packages.props', 'global.json'):
            if (root / 'Managed' / name).is_file():
                shutil.copy2(root / 'Managed' / name, stage / 'Managed' / name)
        for name in ('BeefSpace.toml', 'global.json', 'icon.png', 'LICENSE', 'THIRD_PARTY_LICENSES.txt'):
            shutil.copy2(root / name, stage / name)
        # Games are exported by Tallow.Build (Managed/Tallow.Build, shipped above); of tools/ it reads the NativeAOT
        # allowlist and the web page's shell. No Python script or Beef tool is shipped: C# projects need neither.
        (stage / 'tools').mkdir()
        shutil.copy2(root / 'tools/nativeaot_allowlist.txt', stage / 'tools/nativeaot_allowlist.txt')
        shutil.copytree(root / 'tools/web/shell', stage / 'tools/web/shell')
        for relative in [*archives, shaderc, texturec, modelsettings, modelconv]:
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / relative, destination)
        shutil.copy2(launcher, stage / ('Tallow.exe' if windows else 'Tallow'))
        # Debug builds depend on Beef runtime DLLs. Release builds normally do
        # not, but copy any runtime DLLs the compiler actually staged.
        if windows:
            for dll in launcher.parent.glob('*.dll'):
                shutil.copy2(dll, stage / dll.name)
        # Any machine exports Linux (Vulkan, OpenGL), Windows (Vulkan) and web (WebGL 2) games; a Mac also macOS (Metal).
        keep = {'spirv', 'glsl', 'webgl'} | ({'metal'} if macos else set())
        for backend in (stage / 'Engine/assets/shaders').iterdir():
            if backend.is_dir() and backend.name not in keep:
                shutil.rmtree(backend)
        prerequisites = ('the .NET SDK (Tallow installs it on first start); NativeAOT exports also need the Visual Studio C++ Build Tools.' if windows
                         else 'the .NET SDK (Tallow installs it on first start).' if macos
                         else 'the .NET SDK (Tallow installs it on first start); NativeAOT exports also need clang (or gcc) and zlib development files.')
        # Pin packaged builds to a specific source revision.
        commit = subprocess.run(
            ['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True,
            text=True, check=True).stdout.strip()
        version = os.environ.get('TALLOW_VERSION', '').strip()
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            parser.error('Cannot determine source commit SHA.')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+-]*', version):
            parser.error('Set TALLOW_VERSION to the desired version.')
        # A Mac package is for the chip it was built on (Beef and CMake build for the host).
        mac_arch = 'arm64' if platform.machine() in ('arm64', 'aarch64') else 'x64'
        (stage / 'tallow-version.json').write_text(json.dumps({
            'engine': 'Tallow', 'version': version, 'build': commit,
            'project_format': 1, 'platform': args.platform,
            'architecture': mac_arch if macos else 'x64',
        }, indent=2) + '\n')
        (stage / 'tallow-package.txt').write_text(
            f'Tallow early beta for {args.platform} ({("Apple silicon" if mac_arch == "arm64" else "Intel") if macos else "x64"}), {args.config}.\n'
            f'Start {"Tallow.exe" if windows else "./Tallow"}.\n'
            f'For editing/building projects: {prerequisites}\n'
            'Games are exported with Tallow.Build export (File > Build); no Beef compiler or Python is needed.\n'
            + ('Packaged from an existing executable; no rebuild was performed.\n' if args.skip_build else ''))
        if output.exists():
            shutil.rmtree(output)
        stage.rename(output)
        output.chmod(0o755)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f'Tallow {args.platform} packaged at {output}')


if __name__ == '__main__':
    main()
