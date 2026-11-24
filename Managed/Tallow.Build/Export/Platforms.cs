using System.IO.Compression;
using System.Net.Http;
using System.Text.Json;

namespace Tallow.ManagedBuild.Export;

/// <summary>
/// Platform modules: players an engine package does not carry, added and removed like modules (the editor's Platforms
/// window). Each is a zip (Tallow-Platform-&lt;Name&gt;.zip, on the engine's GitHub release) holding files to put into
/// the engine's folder and tallow-platform.txt, which names the module and the engine build it was made with: a
/// player only works with the engine build it was compiled from.
///
/// <code>
///   platform-list    [--engine-root E]                       each module: name = installed|missing|source
///   platform-install &lt;name&gt; [--engine-root E] [--from Z]    from the engine's release, or a zip (a module that is not public)
///   platform-remove  &lt;name&gt; [--engine-root E]
/// </code>
/// </summary>
internal static class Platforms
{
    /// <summary>MacOnly: the module builds games only on a Mac (iOS: Apple's tools run nowhere else).</summary>
    sealed record Module(string Name, string Title, string[] Files, string Folder, bool MacOnly = false);

    /// <summary>The modules Tallow knows. Files: what has to be there for it to count as installed (engine-relative).</summary>
    static readonly Module[] Known =
    {
        new("android", "Android", Android.Abis.Select(abi => $"Player/build/Release_Android/{abi}/libmain.so").Append("Player/build/Release_Android/classes.dex").ToArray(),
            "Player/build/Release_Android"),
        new("ios", "iOS", new[] { "Player/build/Release_iOS/iphoneos/TallowPlayer", "Player/build/Release_iOS/iphonesimulator/TallowPlayer" },
            "Player/build/Release_iOS", true),
    };

    const string Repository = "LazyAlgorithm/Tallow";

    static string EngineRoot(string[] args)
    {
        int at = Array.IndexOf(args, "--engine-root");
        if (at >= 0 && at + 1 < args.Length)
            return Path.GetFullPath(args[at + 1]);
        for (var folder = new DirectoryInfo(AppContext.BaseDirectory); folder != null; folder = folder.Parent)
            if (Directory.Exists(Path.Combine(folder.FullName, "Engine", "src")) && Directory.Exists(Path.Combine(folder.FullName, "Managed", "Tallow.Build")))
                return folder.FullName;
        throw new ExportException("Cannot find the engine; pass --engine-root.", true);
    }

    static Module Find(string name) => Known.FirstOrDefault(module => module.Name == name.ToLowerInvariant())
        ?? throw new ExportException($"No platform module named {name} (there are: {string.Join(", ", Known.Select(module => module.Name))}).", true);

    public static bool Installed(string engine, string name) =>
        Find(name).Files.All(file => File.Exists(Path.Combine(engine, file)));

    /// <summary>The engine's version and build, from tallow-version.json (engine packages have one; a source
    /// checkout does not, and builds its modules itself).</summary>
    static (string Version, string Build)? EngineVersion(string engine)
    {
        string file = Path.Combine(engine, "tallow-version.json");
        if (!File.Exists(file))
            return null;
        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(file));
        string? version = document.RootElement.TryGetProperty("version", out var v) ? v.GetString() : null;
        string? build = document.RootElement.TryGetProperty("build", out var b) ? b.GetString() : null;
        return version != null && build != null ? (version, build) : null;
    }

    public static int List(string[] args) => Run(() =>
    {
        string engine = EngineRoot(args);
        bool source = Directory.Exists(Path.Combine(engine, "Player", "src")) && EngineVersion(engine) == null;
        foreach (Module module in Known)
        {
            if (module.MacOnly && !ExportUtil.HostMac)
                Console.WriteLine($"{module.Name} = mac-only");
            else
                Console.WriteLine($"{module.Name} = {(Installed(engine, module.Name) ? "installed" : source ? "source" : "missing")}");
        }
    });

    public static int Install(string[] args) => Run(() =>
    {
        if (args.Length == 0 || args[0].StartsWith("--", StringComparison.Ordinal))
            throw new ExportException("usage: platform-install <name> [--engine-root E] [--from <zip>]", true);
        Module module = Find(args[0]);
        if (module.MacOnly && !ExportUtil.HostMac)
            throw new ExportException($"{module.Title} games are built on a Mac with Xcode: add the {module.Title} platform to Tallow on a Mac.");
        string engine = EngineRoot(args);
        int fromAt = Array.IndexOf(args, "--from");
        string? zip = fromAt >= 0 && fromAt + 1 < args.Length ? Path.GetFullPath(args[fromAt + 1]) : null;
        var version = EngineVersion(engine);
        string cache = Path.Combine(ExportUtil.CacheFolder(), "platforms");
        Directory.CreateDirectory(cache);
        if (zip == null)
        {
            if (version == null)
                throw new ExportException($"This engine was built from source: make the {module.Title} player with its build script " +
                    (module.Name == "android" ? "(tools/android/build_player.sh)" : module.Name == "ios" ? "(tools/ios/build_player.sh)" : "") +
                    ", or install a module zip with --from.");
            string asset = $"Tallow-Platform-{module.Title}.zip";
            string url = $"https://github.com/{Repository}/releases/download/{version.Value.Version}/{asset}";
            zip = Path.Combine(cache, $"{version.Value.Version}-{asset}");
            if (!File.Exists(zip))
            {
                Console.WriteLine($"Downloading the {module.Title} platform for Tallow {version.Value.Version}...");
                using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
                using var response = http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
                if (!response.IsSuccessStatusCode)
                    throw new ExportException($"The {module.Title} platform for Tallow {version.Value.Version} could not be downloaded ({(int)response.StatusCode}, {url}).");
                string partial = zip + ".part";
                using (var input = response.Content.ReadAsStream())
                using (var output = File.Create(partial))
                    input.CopyTo(output);
                File.Move(partial, zip, true);
            }
        }
        using (ZipArchive archive = ZipFile.OpenRead(zip))
        {
            ZipArchiveEntry info = archive.GetEntry("tallow-platform.txt")
                ?? throw new ExportException($"{zip} is not a Tallow platform module (it has no tallow-platform.txt).");
            var settings = new Dictionary<string, string>();
            using (var reader = new StreamReader(info.Open()))
                foreach (string line in reader.ReadToEnd().Split('\n'))
                    if (line.IndexOf('=') is var eq and > 0)
                        settings[line[..eq].Trim()] = line[(eq + 1)..].Trim();
            if (settings.Get("platform") != module.Name)
                throw new ExportException($"{zip} is the {settings.Get("platform")} module, not {module.Name}.");
            // A player is compiled against one engine build's native interface: refuse one from another build.
            if (version != null && settings.Get("build").Length > 0 && settings.Get("build") != version.Value.Build)
                throw new ExportException($"{zip} was made for Tallow build {settings.Get("build")[..Math.Min(8, settings.Get("build").Length)]}, " +
                    $"and this engine is {version.Value.Build[..8]} ({version.Value.Version}). Get the module made with this engine version.");
            string root = Path.GetFullPath(engine) + Path.DirectorySeparatorChar;
            string target = Path.Combine(engine, module.Folder);
            if (Directory.Exists(target))
                Directory.Delete(target, true);
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                if (entry.FullName == "tallow-platform.txt" || entry.FullName.EndsWith('/'))
                    continue;
                string path = Path.GetFullPath(Path.Combine(engine, entry.FullName));
                if (!path.StartsWith(root, StringComparison.Ordinal))
                    throw new ExportException($"{zip} has a file outside the engine's folder: {entry.FullName}");
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                entry.ExtractToFile(path, true);
                if (ExportUtil.LooksExecutable(path))
                    ExportUtil.MakeExecutable(path);
            }
        }
        if (!Installed(engine, module.Name))
            throw new ExportException($"The {module.Title} module was unpacked, but files are missing: " +
                string.Join(", ", module.Files.Where(file => !File.Exists(Path.Combine(engine, file)))));
        Console.WriteLine($"{module.Title} platform installed in {Path.Combine(engine, module.Folder)}.");
    });

    public static int Remove(string[] args) => Run(() =>
    {
        if (args.Length == 0 || args[0].StartsWith("--", StringComparison.Ordinal))
            throw new ExportException("usage: platform-remove <name> [--engine-root E]", true);
        Module module = Find(args[0]);
        string engine = EngineRoot(args);
        string target = Path.Combine(engine, module.Folder);
        if (Directory.Exists(target))
            Directory.Delete(target, true);
        Console.WriteLine($"{module.Title} platform removed.");
    });

    /// <summary>Makes a module's zip from an engine that has its files (the release workflow; anyone with a module
    /// that cannot be public).</summary>
    public static int Pack(string[] args) => Run(() =>
    {
        if (args.Length < 3 || args[1] != "--output")
            throw new ExportException("usage: platform-pack <name> --output <zip> [--engine-root E] [--build <commit>]", true);
        Module module = Find(args[0]);
        string engine = EngineRoot(args);
        if (!Installed(engine, module.Name))
            throw new ExportException($"This engine has no {module.Title} player to pack.");
        int buildAt = Array.IndexOf(args, "--build");
        string build = buildAt >= 0 && buildAt + 1 < args.Length ? args[buildAt + 1] : EngineVersion(engine)?.Build ?? "";
        string output = Path.GetFullPath(args[2]);
        if (File.Exists(output))
            File.Delete(output);
        using ZipArchive archive = ZipFile.Open(output, ZipArchiveMode.Create);
        using (var writer = new StreamWriter(archive.CreateEntry("tallow-platform.txt").Open()))
            writer.Write($"platform = {module.Name}\nbuild = {build}\n");
        foreach (var (relative, full) in ExportUtil.Files(Path.Combine(engine, module.Folder)))
            archive.CreateEntryFromFile(full, $"{module.Folder}/{relative}", CompressionLevel.Optimal);
        Console.WriteLine($"{output} ({new FileInfo(output).Length / (1024 * 1024)} MB)");
    });

    static int Run(Action action)
    {
        try
        {
            action();
            return 0;
        }
        catch (ExportException exception)
        {
            Console.Error.WriteLine(exception.Message);
            return exception.Usage ? 2 : 1;
        }
        catch (Exception exception) when (exception is IOException or HttpRequestException or InvalidDataException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }
}
