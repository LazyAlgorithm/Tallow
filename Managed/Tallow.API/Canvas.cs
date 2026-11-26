using System.Numerics;

namespace Tallow;

/// <summary>
/// Immediate-mode drawing into the interface (a document's <c>ondraw</c> canvas, or OnGUI): the game's own menu
/// artwork, its font and its HUD. Window pixels, from the top left. <see cref="UIElement.ScreenX"/> and the other
/// screen properties place a canvas's contents exactly where the document drew it.
/// </summary>
public static class Canvas
{
    private static Vector4 Rgba(Color color) => new(color.R, color.G, color.B, color.A);

    /// <summary>The game view's origin (X, Y) and size (Z, W) in window pixels.</summary>
    public static Vector4 ScreenRect
    {
        get
        {
            Span<float> values = stackalloc float[4];
            CSharpCanvas.ScreenRect(values);
            return new Vector4(values[0], values[1], values[2], values[3]);
        }
    }

    /// <summary>Paints an image (a project path) into a rectangle.</summary>
    public static void DrawImage(string path, float minX, float minY, float maxX, float maxY,
        Color? tint = null, bool opaque = false) =>
        CSharpCanvas.DrawImage(path ?? "", minX, minY, maxX, maxY, Rgba(tint ?? Color.White), opaque);

    /// <summary>Paints an image turned about its middle; angle in radians.</summary>
    public static void DrawImageRotated(string path, float centerX, float centerY, float width, float height,
        float angle) =>
        CSharpCanvas.DrawImageRotated(path ?? "", centerX, centerY, width, height, angle);

    /// <summary>A filled rounded rectangle.</summary>
    public static void DrawRectFilled(float minX, float minY, float maxX, float maxY, Color color, float rounding = 0) =>
        CSharpCanvas.DrawRectFilled(minX, minY, maxX, maxY, Rgba(color), rounding);

    /// <summary>A rounded rectangle's outline.</summary>
    public static void DrawRect(float minX, float minY, float maxX, float maxY, Color color,
        float rounding = 0, float thickness = 1) =>
        CSharpCanvas.DrawRect(minX, minY, maxX, maxY, Rgba(color), rounding, thickness);

    /// <summary>A line between two points.</summary>
    public static void DrawLine(float ax, float ay, float bx, float by, Color color, float thickness = 1) =>
        CSharpCanvas.DrawLine(ax, ay, bx, by, Rgba(color), thickness);

    /// <summary>A filled triangle.</summary>
    public static void DrawTriangle(float ax, float ay, float bx, float by, float cx, float cy, Color color) =>
        CSharpCanvas.DrawTriangle(ax, ay, bx, by, cx, cy, Rgba(color));

    /// <summary>Limits what is drawn next to a rectangle until <see cref="PopClip"/>.</summary>
    public static void PushClip(float minX, float minY, float maxX, float maxY) =>
        CSharpCanvas.PushClip(minX, minY, maxX, maxY);

    /// <summary>Ends the last <see cref="PushClip"/>.</summary>
    public static void PopClip() => CSharpCanvas.PopClip();

    /// <summary>Switches to the interface's font at a pixel size until <see cref="PopFont"/>.</summary>
    public static void PushFontSize(float size) => CSharpCanvas.PushFontSize(size);

    /// <summary>Goes back to the previous font.</summary>
    public static void PopFont() => CSharpCanvas.PopFont();

    /// <summary>The size a line of text takes in the current font.</summary>
    public static Vector2 TextSize(string text)
    {
        Span<float> values = stackalloc float[2];
        CSharpCanvas.TextSize(text ?? "", values);
        return new Vector2(values[0], values[1]);
    }

    /// <summary>Draws text in the current font at a point.</summary>
    public static void DrawText(float x, float y, string text, Color? color = null) =>
        CSharpCanvas.DrawText(x, y, Rgba(color ?? Color.White), text ?? "");

    /// <summary>ImGui's input capture flags: bit 2 (4) is set while a text box has the keyboard.</summary>
    public static int CaptureFlags => CSharpCanvas.CaptureFlags();
    /// <summary>Whether any interface item is being worked (a text box mostly).</summary>
    public static bool AnyItemActive => CSharpCanvas.AnyItemActive();

    /// <summary>The editor's move/turn/size handles over a rectangle of the window.</summary>
    public static void GizmoBegin(float x, float y, float width, float height, bool orthographic = false) =>
        CSharpCanvas.GizmoBegin(x, y, width, height, orthographic);

    /// <summary>Works the handles. <paramref name="data"/>: 16 view, 16 projection, 16 world matrix (written back),
    /// then a snap step per axis (all zero: no snapping). True on a change.</summary>
    public static bool GizmoManipulate(float[] data, int operation, bool local) =>
        CSharpCanvas.GizmoManipulate(data, operation, local);

    /// <summary>Whether a handle is being dragged.</summary>
    public static bool GizmoUsing => CSharpCanvas.GizmoUsing();
    /// <summary>Whether the pointer is over a handle.</summary>
    public static bool GizmoOver => CSharpCanvas.GizmoOver();
}

public readonly partial record struct Camera
{
    /// <summary>The view and projection matrices (16 + 16 floats, column by column) for a picture's
    /// width-to-height ratio; false without a camera.</summary>
    public bool TryGetViewProjection(float aspect, Span<float> values) =>
        CSharpCanvas.CameraViewProjection(GameObject.SceneId, GameObject.Id, aspect, values);
}
