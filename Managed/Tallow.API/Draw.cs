using System.Numerics;

namespace Tallow;

/// <summary>A color with red, green, blue and alpha from 0 to 1.</summary>
public readonly record struct Color(float R, float G, float B, float A = 1f)
{
    /// <summary>White.</summary>
    public static Color White => new(1f, 1f, 1f);
    /// <summary>Black.</summary>
    public static Color Black => new(0f, 0f, 0f);
    /// <summary>A bright red.</summary>
    public static Color Red => new(1f, 0.2f, 0.2f);
    /// <summary>A bright green.</summary>
    public static Color Green => new(0.2f, 1f, 0.2f);
    /// <summary>A light blue.</summary>
    public static Color Blue => new(0.3f, 0.5f, 1f);
    /// <summary>Yellow.</summary>
    public static Color Yellow => new(1f, 0.9f, 0.2f);
    /// <summary>Cyan.</summary>
    public static Color Cyan => new(0.2f, 0.9f, 1f);

    /// <summary>The colour t of the way from a to b (t is kept between 0 and 1).</summary>
    public static Color Lerp(Color a, Color b, float t)
    {
        t = Math.Clamp(t, 0f, 1f);
        return new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t, a.A + (b.A - a.A) * t);
    }

    internal System.Numerics.Vector4 Packed => new(R, G, B, A);
}

/// <summary>Lines drawn from gameplay code for one frame, seen in the game and the editor.</summary>
public static class DebugDraw
{
    /// <summary>A line from a to b, for this frame.</summary>
    public static void Line(Vector3 a, Vector3 b, Color color) => CSharpDraw.Line(0, a, b, color.Packed);
    /// <summary>A wire sphere, for this frame.</summary>
    public static void Sphere(Vector3 center, float radius, Color color) => CSharpDraw.Sphere(0, center, radius, color.Packed);
    /// <summary>A wire box (size is the full size), for this frame.</summary>
    public static void Box(Vector3 center, Vector3 size, Color color) => CSharpDraw.Box(0, center, size, color.Packed);
}

/// <summary>Editor helpers drawn in the Scene view only (never in the Game view or a built game); call them from
/// <see cref="Script.OnDrawGizmos"/>. <c>onTop</c> draws through whatever is in front.</summary>
public static class Gizmos
{
    /// <summary>A line from a to b.</summary>
    public static void Line(Vector3 a, Vector3 b, Color color, bool onTop = false) =>
        CSharpDraw.Line(onTop ? 2 : 1, a, b, color.Packed);
    /// <summary>A wire sphere.</summary>
    public static void Sphere(Vector3 center, float radius, Color color, bool onTop = false) =>
        CSharpDraw.Sphere(onTop ? 2 : 1, center, radius, color.Packed);
    /// <summary>A wire box (size is the full size).</summary>
    public static void Box(Vector3 center, Vector3 size, Color color, bool onTop = false) =>
        CSharpDraw.Box(onTop ? 2 : 1, center, size, color.Packed);
}
