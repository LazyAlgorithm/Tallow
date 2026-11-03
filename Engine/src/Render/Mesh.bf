using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Triangle mesh with CPU-side data and a GPU copy. Front faces wind clockwise (left-handed).
class Mesh
{
	/// The mesh's name (its file, for one loaded from a model).
	public String Name = new .() ~ delete _;
	/// The vertices. Upload (or UploadDynamic) sends them to the graphics card.
	public List<MeshVertex> Vertices = new .() ~ delete _;
	/// Three indices into Vertices for each triangle.
	public List<uint32> Indices = new .() ~ delete _;
	/// The box round the vertices (see RecalculateBounds).
	public Bounds Bounds = .(.Zero, .Zero);
	/// Whether the vertices' uv2 lay the surface out for a lightmap (from the model file, or made by LightmapUV).
	public bool LightmapUVs;
	/// How far uv2 goes for one unit of the mesh's own size (for how many lightmap texels it needs).
	public float LightmapUVScale = 1;
	/// The lightmap coordinates came with the model file (kept as they are, whatever an object's scale).
	public bool LightmapUVsFromModel;
	/// Copies laid out for objects that stretch this mesh unevenly (LightmapUV.MeshesFor), freed with it.
	public List<LightmapUV.Copies> LightmapCopies ~ DeleteContainerAndItems!(_);

	bgfx.VertexBufferHandle mVertexBuffer = .() { idx = uint16.MaxValue };
	bgfx.IndexBufferHandle mIndexBuffer = .() { idx = uint16.MaxValue };
	/// Each edge of the triangles once, as lines (made when a wireframe view first draws the mesh).
	bgfx.IndexBufferHandle mEdgeBuffer = .() { idx = uint16.MaxValue };
	int32 mEdgeCount;
	int32 mUploadedIndexCount;
	int32 mUploadedVertexCount;
	bgfx.DynamicVertexBufferHandle mDynamicBuffer = .() { idx = uint16.MaxValue };

	/// Another mesh whose vertices this one draws, with indices of its own: one part of a model that has several
	/// materials (a skinned character's skin, cloth and armour), sharing the vertices the model updates each frame.
	/// Give it its Indices and call UploadIndices; keep its Bounds in step with the source's.
	public Mesh VertexSource;

	/// Whether a compute shader may write its vertices (UploadDynamic with computeWritable).
	public bool IsComputeWritable => mComputeWritable;
	bool mComputeWritable;

	/// True for meshes whose vertices are rewritten every frame (skinned characters).
	public bool IsDynamic => VertexSource != null ? VertexSource.IsDynamic : mDynamicBuffer.Valid;
	/// The graphics card's copy of the vertices, for a mesh uploaded with UploadDynamic.
	public bgfx.DynamicVertexBufferHandle DynamicBuffer => VertexSource != null ? VertexSource.DynamicBuffer : mDynamicBuffer;

	/// For a part (VertexSource): sends its own indices to the GPU.
	public void UploadIndices()
	{
		ReleaseEdges();
		ReleasePaletteSections();
		if (mIndexBuffer.Valid && Gfx.Initialized)
			bgfx.destroy_index_buffer(mIndexBuffer);
		mIndexBuffer.idx = uint16.MaxValue;
		mUploadedIndexCount = 0;
		if (VertexSource != null)
			Bounds = VertexSource.Bounds;
		if (Indices.Count == 0 || !Gfx.Initialized)
			return;
		mIndexBuffer = bgfx.create_index_buffer(bgfx.copy(Indices.Ptr, (uint32)(Indices.Count * 4)), 0x1000);
		mUploadedIndexCount = (int32)Indices.Count;
	}

	/// Creates GPU buffers that UpdateDynamic can refill. The vertex count must stay the same afterwards.
	/// computeWritable lets a compute shader write the vertices too (GPU skinning).
	public void UploadDynamic(bool computeWritable = false)
	{
		ReleaseGpu();
		ReleasePaletteSections();
		RecalculateBounds();
		if (Vertices.Count == 0 || Indices.Count == 0 || !Gfx.Initialized)
			return;
		mDynamicBuffer = bgfx.create_dynamic_vertex_buffer((uint32)Vertices.Count, &Gfx.MeshLayout, computeWritable ? (uint16)bgfx.BufferFlags.ComputeReadWrite : 0);
		mComputeWritable = computeWritable;
		bgfx.update_dynamic_vertex_buffer(mDynamicBuffer, 0, bgfx.copy(Vertices.Ptr, (uint32)(Vertices.Count * sizeof(MeshVertex))));
		mIndexBuffer = bgfx.create_index_buffer(bgfx.copy(Indices.Ptr, (uint32)(Indices.Count * 4)), 0x1000);
		mUploadedIndexCount = (int32)Indices.Count;
		mUploadedVertexCount = (int32)Vertices.Count;
	}

	/// Sends the current vertex list to the GPU again.
	public void UpdateDynamic()
	{
		if (mDynamicBuffer.Valid && Vertices.Count == mUploadedVertexCount)
			bgfx.update_dynamic_vertex_buffer(mDynamicBuffer, 0, bgfx.copy(Vertices.Ptr, (uint32)(Vertices.Count * sizeof(MeshVertex))));
	}

	public ~this()
	{
		ReleaseGpu();
		ReleasePaletteSections();
	}

	// ---- palette sections ----

	/// Kinds of face in a palette mesh (Material.palette), by their flags: one-sided, double sided, see-through,
	/// and see-through double sided. A draw has one culling and blending, so each kind is drawn on its own.
	public const int PaletteSectionCount = 4;
	/// Palette face flags (the alpha byte of the vertex colour).
	public const uint8 PaletteUnlit = 1, PaletteTransparent = 2, PaletteDoubleSided = 4, PaletteCutout = 8, PaletteHologram = 16,
		PaletteAnimatedGlow = 32, PaletteDissolve = 64;

	Mesh[PaletteSectionCount] mPaletteSections;
	bool mPaletteSectionsMade;

	/// The section of one kind (bit 0 double sided, bit 1 see-through): a mesh drawing this one's vertices with just
	/// those faces, or null when it has none. All null when every face is opaque and one-sided, and for a mesh whose
	/// triangles are not kept on the CPU; it is then drawn whole. Made the first time it is asked for after an upload.
	public Mesh PaletteSection(int section)
	{
		if (!mPaletteSectionsMade)
			MakePaletteSections();
		return section >= 0 && section < PaletteSectionCount ? mPaletteSections[section] : null;
	}

	/// True when the mesh has faces flagged see-through or double sided (see PaletteSection).
	public bool HasPaletteSections
	{
		get
		{
			if (!mPaletteSectionsMade)
				MakePaletteSections();
			for (let section in mPaletteSections)
			{
				if (section != null)
					return true;
			}
			return false;
		}
	}

	void MakePaletteSections()
	{
		ReleasePaletteSections();
		mPaletteSectionsMade = true;
		let source = VertexSource ?? this;
		if (Indices.Count < 3 || source.Vertices.Count == 0 || !HasGpuData)
			return;
		List<uint32>[PaletteSectionCount] lists = default;
		defer
		{
			for (let list in lists)
				delete list;
		}
		bool split = false;
		for (int i = 0; i + 2 < Indices.Count; i += 3)
		{
			let first = Indices[i];
			if (first >= (uint32)source.Vertices.Count)
				return;
			let color = source.Vertices[(int)first].color;
			// Plain white is a face never painted: no flags (as include/palette.sh reads it).
			let flags = color == uint32.MaxValue ? 0 : (uint8)(color >> 24);
			let section = ((flags & PaletteDoubleSided) != 0 ? 1 : 0) | ((flags & PaletteTransparent) != 0 ? 2 : 0);
			split |= section != 0;
			if (lists[section] == null)
				lists[section] = new .();
			lists[section].Add(Indices[i]);
			lists[section].Add(Indices[i + 1]);
			lists[section].Add(Indices[i + 2]);
		}
		if (!split)
			return;
		for (int section < PaletteSectionCount)
		{
			if (lists[section] == null)
				continue;
			let part = new Mesh();
			part.Name.Set(Name);
			part.VertexSource = source;
			part.Indices.AddRange(lists[section]);
			part.UploadIndices();
			part.Bounds = Bounds;
			mPaletteSections[section] = part;
		}
	}

	void ReleasePaletteSections()
	{
		for (var section in ref mPaletteSections)
			DeleteAndNullify!(section);
		mPaletteSectionsMade = false;
	}

	/// Whether the mesh is on the graphics card and can be drawn.
	public bool HasGpuData => (VertexSource != null ? (VertexSource.mVertexBuffer.Valid || VertexSource.mDynamicBuffer.Valid) : (mVertexBuffer.Valid || mDynamicBuffer.Valid)) && mIndexBuffer.Valid;
	/// The graphics card's copy of the vertices.
	public bgfx.VertexBufferHandle VertexBuffer => VertexSource != null ? VertexSource.VertexBuffer : mVertexBuffer;
	/// The graphics card's copy of the indices.
	public bgfx.IndexBufferHandle IndexBuffer => mIndexBuffer;
	/// How many indices were uploaded.
	public int32 IndexCount => mUploadedIndexCount;
	/// How many vertices were uploaded.
	public int32 VertexCount => VertexSource != null ? VertexSource.VertexCount : mUploadedVertexCount;

	/// Removes every vertex and index (the graphics card's copy stays until the next upload).
	public void Clear()
	{
		Vertices.Clear();
		Indices.Clear();
	}

	/// Adds a vertex and returns its index.
	public uint32 AddVertex(Vector3 position, Vector3 normal, Color color, Vector2 uv = default)
	{
		Vertices.Add(.(position, normal, color.ToABGR(), uv));
		return (uint32)Vertices.Count - 1;
	}

	/// Adds a triangle of three vertex indices, clockwise seen from its front.
	public void AddTriangle(uint32 a, uint32 b, uint32 c)
	{
		Indices.Add(a);
		Indices.Add(b);
		Indices.Add(c);
	}

	/// Adds a quad from four corners given clockwise when seen from the front.
	public void AddQuad(Vector3 a, Vector3 b, Vector3 c, Vector3 d, Color color)
	{
		let normal = Vector3.Cross(b - a, c - a).Normalized;
		let i = AddVertex(a, normal, color, .(0, 0));
		AddVertex(b, normal, color, .(1, 0));
		AddVertex(c, normal, color, .(1, 1));
		AddVertex(d, normal, color, .(0, 1));
		AddTriangle(i, i + 1, i + 2);
		AddTriangle(i, i + 2, i + 3);
	}

	/// Works Bounds out again from the vertices.
	public void RecalculateBounds()
	{
		if (Vertices.Count == 0)
		{
			Bounds = .(.Zero, .Zero);
			return;
		}
		var bounds = Tallow.Bounds.Empty;
		for (let v in Vertices)
			bounds.Encapsulate(v.position);
		Bounds = bounds;
	}

	/// Smooth normals from face normals weighted by area.
	public void RecalculateNormals()
	{
		for (var v in ref Vertices)
			v.normal = .Zero;
		for (int i = 0; i + 2 < Indices.Count; i += 3)
		{
			let a = (int)Indices[i], b = (int)Indices[i + 1], c = (int)Indices[i + 2];
			let n = Vector3.Cross(Vertices[b].position - Vertices[a].position, Vertices[c].position - Vertices[a].position);
			Vertices[a].normal = Vertices[a].normal + n;
			Vertices[b].normal = Vertices[b].normal + n;
			Vertices[c].normal = Vertices[c].normal + n;
		}
		for (var v in ref Vertices)
			v.normal = v.normal.Normalized;
	}

	/// Sends the current vertex and index lists to the GPU, replacing any previous copy.
	public void Upload(bool keepCpuData = true)
	{
		ReleaseGpu();
		ReleasePaletteSections();
		RecalculateBounds();
		if (Vertices.Count == 0 || Indices.Count == 0 || !Gfx.Initialized)
			return;
		mVertexBuffer = bgfx.create_vertex_buffer(bgfx.copy(Vertices.Ptr, (uint32)(Vertices.Count * sizeof(MeshVertex))), &Gfx.MeshLayout, 0);
		mIndexBuffer = bgfx.create_index_buffer(bgfx.copy(Indices.Ptr, (uint32)(Indices.Count * 4)), 0x1000);
		mUploadedIndexCount = (int32)Indices.Count;
		mUploadedVertexCount = (int32)Vertices.Count;
		if (!keepCpuData)
		{
			Vertices.Clear();
			Vertices.Capacity = 0;
			Indices.Clear();
			Indices.Capacity = 0;
		}
	}

	/// Frees the graphics card's copy.
	public void ReleaseGpu()
	{
		if (!Gfx.Initialized)
			return;
		if (mVertexBuffer.Valid)
			bgfx.destroy_vertex_buffer(mVertexBuffer);
		if (mIndexBuffer.Valid)
			bgfx.destroy_index_buffer(mIndexBuffer);
		if (mDynamicBuffer.Valid)
			bgfx.destroy_dynamic_vertex_buffer(mDynamicBuffer);
		mDynamicBuffer.idx = uint16.MaxValue;
		mComputeWritable = false;
		mVertexBuffer.idx = uint16.MaxValue;
		mIndexBuffer.idx = uint16.MaxValue;
		mUploadedIndexCount = 0;
		mUploadedVertexCount = 0;
		ReleaseEdges();
	}

	void ReleaseEdges()
	{
		if (mEdgeBuffer.Valid && Gfx.Initialized)
			bgfx.destroy_index_buffer(mEdgeBuffer);
		mEdgeBuffer.idx = uint16.MaxValue;
		mEdgeCount = 0;
	}

	/// The mesh's edges as lines, for a wireframe view: each edge of its triangles once. False when it has no
	/// triangles on the CPU to find them from.
	public bool EdgeLines(out bgfx.IndexBufferHandle buffer, out int32 count)
	{
		if (!mEdgeBuffer.Valid && Gfx.Initialized && Indices.Count >= 3)
		{
			let seen = scope HashSet<uint64>();
			let lines = scope List<uint32>(Indices.Count * 2);
			for (int i = 0; i + 2 < Indices.Count; i += 3)
			{
				for (int k < 3)
				{
					let a = Indices[i + k];
					let b = Indices[i + (k + 1) % 3];
					if (seen.Add(((uint64)Math.Min(a, b) << 32) | Math.Max(a, b)))
					{
						lines.Add(a);
						lines.Add(b);
					}
				}
			}
			mEdgeBuffer = bgfx.create_index_buffer(bgfx.copy(lines.Ptr, (uint32)(lines.Count * 4)), 0x1000);
			mEdgeCount = (int32)lines.Count;
		}
		buffer = mEdgeBuffer;
		count = mEdgeCount;
		return mEdgeBuffer.Valid;
	}

	/// Ray test against the CPU triangles in mesh space. Returns the distance or a negative value.
	public float Raycast(Ray ray)
	{
		float best = -1.0f;
		for (int i = 0; i + 2 < Indices.Count; i += 3)
		{
			let a = Vertices[(int)Indices[i]].position;
			let b = Vertices[(int)Indices[i + 1]].position;
			let c = Vertices[(int)Indices[i + 2]].position;
			let e1 = b - a;
			let e2 = c - a;
			let p = Vector3.Cross(ray.direction, e2);
			let det = Vector3.Dot(e1, p);
			if (Mathf.Abs(det) < 1.0e-9f)
				continue;
			let inv = 1.0f / det;
			let s = ray.origin - a;
			let u = Vector3.Dot(s, p) * inv;
			if (u < 0 || u > 1)
				continue;
			let q = Vector3.Cross(s, e1);
			let v = Vector3.Dot(ray.direction, q) * inv;
			if (v < 0 || u + v > 1)
				continue;
			let t = Vector3.Dot(e2, q) * inv;
			if (t > 1.0e-5f && (best < 0 || t < best))
				best = t;
		}
		return best;
	}
}
