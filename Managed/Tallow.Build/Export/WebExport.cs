using System.Security;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// C# games for the web: the engine, its precompiled player and .NET in one WebAssembly module. In a browser .NET's
/// own start-up must run first (it is a page script), so a C# web player is a .NET browser app
/// (Microsoft.NET.Sdk.WebAssembly) whose native part is relinked with the engine: the player's Beef code (compiled for
/// wasm32 and archived: build/web-player/libTallowPlayer_&lt;config&gt;.a), Beef's runtime
/// (build/web-player/Beef*_dotnet.a) and the engine's native libraries built with the Emscripten that .NET's
/// wasm-tools workload ships (build/native-web-dotnet). Engine packages carry all three; an engine source checkout
/// with the Beef compiler makes them (<c>Tallow.Build web-setup</c>). The machine needs only .NET with the
/// wasm-tools workload, which <c>web-setup</c> installs.
/// </summary>
internal static class WebExport
{
    static readonly string[] NativeLibs =
    {
        "libtallow_native.a", "bgfx/cmake/bgfx/libbgfx.a", "bgfx/cmake/bimg/libbimg.a", "bgfx/cmake/bimg/libbimg_decode.a",
        "bgfx/cmake/bx/libbx.a", "SDL/libSDL3.a", "joltc/libjoltc.a", "_deps/joltphysics-build/libJolt.a", "enet/libenet.a"
    };
    // .NET's own list of runtime methods its JavaScript uses and the engine's: wasmTable (Beef's reflection calls), FS
    // and the run dependencies (the page writes the asset pack and mounts the save folder), HEAPF32 (Web Audio).
    const string RuntimeMethods = "FS,out,err,ccall,cwrap,setValue,getValue,UTF8ToString,UTF8ArrayToString,lengthBytesUTF8," +
        "stringToUTF8Array,FS_createPath,FS_createDataFile,removeRunDependency,addRunDependency,addFunction," +
        "safeSetTimeout,runtimeKeepalivePush,runtimeKeepalivePop,maybeExit,abort,HEAP8,HEAP16,HEAPU8,HEAPU16," +
        "HEAP32,HEAPU32,HEAPF32,HEAPF64,HEAP64,HEAPU64,wasmExports,wasmTable";

    static string WebHome()
    {
        string? fromEnvironment = Environment.GetEnvironmentVariable("TALLOW_WEB_HOME");
        if (!string.IsNullOrEmpty(fromEnvironment))
            return fromEnvironment;
        if (ExportUtil.HostLinux)
        {
            string? xdg = Environment.GetEnvironmentVariable("XDG_DATA_HOME");
            return Path.Combine(string.IsNullOrEmpty(xdg) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share") : xdg, "tallow-web");
        }
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tallow-web");
    }

    /// <summary>Whether a C# game's web build has threads. TALLOW_WEB_THREADS=1 turns them on; off by default, which
    /// keeps the single-threaded page every browser can run. With threads the page must be cross-origin isolated
    /// (tools/web/shell/coi-serviceworker.js, tallowengine.com/docs/web).</summary>
    public static bool ThreadsEnabled() =>
        (Environment.GetEnvironmentVariable("TALLOW_WEB_THREADS") ?? "0").Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";

    static string Exe(string path) => ExportUtil.HostWindows ? path + ".exe" : path;

    /// <summary>The workload's Emscripten (its tools/ folder) in a .NET folder, or null.</summary>
    static string? EmscriptenPack(string root)
    {
        string packs = Path.Combine(root, "packs");
        if (!Directory.Exists(packs))
            return null;
        foreach (string pack in Directory.EnumerateDirectories(packs, "Microsoft.NET.Runtime.Emscripten.*.Sdk.*").OrderDescending(StringComparer.Ordinal))
            foreach (string version in Directory.EnumerateDirectories(pack).OrderDescending(StringComparer.Ordinal))
            {
                string emscripten = Path.Combine(version, "tools", "emscripten");
                if (File.Exists(Path.Combine(emscripten, "emcc")) || File.Exists(Path.Combine(emscripten, "emcc.bat")))
                    return Path.Combine(version, "tools");
            }
        return null;
    }

    /// <summary>A .NET 11 SDK with the wasm-tools workload: TALLOW_WEB_DOTNET, the one web-setup installed, or the
    /// .NET running this tool.</summary>
    static string? DotNetRoot()
    {
        var candidates = new List<string>();
        if (Environment.GetEnvironmentVariable("TALLOW_WEB_DOTNET") is { Length: > 0 } chosen)
            candidates.Add(chosen);
        string home = Path.Combine(WebHome(), "dotnet");
        if (Directory.Exists(home))
            candidates.AddRange(Directory.EnumerateDirectories(home).OrderDescending(StringComparer.Ordinal));
        if (DotNetRuntime.HostRoot() is { } host)
            candidates.Add(host);
        return candidates.FirstOrDefault(root => File.Exists(Exe(Path.Combine(root, "dotnet"))) && EmscriptenPack(root) != null);
    }

    /// <summary>Environment for running the workload's Emscripten and its dotnet.</summary>
    static Dictionary<string, string> WebEnvironment(string root)
    {
        string tools = EmscriptenPack(root)!;
        string packs = Path.Combine(root, "packs");
        string? node = Directory.EnumerateDirectories(packs, "Microsoft.NET.Runtime.Emscripten.*.Node.*")
            .SelectMany(pack => Directory.EnumerateDirectories(pack))
            .Select(version => Exe(Path.Combine(version, "tools", "bin", "node"))).FirstOrDefault(File.Exists);
        string cache = Path.Combine(WebHome(), "emcache-dotnet");
        if (!Directory.Exists(Path.Combine(cache, "sysroot")))
        {
            // Emscripten writes to its cache (it checks its sanity there), so it gets a copy of the workload's own.
            string? shipped = Directory.EnumerateDirectories(packs, "Microsoft.NET.Runtime.Emscripten.*.Cache.*")
                .SelectMany(pack => Directory.EnumerateDirectories(pack))
                .Select(version => Path.Combine(version, "tools", "emscripten", "cache")).FirstOrDefault(Directory.Exists);
            if (shipped != null)
                ExportUtil.CopyTree(shipped, cache);
        }
        var environment = new Dictionary<string, string>
        {
            ["DOTNET_ROOT"] = root, ["DOTNET_NOLOGO"] = "1", ["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1",
            ["DOTNET_EMSCRIPTEN_LLVM_ROOT"] = Path.Combine(tools, "bin"), ["DOTNET_EMSCRIPTEN_BINARYEN_ROOT"] = tools,
            ["EM_CONFIG"] = Path.Combine(tools, "emscripten", ".emscripten"), ["EM_CACHE"] = cache, ["FROZEN_CACHE"] = "",
            ["PATH"] = string.Join(Path.PathSeparator, root, Path.Combine(tools, "emscripten"), Path.Combine(tools, "bin"),
                Environment.GetEnvironmentVariable("PATH") ?? ""),
        };
        if (node != null)
            environment["DOTNET_EMSCRIPTEN_NODE_JS"] = node;
        return environment;
    }

    static string LlvmAr(string root) => Exe(Path.Combine(EmscriptenPack(root)!, "bin", "llvm-ar"));

    public static string NativesFolder(string engine) => Path.Combine(engine, "build", "native-web-dotnet");

    static string? Beef()
    {
        string name = Environment.GetEnvironmentVariable("BEEFBUILD") is { Length: > 0 } chosen ? chosen : "BeefBuild";
        return File.Exists(name) ? Path.GetFullPath(name) : ExportUtil.Which(name);
    }

    /// <summary>Beef's WebAssembly runtime as .NET's link needs it: the engine package's copy, or (with Beef) made from
    /// Beef's own. Its WasmCommon.o defines a stand-in _Unwind_GetIP; .NET links the real one, so the copy renames the
    /// stand-in (a name of the same length) and every other caller gets the real one.</summary>
    static string BeefRuntime(string engine, string root)
    {
        string pattern = ThreadsEnabled() ? "Beef*RT32_wasm_pthread_dotnet.a" : "Beef*RT32_wasm_dotnet.a";
        string folder = Path.Combine(engine, "build", "web-player");
        string? beef = Beef();
        string? source = null;
        if (beef != null)
        {
            string dist = Path.GetDirectoryName(new FileInfo(beef).ResolveLinkTarget(true)?.FullName ?? beef)!;
            source = Directory.EnumerateFiles(dist, ThreadsEnabled() ? "Beef*RT32_wasm_pthread.a" : "Beef*RT32_wasm.a").Order(StringComparer.Ordinal).FirstOrDefault();
        }
        if (source == null)
        {
            string? packaged = Directory.Exists(folder) ? Directory.EnumerateFiles(folder, pattern).Order(StringComparer.Ordinal).FirstOrDefault() : null;
            return packaged ?? throw new ExportException($"Beef's WebAssembly runtime ({pattern}) is missing from {folder}. Engine packages carry it; " +
                "in an engine source checkout run Tallow.Build web-setup with the Beef compiler on PATH.");
        }
        string target = Path.Combine(folder, Path.GetFileNameWithoutExtension(source) + "_dotnet.a");
        if (File.Exists(target) && File.GetLastWriteTimeUtc(target) >= File.GetLastWriteTimeUtc(source))
            return target;
        Directory.CreateDirectory(folder);
        string work = Directory.CreateTempSubdirectory("tallow-beefrt-").FullName;
        try
        {
            string ar = LlvmAr(root);
            Check(ExportUtil.Run(ar, new[] { "x", source, "WasmCommon.o" }, true, work), "llvm-ar x");
            string member = Path.Combine(work, "WasmCommon.o");
            byte[] data = File.ReadAllBytes(member);
            byte[] old = Encoding.ASCII.GetBytes("\x0d_Unwind_GetIP"), replacement = Encoding.ASCII.GetBytes("\x0d_BfStub_GetIP");
            int first = data.AsSpan().IndexOf(old);
            if (first >= 0 && data.AsSpan(first + 1).IndexOf(old) < 0)
            {
                replacement.CopyTo(data, first);
                File.WriteAllBytes(member, data);
            }
            string temporary = Path.ChangeExtension(target, ".tmp");
            File.Copy(source, temporary, true);
            Check(ExportUtil.Run(ar, new[] { "r", temporary, member }, true), "llvm-ar r");
            File.Move(temporary, target, true);
        }
        finally
        {
            Directory.Delete(work, true);
        }
        return target;
    }

    static void Check(ExportUtil.Result result, string what)
    {
        if (result.ExitCode != 0)
            throw new ExportException($"{what} failed:\n{result.All.Trim()}");
    }

    /// <summary>Player/ compiled for wasm32 as an application in a static library (BeefStart runs its Main), archived
    /// from the objects Beef's own link step names: the engine package's copy, or (with Beef and Player/src) built in
    /// build/web-player, so later builds are incremental.</summary>
    public static string PlayerLibrary(string engine, string config, string root)
    {
        string work = Path.Combine(engine, "build", "web-player");
        string library = Path.Combine(work, $"libTallowPlayer_{config}.a");
        string? beef = Beef();
        if (beef == null || !Directory.Exists(Path.Combine(engine, "Player", "src")))
            return File.Exists(library) ? library : throw new ExportException($"The web player ({library}) is missing. Engine packages carry it; " +
                "in an engine source checkout run Tallow.Build web-setup with the Beef compiler on PATH.");
        string source = Path.Combine(work, "src");
        if (Directory.Exists(source))
            Directory.Delete(source, true);
        ExportUtil.CopyTree(Path.Combine(engine, "Player", "src"), source);
        string Q(string text) => "\"" + text.Replace('\\', '/') + "\"";
        File.WriteAllText(Path.Combine(work, "BeefSpace.toml"), "FileVersion = 1\nProjects = {TallowPlayer = {Path = \".\"}, Tallow = {Path = " +
            Q(Path.Combine(engine, "Engine")) + "}}\n[Workspace]\nStartupProject = \"TallowPlayer\"\n" +
            $"[Configs.{config}.wasm32]\nToolset = \"GNU\"\n" + (config == "Release" ? "EmitDebugInfo = \"No\"\n" : ""));
        File.WriteAllText(Path.Combine(work, "BeefProj.toml"), "FileVersion = 1\nDependencies = {corlib = \"*\", Tallow = \"*\"}\n[Project]\nName = \"TallowPlayer\"\n" +
            "TargetType = \"BeefApplication_StaticLib\"\nStartupObject = \"Tallow.Player.Program\"\n");
        string output = Path.Combine(work, "build", $"{config}_wasm32", "TallowPlayer");
        // Beef does not make this folder itself for a library.
        Directory.CreateDirectory(output);
        if (ExportUtil.Run(beef, new[] { $"-workspace={work}", $"-config={config}", "-platform=wasm32", "-verbosity=minimal" }).ExitCode != 0)
            throw new ExportException("The web player's Beef build failed.");
        // For wasm32 Beef links a page as well, whatever the target type; that page's link line names exactly the
        // objects of this build (older objects of renamed types can linger in the folders).
        string line = ExportUtil.ReadText(Path.Combine(output, "TallowPlayer.html.build.txt"));
        var objects = Regex.Matches(line, @"""([^""]+\.o)""|(\S+\.o)\b")
            .Select(match => match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value)
            .Distinct().Where(File.Exists).ToList();
        if (!objects.Any(path => Path.GetFileName(path) == "vdata.o"))
            throw new ExportException("The web player's Beef build named no objects.");
        File.Delete(library);
        string listing = Path.Combine(work, "objects.rsp");
        File.WriteAllText(listing, string.Join('\n', objects.Select(path => $"\"{path}\"")));
        Check(ExportUtil.Run(LlvmAr(root), new[] { "rcs", library, "@" + listing }, true), "llvm-ar rcs");
        File.Delete(listing);
        return library;
    }

    static string X(string text) => SecurityElement.Escape(text);

    static string[] LinkFlags()
    {
        string methods = RuntimeMethods + (ThreadsEnabled() ? ",PThread" : "");
        return new[]
        {
            "-matomics", "-mbulk-memory", "-sUSE_WEBGL2=1", "-sMIN_WEBGL_VERSION=2", "-sMAX_WEBGL_VERSION=2", "-sFULL_ES3=1",
            "-lidbfs.js", "-sINITIAL_MEMORY=268435456", $"-sEXPORTED_RUNTIME_METHODS={methods}",
            // The browser glue (native/tallow_web.c) is JavaScript the linker only takes from the archive when asked.
            "-Wl,-u,tn_web_free"
        };
    }

    /// <summary>The page's .NET bundle (_framework/) for the C# game at <paramref name="project"/>, into staging.</summary>
    public static void Build(string engine, string project, string config, string staging)
    {
        string root = DotNetRoot() ?? throw new ExportException(
            $"C# games for the web need .NET {DotNetRuntime.Major} with the wasm-tools workload. Set it up once with the editor's " +
            "Build window, or: dotnet <engine>/Managed/Tallow.Build/bin/Debug/net11.0/Tallow.Build.dll web-setup");
        var environment = WebEnvironment(root);
        string natives = NativesFolder(engine);
        if (!File.Exists(Path.Combine(natives, "libtallow_native.a")))
            throw new ExportException($"The native libraries for C# web games are missing from {natives}. Engine packages carry them; " +
                "in an engine source checkout run Tallow.Build web-setup.");
        string library = PlayerLibrary(engine, config, root);
        string runtime = BeefRuntime(engine, root);
        string app = Directory.CreateTempSubdirectory("tallow-web-cs-").FullName;
        try
        {
            // The name the managed P/Invokes bind the engine's functions by (WebHost's "tallowengine").
            File.WriteAllText(Path.Combine(app, "tallowengine.c"), "int tallow_engine_module(void) { return 1; }\n");
            File.WriteAllText(Path.Combine(app, "Program.cs"), "public static class TallowWebMain\n{\n    public static int Main(string[] args) => Tallow.ManagedRuntime.WebHost.Run(args);\n}\n");
            var references = new StringBuilder();
            foreach (string dll in NativeAot.GameAssemblies(project, config))
            {
                string stem = Path.GetFileNameWithoutExtension(dll);
                references.Append($"    <Reference Include=\"{X(stem)}\"><HintPath>{X(dll)}</HintPath></Reference>\n");
                references.Append($"    <TrimmerRootAssembly Include=\"{X(stem)}\" />\n");
            }
            var nativeItems = new StringBuilder();
            foreach (string path in new[] { Path.Combine(app, "tallowengine.c"), library, runtime }.Concat(NativeLibs.Select(lib => Path.Combine(natives, lib))))
                nativeItems.Append($"    <NativeFileReference Include=\"{X(path)}\" />\n");
            bool threads = ThreadsEnabled();
            // No Emscripten pool: .NET's runtime builds the pool itself. The offscreen framebuffer lets the game (on
            // .NET's deputy worker) draw through the page's WebGL context, proxied to its thread.
            string threadFlags = threads ? "-pthread -sDEFAULT_PTHREAD_STACK_SIZE=1048576 -sOFFSCREEN_FRAMEBUFFER=1 -sGL_SUPPORT_EXPLICIT_SWAP_CONTROL=1 " : "";
            string threadsProperty = threads ? "    <!-- .NET's own threads (System.Threading), tied to the module's. -->\n    <WasmEnableThreads>true</WasmEnableThreads>\n" : "";
            string managedRuntime = Path.Combine(engine, "Managed", "Tallow.ManagedRuntime", "Tallow.ManagedRuntime.csproj");
            File.WriteAllText(Path.Combine(app, "TallowWeb.csproj"), $"""
                <Project Sdk="Microsoft.NET.Sdk.WebAssembly">
                  <PropertyGroup>
                    <TargetFramework>net{DotNetRuntime.Major}.0</TargetFramework>
                    <OutputType>Exe</OutputType>
                    <AssemblyName>TallowWeb</AssemblyName>
                    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
                    <Nullable>enable</Nullable>
                    <WasmBuildNative>true</WasmBuildNative>
                    <EmccStackSize>8388608</EmccStackSize>
                {threadsProperty}    <EmccExtraLDFlags>{X(threadFlags + string.Join(' ', LinkFlags()))}</EmccExtraLDFlags>
                    <!-- Every file is served as it is: GitHub Pages and itch.io do not serve the precompressed copies. -->
                    <CompressionEnabled>false</CompressionEnabled>
                    <InvariantGlobalization>true</InvariantGlobalization>
                  </PropertyGroup>
                  <ItemGroup>
                    <ProjectReference Include="{X(managedRuntime)}" />
                    <!-- The interpreter finds Tallow's and the game's code by reflection (the registry, the signatures). -->
                    <TrimmerRootAssembly Include="Tallow.ManagedRuntime" />
                    <TrimmerRootAssembly Include="Tallow.API" />
                {references}    <!-- .NET's own pass after linking: the engine's code uses atomic instructions. -->
                    <WasmOptConfigurationFlags Include="--enable-threads" />
                {nativeItems}  </ItemGroup>
                </Project>

                """);
            string published = Path.Combine(app, "out");
            var result = ExportUtil.Run(Exe(Path.Combine(root, "dotnet")), new[] { "publish", Path.Combine(app, "TallowWeb.csproj"), "-c", config, "-o", published },
                true, null, environment);
            if (result.ExitCode != 0)
            {
                var lines = result.All.Split('\n');
                var problems = lines.Where(line => line.Contains(" error ") || line.Contains("undefined symbol") || line.Contains("error:")).ToList();
                throw new ExportException("The C# web build failed:\n" + string.Join('\n', problems.Count > 0 ? problems.TakeLast(30) : lines.TakeLast(40)));
            }
            ExportUtil.CopyTree(Path.Combine(published, "wwwroot", "_framework"), Path.Combine(staging, "_framework"));
            if (threads)
                CapRuntimeCores(Path.Combine(staging, "_framework", "dotnet.js"));
        }
        finally
        {
            Directory.Delete(app, true);
        }
        Console.WriteLine($"C# for the web: .NET bundle {ExportUtil.Size(Path.Combine(staging, "_framework")) / (1024 * 1024)} MB");
    }

    /// <summary>Caps the cores .NET's runtime sees at 8, in every thread it starts: .NET cannot add workers to its
    /// pool after start-up, so the page pre-creates it, and this keeps a game's demand within it. The loader
    /// (dotnet.js) is the script every worker and the page run first, so a few lines at its top do it.</summary>
    static void CapRuntimeCores(string loader)
    {
        string text = File.ReadAllText(loader);
        const string marker = "/* Tallow: cap the cores .NET sees";
        if (text.Contains(marker, StringComparison.Ordinal))
            return;
        string prelude = marker + """
             (see Tallow.Build's WebExport). */
            try {
                var tallowCores = Math.max(2, Math.min((typeof navigator !== "undefined" && navigator.hardwareConcurrency) || 4, 8));
                Object.defineProperty(navigator, "hardwareConcurrency", { get: function () { return tallowCores; }, configurable: true });
            } catch (error) {}

            """;
        File.WriteAllText(loader, prelude + text);
    }

    /// <summary>The page that loads and runs a web player: index.html, its install manifest and icon.</summary>
    public static void WritePage(string engine, string project, string name, string staging)
    {
        string shell = Path.Combine(engine, "tools", "web", "shell");
        string pack = File.Exists(Path.Combine(staging, "game.tpak")) ? "game.tpak" : "";
        // Scene packs download after the game has started, smallest first; the game asks for one it needs sooner.
        var later = Directory.EnumerateFiles(staging, "*.tpak").Where(file => Path.GetFileName(file) != "game.tpak")
            .OrderBy(file => new FileInfo(file).Length).Select(Path.GetFileName).ToList();
        string laterList = JsonSerializer.Serialize(later).Replace(",", ", ");
        foreach (string file in new[] { "index.html", "manifest.webmanifest" })
        {
            string text = File.ReadAllText(Path.Combine(shell, file)).Replace("{{NAME}}", name).Replace("{{SCRIPT}}", "_framework/dotnet.js")
                .Replace("{{RUNTIME}}", "dotnet").Replace("{{PACK}}", pack).Replace("{{LATER_PACKS}}", laterList)
                .Replace("{{THREADS}}", ThreadsEnabled() ? "true" : "false");
            File.WriteAllText(Path.Combine(staging, file), text);
        }
        // Multiplayer between browsers (WebRTC), and cross-origin isolation for a threaded build where the host cannot
        // set headers (see the files).
        foreach (string file in new[] { "tallow-net.js", "coi-serviceworker.js" })
            File.Copy(Path.Combine(shell, file), Path.Combine(staging, file), true);
        string? icon = new[] { Path.Combine(project, "icon.png"), Path.Combine(project, "src", "icon.png"), Path.Combine(engine, "icon.png") }.FirstOrDefault(File.Exists);
        if (icon != null)
            File.Copy(icon, Path.Combine(staging, "icon.png"), true);
        // GitHub Pages runs its own site generator (Jekyll) over a folder unless told not to (it would also leave out
        // _framework/, as it skips folders starting with _).
        File.WriteAllText(Path.Combine(staging, ".nojekyll"), "");
    }

    /// <summary><c>web-setup</c>: once per machine, .NET's wasm-tools workload (into Tallow's own .NET when that is
    /// the one running, else into a private copy). In an engine source checkout, also the engine's native libraries
    /// built with the workload's Emscripten, and with the Beef compiler the web player and Beef's runtime.</summary>
    public static int Setup(string[] args)
    {
        try
        {
            string engine = args.Length > 0 && args[0] is { } given && !given.StartsWith("--", StringComparison.Ordinal) ? Path.GetFullPath(given)
                : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
            string? root = DotNetRoot();
            if (root == null)
            {
                string? host = DotNetRuntime.HostRoot();
                if (host == null)
                    throw new ExportException("The .NET running this tool was not found.");
                if (!Writable(host))
                {
                    // A system-wide .NET cannot take a workload without administrator rights: a private copy does.
                    string home = Path.Combine(WebHome(), "dotnet");
                    string launcher = new[] { Path.Combine(engine, "Tallow"), Path.Combine(engine, "Tallow.exe"),
                        Path.Combine(engine, "build", "Debug_Linux64", "TallowLauncher", "TallowLauncher") }.FirstOrDefault(File.Exists)
                        ?? throw new ExportException($"The .NET in {host} cannot be changed without administrator rights, and Tallow's launcher " +
                            "was not found to install a private copy. Run: sudo dotnet workload install wasm-tools");
                    ExportUtil.Run(launcher, new[] { "--install-dotnet" }, false, null, new Dictionary<string, string> { ["TALLOW_DOTNET_HOME"] = home });
                    host = Directory.Exists(home) ? Directory.EnumerateDirectories(home).OrderDescending(StringComparer.Ordinal)
                        .FirstOrDefault(entry => File.Exists(Exe(Path.Combine(entry, "dotnet")))) : null;
                    if (host == null)
                        throw new ExportException("Installing a private .NET for web builds did not work.");
                }
                Console.WriteLine($"Installing .NET's wasm-tools workload into {host} (about 1 GB, once)...");
                int installed = ExportUtil.Run(Exe(Path.Combine(host, "dotnet")), new[] { "workload", "install", "wasm-tools" }, false, null,
                    new Dictionary<string, string> { ["DOTNET_ROOT"] = host, ["DOTNET_NOLOGO"] = "1" }).ExitCode;
                root = DotNetRoot();
                if (installed != 0 || root == null)
                    throw new ExportException("The wasm-tools workload did not install its Emscripten.");
            }
            var environment = WebEnvironment(root);
            // An engine source checkout builds the web pieces an engine package carries.
            if (Directory.Exists(Path.Combine(engine, "native")) && Args(args, "--engine-pieces"))
            {
                BuildNatives(engine, environment);
                if (Beef() != null)
                {
                    // Release only: engine packages export Release web builds (a source checkout with Beef makes Debug
                    // ones as it exports them). Beef's runtime both with and without threads (TALLOW_WEB_THREADS).
                    PlayerLibrary(engine, "Release", root);
                    string? threads = Environment.GetEnvironmentVariable("TALLOW_WEB_THREADS");
                    foreach (string mode in new[] { "0", "1" })
                    {
                        Environment.SetEnvironmentVariable("TALLOW_WEB_THREADS", mode);
                        BeefRuntime(engine, root);
                    }
                    Environment.SetEnvironmentVariable("TALLOW_WEB_THREADS", threads);
                }
            }
            Console.WriteLine($"Done: C# games build for the web with {root}.");
            return 0;
        }
        catch (ExportException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    static bool Args(string[] args, string flag) => args.Contains(flag);

    static bool Writable(string folder)
    {
        try
        {
            string probe = Path.Combine(folder, $".tallow-write-test-{Environment.ProcessId}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>The engine's native libraries built with the workload's Emscripten (their objects must match
    /// .NET's), always with -pthread: one build serves both a threaded module and a single-threaded one.</summary>
    static void BuildNatives(string engine, Dictionary<string, string> environment)
    {
        string output = NativesFolder(engine);
        string tools = EmscriptenPack(environment["DOTNET_ROOT"])!;
        string cmake = ExportUtil.Which("cmake") ?? throw new ExportException("CMake is needed to build the engine's native libraries.");
        // TextEdit's patch (third_party/TextEdit) is applied by the desktop build, which comes first in a source checkout.
        string toolchain = Path.Combine(tools, "emscripten", "cmake", "Modules", "Platform", "Emscripten.cmake");
        Check(ExportUtil.Run(cmake, new[] { "-S", Path.Combine(engine, "native"), "-B", output, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_TOOLCHAIN_FILE=" + toolchain, "-DCMAKE_C_FLAGS=-pthread", "-DCMAKE_CXX_FLAGS=-pthread" }, true, null, environment), "cmake (web)");
        var build = new List<string> { "--build", output, "-j", Environment.ProcessorCount.ToString(), "--target" };
        build.AddRange(new[] { "tallow_native", "bgfx", "bimg", "bimg_decode", "bx", "SDL3-static", "joltc", "Jolt", "enet" });
        if (ExportUtil.Run(cmake, build, false, null, environment).ExitCode != 0)
            throw new ExportException("Building the engine's native libraries for the web failed.");
    }
}
