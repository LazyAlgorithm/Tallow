using System;

namespace Tallow.Editor;

/// <summary>
/// A terrain undo record open while editor scripts sculpt: from <see cref="EditorTerrain.Begin"/> until it is
/// disposed, the chunks the terrain changes are kept as they were, and the changes become one undo step. The
/// script digs and raises the terrain with Tallow.API's <see cref="Tallow.VoxelTerrain"/> calls in between.
/// </summary>
/// <example><code>
/// EditorObject ground = EditorScene.Find("Level/Terrain");
/// using (EditorTerrain.Begin(ground))
/// {
///     VoxelTerrain? terrain = ground.GameObject.GetComponent&lt;VoxelTerrain&gt;();
///     terrain?.ModifySphere(new Vector3(0, 0, 0), 3, -5);
/// }
/// </code></example>
public sealed class EditorTerrainEdit : IDisposable
{
    private readonly EditorObject mTarget;
    private bool mEnded;

    internal EditorTerrainEdit(EditorObject target) => mTarget = target;

    /// <summary>Ends the record: the sculpting becomes the scene's next undo step.</summary>
    public void Dispose()
    {
        if (mEnded)
            return;
        mEnded = true;
        EditorHost.TerrainEnd(mTarget.Id);
    }
}

/// <summary>Terrain sculpting from editor scripts, undoable (see <see cref="EditorTerrainEdit"/>). Which object to
/// give it: the one with the terrain's Voxel Terrain component.</summary>
public static class EditorTerrain
{
    /// <summary>Starts an undo record for the object's terrain; null when it has none (or this is Play mode).</summary>
    public static EditorTerrainEdit? Begin(EditorObject target) =>
        EditorHost.TerrainBegin(target.Id) ? new EditorTerrainEdit(target) : null;
}
