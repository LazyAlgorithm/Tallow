using Tallow;

namespace Tallow.Editor;

/// <summary>
/// An object's model (its Model Mesh), for modelling tools written as editor scripts: read it into an
/// <see cref="EditMesh"/>, work on the mesh with the whole modeller API (shapes, extrude, inset, subdivide,
/// bevel, UVs, colours, materials, booleans...), and write it back. Writing marks the scene dirty, so the editor's
/// snapshot undo makes it a step; Dispose the mesh when done.
/// </summary>
/// <example><code>
/// if (EditorModel.Read(EditorScene.Selection!.Value) is { } model)
/// {
///     using (model)
///     {
///         model.ExtrudeFaces(model.FacesFacing(Vector3.UnitY), 0.25f);
///         EditorModel.Write(EditorScene.Selection!.Value, model);
///     }
/// }
/// </code></example>
public static class EditorModel
{
    /// <summary>The object's Model Mesh as a new mesh (Dispose it when done), or null when it has none.</summary>
    public static EditMesh? Read(EditorObject target)
    {
        int handle = EditorHost.ModelRead(target.Id);
        return handle != 0 ? EditMesh.FromHandle(handle) : null;
    }

    /// <summary>
    /// Makes the mesh the object's Model Mesh: added, with a Mesh Renderer when it has none. The mesh is copied, so
    /// it can be disposed after; false when the object is gone or this is Play mode.
    /// </summary>
    public static bool Write(EditorObject target, EditMesh mesh) => EditorHost.ModelWrite(target.Id, mesh.Handle);
}
