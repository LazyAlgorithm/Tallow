using Tallow;
using Tallow.Editor;

namespace InGame.Editor;

[EditorWindow("Test/Probe Window")]
public class ProbeWindow : EditorWindow
{
    private float _value = 0.5f;
    private string _text = "text";
    private int _choice;
    private Vector3 _vector = Vector3.One;

    public override void OnGUI()
    {
        EditorGUI.Heading("Every widget");
        EditorGUI.Label("A label");
        EditorGUI.HelpBox("A warning", MessageKind.Warning);
        _value = EditorGUI.Slider("Slider", _value, 0, 1);
        _text = EditorGUI.TextField("Text", _text);
        _choice = EditorGUI.Popup("Choice", _choice, ["One", "Two", "Three"]);
        _vector = EditorGUI.Vector3Field("Vector", _vector);
        EditorGUI.ColorField("Colour", Color.Cyan);
        EditorGUI.EnumPopup("Kind", MessageKind.Error);
        using (EditorGUI.Disabled())
            EditorGUI.Button("Disabled button");
        EditorGUI.ProgressBar(_value, "Progress");
        if (EditorGUI.Foldout("More"))
            for (int i = 0; i < 3; i++)
                using (EditorGUI.Id(i))
                    EditorGUI.Toggle("Same label", i == 1);
        ProjectPrefs.SetString("windowSelection", EditorApplication.SelectedObjectName);
    }
}

/// <summary>Throws inside a scope it never ends: the editor must carry on and report it once.</summary>
[EditorWindow("Test/Broken Window")]
public class BrokenWindow : EditorWindow
{
    public override void OnGUI()
    {
        EditorGUI.Label("Before the failure");
        EditorGUI.Disabled();
        EditorGUI.Indented();
        throw new InvalidOperationException("The broken window fails on purpose.");
    }
}

public static class ProbeCommands
{
    [MenuItem("Test/Run Probe")]
    private static void Run()
    {
        ProbeSettings settings = EditorPrefs.Get<ProbeSettings>();
        settings.GridSize = 3;
        EditorPrefs.Save(settings);
        ProjectPrefs.SetBool("menuRan", true);
    }
}

[PreferencesPage("Probe Settings")]
public class ProbeSettings
{
    public float GridSize = 1;
    public bool SnapToGrid = true;
    public string Author = "";
    public MessageKind Kind = MessageKind.Info;
}

[PreferencesPage("Probe Drawn")]
public class ProbeDrawnPage : PreferencesPage
{
    public override void OnGUI()
    {
        EditorGUI.Label("A tab that draws itself");
        ProjectPrefs.SetBool("pageDrawn", true);
    }
}
