namespace Tallow.Editor;

/// <summary>Draws the Inspector of a C# script (and of the scripts that derive from it, unless a closer one has its
/// own) instead of the field list the Inspector draws by itself. The class derives from <see cref="Inspector"/>.</summary>
/// <example><code>
/// [CustomInspector(typeof(Door))]
/// public class DoorInspector : Inspector
/// {
///     public override void OnInspectorGUI()
///     {
///         Field("openAngle");
///         if (EditorGUI.Button("Open fully"))
///             Target.SetFloat("openAngle", 120);
///     }
/// }
/// </code></example>
[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class CustomInspectorAttribute(Type script) : Attribute
{
    /// <summary>The script class this Inspector draws.</summary>
    public Type Script { get; } = script;
}

/// <summary>Adds an <see cref="EditorWindow"/> to the editor's Tools menu. The path's parts are submenus; its last
/// part is the window's title ("Level/Statistics" is Tools > Level > Statistics).</summary>
[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class EditorWindowAttribute(string menuPath) : Attribute
{
    /// <summary>Where the window is in the Tools menu.</summary>
    public string MenuPath { get; } = menuPath;
}

/// <summary>Adds a static method without parameters to the editor's Tools menu ("Level/Rename Lights" is
/// Tools > Level > Rename Lights). It runs when the item is chosen.</summary>
[AttributeUsage(AttributeTargets.Method, Inherited = false)]
public sealed class MenuItemAttribute(string path) : Attribute
{
    /// <summary>Where the command is in the Tools menu.</summary>
    public string Path { get; } = path;
}

/// <summary>A custom Inspector: <see cref="OnInspectorGUI"/> draws a script's section of the Inspector every frame
/// it is shown, with <see cref="EditorGUI"/>. Mark the class with <see cref="CustomInspectorAttribute"/>.</summary>
/// <remarks>Edits go through <see cref="Target"/> (or <see cref="Field"/>), so they are saved with the scene, can be
/// undone and reach the running script during Play, as the Inspector's own fields do. One Inspector object is made
/// per script shown, so its own fields (a selected tab, say) last while the editor runs.</remarks>
public abstract class Inspector
{
    private SerializedScript? mTarget;

    /// <summary>The script being drawn: its saved field values.</summary>
    public SerializedScript Target => mTarget ?? throw new InvalidOperationException("The Inspector has no target outside OnInspectorGUI.");

    /// <summary>Called once, before the Inspector first draws.</summary>
    public virtual void OnEnable() { }

    /// <summary>Draws the script's section. The default draws every field as the Inspector would.</summary>
    public virtual void OnInspectorGUI() => DrawDefaultInspector();

    /// <summary>Draws every field as the Inspector would without a custom Inspector. True when one was edited.</summary>
    public bool DrawDefaultInspector() => EditorHost.TargetDefault();

    /// <summary>Draws one field (by its C# name) as the Inspector would, with its label. A [Serializable] struct or
    /// class field draws its own fields under it. True when it was edited; false also when there is no such field.</summary>
    public bool Field(string name) => EditorHost.TargetField(name);

    internal void Bind(SerializedScript? target) => mTarget = target;
}

/// <summary>A window of the editor, drawn by <see cref="OnGUI"/> every frame it is open, with <see cref="EditorGUI"/>.
/// Mark the class with <see cref="EditorWindowAttribute"/> to list it in the Tools menu. It can be docked with the
/// editor's other windows; it is open again next time when it was open when the editor closed.</summary>
public abstract class EditorWindow
{
    /// <summary>The window's title (the last part of its menu path).</summary>
    public string Title { get; internal set; } = "";

    internal bool CloseRequested;

    /// <summary>Called when the window opens (also after a recompile, with a new object).</summary>
    public virtual void OnEnable() { }

    /// <summary>Called when the window closes, and before a recompile replaces it.</summary>
    public virtual void OnDisable() { }

    /// <summary>Draws the window's contents.</summary>
    public abstract void OnGUI();

    /// <summary>Closes the window after this frame.</summary>
    public void Close() => CloseRequested = true;
}

/// <summary>The saved field values of the script an <see cref="Inspector"/> is drawing, as text in the scene file's
/// form (numbers with '.', vectors "x,y,z", true/false, enum constant names). Setting one records it for undo, saves
/// it with the scene, calls the script's OnValidate and, during Play, changes the running script.</summary>
public sealed class SerializedScript
{
    internal SerializedScript() { }

    /// <summary>The script's full class name.</summary>
    public string ScriptName => EditorHost.QueryText(EditorHost.QueryTargetScript);

    /// <summary>The name of the object the script is on.</summary>
    public string ObjectName => EditorHost.QueryText(EditorHost.QueryTargetObject);

    /// <summary>A field's value as text (its default when the scene has not set it); null when there is no such
    /// field.</summary>
    public string? Get(string field) => EditorHost.TargetRead(field);

    /// <summary>Sets a field from text. False when there is no such field or the value cannot be stored (a value
    /// with a tab or a line break, or one the running script refused).</summary>
    public bool Set(string field, string value) => EditorHost.TargetWrite(field, value);

    /// <summary>A number field's value (0 when missing or not a number).</summary>
    public float GetFloat(string field) =>
        float.TryParse(Get(field), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out float value) ? value : 0;

    /// <summary>Sets a number field.</summary>
    public bool SetFloat(string field, float value) => Set(field, value.ToString("R", System.Globalization.CultureInfo.InvariantCulture));

    /// <summary>A whole-number field's value (0 when missing).</summary>
    public int GetInt(string field) =>
        int.TryParse(Get(field), System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out int value) ? value : 0;

    /// <summary>Sets a whole-number field.</summary>
    public bool SetInt(string field, int value) => Set(field, value.ToString(System.Globalization.CultureInfo.InvariantCulture));

    /// <summary>A bool field's value.</summary>
    public bool GetBool(string field) => Get(field) is { } text && (text.Equals("true", StringComparison.OrdinalIgnoreCase) || text == "1");

    /// <summary>Sets a bool field.</summary>
    public bool SetBool(string field, bool value) => Set(field, value ? "true" : "false");

    /// <summary>A Vector3 field's value.</summary>
    public Vector3 GetVector3(string field)
    {
        Span<float> parts = stackalloc float[3];
        EditorGUI.ParseFloats(Get(field), parts);
        return new Vector3(parts[0], parts[1], parts[2]);
    }

    /// <summary>Sets a Vector3 field.</summary>
    public bool SetVector3(string field, Vector3 value) => Set(field, EditorGUI.FormatFloats([value.X, value.Y, value.Z]));

    /// <summary>An enum field's value (its default when missing or not one of its constants).</summary>
    public T GetEnum<T>(string field) where T : struct, Enum => Enum.TryParse(Get(field), out T value) ? value : default;

    /// <summary>Sets an enum field.</summary>
    public bool SetEnum<T>(string field, T value) where T : struct, Enum => Set(field, value.ToString());
}

/// <summary>The editor itself.</summary>
public static class EditorApplication
{
    /// <summary>Whether the editor is in Play.</summary>
    public static bool IsPlaying => EditorHost.Query(EditorHost.QueryPlaying) != 0;

    /// <summary>The open project's folder.</summary>
    public static string ProjectPath => EditorHost.QueryText(EditorHost.QueryProjectPath);

    /// <summary>The name of the object selected in the Hierarchy; empty when none is.</summary>
    public static string SelectedObjectName => EditorHost.QueryText(EditorHost.QuerySelection);

    /// <summary>Writes a line to the editor's Console.</summary>
    public static void Log(string message) => EditorHost.Log(0, message);

    /// <summary>Writes a warning to the editor's Console.</summary>
    public static void LogWarning(string message) => EditorHost.Log(1, message);

    /// <summary>Writes an error to the editor's Console.</summary>
    public static void LogError(string message) => EditorHost.Log(2, message);
}
