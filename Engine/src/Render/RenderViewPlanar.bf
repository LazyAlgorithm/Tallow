using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Planar reflections (MeshRenderer.planarReflection, docs/reflections.md). Before the frame's scene, a second
/// RenderView draws it from the camera mirrored under the nearest such surface's top face, with its near plane tilted
/// onto that face (an oblique projection) so nothing below the surface shows. The mirror pass (fs_mirror.sc) then
/// reads that picture at each pixel of the surface. bgfx's views are put in an order where the mirrored view's come
/// just before its owner's, so the picture is this frame's.
extension RenderView
{
	/// Where the game's view and the editor's Scene and Game views draw their mirrored scene: view ids no other view
	/// uses (after the asset preview's copy view), each block the eleven a capture view needs.
	const uint16 PlanarBlock = 11;
	const uint16 PlanarBase0 = 10 + ViewCount * 3 + 1;
	const uint16 PlanarBase1 = PlanarBase0 + PlanarBlock;
	/// The first view id of this view's mirrored scene, or 0 when it has none.
	public uint16 PlanarViewBase;
	/// Whether this view is another's mirrored scene: it draws everything, including what reflection probes leave out.
	public bool PlanarPass;
	/// A view drawn from a mirrored camera: the backs of faces face the other way.
	public bool MirroredCamera;

	RenderView mPlanarView ~ delete _;
	HashSet<uint32> mPlanarHidden = new .() ~ delete _;
	MeshRenderer mPlanarRenderer;
	bool mPlanarDrawn;

	static uint16 PlanarBaseFor(uint16 viewBase)
	{
		if (viewBase == 10)
			return PlanarBase0;
		if (viewBase == 10 + ViewCount)
			return PlanarBase1;
		return 0;
	}

	/// Back-face culling as this view needs it: turned round in a mirrored view.
	[Inline]
	uint64 FacingCull(uint64 cull)
	{
		if (!MirroredCamera || cull == 0)
			return cull;
		return cull == Gfx.StateCullCw ? Gfx.StateCullCcw : Gfx.StateCullCw;
	}

	/// Puts each mirrored-scene block of views just before the views of the view it belongs to. Set again each frame a
	/// mirror is drawn (cheap), in case the device was reset.
	static void SetViewOrder()
	{
		uint16[256] order = default;
		int count = 0;
		for (uint16 id < 256)
		{
			if (id >= PlanarBase0 && id < PlanarBase1 + PlanarBlock)
				continue;
			if (id == 10)
			{
				for (uint16 k < PlanarBlock)
					order[count++] = PlanarBase0 + k;
			}
			if (id == 10 + ViewCount)
			{
				for (uint16 k < PlanarBlock)
					order[count++] = PlanarBase1 + k;
			}
			order[count++] = id;
		}
		bgfx.set_view_order(0, (uint16)count, &order);
	}

	/// The nearest visible surface with Planar Reflection, drawn from under its top face.
	void DrawPlanarReflection(Scene scene, CameraData camera)
	{
		mPlanarDrawn = false;
		mPlanarRenderer = null;
		if (PlanarViewBase == 0 || Capture || shading != .Rendered || camera.orthographic || !ScreenEffects.SurfaceReflections || !Reflections.Enabled)
			return;
		RenderItem* best = null;
		float bestDistance = float.MaxValue;
		for (int i < mMirrorItems.Count)
		{
			let item = &mMirrorItems.Ptr[i];
			if (!item.renderer.planarReflection)
				continue;
			let distance = (item.center - camera.position).Length - item.radius;
			if (distance < bestDistance)
			{
				best = item;
				bestDistance = distance;
			}
		}
		if (best == null)
			return;
		// The surface's top face: through the top of its mesh's box, facing along its object's up.
		var normal = best.world.TransformDirection(.Up);
		if (normal.Length < 0.0001f)
			return;
		normal = normal.Normalized;
		let bounds = best.mesh.Bounds;
		let top = best.world.TransformPoint(.((bounds.min.x + bounds.max.x) * 0.5f, bounds.max.y, (bounds.min.z + bounds.max.z) * 0.5f));
		let d = Vector3.Dot(normal, top);
		// Seen from behind its face, the surface mirrors nothing this way.
		if (Vector3.Dot(normal, camera.position) - d <= 0.001f)
			return;

		if (mPlanarView == null)
		{
			mPlanarView = new RenderView(PlanarViewBase);
			mPlanarView.Capture = true;
			mPlanarView.PlanarPass = true;
			mPlanarView.MirroredCamera = true;
			mPlanarView.CapturesReflections = false;
			mPlanarView.PlanarViewBase = 0;
		}
		SetViewOrder();
		mPlanarView.Resize(mWidth, mHeight);
		mPlanarHidden.Clear();
		mPlanarHidden.Add(best.renderer.GameObject.Id);
		if (hiddenHere != null)
		{
			for (let id in hiddenHere)
				mPlanarHidden.Add(id);
		}
		mPlanarView.hiddenHere = mPlanarHidden;

		// Mirrors a point through the plane n.x = d.
		Matrix4 reflect = .Identity;
		reflect.m[0] = 1 - 2 * normal.x * normal.x;
		reflect.m[1] = -2 * normal.y * normal.x;
		reflect.m[2] = -2 * normal.z * normal.x;
		reflect.m[4] = -2 * normal.x * normal.y;
		reflect.m[5] = 1 - 2 * normal.y * normal.y;
		reflect.m[6] = -2 * normal.z * normal.y;
		reflect.m[8] = -2 * normal.x * normal.z;
		reflect.m[9] = -2 * normal.y * normal.z;
		reflect.m[10] = 1 - 2 * normal.z * normal.z;
		reflect.m[12] = 2 * d * normal.x;
		reflect.m[13] = 2 * d * normal.y;
		reflect.m[14] = 2 * d * normal.z;

		CameraData mirrored = camera;
		mirrored.view = camera.view * reflect;
		mirrored.position = reflect.TransformPoint(camera.position);
		mirrored.forward = reflect.TransformDirection(camera.forward);
		mirrored.hasViewmodel = false;
		mirrored.occlusionCulling = false;
		mirrored.projection = ObliqueProjection(camera.projection, mirrored.view, normal, d - 0.01f);
		mPlanarView.Render(scene, mirrored);
		mPlanarRenderer = best.renderer;
		mPlanarDrawn = true;
	}

	/// The projection with its near plane moved onto the plane n.x = d (in the world), so that what is behind the
	/// plane is not drawn (Lengyel, "Oblique View Frustum Depth Projection and Clipping").
	static Matrix4 ObliqueProjection(Matrix4 projection, Matrix4 view, Vector3 normal, float d)
	{
		// The plane in the view's space: the world plane as a row, times the inverse of the view.
		let toWorld = view.Inverse;
		float[4] world = .(normal.x, normal.y, normal.z, -d);
		float[4] p = default;
		for (int column < 4)
			p[column] = world[0] * toWorld.m[column * 4] + world[1] * toWorld.m[column * 4 + 1] + world[2] * toWorld.m[column * 4 + 2] + world[3] * toWorld.m[column * 4 + 3];
		let plane = Vector4(p[0], p[1], p[2], p[3]);
		var result = projection;
		let toView = projection.Inverse;
		// The far corner of the view on the plane's side.
		float[4] corner = .(Math.Sign(plane.x), Math.Sign(plane.y), 1, 1);
		float[4] q = default;
		for (int row < 4)
			q[row] = toView.m[row] * corner[0] + toView.m[4 + row] * corner[1] + toView.m[8 + row] * corner[2] + toView.m[12 + row] * corner[3];
		let dot = plane.x * q[0] + plane.y * q[1] + plane.z * q[2] + plane.w * q[3];
		if (Math.Abs(dot) < 1e-8f)
			return projection;
		if (Gfx.HomogeneousDepth)
		{
			// Depth from -1 to 1: the near plane is the third row plus the fourth.
			let scale = 2.0f / dot;
			result.m[2] = plane.x * scale - projection.m[3];
			result.m[6] = plane.y * scale - projection.m[7];
			result.m[10] = plane.z * scale - projection.m[11];
			result.m[14] = plane.w * scale - projection.m[15];
		}
		else
		{
			let scale = 1.0f / dot;
			result.m[2] = plane.x * scale;
			result.m[6] = plane.y * scale;
			result.m[10] = plane.z * scale;
			result.m[14] = plane.w * scale;
		}
		return result;
	}
}
