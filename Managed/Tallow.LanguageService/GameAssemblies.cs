using System.Text.Json;

namespace Tallow.LanguageService;

/// <summary>An assembly definition (.tasmdef) as the request or the project gives it.</summary>
internal sealed class GameAssemblyInfo
{
    public string Name { get; set; } = "";
    public string Folder { get; set; } = "";
    public List<string> References { get; set; } = [];
}

/// <summary>
/// The game's assemblies as Tallow.Build makes them: each .tasmdef folder (with its subfolders, unless a deeper
/// .tasmdef takes them) is an assembly that sees Tallow.API and the assemblies it lists; everything else in src/ is
/// Tallow.Game, which sees every assembly definition. Engine API source is Tallow.API, compiled on its own so its
/// internals stay hidden from the game as in a real build.
/// </summary>
internal sealed class AssemblyLayout
{
    public const string Game = "Tallow.Game";
    public const string Api = "Tallow.API";
    /// <summary>The editor scripts' API (engine source, like Tallow.API) and the game's editor scripts: every file
    /// in a folder named Editor under src/, which sees Tallow.Editor and every game assembly.</summary>
    public const string EditorApi = "Tallow.Editor";
    public const string GameEditor = "Tallow.Game.Editor";

    /// <summary>The game's src folder when the layout was read from it (editor folders are found there).</summary>
    public string SourceDirectory { get; private set; } = "";

    /// <summary>Whether src/ has editor scripts: Tallow.Editor and Tallow.Game.Editor are then assemblies too.</summary>
    public bool HasEditor { get; private set; }

    private readonly List<GameAssemblyInfo> _definitions;

    /// <summary>Tallow.Build's per-assembly generated code (.tallow-csharp/generated/&lt;assembly&gt;), or empty.</summary>
    public string GeneratedDirectory { get; private set; } = "";

    /// <summary>Changes whenever the layout does (names, folders, references).</summary>
    public string Key { get; }

    /// <summary>Assembly definitions in build order (each after the ones it references).</summary>
    public IReadOnlyList<GameAssemblyInfo> Definitions => _definitions;

    private AssemblyLayout(List<GameAssemblyInfo> definitions, string sourceDirectory = "", bool hasEditor = false)
    {
        _definitions = definitions;
        SourceDirectory = sourceDirectory;
        HasEditor = hasEditor;
        Key = string.Join("|", definitions.Select(d => d.Name + ">" + d.Folder + ">" + string.Join(",", d.References))) +
            (hasEditor ? "|editor>" + sourceDirectory : "");
    }

    /// <summary>A file in a folder named Editor under src/ (as Tallow.Build decides).</summary>
    public static bool IsEditorScript(string sourceDirectory, string path)
    {
        if (sourceDirectory.Length == 0)
            return false;
        string relative = Path.GetRelativePath(sourceDirectory, path);
        if (relative == ".." || Path.IsPathRooted(relative) || relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            return false;
        return relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).SkipLast(1).Any(folder => folder == "Editor");
    }

    public static readonly AssemblyLayout Single = new([]);

    /// <summary>The layout from definitions, or one game assembly when they do not make a valid graph (an unknown
    /// or circular reference): the real build reports those, the editor then still checks the code.</summary>
    public static AssemblyLayout From(IEnumerable<GameAssemblyInfo> definitions)
    {
        var byName = new Dictionary<string, GameAssemblyInfo>(StringComparer.Ordinal);
        foreach (GameAssemblyInfo definition in definitions)
        {
            if (definition.Name.Length == 0 || definition.Name is Game or Api || !byName.TryAdd(definition.Name,
                    new GameAssemblyInfo { Name = definition.Name, Folder = Path.GetFullPath(definition.Folder),
                        References = definition.References.Distinct().ToList() }))
                return Single;
        }
        var ordered = new List<GameAssemblyInfo>();
        var visiting = new HashSet<string>();
        var done = new HashSet<string>();
        bool Visit(string name)
        {
            if (done.Contains(name))
                return true;
            if (!byName.TryGetValue(name, out GameAssemblyInfo? definition) || !visiting.Add(name))
                return false;
            foreach (string reference in definition.References)
                if (!Visit(reference))
                    return false;
            visiting.Remove(name);
            done.Add(name);
            ordered.Add(definition);
            return true;
        }
        foreach (string name in byName.Keys.Order(StringComparer.Ordinal))
            if (!Visit(name))
                return Single;
        return new AssemblyLayout(ordered);
    }

    /// <summary>The .tasmdef files under a game's src folder (unreadable ones are left out), and where the build
    /// puts each assembly's generated code.</summary>
    public static AssemblyLayout Read(string sourceDirectory, string generatedDirectory)
    {
        AssemblyLayout layout = Read(sourceDirectory);
        string source = Path.GetFullPath(sourceDirectory);
        bool hasEditor = Directory.Exists(source) && Directory.EnumerateFiles(source, "*.cs", SearchOption.AllDirectories)
            .Any(file => IsEditorScript(source, file));
        layout = new AssemblyLayout(layout == Single ? [] : layout._definitions, source, hasEditor);
        layout.GeneratedDirectory = Path.GetFullPath(generatedDirectory);
        return layout;
    }

    private static AssemblyLayout Read(string sourceDirectory)
    {
        if (!Directory.Exists(sourceDirectory))
            return Single;
        var definitions = new List<GameAssemblyInfo>();
        foreach (string path in Directory.EnumerateFiles(sourceDirectory, "*.tasmdef", SearchOption.AllDirectories).Order())
        {
            try
            {
                using JsonDocument json = JsonDocument.Parse(File.ReadAllText(path));
                JsonElement root = json.RootElement;
                if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("name", out JsonElement name) ||
                    name.ValueKind != JsonValueKind.String)
                    continue;
                var info = new GameAssemblyInfo { Name = name.GetString()!, Folder = Path.GetDirectoryName(Path.GetFullPath(path))! };
                if (root.TryGetProperty("references", out JsonElement references) && references.ValueKind == JsonValueKind.Array)
                    info.References.AddRange(references.EnumerateArray()
                        .Where(reference => reference.ValueKind == JsonValueKind.String).Select(reference => reference.GetString()!));
                definitions.Add(info);
            }
            catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
            {
                // Being typed in the editor, or broken: the build says what is wrong with it.
            }
        }
        return From(definitions);
    }

    internal static bool IsApi(string path) =>
        path.Replace('\\', '/').Contains("/Managed/Tallow.API/", StringComparison.OrdinalIgnoreCase);

    internal static bool IsEditorApi(string path) =>
        path.Replace('\\', '/').Contains("/Managed/Tallow.Editor/", StringComparison.OrdinalIgnoreCase);

    /// <summary>Engine source (Tallow.API, Tallow.Editor): read-only, and allowed unsafe code.</summary>
    internal static bool IsEngine(string path) => IsApi(path) || IsEditorApi(path);

    /// <summary>Whether an assembly may use unsafe code (the engine's may; the game's may not).</summary>
    public static bool AllowsUnsafe(string name) => name is Api or EditorApi;

    /// <summary>The assembly a source file is compiled into: the deepest assembly definition folder holding it.</summary>
    public string Owner(string path)
    {
        if (IsApi(path))
            return Api;
        if (IsEditorApi(path))
            return EditorApi;
        if (HasEditor && IsEditorScript(SourceDirectory, path))
            return GameEditor;
        // Generated code: the assembly is the folder's name.
        if (GeneratedDirectory.Length > 0 && Path.GetDirectoryName(path) is { } folder &&
            string.Equals(Path.GetDirectoryName(folder), GeneratedDirectory, StringComparison.OrdinalIgnoreCase))
        {
            string name = Path.GetFileName(folder);
            if (name == Game || _definitions.Any(d => d.Name == name))
                return name;
        }
        string owner = Game;
        int depth = -1;
        foreach (GameAssemblyInfo definition in _definitions)
        {
            if (definition.Folder.Length <= depth)
                continue;
            string relative = Path.GetRelativePath(definition.Folder, path);
            if (relative != ".." && !Path.IsPathRooted(relative) &&
                !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            {
                owner = definition.Name;
                depth = definition.Folder.Length;
            }
        }
        return owner;
    }

    /// <summary>The game assemblies an assembly references (Tallow.API is referenced by all of them).</summary>
    public IEnumerable<string> ReferencesOf(string name) =>
        name is Api or EditorApi ? [] : name == Game ? _definitions.Select(d => d.Name) :
        name == GameEditor ? _definitions.Select(d => d.Name).Append(Game).Append(EditorApi) :
        _definitions.First(d => d.Name == name).References;

    /// <summary>Every game assembly in build order, Tallow.Game after the assembly definitions (then, with editor
    /// scripts, Tallow.Editor and Tallow.Game.Editor).</summary>
    public IEnumerable<string> GameAssemblies => HasEditor
        ? _definitions.Select(d => d.Name).Append(Game).Append(EditorApi).Append(GameEditor)
        : _definitions.Select(d => d.Name).Append(Game);
}
