using System;
using System.Collections;

namespace Tallow;

/// Which way a line's or trail's ribbon faces.
[Reflect(.All)]
enum LineAlignment : int32
{
	/// Turned round its own length to face the viewer, so it always looks its full width.
	View,
	/// Facing along its object's forward (Z) axis: lies flat in the object's XY plane, like a strip painted on it.
	TransformZ
}

/// How a texture is laid along a line or trail.
[Reflect(.All)]
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
	// The hidden child, by its id: the ribbon may outlive it (children go before their parent's components).
	Scene mScene;
	uint32 mHolderId;
	int mCapacity;

	/// The hidden child drawing the strip, or null.
	GameObject Holder
	{
		get
		{
			if (mScene == null || mHolderId == 0)
				return null;
			let holder = mScene.FindById(mHolderId);
			return (holder != null && !holder.IsDestroyed) ? holder : null;
		}
	}

	/// The renderer drawing the strip, or not valid before the first frame.
	public MeshRenderer Renderer
	{
		get
		{
			let holder = Holder;
			return (holder != null && holder.HasComponent<MeshRenderer>()) ? holder.GetComponent<MeshRenderer>() : default;
		}
	}

	/// Makes the hidden child that draws the strip, if it is not there, and gives it the look.
	public void Attach(GameObject owner, RibbonLook look)
	{
		var holder = Holder;
		if (holder == null)
		{
			holder = owner.Scene.CreateGameObject(scope $"{owner.Name} (drawn)");
			holder.Transient = true;
			holder.Transform.SetParent(owner.Transform, false);
			mScene = owner.Scene;
			mHolderId = holder.Id;
			let made = holder.AddComponent<MeshRenderer>();
			made.mesh.Clear();
			made.backFaceCulling = false;
			made.flatShading = false;
			made.inReflectionProbes = false;
			if (mMesh == null)
				mMesh = new Mesh();
			mMesh.Name.Set(owner.Name);
			made.RuntimeMesh = mMesh;
			mCapacity = 0;
		}
		if (!holder.ActiveSelf)
			holder.SetActive(true);
		let renderer = holder.GetComponent<MeshRenderer>();
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
		let renderer = Renderer;
		if (renderer && renderer.Enabled)
			renderer.Enabled = false;
	}

	/// Removes the hidden child, when the line or trail itself is removed.
	public void Remove()
	{
		if (let holder = Holder)
		{
			// Not while the scene is emptied: everything is going anyway.
			if (!holder.Scene.[Friend]mClearing)
			{
				// Its mesh is this ribbon's, which is about to go.
				holder.GetComponent<MeshRenderer>().RuntimeMesh = null;
				holder.Scene.Destroy(holder);
			}
		}
		mScene = null;
		mHolderId = 0;
	}

	List<RibbonPoint> mPath = new .() ~ delete _;
	List<float> mAlong = new .() ~ delete _;
	List<RibbonPoint> mRun = new .() ~ delete _;
	List<float> mRunAlong = new .() ~ delete _;

	/// Rebuilds the strip along points (in the world), each its width across, in the hidden object's space: solid, or
	/// in dashes Style.dash long with Style.gap between.
	public void Build(Transform owner, List<RibbonPoint> points, RibbonStyle style)
	{
		let renderer = Renderer;
		if (mMesh == null || !renderer)
			return;
		let transform = renderer.Transform;
		let toLocal = transform.WorldToLocal;
		let viewer = Camera.ViewerPosition;
		let facing = owner.Forward;
		var transparent = style.textured;

		// The path, closed round for a loop, and how far along it each point is.
		mPath.Clear();
		mAlong.Clear();
		if (points.Count >= 2)
		{
			mPath.AddRange(points);
			if (style.loop && points.Count >= 3)
				mPath.Add(points[0]);
		}
		float total = 0;
		for (int i < mPath.Count)
		{
			if (i > 0)
				total += (mPath[i].position - mPath[i - 1].position).Length;
			mAlong.Add(total);
			if (mPath[i].color.a < 0.999f)
				transparent = true;
		}
		let closed = style.loop && points.Count >= 3;

		mMesh.Vertices.Clear();
		if (mPath.Count >= 2 && total > 0)
		{
			let dashed = style.dash > 0 && style.gap > 0;
			if (!dashed)
				AddRun(0, total, total, closed, toLocal, viewer, facing, style);
			else
			{
				let period = style.dash + style.gap;
				// At most this many dashes, so a tiny dash on a long line cannot make millions of quads.
				let most = 20000;
				var made = 0;
				for (var from = 0.0f; from < total && made < most; from += period)
				{
					AddRun(from, Math.Min(from + style.dash, total), total, false, toLocal, viewer, facing, style);
					made++;
				}
			}
		}

		// Spare quads sit on one point, drawing nothing; the buffers only grow.
		let quads = mMesh.Vertices.Count / 4;
		var capacity = Math.Max(mCapacity, 4);
		while (capacity < quads)
			capacity *= 2;
		let rest = mMesh.Vertices.Count > 0 ? mMesh.Vertices.Back : MeshVertex(.Zero, .Up, 0, .Zero);
		while (mMesh.Vertices.Count < capacity * 4)
			mMesh.Vertices.Add(rest);

		renderer.vertexAlpha = transparent;
		if (capacity != mCapacity || !mMesh.HasGpuData)
		{
			mCapacity = capacity;
			mMesh.Indices.Clear();
			for (int i < capacity)
			{
				let a = (uint32)(i * 4);
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

	/// The path's point `distance` along it, its width and colour blended between the points either side.
	RibbonPoint PointAt(float distance)
	{
		var i = 1;
		while (i < mAlong.Count - 1 && mAlong[i] < distance)
			i++;
		let a = mPath[i - 1];
		let b = mPath[i];
		let span = mAlong[i] - mAlong[i - 1];
		let t = span > 0 ? Math.Clamp((distance - mAlong[i - 1]) / span, 0, 1) : 0;
		return .() { position = Vector3.Lerp(a.position, b.position, t), width = Mathf.Lerp(a.width, b.width, t), color = Color.Lerp(a.color, b.color, t) };
	}

	/// Quads along the path from `from` to `to` (in metres along it): one between each two points on the way.
	void AddRun(float from, float to, float total, bool closed, Matrix4 toLocal, Vector3 viewer, Vector3 facing, RibbonStyle style)
	{
		if (to - from <= 1.0e-5f)
			return;
		mRun.Clear();
		mRunAlong.Clear();
		mRun.Add(PointAt(from));
		mRunAlong.Add(from);
		for (int i < mPath.Count)
		{
			if (mAlong[i] > from + 1.0e-5f && mAlong[i] < to - 1.0e-5f)
			{
				mRun.Add(mPath[i]);
				mRunAlong.Add(mAlong[i]);
			}
		}
		mRun.Add(PointAt(to));
		mRunAlong.Add(to);

		let count = mRun.Count;
		var side = Vector3(1, 0, 0);
		Vector3 lastLeft = default, lastRight = default, lastNormal = default;
		Color lastColor = default;
		float lastU = 0;
		for (int i < count)
		{
			let point = mRun[i];
			// The direction along the strip here: between the points either side (round the join of a closed loop).
			Vector3 previous, next;
			if (closed && (i == 0 || i == count - 1))
			{
				previous = mRun[count - 2].position;
				next = mRun[1].position;
			}
			else
			{
				previous = mRun[Math.Max(i - 1, 0)].position;
				next = mRun[Math.Min(i + 1, count - 1)].position;
			}
			var tangent = next - previous;
			if (tangent.LengthSquared < 1.0e-12f)
				tangent = Vector3(0, 0, 1);
			tangent = tangent.Normalized;
			let normal = style.alignment == .View ? (viewer - point.position) : facing;
			let across = Vector3.Cross(tangent, normal);
			// Keeps the last good side where the strip points straight at the viewer.
			if (across.LengthSquared > 1.0e-10f)
				side = across.Normalized;
			let half = side * (point.width * 0.5f);
			let along = mRunAlong[i];
			let u = style.textureMode == .Tile ? along / Math.Max(style.tileLength, 0.0001f) : along / total;
			let localNormal = toLocal.TransformDirection(normal.LengthSquared > 1.0e-12f ? normal.Normalized : Vector3.Up);
			let left = toLocal.TransformPoint(point.position - half);
			let right = toLocal.TransformPoint(point.position + half);
			if (i > 0)
			{
				mMesh.AddVertex(lastLeft, lastNormal, lastColor, .(lastU, 0));
				mMesh.AddVertex(lastRight, lastNormal, lastColor, .(lastU, 1));
				mMesh.AddVertex(left, localNormal, point.color, .(u, 0));
				mMesh.AddVertex(right, localNormal, point.color, .(u, 1));
			}
			lastLeft = left;
			lastRight = right;
			lastNormal = localNormal;
			lastColor = point.color;
			lastU = u;
		}
	}
}

/// How a strip is laid out, from its component's fields.
struct RibbonStyle
{
	public LineAlignment alignment;
	public LineTextureMode textureMode;
	public bool loop;
	/// Dash and gap lengths in metres; solid when either is 0.
	public float dash;
	public float gap;
	/// How long one repeat of the texture is, with Tile.
	public float tileLength;
	/// Whether it has a texture, whose alpha then makes it see-through where the texture is.
	public bool textured;
}
