using System;
using System.Collections;

namespace Tallow;

/// Meshes C# scripts build at run time (MeshRenderer.SetMesh). The renderer does not own a RuntimeMesh, so these do:
/// one per object, reused when the script builds it again, freed when the object is gone (checked whenever another
/// is set) or when the game unloads.
[CSharpExpose]
static class CSharpMeshes
{
	class Owned
	{
		public uint64 session, entity;
		public Mesh mesh ~ delete _;
	}

	static List<Owned> sOwned = new .() ~ DeleteContainerAndItems!(_);

	/// The renderer's own mesh again (the one its mesh field names), freeing what was being drawn in its place.
	static void Release(int index, bool clearRenderer)
	{
		let owned = sOwned[index];
		if (clearRenderer)
		{
			GameObject obj = null;
			if (CSharpRuntime.StillInScene(owned.session, owned.entity))
				obj = CSharpRuntime.[Friend]sScene.FindById((uint32)owned.entity);
			MeshRenderer renderer = obj != null ? obj.GetComponent<MeshRenderer>() : default;
			if (renderer && renderer.RuntimeMesh == owned.mesh)
				renderer.RuntimeMesh = null;
		}
		sOwned.RemoveAtFast(index);
		delete owned;
	}

	/// Frees the meshes of objects that are gone (not those destroyed this frame: they are still drawn).
	static void Sweep()
	{
		for (int i = sOwned.Count - 1; i >= 0; i--)
			if (!CSharpRuntime.StillInScene(sOwned[i].session, sOwned[i].entity))
				Release(i, false);
	}

	/// Every mesh, when the game unloads (renderers still in the scene go back to their own meshes).
	public static void ReleaseAll()
	{
		for (int i = sOwned.Count - 1; i >= 0; i--)
			Release(i, true);
	}

	/// Draws a mesh built from these numbers in place of the Mesh Renderer's own: positions xyz per vertex, normals
	/// xyz (empty: worked out smooth from the triangles), uvs xy (empty: all 0) and indices three per triangle
	/// (clockwise from the front; numbers, exact to 16 million vertices). The vertex count, or -1 without a Mesh
	/// Renderer, -2 when the lengths do not fit together, -3 for an index that is not a vertex.
	[CSharpExpose]
	public static int32 SetMesh(uint64 session, uint64 entity, Span<float> positions, Span<float> normals,
		Span<float> uvs, Span<float> indices)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		MeshRenderer renderer = obj != null ? obj.GetComponent<MeshRenderer>() : default;
		if (!renderer)
			return -1;
		let count = positions.Length / 3;
		if (positions.Length % 3 != 0 || (!normals.IsEmpty && normals.Length != positions.Length) ||
			(!uvs.IsEmpty && uvs.Length != count * 2) || indices.Length % 3 != 0)
			return -2;
		for (let index in indices)
			if (index < 0 || index >= count || index != Math.Floor(index))
				return -3;
		Sweep();
		Owned owned = null;
		for (let o in sOwned)
			if (o.session == session && o.entity == entity)
				owned = o;
		if (owned == null)
		{
			owned = new .();
			owned.session = session;
			owned.entity = entity;
			owned.mesh = new .();
			owned.mesh.Name.Set(scope $"{obj.Name} (C# mesh)");
			sOwned.Add(owned);
		}
		let mesh = owned.mesh;
		mesh.Clear();
		for (int i < count)
		{
			let normal = normals.IsEmpty ? Vector3.Zero : Vector3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]);
			let uv = uvs.IsEmpty ? Vector2.Zero : Vector2(uvs[i * 2], uvs[i * 2 + 1]);
			mesh.Vertices.Add(.(.(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]), normal, 0xFFFFFFFF, uv));
		}
		for (let index in indices)
			mesh.Indices.Add((uint32)index);
		if (normals.IsEmpty)
			mesh.RecalculateNormals();
		mesh.Upload();
		renderer.RuntimeMesh = mesh;
		return (int32)count;
	}

	/// Goes back to the renderer's own mesh. False when no C# mesh was set on it.
	[CSharpExpose]
	public static bool ClearMesh(uint64 session, uint64 entity)
	{
		for (int i < sOwned.Count)
			if (sOwned[i].session == session && sOwned[i].entity == entity)
			{
				Release(i, true);
				return true;
			}
		return false;
	}
}
