using System.Text;

namespace Tallow;

/// <summary>
/// Scene text and the project's files for a game that writes its own scenes (a map editor): save an object or a
/// group as the text a scene file uses, make objects from that text, and read models and files the player added.
/// </summary>
public static class SceneText
{
    private static string Read(Func<byte[], int> copy, bool negativeIsMissing = false)
    {
        byte[] buffer = new byte[256];
        int length = copy(buffer);
        if (negativeIsMissing && length < 0)
            return "";
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, copy(buffer));
        }
        return Encoding.UTF8.GetString(buffer, 0, Math.Max(length, 0));
    }

    /// <summary>Makes the objects written as scene text, with fresh ids; null when the text is not a scene.</summary>
    public static GameObject? Instantiate(Scene scene, string text)
    {
        ulong id = CSharpSavedScenes.Instantiate(scene.SessionId, text ?? "");
        return id == 0 ? null : new GameObject(scene.SessionId, id);
    }

    /// <summary>An object's whole hierarchy as scene text.</summary>
    public static string SaveObjectTree(GameObject gameObject) =>
        Read(buffer => CSharpSavedScenes.SaveObjectTree(gameObject.SceneId, gameObject.Id, buffer), true);

    /// <summary>The objects under a group as scene text, named: a map's contents.</summary>
    public static string SaveGroup(GameObject group, string name) =>
        Read(buffer => CSharpSavedScenes.SaveGroup(group.SceneId, group.Id, name ?? "", buffer), true);

    /// <summary>The problems MapRules.txt finds in scene text; empty when it is a map.</summary>
    public static string[] MapProblems(string sceneText)
    {
        string text = Read(buffer => CSharpSavedScenes.MapProblems(sceneText ?? "", buffer), true);
        return text.Length == 0 ? [] : text.Split('\x1f');
    }

    /// <summary>Parses a number a scene or interface file wrote.</summary>
    public static float ParseFloat(string text) => CSharpSavedScenes.ParseFloat(text ?? "");
    /// <summary>Parses a whole number a scene or interface file wrote.</summary>
    public static int ParseInt(string text) => CSharpSavedScenes.ParseInt(text ?? "");
}

/// <summary>Named settings in the engine's checksummed save format, apart from a save game (volume, controls, the
/// chosen aircraft).</summary>
public static class Settings
{
    /// <summary>Saves named settings under a slot (the engine's checksummed format). Text lines are
    /// "key", a tab, a kind ("f" float, "b" bool, "i" whole number, "s" text), a tab and the value.</summary>
    public static bool Save(string slot, string text) => CSharpSettings.Save(slot ?? "", text ?? "");

    /// <summary>Reads named settings as the same text <see cref="Save"/> takes; "" when there is no such save.</summary>
    public static string Load(string slot)
    {
        byte[] buffer = new byte[256];
        int length = CSharpSettings.Load(slot ?? "", buffer);
        if (length < 0)
            return "";
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, CSharpSettings.Load(slot ?? "", buffer));
        }
        return Encoding.UTF8.GetString(buffer, 0, Math.Max(length, 0));
    }
}

/// <summary>The project's files as a game reads them: models from the player's folder, and files kept in memory for
/// a map being made. Works the same in the editor and a built game.</summary>
public static class GameFiles
{
    private static string Read(Func<byte[], int> copy)
    {
        byte[] buffer = new byte[256];
        int length = copy(buffer);
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, copy(buffer));
        }
        return Encoding.UTF8.GetString(buffer, 0, Math.Max(length, 0));
    }

    private static byte[] ReadBytes(Func<byte[], int> copy)
    {
        byte[] buffer = new byte[4096];
        int length = copy(buffer);
        if (length <= 0)
            return [];
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, copy(buffer));
        }
        byte[] bytes = new byte[Math.Max(length, 0)];
        Array.Copy(buffer, bytes, bytes.Length);
        return bytes;
    }

    /// <summary>The project's folder (the place memory files are added under).</summary>
    public static string ProjectPath => Read(buffer => CSharpAssetFiles.ProjectPath(buffer));

    /// <summary>A project path made absolute.</summary>
    public static string Resolve(string path) =>
        Read(buffer => CSharpAssetFiles.ResolvePath(path ?? "", buffer));

    /// <summary>A file's bytes; empty when it cannot be read.</summary>
    public static byte[] Read(string path) =>
        ReadBytes(buffer => CSharpAssetFiles.ReadFile(path ?? "", buffer));

    /// <summary>Keeps a file in memory under a project path (a model brought into a map).</summary>
    public static void AddMemoryFile(string path, ReadOnlySpan<byte> data)
    {
        byte[] copy = data.ToArray();
        CSharpAssetFiles.AddMemoryFile(path ?? "", copy);
    }

    /// <summary>Forgets every memory file under a folder.</summary>
    public static int RemoveMemoryFiles(string folder) => CSharpAssetFiles.RemoveMemoryFiles(folder ?? "");

    /// <summary>Makes the asset cache read a file again.</summary>
    public static void Forget(string prefix) => CSharpAssetFiles.ForgetAsset(prefix ?? "");

    /// <summary>The files in a folder and its sub-folders.</summary>
    public static string[] FilesIn(string folder)
    {
        string text = Read(buffer => CSharpAssetFiles.FilesIn(folder ?? "", buffer));
        return text.Length == 0 ? [] : text.Split('\x1f');
    }
}
