namespace Tallow.ManagedBuild.Export;

/// <summary>The export's asset steps on their own:
/// <code>
///   pack --list|--verify &lt;game.tpak&gt;           what a pack holds / read every file back and check it (exit 1 if damaged)
///   convert-models &lt;project&gt; [--engine-root E]   bring the project's converted models (.cache/models) up to date
///   compress-textures &lt;folder&gt; [--exclude 'UI/*;Fonts/*'] [--engine-root E]   make the .ktx copies a build makes
/// </code></summary>
internal static class AssetCommands
{
    static string? Option(string[] args, string name)
    {
        int at = Array.IndexOf(args, name);
        return at >= 0 && at + 1 < args.Length ? args[at + 1] : null;
    }

    static string Engine(string[] args) =>
        Option(args, "--engine-root") is { } given ? Path.GetFullPath(given) : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));

    static string? Positional(string[] args) =>
        args.Where((arg, i) => !arg.StartsWith("--", StringComparison.Ordinal) && (i == 0 || args[i - 1] is not ("--engine-root" or "--exclude"))).FirstOrDefault();

    public static int Pack(string[] args)
    {
        string? path = Positional(args);
        bool verify = args.Contains("--verify");
        if (path == null || (!verify && !args.Contains("--list")))
        {
            Console.Error.WriteLine("usage: pack --list|--verify <game.tpak>");
            return 2;
        }
        try
        {
            var files = AssetPack.Read(path);
            if (!verify)
                foreach (var (name, data) in files)
                    Console.WriteLine($"{data.Length,10}  {name}");
            Console.WriteLine($"{files.Count} files{(verify ? ", 0 damaged" : "")}");
            return 0;
        }
        catch (Exception exception) when (exception is InvalidDataException or IOException)
        {
            Console.WriteLine($"DAMAGED: {exception.Message}");
            return 1;
        }
    }

    public static int ConvertModels(string[] args)
    {
        string? project = Positional(args);
        if (project == null)
        {
            Console.Error.WriteLine("usage: convert-models <project> [--engine-root E]");
            return 2;
        }
        var (done, errors) = Models.ConvertProject(Path.GetFullPath(project), Engine(args));
        foreach (var (relative, _) in done)
            Console.WriteLine($"converted {relative}");
        foreach (string error in errors)
            Console.WriteLine($"error: {error}");
        return errors.Count > 0 ? 1 : 0;
    }

    public static int CompressTextures(string[] args)
    {
        string? folder = Positional(args);
        if (folder == null)
        {
            Console.Error.WriteLine("usage: compress-textures <folder> [--exclude 'UI/*;Fonts/*'] [--engine-root E]");
            return 2;
        }
        var (made, reused, skipped, errors) = Textures.CompressFolder(Path.GetFullPath(folder), Engine(args), Option(args, "--exclude") ?? Textures.DefaultExclude);
        Console.WriteLine($"Compressed {made} pictures, reused {reused}, left {skipped} alone" + (errors.Count > 0 ? $"; {errors.Count} failed" : ""));
        foreach (string error in errors)
            Console.WriteLine("  " + error);
        return errors.Count > 0 && made == 0 ? 1 : 0;
    }
}
