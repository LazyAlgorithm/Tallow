using System;
using System.Collections;

namespace Tallow;

/// Which way a line's or trail's ribbon faces.
enum LineAlignment : int32
{
	/// Turned round its own length to face the viewer, so it always looks its full width.
	View,
	/// Facing along its object's forward (Z) axis: lies flat in the object's XY plane, like a strip painted on it.
	TransformZ
}

/// How a texture is laid along a line or trail.
enum LineTextureMode : int32
{
	/// Once along its whole length.
	Stretch,
	/// Again every metre (with the renderer's tiling), so dashes and arrows keep their size as it grows.
	Tile
}

/// One point of a ribbon, in the world.
struct RibbonPoint
{
	public Vector3 position;
	public float width;
	public Color color;
}

/// How a line or trail looks, from its component's fields.
struct RibbonLook
{
	public StringView material;
	public StringView texture;
	public bool unlit;
	public bool castShadows;
	public float glow;
}

/// The mesh of a LineRenderer or TrailRenderer: a strip two vertices wide along a list of points, drawn by a
/// MeshRenderer on a hidden child object made for it (not saved with the scene), so it never takes the place of a
/// mesh the object already draws. Its GPU buffers keep their size while the point count fits (spare vertices sit on
/// the last point, drawing nothing), so a trail that grows and shrinks is not reallocated every frame.
class Ribbon
{
	Mesh mMesh ~ delete _;
	GameObject mHolder;
	MeshRenderer mRenderer;
	int mCapacity;

	/// The renderer drawing the strip, or null before the first frame.
	public MeshRenderer Renderer => (mHolder != null && !mHolder.IsDestroyed) ? mRenderer : null;

	/// Makes the hidden child that draws the strip, if it is not there, and gives it the look.
	public void Attach(Component owner, RibbonLook look)
	{
		if (mHolder == null || mHolder.IsDestroyed)
		{
			mHolder = owner.Scene.CreateGameObject(scope $"{owner.GameObject.Name} (drawn)");
			mHolder.Transient = true;
			mHolder.Transform.SetParent(owner.Transform, false);
			mRenderer = mHolder.AddComponent<MeshRenderer>();
			mRenderer.mesh.Clear();
			mRenderer.backFaceCulling = false;
			mRenderer.flatShading = false;
			mRenderer.inReflectionProbes = false;
			if (mMesh == null)
				mMesh = new Mesh();
			mMesh.Name.Set(owner.GameObject.Name);
			mRenderer.RuntimeMesh = mMesh;
			mCapacity = 0;
		}
		if (!mHolder.ActiveSelf)
			mHolder.SetActive(true);
		let renderer = mRenderer;
		if (!renderer.Enabled)
			renderer.Enabled = true;
		if (renderer.material != look.material)
			renderer.material.Set(look.material);
		if (renderer.texture != look.texture)
			renderer.texture.Set(look.texture);
		renderer.unlit = look.unlit;
		renderer.castShadows = look.castShadows;
		renderer.emissiveFromColor = look.glow > 0;
		renderer.emissiveIntensity = Math.Max(look.glow, 0);
	}

	/// Stops drawing the strip (it comes back with the next Attach).
	public void Detach()
	{
		if (mHolder != null && !mHolder.IsDestroyed && mRenderer.Enabled)
			mRenderer.Enabled = false;
	}

	/// Removes the hidden child, when the line or trail itself is removed.
	public void Remove()
	{
		if (mHolder != null && !mHolder.IsDestroyed)
			mHolder.Scene.Destroy(mHolder);
		mHolder = null;
		mRenderer = null;
	}

	/// Rebuilds the strip along points (in the world), each its width across, in the object's space.
	public void Build(Transform owner, List<RibbonPoint> points, LineAlignment alignment, LineTextureMode textureMode, bool loop)
	{
		if (mMesh == null || Renderer == null)
			return;
		let transform = mHolder.Transform;
		var count = points.Count;
		let drawn = count >= 2 ? (loop && count >= 3 ? count + 1 : count) : 0;
		var capacity = Math.Max(mCapacity, 2);
		while (capacity < drawn)
			capacity *= 2;
		let toLocal = transform.WorldToLocal;
		let viewer = Camera.ViewerPosition;
		let facing = owner.Forward;
		var transparent = false;

		// Distance along the strip, for the texture.
		float total = 0;
		for (int i = 1; i < drawn; i++)
			total += (points[i % count].position - points[i - 1].position).Length;

		mMesh.Vertices.Clear();
		float along = 0;
		var side = Vector3(1, 0, 0);
		for (int i < drawn)
		{
			let point = points[i % count];
			if (i > 0)
				along += (point.position - points[i - 1].position).Length;
			// The direction along the strip here: between the points either side (round the join of a loop).
			Vector3 previous, next;
			if (loop && drawn > count)
			{
				previous = points[(i - 1 + count) % count].position;
				next = points[(i + 1) % count].position;
			}
			else
			{
				previous = points[Math.Max(i - 1, 0)].position;
				next = points[Math.Min(i + 1, count - 1)].position;
			}
			var tangent = next - previous;
			if (tangent.LengthSquared < 1.0e-12f)
				tangent = Vector3(0, 0, 1);
			tangent = tangent.Normalized;
			let normal = alignment == .View ? (viewer - point.position) : facing;
			var across = Vector3.Cross(tangent, normal);
			// Keeps the last good side where the strip points straight at the viewer.
			if (across.LengthSquared > 1.0e-10f)
				side = across.Normalized;
			let half = side * (point.width * 0.5f);
			let u = textureMode == .Tile ? along : (total > 0 ? along / total : 0);
			let localNormal = toLocal.TransformDirection(normal.LengthSquared > 1.0e-12f ? normal.Normalized : Vector3.Up);
			mMesh.AddVertex(toLocal.TransformPoint(point.position - half), localNormal, point.color, .(u, 0));
			mMesh.AddVertex(toLocal.TransformPoint(point.position + half), localNormal, point.color, .(u, 1));
			if (point.color.a < 0.999f)
				transparent = true;
		}
		// Spare vertices on the last point (or the object, with nothing drawn) make triangles with no area.
		let rest = drawn > 0 ? mMesh.Vertices.Back : MeshVertex(.Zero, .Up, 0, .Zero);
		while (mMesh.Vertices.Count < capacity * 2)
			mMesh.Vertices.Add(rest);

		mRenderer.vertexAlpha = transparent;
		if (capacity != mCapacity || !mMesh.HasGpuData)
		{
			mCapacity = capacity;
			mMesh.Indices.Clear();
			for (int i < capacity - 1)
			{
				let a = (uint32)(i * 2);
				mMesh.AddTriangle(a, a + 2, a + 1);
				mMesh.AddTriangle(a + 1, a + 2, a + 3);
			}
			mMesh.UploadDynamic();
		}
		else
		{
			mMesh.RecalculateBounds();
			mMesh.UpdateDynamic();
		}
	}
}
