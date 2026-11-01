using System;
using System.Collections;

namespace Tallow;

/// Levels of detail: far away, an object is drawn with fewer triangles, and when it is only a speck it is not drawn at
/// all. The level is picked for each camera from how much of the screen's height the object covers. See docs/lod.md.
[Component]
class LODGroup : Component
{
	public enum Source
	{
		/// The children (or deeper objects) named `..._LOD0`, `..._LOD1`, `..._LOD2`, `..._LOD3` are the levels, as model
		/// files from most tools name them. Renderers without such a name are drawn at every level, except the
		/// group's own when there is no `_LOD0`: that is level 0.
		Children,
		/// Every renderer under the object is simplified when the scene loads to make the lower levels.
		Generated
	}

	public Source source = .Children;
	/// Below this share of the screen's height, level 1 is drawn instead of level 0.
	[Range(0, 1)]
	public float level1Below = 0.4f;
	[Range(0, 1)]
	public float level2Below = 0.15f;
	[Range(0, 1)]
	public float level3Below = 0.05f;
	/// Below this share of the screen's height nothing is drawn (0: always drawn).
	[Range(0, 0.2f)]
	public float cullBelow = 0.005f;
	/// Generated: how many levels there are, counting the full one (2 to 4).
	[Range(2, 4)]
	public int32 generatedLevels = 3;
	/// Generated: the share of its triangles each lower level keeps.
	[Range(0.02f, 1)]
	public float level1Triangles = 0.5f;
	[Range(0.02f, 1)]
	public float level2Triangles = 0.2f;
	[Range(0.02f, 1)]
	public float level3Triangles = 0.08f;

	/// Above 1 keeps detail to farther away (a high quality setting); below 1 drops it sooner. Applies to every group.
	public static float Bias = 1;
	/// Draws every group at this level (-1: as usual). For checking levels in the editor and in tests.
	public static int32 ForceLevel = -1;

	List<MeshRenderer> mRenderers = new .() ~ delete _;
	int32 mLevelCount = 1;
	int mHierarchyHash;
	// The last camera a level was picked for, and the level, so the renderers of one group agree cheaply.
	int64 mPickedFrame = -1;
	Vector3 mPickedFrom;
	int32 mPicked;
	float mPickedHeight;

	/// How many levels it has (1 when it found none).
	public int32 LevelCount => mLevelCount;
	/// The renderers it controls.
	public Span<MeshRenderer> Renderers => mRenderers;

	public override void OnRegister()
	{
		Refresh();
	}

	public override void OnUnregister()
	{
		for (let renderer in mRenderers)
		{
			if (renderer.LodGroup == this)
				renderer.LodGroup = null;
		}
		mRenderers.Clear();
	}

	public override void OnValidate()
	{
		Refresh();
	}

	/// Each frame: finds its renderers again if the objects under it changed.
	public override void OnFrame()
	{
		if (HashHierarchy() != mHierarchyHash)
			Refresh();
	}

	int HashHierarchy()
	{
		var hash = (int)source * 7919 + generatedLevels;
		void Walk(Transform transform)
		{
			hash = hash * 31 + transform.Children.Count;
			hash = hash * 31 + (transform.GameObject.GetComponent<MeshRenderer>() != null ? 1 : 0);
			for (let child in transform.Children)
				Walk(child);
		}
		Walk(Transform);
		return hash;
	}

	/// The level a name gives (`Rock_LOD2` is 2), or -1.
	public static int32 LevelInName(StringView name)
	{
		// Ends in _LOD and one digit, in any case.
		if (name.Length < 5 || name[name.Length - 5] != '_' || !name[name.Length - 1].IsDigit)
			return -1;
		if (!name.Substring(name.Length - 4, 3).Equals("LOD", true))
			return -1;
		return name[name.Length - 1] - '0';
	}

	/// Finds the renderers under it and their levels.
	public void Refresh()
	{
		for (let renderer in mRenderers)
		{
			if (renderer.LodGroup == this)
				renderer.LodGroup = null;
		}
		mRenderers.Clear();
		mLevelCount = source == .Generated ? Math.Clamp(generatedLevels, 2, 4) : 1;
		void Walk(Transform transform, int32 level)
		{
			var level;
			let named = LevelInName(transform.GameObject.Name);
			if (named >= 0 && source == .Children)
				level = named;
			if (let renderer = transform.GameObject.GetComponent<MeshRenderer>())
			{
				// A renderer belongs to the nearest group above it.
				renderer.LodGroup = this;
				renderer.LodLevel = (int8)level;
				mRenderers.Add(renderer);
				if (level >= 0)
					mLevelCount = Math.Max(mLevelCount, level + 1);
			}
			for (let child in transform.Children)
			{
				if (child.GameObject.GetComponent<LODGroup>() == null)
					Walk(child, level);
			}
		}
		Walk(Transform, -1);
		// The group's own renderer, without a level in its name, is level 0 when the levels under it start at 1
		// (as the modeller's Make Levels of Detail leaves them).
		if (source == .Children && mLevelCount > 1)
		{
			let own = GameObject.GetComponent<MeshRenderer>();
			bool hasZero = false;
			for (let renderer in mRenderers)
				hasZero |= renderer.LodLevel == 0;
			if (own != null && own.LodLevel < 0 && !hasZero)
				own.LodLevel = 0;
		}
		mHierarchyHash = HashHierarchy();
		mPickedFrame = -1;
	}

	/// The box round its full-detail renderers, in the world.
	public Bounds WorldBounds
	{
		get
		{
			var bounds = Bounds.Empty;
			for (let renderer in mRenderers)
			{
				if (renderer.LodLevel > 0 || !renderer.IsActiveAndEnabled)
					continue;
				let mesh = renderer.ActiveMesh;
				if (mesh != null)
					bounds.EncapsulateBounds(mesh.Bounds.Transformed(renderer.RenderMatrix));
			}
			if (!bounds.IsValid)
				bounds = .(Transform.Position, Transform.Position);
			return bounds;
		}
	}

	/// The share of the screen's height it covers from a camera (its bounding sphere's diameter over the view's
	/// height at its distance).
	public float ScreenHeight(CameraData camera)
	{
		let bounds = WorldBounds;
		let radius = bounds.Extents.Length;
		if (camera.orthographic)
			return radius / Math.Max(camera.orthographicSize, 0.0001f);
		let distance = (bounds.Center - camera.position).Length;
		if (distance <= radius)
			return 1;
		let halfHeight = distance * Math.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad);
		return radius / Math.Max(halfHeight, 0.0001f);
	}

	/// The level a screen height gives: 0 full detail, -1 not drawn.
	public int32 LevelForHeight(float height)
	{
		let h = height * Math.Max(Bias, 0.01f);
		if (cullBelow > 0 && h < cullBelow)
			return -1;
		int32 level = 0;
		if (h < level1Below)
			level = 1;
		if (h < level2Below)
			level = 2;
		if (h < level3Below)
			level = 3;
		return Math.Min(level, mLevelCount - 1);
	}

	/// The level drawn for a camera: 0 full detail, -1 not drawn.
	public int32 LevelFor(CameraData camera)
	{
		if (ForceLevel >= 0)
			return Math.Min(ForceLevel, mLevelCount - 1);
		if (mPickedFrame == Time.FrameCount && mPickedFrom == camera.position)
			return mPicked;
		mPickedHeight = ScreenHeight(camera);
		mPicked = LevelForHeight(mPickedHeight);
		mPickedFrame = Time.FrameCount;
		mPickedFrom = camera.position;
		return mPicked;
	}

	/// The screen height worked out last (for the editor).
	public float LastScreenHeight => mPickedHeight;

	/// Generated: the share of triangles a level keeps.
	public float TrianglesAt(int32 level)
	{
		switch (level)
		{
		case 0: return 1;
		case 1: return level1Triangles;
		case 2: return level2Triangles;
		default: return level3Triangles;
		}
	}

	/// What a renderer of this group draws for a level: its own mesh, a simplified one, or null (not at this level).
	public Mesh MeshAt(MeshRenderer renderer, Mesh mesh, int32 level)
	{
		if (level < 0 || mesh == null)
			return null;
		if (source == .Children)
			return renderer.LodLevel < 0 || renderer.LodLevel == level ? mesh : null;
		if (level == 0 || mesh.IsDynamic)
			return mesh;
		return MeshSimplifier.Simplified(mesh, TrianglesAt(level));
	}
}

/// Makes meshes with fewer triangles, for levels of detail. Vertices that lie close together (and face much the
/// same way, so hard edges stay hard) are merged; the size of "close" is chosen to reach the wanted triangle count.
static class MeshSimplifier
{
	struct Key : IHashable
	{
		public Mesh mesh;
		public int32 share;
		public int GetHashCode() => (int)Internal.UnsafeCastToPtr(mesh) ^ (share * 7919);
		public static bool operator ==(Key a, Key b) => a.mesh == b.mesh && a.share == b.share;
	}

	static Dictionary<Key, Mesh> sCache = new .() ~ DeleteDictionaryAndValues!(_);

	/// A simplified copy of a mesh keeping about a share of its triangles, made once and kept.
	public static Mesh Simplified(Mesh mesh, float share)
	{
		Key key;
		key.mesh = mesh;
		key.share = (int32)Math.Round(Math.Clamp(share, 0.01f, 1) * 1000);
		if (sCache.TryGetValue(key, let cached))
			return cached;
		let simplified = Simplify(mesh, share);
		if (Gfx.Initialized)
			simplified.Upload();
		sCache[key] = simplified;
		return simplified;
	}

	/// Forgets simplified meshes of a mesh (it changed, or is going).
	public static void Forget(Mesh mesh)
	{
		List<Key> gone = scope .();
		for (let pair in sCache)
		{
			if (pair.key.mesh == mesh)
				gone.Add(pair.key);
		}
		for (let key in gone)
		{
			delete sCache[key];
			sCache.Remove(key);
		}
	}

	static int Direction(Vector3 normal)
	{
		// Which of 26 directions the normal is nearest, so faces turned apart are never merged.
		int Axis(float v) => v > 0.38f ? 2 : (v < -0.38f ? 0 : 1);
		return Axis(normal.x) * 9 + Axis(normal.y) * 3 + Axis(normal.z);
	}

	/// A new mesh with about share of the triangles (never more than it has).
	public static Mesh Simplify(Mesh source, float share)
	{
		let vertices = source.VertexSource != null ? source.VertexSource.Vertices : source.Vertices;
		let indices = source.Indices;
		let triangles = indices.Count / 3;
		let wanted = Math.Max((int)(triangles * Math.Clamp(share, 0.01f, 1)), 4);
		var bounds = Bounds.Empty;
		for (let index in indices)
			bounds.Encapsulate(vertices[(int)index].position);
		let size = bounds.IsValid ? Math.Max(Math.Max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y), bounds.max.z - bounds.min.z) : 1;
		let result = new Mesh();
		result.Name.Set(source.Name);
		result.Name.Append(" (simplified)");
		if (triangles <= wanted || size <= 0)
		{
			for (let index in indices)
				result.Vertices.Add(vertices[(int)index]);
			for (int i < result.Vertices.Count)
				result.Indices.Add((uint32)i);
			result.RecalculateBounds();
			return result;
		}
		// Finer grids keep more triangles: search for the coarsest grid that keeps at least the wanted count.
		float low = size / 512, high = size / 2;
		List<uint32> best = scope .();
		List<MeshVertex> bestVertices = scope .();
		List<uint32> attempt = scope .();
		List<MeshVertex> attemptVertices = scope .();
		for (int step < 12)
		{
			let cell = Math.Sqrt(low * high);
			Cluster(vertices, indices, bounds.min, cell, attempt, attemptVertices);
			if (attempt.Count / 3 >= wanted)
			{
				best.Set(attempt);
				bestVertices.Set(attemptVertices);
				low = cell;
			}
			else
				high = cell;
		}
		if (best.IsEmpty)
		{
			Cluster(vertices, indices, bounds.min, low, best, bestVertices);
		}
		result.Vertices.Set(bestVertices);
		result.Indices.Set(best);
		result.RecalculateBounds();
		return result;
	}

	static void Cluster(List<MeshVertex> vertices, List<uint32> indices, Vector3 origin, float cell, List<uint32> outIndices, List<MeshVertex> outVertices)
	{
		outIndices.Clear();
		outVertices.Clear();
		Dictionary<int64, int32> clusters = scope .();
		List<int32> remap = scope .();
		remap.Resize(vertices.Count, -1);
		List<Vector3> sums = scope .();
		List<Vector3> normals = scope .();
		List<int32> counts = scope .();
		let inverse = 1 / cell;
		for (let index in indices)
		{
			if (remap[(int)index] >= 0)
				continue;
			let vertex = vertices[(int)index];
			let p = (vertex.position - origin) * inverse;
			let key = ((int64)Math.Floor(p.x) & 0xFFFFF) | (((int64)Math.Floor(p.y) & 0xFFFFF) << 20) | (((int64)Math.Floor(p.z) & 0xFFFFF) << 40) | ((int64)Direction(vertex.normal) << 58);
			if (!clusters.TryGetValue(key, var cluster))
			{
				cluster = (int32)outVertices.Count;
				clusters[key] = cluster;
				outVertices.Add(vertex);
				sums.Add(.Zero);
				normals.Add(.Zero);
				counts.Add(0);
			}
			remap[(int)index] = cluster;
			sums[cluster] += vertex.position;
			normals[cluster] += vertex.normal;
			counts[cluster]++;
		}
		for (int i < outVertices.Count)
		{
			var vertex = outVertices[i];
			vertex.position = sums[i] / counts[i];
			if (normals[i].LengthSquared > 0.000001f)
				vertex.normal = normals[i].Normalized;
			outVertices[i] = vertex;
		}
		HashSet<int64> seen = scope .();
		for (int t = 0; t + 2 < indices.Count; t += 3)
		{
			let a = remap[(int)indices[t]];
			let b = remap[(int)indices[t + 1]];
			let c = remap[(int)indices[t + 2]];
			if (a == b || b == c || a == c)
				continue;
			// The same triangle twice (in any rotation) is drawn once.
			var (x, y, z) = (a, b, c);
			if (b < a && b < c)
				(x, y, z) = (b, c, a);
			else if (c < a && c < b)
				(x, y, z) = (c, a, b);
			if (!seen.Add((int64)x | ((int64)y << 21) | ((int64)z << 42)))
				continue;
			outIndices.Add((uint32)a);
			outIndices.Add((uint32)b);
			outIndices.Add((uint32)c);
		}
	}
}
