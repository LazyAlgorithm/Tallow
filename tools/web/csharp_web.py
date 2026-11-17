#!/usr/bin/env python3
"""C# games for the web: the engine, its precompiled player and .NET in one WebAssembly module.

On the desktop the engine starts .NET. In a browser .NET's own start-up must run first (it is a page script), so a C#
web player is a .NET browser app (Microsoft.NET.Sdk.WebAssembly, Mono) whose native part is relinked with the engine:
the player's Beef code (compiled for wasm32 into object files, archived here), Beef's runtime, and the engine's native
libraries built with the Emscripten that .NET's wasm-tools workload ships (build/native-web-dotnet). Its Main is
Tallow.ManagedRuntime's WebHost, which registers the managed entrypoints with the engine and runs the player.

  python3 tools/web/csharp_web.py setup      # once: .NET 11 + wasm-tools for the web, and build/native-web-dotnet

build_player.py --platform web calls build() for a C# project.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

DOTNET_MAJOR = 11
WEB_HOME = Path(os.environ.get('TALLOW_WEB_HOME', Path.home() / '.local/share/tallow-web'))
NATIVE_LIBS = ('libtallow_native.a', 'bgfx/cmake/bgfx/libbgfx.a', 'bgfx/cmake/bimg/libbimg.a', 'bgfx/cmake/bimg/libbimg_decode.a',
               'bgfx/cmake/bx/libbx.a', 'SDL/libSDL3.a', 'joltc/libjoltc.a', '_deps/joltphysics-build/libJolt.a', 'enet/libenet.a')
# .NET's own list of runtime methods its JavaScript uses (runtimes/browser-wasm/native/src/emcc-link.rsp) and the
# engine's: wasmTable (Beef's reflection calls), FS and the run dependencies (the page writes the asset pack and
# mounts the save folder), HEAPF32 (miniaudio's Web Audio code).
RUNTIME_METHODS = ('FS,out,err,ccall,cwrap,setValue,getValue,UTF8ToString,UTF8ArrayToString,lengthBytesUTF8,'
                   'stringToUTF8Array,FS_createPath,FS_createDataFile,removeRunDependency,addRunDependency,addFunction,'
                   'safeSetTimeout,runtimeKeepalivePush,runtimeKeepalivePop,maybeExit,abort,HEAP8,HEAP16,HEAPU8,HEAPU16,'
                   'HEAP32,HEAPU32,HEAPF32,HEAPF64,HEAP64,HEAPU64,wasmExports,wasmTable')
# As the Beef web player links (build_player.WEB_LINK_FLAGS), where .NET does not already: WebGL 2 only, the browser's
# storage for saved files, a large stack (Beef code keeps a lot on it). -matomics: Beef's Interlocked compiles to
# atomic instructions, valid without shared memory (no threads are started).
LINK_FLAGS = ('-matomics', '-mbulk-memory', '-sUSE_WEBGL2=1', '-sMIN_WEBGL_VERSION=2', '-sMAX_WEBGL_VERSION=2', '-sFULL_ES3=1',
              '-lidbfs.js', '-sINITIAL_MEMORY=268435456', f'-sEXPORTED_RUNTIME_METHODS={RUNTIME_METHODS}',
              # The browser glue (native/tallow_web.c) is JavaScript the linker only takes from the archive when asked.
              '-Wl,-u,tn_web_free')


def dotnet_root():
    """A .NET 11 SDK with the wasm-tools workload: TALLOW_WEB_DOTNET, the one setup installed, or the dotnet on PATH."""
    candidates = []
    if os.environ.get('TALLOW_WEB_DOTNET'):
        candidates.append(Path(os.environ['TALLOW_WEB_DOTNET']))
    home = WEB_HOME / 'dotnet'
    if home.is_dir():
        candidates += sorted((entry for entry in home.iterdir() if entry.is_dir()), reverse=True)
    found = shutil.which('dotnet')
    if found:
        candidates.append(Path(os.path.realpath(found)).parent)
    for root in candidates:
        if (root / 'dotnet').is_file() and emscripten_pack(root):
            return root
    return None


def emscripten_pack(root):
    """The workload's Emscripten (its tools/ folder), or None."""
    packs = root / 'packs'
    if not packs.is_dir():
        return None
    for pack in sorted(packs.glob('Microsoft.NET.Runtime.Emscripten.*.Sdk.*'), reverse=True):
        for version in sorted(pack.iterdir(), reverse=True):
            if (version / 'tools' / 'emscripten' / 'emcc').is_file():
                return version / 'tools'
    return None


def environment(root):
    """Environment for running the workload's Emscripten (emcc, emar, emcmake) and its dotnet."""
    tools = emscripten_pack(root)
    node = next((path for path in (root / 'packs').glob('Microsoft.NET.Runtime.Emscripten.*.Node.*/*/tools/bin/node')), None)
    cache = WEB_HOME / 'emcache-dotnet'
    if not (cache / 'sysroot').is_dir():
        # Emscripten writes to its cache (it checks its sanity there), so it gets a copy of the workload's own.
        shipped = next((root / 'packs').glob('Microsoft.NET.Runtime.Emscripten.*.Cache.*/*/tools/emscripten/cache'), None)
        if shipped is not None:
            shutil.copytree(shipped, cache, dirs_exist_ok=True)
    env = dict(os.environ, DOTNET_ROOT=str(root), DOTNET_NOLOGO='1', DOTNET_CLI_TELEMETRY_OPTOUT='1',
               DOTNET_EMSCRIPTEN_LLVM_ROOT=str(tools / 'bin'), DOTNET_EMSCRIPTEN_BINARYEN_ROOT=str(tools),
               EM_CONFIG=str(tools / 'emscripten' / '.emscripten'), EM_CACHE=str(cache), FROZEN_CACHE='',
               PATH=os.pathsep.join([str(root), str(tools / 'emscripten'), str(tools / 'bin'), os.environ.get('PATH', '')]))
    if node is not None:
        env['DOTNET_EMSCRIPTEN_NODE_JS'] = str(node)
    return env


def natives_folder(engine):
    return engine / 'build' / 'native-web-dotnet'


def build_natives(engine, env):
    """The engine's native libraries, built with the workload's Emscripten (their objects must match .NET's)."""
    out = natives_folder(engine)
    subprocess.run([sys.executable, str(engine / 'tools' / 'patch_textedit.py')], check=True, env=env)
    subprocess.run(['emcmake', 'cmake', '-S', str(engine / 'native'), '-B', str(out), '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release'],
                   check=True, env=env)
    subprocess.run(['cmake', '--build', str(out), '-j', str(os.cpu_count() or 4), '--target', 'tallow_native', 'bgfx', 'bimg',
                    'bimg_decode', 'bx', 'SDL3-static', 'joltc', 'Jolt', 'enet'], check=True, env=env)


def beef_runtime(engine, env):
    """Beef's WebAssembly runtime, as .NET's link needs it. Its WasmCommon.o defines a stand-in _Unwind_GetIP (for
    builds without unwinding); .NET links the real one (libunwind, for WebAssembly exceptions), so the copy here
    renames the stand-in (a name of the same length) and every other caller gets the real one."""
    beef = shutil.which(os.environ.get('BEEFBUILD', 'BeefBuild'))
    if not beef:
        raise SystemExit('BeefBuild was not found: put it on PATH or set BEEFBUILD.')
    dist = Path(os.path.realpath(beef)).parent
    source = next(iter(sorted(dist.glob('Beef*RT32_wasm.a'))), None)
    if source is None:
        raise SystemExit(f'Beef\'s WebAssembly runtime is missing from {dist}: run {engine / "tools/web/setup.sh"} once.')
    target = engine / 'build' / 'web-player' / (source.stem + '_dotnet.a')
    if target.is_file() and target.stat().st_mtime >= source.stat().st_mtime:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='tallow-beefrt-') as work:
        subprocess.run(['emar', 'x', str(source), 'WasmCommon.o'], cwd=work, check=True, env=env)
        member = Path(work) / 'WasmCommon.o'
        data = member.read_bytes()
        old, new = b'\x0d_Unwind_GetIP', b'\x0d_BfStub_GetIP'
        if data.count(old) == 1:
            member.write_bytes(data.replace(old, new))
        shutil.copy2(source, target.with_suffix('.tmp'))
        subprocess.run(['emar', 'r', str(target.with_suffix('.tmp')), str(member)], check=True, env=env)
        os.replace(target.with_suffix('.tmp'), target)
    return target


def player_library(engine, config, env):
    """Player/ compiled for wasm32 as an application in a static library (BeefStart runs its Main), archived from
    the objects Beef's own link step names. Built in build/web-player, so later builds are incremental."""
    work = engine / 'build' / 'web-player'
    source = work / 'src'
    if source.exists():
        shutil.rmtree(source)
    shutil.copytree(engine / 'Player' / 'src', source)
    q = lambda text: '"' + str(text).replace('\\', '/') + '"'
    (work / 'BeefSpace.toml').write_text('FileVersion = 1\nProjects = {TallowPlayer = {Path = "."}, Tallow = {Path = ' + q(engine / 'Engine') + '}}\n'
                                         '[Workspace]\nStartupProject = "TallowPlayer"\n'
                                         f'[Configs.{config}.wasm32]\nToolset = "GNU"\n' + ('EmitDebugInfo = "No"\n' if config == 'Release' else ''))
    (work / 'BeefProj.toml').write_text('FileVersion = 1\nDependencies = {corlib = "*", Tallow = "*"}\n[Project]\nName = "TallowPlayer"\n'
                                        'TargetType = "BeefApplication_StaticLib"\nStartupObject = "Tallow.Player.Program"\n')
    out = work / 'build' / f'{config}_wasm32' / 'TallowPlayer'
    # Beef does not make this folder itself for a library.
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([os.environ.get('BEEFBUILD', 'BeefBuild'), f'-workspace={work}', f'-config={config}', '-platform=wasm32',
                    '-verbosity=minimal'], check=True)
    # For wasm32 Beef links a page as well, whatever the target type; that page's link line names exactly the
    # objects of this build (older objects of renamed types can linger in the folders).
    line = (out / 'TallowPlayer.html.build.txt').read_text(errors='replace')
    objects = [token for token in re.findall(r'"([^"]+\.o)"|(\S+\.o)\b', line) for token in token if token]
    objects = [path for path in dict.fromkeys(objects) if Path(path).is_file()]
    if not any(Path(path).name == 'vdata.o' for path in objects):
        raise SystemExit('The web player\'s Beef build named no objects.')
    library = work / f'libTallowPlayer_{config}.a'
    library.unlink(missing_ok=True)
    with tempfile.NamedTemporaryFile('w', suffix='.rsp', delete=False) as listing:
        listing.write('\n'.join(f'"{path}"' for path in objects))
    try:
        subprocess.run(['emar', 'rcs', str(library), f'@{listing.name}'], check=True, env=env)
    finally:
        os.unlink(listing.name)
    return library


def game_assemblies(project, config):
    """The game's own assemblies (Tallow.Game and its packages), not Tallow's (those come with the runtime)."""
    built = project / 'build' / 'csharp' / config
    result = []
    for folder in sorted(built.iterdir()) if built.is_dir() else []:
        for dll in sorted(folder.glob('*.dll')):
            if dll.stem not in ('Tallow.API', 'Tallow.ManagedRuntime') and dll.name not in (path.name for path in result):
                result.append(dll)
    if not any(path.name == 'Tallow.Game.dll' for path in result):
        raise SystemExit(f'The game\'s C# is not built ({built}/Tallow.Game/Tallow.Game.dll is missing).')
    return result


def build(engine, project, config, staging):
    """The page's .NET bundle (_framework/) for the C# game at project, into staging."""
    root = dotnet_root()
    if root is None:
        raise SystemExit(f'C# games for the web need .NET {DOTNET_MAJOR} with the wasm-tools workload. Run: python3 {engine / "tools/web/csharp_web.py"} setup')
    env = environment(root)
    natives = natives_folder(engine)
    if not (natives / 'libtallow_native.a').is_file():
        raise SystemExit(f'The native libraries for C# web games are missing from {natives}. Run: python3 {engine / "tools/web/csharp_web.py"} setup')
    library = player_library(engine, config, env)
    runtime = beef_runtime(engine, env)
    with tempfile.TemporaryDirectory(prefix='tallow-web-cs-') as temporary:
        app = Path(temporary)
        # The name the managed P/Invokes bind the engine's functions by (WebHost's "tallowengine").
        (app / 'tallowengine.c').write_text('int tallow_engine_module(void) { return 1; }\n')
        (app / 'Program.cs').write_text('public static class TallowWebMain\n{\n    public static int Main(string[] args) => Tallow.ManagedRuntime.WebHost.Run(args);\n}\n')
        x = lambda text: str(text).replace('&', '&amp;').replace('"', '&quot;').replace('<', '&lt;')
        references = ''.join(f'    <Reference Include="{x(dll.stem)}"><HintPath>{x(dll)}</HintPath></Reference>\n'
                             f'    <TrimmerRootAssembly Include="{x(dll.stem)}" />\n' for dll in game_assemblies(project, config))
        natives_items = ''.join(f'    <NativeFileReference Include="{x(path)}" />\n' for path in
                                [app / 'tallowengine.c', library, runtime] + [natives / lib for lib in NATIVE_LIBS])
        (app / 'TallowWeb.csproj').write_text(f'''<Project Sdk="Microsoft.NET.Sdk.WebAssembly">
  <PropertyGroup>
    <TargetFramework>net{DOTNET_MAJOR}.0</TargetFramework>
    <OutputType>Exe</OutputType>
    <AssemblyName>TallowWeb</AssemblyName>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <Nullable>enable</Nullable>
    <WasmBuildNative>true</WasmBuildNative>
    <EmccStackSize>8388608</EmccStackSize>
    <EmccExtraLDFlags>{x(' '.join(LINK_FLAGS))}</EmccExtraLDFlags>
    <!-- Every file is served as it is: GitHub Pages and itch.io do not serve the precompressed copies. -->
    <CompressionEnabled>false</CompressionEnabled>
    <InvariantGlobalization>true</InvariantGlobalization>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="{x(engine / 'Managed' / 'Tallow.ManagedRuntime' / 'Tallow.ManagedRuntime.csproj')}" />
    <!-- The interpreter finds Tallow's and the game's code by reflection (the registry, the signatures). -->
    <TrimmerRootAssembly Include="Tallow.ManagedRuntime" />
    <TrimmerRootAssembly Include="Tallow.API" />
{references}    <!-- .NET's own pass after linking: the engine's code uses atomic instructions (see LINK_FLAGS). -->
    <WasmOptConfigurationFlags Include="--enable-threads" />
{natives_items}  </ItemGroup>
</Project>
''')
        published = app / 'out'
        result = subprocess.run(['dotnet', 'publish', str(app / 'TallowWeb.csproj'), '-c', config, '-o', str(published)],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.returncode != 0:
            problems = [line for line in result.stdout.splitlines() if ' error ' in line or 'undefined symbol' in line or 'error:' in line]
            raise SystemExit('The C# web build failed:\n' + '\n'.join(problems[-30:] or result.stdout.splitlines()[-40:]))
        shutil.copytree(published / 'wwwroot' / '_framework', staging / '_framework')
    size = sum(file.stat().st_size for file in (staging / '_framework').rglob('*') if file.is_file())
    print(f'C# for the web: .NET bundle {size // (1024 * 1024)} MB')


def setup(engine):
    """Once: .NET {DOTNET_MAJOR} for web builds (into ~/.local/share/tallow-web/dotnet), its wasm-tools workload, and
    the engine's native libraries built with that workload's Emscripten."""
    root = dotnet_root()
    if root is None:
        home = WEB_HOME / 'dotnet'
        launcher = engine / 'build' / 'Debug_Linux64' / 'TallowLauncher' / 'TallowLauncher'
        existing = next((entry for entry in sorted(home.iterdir(), reverse=True) if (entry / 'dotnet').is_file()), None) if home.is_dir() else None
        if existing is None:
            if not launcher.is_file():
                raise SystemExit(f'Build the engine first (./build.sh): its launcher installs Tallow\'s .NET SDK.')
            subprocess.run([str(launcher), '--install-dotnet'], check=True, env=dict(os.environ, TALLOW_DOTNET_HOME=str(home)))
            existing = next(entry for entry in sorted(home.iterdir(), reverse=True) if (entry / 'dotnet').is_file())
        env = dict(os.environ, DOTNET_ROOT=str(existing), PATH=f'{existing}{os.pathsep}{os.environ.get("PATH", "")}', DOTNET_NOLOGO='1')
        subprocess.run([str(existing / 'dotnet'), 'workload', 'install', 'wasm-tools'], check=True, env=env)
        root = dotnet_root()
        if root is None:
            raise SystemExit('The wasm-tools workload did not install its Emscripten.')
    env = environment(root)
    build_natives(engine, env)
    print(f'Done: C# games build for the web with {root} and {natives_folder(engine)}.')


if __name__ == '__main__':
    if sys.argv[1:] == ['setup']:
        setup(Path(__file__).resolve().parent.parent.parent)
    else:
        print(__doc__)
        sys.exit(2)
