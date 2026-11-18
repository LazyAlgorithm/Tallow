using System.Runtime.Loader;

namespace Tallow;

/// <summary>
/// A file of data that every script shares: game settings, a table of weapons, the levels in order. Write a class,
/// make the file in the Project window (+ &gt; Data Asset), fill it in in the Inspector, and read it from anywhere:
/// <code>
/// public class GameSettings : DataAsset
/// {
///     public float MaxFieldOfView = 95;          // set in the Inspector, the same for every player
///     [Saved] public float Volume = 0.8f;        // each player's own: kept with their files
/// }
///
/// var settings = DataAsset.Get&lt;GameSettings&gt;();  // the project's GameSettings asset, loaded once and shared
/// settings.Volume = 0.5f;
/// settings.Save();                               // keeps the player's [Saved] fields
/// </code>
/// The asset file (.tdata) holds what was set in the editor and ships with the game. Its fields are the ones the
/// Inspector shows on a script (public, or [ShowInInspector]); object references are not kept (there is no scene).
/// Fields marked [Saved] are the player's to change: <see cref="Save"/> keeps them in the player's folder (or
/// wherever the engine's data asset storage is), the next Get puts them over the file's values, and
/// <see cref="Revert"/> goes back to the file's. A class with no asset file still works: Get makes one with the
/// values written in the code.
/// </summary>
public abstract class DataAsset
{
    private static readonly Dictionary<string, DataAsset> sLoaded = new(StringComparer.Ordinal);
    private static readonly object sLock = new();

    /// <summary>The asset file, relative to the asset folder ("Data/Settings.tdata"), or the class's name for one
    /// with no file.</summary>
    public string AssetPath { get; private set; } = "";

    /// <summary>Called after the player's copy has been put over the file's values (at Get, and after Revert).</summary>
    public virtual void OnLoaded() { }

    /// <summary>The project's asset of this class: the first .tdata file made from it (or, with none, one with the
    /// code's values). Loaded once and shared.</summary>
    public static T Get<T>() where T : DataAsset, new()
    {
        string[] files = FilesOf<T>();
        return Get<T>(files.Length > 0 ? files[0] : ClassName(typeof(T)));
    }

    /// <summary>The asset at a path (relative to the asset folder), loaded once and shared by everyone who asks.
    /// The file may be of a class derived from <typeparamref name="T"/>.</summary>
    /// <exception cref="InvalidCastException">The file is of a class that is not a <typeparamref name="T"/>.</exception>
    public static T Get<T>(string path) where T : DataAsset, new()
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        lock (sLock)
        {
            if (!sLoaded.TryGetValue(path, out DataAsset? asset))
            {
                asset = Load(path, typeof(T)) ?? new T();
                asset.AssetPath = path;
                sLoaded[path] = asset;
                asset.LoadCopy();
            }
            return asset as T ?? throw new InvalidCastException(
                $"The data asset '{path}' is a {asset.GetType().FullName}, not a {typeof(T).FullName}.");
        }
    }

    /// <summary>Every asset file of a class, sorted, for a game with several (one per level, say).</summary>
    public static string[] FilesOf<T>() where T : DataAsset => FilesOf(typeof(T));

    /// <summary>Every asset file of a class, sorted.</summary>
    public static string[] FilesOf(Type type)
    {
        ArgumentNullException.ThrowIfNull(type);
        string text = NativeText.Read(buffer => CSharpDataAssets.FilesOf(ClassName(type), buffer)) ?? "";
        return text.Length == 0 ? [] : text.Split('\n');
    }

    /// <summary>Keeps the [Saved] fields in the player's folder (or the data asset storage). False when it failed
    /// (the Console says why).</summary>
    public bool Save() => CSharpDataAssets.WriteCopy(AssetPath, FieldCodec.Read(this, true));

    /// <summary>Forgets the player's copy and goes back to the values in the asset file (or the code).</summary>
    public void Revert()
    {
        CSharpDataAssets.DeleteCopy(AssetPath);
        var fresh = DataAssetRegistry.Create(ClassName(GetType())) ?? throw new InvalidOperationException(
            $"The data asset class {GetType().FullName} is not registered by the build; rebuild the game's C#.");
        if (FileText(AssetPath) is { } file)
            FieldCodec.Apply(fresh, FieldsIn(file));
        // The file's values, and the code's for [Saved] fields that the file does not set.
        FieldCodec.Apply(this, FieldCodec.Read(fresh, true) + FieldCodec.Read(fresh, false));
        OnLoaded();
    }

    /// <summary>The project's .tdata files are looked for again, for a game that writes them while running.
    /// Loaded assets stay.</summary>
    public static void Rescan() => CSharpDataAssets.Rescan();

    private void LoadCopy()
    {
        string? copy = NativeText.Read(buffer => CSharpDataAssets.ReadCopy(AssetPath, buffer));
        if (string.IsNullOrEmpty(copy))
            return;
        FieldCodec.Apply(this, copy);
        OnLoaded();
    }

    private static DataAsset? Load(string path, Type wanted)
    {
        string? text = FileText(path);
        if (text == null)
            return null;
        DataAsset? asset;
        if (ClassIn(text) is { } name && name != ClassName(wanted))
        {
            asset = DataAssetRegistry.Create(name);
            if (asset is null || !wanted.IsAssignableFrom(asset.GetType()))
                throw new InvalidCastException($"The data asset '{path}' is a {name}, not a {wanted.FullName}.");
        }
        else
        {
            asset = DataAssetRegistry.Create(ClassName(wanted)) ?? throw new InvalidOperationException(
                $"The data asset class {wanted.FullName} is not registered by the build. Rebuild the game's C# " +
                "(Tallow.Build lists every DataAsset class), or make the class internal or public.");
        }
        FieldCodec.Apply(asset, FieldsIn(text));
        return asset;
    }

    private static string? FileText(string path)
    {
        string? text = NativeText.Read(buffer => CSharpDataAssets.ReadFile(path, buffer));
        return text;
    }

    /// <summary>The class a .tdata file says it is.</summary>
    internal static string? ClassIn(string text)
    {
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.Trim();
            if (line.StartsWith("dataasset ", StringComparison.Ordinal))
                return line[10..].Trim();
        }
        return null;
    }

    /// <summary>A .tdata file's "field Name\tvalue" lines as the "Name\tvalue" lines the codec reads.</summary>
    internal static string FieldsIn(string text)
    {
        var fields = new System.Text.StringBuilder();
        foreach (string raw in text.Split('\n'))
        {
            string line = raw.TrimEnd('\r');
            if (line.StartsWith("field ", StringComparison.Ordinal) && line.IndexOf('\t') > 6)
                fields.Append(line, 6, line.Length - 6).Append('\n');
        }
        return fields.ToString();
    }

    /// <summary>A .tdata file of an asset with these values (what the editor writes).</summary>
    public static string ToFileText(DataAsset asset)
    {
        ArgumentNullException.ThrowIfNull(asset);
        var text = new System.Text.StringBuilder("dataasset ").Append(ClassName(asset.GetType())).Append('\n');
        foreach (string line in FieldCodec.Read(asset, false).Split('\n', StringSplitOptions.RemoveEmptyEntries))
            text.Append("field ").Append(line).Append('\n');
        return text.ToString();
    }

    internal static string ClassName(Type type) => (type.FullName ?? type.Name).Replace('+', '.');

    /// <summary>Drops every loaded asset: the next Get reads the file (and the player's copy) again. Code that kept
    /// an asset keeps the old one. (Also when the game's code stops or is hot reloaded.)</summary>
    public static void ClearCache()
    {
        lock (sLock)
            sLoaded.Clear();
    }
}

/// <summary>The build-generated constructors of the game's DataAsset classes (Tallow.Build), so a .tdata file that
/// names a derived class is loaded without scanning assemblies or reflecting over constructors (NativeAOT cannot).
/// The game assemblies register their classes from a module initializer; nothing is registered until one loads.</summary>
public static class DataAssetRegistry
{
    private static readonly Dictionary<string, Func<DataAsset>> sFactories = new(StringComparer.Ordinal);

    /// <summary>One class, by the name .tdata files use ("MyGame.TuningData"). Generated code calls this.</summary>
    public static void Register(string name, Func<DataAsset> create) => sFactories[name] = create;

    /// <summary>A new instance of a registered class, or null when no assembly registered that name.</summary>
    public static DataAsset? Create(string name) =>
        sFactories.TryGetValue(name, out Func<DataAsset>? create) ? create() : null;

    /// <summary>Forgets the classes of a game whose code stopped or was reloaded (the next load registers them).</summary>
    public static void Clear() => sFactories.Clear();
}

/// <summary>The runtime's field text (the Inspector's "Name\tvalue" lines), for data assets.</summary>
internal static class FieldCodec
{
    /// <summary>Set by the runtime: the object's Inspector fields (false) or [Saved] fields (true) as text.</summary>
    internal static Func<object, bool, string>? Reader;
    /// <summary>Set by the runtime: puts "Name\tvalue" lines into the object's fields.</summary>
    internal static Action<object, string>? Applier;

    internal static string Read(object target, bool saved) =>
        (Reader ?? throw new InvalidOperationException("The C# runtime is not running.")).Invoke(target, saved);

    internal static void Apply(object target, string text) =>
        (Applier ?? throw new InvalidOperationException("The C# runtime is not running.")).Invoke(target, text);
}
