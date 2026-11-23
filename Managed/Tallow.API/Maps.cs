namespace Tallow;

/// <summary>A player-made map file (.tmap) and what checking it found (tallowengine.com/docs/maps).</summary>
/// <param name="File">The .tmap file on disk.</param>
/// <param name="Id">Stays the same when the file is renamed or copied: players with the same map have the same Id.</param>
/// <param name="Name">The map's name.</param>
/// <param name="Author">Who made it.</param>
/// <param name="Description">What it is.</param>
/// <param name="Game">The game it was made for.</param>
/// <param name="Version">The map format version.</param>
/// <param name="Hash">The whole file's hash: players with the same Id and Hash have the same map.</param>
/// <param name="Bytes">The file's size.</param>
/// <param name="Problems">Why the map cannot be played, one reason each; empty when it can.</param>
public sealed record MapFileInfo(string File, string Id, string Name, string Author, string Description, string Game,
    int Version, string Hash, long Bytes, string[] Problems)
{
    /// <summary>Whether the map can be played.</summary>
    public bool Ok => Problems.Length == 0;

    /// <summary>Whether its files are mounted (<see cref="MapFiles.Mount"/>).</summary>
    public bool Mounted => CSharpMaps.IsMounted(File);

    /// <summary>How many components of a type (its full name, "Tallow.SpawnPoint") the map's scene has, for a
    /// game's own checks.</summary>
    public int CountComponents(string typeName) => CSharpMaps.CountComponents(File, typeName ?? "");

    /// <summary>The same map with one more problem (a game's own rule it breaks), so it is no longer Ok.</summary>
    public MapFileInfo WithProblem(string reason) => this with { Problems = [.. Problems, reason] };

    /// <summary>The asset path to load its scene from once it is mounted.</summary>
    public string ScenePath => $".maps/{Id}/map.tscene";

    internal static MapFileInfo Parse(string text)
    {
        string[] f = text.Split('\x1e');
        if (f.Length < 10)
            throw new FormatException("A map description from the engine is incomplete.");
        string[] problems = f[9].Length == 0 ? [] : f[9].Split('\x1f');
        return new MapFileInfo(f[0], f[1], f[2], f[3], f[4], f[5], int.TryParse(f[6], out int version) ? version : 0, f[7],
            long.TryParse(f[8], out long bytes) ? bytes : 0, problems);
    }
}

/// <summary>
/// Player-made maps: scenes written to .tmap files that a game finds, checks, mounts and loads like any other scene.
/// </summary>
public static class MapFiles
{
    /// <summary>The file extension of a map.</summary>
    public const string Extension = ".tmap";

    /// <summary>Where the game keeps its maps (the game's folder in the player's data, plus "Maps").</summary>
    public static string Folder => ActionText.Read(CSharpMaps.Folder) ?? "";

    /// <summary>Every map file in a folder (not its sub-folders), sorted by name, broken ones included with their
    /// Problems. A missing folder finds nothing.</summary>
    public static MapFileInfo[] Find(string folder)
    {
        string text = ActionText.Read(buffer => CSharpMaps.Find(folder ?? "", buffer)) ?? "";
        return text.Length == 0 ? [] : Array.ConvertAll(text.Split('\x1d'), MapFileInfo.Parse);
    }

    /// <summary>Reads and checks one map file.</summary>
    public static MapFileInfo Check(string file) =>
        MapFileInfo.Parse(ActionText.Read(buffer => CSharpMaps.Check(file ?? "", buffer)) ?? "");

    /// <summary>Makes a map's files readable so that its <see cref="MapFileInfo.ScenePath"/> loads. False for a map
    /// with problems (unless allowProblems: a map editor opening an unfinished map), or one whose file has gone.</summary>
    public static bool Mount(MapFileInfo map, bool allowProblems = false) => CSharpMaps.Mount(map.File, allowProblems);

    /// <summary>Frees the memory a mounted map's files take. Unload its scene first.</summary>
    public static void Unmount(MapFileInfo map) => CSharpMaps.Unmount(map.File);

    /// <summary>Writes the scene as a map file with a new Id; or, given group (the object a loaded level's scene
    /// is under), only the objects under it; keepId saves a new version of that map. The problems found (files the
    /// scene names that the project lacks); the map is written unless the result's Written is false.</summary>
    public static (bool Written, string[] Problems) Export(Scene scene, string file, string name, string author,
        string description, GameObject? group = null, string keepId = "")
    {
        bool written = CSharpMaps.Export(scene.SessionId, group?.Id ?? 0, file ?? "", keepId ?? "", name ?? "", author ?? "",
            description ?? "");
        string problems = ActionText.Read(CSharpMaps.ExportProblems) ?? "";
        return (written, problems.Length == 0 ? [] : problems.Split('\x1f'));
    }
}

/// <summary>Where a map download from the host stands.</summary>
public enum MapDownloadState
{
    /// <summary>Nothing asked for.</summary>
    None,
    /// <summary>Asked the host, nothing back yet.</summary>
    Asking,
    /// <summary>Coming in (<see cref="MapSharing.Progress"/>).</summary>
    Downloading,
    /// <summary>The map is in the Maps folder (<see cref="MapSharing.DownloadedFile"/>).</summary>
    Done,
    /// <summary>It could not be had (<see cref="MapSharing.Error"/> says why).</summary>
    Failed,
}

/// <summary>Sends map files from the host to players who lack them, or whose copy is another version.</summary>
public static class MapSharing
{
    /// <summary>Host: makes a map available to players who ask for it by Id. It is read from its file when asked for.</summary>
    public static bool Offer(MapFileInfo map) => CSharpMaps.Offer(map.File);

    /// <summary>Host: forgets every offered map.</summary>
    public static void ClearOffers() => CSharpMaps.ClearOffers();

    /// <summary>Whether the Maps folder (or another) has a map with this Id and Hash (an empty hash matches any version).</summary>
    public static bool Have(string id, string hash, string folder = "") => CSharpMaps.Have(id ?? "", hash ?? "", folder ?? "");

    /// <summary>Player: asks the host for its map; nothing happens while that map is already coming. False when
    /// this machine is not a client in a session.</summary>
    public static bool Request(Scene scene, string id, string hash) => CSharpMaps.Request(scene.SessionId, id ?? "", hash ?? "");

    /// <summary>Forgets the download, for leaving a game.</summary>
    public static void Reset() => CSharpMaps.Reset();

    /// <summary>Where the download stands.</summary>
    public static MapDownloadState State => (MapDownloadState)CSharpMaps.State();
    /// <summary>How much of it has come, 0 to 1.</summary>
    public static float Progress => CSharpMaps.Progress();
    /// <summary>The whole map's size in bytes, once the host has said.</summary>
    public static int TotalBytes => CSharpMaps.TotalBytes();
    /// <summary>The Id asked for.</summary>
    public static string WantedId => ActionText.Read(buffer => CSharpMaps.SharingText(0, buffer)) ?? "";
    /// <summary>The map's name, as the host gave it.</summary>
    public static string Name => ActionText.Read(buffer => CSharpMaps.SharingText(1, buffer)) ?? "";
    /// <summary>Why it failed.</summary>
    public static string Error => ActionText.Read(buffer => CSharpMaps.SharingText(2, buffer)) ?? "";
    /// <summary>The file it was saved as, once Done.</summary>
    public static string DownloadedFile => ActionText.Read(buffer => CSharpMaps.SharingText(3, buffer)) ?? "";

    /// <summary>Where downloads go (MapFiles.Folder unless changed).</summary>
    public static string Folder
    {
        get => ActionText.Read(buffer => CSharpMaps.SharingText(4, buffer)) ?? "";
        set => CSharpMaps.SetSharingFolder(value ?? "");
    }
}
