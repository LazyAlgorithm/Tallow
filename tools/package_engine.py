#!/usr/bin/env python3
"""Build and package the Tallow editor for Linux, Windows or macOS, without build caches."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib


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
    # tallow_modelsettings applies the import settings of converted models (docs/model-import.md) in a build.
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
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.tallow-package-', dir=output.parent))
    try:
        ignore = shutil.ignore_patterns('build', '__pycache__', '*.pyc', 'recovery', '.reload', 'imgui.ini')
        for name in ('Engine', 'Editor', 'Launcher'):
            shutil.copytree(root / name, stage / name, ignore=ignore)
        for name in ('BeefSpace.toml', 'icon.png', 'LICENSE', 'THIRD_PARTY_LICENSES.txt'):
            shutil.copy2(root / name, stage / name)
        (stage / 'tools').mkdir()
        for name in ('build_player.py', 'pack_assets.py', 'compress_textures.py', 'convert_models.py', 'macos_link.py', 'reload_scripts.py', 'package_engine.py', 'engine_versions.py', 'toolchain.txt', 'setup_dependencies.ps1'):
            shutil.copy2(root / 'tools' / name, stage / 'tools' / name)
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
        # webgl: the editor's File > Build can make web builds (after tools/web/setup.sh).
        keep = {'spirv', 'webgl'} if windows else {'metal', 'webgl'} if macos else {'spirv', 'glsl', 'webgl'}
        for backend in (stage / 'Engine/assets/shaders').iterdir():
            if backend.is_dir() and backend.name not in keep:
                shutil.rmtree(backend)
        prerequisites = ('Beef toolchain, Microsoft C++ Build Tools, and Python 3.11+ on PATH.' if windows
                         else 'BeefBuild (built for macOS) and Python 3.11+ on PATH, and the Xcode command line tools.' if macos
                         else 'BeefBuild and Python 3.11+ on PATH, plus system graphics/audio drivers and X11 libraries.')
        # Pin packaged builds to a specific source revision.
        commit = subprocess.run(
            ['git', 'rev-parse', 'HEAD'], cwd=root, capture_output=True,
            text=True, check=True).stdout.strip()
        version = os.environ.get('TALLOW_VERSION', '').strip()
        if not re.fullmatch(r'[0-9a-f]{40}', commit):
            parser.error('Cannot determine source commit SHA.')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+-]*', version):
            parser.error('Set TALLOW_VERSION to the desired version.')
        (stage / 'tallow-version.json').write_text(json.dumps({
            'engine': 'Tallow', 'version': version, 'build': commit,
            'project_format': 1, 'platform': args.platform,
            'architecture': 'arm64' if macos else 'x64',
        }, indent=2) + '\n')
        (stage / 'tallow-package.txt').write_text(
            f'Tallow early beta for {args.platform} ({"Apple silicon" if macos else "x64"}), {args.config}.\n'
            f'Start {"Tallow.exe" if windows else "./Tallow"}.\n'
            f'For editing/building projects: {prerequisites}\n'
            'Engine/editor source and native archives are required to compile project scripts.\n'
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
