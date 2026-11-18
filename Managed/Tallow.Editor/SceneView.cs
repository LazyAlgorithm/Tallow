using System;
using System.Numerics;

namespace Tallow.Editor;

/// <summary>A ray through the Scene view: where it starts (the camera) and which way it goes.</summary>
public readonly record struct ViewRay(Vector3 Origin, Vector3 Direction);

/// <summary>
/// Draws in the Scene view every frame while it is open, and can read where the mouse is and what it is over:
/// derive from it (any concrete subclass is picked up), draw with <see cref="SceneView.Line"/> and its kin (the
/// editor's own <see cref="Tallow.Gizmos"/> batches, so they are seen through or over the scene as asked), and use
/// the mouse state to make a tool. Its OnSceneViewGUI runs while the editor renders, so it draws gizmos and reads
/// input, but does not lay out widgets: an editor window or an Inspector is for those.
/// </summary>
/// <example><code>
/// public class SpawnRing : SceneViewOverlay
/// {
///     public override void OnSceneViewGUI()
///     {
///         Vector3 center = EditorScene.Selection?.Position ?? Vector3.Zero;
///         SceneView.Sphere(center, 4, Color.Yellow);
///         if (SceneView.IsMouseOver &amp;&amp; SceneView.IsClicked &amp;&amp; SceneView.PickUnderMouse() is { } picked)
///             EditorScene.Selection = picked;
///     }
/// }
/// </code></example>
public abstract class SceneViewOverlay
{
    /// <summary>Called once per frame while the Scene view is open.</summary>
    public virtual void OnSceneViewGUI() { }
}

/// <summary>The editor's Scene view: whether it is open, where the mouse is, what it is over, and helpers for
/// drawing in it. For editor scripts only (a game's own gizmos come from <see cref="Tallow.Gizmos"/>).</summary>
public static class SceneView
{
    /// <summary>Whether the Scene view is open (it can be hidden under another tab).</summary>
    public static bool IsVisible => EditorHost.SceneViewState(EditorHost.SceneViewVisible);

    /// <summary>Whether the mouse is over the Scene view.</summary>
    public static bool IsMouseOver => EditorHost.SceneViewState(EditorHost.SceneViewHovered);

    /// <summary>Whether the mouse was clicked there this frame (left button).</summary>
    public static bool IsClicked => EditorHost.SceneViewState(EditorHost.SceneViewClicked);

    /// <summary>Whether the left button is held, whether or not over the view.</summary>
    public static bool IsMouseDown => EditorHost.SceneViewState(EditorHost.SceneViewMouseDown);

    /// <summary>Where the mouse is in the view, from 0 to 1 across and down.</summary>
    public static Vector2 MousePoint
    {
        get
        {
            Span<float> values = stackalloc float[2];
            EditorHost.SceneViewCursor(values);
            return new Vector2(values[0], values[1]);
        }
    }

    /// <summary>The ray through a point of the view (0 to 1 across and down); not valid when the view is closed.</summary>
    public static ViewRay Ray(Vector2 point)
    {
        Span<float> values = stackalloc float[6];
        return EditorHost.SceneViewRay(point.X, point.Y, values)
            ? new ViewRay(new Vector3(values[0], values[1], values[2]), new Vector3(values[3], values[4], values[5]))
            : default;
    }

    /// <summary>The object under a point of the view (0 to 1 across and down); none when there is none.</summary>
    public static EditorObject Pick(Vector2 point) => new(EditorHost.SceneViewPick(point.X, point.Y));

    /// <summary>The object under the mouse, from the Scene view's own picking (the same objects clicks select from).</summary>
    public static EditorObject PickUnderMouse() => Pick(MousePoint);

    /// <summary>A line in the Scene view, drawn this frame.</summary>
    public static void Line(Vector3 a, Vector3 b, Color color, bool onTop = false) => Tallow.Gizmos.Line(a, b, color, onTop);

    /// <summary>A wire sphere in the Scene view, drawn this frame.</summary>
    public static void Sphere(Vector3 center, float radius, Color color, bool onTop = false) =>
        Tallow.Gizmos.Sphere(center, radius, color, onTop);

    /// <summary>A wire box (size is the full size) in the Scene view, drawn this frame.</summary>
    public static void Box(Vector3 center, Vector3 size, Color color, bool onTop = false) =>
        Tallow.Gizmos.Box(center, size, color, onTop);
}
