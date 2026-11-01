#!/usr/bin/env python3
"""Build a player (Linux, Windows with --platform windows, the web with --platform web, or macOS on a Mac) with no TallowEditor
dependency and stage its runtime assets.

A Windows player is built here on Linux: the Windows Beef compiler runs under Wine and links against the native
libraries in build/native-win. tools/windows/setup.sh downloads and builds what that needs, once.

A web player is a folder to put on any web server (GitHub Pages, itch.io): index.html, the game as WebAssembly and its
asset pack. Beef compiles it through Emscripten and links the native libraries in build/native-web; tools/web/setup.sh
sets that up, once."""
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

import compress_textures
import convert_models
import macos_link
import pack_assets

# Windows system libraries the native libraries call into (SDL, bgfx, ENet, miniaudio).
WINDOWS_SYSTEM_LIBS = ('user32', 'gdi32', 'shell32', 'winmm', 'imm32', 'ole32', 'oleaut32', 'version', 'setupapi', 'advapi32',
                       'ws2_32', 'psapi', 'uuid', 'cfgmgr32')
# The same libraries built for the web (tools/web/build_native.sh).
WEB_NATIVE_LIBS = ('libtessera_native.a', 'bgfx/cmake/bgfx/libbgfx.a', 'bgfx/cmake/bimg/libbimg.a', 'bgfx/cmake/bimg/libbimg_decode.a',
                   'bgfx/cmake/bx/libbx.a', 'SDL/libSDL3.a', 'joltc/libjoltc.a', '_deps/joltphysics-build/libJolt.a', 'enet/libenet.a')
# How Emscripten links the web player. WebGL 2 only; memory grows as the game needs it; a large stack, as Beef code
# keeps a lot on it; the browser's storage (IDBFS) for saved files; the page (tools/web/shell) drives start-up.
WEB_LINK_FLAGS = ('-sUSE_WEBGL2=1', '-sMIN_WEBGL_VERSION=2', '-sMAX_WEBGL_VERSION=2', '-sFULL_ES3=1', '-sALLOW_MEMORY_GROWTH=1',
                  '-sINITIAL_MEMORY=268435456', '-sSTACK_SIZE=8388608', '-sFORCE_FILESYSTEM=1', '-lidbfs.js', '-sENVIRONMENT=web',
                  # miniaudio's Web Audio code reads the memory as Module.HEAPF32.
                  '-sEXPORTED_RUNTIME_METHODS=FS,addRunDependency,removeRunDependency,wasmTable,HEAPF32', '-sEXIT_RUNTIME=0', '-sMINIFY_HTML=0',
                  # The browser glue (native/tessera_web.c) is JavaScript the linker only takes from the archive when asked.
                  '-Wl,-u,tn_web_free')
WINDOWS_NATIVE_LIBS = ('tessera_native.lib', 'bgfx/cmake/bgfx/bgfx.lib', 'bgfx/cmake/bimg/bimg.lib', 'bgfx/cmake/bimg/bimg_decode.lib',
                       'bgfx/cmake/bx/bx.lib', 'SDL/SDL3-static.lib', 'joltc/joltc.lib', '_deps/joltphysics-build/Jolt.lib', 'enet/enet.lib')


def wine_path(path, separator='\\'):
    """A Linux path as Wine sees it: its Z: drive is the whole file system."""
    return 'Z:' + str(path).replace('/', separator)


def write_web_page(engine, project, name, staging):
    """The page that loads and runs a web player: index.html, its install manifest and icon."""
    shell = engine / 'tools' / 'web' / 'shell'
    pack = 'game.tpak' if (staging / 'game.tpak').is_file() else ''
    # Scene packs download after the game has started, smallest first; the game asks for one it needs sooner.
    later = sorted((file for file in staging.glob('*.tpak') if file.name != 'game.tpak'), key=lambda file: file.stat().st_size)
    later_list = json.dumps([file.name for file in later])
    for file in ('index.html', 'manifest.webmanifest'):
        text = (shell / file).read_text().replace('{{NAME}}', name).replace('{{SCRIPT}}', name + '.js').replace('{{PACK}}', pack).replace('{{LATER_PACKS}}', later_list)
        (staging / file).write_text(text)
    # Multiplayer between browsers (WebRTC); see the file for how players find each other.
    shutil.copy2(shell / 'tessera-net.js', staging / 'tessera-net.js')
    for icon in (project / 'icon.png', project / 'src' / 'icon.png', engine / 'icon.png'):
        if icon.is_file():
            shutil.copy2(icon, staging / 'icon.png')
            break
    # GitHub Pages runs its own site generator (Jekyll) over a folder unless told not to.
    (staging / '.nojekyll').write_text('')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--scene', help='Asset-relative start scene')
    parser.add_argument('--config', choices=('Debug', 'Release'), default='Release')
    parser.add_argument('--platform', choices=('linux', 'windows', 'web', 'macos'), default='windows' if os.name == 'nt' else 'macos' if sys.platform == 'darwin' else 'linux')
    parser.add_argument('--replace', action='store_true', help='Replace the output folder if it holds an earlier build (it must contain game.tallow)')
    parser.add_argument('--fullscreen', action='store_true', help='The game starts fullscreen, whatever the project says')
    parser.add_argument('--windowed', action='store_true', help='The game starts in a window, whatever the project says')
    parser.add_argument('--no-compress', action='store_true', help='Pack the assets without compressing them')
    parser.add_argument('--no-texture-compression', action='store_true', help='Leave pictures uncompressed for the graphics card (no .ktx copies)')
    parser.add_argument('--single-pack', action='store_true', help='Put every asset in game.tpak, with no pack per scene')
    parser.add_argument('--loose', action='store_true', help='Leave the assets as loose files instead of packing them into game.tpak')
    parser.add_argument('--console', action='store_true', help='Windows: keep a console window for log output (a dedicated server wants one)')
    parser.add_argument('--bootstrap', help='Static registration method, e.g. Sandbox.GameSetup.Register')
    args = parser.parse_args()
    project = args.project.resolve()
    output = args.output.resolve()
    if output.exists():
        # Only ever delete a folder this tool made: an earlier build, recognised by its game.tallow or game.tpak.
        if not args.replace:
            parser.error('Output already exists; choose a new folder to preserve the existing build, or pass --replace.')
        if not output.is_dir() or (any(output.iterdir()) and not (output / 'game.tallow').is_file() and not (output / 'game.tpak').is_file()):
            parser.error(f'{output} exists and is not an earlier build of a game, so it is left alone. Choose another folder.')
    settings = {}
    for line in (project / 'project.tallow').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            settings[key.strip()] = value.strip()
    windows = args.platform == 'windows'
    web = args.platform == 'web'
    macos = args.platform == 'macos'
    if macos and sys.platform != 'darwin':
        parser.error('A macOS player is built on a Mac.')
    if sys.platform == 'darwin' and not (macos or web):
        parser.error('A Mac builds macOS and web players.')
    # On a Windows machine Beef builds for Windows by itself; on Linux its Windows release runs under Wine.
    cross = windows and os.name != 'nt'
    if os.name == 'nt' and not windows:
        parser.error(f'A {"web" if web else "Linux"} player is built on Linux.')
    engine = Path(settings['engine']).resolve()
    recorded_engine = settings['engine']
    # A project copied from another machine names an engine folder that is not here: use the engine this tool
    # belongs to, and point the project's link settings at it.
    if not (engine / 'Engine' / 'src').is_dir():
        engine = Path(__file__).resolve().parent.parent
    name = settings['name']
    if windows:
        toolchain = Path(os.environ.get('TESSERA_WIN', Path.home() / '.local/share/tessera-win'))
        natives = engine / 'build' / 'native-win'
        if args.config != 'Release':
            parser.error('Windows players are built in the Release configuration only.')
        if cross and not shutil.which('wine'):
            parser.error('Building for Windows needs Wine (it runs the Windows Beef compiler).')
        if cross and (not (toolchain / 'beef/bin/BeefBuild.exe').is_file() or not (natives / 'tessera_native.lib').is_file()):
            parser.error(f'The Windows toolchain is not set up. Run {engine / "tools/windows/setup.sh"} once.')
        if not cross and not (natives / 'tessera_native.lib').is_file():
            parser.error(f'The native libraries for Windows are missing from {natives}.')
    if web:
        natives = engine / 'build' / 'native-web'
        if not (natives / 'libtessera_native.a').is_file():
            parser.error(f'The native libraries for the web are missing from {natives}. Run {engine / "tools/web/setup.sh"} once.')
        if args.loose:
            parser.error('A web player always packs its assets: a browser loads one file far faster than thousands.')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name):
        parser.error('Project name must be a valid Beef identifier.')
    scene = args.scene or settings.get('startScene', 'Scenes/Main.tscene')
    scene_path = (project / 'src' / scene).resolve()
    if not scene_path.is_relative_to(project / 'src') or not scene_path.is_file():
        parser.error('Start scene must exist inside the project src folder. Save it in the editor first.')
    proj = tomllib.loads((project / 'BeefProj.toml').read_text())
    space = tomllib.loads((project / 'BeefSpace.toml').read_text())
    dependencies = {key: value for key, value in proj['Dependencies'].items() if key != 'TallowEditor'}
    dependencies.setdefault('Tallow', '*')
    program = (project / 'src' / 'Program.bf').read_text()
    # Keep the entry point's namespace imports: copied/renamed projects can
    # register scripts from a namespace that differs from the project name.
    imports = [match.group(0) for match in re.finditer(r'^\s*using\s+([A-Za-z_][A-Za-z0-9_.]*)\s*;', program, re.MULTILINE)
               if match.group(1) not in ('System', 'Tallow') and not match.group(1).startswith(('Tallow.Editor',))]
    bootstrap = args.bootstrap
    registration = re.search(r'\b((?:[A-Za-z_][A-Za-z0-9_]*\.)*GameSetup\.Register)\(\)', program)
    if bootstrap is None and registration:
        bootstrap = registration.group(1)
    if bootstrap and not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.]*', bootstrap):
        parser.error('Invalid bootstrap method name.')
    with tempfile.TemporaryDirectory(prefix='tallow-player-') as temporary:
        workspace = Path(temporary)
        source = workspace / 'src'
        source.mkdir()
        for file in (project / 'src').rglob('*.bf'):
            if file == project / 'src' / 'Program.bf':
                continue
            if re.search(r'\bTallow\.Editor\b', file.read_text()):
                parser.error(f'Runtime script references the editor: {file}')
            target = source / file.relative_to(project / 'src')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
        (source / 'Program.bf').write_text('using System;\nusing Tallow;\n' + '\n'.join(imports) + '\nnamespace ' + name + ';\nclass Program { public static int Main(String[] args) {\n' + (f'{bootstrap}();\n' if bootstrap else '') + 'return GameMain.Run(args);\n} }\n')
        q = json.dumps
        # Beef under Wine is given forward-slash Z: paths for projects and backslash ones on the link line.
        located = (lambda path: wine_path(path, '/')) if cross else (lambda path: str(path).replace('\\', '/'))
        project_entries = [f'{name} = {{Path = "."}}', f'Tallow = {{Path = {q(located(engine / "Engine"))}}}']
        for dependency in dependencies:
            if dependency in ('corlib', 'Tallow'):
                continue
            location = (project / space['Projects'][dependency]['Path']).resolve()
            project_entries.append(f'{dependency} = {{Path = {q(located(location))}}}')
        (workspace / 'BeefSpace.toml').write_text('FileVersion = 1\nProjects = {' + ', '.join(project_entries) + '}\n[Workspace]\nStartupProject = ' + q(name) + '\n'
                                               + (f'[Configs.{args.config}.Win64]\nToolset = "LLVM"\n' if windows else '')
                                               # Emscripten is a GNU-style toolchain. Debug info would stop its optimiser.
                                               + (f'[Configs.{args.config}.wasm32]\nToolset = "GNU"\n' + ('EmitDebugInfo = "No"\n' if args.config == 'Release' else '') if web else ''))
        if windows:
            # The project's own settings are for Linux; a Windows player links the same libraries as built for Windows.
            config = {'OtherLinkFlags': '$(LinkFlags) ' + ' '.join([f'"{wine_path(natives / lib) if cross else natives / lib}"' for lib in WINDOWS_NATIVE_LIBS] + [lib + '.lib' for lib in WINDOWS_SYSTEM_LIBS])}
        elif web:
            config = {'OtherLinkFlags': '$(LinkFlags) ' + ' '.join([str(natives / lib) for lib in WEB_NATIVE_LIBS] + list(WEB_LINK_FLAGS))}
        elif macos:
            # The project's own settings are for Linux; a Mac links the same libraries as built for macOS.
            config = {'OtherLinkFlags': macos_link.flags(str(engine / 'build' / 'native'))}
        else:
            config = proj['Configs'][args.config]['Linux64']
        target_type = 'BeefGUIApplication' if windows and not args.console else 'BeefConsoleApplication'
        beef_platform = 'Win64' if windows else 'wasm32' if web else 'macOS' if macos else 'Linux64'
        lines = ['FileVersion = 1', 'Dependencies = {' + ', '.join(f'{key} = {q(value)}' for key, value in dependencies.items()) + '}', '[Project]', f'Name = {q(name)}', f'TargetType = {q(target_type)}', f'StartupObject = {q(name + ".Program")}', f'[Configs.{args.config}.{beef_platform}]']
        for key, value in config.items():
            if not windows and not web and not macos and isinstance(value, str) and recorded_engine and str(engine) != recorded_engine:
                value = value.replace(recorded_engine, str(engine))
            lines.append(f'{key} = {q(value)}')
        (workspace / 'BeefProj.toml').write_text('\n'.join(lines) + '\n')
        if cross:
            environment = dict(os.environ, WINEPREFIX=str(toolchain / 'wine'), WINEDEBUG='-all', WINEDLLOVERRIDES='mscoree,mshtml=')
            built = subprocess.run(['wine', str(toolchain / 'beef/bin/BeefBuild.exe'), '-workspace=.', f'-config={args.config}', '-platform=Win64', '-verbosity=minimal'],
                                   cwd=workspace, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            # Wine's own chatter about graphics drivers is noise here; the compiler's messages are not.
            print('\n'.join(line for line in built.stdout.splitlines() if 'MESA' not in line and 'pci id' not in line))
            if built.returncode != 0:
                raise SystemExit('The Windows build failed.')
        else:
            subprocess.run([os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={workspace}', f'-config={args.config}', '-verbosity=minimal'] + (['-platform=Win64'] if windows else ['-platform=wasm32'] if web else ['-platform=macOS'] if macos else []), check=True)
        output.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(prefix=output.name + '-', dir=output.parent))
        try:
            built_folder = workspace / 'build' / f'{args.config}_{beef_platform}' / name
            if web:
                # The program is a script and its WebAssembly; the page that runs them comes from tools/web/shell.
                for suffix in ('.js', '.wasm'):
                    shutil.copy2(built_folder / (name + suffix), staging / (name + suffix))
            else:
                executable = name + ('.exe' if windows else '')
                shutil.copy2(built_folder / executable, staging / executable)
            # Of the engine's files a game reads only the compiled shaders, and only those of the graphics backends
            # it can start on this system: Vulkan, plus OpenGL as the fallback on Linux; WebGL 2 in a browser.
            # Metal on a Mac.
            for backend in (('webgl',) if web else ('spirv',) if windows else ('metal',) if macos else ('spirv', 'glsl')):
                shutil.copytree(engine / 'Engine' / 'assets' / 'shaders' / backend, staging / 'Engine' / 'assets' / 'shaders' / backend)
            for file in (engine / 'Engine' / 'assets').iterdir():
                if file.is_file():
                    shutil.copy2(file, staging / 'Engine' / 'assets' / file.name)
            # The libraries' licences ask to travel with what is built from them.
            if (engine / 'LICENSE').exists():
                shutil.copy2(engine / 'LICENSE', staging / 'LICENSE')
            if (engine / 'THIRD_PARTY_LICENSES.txt').exists():
                shutil.copy2(engine / 'THIRD_PARTY_LICENSES.txt', staging / 'THIRD_PARTY_LICENSES.txt')
            for file in (project / 'src').rglob('*'):
                if not file.is_file() or file.suffix in ('.bf', '.tgraph', '.py', '.sh') or any(part.startswith('.') for part in file.relative_to(project / 'src').parts):
                    continue
                # FBX, OBJ, ... and their import settings: the game gets the converted .glb instead (below).
                if convert_models.is_converted(file.name) or (file.name.endswith('.import') and convert_models.is_converted(file.name[:-7])):
                    continue
                target = staging / 'Assets' / file.relative_to(project / 'src')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(file, target)
            # Converted models (docs/model-import.md), as <file>.glb: the name the engine looks for when a scene names
            # the file itself.
            converted, conversion_errors = convert_models.convert_project(project, engine)
            if conversion_errors:
                sys.exit('Some models could not be converted:\n  ' + '\n  '.join(conversion_errors))
            for relative, path in converted:
                target = staging / 'Assets' / (relative + '.glb')
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
            if converted:
                print(f'Models: {len(converted)} converted to glTF')
            # Pictures compressed for the graphics card (docs/textures.md): a .ktx beside each, which the engine uses in its
            # place. Not for the web, whose browsers do not all read the same compressed formats.
            if not web and not args.no_texture_compression and settings.get('compressTextures', '1') != '0':
                made, skipped, errors = compress_textures.compress_folder(staging / 'Assets', engine, settings.get('textureCompressExclude', compress_textures.DEFAULT_EXCLUDE))
                print(f'Textures: {made} compressed, {skipped} left as they are' + ''.join(f'\n  note: {error}' for error in errors))
            # A web page cannot load Steam.
            steam = '' if web else settings.get('steamAppId', '')
            if steam:
                # A game that is not started from Steam says which app it is with this file, and needs Valve's
                # Steamworks library beside it: the project's own copy if it has one, else one found on this machine.
                (staging / 'steam_appid.txt').write_text(steam + '\n')
                library = 'steam_api64.dll' if windows else 'libsteam_api.dylib' if macos else 'libsteam_api.so'
                for candidate in (project / library, project / 'Libraries' / library, Path.home() / '.local/share/Steam/steamrt64' / library):
                    if candidate.is_file():
                        shutil.copy2(candidate, staging / library)
                        break
                else:
                    print(f'Note: {library} was not found, so this build runs without Steam. Put the file from the Steamworks SDK in {project} and build again.')
            hrtf = settings.get('audioHrtf', '')
            # How the game starts out: the project's Build setting, unless this run says otherwise.
            # In a browser the page fills the window, and the player chooses full screen.
            fullscreen = (settings.get('fullscreen', '') == '1' or args.fullscreen) and not args.windowed and not web
            (staging / 'game.tallow').write_text(f'name = {name}\nstartScene = {scene}\n' + (f'steamAppId = {steam}\n' if steam else '') + (f'audioHrtf = {hrtf}\n' if hrtf else '') + ('fullscreen = 1\n' if fullscreen else '') + ''.join(f'{k} = {settings[k]}\n' for k in ('antiCheat', 'voiceChat', 'voicePushToTalk', 'voiceProximity', 'voiceTeamOnly', 'voiceKey', 'loadSaveAtStart', 'saveSlot', 'windowWidth', 'windowHeight', 'escapeQuits') if settings.get(k)))
            if output.exists():
                shutil.rmtree(output)
            # Everything the game reads goes into one pack, unless the project (or --loose) says to leave it loose.
            # A web build's pack is downloaded by every player every time, so it is always compressed.
            if not args.loose and settings.get('packAssets', '1') != '0':
                packed = [(file.relative_to(staging).as_posix(), str(file)) for folder in ('Assets', 'Engine') for file in (staging / folder).rglob('*') if file.is_file()]
                packed.append(('game.tallow', str(staging / 'game.tallow')))
                compress = not args.no_compress and (web or settings.get('packCompress', '1') != '0')
                # A scene's own files (what only that scene uses) go into a pack of its own, so that changing one
                # map rewrites one small file, and a browser can start before every map has arrived. packs.txt in
                # game.tpak lists them; the engine mounts them all at start, or as they download on the web.
                extra = []
                if not args.single_pack and settings.get('packSplit', '1') != '0':
                    assets = {file.relative_to(staging / 'Assets').as_posix(): str(file) for file in (staging / 'Assets').rglob('*') if file.is_file()}
                    code = [file.read_text(errors='replace') for file in (project / 'src').rglob('*') if file.is_file() and file.suffix in ('.bf', '.tgraph')]
                    patterns = [pattern.strip() for pattern in settings.get('packShared', '').split(';')]
                    scene_packs, served = pack_assets.plan_split(assets, code, scene, patterns)
                    inside = set()
                    for pack_name, members in sorted(scene_packs.items()):
                        pack_assets.write_pack(staging / pack_name, [('Assets/' + member, assets[member]) for member in members], compress=compress, name=name)
                        inside.update('Assets/' + member for member in members)
                        extra.append((pack_name, served[pack_name], (staging / pack_name).stat().st_size))
                    packed = [entry for entry in packed if entry[0] not in inside]
                    if extra:
                        manifest = staging / 'packs.txt'
                        manifest.write_text(''.join(f'{pack_name}\t{served_scene}\t{size}\n' for pack_name, served_scene, size in extra))
                        packed.append(('packs.txt', str(manifest)))
                pack_assets.write_pack(staging / 'game.tpak', packed, compress=compress, name=name)
                if extra:
                    (staging / 'packs.txt').unlink()
                    print(f'Packs: game.tpak and {len(extra)} for scenes (' + ', '.join(entry[0] for entry in extra) + ')')
                shutil.rmtree(staging / 'Assets')
                shutil.rmtree(staging / 'Engine')
                (staging / 'game.tallow').unlink()
            if web:
                write_web_page(engine, project, name, staging)
            staging.rename(output)
        except BaseException:
            shutil.rmtree(staging)
            raise
    print(f'{args.platform.capitalize()} player packaged at {output}; TallowEditor excluded.')


if __name__ == '__main__':
    main()
