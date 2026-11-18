using System;
using System.Numerics;
using System.Text;
using Tallow.Editor;

namespace InGame.Editor;

/// <summary>
/// Exercises Tallow.Editor's EditorScene from a Tools command. The editor's --editor-extensions-test
/// (tools/test_csharp_editor_extensions.py) runs it, checks what it reports, and checks the scene the Beef side
/// sees: the "Probe Kept" object it leaves behind with a light of intensity 2.5, then undo.
/// </summary>
public static class SceneProbe
{
    [MenuItem("Test/Scene Probe")]
    private static void Run()
    {
        var report = new StringBuilder();
        bool ok = true;
        void Check(string what, bool passed)
        {
            ok &= passed;
            if (report.Length > 0)
                report.Append("; ");
            report.Append(what).Append(": ").Append(passed);
        }

        Check("editable", EditorScene.IsEditable);

        EditorObject cube = EditorScene.Create("Cube", EditorObject.None);
        Check("create", cube.Exists && cube.Name == "Cube" && cube.HasComponent("Tallow.MeshRenderer"));

        cube.Position = new Vector3(1, 2, 3);
        cube.Rotation = new Vector3(0, 45, 0);
        cube.Scale = new Vector3(2, 2, 2);
        Check("transform",
            cube.Position == new Vector3(1, 2, 3) && MathF.Abs(cube.Rotation.Y - 45) < 0.01f &&
            cube.Scale == new Vector3(2, 2, 2));

        cube.Name = "Probe Cube";
        Check("rename and find", cube.Name == "Probe Cube" && EditorScene.Find("Probe Cube") == cube);

        EditorObject child = cube.Create("Sphere");
        Check("create under a parent",
            child.Exists && child.Parent == cube && EditorScene.Find("Probe Cube/Sphere") == child);

        EditorScene.Selection = child;
        Check("selection", EditorScene.Selection == child);

        EditorObject copy = child.Duplicate();
        Check("duplicate", copy.Exists && copy != child);

        EditorComponent? light = cube.AddComponent("Tallow.Light");
        Check("add a component", light is { } added && added.Exists && cube.HasComponent("Tallow.Light"));
        bool listed = false;
        if (light is { } listedLight)
            foreach (EditorField field in listedLight.Fields)
                listed |= field.Name == "intensity";
        Check("the field is listed", listed);
        Check("a field reads and writes",
            light!.Value.SetFloat("intensity", 2.5f) && MathF.Abs(light.Value.GetFloat("intensity") - 2.5f) < 0.001f);
        Check("remove a component", cube.RemoveComponent("Tallow.Light") && !cube.HasComponent("Tallow.Light"));

        cube.Delete();
        Check("delete takes the children", !cube.Exists && !child.Exists && !copy.Exists);

        // Left behind for the editor itself to look at (and undo to remove).
        EditorObject kept = EditorScene.Create("Cube", EditorObject.None);
        kept.Name = "Probe Kept";
        kept.Position = new Vector3(4, 0, -2);
        EditorComponent addedLight = kept.AddComponent("Tallow.Light")!.Value;
        addedLight.SetFloat("intensity", 2.5f);
        Check("kept", kept.Exists && kept.Name == "Probe Kept" && MathF.Abs(kept.Position.X - 4) < 0.001f);
        // The Inspector draws the selected object: the kept cube's Light has a C# Inspector of its own.
        EditorScene.Selection = kept;

        ProjectPrefs.SetBool("sceneProbeOk", ok);
        ProjectPrefs.SetString("sceneProbe", report.ToString());
    }
}
