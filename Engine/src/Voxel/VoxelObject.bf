using System;
using System.Collections;

namespace Tallow;

[Reflect(.All)]
enum VoxelShape : int32
{
	Sphere,
	Box,
	Cylinder,
	/// The shape of a model (the Mesh field): a statue, a crate, a pillar, a wall.
	Mesh
}

/// A destructible object built from a small marching-cubes grid. Carve() removes material in
/// real time; pieces that are cut loose break off and fall as their own physics objects.
///
/// Almost any object can be one. Set Shape to Mesh and name a model: the model is filled in as solid material (it
/// must be closed, like a real object, for the engine to tell its inside from its outside) and keeps its own colours
/// and texture coordinates on the outside. The outside is drawn with the Mesh Renderer's material; the surfaces that
/// carving exposes are drawn with Interior Material, or, with none, with an inside made from the outside's material
/// (the same texture carried through the solid, tinted by Interior Color and rougher).
///
/// What you get is the model re-made from a grid of Resolution cells: parts thinner than a cell are lost and sharp
/// edges are softened, so raise Resolution for fine models and keep thin sheets as ordinary meshes.
///
/// Collision: with a MeshCollider and no Rigidbody the object has exact (static) triangle
/// collision. Jolt cannot simulate moving triangle meshes, so pieces that break off collide
/// with a convex hull wrapped around their surface.
[Component]
class VoxelObject : Component
{
	public VoxelShape shape = .Sphere;
	/// Shape Mesh: the model to make destructible. It keeps its own size; Size is not used.
	public String mesh = new .() ~ delete _;
	/// Grid cells along each axis (8 to 48). Higher is smoother and slower to re-mesh.
	public int32 resolution = 24;
	/// Edge length of the grid in local units.
	public float size = 4.0f;
	public Color color = .FromBytes(150, 146, 140);
	/// Color of surfaces exposed by carving. With an inside made from the outside's material, its tint.
	public Color interiorColor = .FromBytes(96, 82, 70);
	/// The material (.tmat) of surfaces exposed by carving: the wood inside a painted crate, the concrete inside a
	/// plastered wall. Empty: an inside made from the Mesh Renderer's material, or plain Interior Color without one.
	public String interiorMaterial = new .() ~ delete _;
	/// How many times the inside's texture repeats in each unit of the object's own space.
	public float interiorTiling = 1;
	/// Detach pieces that are no longer connected to the largest part (play mode only).
	public bool breakOffPieces = true;
	/// Loose pieces with fewer solid samples than this simply vanish.
	public int32 minimumPieceSize = 6;
	/// Anchored objects stay fixed in place (cliffs, walls) and only cut-off pieces fall.
	/// Otherwise the whole object becomes a physics body the first time it is carved.
	public bool anchored = false;

	/// What a model's surface looks like near each sample of the grid (its colour and texture coordinates), read
	/// from the model once and shared with the pieces that break off.
	class Surface
	{
		public uint32[] colors ~ delete _;
		public Vector2[] uvs ~ delete _;
		public int32 users = 1;
	}

	int8[] mDensity ~ delete _;
	bool[] mCarved ~ delete _;
	Mesh mMesh ~ delete _;
	Surface mSurface ~ ReleaseSurface(_);
	/// Shape Mesh: the grid's edge length and where its middle is, in the object's own space.
	float mMeshSize;
	Vector3 mCenter;
	/// The outside and the inside as two parts of the mesh, each with its material, when either has one.
	List<MeshRenderer.Part> mParts = new .() ~ { for (let part in _) delete part.mesh; DeleteContainerAndItems!(_); };
	Material mDerivedInterior ~ delete _;
	Material mDerivedFrom;
	int32 mDerivedRevision = -1;
	int32 mSamples;
	int32 mBuiltHash;
	bool mCustom;

	public bool IsEmpty => mMesh == null || mMesh.Indices.Count == 0;
	int Index(int x, int y, int z) => x + y * mSamples + z * mSamples * mSamples;
	/// The grid's edge length: Size, or for a model whatever holds it.
	public float GridSize => (shape == .Mesh && mMeshSize > 0) ? mMeshSize : size;
	float CellSize => GridSize / (mSamples - 1);

	static void ReleaseSurface(Surface surface)
	{
		if (surface != null && --surface.users <= 0)
			delete surface;
	}

	int32 ShapeHash
	{
		get
		{
			var hash = (int32)shape ^ resolution * 31 ^ (int32)(size * 1000) * 7;
			if (shape == .Mesh)
			{
				for (let c in mesh.RawChars)
					hash = hash * 16777619 ^ (int32)c;
			}
			return hash;
		}
	}

	int32 LookHash
	{
		get
		{
			var hash = ShapeHash ^ (int32)color.ToABGR() * 3 ^ (int32)interiorColor.ToABGR() * 5 ^ (int32)(interiorTiling * 1000) * 11;
			for (let c in interiorMaterial.RawChars)
				hash = hash * 16777619 ^ (int32)c;
			return hash;
		}
	}

	public override void OnRegister()
	{
		// A piece that is breaking off is given its grid by SpawnPiece.
		if (!mCustom && !sMakingPiece)
			Fill();
		Rebuild();
	}

	public override void OnUnregister()
	{
		let renderer = GetComponent<MeshRenderer>();
		if (renderer != null && renderer.RuntimeMesh == mMesh)
			renderer.RuntimeMesh = null;
		if (renderer != null && renderer.RuntimeParts == mParts)
			renderer.RuntimeParts = null;
	}

	public override void OnValidate()
	{
		if (LookHash == mBuiltHash)
			return;
		if (!mCustom && (mDensity == null || ShapeHash != mShapeHash))
			Fill();
		Rebuild();
	}

	int32 mShapeHash;
	bool mAttachPending;
	static bool sMakingPiece;
	/// Ids of the pieces that broke off this object, so a reset can clean them up.
	List<uint32> mPieces = new .() ~ delete _;

	/// Restores the untouched shape and removes every piece that broke off (and pieces of those pieces).
	public void ResetShape()
	{
		DestroyPieces();
		Fill();
		Rebuild();
	}

	void DestroyPieces()
	{
		for (let id in mPieces)
		{
			let piece = Scene.FindById(id);
			if (piece == null || piece.IsDestroyed)
				continue;
			piece.GetComponent<VoxelObject>()?.DestroyPieces();
			Scene.Destroy(piece);
		}
		mPieces.Clear();
	}

	public override void OnFrame()
	{
		if (!mAttachPending)
			return;
		mAttachPending = false;
		var renderer = GetComponent<MeshRenderer>();
		if (renderer == null)
		{
			renderer = GameObject.AddComponent<MeshRenderer>();
			renderer.roughness = 0.9f;
		}
		renderer.RuntimeMesh = mMesh;
		renderer.RuntimeParts = mParts.Count > 0 ? mParts : null;
		GetComponent<Collider>()?.Refresh();
	}

	/// Resets the grid to the untouched shape.
	public void Fill()
	{
		mSamples = Math.Max(8, Math.Min(resolution, 48)) + 1;
		delete mDensity;
		delete mCarved;
		let count = mSamples * mSamples * mSamples;
		mDensity = new int8[count];
		mCarved = new bool[count];
		mShapeHash = ShapeHash;
		ReleaseSurface(mSurface);
		mSurface = null;
		mMeshSize = 0;
		mCenter = .Zero;
		if (shape == .Mesh)
		{
			if (FillFromMesh())
				return;
			// No model, or one that could not be read: an empty grid, and nothing drawn.
			for (int i < count)
				mDensity[i] = -127;
			return;
		}
		let half = (mSamples - 1) * 0.5f;
		// Leave a one-cell empty margin so the surface is closed on every side.
		let radius = half - 1.5f;
		for (int z < mSamples)
		{
			for (int y < mSamples)
			{
				for (int x < mSamples)
				{
					let p = Vector3(x - half, y - half, z - half);
					float d;
					switch (shape)
					{
					case .Box: d = radius - Math.Max(Mathf.Abs(p.x), Math.Max(Mathf.Abs(p.y), Mathf.Abs(p.z)));
					case .Cylinder: d = Math.Min(radius - Math.Sqrt(p.x * p.x + p.z * p.z), radius - Mathf.Abs(p.y));
					default: d = radius - p.Length;
					}
					mDensity[Index(x, y, z)] = (int8)Mathf.Clamp(d * 32.0f, -127, 127);
				}
			}
		}
	}

	/// The point of a triangle nearest to a point, as the weights of its three corners.
	static Vector3 Nearest(Vector3 p, Vector3 a, Vector3 b, Vector3 c)
	{
		let ab = b - a, ac = c - a, ap = p - a;
		let d1 = Vector3.Dot(ab, ap), d2 = Vector3.Dot(ac, ap);
		if (d1 <= 0 && d2 <= 0)
			return .(1, 0, 0);
		let bp = p - b;
		let d3 = Vector3.Dot(ab, bp), d4 = Vector3.Dot(ac, bp);
		if (d3 >= 0 && d4 <= d3)
			return .(0, 1, 0);
		let vc = d1 * d4 - d3 * d2;
		if (vc <= 0 && d1 >= 0 && d3 <= 0)
		{
			let v = d1 / Math.Max(d1 - d3, 1.0e-12f);
			return .(1 - v, v, 0);
		}
		let cp = p - c;
		let d5 = Vector3.Dot(ab, cp), d6 = Vector3.Dot(ac, cp);
		if (d6 >= 0 && d5 <= d6)
			return .(0, 0, 1);
		let vb = d5 * d2 - d1 * d6;
		if (vb <= 0 && d2 >= 0 && d6 <= 0)
		{
			let w = d2 / Math.Max(d2 - d6, 1.0e-12f);
			return .(1 - w, 0, w);
		}
		let va = d3 * d6 - d5 * d4;
		if (va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0)
		{
			let w = (d4 - d3) / Math.Max((d4 - d3) + (d5 - d6), 1.0e-12f);
			return .(0, 1 - w, w);
		}
		let denominator = 1.0f / Math.Max(va + vb + vc, 1.0e-12f);
		let v = vb * denominator, w = vc * denominator;
		return .(1 - v - w, v, w);
	}

	/// Fills the grid from the model: solid inside it, with the distance to its surface near the surface (which is
	/// what makes the re-made surface follow the model and not the grid), and the model's colour and texture
	/// coordinates noted at each sample near it. False when there is no model to use.
	bool FillFromMesh()
	{
		if (mesh.IsEmpty)
			return false;
		let model = Assets.GetMesh(mesh);
		if (model == null || model.Vertices.Count < 3 || model.Indices.Count < 3)
			return false;
		var bounds = Bounds.Empty;
		for (let v in model.Vertices)
			bounds.Encapsulate(v.position);
		let extents = bounds.Extents;
		let longest = Math.Max(Math.Max(extents.x, extents.y), extents.z) * 2;
		if (longest <= 0)
			return false;
		let cells = mSamples - 1;
		// A cell and a half of air round the model, so that its surface is closed on every side.
		mMeshSize = longest / (cells - 3) * cells;
		mCenter = bounds.Center;
		let cell = mMeshSize / cells;
		let origin = mCenter - Vector3(mMeshSize * 0.5f);
		let count = mSamples * mSamples * mSamples;
		float[] distance = new float[count];
		defer delete distance;
		int32[] nearest = new int32[count];
		defer delete nearest;
		for (int i < count)
		{
			distance[i] = float.MaxValue;
			nearest[i] = -1;
		}
		// Where each row of samples along X passes through the model's surface: inside is after an odd number.
		List<float>[] rows = new List<float>[mSamples * mSamples];
		defer
		{
			for (let row in rows)
				delete row;
			delete rows;
		}
		for (int t < model.Indices.Count / 3)
		{
			Triangle(model, t, let a, let b, let c);
			CrossRows(a, b, c, origin, cell, rows);
			NearestSamples((int32)t, a, b, c, origin, cell, distance, nearest);
		}
		mSurface = new Surface();
		mSurface.colors = new uint32[count];
		mSurface.uvs = new Vector2[count];
		for (int z < mSamples)
		{
			for (int y < mSamples)
			{
				let row = rows[y + z * mSamples];
				if (row != null)
					row.Sort();
				int crossed = 0;
				for (int x < mSamples)
				{
					let px = origin.x + x * cell;
					while (row != null && crossed < row.Count && row[crossed] < px)
						crossed++;
					let inside = (crossed & 1) == 1;
					let index = Index(x, y, z);
					let away = distance[index] < float.MaxValue ? Math.Sqrt(distance[index]) / cell : 4.0f;
					mDensity[index] = (int8)Mathf.Clamp((inside ? away : -away) * 32.0f, -127, 127);
					// Exactly on the surface counts as outside, like everywhere else.
					if (inside && mDensity[index] <= 0)
						mDensity[index] = 1;
					mSurface.colors[index] = 0xFFFFFFFF;
					if (nearest[index] >= 0)
						TakeSurface(model, nearest[index], origin + Vector3(x, y, z) * cell, out mSurface.colors[index], out mSurface.uvs[index]);
				}
			}
		}
		return true;
	}

	static void Triangle(Mesh model, int t, out Vector3 a, out Vector3 b, out Vector3 c)
	{
		a = model.Vertices[(int)model.Indices[t * 3]].position;
		b = model.Vertices[(int)model.Indices[t * 3 + 1]].position;
		c = model.Vertices[(int)model.Indices[t * 3 + 2]].position;
	}

	/// Notes where each row of samples along X that the triangle crosses passes through it.
	void CrossRows(Vector3 a, Vector3 b, Vector3 c, Vector3 origin, float cell, List<float>[] rows)
	{
		let low = (Vector3.Min(a, Vector3.Min(b, c)) - origin) / cell;
		let high = (Vector3.Max(a, Vector3.Max(b, c)) - origin) / cell;
		for (int z = Math.Max((int)Math.Floor(low.z), 0); z <= Math.Min((int)Math.Ceiling(high.z), mSamples - 1); z++)
		{
			for (int y = Math.Max((int)Math.Floor(low.y), 0); y <= Math.Min((int)Math.Ceiling(high.y), mSamples - 1); y++)
			{
				// A hair off the grid, so that a row never runs exactly along an edge shared by two triangles.
				let py = origin.y + y * cell + cell * 0.00037f, pz = origin.z + z * cell + cell * 0.00053f;
				let e0 = (b.y - a.y) * (pz - a.z) - (b.z - a.z) * (py - a.y);
				let e1 = (c.y - b.y) * (pz - b.z) - (c.z - b.z) * (py - b.y);
				let e2 = (a.y - c.y) * (pz - c.z) - (a.z - c.z) * (py - c.y);
				if (!((e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0)))
					continue;
				let area = e0 + e1 + e2;
				if (Math.Abs(area) < 1.0e-12f)
					continue;
				let x = (a.x * e1 + b.x * e2 + c.x * e0) / area;
				let rowIndex = y + z * mSamples;
				if (rows[rowIndex] == null)
					rows[rowIndex] = new .();
				rows[rowIndex].Add(x);
			}
		}
	}

	/// For every sample within two cells of the triangle: the triangle, if it is the nearest so far, and how far
	/// away it is (squared).
	void NearestSamples(int32 t, Vector3 a, Vector3 b, Vector3 c, Vector3 origin, float cell, float[] distance, int32[] nearest)
	{
		const int reach = 2;
		let low = (Vector3.Min(a, Vector3.Min(b, c)) - origin) / cell;
		let high = (Vector3.Max(a, Vector3.Max(b, c)) - origin) / cell;
		for (int z = Math.Max((int)Math.Floor(low.z) - reach, 0); z <= Math.Min((int)Math.Ceiling(high.z) + reach, mSamples - 1); z++)
		{
			for (int y = Math.Max((int)Math.Floor(low.y) - reach, 0); y <= Math.Min((int)Math.Ceiling(high.y) + reach, mSamples - 1); y++)
			{
				for (int x = Math.Max((int)Math.Floor(low.x) - reach, 0); x <= Math.Min((int)Math.Ceiling(high.x) + reach, mSamples - 1); x++)
				{
					let p = origin + Vector3(x, y, z) * cell;
					let weights = Nearest(p, a, b, c);
					let away = (a * weights.x + b * weights.y + c * weights.z - p).LengthSquared;
					let index = Index(x, y, z);
					if (away < distance[index])
					{
						distance[index] = away;
						nearest[index] = t;
					}
				}
			}
		}
	}

	/// The model's colour and texture coordinates at the point of triangle t nearest a point.
	static void TakeSurface(Mesh model, int t, Vector3 point, out uint32 color, out Vector2 uv)
	{
		let va = model.Vertices[(int)model.Indices[t * 3]], vb = model.Vertices[(int)model.Indices[t * 3 + 1]], vc = model.Vertices[(int)model.Indices[t * 3 + 2]];
		let weights = Nearest(point, va.position, vb.position, vc.position);
		uv = va.uv * weights.x + vb.uv * weights.y + vc.uv * weights.z;
		color = 0;
		for (int channel < 4)
		{
			let shift = (uint32)channel * 8;
			let value = ((va.color >> shift) & 0xFF) * weights.x + ((vb.color >> shift) & 0xFF) * weights.y + ((vc.color >> shift) & 0xFF) * weights.z;
			color |= (uint32)Math.Clamp(Math.Round(value), 0, 255) << shift;
		}
	}

	/// Texture coordinates for a point with no model to take them from: the object's own space, seen along
	/// whichever axis the surface faces most.
	static Vector2 Project(Vector3 local, Vector3 normal, float tiling)
	{
		let ax = Math.Abs(normal.x), ay = Math.Abs(normal.y), az = Math.Abs(normal.z);
		if (ay >= ax && ay >= az)
			return .(local.x * tiling, local.z * tiling);
		if (ax >= az)
			return .(local.z * tiling, local.y * tiling);
		return .(local.x * tiling, local.y * tiling);
	}

	/// The material for carved surfaces: Interior Material, else one made from the outside's (the same texture,
	/// tinted by Interior Color and rougher), else none (plain Interior Color).
	Material InteriorMaterialFor(MeshRenderer renderer)
	{
		if (!interiorMaterial.IsEmpty)
		{
			let loaded = Material.Load(interiorMaterial);
			if (loaded != null)
				return loaded;
		}
		let outside = renderer != null ? renderer.ActiveMaterial : null;
		if (outside == null)
			return null;
		if (mDerivedInterior == null || mDerivedFrom != outside || mDerivedRevision != outside.Revision)
		{
			delete mDerivedInterior;
			mDerivedInterior = outside.Clone();
			mDerivedFrom = outside;
			mDerivedRevision = outside.Revision;
		}
		// Brighter than the tint alone would leave it: Interior Color is a dark colour meant to be seen on its own.
		let tint = interiorColor;
		mDerivedInterior.color = .(Math.Min(outside.color.r * tint.r * 1.8f, 1), Math.Min(outside.color.g * tint.g * 1.8f, 1), Math.Min(outside.color.b * tint.b * 1.8f, 1), outside.color.a);
		mDerivedInterior.roughness = Math.Min(outside.roughness + 0.25f, 1);
		mDerivedInterior.metallic = outside.metallic * 0.5f;
		return mDerivedInterior;
	}

	Vector3 Gradient(int x, int y, int z)
	{
		let x0 = Math.Max(x - 1, 0), x1 = Math.Min(x + 1, mSamples - 1);
		let y0 = Math.Max(y - 1, 0), y1 = Math.Min(y + 1, mSamples - 1);
		let z0 = Math.Max(z - 1, 0), z1 = Math.Min(z + 1, mSamples - 1);
		return .(
			(float)mDensity[Index(x0, y, z)] - mDensity[Index(x1, y, z)],
			(float)mDensity[Index(x, y0, z)] - mDensity[Index(x, y1, z)],
			(float)mDensity[Index(x, y, z0)] - mDensity[Index(x, y, z1)]);
	}

	/// Re-meshes the grid and refreshes the renderer and collider.
	public void Rebuild()
	{
		if (mDensity == null)
			return;
		mBuiltHash = LookHash;
		if (mMesh == null)
			mMesh = new Mesh();
		mMesh.Clear();
		let renderer = GetComponent<MeshRenderer>();
		// With a material inside, the inside's own colour comes from that material and its vertices stay white.
		let insideMaterial = InteriorMaterialFor(renderer);
		List<uint32> outsideIndices = scope .();
		List<uint32> insideIndices = scope .();
		March(insideMaterial != null, outsideIndices, insideIndices);
		mMesh.Upload();
		MakeParts(insideMaterial, outsideIndices, insideIndices);

		// The renderer may not exist yet while a scene or prefab is still loading this object's
		// components, so attaching (or creating) it is finished in OnFrame.
		if (renderer != null)
		{
			renderer.RuntimeMesh = mMesh;
			renderer.RuntimeParts = mParts.Count > 0 ? mParts : null;
		}
		else
			mAttachPending = true;
		RefreshCollision();
	}

	/// Marching cubes over the grid into mMesh. Triangles touching carved samples go in `inside`, the rest in
	/// `outside`, so that the two can be drawn with different materials.
	void March(bool insideHasMaterial, List<uint32> outside, List<uint32> inside)
	{
		let cells = mSamples - 1;
		let cell = CellSize;
		let offset = Vector3(GridSize * 0.5f) - mCenter;
		uint32 outer = mSurface != null ? (uint32)0xFFFFFFFF : color.ToABGR();
		uint32 inner = insideHasMaterial ? (uint32)0xFFFFFFFF : interiorColor.ToABGR();
		uint32[12] edgeVertex = default;
		bool[12] edgeCarved = default;
		for (int z < cells)
		{
			for (int y < cells)
			{
				for (int x < cells)
				{
					int config = 0;
					for (int c < 8)
					{
						if (mDensity[Index(x + MarchingTables.Corners[c * 3], y + MarchingTables.Corners[c * 3 + 1], z + MarchingTables.Corners[c * 3 + 2])] <= 0)
							config |= 1 << c;
					}
					let edgeMask = MarchingTables.Edges[config];
					if (edgeMask == 0)
						continue;
					for (int e < 12)
					{
						if ((edgeMask & (1 << e)) == 0)
							continue;
						let a = e & 7;
						let b = MarchingTables.EdgeEnd[e];
						let ax = x + MarchingTables.Corners[a * 3], ay = y + MarchingTables.Corners[a * 3 + 1], az = z + MarchingTables.Corners[a * 3 + 2];
						let bx = x + MarchingTables.Corners[b * 3], by = y + MarchingTables.Corners[b * 3 + 1], bz = z + MarchingTables.Corners[b * 3 + 2];
						let da = (float)mDensity[Index(ax, ay, az)];
						let db = (float)mDensity[Index(bx, by, bz)];
						let t = Mathf.Abs(da - db) > 0.001f ? Mathf.Clamp01(da / (da - db)) : 0.5f;
						let local = Vector3(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t) * cell - offset;
						let normal = Vector3.Lerp(Gradient(ax, ay, az), Gradient(bx, by, bz), t).Normalized;
						let carved = mCarved[Index(ax, ay, az)] || mCarved[Index(bx, by, bz)];
						edgeVertex[e] = (uint32)mMesh.Vertices.Count;
						edgeCarved[e] = carved;
						uint32 vertexColor = carved ? inner : outer;
						var uv = Project(local, normal, carved ? interiorTiling : 1);
						if (!carved && mSurface != null)
						{
							// The model's own colour and texture coordinates, from the end of the edge inside it.
							let solid = da > 0 ? Index(ax, ay, az) : Index(bx, by, bz);
							vertexColor = mSurface.colors[solid];
							uv = mSurface.uvs[solid];
						}
						mMesh.Vertices.Add(.(local, normal, vertexColor, uv));
					}
					// The table winds the other way from Tallow's front faces.
					let row = config * 16;
					for (int i = 0; MarchingTables.Triangles[row + i] != -1; i += 3)
					{
						let e0 = MarchingTables.Triangles[row + i], e1 = MarchingTables.Triangles[row + i + 2], e2 = MarchingTables.Triangles[row + i + 1];
						let list = (edgeCarved[e0] || edgeCarved[e1] || edgeCarved[e2]) ? inside : outside;
						for (let edge in int[3](e0, e1, e2))
						{
							mMesh.Indices.Add(edgeVertex[edge]);
							list.Add(edgeVertex[edge]);
						}
					}
				}
			}
		}
	}

	/// The outside and the inside as parts with a material each, when the inside has one and there is any inside.
	void MakeParts(Material insideMaterial, List<uint32> outside, List<uint32> inside)
	{
		for (let part in mParts)
			delete part.mesh;
		ClearAndDeleteItems!(mParts);
		if (insideMaterial == null || inside.Count == 0)
			return;
		for (int side < 2)
		{
			let indices = side == 0 ? outside : inside;
			if (indices.Count == 0)
				continue;
			let part = new MeshRenderer.Part();
			part.mesh = new Mesh();
			part.mesh.VertexSource = mMesh;
			part.mesh.Indices.AddRange(indices);
			part.mesh.UploadIndices();
			// The outside has no material of its own here: it takes the Mesh Renderer's.
			part.material = side == 0 ? null : insideMaterial;
			mParts.Add(part);
		}
	}

	/// Keeps collision in step with the surface: a Box Collider is fitted to it, and the body or collider remade.
	void RefreshCollision()
	{
		let boxCollider = GetComponent<BoxCollider>();
		if (boxCollider != null && mMesh.Vertices.Count > 0)
		{
			boxCollider.center = mMesh.Bounds.Center;
			boxCollider.size = Vector3.Max(mMesh.Bounds.Extents * 2.0f, .(0.05f));
		}
		let body = GetComponent<Rigidbody>();
		if (body != null)
			body.RebuildBody();
		else
			GetComponent<Collider>()?.Refresh();
	}

	/// Removes material inside a sphere given in world space. Returns true if anything changed.
	///
	/// In multiplayer the carve happens on every machine. Called on a client it is sent to the server first and
	/// this returns false; the carve follows when the server passes it back.
	public bool Carve(Vector3 worldPoint, float radius)
	{
		if (mDensity == null)
			return false;
		if (NetworkSync.RouteCarve(this, worldPoint, radius))
			return false;
		return CarveLocal(Transform.InverseTransformPoint(worldPoint), radius);
	}

	/// Carve with the centre of the sphere given in the object's own space (the radius is still in world units).
	/// This is what a carve becomes on its way round a network session: every machine works from the same
	/// numbers, wherever exactly it has the object, so the result is the same on all of them. It is applied here
	/// and now, and not sent anywhere.
	public bool CarveLocal(Vector3 objectPoint, float radius)
	{
		if (mDensity == null)
			return false;
		let cell = CellSize;
		let scale = Transform.LocalToWorld.Right.Length;
		let localRadius = radius / Math.Max(scale, 1.0e-4f);
		let local = objectPoint - mCenter + Vector3(GridSize * 0.5f);
		let reach = localRadius + cell;
		let x0 = Math.Max(0, (int)Math.Floor((local.x - reach) / cell)), x1 = Math.Min(mSamples - 1, (int)Math.Ceiling((local.x + reach) / cell));
		let y0 = Math.Max(0, (int)Math.Floor((local.y - reach) / cell)), y1 = Math.Min(mSamples - 1, (int)Math.Ceiling((local.y + reach) / cell));
		let z0 = Math.Max(0, (int)Math.Floor((local.z - reach) / cell)), z1 = Math.Min(mSamples - 1, (int)Math.Ceiling((local.z + reach) / cell));
		bool changed = false;
		for (int z = z0; z <= z1; z++)
		{
			for (int y = y0; y <= y1; y++)
			{
				for (int x = x0; x <= x1; x++)
				{
					let distance = (Vector3(x, y, z) * cell - local).Length;
					// Signed distance to the carving sphere in cells, like the fill functions.
					let cut = (distance - localRadius) / cell * 32.0f;
					let index = Index(x, y, z);
					if (cut < mDensity[index])
					{
						if (mDensity[index] > -100)
							mCarved[index] = true;
						mDensity[index] = (int8)Mathf.Clamp(cut, -127, 127);
						changed = true;
					}
				}
			}
		}
		if (!changed)
			return false;
		if (breakOffPieces && Scene.IsPlaying)
			SplitLoosePieces();
		if (!anchored && Scene.IsPlaying)
			MakeDynamic();
		Rebuild();
		if (IsEmpty && Scene.IsPlaying)
			Scene.Destroy(GameObject);
		return true;
	}

	/// Swaps static triangle collision for a convex body so what is left of the object can fall and roll.
	void MakeDynamic()
	{
		if (GetComponent<Rigidbody>() != null)
			return;
		let staticCollider = GetComponent<MeshCollider>();
		if (staticCollider != null)
			GameObject.RemoveComponent(staticCollider);
		if (GetComponent<Collider>() == null)
			GameObject.AddComponent<ConvexCollider>();
		int32 solid = 0;
		for (let d in mDensity)
		{
			if (d > 0)
				solid++;
		}
		let body = GameObject.AddComponent<Rigidbody>();
		body.mass = Math.Max(0.5f, solid * 0.02f);
		// In multiplayer every machine carves at the same moment, so they all start sharing its motion from here.
		NetworkSync.EnsureShared(GameObject);
	}

	/// Flood-fills the solid samples; everything not connected to the largest group becomes a new falling object.
	void SplitLoosePieces()
	{
		let count = mSamples * mSamples * mSamples;
		int32[] labels = new int32[count];
		defer delete labels;
		List<int32> sizes = scope .();
		sizes.Add(0);
		List<int32> stack = scope .();
		let stepY = mSamples;
		let stepZ = mSamples * mSamples;
		for (int32 start = 0; start < (int32)count; start++)
		{
			if (mDensity[start] <= 0 || labels[start] != 0)
				continue;
			let label = (int32)sizes.Count;
			int32 members = 0;
			labels[start] = label;
			stack.Add(start);
			while (stack.Count > 0)
			{
				let index = stack.PopBack();
				members++;
				let x = index % mSamples;
				let y = (index / mSamples) % mSamples;
				let z = index / stepZ;
				void Visit(int32 neighbor)
				{
					if (mDensity[neighbor] > 0 && labels[neighbor] == 0)
					{
						labels[neighbor] = label;
						stack.Add(neighbor);
					}
				}
				if (x > 0)
					Visit(index - 1);
				if (x < mSamples - 1)
					Visit(index + 1);
				if (y > 0)
					Visit(index - (int32)stepY);
				if (y < mSamples - 1)
					Visit(index + (int32)stepY);
				if (z > 0)
					Visit(index - (int32)stepZ);
				if (z < mSamples - 1)
					Visit(index + (int32)stepZ);
			}
			sizes.Add(members);
		}
		if (sizes.Count <= 2)
			return;
		int32 largest = 1;
		for (int32 i = 2; i < (int32)sizes.Count; i++)
		{
			if (sizes[i] > sizes[largest])
				largest = i;
		}
		for (int32 label = 1; label < (int32)sizes.Count; label++)
		{
			if (label == largest)
				continue;
			if (sizes[label] >= minimumPieceSize)
				SpawnPiece(labels, label, sizes[label]);
		}
		for (int i < count)
		{
			if (labels[i] != 0 && labels[i] != largest)
				mDensity[i] = -127;
		}
	}

	void SpawnPiece(int32[] labels, int32 label, int32 solid)
	{
		let piece = Scene.CreateGameObject("Fragment");
		piece.Transient = true;
		mPieces.Add(piece.Id);
		piece.Transform.SetPositionAndRotation(Transform.Position, Transform.Rotation);
		piece.Transform.LocalScale = Transform.LocalScale;
		let source = GetComponent<MeshRenderer>();
		// Renderer first, so the piece's mesh is attached (and its collider can be built) immediately.
		let renderer = piece.AddComponent<MeshRenderer>();
		if (source != null)
		{
			renderer.roughness = source.roughness;
			renderer.metallic = source.metallic;
			renderer.color = source.color;
			renderer.flatShading = source.flatShading;
			renderer.texture.Set(source.texture);
			// The piece is made of the same stuff: same material outside, and so the same inside.
			renderer.material.Set(source.material);
		}
		sMakingPiece = true;
		let voxels = piece.AddComponent<VoxelObject>();
		sMakingPiece = false;
		voxels.shape = shape;
		voxels.mesh.Set(mesh);
		voxels.resolution = resolution;
		voxels.size = size;
		voxels.color = color;
		voxels.interiorColor = interiorColor;
		voxels.interiorMaterial.Set(interiorMaterial);
		voxels.interiorTiling = interiorTiling;
		voxels.minimumPieceSize = minimumPieceSize;
		voxels.anchored = false;
		voxels.mCustom = true;
		// A piece is the same grid with everything else taken out: the same place in the model, the same surface.
		voxels.mMeshSize = mMeshSize;
		voxels.mCenter = mCenter;
		voxels.mShapeHash = voxels.ShapeHash;
		if (mSurface != null)
		{
			ReleaseSurface(voxels.mSurface);
			voxels.mSurface = mSurface;
			mSurface.users++;
		}
		let count = mSamples * mSamples * mSamples;
		voxels.mSamples = mSamples;
		voxels.mDensity = new int8[count];
		voxels.mCarved = new bool[count];
		for (int i < count)
		{
			// Neighbours of the piece keep their (negative) density so its surface stays where it was.
			voxels.mDensity[i] = labels[i] == label ? mDensity[i] : (mDensity[i] > 0 ? (int8) - 127 : mDensity[i]);
			voxels.mCarved[i] = mCarved[i];
		}
		voxels.Rebuild();
		piece.AddComponent<ConvexCollider>();
		let body = piece.AddComponent<Rigidbody>();
		body.mass = Math.Max(0.2f, solid * 0.02f);
		// In multiplayer every machine breaks this piece off at the same moment; from here its motion is shared and
		// it can be carved in turn.
		NetworkSync.ShareFragment(piece);
	}
}
