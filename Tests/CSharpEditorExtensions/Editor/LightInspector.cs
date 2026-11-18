using Tallow;
using Tallow.Editor;

namespace InGame.Editor;

/// <summary>A C# Inspector for the built-in Light component (the editor-extension test checks that the Inspector
/// shows it instead of the plain field list, and that Target reads the component the scene has).</summary>
[CustomInspector(typeof(Light))]
public class LightInspector : ComponentInspector
{
    public override void OnInspectorGUI()
    {
        ProjectPrefs.SetBool("lightInspectorDrawn", true);
        ProjectPrefs.SetString("lightInspectorTarget", Target.TypeName);
        ProjectPrefs.SetString("lightInspectorIntensity",
            Target.GetFloat("intensity").ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (EditorGUI.Button("Dim"))
            Target.SetFloat("intensity", Target.GetFloat("intensity") * 0.5f);
        EditorGUI.Label("Drawn by a C# Inspector");
        Field("intensity");
    }
}
