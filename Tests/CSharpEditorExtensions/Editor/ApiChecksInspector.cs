using Tallow;
using Tallow.Editor;

namespace InGame.Editor;

/// <summary>Draws ApiChecks with one field, a heading and the rest, and sets Speed once.</summary>
[CustomInspector(typeof(ApiChecks))]
public class ApiChecksInspector : Inspector
{
    private bool _set;

    public override void OnInspectorGUI()
    {
        EditorGUI.Heading("Probe Inspector");
        Field("Speed");
        if (!_set)
        {
            _set = true;
            Target.SetFloat("Speed", Target.GetFloat("Speed") * 2);
            ProjectPrefs.SetString("inspectorTarget", $"{Target.ScriptName} on {Target.ObjectName}");
        }
        using (EditorGUI.Indented())
            DrawDefaultInspector();
    }
}
