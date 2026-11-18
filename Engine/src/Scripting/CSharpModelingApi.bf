using System;
using System.Collections;

namespace Tallow;

/// Building models from C# (EditMesh in Tallow.API): the modeller's EditMesh, shapes and edits, by handle. Face and
/// vertex lists come as int32 bytes (faces: Span<uint8> of little-endian int32 indices).
[CSharpExpose]
static class CSharpModeling
{
	static Dictionary<int32, EditMesh> sMeshes = new .() ~ DeleteDictionaryAndValues!(_);
	static int32 sNext = 1;

	static int32 Keep(EditMesh mesh)
	{
		let id = sNext++;
		sMeshes[id] = mesh;
		return id;
	}

	static EditMesh Find(int32 id) => sMeshes.TryGetValue(id, let mesh) ? mesh : null;

	/// The int32 indices in bytes that are in range (count: how many there may be).
	static void Indices(Span<uint8> bytes, int count, List<int32> into)
	{
		let values = (int32*)bytes.Ptr;
		for (int i < bytes.Length / 4)
		{
			let value = values[i];
			if (value >= 0 && value < count && !into.Contains(value))
				into.Add(value);
		}
	}

	/// An empty mesh: its handle.
	[CSharpExpose]
	public static int32 Create() => Keep(new EditMesh());

	/// A shape (MeshShapes.Kind) of this size and detail: its handle.
	[CSharpExpose]
	public static int32 Shape(int32 kind, Vector3 size, int32 sides, int32 steps, float thickness, bool smooth)
	{
		MeshShapes.Settings settings = .();
		settings.size = size;
		settings.sides = sides;
		settings.steps = steps;
		settings.thickness = thickness;
		settings.smooth = smooth;
		let shape = (MeshShapes.Kind)Math.Clamp(kind, 0, (int32)MeshShapes.Kind.Pipe);
		return Keep(MeshShapes.Create(shape, settings));
	}

	[CSharpExpose]
	public static int32 Clone(int32 id)
	{
		let mesh = Find(id);
		return mesh != null ? Keep(mesh.Clone()) : 0;
	}

	[CSharpExpose]
	public static void Release(int32 id)
	{
		if (sMeshes.GetAndRemove(id) case .Ok(let pair))
			delete pair.value;
	}

	[CSharpExpose]
	public static int32 VertexCount(int32 id) => (int32)(Find(id)?.positions.Count ?? 0);

	[CSharpExpose]
	public static int32 FaceCount(int32 id) => (int32)(Find(id)?.faces.Count ?? 0);

	[CSharpExpose]
	public static Vector3 GetVertex(int32 id, int32 index)
	{
		let mesh = Find(id);
		return mesh != null && index >= 0 && index < mesh.positions.Count ? mesh.positions[index] : .Zero;
	}

	[CSharpExpose]
	public static bool SetVertex(int32 id, int32 index, Vector3 position)
	{
		let mesh = Find(id);
		if (mesh == null || index < 0 || index >= mesh.positions.Count)
			return false;
		mesh.positions[index] = position;
		return true;
	}

	[CSharpExpose]
	public static int32 AddVertex(int32 id, Vector3 position) => Find(id)?.AddVertex(position) ?? -1;

	/// Adds a face through vertices (at least 3, clockwise seen from the front): its index, -1 when it cannot.
	[CSharpExpose]
	public static int32 AddFace(int32 id, Span<uint8> verts)
	{
		let mesh = Find(id);
		if (mesh == null)
			return -1;
		let list = scope List<int32>();
		Indices(verts, mesh.positions.Count, list);
		if (list.Count < 3 || list.Count != verts.Length / 4)
			return -1;
		mesh.AddFace(params list);
		return (int32)mesh.faces.Count - 1;
	}

	/// A face's vertices as int32 bytes into buffer: how many vertices (-1 for no such face).
	[CSharpExpose]
	public static int32 FaceVertices(int32 id, int32 face, Span<uint8> buffer)
	{
		let mesh = Find(id);
		if (mesh == null || face < 0 || face >= mesh.faces.Count)
			return -1;
		let verts = mesh.faces[face].verts;
		let target = (int32*)buffer.Ptr;
		for (int i < Math.Min(verts.Count, buffer.Length / 4))
			target[i] = verts[i];
		return (int32)verts.Count;
	}

	/// A face's normal (x, y, z), centre (x, y, z) and area into values.
	[CSharpExpose]
	public static bool FaceInfo(int32 id, int32 face, Span<float> values)
	{
		let mesh = Find(id);
		if (mesh == null || face < 0 || face >= mesh.faces.Count || values.Length < 7)
			return false;
		let f = mesh.faces[face];
		let normal = mesh.FaceNormal(f);
		let centre = mesh.FaceCenter(f);
		values[0] = normal.x;
		values[1] = normal.y;
		values[2] = normal.z;
		values[3] = centre.x;
		values[4] = centre.y;
		values[5] = centre.z;
		values[6] = mesh.FaceArea(f);
		return true;
	}

	/// Sets a face's colour (every corner), material slot (-1 keeps it) and smoothness (0 flat, 1 smooth, -1 keeps).
	[CSharpExpose]
	public static bool SetFace(int32 id, int32 face, float r, float g, float b, float a, bool setColor, int32 material, int32 smooth)
	{
		let mesh = Find(id);
		if (mesh == null || face < 0 || face >= mesh.faces.Count)
			return false;
		let f = mesh.faces[face];
		if (setColor)
		{
			for (int i < f.colors.Count)
				f.colors[i] = Color(r, g, b, a);
		}
		if (material >= 0)
			f.material = material;
		if (smooth >= 0)
			f.smooth = smooth == 1;
		return true;
	}

	/// An edit of some faces (op: 0 extrude, 1 inset, 2 subdivide, 3 triangulate, 4 poke, 5 solidify, 6 flip,
	/// 7 delete, 8 duplicate); amount: distance, inset or thickness; flag: individual, or smooth for subdivide.
	/// The faces it made, as int32 bytes into added (their count; -1 when there is no such mesh).
	[CSharpExpose]
	public static int32 EditFaces(int32 id, int32 op, Span<uint8> faces, float amount, bool flag, Span<uint8> added)
	{
		let mesh = Find(id);
		if (mesh == null)
			return -1;
		let list = scope List<int32>();
		Indices(faces, mesh.faces.Count, list);
		let made = scope List<int32>();
		Span<int32> chosen = list;
		switch (op)
		{
		case 0: MeshOps.ExtrudeFaces(mesh, chosen, amount, flag, made);
		case 1: MeshOps.InsetFaces(mesh, chosen, amount, flag, made);
		case 2: MeshOps.Subdivide(mesh, chosen, flag, made);
		case 3: MeshOps.Triangulate(mesh, chosen, made);
		case 4: MeshOps.Poke(mesh, chosen, made);
		case 5: MeshOps.Solidify(mesh, chosen, amount, made);
		case 6: MeshOps.FlipFaces(mesh, chosen);
		case 7: MeshOps.DeleteFaces(mesh, chosen);
		case 8: MeshOps.Duplicate(mesh, chosen, made);
		default: return -1;
		}
		let target = (int32*)added.Ptr;
		for (int i < Math.Min(made.Count, added.Length / 4))
			target[i] = made[i];
		return (int32)made.Count;
	}

	/// Mirrors the mesh across an axis (0 x, 1 y, 2 z), welding the middle.
	[CSharpExpose]
	public static void Mirror(int32 id, int32 axis, float weld)
	{
		if (let mesh = Find(id))
			MeshOps.Mirror(mesh, Math.Clamp(axis, 0, 2), weld);
	}

	/// Copies the mesh `count` times, each offset and turned from the last.
	[CSharpExpose]
	public static void Repeat(int32 id, int32 count, Vector3 offset, Quaternion turn, bool weld)
	{
		if (let mesh = Find(id))
			MeshOps.Array(mesh, Math.Clamp(count, 1, 1000), offset, turn, weld);
	}

	/// Moves every vertex so that newOrigin is at 0.
	[CSharpExpose]
	public static void MoveOrigin(int32 id, Vector3 newOrigin)
	{
		if (let mesh = Find(id))
			MeshOps.MoveOrigin(mesh, newOrigin);
	}

	/// Adds another mesh's faces, placed by a position, rotation and scale.
	[CSharpExpose]
	public static bool Append(int32 id, int32 other, Vector3 position, Quaternion rotation, Vector3 scale)
	{
		let mesh = Find(id);
		let from = Find(other);
		if (mesh == null || from == null)
			return false;
		mesh.Append(from, Matrix4.TRS(position, rotation, scale));
		return true;
	}

	/// A boolean of two meshes (op: 0 union, 1 subtract, 2 intersect), b placed in a's space by a position, rotation
	/// and scale: a new mesh's handle, 0 when either is missing.
	[CSharpExpose]
	public static int32 Combine(int32 a, int32 b, Vector3 position, Quaternion rotation, Vector3 scale, int32 op)
	{
		let first = Find(a);
		let second = Find(b);
		if (first == null || second == null)
			return 0;
		let result = MeshCsg.Combine(first, .Identity, second, Matrix4.TRS(position, rotation, scale),
			(MeshCsg.Op)Math.Clamp(op, 0, 2), .Identity);
		return result != null ? Keep(result) : 0;
	}

	[CSharpExpose]
	public static float Volume(int32 id) => Find(id)?.Volume() ?? 0;

	/// The mesh as .tmesh text: its whole length.
	[CSharpExpose]
	public static int32 ToText(int32 id, Span<uint8> buffer)
	{
		let mesh = Find(id);
		if (mesh == null)
			return 0;
		let text = scope String();
		mesh.Write(text);
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// A mesh read from .tmesh text: its handle, 0 when the text is not a mesh.
	[CSharpExpose]
	public static int32 FromText(StringView text)
	{
		let mesh = new EditMesh();
		if (!mesh.Read(text))
		{
			delete mesh;
			return 0;
		}
		return Keep(mesh);
	}

	/// Puts the mesh on an object as its Model Mesh (adding a Mesh Renderer and Model Mesh when it has none).
	[CSharpExpose]
	public static bool ApplyTo(int32 id, uint64 session, uint64 entity)
	{
		let mesh = Find(id);
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (mesh == null || obj == null)
			return false;
		if (!obj.GetComponent<MeshRenderer>().IsValid)
			obj.AddComponent<MeshRenderer>();
		if (!obj.GetComponent<ModelMesh>().IsValid)
			obj.AddComponent<ModelMesh>();
		let model = obj.GetComponent<ModelMesh>();
		if (!model.IsValid)
			return false;
		model.Set(mesh);
		return true;
	}

	/// An object's Model Mesh as a new mesh (for editor scripts, Tallow.Editor's EditorModel): its handle, 0 when it
	/// has none.
	public static int32 ReadFromObject(GameObject obj)
	{
		let model = obj.GetComponent<ModelMesh>();
		return model.IsValid ? Keep(model.Edit.Clone()) : 0;
	}

	/// Puts a mesh on an object (for editor scripts): its Model Mesh, and a Mesh Renderer when it has none.
	public static bool ApplyToObject(int32 id, GameObject obj)
	{
		let mesh = Find(id);
		if (mesh == null)
			return false;
		if (!obj.GetComponent<MeshRenderer>().IsValid)
			obj.AddComponent<MeshRenderer>();
		if (!obj.GetComponent<ModelMesh>().IsValid)
			obj.AddComponent<ModelMesh>();
		let model = obj.GetComponent<ModelMesh>();
		if (!model.IsValid)
			return false;
		model.Set(mesh);
		return true;
	}

	/// An object's Model Mesh as a new mesh: its handle, 0 when it has none.
	[CSharpExpose]
	public static int32 ReadFrom(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null)
			return 0;
		let model = obj.GetComponent<ModelMesh>();
		if (!model.IsValid)
			return 0;
		return Keep(model.Edit.Clone());
	}

	/// The game's code is going: its meshes go with it.
	public static void ReleaseAll()
	{
		for (let mesh in sMeshes.Values)
			delete mesh;
		sMeshes.Clear();
	}
}
