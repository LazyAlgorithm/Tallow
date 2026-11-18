using System.Numerics;
using Tallow;
using Tallow.Editor;

namespace InGame.Editor;

/// <summary>
/// Draws a marker over the selected object in the Scene view and reports what it saw. The editor-extension test
/// checks that it ran, that it saw the Scene view open, and that it got a ray into the scene.
/// </summary>
public class ProbeOverlay : SceneViewOverlay
{
    private int _frames;

    public override void OnSceneViewGUI()
    {
        _frames++;
        if (_frames == 30)
        {
            ProjectPrefs.SetBool("overlayDrawn", true);
            ProjectPrefs.SetBool("overlayVisible", SceneView.IsVisible);
            ProjectPrefs.SetBool("overlayHovered", SceneView.IsMouseOver);
            ProjectPrefs.SetBool("overlayRay", SceneView.Ray(new Vector2(0.5f, 0.5f)).Direction.Length() > 0.5f);
        }
        if (!SceneView.IsVisible)
            return;
        Vector3 center = EditorScene.Selection is { } selected ? selected.Position : Vector3.Zero;
        SceneView.Sphere(center, 2, Color.Yellow);
        SceneView.Line(center, center + Vector3.UnitY * 5, Color.Red);
    }
}
