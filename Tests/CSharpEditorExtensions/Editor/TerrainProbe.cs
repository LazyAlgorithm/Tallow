using System.Numerics;
using System.Text;
using Tallow;
using Tallow.Editor;

namespace InGame.Editor;

/// <summary>
/// Exposes the terrain API to the editor-extension test in two commands, so the editor can sample the terrain
/// itself between them: Make puts a terrain in the scene, Dig sculpts it inside an undo record.
/// </summary>
public static class TerrainProbe
{
    private const string Name = "Probe Terrain";

    [MenuItem("Test/Terrain Make")]
    private static void Make()
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

        EditorObject ground = EditorScene.Create("Voxel Terrain", EditorObject.None);
        Check("terrain made", ground.Exists && ground.HasComponent("Tallow.VoxelTerrain"));
        if (ground.Exists)
        {
            ground.Name = Name;
            ground.Select();
        }
        VoxelTerrain? terrain = ground.Exists ? ground.GameObject.GetComponent<VoxelTerrain>() : null;
        Check("terrain handle", terrain is { IsValid: true });

        ProjectPrefs.SetBool("terrainMakeOk", ok);
        ProjectPrefs.SetString("terrainMake", report.ToString());
    }

    [MenuItem("Test/Terrain Dig")]
    private static void Dig()
    {
        EditorObject ground = EditorScene.Find(Name);
        VoxelTerrain? terrain = ground.Exists ? ground.GameObject.GetComponent<VoxelTerrain>() : null;
        bool dug = false;
        using (EditorTerrain.Begin(ground))
            dug = terrain?.ModifySphere(new Vector3(0, 0, 0), 4, -6) == true;
        ProjectPrefs.SetBool("terrainDug", dug);
    }
}
