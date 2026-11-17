global using System.Numerics;
using System.Globalization;

namespace Tallow.Editor;

/// <summary>How a <see cref="EditorGUI.HelpBox"/> looks.</summary>
public enum MessageKind
{
    /// <summary>A note.</summary>
    Info,
    /// <summary>Something to look at.</summary>
    Warning,
    /// <summary>Something wrong.</summary>
    Error
}

/// <summary>Editor widgets, for <see cref="Inspector.OnInspectorGUI"/> and <see cref="EditorWindow.OnGUI"/>. They are
/// immediate: each call draws one widget this frame, top to bottom, and returns its value (the new one when it was
/// edited this frame). A label is drawn on the left, as in the Inspector; labels are also how widgets tell each other
/// apart, so two widgets with the same label in one window need a "##" suffix ("Speed##front"; what follows "##" is
/// not shown).</summary>
public static partial class EditorGUI
{
    /// <summary>True once any widget was edited since it was last set false. Set it false before a group of
    /// widgets to find whether one of them changed.</summary>
    public static bool Changed { get; set; }

    private static T Track<T>(bool changed, T value)
    {
        if (changed)
            Changed = true;
        return value;
    }

    /// <summary>A line of text.</summary>
    public static void Label(string text) => EditorHost.Text(0, text);

    /// <summary>A line of greyed-out text.</summary>
    public static void DisabledLabel(string text) => EditorHost.Text(1, text);

    /// <summary>Text that wraps at the window's edge.</summary>
    public static void WrappedLabel(string text) => EditorHost.Text(2, text);

    /// <summary>A heading, with a line under it.</summary>
    public static void Heading(string text) => EditorHost.Text(3, text);

    /// <summary>A coloured note.</summary>
    public static void HelpBox(string text, MessageKind kind = MessageKind.Info) => EditorHost.Text(4 + (int)kind, text);

    /// <summary>A button: true the frame it was clicked.</summary>
    public static bool Button(string label, bool fullWidth = false) => EditorHost.Button(label, fullWidth ? -1 : 0, 0);

    /// <summary>A checkbox.</summary>
    public static bool Toggle(string label, bool value)
    {
        int state = value ? 1 : 0;
        return Track(EditorHost.Toggle(label, ref state), state != 0);
    }

    /// <summary>A number, changed by dragging or typing.</summary>
    public static float FloatField(string label, float value, float speed = 0.05f)
    {
        bool changed = EditorHost.Float(label, ref value, speed, 0, 0, false);
        return Track(changed, value);
    }

    /// <summary>A number between min and max, on a slider.</summary>
    public static float Slider(string label, float value, float min, float max)
    {
        bool changed = EditorHost.Float(label, ref value, 0, min, max, true);
        return Track(changed, value);
    }

    /// <summary>A whole number, changed by dragging or typing.</summary>
    public static int IntField(string label, int value) => Track(EditorHost.Int(label, ref value, 0.1f, 0, 0), value);

    /// <summary>A whole number kept between min and max.</summary>
    public static int IntSlider(string label, int value, int min, int max) =>
        Track(EditorHost.Int(label, ref value, 0.1f, min, max), Math.Clamp(value, min, max));

    /// <summary>Two numbers.</summary>
    public static Vector2 Vector2Field(string label, Vector2 value)
    {
        Span<float> parts = [value.X, value.Y];
        return Track(EditorHost.Vector(label, parts, 2), new Vector2(parts[0], parts[1]));
    }

    /// <summary>Three numbers.</summary>
    public static Vector3 Vector3Field(string label, Vector3 value)
    {
        Span<float> parts = [value.X, value.Y, value.Z];
        return Track(EditorHost.Vector(label, parts, 3), new Vector3(parts[0], parts[1], parts[2]));
    }

    /// <summary>Four numbers.</summary>
    public static Vector4 Vector4Field(string label, Vector4 value)
    {
        Span<float> parts = [value.X, value.Y, value.Z, value.W];
        return Track(EditorHost.Vector(label, parts, 4), new Vector4(parts[0], parts[1], parts[2], parts[3]));
    }

    /// <summary>A colour (red, green, blue, alpha from 0 to 1), with a picker.</summary>
    public static Color ColorField(string label, Color value)
    {
        Span<float> parts = [value.R, value.G, value.B, value.A];
        return Track(EditorHost.Vector(label, parts, 5), new Color(parts[0], parts[1], parts[2], parts[3]));
    }

    /// <summary>One line of text.</summary>
    public static string TextField(string label, string value) => Track(EditorHost.TextField(label, ref value, false), value);

    /// <summary>Text over several lines.</summary>
    public static string TextArea(string label, string value) => Track(EditorHost.TextField(label, ref value, true), value);

    /// <summary>A list to pick one of: the index picked (-1 shows nothing picked).</summary>
    public static int Popup(string label, int index, IReadOnlyList<string> options) =>
        Track(EditorHost.Popup(label, options, ref index), index);

    /// <summary>A list of an enum's constants.</summary>
    public static T EnumPopup<T>(string label, T value) where T : struct, Enum
    {
        T[] values = Enum.GetValues<T>();
        string[] names = Array.ConvertAll(values, item => item.ToString());
        int index = Array.IndexOf(values, value);
        int picked = Popup(label, index, names);
        return picked >= 0 && picked < values.Length ? values[picked] : value;
    }

    /// <summary>A heading that opens and closes the widgets under it: true while open (draw them only then). The
    /// editor remembers whether it is open.</summary>
    public static bool Foldout(string label, bool openAtFirst = true) => EditorHost.Foldout(label, openAtFirst);

    /// <summary>A bar filled to fraction (0 to 1), with optional text on it.</summary>
    public static void ProgressBar(float fraction, string text = "") => EditorHost.Progress(fraction, text);

    /// <summary>Shows text when the mouse is over the widget drawn just before.</summary>
    public static void Tooltip(string text) => EditorHost.Tooltip(text);

    /// <summary>A line across the window.</summary>
    public static void Separator() => EditorHost.Layout(EditorHost.LayoutSeparator, 0);

    /// <summary>Some empty space.</summary>
    public static void Space() => EditorHost.Layout(EditorHost.LayoutSpacing, 0);

    /// <summary>Draws the next widget on the same line as the last one.</summary>
    public static void SameLine() => EditorHost.Layout(EditorHost.LayoutSameLine, 0);

    /// <summary>Widgets until the scope ends are greyed out and cannot be edited (when disabled is true).</summary>
    /// <example><code>using (EditorGUI.Disabled(!EditorApplication.IsPlaying)) { ... }</code></example>
    public static Scope Disabled(bool disabled = true) => EditorHost.Push(EditorHost.LayoutBeginDisabled, disabled ? 1 : 0);

    /// <summary>Widgets until the scope ends are indented.</summary>
    public static Scope Indented() => EditorHost.Push(EditorHost.LayoutIndent, 0);

    /// <summary>Widgets until the scope ends are told apart from others with the same labels by id (for widgets
    /// drawn in a loop).</summary>
    public static Scope Id(int id) => EditorHost.Push(EditorHost.LayoutPushId, id);

    /// <summary>Ends what <see cref="Disabled"/>, <see cref="Indented"/> or <see cref="Id"/> started. Use it with
    /// "using".</summary>
    public readonly struct Scope : IDisposable
    {
        internal readonly int Depth;
        internal Scope(int depth) => Depth = depth;

        /// <summary>Ends the scope.</summary>
        public void Dispose() => EditorHost.Pop(Depth);
    }

    internal static void ParseFloats(string? text, Span<float> parts)
    {
        parts.Clear();
        if (text == null)
            return;
        int index = 0;
        foreach (Range range in text.AsSpan().Split(','))
        {
            if (index >= parts.Length)
                break;
            float.TryParse(text.AsSpan(range), NumberStyles.Float, CultureInfo.InvariantCulture, out parts[index++]);
        }
    }

    internal static string FormatFloats(ReadOnlySpan<float> parts)
    {
        var text = new System.Text.StringBuilder();
        for (int i = 0; i < parts.Length; i++)
        {
            if (i > 0)
                text.Append(',');
            text.Append(parts[i].ToString("R", CultureInfo.InvariantCulture));
        }
        return text.ToString();
    }
}
