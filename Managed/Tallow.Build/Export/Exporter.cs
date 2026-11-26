using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// <c>Tallow.Build export</c>: makes a game folder for Linux, Windows, macOS or the web from a C# project, with no
/// Python and no Beef compiler. A game ships the engine's precompiled player (Player/build/Release_&lt;platform&gt;, in
/// every engine package), its compiled assemblies (or one NativeAOT library), the .NET runtime for that platform, the
/// compiled shaders for its graphics backends and its assets, packed.
///
/// <code>
///   export &lt;project&gt; --output &lt;folder&gt; [--platform linux|windows|macos|web|android|ios] [--ios-simulator] [--config Release|Debug] [--replace]
///          [--scene S] [--fullscreen|--windowed] [--no-compress] [--no-texture-compression] [--single-pack] [--loose]
///          [--csharp-runtime jit|native] [--aot-warnings error|report] [--no-bundle-dotnet] [--engine-root E] [--zip]
/// </code>
///
/// Every export works from any machine (the .NET runtime for the target is downloaded once). NativeAOT: see
/// NativeAot.CanBuild; when the project asks for it and this machine cannot, the export uses JIT and says so.
/// --zip also writes &lt;output&gt;.zip with Unix permissions, which a Linux or macOS game made on Windows needs.
/// </summary>
internal static class Exporter
{
    sealed class Options
    {
        public string Project = "";
        public string Output = "";
        public string? Scene;
        public string Config = "Release";
        public Target Platform = ExportUtil.HostWindows ? Target.Windows : ExportUtil.HostMac ? Target.MacOS : Target.Linux;
        public bool Replace, Fullscreen, Windowed, NoCompress, NoTextureCompression, SinglePack, Loose, NoBundleDotNet, Zip, IosSimulator;
        public string? CSharpRuntime;
        public string AotWarnings = "error";
        public string? EngineRoot;
    }

    const string Usage = "usage: export <project> --output <folder> [--platform linux|windows|macos|web|android|ios] [--ios-simulator] [--config Release|Debug] " +
        "[--replace] [--scene S] [--fullscreen|--windowed] [--no-compress] [--no-texture-compression] [--single-pack] [--loose] " +
        "[--csharp-runtime jit|native] [--aot-warnings error|report] [--no-bundle-dotnet] [--engine-root E] [--zip]";

    static Options Parse(string[] args)
    {
        var options = new Options();
        bool haveProject = false, haveOutput = false;
        string Value(ref int i, string name)
        {
            if (i + 1 >= args.Length)
                throw new ExportException($"{name} needs a value.", true);
            return args[++i];
        }
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            switch (arg)
            {
                case "--": break;
                case "--output": options.Output = Value(ref i, arg); haveOutput = true; break;
                case "--scene": options.Scene = Value(ref i, arg); break;
                case "--config":
                    options.Config = Value(ref i, arg);
                    if (options.Config is not ("Debug" or "Release"))
                        throw new ExportException("--config is Debug or Release.", true);
                    break;
                case "--platform":
                    options.Platform = Value(ref i, arg) switch
                    {
                        "linux" => Target.Linux, "windows" => Target.Windows, "macos" => Target.MacOS, "web" => Target.Web, "android" => Target.Android, "ios" => Target.IOS,
                        var other => throw new ExportException($"--platform is linux, windows, macos, web, android or ios, not {other}.", true)
                    };
                    break;
                case "--replace": options.Replace = true; break;
                case "--fullscreen": options.Fullscreen = true; break;
                case "--windowed": options.Windowed = true; break;
                case "--no-compress": options.NoCompress = true; break;
                case "--no-texture-compression": options.NoTextureCompression = true; break;
                case "--single-pack": options.SinglePack = true; break;
                case "--loose": options.Loose = true; break;
                case "--no-bundle-dotnet": options.NoBundleDotNet = true; break;
                case "--zip": options.Zip = true; break;
                // iOS: an app for the iOS Simulator on this Mac instead of for iPhones and iPads.
                case "--ios-simulator": options.IosSimulator = true; break;
                // A Windows console belongs to the Beef player build; the precompiled player is the same either way.
                case "--console": break;
                case "--csharp-runtime":
                    options.CSharpRuntime = Value(ref i, arg);
                    if (options.CSharpRuntime is not ("jit" or "native"))
                        throw new ExportException("--csharp-runtime is jit or native.", true);
                    break;
                case "--aot-warnings":
                    options.AotWarnings = Value(ref i, arg);
                    if (options.AotWarnings is not ("error" or "report"))
                        throw new ExportException("--aot-warnings is error or report.", true);
                    break;
                case "--engine-root": options.EngineRoot = Value(ref i, arg); break;
                default:
                    if (arg.StartsWith("--", StringComparison.Ordinal) || haveProject)
                        throw new ExportException($"Unknown argument {arg}.\n{Usage}", true);
                    options.Project = arg;
                    haveProject = true;
                    break;
            }
        }
        if (!haveProject || !haveOutput)
            throw new ExportException(Usage, true);
        return options;
    }

    /// <summary>The engine this tool belongs to: the folder above Managed/Tallow.Build.</summary>
    static string ToolEngine()
    {
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder != null; folder = folder.Parent)
            if (Directory.Exists(Path.Combine(folder.FullName, "Engine", "src")) && Directory.Exists(Path.Combine(folder.FullName, "Managed", "Tallow.Build")))
                return folder.FullName;
        throw new ExportException("Cannot find the engine this tool belongs to; pass --engine-root.", true);
    }

    /// <summary>A legacy Beef gameplay project: Beef build files and Beef source.</summary>
    static bool BeefProject(string project) =>
        File.Exists(Path.Combine(project, "BeefProj.toml")) &&
        ExportUtil.Files(Path.Combine(project, "src")).Any(file => file.Relative.EndsWith(".bf", StringComparison.Ordinal) && !ExportUtil.Hidden(file.Relative));

    static string PlatformFolder(Target target) => target switch { Target.Windows => "Win64", Target.MacOS => "macOS", _ => "Linux64" };

    /// <summary>The engine's player without the editor, precompiled (every engine package carries one per desktop
    /// platform). In an engine source checkout with the Beef compiler, a missing one for this machine is built.</summary>
    static string Player(string engine, string config, Target target)
    {
        string platform = PlatformFolder(target);
        string executable = Path.Combine(engine, "Player", "build", $"{config}_{platform}", "TallowPlayer", target == Target.Windows ? "TallowPlayer.exe" : "TallowPlayer");
        if (File.Exists(executable))
            return executable;
        bool native = target == (ExportUtil.HostWindows ? Target.Windows : ExportUtil.HostMac ? Target.MacOS : Target.Linux);
        string beef = Environment.GetEnvironmentVariable("BEEFBUILD") is { Length: > 0 } chosen ? chosen : "BeefBuild";
        if (native && Directory.Exists(Path.Combine(engine, "Player", "src")) && (File.Exists(beef) || ExportUtil.Which(beef) != null))
        {
            Console.WriteLine($"Building the {target} player (engine source checkout)...");
            ExportUtil.Run(beef, new[] { $"-workspace={Path.Combine(engine, "Player")}", $"-config={config}", $"-platform={platform}", "-verbosity=minimal" });
        }
        if (!File.Exists(executable))
            throw new ExportException($"This engine has no precompiled {target} player ({executable}). Engine packages from the " +
                "release page carry the Linux, Windows and macOS players; an engine built from source has the one " +
                "for the machine that built it.");
        return executable;
    }

    /// <summary>Compiles a C# project's assemblies, optimised, into its build folder, and Tallow's runtime in that
    /// configuration.</summary>
    static void BuildGame(string engine, string project, string config)
    {
        string output = Path.Combine(project, "build", "csharp", config);
        if (Directory.Exists(output))
            Directory.Delete(output, true);
        int built = Program.Main(new[] { "--project", project, "--engine-root", engine, "--configuration", config, "--output", output });
        if (built != 0 || !File.Exists(Path.Combine(output, "Tallow.Game", "Tallow.Game.dll")))
            throw new ExportException("The C# scripts did not compile; fix the errors above and build again.");
        string runtime = Path.Combine(engine, "Managed", "Tallow.ManagedRuntime", "Tallow.ManagedRuntime.csproj");
        if (ExportUtil.Run("dotnet", new[] { "build", runtime, "--configuration", config, "--nologo", "--verbosity", "minimal" }).ExitCode != 0)
            throw new ExportException("Tallow's C# runtime did not build.");
    }

    /// <summary>Managed/Runtime (Tallow's runtime and API), Managed/Game (the game's assemblies, a folder each) and,
    /// unless told not to, dotnet/: the .NET runtime for the target, so that players need not install it.</summary>
    static void StageJit(string engine, string project, string staging, string config, string? rid)
    {
        string runtime = Path.Combine(engine, "Managed", "Tallow.ManagedRuntime", "bin", config, $"net{DotNetRuntime.Major}.0");
        string target = Path.Combine(staging, "Managed", "Runtime");
        Directory.CreateDirectory(target);
        foreach (string file in Directory.EnumerateFiles(runtime))
        {
            string name = Path.GetFileName(file);
            if ((name.EndsWith(".dll", StringComparison.Ordinal) || name.EndsWith(".json", StringComparison.Ordinal)) && !name.EndsWith(".dev.json", StringComparison.Ordinal))
                File.Copy(file, Path.Combine(target, name), true);
        }
        ExportUtil.CopyTree(Path.Combine(project, "build", "csharp", config), Path.Combine(staging, "Managed", "Game"),
            name => (config == "Release" && name.EndsWith(".pdb", StringComparison.Ordinal)) || name.EndsWith(".deps.json", StringComparison.Ordinal));
        // NuGet packages' licences (Tallow.Build writes them): beside the game, where players see them.
        string notices = Path.Combine(staging, "Managed", "Game", "THIRD-PARTY-NOTICES.txt");
        if (File.Exists(notices))
            File.Move(notices, Path.Combine(staging, "THIRD-PARTY-NOTICES.txt"), true);
        if (rid == null)
        {
            Console.WriteLine($".NET not bundled: players need the .NET {DotNetRuntime.Major} runtime installed.");
            return;
        }
        DotNetRuntime.Bundle(staging, rid);
    }

    public static int Run(string[] args)
    {
        try
        {
            Export(Parse(args));
            return 0;
        }
        catch (ExportException exception)
        {
            Console.Error.WriteLine(exception.Usage ? $"export: error: {exception.Message}" : exception.Message);
            return exception.Usage ? 2 : 1;
        }
    }

    static void Export(Options options)
    {
        string project = Path.GetFullPath(options.Project);
        string output = Path.GetFullPath(options.Output).TrimEnd('/', '\\');
        if (Directory.Exists(output) || File.Exists(output))
        {
            // Only ever delete a folder this tool made: an earlier build, recognised by its game.tallow or game.tpak.
            if (!options.Replace)
                throw new ExportException("Output already exists; choose a new folder to preserve the existing build, or pass --replace.", true);
            if (!Directory.Exists(output) || (Directory.EnumerateFileSystemEntries(output).Any() &&
                !File.Exists(Path.Combine(output, "game.tallow")) && !File.Exists(Path.Combine(output, "game.tpak")) &&
                !File.Exists(Path.Combine(output, "tallow-android.txt")) && !File.Exists(Path.Combine(output, "tallow-ios.txt"))))
                throw new ExportException($"{output} exists and is not an earlier build of a game, so it is left alone. Choose another folder.", true);
        }
        string manifest = Path.Combine(project, "project.tallow");
        if (!File.Exists(manifest))
            throw new ExportException($"Missing {manifest}. Tallow projects require project.tallow; regenerate or update the project before building.", true);
        var settings = ExportUtil.ReadSettings(manifest);
        Target target = options.Platform;
        bool windows = target == Target.Windows, web = target == Target.Web, macos = target == Target.MacOS, android = target == Target.Android, ios = target == Target.IOS;
        string recorded = settings.Get("engine");
        string engine = options.EngineRoot != null ? Path.GetFullPath(options.EngineRoot)
            : recorded.Length > 0 ? Path.GetFullPath(Path.IsPathRooted(recorded) ? recorded : Path.Combine(project, recorded)) : ToolEngine();
        // A project copied from another machine names an engine folder that is not here: use the engine this tool belongs to.
        if (!Directory.Exists(Path.Combine(engine, "Engine", "src")))
            engine = ToolEngine();
        if (BeefProject(project))
            throw new ExportException("This project has Beef gameplay scripts. This Tallow exports C# games only: convert the scripts to C#, " +
                "or build the project with an older Tallow.", true);
        string name = settings.Get("name");
        if (!Regex.IsMatch(name, "^[A-Za-z_][A-Za-z0-9_]*$"))
            throw new ExportException("Project name must be a valid identifier (letters, digits and _; not starting with a digit).", true);
        if (windows && options.Config != "Release")
            throw new ExportException("Windows players are built in the Release configuration only.", true);
        if (web && options.Loose)
            throw new ExportException("A web player always packs its assets: a browser loads one file far faster than thousands.", true);
        string scene = options.Scene ?? settings.Get("startScene", "Scenes/Main.tscene");
        string source = Path.Combine(project, "src");
        string scenePath = Path.GetFullPath(Path.Combine(source, scene));
        if (!scenePath.StartsWith(source + Path.DirectorySeparatorChar, StringComparison.Ordinal) || !File.Exists(scenePath))
            throw new ExportException("Start scene must exist inside the project src folder. Save it in the editor first.", true);

        // NativeAOT is the default; a project chooses JIT with csharpRuntime = jit. The web always runs .NET in the
        // browser, and NativeAOT is built only where NativeAot.CanBuild says: asked for on the command line, anywhere
        // else is an error; from the project, the export uses JIT.
        string runtime = options.CSharpRuntime ?? settings.Get("csharpRuntime", "native");
        // Android has no .NET to run the game's assemblies on: its C# is always compiled ahead of time, with Android
        // Studio's tools (the NDK installed into its SDK the first time).
        AndroidTools? androidTools = null;
        if (android)
        {
            if (options.CSharpRuntime == "jit")
                throw new ExportException("Android games always compile their C# ahead of time (NativeAOT); --csharp-runtime jit is not available.", true);
            runtime = "native";
            androidTools = Android.Require();
            Android.PlayerFolder(engine);
        }
        // iOS likewise runs no JIT; its C# is compiled with Xcode, on a Mac.
        if (ios)
        {
            if (options.CSharpRuntime == "jit")
                throw new ExportException("iOS games always compile their C# ahead of time (NativeAOT); --csharp-runtime jit is not available.", true);
            runtime = "native";
            if (Ios.Problem(options.IosSimulator) is { } problem)
                throw new ExportException(problem);
            if (!File.Exists(Ios.PlayerPath(engine, options.IosSimulator)))
                throw new ExportException($"This engine has no iOS player ({Ios.PlayerPath(engine, options.IosSimulator)}). Engine packages carry it; " +
                    "in an engine source checkout make it with tools/ios/build_player.sh.");
        }
        if (runtime is not ("jit" or "native"))
            throw new ExportException($"csharpRuntime in project.tallow is jit or native, not {runtime}.", true);
        if (runtime == "native" && !android && !ios && !NativeAot.CanBuild(target))
        {
            if (options.CSharpRuntime == "native")
                throw new ExportException(web ? "A web build always runs .NET in the browser; NativeAOT is not available for it."
                    : $"No NativeAOT build here: {NativeAot.WhyNot(target)}. Export with --csharp-runtime jit.", true);
            if (!web)
                Console.WriteLine($"note: exporting with the JIT runtime (.NET bundled): {NativeAot.WhyNot(target)}.");
            runtime = "jit";
        }
        bool nativeAot = runtime == "native";
        bool bundle = !options.NoBundleDotNet && settings.Get("bundleDotNet", "1") != "0";

        string? player = web || android || ios ? null : Player(engine, options.Config, target);
        // Nothing changed since the last build of this target? The game is already there: skip all of it. (Web,
        // Android and iOS have their own hosts and build files, so their exports always run.)
        string exportCache = Path.Combine(ExportCache.Root(project, target, options.Config), "export");
        string exportSignature = ExportCache.Hash("export-v" + ExportCache.Version, engine, target.ToString(), options.Config,
            name, scene, output, runtime, bundle ? "bundle" : "nobundle",
            string.Join("\n", settings.OrderBy(entry => entry.Key, StringComparer.Ordinal).Select(entry => entry.Key + "=" + entry.Value)),
            string.Join(",", options.Fullscreen, options.Windowed, options.NoCompress, options.NoTextureCompression, options.SinglePack,
                options.Loose, options.NoBundleDotNet, options.Zip, options.AotWarnings, options.CSharpRuntime ?? ""),
            ExportCache.TreeStamp(Path.Combine(project, "src")), ExportCache.FileStamp(manifest),
            ExportCache.TreeStamp(Path.Combine(engine, "Engine", "assets")), ExportCache.FileStamp(player ?? ""),
            ExportCache.ContentStamp(Path.Combine(engine, "Managed", "Tallow.API", "bin", options.Config, "net11.0", "Tallow.API.dll")),
            ExportCache.ContentStamp(Path.Combine(engine, "Managed", "Tallow.ManagedRuntime", "bin", options.Config, "net11.0", "Tallow.ManagedRuntime.dll")),
            ExportCache.FileStamp(typeof(Exporter).Assembly.Location));
        if (!web && !android && !ios && Directory.Exists(output) && (!options.Zip || File.Exists(output + ".zip")) &&
            ExportCache.Matches(exportCache, exportSignature))
        {
            ExportProgress.Report(1, "Unchanged");
            Console.WriteLine($"Nothing changed since the last build; the game is already at {output}.");
            return;
        }
        // --replace: free the old build now (the new one is staged beside it), so a big game does not need room for
        // both. Nothing has been written yet; if this build fails the old folder is gone, which is what --replace says.
        if (options.Replace && Directory.Exists(output))
            Directory.Delete(output, true);
        ExportProgress.Report(0.04, "Compiling the game's C#");
        // Builds for two systems may run at once (the editor starts them): the steps that share the project's build
        // folders take turns, the rest (assets, textures, packing) overlap.
        var gate = ExportProgress.Gate(project);
        BuildGame(engine, project, options.Config);
        ExportProgress.Report(0.2, nativeAot || android || ios ? "Compiling native code" : "Staging the runtime");

        string parent = Path.GetDirectoryName(output)!;
        Directory.CreateDirectory(parent);
        string staging = Path.Combine(parent, $"{Path.GetFileName(output)}-{Guid.NewGuid().ToString("N")[..8]}");
        Directory.CreateDirectory(staging);
        try
        {
            string executable = name + (windows ? ".exe" : "");
            // Android: the game's C# for each ABI, compiled into libraries the APK carries (Android.Package).
            var androidLibraries = new Dictionary<string, string>();
            string androidWork = Path.Combine(parent, $"{Path.GetFileName(output)}-android-{Guid.NewGuid().ToString("N")[..8]}");
            string? iosLibrary = null;
            // The game's native code is made while the assets are staged: the two share nothing but the disk.
            Task? aotTask = null;
            if (web)
                WebExport.Build(engine, project, options.Config, staging);
            else if (ios)
            {
                // The game's C# as a library, made into a framework by Ios.Package; its code ID stays with the game.
                string iosStaging = androidWork;
                NativeAot.Build(engine, project, options.Config, iosStaging, target, "", Symbols.Folder(output), options.AotWarnings, null, null, options.IosSimulator);
                iosLibrary = Path.Combine(iosStaging, "Managed", "Native", NativeAot.LibraryName(target));
                Directory.CreateDirectory(Path.Combine(staging, "Managed", "Native"));
                string codeId = Path.Combine(iosStaging, "Managed", "Native", "Tallow.Game.codeid");
                if (File.Exists(codeId))
                    File.Copy(codeId, Path.Combine(staging, "Managed", "Native", "Tallow.Game.codeid"), true);
                string notices = Path.Combine(iosStaging, "THIRD-PARTY-NOTICES.txt");
                if (File.Exists(notices))
                    File.Copy(notices, Path.Combine(staging, "THIRD-PARTY-NOTICES.txt"), true);
            }
            else if (android)
            {
                foreach (string abi in Android.Abis)
                {
                    string abiStaging = Path.Combine(androidWork, abi);
                    NativeAot.Build(engine, project, options.Config, abiStaging, target, "", Path.Combine(Symbols.Folder(output), abi),
                        options.AotWarnings, androidTools, abi);
                    androidLibraries[abi] = Path.Combine(abiStaging, "Managed", "Native", NativeAot.LibraryName(target));
                    string codeId = Path.Combine(abiStaging, "Managed", "Native", "Tallow.Game.codeid");
                    string notices = Path.Combine(abiStaging, "THIRD-PARTY-NOTICES.txt");
                    Directory.CreateDirectory(Path.Combine(staging, "Managed", "Native"));
                    if (File.Exists(codeId))
                        File.Copy(codeId, Path.Combine(staging, "Managed", "Native", "Tallow.Game.codeid"), true);
                    if (File.Exists(notices))
                        File.Copy(notices, Path.Combine(staging, "THIRD-PARTY-NOTICES.txt"), true);
                }
            }
            else
            {
                File.Copy(player!, Path.Combine(staging, executable), true);
                ExportUtil.MakeExecutable(Path.Combine(staging, executable));
                if (nativeAot)
                    // Private symbols beside the build, never in it. Started here and awaited after the assets are
                    // staged: the assets do not need the library, and a NativeAOT compile is minutes of CPU time.
                    aotTask = Task.Run(() => BuildNativeAot(engine, project, options.Config, staging, target, player!,
                        Symbols.Folder(output), options.AotWarnings));
                else
                {
                    string? rid = null;
                    if (bundle)
                        rid = windows ? "win-x64" : macos ? "osx-" + (Symbols.MachOArch(player!) ?? "x64") : "linux-x64";
                    StageJit(engine, project, staging, options.Config, rid);
                }
            }

            // A desktop build's NativeAOT compile keeps the gate (another build of the project must not compile at the
            // same time); it is let go once the compile has finished, below, after the assets are staged.
            if (aotTask == null)
                gate.Dispose();

            // Of the engine's files a game reads only the compiled shaders, and only those of the graphics backends it
            // can start on: Vulkan, plus OpenGL as the fallback on Linux; Vulkan on Windows; Metal on a Mac; WebGL 2 in
            // a browser.
            ExportProgress.Report(0.6, "Copying shaders and assets");
            string engineAssets = Path.Combine(engine, "Engine", "assets");
            string[] backends = target switch
            {
                Target.Web => new[] { "webgl" }, Target.Windows => new[] { "spirv" }, Target.MacOS => new[] { "metal" },
                // Android: Vulkan, and OpenGL ES 3 on phones without a good Vulkan driver.
                Target.Android => new[] { "spirv", "essl" }, Target.IOS => new[] { "metal" }, _ => new[] { "spirv", "glsl" }
            };
            foreach (string backend in backends)
            {
                string shaders = Path.Combine(engineAssets, "shaders", backend);
                if (!Directory.Exists(shaders))
                    throw new ExportException($"This engine has no {backend} shaders ({shaders}), which a {target} game needs.");
                ExportUtil.LinkTree(shaders, Path.Combine(staging, "Engine", "assets", "shaders", backend));
            }
            foreach (string file in Directory.EnumerateFiles(engineAssets))
                ExportUtil.LinkFile(file, Path.Combine(staging, "Engine", "assets", Path.GetFileName(file)));
            // The libraries' licences ask to travel with what is built from them.
            foreach (string licence in new[] { "LICENSE", "THIRD_PARTY_LICENSES.txt" })
                if (File.Exists(Path.Combine(engine, licence)))
                    ExportUtil.LinkFile(Path.Combine(engine, licence), Path.Combine(staging, licence));

            string[] codeSuffixes = { ".bf", ".tgraph", ".py", ".sh", ".tmeta", ".cs", ".csproj", ".tasmdef" };
            foreach (var (relative, file) in ExportUtil.Files(source))
            {
                string fileName = Path.GetFileName(file);
                if (codeSuffixes.Contains(Path.GetExtension(fileName)) || ExportUtil.Hidden(relative))
                    continue;
                // FBX, OBJ, ... and their import settings: the game gets the converted .glb instead (below).
                if (Models.IsConverted(fileName) || (fileName.EndsWith(".import", StringComparison.Ordinal) && Models.IsConverted(fileName[..^7])))
                    continue;
                // Linked, not copied: the staging folder reads these and the pack takes them; hard links keep a
                // 16 GB project from being copied (and from doubling its disk use) on every build.
                ExportUtil.LinkFile(file, Path.Combine(staging, "Assets", relative));
            }
            // Converted models (tallowengine.com/docs/model-import), as <file>.glb: the name the engine looks for when a
            // scene names the file itself.
            ExportProgress.Report(0.65, "Converting models");
            var (converted, conversionErrors) = Models.ConvertProject(project, engine);
            if (conversionErrors.Count > 0)
                throw new ExportException("Some models could not be converted:\n  " + string.Join("\n  ", conversionErrors));
            foreach (var (relative, path) in converted)
                ExportUtil.LinkFile(path, Path.Combine(staging, "Assets", relative + ".glb"));
            if (converted.Count > 0)
                Console.WriteLine($"Models: {converted.Count} converted to glTF");
            // Custom skyboxes as the cubes the game loads (tallowengine.com/docs/skybox): before the pictures are
            // compressed, so a panorama that is only a skybox is not compressed as a picture too. The host's player cooks.
            try
            {
                Target skyHost = ExportUtil.HostWindows ? Target.Windows : ExportUtil.HostMac ? Target.MacOS : Target.Linux;
                string? skyboxes = SkyboxCook.Run(Player(engine, options.Config, skyHost), staging, engine,
                    !web && !android && !ios && !options.NoTextureCompression && settings.Get("compressTextures", "1") != "0");
                if (skyboxes != null)
                    Console.WriteLine(skyboxes);
            }
            catch (ExportException exception)
            {
                Console.WriteLine("Note: the skyboxes were not cooked (" + exception.Message.Split('\n')[0] + "); the game imports them when it first draws them.");
            }
            // Pictures compressed for the graphics card (tallowengine.com/docs/textures): a .ktx beside each. Not for
            // the web, whose browsers do not all read the same compressed formats.
            // Nor for Android, whose graphics chips do not read the desktop's BC formats.
            // The compressed copies and the cooked streamed data write different files, so they go at once (as does the
            // native compile started above); the pack waits for all of them.
            Task<string>? texturesTask = null;
            Task<string?>? cookTask = null;
            if (!web && !android && !ios && !options.NoTextureCompression && settings.Get("compressTextures", "1") != "0" && Directory.Exists(Path.Combine(staging, "Assets")))
            {
                ExportProgress.Report(0.7, "Compressing textures");
                texturesTask = Task.Run(() => CompressTextures(project, engine, staging, settings, options, target));
            }
            if (!web && !android && !ios && settings.Get("cookStreaming", "1") != "0")
            {
                if (texturesTask == null)
                    ExportProgress.Report(0.8, "Cooking streamed data");
                cookTask = Task.Run(() => CookStreamed(project, engine, staging, options, target));
            }
            if (texturesTask != null && WaitFor(texturesTask) is { } texturesMessage)
                Console.WriteLine(texturesMessage);
            if (cookTask != null && WaitFor(cookTask) is { } cookMessage)
                Console.WriteLine(cookMessage);

            // The native compile has had the whole asset stage to itself on another core.
            if (aotTask != null)
            {
                WaitFor(aotTask);
                gate.Dispose();
            }
            ExportProgress.Report(0.85, "Stripping symbols");
            // A Release export ships a player with no debug information. Its matching symbols and a record of every
            // module's exact build identifier go to <output>-symbols beside the build, never inside it.
            if (!web && !android && !ios && options.Config == "Release")
            {
                string symbols = Symbols.Folder(output);
                string stripped = Path.Combine(staging, executable);
                Symbols.StripReleasePlayer(stripped, symbols, target, player);
                string? library = null;
                if (nativeAot)
                {
                    library = Path.Combine(staging, "Managed", "Native", NativeAot.LibraryName(target));
                    // The shipped library is stripped; the map comes from the private symbols it matches (Linux).
                    string privateSymbols = Path.Combine(symbols, Path.GetFileName(library) + ".dbg");
                    if (target == Target.Linux && File.Exists(privateSymbols))
                        Symbols.WriteMap(symbols, privateSymbols);
                }
                // NativeAOT keeps the ID beside its library; a JIT export keeps it with the game's assemblies.
                string codeIdFile = Path.Combine(staging, "Managed", "Native", "Tallow.Game.codeid");
                if (!File.Exists(codeIdFile))
                    codeIdFile = Path.Combine(staging, "Managed", "Game", "Tallow.Game", "Tallow.Game.codeid");
                string? codeId = File.Exists(codeIdFile) ? File.ReadAllText(codeIdFile).Trim() : null;
                string info = Symbols.WriteBuildInfo(symbols, engine, name, options.Config, target, nativeAot ? "native" : "jit", codeId, library, stripped);
                Console.WriteLine($"Build information in {info}; the package ships no symbols.");
            }
            ExportProgress.Report(0.88, "Writing the game's settings");
            // A web page cannot load Steam.
            string steam = web || android || ios ? "" : settings.Get("steamAppId");
            if (steam.Length > 0)
            {
                // A game that is not started from Steam says which app it is with this file, and needs Valve's
                // Steamworks library beside it: the project's own copy if it has one, else one found on this machine.
                File.WriteAllText(Path.Combine(staging, "steam_appid.txt"), steam + "\n");
                string library = windows ? "steam_api64.dll" : macos ? "libsteam_api.dylib" : "libsteam_api.so";
                string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                string? found = new[] { Path.Combine(project, library), Path.Combine(project, "Libraries", library),
                    Path.Combine(home, ".local", "share", "Steam", "steamrt64", library) }.FirstOrDefault(File.Exists);
                if (found != null)
                    File.Copy(found, Path.Combine(staging, library), true);
                else
                    Console.WriteLine($"Note: {library} was not found, so this build runs without Steam. Put the file from the Steamworks SDK in {project} and build again.");
            }
            // DLSS (NVIDIA's upscaler) needs its dlssRuntime library next to the game, and its licence notice goes with it. They
            // come from the SDK the engine's native build downloaded; without them the game still runs, DLSS is just not offered.
            if (!web && !android && !ios && !macos)
            {
                string sdkRoot = Path.Combine(engine, "build", "native", "sdk");
                string? dlss = Directory.Exists(sdkRoot) ? Directory.GetDirectories(sdkRoot, "dlss-*").OrderDescending().FirstOrDefault() : null;
                string dlssFolder = Path.Combine(dlss ?? "", "lib", windows ? "Windows_x86_64" : "Linux_x86_64", "rel");
                string? dlssRuntime = dlss != null && Directory.Exists(dlssFolder)
                    ? Directory.GetFiles(dlssFolder, windows ? "nvngx_dlss.dll" : "libnvidia-ngx-dlss.so*").FirstOrDefault() : null;
                if (dlssRuntime != null)
                {
                    File.Copy(dlssRuntime, Path.Combine(staging, Path.GetFileName(dlssRuntime)), true);
                    string notice = Path.Combine(dlss!, "LICENSE.txt");
                    if (File.Exists(notice))
                        File.Copy(notice, Path.Combine(staging, "NVIDIA-DLSS-LICENSE.txt"), true);
                    Console.WriteLine($"DLSS: copied {Path.GetFileName(dlssRuntime)}");
                }
                else
                    Console.WriteLine("Note: the DLSS dlssRuntime library was not found in the engine's build folder, so this build does not offer DLSS.");
            }
            string hrtf = settings.Get("audioHrtf");
            // How the game starts out: the project's Build setting, unless this run says otherwise. In a browser the
            // page fills the window, and the player chooses full screen.
            bool fullscreen = (settings.Get("fullscreen") == "1" || options.Fullscreen) && !options.Windowed && !web;
            var game = new StringBuilder($"name = {name}\nstartScene = {scene}\n");
            if (steam.Length > 0)
                game.Append($"steamAppId = {steam}\n");
            if (hrtf.Length > 0)
                game.Append($"audioHrtf = {hrtf}\n");
            if (fullscreen)
                game.Append("fullscreen = 1\n");
            foreach (string key in new[] { "antiCheat", "voiceChat", "voicePushToTalk", "voiceProximity", "voiceTeamOnly", "voiceKey",
                "loadSaveAtStart", "saveSlot", "windowWidth", "windowHeight", "escapeQuits" })
                if (settings.Get(key).Length > 0)
                    game.Append($"{key} = {settings[key]}\n");
            // Android: which ways a phone may hold the game (the manifest's screenOrientation; the player tells SDL).
            if (android || ios)
                game.Append($"orientation = {settings.Get("androidOrientation", settings.Get("orientation", "landscape"))}\n");
            string gameFile = Path.Combine(staging, "game.tallow");
            File.WriteAllText(gameFile, game.ToString());

            // Everything the game reads goes into one pack, unless the project (or --loose) says to leave it loose. A
            // web build's pack is downloaded by every player every time, so it is always compressed.
            ExportProgress.Report(0.92, "Packing assets");
            if (!options.Loose && settings.Get("packAssets", "1") != "0")
                Pack(project, staging, name, scene, settings, options, web);
            if (web)
                WebExport.WritePage(engine, project, name, staging);
            ExportProgress.Report(0.97, "Finishing");
            if (Directory.Exists(output))
                Directory.Delete(output, true);
            if (android)
            {
                // The game folder goes inside the APK; the output folder holds the APK.
                Android.Package(androidTools!, engine, project, staging, androidLibraries, output, name, settings, options.Config);
                Directory.Delete(staging, true);
                if (Directory.Exists(androidWork))
                    Directory.Delete(androidWork, true);
            }
            else if (ios)
            {
                Ios.Package(engine, project, staging, iosLibrary!, output, name, settings, options.IosSimulator);
                Directory.Delete(staging, true);
                if (Directory.Exists(androidWork))
                    Directory.Delete(androidWork, true);
            }
            else
                Directory.Move(staging, output);
        }
        catch
        {
            if (Directory.Exists(staging))
                Directory.Delete(staging, true);
            foreach (string leftover in Directory.EnumerateDirectories(Path.GetDirectoryName(output)!, Path.GetFileName(output) + "-android-*"))
                Directory.Delete(leftover, true);
            throw;
        }
        ExportProgress.Report(1, "Done");
        Console.WriteLine($"{target} player packaged at {output}; TallowEditor excluded.");
        if (options.Zip)
        {
            ExportUtil.WriteZip(output, output + ".zip");
            Console.WriteLine($"Zipped with its file permissions: {output}.zip");
        }
        // This build's inputs, so the next one with the same ones can skip the work.
        ExportCache.Save(exportCache, exportSignature);
    }

    /// <summary>Waits for a step running beside the export (the native compile, textures, the cook). GetResult rethrows
    /// what the step threw, not an AggregateException, so the build reports the same error as when it ran in line.</summary>
    static void WaitFor(Task task) => task.GetAwaiter().GetResult();
    static T WaitFor<T>(Task<T> task) => task.GetAwaiter().GetResult();

    /// <summary>The game's NativeAOT library, made again only when the game, the runtime or the player it goes into has
    /// changed (the result is kept in the build cache).</summary>
    static void BuildNativeAot(string engine, string project, string config, string staging, Target target, string player,
        string symbols, string warningsMode)
    {
        string cache = Path.Combine(ExportCache.Root(project, target, config), "aot");
        string gameTree = ExportCache.ContentTreeStamp(Path.Combine(project, "build", "csharp", config), ".dll", ".codeid");
        string apiTree = ExportCache.ContentTreeStamp(Path.Combine(engine, "Managed", "Tallow.API", "bin", config), ".dll");
        string runtimeTree = ExportCache.ContentTreeStamp(Path.Combine(engine, "Managed", "Tallow.ManagedRuntime", "bin", config), ".dll");
        string playerStamp = ExportCache.FileStamp(player);
        string toolStamp = ExportCache.FileStamp(typeof(NativeAot).Assembly.Location);
        string signature = ExportCache.Hash("aot-v" + ExportCache.Version, target.ToString(), config, warningsMode,
            gameTree, apiTree, runtimeTree, playerStamp, toolStamp);
        if (Environment.GetEnvironmentVariable("TALLOW_BUILD_DEBUG") == "1")
            Console.WriteLine($"aot debug: game={gameTree} api={apiTree} runtime={runtimeTree} player={playerStamp} tool={toolStamp}");
        if (ExportCache.Matches(cache, signature) && Directory.Exists(Path.Combine(cache, "managed")))
        {
            ExportUtil.LinkTree(Path.Combine(cache, "managed"), Path.Combine(staging, "Managed"));
            if (File.Exists(Path.Combine(cache, "THIRD-PARTY-NOTICES.txt")))
                ExportUtil.LinkFile(Path.Combine(cache, "THIRD-PARTY-NOTICES.txt"), Path.Combine(staging, "THIRD-PARTY-NOTICES.txt"));
            Console.WriteLine($"NativeAOT: unchanged; reused {NativeAot.LibraryName(target)} from the build cache");
            return;
        }
        NativeAot.Build(engine, project, config, staging, target, player, symbols, warningsMode);
        ExportCache.Clear(cache);
        Directory.CreateDirectory(cache);
        if (Directory.Exists(Path.Combine(staging, "Managed")))
            ExportUtil.LinkTree(Path.Combine(staging, "Managed"), Path.Combine(cache, "managed"));
        if (File.Exists(Path.Combine(staging, "THIRD-PARTY-NOTICES.txt")))
            ExportUtil.LinkFile(Path.Combine(staging, "THIRD-PARTY-NOTICES.txt"), Path.Combine(cache, "THIRD-PARTY-NOTICES.txt"));
        ExportCache.Save(cache, signature);
    }

    /// <summary>Compresses the staged pictures (only those whose source changed: the rest come from the cache).</summary>
    static string CompressTextures(string project, string engine, string staging, Dictionary<string, string> settings, Options options, Target target)
    {
        string cache = Path.Combine(ExportCache.Root(project, target, options.Config), "textures");
        var (made, reused, skipped, errors) = Textures.CompressFolder(Path.Combine(staging, "Assets"), engine,
            settings.Get("textureCompressExclude", Textures.DefaultExclude), cache);
        string message = $"Textures: {made} compressed, {reused} unchanged, {skipped} left as they are" +
            string.Concat(errors.Select(error => "\n  note: " + error));
        long bytes = ExportCache.Size(cache);
        if (bytes > ExportCache.LimitBytes)
        {
            Directory.Delete(cache, true);
            message += $"\n  (the compressed copies are {ExportCache.Gigabytes(bytes)}; not kept, over the build cache's " +
                ExportCache.Gigabytes(ExportCache.LimitBytes) + " limit — set TALLOW_BUILD_CACHE_MB to keep more)";
        }
        return message;
    }

    /// <summary>Cooks the streamed files (or links those a build with the same assets already cooked).</summary>
    static string? CookStreamed(string project, string engine, string staging, Options options, Target target)
    {
        Target host = ExportUtil.HostWindows ? Target.Windows : ExportUtil.HostMac ? Target.MacOS : Target.Linux;
        string cookPlayer = Player(engine, options.Config, host);
        string cache = Path.Combine(ExportCache.Root(project, target, options.Config), "cook");
        // The cooked files' own neighbours (.ktx, .tmips, .tvt) are not what the cook reads: it makes them.
        string signature = ExportCache.Hash("cook-v" + ExportCache.Version,
            ExportCache.TreeStamp(Path.Combine(staging, "Assets"), ".ktx", ".tmips", ".tvt"), ExportCache.FileStamp(cookPlayer));
        if (ExportCache.Matches(cache, signature))
        {
            ExportUtil.LinkTree(Path.Combine(cache, "files"), staging);
            return "Streaming: unchanged, reused the cooked files";
        }
        bool cooked = false;
        string? message = null;
        try
        {
            message = StreamingCook.Run(cookPlayer, staging);
            cooked = message == null || message.StartsWith("Streaming:", StringComparison.Ordinal);
        }
        catch (ExportException exception)
        {
            message = "Note: the streamed files were not cooked (" + exception.Message.Split('\n')[0] + "); the game loads them whole.";
        }
        if (cooked)
        {
            long bytes = ExportCache.Size(Path.Combine(staging, ".cache"));
            string assets = Path.Combine(staging, "Assets");
            if (Directory.Exists(assets))
                foreach (var (_, full) in ExportUtil.Files(assets))
                    if (full.EndsWith(".tmips", StringComparison.OrdinalIgnoreCase) || full.EndsWith(".tvt", StringComparison.OrdinalIgnoreCase))
                        bytes += new FileInfo(full).Length;
            if (bytes > ExportCache.LimitBytes)
            {
                ExportCache.Clear(cache);
                message += $"\n  (the cooked files are {ExportCache.Gigabytes(bytes)}; not kept, over the build cache's " +
                    ExportCache.Gigabytes(ExportCache.LimitBytes) + " limit — set TALLOW_BUILD_CACHE_MB to keep more)";
            }
            else
            {
                ExportCache.Clear(cache);
                string files = Path.Combine(cache, "files");
                Directory.CreateDirectory(files);
                if (Directory.Exists(Path.Combine(staging, ".cache")))
                    ExportUtil.LinkTree(Path.Combine(staging, ".cache"), Path.Combine(files, ".cache"));
                if (Directory.Exists(assets))
                    foreach (var (relative, full) in ExportUtil.Files(assets))
                        if (full.EndsWith(".tmips", StringComparison.OrdinalIgnoreCase) || full.EndsWith(".tvt", StringComparison.OrdinalIgnoreCase))
                            ExportUtil.LinkFile(full, Path.Combine(files, "Assets", relative));
                ExportCache.Save(cache, signature);
            }
        }
        return message;
    }

    static void Pack(string project, string staging, string name, string scene, Dictionary<string, string> settings, Options options, bool web)
    {
        bool compress = !options.NoCompress && (web || settings.Get("packCompress", "1") != "0");
        // What goes into the packs, by path, size and timestamp; game.tallow by content (written each build). The
        // project's scripts are in it too: which assets a map uses (and so which pack it goes in) is read from them.
        string codeStamp = ExportCache.Hash(ExportUtil.Files(Path.Combine(project, "src"))
            .Where(file => Path.GetExtension(file.Full) is ".bf" or ".tgraph" or ".cs")
            .Select(file => ExportCache.FileStamp(file.Full)).ToArray());
        string signature = ExportCache.Hash("pack-v" + ExportCache.Version, name, scene, compress ? "compressed" : "stored",
            options.SinglePack ? "single" : "split", settings.Get("packSplit", "1"), settings.Get("packShared", ""),
            settings.Get("packAssets", "1"), ExportCache.TreeStamp(Path.Combine(staging, "Assets")),
            ExportCache.TreeStamp(Path.Combine(staging, "Engine")), ExportCache.TreeStamp(Path.Combine(staging, ".cache")),
            ExportCache.ContentStamp(Path.Combine(staging, "game.tallow")), codeStamp);
        string packCache = Path.Combine(ExportCache.Root(project, options.Platform, options.Config), "pack");
        string filesList = Path.Combine(packCache, "files.txt");
        if (ExportCache.Matches(packCache, signature) && File.Exists(filesList))
        {
            var names = File.ReadAllLines(filesList).Where(line => line.Length > 0).ToList();
            foreach (string packName in names)
                ExportUtil.LinkFile(Path.Combine(packCache, "packs", packName), Path.Combine(staging, packName));
            DeletePackedFolders(staging);
            Console.WriteLine($"Packs: unchanged; reused {string.Join(", ", names)}");
            return;
        }
        var packed = new List<(string Name, string Source)>();
        foreach (string folder in new[] { "Assets", "Engine" })
            foreach (var (relative, file) in ExportUtil.Files(Path.Combine(staging, folder)))
                packed.Add((folder + "/" + relative, file));
        packed.Add(("game.tallow", Path.Combine(staging, "game.tallow")));
        // Cooked cluster hierarchies: <game>/.cache/clod/..., where the engine looks for them.
        foreach (var (relative, file) in ExportUtil.Files(Path.Combine(staging, ".cache")))
            packed.Add((".cache/" + relative, file));
        // A scene's own files (what only that scene uses) go into a pack of its own, so that changing one map rewrites
        // one small file, and a browser can start before every map has arrived. packs.txt in game.tpak lists them.
        var extra = new List<(string Pack, string Scene, long Size)>();
        string packsList = Path.Combine(staging, "packs.txt");
        if (!options.SinglePack && settings.Get("packSplit", "1") != "0")
        {
            var assets = ExportUtil.Files(Path.Combine(staging, "Assets")).ToDictionary(file => file.Relative, file => file.Full, StringComparer.Ordinal);
            var code = ExportUtil.Files(Path.Combine(project, "src"))
                .Where(file => Path.GetExtension(file.Full) is ".bf" or ".tgraph" or ".cs")
                .Select(file => ExportUtil.ReadText(file.Full)).ToList();
            var patterns = settings.Get("packShared").Split(';').Select(pattern => pattern.Trim());
            var (scenePacks, served) = AssetPack.PlanSplit(assets, code, scene, patterns);
            var inside = new HashSet<string>(StringComparer.Ordinal);
            foreach (var (packName, members) in scenePacks)
            {
                string packPath = Path.Combine(staging, packName);
                AssetPack.Write(packPath, members.Select(member => ("Assets/" + member, assets[member])), compress, name);
                inside.UnionWith(members.Select(member => "Assets/" + member));
                extra.Add((packName, served[packName], new FileInfo(packPath).Length));
            }
            packed = packed.Where(entry => !inside.Contains(entry.Name)).ToList();
            if (extra.Count > 0)
            {
                File.WriteAllText(packsList, string.Concat(extra.Select(entry => $"{entry.Pack}\t{entry.Scene}\t{entry.Size}\n")));
                packed.Add(("packs.txt", packsList));
            }
        }
        AssetPack.Write(Path.Combine(staging, "game.tpak"), packed, compress, name);
        if (extra.Count > 0)
        {
            File.Delete(packsList);
            Console.WriteLine($"Packs: game.tpak and {extra.Count} for scenes (" + string.Join(", ", extra.Select(entry => entry.Pack)) + ")");
        }
        // Keep the packs, linked (no extra space), so the next build with the same files writes them again rather than
        // reading and scrambling several gigabytes. A pack bigger than the cache limit is not kept.
        ExportCache.Clear(packCache);
        var made = Directory.EnumerateFiles(staging, "*.tpak")
            .Select(path => Path.GetFileName(path)!)
            .OrderBy(entry => entry, StringComparer.Ordinal)
            .ToList();
        long packBytes = made.Sum(name => new FileInfo(Path.Combine(staging, name)).Length);
        if (packBytes > ExportCache.LimitBytes)
            Console.WriteLine($"Packs: {ExportCache.Gigabytes(packBytes)}; not kept, over the build cache's " +
                ExportCache.Gigabytes(ExportCache.LimitBytes) + " limit — set TALLOW_BUILD_CACHE_MB to keep more");
        else
        {
            Directory.CreateDirectory(Path.Combine(packCache, "packs"));
            foreach (string packName in made)
                ExportUtil.LinkFile(Path.Combine(staging, packName), Path.Combine(packCache, "packs", packName));
            File.WriteAllText(filesList, string.Concat(made.Select(entry => entry + "\n")));
            ExportCache.Save(packCache, signature);
        }
        DeletePackedFolders(staging);
    }

    /// <summary>Removes the loose assets a packed build does not ship (they are in the .tpak).</summary>
    static void DeletePackedFolders(string staging)
    {
        foreach (string folder in new[] { "Assets", "Engine" })
            if (Directory.Exists(Path.Combine(staging, folder)))
                Directory.Delete(Path.Combine(staging, folder), true);
        File.Delete(Path.Combine(staging, "game.tallow"));
        if (Directory.Exists(Path.Combine(staging, ".cache")))
            Directory.Delete(Path.Combine(staging, ".cache"), true);
    }
}
