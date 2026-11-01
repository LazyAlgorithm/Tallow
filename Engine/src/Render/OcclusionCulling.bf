using System;
using System.Collections;

namespace Tallow;

/// Whether a renderer hides what is behind it from occlusion culling (docs/occlusion-culling.md).
enum OccluderMode
{
	/// When it is big on screen, still (no Rigidbody, not skinned) and simple enough (Occlusion.MaxAutoTriangles).
	Auto,
	/// Whenever it is on screen and solid.
	Always,
	/// Never: for things with holes the box would not show (fences, leaves, glass).
	Never
}

/// Occlusion culling: before a camera draws, the big solid things in view (walls, buildings, hills) are drawn into a
/// small depth picture on the CPU, and anything whose box is wholly behind them there is not drawn. It is worked out
/// again every frame for each camera that has Occlusion Culling on, so nothing needs baking and moving cameras and
/// doors just work.
class OcclusionBuffer
{
	public const int32 Width = 256;
	public const int32 Height = 144;
	const int32 Tile = 8;
	const int32 TilesX = Width / Tile;
	const int32 TilesY = Height / Tile;

	/// The most occluder triangles drawn into the picture per frame; the biggest occluders on screen go first.
	public static int32 TriangleBudget = 30000;
	/// Auto occluders have at most this many triangles.
	public static int32 MaxAutoTriangles = 2000;
	/// Auto occluders cover at least this share of the screen's height.
	public static float MinOccluderSize = 0.08f;

	// The distance (view depth) of the nearest occluder in each pixel; MaxValue where there is none.
	float[] mDepth = new float[Width * Height] ~ delete _;
	float[] mScratch = new float[Width * Height] ~ delete _;
	// The farthest depth in each 8 x 8 tile, to pass over hidden tiles at once.
	float[] mTileFar = new float[TilesX * TilesY] ~ delete _;
	Matrix4 mViewProj;
	float mNear;

	/// Occluders drawn and their triangles, and boxes found hidden, since Begin.
	public int32 Occluders, OccluderTriangles, Culled;

	/// The depth picture (for the editor's view of it).
	public Span<float> Depth => mDepth;

	/// Clears the picture for a camera.
	public void Begin(CameraData camera)
	{
		mViewProj = camera.projection * camera.view;
		mNear = Math.Max(camera.near, 0.001f);
		for (int i < mDepth.Count)
			mDepth[i] = float.MaxValue;
		Occluders = 0;
		OccluderTriangles = 0;
		Culled = 0;
	}

	Vector4 Clip(Matrix4 m, Vector3 p) => .(m.m[0] * p.x + m.m[4] * p.y + m.m[8] * p.z + m.m[12], m.m[1] * p.x + m.m[5] * p.y + m.m[9] * p.z + m.m[13], m.m[2] * p.x + m.m[6] * p.y + m.m[10] * p.z + m.m[14], m.m[3] * p.x + m.m[7] * p.y + m.m[11] * p.z + m.m[15]);

	/// Draws a mesh's triangles into the picture. Each triangle is put at its farthest corner's depth, so it never
	/// hides more than it really does; triangles reaching behind the camera are left out.
	[Optimize]
	public void AddOccluder(Mesh mesh, Matrix4 world)
	{
		let vertices = mesh.VertexSource != null ? mesh.VertexSource.Vertices : mesh.Vertices;
		let indices = mesh.Indices;
		let m = mViewProj * world;
		Occluders++;
		for (int t = 0; t + 2 < indices.Count; t += 3)
		{
			let a = Clip(m, vertices[(int)indices[t]].position);
			let b = Clip(m, vertices[(int)indices[t + 1]].position);
			let c = Clip(m, vertices[(int)indices[t + 2]].position);
			if (a.w < mNear || b.w < mNear || c.w < mNear)
				continue;
			OccluderTriangles++;
			Triangle(ToPixel(a), ToPixel(b), ToPixel(c), Math.Max(Math.Max(a.w, b.w), c.w));
		}
	}

	static Vector2 ToPixel(Vector4 clip) => .((clip.x / clip.w * 0.5f + 0.5f) * Width, (0.5f - clip.y / clip.w * 0.5f) * Height);

	[Optimize]
	void Triangle(Vector2 a, Vector2 b, Vector2 c, float depth)
	{
		let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
		if (Math.Abs(area) < 0.0001f)
			return;
		let sign = area > 0 ? 1.0f : -1.0f;
		let minX = Math.Max((int32)Math.Floor(Math.Min(Math.Min(a.x, b.x), c.x)), 0);
		let maxX = Math.Min((int32)Math.Ceiling(Math.Max(Math.Max(a.x, b.x), c.x)), Width - 1);
		let minY = Math.Max((int32)Math.Floor(Math.Min(Math.Min(a.y, b.y), c.y)), 0);
		let maxY = Math.Min((int32)Math.Ceiling(Math.Max(Math.Max(a.y, b.y), c.y)), Height - 1);
		for (int32 y = minY; y <= maxY; y++)
		{
			let py = y + 0.5f;
			for (int32 x = minX; x <= maxX; x++)
			{
				let px = x + 0.5f;
				// A pixel is covered when its centre is inside all three edges.
				let e0 = ((b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x)) * sign;
				let e1 = ((c.x - b.x) * (py - b.y) - (c.y - b.y) * (px - b.x)) * sign;
				let e2 = ((a.x - c.x) * (py - c.y) - (a.y - c.y) * (px - c.x)) * sign;
				if (e0 < 0 || e1 < 0 || e2 < 0)
					continue;
				let i = y * Width + x;
				if (depth < mDepth[i])
					mDepth[i] = depth;
			}
		}
	}

	/// After the occluders: each pixel takes the farthest depth round it, so an occluder's edge (which covers only
	/// part of its pixels) hides nothing, and the tiles' farthest depths are worked out.
	[Optimize]
	public void Finish()
	{
		for (int32 y < Height)
		{
			for (int32 x < Width)
			{
				var far = 0.0f;
				for (int32 dy = -1; dy <= 1; dy++)
				{
					let sy = Math.Clamp(y + dy, 0, Height - 1);
					for (int32 dx = -1; dx <= 1; dx++)
					{
						let sx = Math.Clamp(x + dx, 0, Width - 1);
						far = Math.Max(far, mDepth[sy * Width + sx]);
					}
				}
				mScratch[y * Width + x] = far;
			}
		}
		Swap!(mDepth, mScratch);
		for (int32 ty < TilesY)
		{
			for (int32 tx < TilesX)
			{
				var far = 0.0f;
				for (int32 y = ty * Tile; y < (ty + 1) * Tile; y++)
				{
					for (int32 x = tx * Tile; x < (tx + 1) * Tile; x++)
						far = Math.Max(far, mDepth[y * Width + x]);
				}
				mTileFar[ty * TilesX + tx] = far;
			}
		}
	}

	/// False when a world box is wholly behind the occluders. A box reaching behind the camera counts as visible.
	[Optimize]
	public bool IsVisible(Bounds bounds)
	{
		float minX = float.MaxValue, minY = float.MaxValue, maxX = -float.MaxValue, maxY = -float.MaxValue;
		float nearest = float.MaxValue;
		for (int corner < 8)
		{
			let p = Vector3((corner & 1) != 0 ? bounds.max.x : bounds.min.x, (corner & 2) != 0 ? bounds.max.y : bounds.min.y, (corner & 4) != 0 ? bounds.max.z : bounds.min.z);
			let clip = Clip(mViewProj, p);
			if (clip.w < mNear)
				return true;
			let pixel = ToPixel(clip);
			minX = Math.Min(minX, pixel.x);
			maxX = Math.Max(maxX, pixel.x);
			minY = Math.Min(minY, pixel.y);
			maxY = Math.Max(maxY, pixel.y);
			nearest = Math.Min(nearest, clip.w);
		}
		let x0 = Math.Max((int32)Math.Floor(minX), 0);
		let x1 = Math.Min((int32)Math.Floor(maxX), Width - 1);
		let y0 = Math.Max((int32)Math.Floor(minY), 0);
		let y1 = Math.Min((int32)Math.Floor(maxY), Height - 1);
		if (x0 > x1 || y0 > y1)
			return true;
		// Hidden only if every pixel it covers has an occluder in front of its nearest point.
		let limit = nearest * 0.999f;
		for (int32 ty = y0 / Tile; ty <= y1 / Tile; ty++)
		{
			for (int32 tx = x0 / Tile; tx <= x1 / Tile; tx++)
			{
				if (mTileFar[ty * TilesX + tx] < limit)
					continue;
				let ya = Math.Max(y0, ty * Tile);
				let yb = Math.Min(y1, ty * Tile + Tile - 1);
				let xa = Math.Max(x0, tx * Tile);
				let xb = Math.Min(x1, tx * Tile + Tile - 1);
				for (int32 y = ya; y <= yb; y++)
				{
					for (int32 x = xa; x <= xb; x++)
					{
						if (mDepth[y * Width + x] >= limit)
							return true;
					}
				}
			}
		}
		Culled++;
		return false;
	}

	/// Fills the picture from a scene's renderers for a camera: the solid ones in view that can hide things, biggest on
	/// screen first, up to the triangle budget.
	public void Build(Scene scene, CameraData camera, Frustum frustum)
	{
		Begin(camera);
		List<(float size, MeshRenderer renderer, Mesh mesh)> candidates = scope .();
		let tanHalf = Math.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad);
		for (let renderer in scene.Renderers)
		{
			if (renderer.occluder == .Never || !renderer.IsActiveAndEnabled || renderer.shadowOnly || !renderer.GameObject.InActiveWorld)
				continue;
			let parts = renderer.DrawnParts;
			let mesh = (parts != null && parts.Count > 0) ? null : renderer.ActiveMesh;
			// Several-material models are occluders only when asked for, part by part being costly.
			if (mesh == null || mesh.IsDynamic || mesh.Indices.Count == 0)
				continue;
			if (renderer.color.a < 0.99f || (renderer.ActiveMaterial != null && renderer.ActiveMaterial.IsTransparent))
				continue;
			let world = renderer.RenderMatrix;
			let bounds = mesh.Bounds.Transformed(world);
			if (!frustum.Intersects(bounds))
				continue;
			let radius = bounds.Extents.Length;
			let distance = Math.Max((bounds.Center - camera.position).Length, 0.001f);
			let size = camera.orthographic ? radius / Math.Max(camera.orthographicSize, 0.001f) : radius / (distance * tanHalf);
			if (renderer.occluder == .Auto && (size < MinOccluderSize || mesh.Indices.Count / 3 > MaxAutoTriangles || renderer.IsMoving))
				continue;
			candidates.Add((size, renderer, mesh));
		}
		candidates.Sort(scope (a, b) => b.size <=> a.size);
		for (let candidate in candidates)
		{
			if (OccluderTriangles + candidate.mesh.Indices.Count / 3 > TriangleBudget)
				break;
			AddOccluder(candidate.mesh, candidate.renderer.RenderMatrix);
		}
		Finish();
	}
}
