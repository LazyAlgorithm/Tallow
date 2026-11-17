using System.Globalization;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tallow.Editor;

/// <summary>Adds a tab to Edit > Preferences. On a class deriving from <see cref="PreferencesPage"/>, its OnGUI draws
/// the tab. On any other class (a settings class with public fields and a constructor without parameters), the tab
/// shows its public fields and saves every change in <see cref="EditorPrefs"/>, so nothing else is needed:</summary>
/// <example><code>
/// [PreferencesPage("Level Tools")]
/// public class LevelToolSettings
/// {
///     public float gridSize = 1;
///     public bool snapToGrid = true;
/// }
/// // Anywhere in the editor scripts:
/// float grid = EditorPrefs.Get&lt;LevelToolSettings&gt;().gridSize;
/// </code></example>
[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class PreferencesPageAttribute(string title) : Attribute
{
    /// <summary>The tab's name in the Preferences window.</summary>
    public string Title { get; } = title;
}

/// <summary>A Preferences tab that draws itself (see <see cref="PreferencesPageAttribute"/>).</summary>
public abstract class PreferencesPage
{
    /// <summary>Draws the tab, with <see cref="EditorGUI"/>.</summary>
    public abstract void OnGUI();
}

/// <summary>Settings kept as JSON in one file: values by key, and settings objects by their class. A change is
/// written at once. <see cref="EditorPrefs"/> is this user's (every project, this machine);
/// <see cref="ProjectPrefs"/> is the project's (in its folder, shared with whoever has the project).</summary>
public sealed class SettingsStore
{
    private readonly Func<string> mPath;
    private JsonObject? mValues;
    private string mLoadedFrom = "";
    private readonly Dictionary<Type, object> mObjects = [];
    private static readonly JsonSerializerOptions Options = new()
    {
        IncludeFields = true,
        WriteIndented = true,
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowNamedFloatingPointLiterals
    };

    internal SettingsStore(Func<string> path) => mPath = path;

    /// <summary>The file the settings are in.</summary>
    public string FilePath => mPath();

    private JsonObject Values
    {
        get
        {
            string path = mPath();
            if (mValues != null && path == mLoadedFrom)
                return mValues;
            mObjects.Clear();
            mLoadedFrom = path;
            mValues = null;
            try
            {
                if (File.Exists(path))
                    mValues = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
            }
            catch (Exception exception) when (exception is JsonException or IOException or UnauthorizedAccessException)
            {
                EditorHost.Log(1, $"Could not read the settings in {path} ({exception.Message}); they start again from the defaults.");
            }
            return mValues ??= [];
        }
    }

    private void Write()
    {
        string path = mPath();
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string temporary = path + ".tmp";
            File.WriteAllText(temporary, Values.ToJsonString(Options));
            File.Move(temporary, path, true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            EditorHost.Log(2, $"Could not save the settings in {path}: {exception.Message}");
        }
    }

    /// <summary>Whether a value is set for key.</summary>
    public bool Has(string key) => Values.ContainsKey(key);

    /// <summary>Removes a value.</summary>
    public void Delete(string key)
    {
        if (Values.Remove(key))
            Write();
    }

    private T Read<T>(string key, T fallback)
    {
        try
        {
            return Values.TryGetPropertyValue(key, out JsonNode? node) && node != null ? node.GetValue<T>() : fallback;
        }
        catch (Exception exception) when (exception is InvalidOperationException or FormatException)
        {
            return fallback;
        }
    }

    private void Store(string key, JsonNode value)
    {
        if (Values.TryGetPropertyValue(key, out JsonNode? old) && JsonNode.DeepEquals(old, value))
            return;
        Values[key] = value;
        Write();
    }

    /// <summary>A text value (fallback when it is not set).</summary>
    public string GetString(string key, string fallback = "") => Read(key, fallback);
    /// <summary>A number.</summary>
    public float GetFloat(string key, float fallback = 0) => Read(key, fallback);
    /// <summary>A whole number.</summary>
    public int GetInt(string key, int fallback = 0) => Read(key, fallback);
    /// <summary>A yes or no.</summary>
    public bool GetBool(string key, bool fallback = false) => Read(key, fallback);

    /// <summary>Sets a text value and saves.</summary>
    public void SetString(string key, string value) => Store(key, JsonValue.Create(value));
    /// <summary>Sets a number and saves.</summary>
    public void SetFloat(string key, float value) => Store(key, JsonValue.Create(value));
    /// <summary>Sets a whole number and saves.</summary>
    public void SetInt(string key, int value) => Store(key, JsonValue.Create(value));
    /// <summary>Sets a yes or no and saves.</summary>
    public void SetBool(string key, bool value) => Store(key, JsonValue.Create(value));

    private static string KeyOf(Type type) => "type:" + type.FullName;

    /// <summary>The settings object of class T: its public fields (and properties) as last saved, or as the class
    /// starts them. The same object every time, so change its fields and call <see cref="Save{T}"/>.</summary>
    public T Get<T>() where T : class, new() => (T)Get(typeof(T));

    internal object Get(Type type)
    {
        JsonObject values = Values;
        if (mObjects.TryGetValue(type, out object? cached))
            return cached;
        object? loaded = null;
        if (values.TryGetPropertyValue(KeyOf(type), out JsonNode? node) && node != null)
        {
            try
            {
                loaded = node.Deserialize(type, Options);
            }
            catch (Exception exception) when (exception is JsonException or NotSupportedException or InvalidOperationException)
            {
                EditorHost.Log(1, $"The saved {type.Name} settings could not be read ({exception.Message}); they start from the defaults.");
            }
        }
        loaded ??= Activator.CreateInstance(type)!;
        mObjects[type] = loaded;
        return loaded;
    }

    /// <summary>Saves a settings object of class T (the one <see cref="Get{T}"/> gives, or a new one that replaces
    /// it).</summary>
    public void Save<T>(T settings) where T : class => Save(typeof(T), settings);

    internal void Save(Type type, object settings)
    {
        JsonObject values = Values;
        mObjects[type] = settings;
        JsonNode node = JsonSerializer.SerializeToNode(settings, type, Options)!;
        if (values.TryGetPropertyValue(KeyOf(type), out JsonNode? old) && JsonNode.DeepEquals(old, node))
            return;
        values[KeyOf(type)] = node;
        Write();
    }

    /// <summary>Settings objects are of the editor scripts' classes: a recompile makes new classes, so the objects
    /// are read again from the file.</summary>
    internal void Forget() => mObjects.Clear();
}

/// <summary>This user's editor settings, the same in every project on this machine.</summary>
public static class EditorPrefs
{
    /// <summary>The store (to pass around, or for its file's path).</summary>
    public static SettingsStore Store { get; } = new(() => Path.Combine(EditorHost.QueryText(EditorHost.QueryConfigFolder), "editor-prefs.json"));

    /// <inheritdoc cref="SettingsStore.Get{T}"/>
    public static T Get<T>() where T : class, new() => Store.Get<T>();
    /// <inheritdoc cref="SettingsStore.Save{T}"/>
    public static void Save<T>(T settings) where T : class => Store.Save(settings);
    /// <inheritdoc cref="SettingsStore.Has"/>
    public static bool Has(string key) => Store.Has(key);
    /// <inheritdoc cref="SettingsStore.Delete"/>
    public static void Delete(string key) => Store.Delete(key);
    /// <inheritdoc cref="SettingsStore.GetString"/>
    public static string GetString(string key, string fallback = "") => Store.GetString(key, fallback);
    /// <inheritdoc cref="SettingsStore.GetFloat"/>
    public static float GetFloat(string key, float fallback = 0) => Store.GetFloat(key, fallback);
    /// <inheritdoc cref="SettingsStore.GetInt"/>
    public static int GetInt(string key, int fallback = 0) => Store.GetInt(key, fallback);
    /// <inheritdoc cref="SettingsStore.GetBool"/>
    public static bool GetBool(string key, bool fallback = false) => Store.GetBool(key, fallback);
    /// <inheritdoc cref="SettingsStore.SetString"/>
    public static void SetString(string key, string value) => Store.SetString(key, value);
    /// <inheritdoc cref="SettingsStore.SetFloat"/>
    public static void SetFloat(string key, float value) => Store.SetFloat(key, value);
    /// <inheritdoc cref="SettingsStore.SetInt"/>
    public static void SetInt(string key, int value) => Store.SetInt(key, value);
    /// <inheritdoc cref="SettingsStore.SetBool"/>
    public static void SetBool(string key, bool value) => Store.SetBool(key, value);
}

/// <summary>The project's editor settings: ProjectSettings/EditorPrefs.json in the project, so everybody working on
/// it has the same ones (put it in version control).</summary>
public static class ProjectPrefs
{
    /// <summary>The store (to pass around, or for its file's path).</summary>
    public static SettingsStore Store { get; } = new(() => Path.Combine(EditorApplication.ProjectPath, "ProjectSettings", "EditorPrefs.json"));

    /// <inheritdoc cref="SettingsStore.Get{T}"/>
    public static T Get<T>() where T : class, new() => Store.Get<T>();
    /// <inheritdoc cref="SettingsStore.Save{T}"/>
    public static void Save<T>(T settings) where T : class => Store.Save(settings);
    /// <inheritdoc cref="SettingsStore.Has"/>
    public static bool Has(string key) => Store.Has(key);
    /// <inheritdoc cref="SettingsStore.Delete"/>
    public static void Delete(string key) => Store.Delete(key);
    /// <inheritdoc cref="SettingsStore.GetString"/>
    public static string GetString(string key, string fallback = "") => Store.GetString(key, fallback);
    /// <inheritdoc cref="SettingsStore.GetFloat"/>
    public static float GetFloat(string key, float fallback = 0) => Store.GetFloat(key, fallback);
    /// <inheritdoc cref="SettingsStore.GetInt"/>
    public static int GetInt(string key, int fallback = 0) => Store.GetInt(key, fallback);
    /// <inheritdoc cref="SettingsStore.GetBool"/>
    public static bool GetBool(string key, bool fallback = false) => Store.GetBool(key, fallback);
    /// <inheritdoc cref="SettingsStore.SetString"/>
    public static void SetString(string key, string value) => Store.SetString(key, value);
    /// <inheritdoc cref="SettingsStore.SetFloat"/>
    public static void SetFloat(string key, float value) => Store.SetFloat(key, value);
    /// <inheritdoc cref="SettingsStore.SetInt"/>
    public static void SetInt(string key, int value) => Store.SetInt(key, value);
    /// <inheritdoc cref="SettingsStore.SetBool"/>
    public static void SetBool(string key, bool value) => Store.SetBool(key, value);
}

public static partial class EditorGUI
{
    /// <summary>A widget for each public field and settable property of an object (numbers, whole numbers, bools,
    /// text, enums, vectors and colours; others are left out), labelled with its name ("gridSize" shows
    /// "Grid Size"). True when one was edited; the object then has the new value.</summary>
    public static bool Fields(object target)
    {
        bool changed = false;
        Type type = target.GetType();
        foreach (MemberInfo member in type.GetMembers(BindingFlags.Instance | BindingFlags.Public))
        {
            (Type valueType, Func<object?> get, Action<object?> set)? access = member switch
            {
                FieldInfo { IsInitOnly: false, IsLiteral: false } field => (field.FieldType, () => field.GetValue(target), value => field.SetValue(target, value)),
                PropertyInfo { CanRead: true, CanWrite: true } property when property.GetIndexParameters().Length == 0 &&
                    property.SetMethod!.IsPublic => (property.PropertyType, () => property.GetValue(target), value => property.SetValue(target, value)),
                _ => null
            };
            if (access is not { } found)
                continue;
            (Type valueType, Func<object?> get, Action<object?> set) = found;
            string label = NiceName(member.Name) + "##" + member.Name;
            object? current = get();
            object? edited = current switch
            {
                float number => FloatField(label, number),
                double number => (double)FloatField(label, (float)number),
                int number => IntField(label, number),
                bool flag => Toggle(label, flag),
                string text => TextField(label, text),
                Vector2 vector => Vector2Field(label, vector),
                Vector3 vector => Vector3Field(label, vector),
                Vector4 vector => Vector4Field(label, vector),
                Color colour => ColorField(label, colour),
                Enum value => EnumValue(label, value),
                null when valueType == typeof(string) => TextField(label, ""),
                _ => current
            };
            if (!Equals(edited, current))
            {
                set(edited);
                changed = true;
            }
        }
        return changed;
    }

    private static object EnumValue(string label, Enum value)
    {
        Array values = Enum.GetValues(value.GetType());
        string[] names = new string[values.Length];
        int index = -1;
        for (int i = 0; i < values.Length; i++)
        {
            names[i] = values.GetValue(i)!.ToString()!;
            if (Equals(values.GetValue(i), value))
                index = i;
        }
        int picked = Popup(label, index, names);
        return picked >= 0 ? values.GetValue(picked)! : value;
    }

    /// <summary>"gridSize" as "Grid Size", "_speed" and "m_speed" as "Speed".</summary>
    public static string NiceName(string name)
    {
        if (name.StartsWith("m_", StringComparison.Ordinal))
            name = name[2..];
        name = name.TrimStart('_');
        var text = new System.Text.StringBuilder();
        for (int i = 0; i < name.Length; i++)
        {
            char c = name[i];
            if (c == '_')
            {
                text.Append(' ');
                continue;
            }
            if (i > 0 && text.Length > 0 && text[^1] != ' ' &&
                ((char.IsUpper(c) && (!char.IsUpper(name[i - 1]) || (i + 1 < name.Length && char.IsLower(name[i + 1])))) ||
                 (char.IsDigit(c) && !char.IsDigit(name[i - 1]))))
                text.Append(' ');
            text.Append(text.Length == 0 || text[^1] == ' ' ? char.ToUpper(c, CultureInfo.InvariantCulture) : c);
        }
        return text.ToString();
    }
}
