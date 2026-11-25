using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// The sun's shadows (four cascades fitted round the camera's view, drawn into the shadow atlas) and the point and
/// spot lights' (tiles of a second atlas, tallowengine.com/docs/lighting).
extension RenderView
{
	/// The sun's four shadow cascades, one tile of the shadow atlas each.
	void DrawShadowCascades(CameraData camera, Vector3 lightDirection, float shadowDistance)
	{
		ComputeCascades(camera, lightDirection, shadowDistance);
		let tile = RenderResources.ShadowTileSize;
		for (int cascade < RenderResources.CascadeCount)
		{
			let view = (uint16)(ViewBase + ShadowView + cascade);
			SetUpView(view, "Shadow", RenderResources.ShadowFrameBuffer, (int32)(cascade % 2) * tile, (int32)(cascade / 2) * tile, tile, tile,
				Gfx.ClearDepth);
			bgfx.set_view_transform(view, &mCascadeView[cascade], &mCascadeProj[cascade]);
			bgfx.touch(view);
			mShadowPassViewProj = mCascadeViewProj[cascade];
			mShadowScissor = default;
			GpuCullCascade(cascade);
			SubmitShadowCascade(view, cascade);
			GpuDrawShadow(view, cascade);
		}
		let filterRadius = mCascadeRadius[0] * 2.0f / RenderResources.ShadowTileSize * 1.5f;
		mShadowParams = .(1.0f / RenderResources.ShadowAtlasSize, ShadowBias, 1.0f, filterRadius);
	}

	/// The casters of the cascade or tile being drawn.
	List<RenderItem*> mShadowVisible = new .() ~ delete _;

	/// The point and spot lights' shadows, all in one view: each tile is a spot light's view or one face of a point
	/// light's cube, drawn through its own matrix and kept to its part of the atlas by a scissor. Casters come from
	/// the light's view, including walls outside the camera's: a wall behind the viewer must still stop a remote
	/// flashlight.
	void DrawLocalShadows()
	{
		RenderResources.EnsureLocalShadows();
		let size = RenderResources.ShadowAtlasSize;
		let view = (uint16)(ViewBase + LocalShadowView);
		SetUpView(view, "Point and spot shadows", RenderResources.LocalShadowFrameBuffer, 0, 0, size, size, Gfx.ClearDepth);
		Matrix4 identity = .Identity;
		bgfx.set_view_transform(view, &identity, &identity);
		bgfx.touch(view);
		let items = mShadowItems.Ptr;
		var tileIndex = 0;
		for (let tile in mLights.Tiles)
		{
			mShadowPassViewProj = tile.drawViewProj;
			mShadowScissor = .(tile.x, tile.y, tile.size, tile.size);
			mShadowVisible.Clear();
			for (int i < mShadowItems.Count)
			{
				if (tile.frustum.IntersectsSphere(items[i].center, items[i].radius))
					mShadowVisible.Add(&items[i]);
			}
			// What is drawn from clusters has its own culling for the tile; the tiles past the room for that draw it whole.
			let onGpu = GpuCullTile(tileIndex, tile);
			if (!onGpu)
			{
				let local = mLocalShadowItems.Ptr;
				for (int i < mLocalShadowItems.Count)
				{
					if (tile.frustum.IntersectsSphere(local[i].center, local[i].radius))
						mShadowVisible.Add(&local[i]);
				}
			}
			SubmitShadowCasters(view);
			if (onGpu)
				GpuDrawTile(view, tileIndex);
			tileIndex++;
		}
		mShadowScissor = default;
	}

	/// mShadowVisible, in runs of one mesh and sway.
	void SubmitShadowCasters(uint16 view)
	{
		let visible = mShadowVisible;
		int start = 0;
		while (start < visible.Count)
		{
			int end = start + 1;
			while (end < visible.Count && visible[end].mesh == visible[start].mesh && visible[end].renderer.windSway == visible[start].renderer.windSway)
				end++;
			SubmitShadowBatch(view, start, end - start);
			start = end;
		}
	}

	/// Draws `count` of mShadowVisible from `start` as one instanced draw into the shadow map.
	void SubmitShadowBatch(uint16 view, int start, int count)
	{
		var done = 0;
		while (done < count)
		{
			let drawn = SubmitShadowPiece(view, start + done, count - done);
			if (drawn <= 0)
			{
				InstancesDropped += (int32)(count - done);
				break;
			}
			done += drawn;
		}
	}

	/// One draw of as many of the casters as the instance memory has room for; returns how many.
	int SubmitShadowPiece(uint16 view, int start, int count)
	{
		let stride = (uint16)sizeof(InstanceData);
		let drawCount = Math.Min(count, (int)bgfx.get_avail_instance_data_buffer((uint32)count, stride));
		if (drawCount <= 0)
			return 0;
		bgfx.InstanceDataBuffer buffer = default;
		bgfx.alloc_instance_data_buffer(&buffer, (uint32)drawCount, stride);
		let data = (InstanceData*)buffer.data;
		let items = mShadowVisible.Ptr + start;
		for (int i < drawCount)
			FillInstance(data + i, items[i]);
		let mesh = items[0].mesh;
		if (mesh.IsDynamic)
			bgfx.set_dynamic_vertex_buffer(0, mesh.DynamicBuffer, 0, (uint32)mesh.VertexCount);
		else
			bgfx.set_vertex_buffer(0, mesh.VertexBuffer, 0, (uint32)mesh.VertexCount);
		bgfx.set_index_buffer(mesh.IndexBuffer, 0, (uint32)mesh.IndexCount);
		bgfx.set_instance_data_buffer(&buffer, 0, (uint32)drawCount);
		SetWindUniforms(items[0].renderer.windSway);
		bgfx.set_uniform(RenderResources.uShadowViewProj, &mShadowPassViewProj, 1);
		if (mShadowScissor[2] > 0)
			bgfx.set_scissor((uint16)mShadowScissor[0], (uint16)mShadowScissor[1], (uint16)mShadowScissor[2], (uint16)mShadowScissor[3]);
		bgfx.set_state(Gfx.StateWriteZ | Gfx.StateDepthLess, 0);
		bgfx.submit(view, RenderResources.ShadowProgram, 0, 0xff);
		return drawCount;
	}

	/// Day / Night: the step, in degrees, the sun's direction moves in for its shadow cascades.
	public const float ShadowAngleStep = 0.05f;

	/// How far behind a cascade's view things can stand and still cast a shadow into it.
	const float CasterDistance = 150.0f;

	/// Fits the four cascades: each a slice of the camera's view, wrapped in a sphere and seen from the sun.
	void ComputeCascades(CameraData camera, Vector3 lightDirection, float shadowDistance)
	{
		float[RenderResources.CascadeCount + 1] splits = default;
		CascadeSplits(camera, shadowDistance, ref splits);

		var lightForward = lightDirection.Normalized;
		Vector3 lightRight = .Zero;
		if (mShadowPole.LengthSquared > 0.5f)
		{
			// Day / Night: the sun turns round the celestial pole. The cascades see it from a direction stepped by
			// ShadowAngleStep round and away from the pole (steps too small to see, so shadow edges do not crawl
			// every frame), and their basis comes from the pole, so it turns smoothly with the sun instead of
			// flipping where the sun passes overhead.
			let pole = mShadowPole.Normalized;
			let e1 = Vector3.Cross(pole, Math.Abs(pole.x) < 0.9f ? Vector3.Right : Vector3.Forward).Normalized;
			let e2 = Vector3.Cross(pole, e1);
			let step = ShadowAngleStep * Mathf.Deg2Rad;
			let around = Math.Round(Math.Atan2(Vector3.Dot(lightForward, e2), Vector3.Dot(lightForward, e1)) / step) * step;
			let up = Math.Round(Math.Asin(Math.Clamp(Vector3.Dot(lightForward, pole), -1, 1)) / step) * step;
			lightForward = ((e1 * Math.Cos(around) + e2 * Math.Sin(around)) * Math.Cos(up) + pole * Math.Sin(up)).Normalized;
			lightRight = Vector3.Cross(pole, lightForward);
		}
		if (lightRight.LengthSquared < 1.0e-6f)
			lightRight = Vector3.Cross(Vector3.Up, lightForward);
		if (lightRight.LengthSquared < 1.0e-6f)
			lightRight = Vector3.Cross(Vector3.Right, lightForward);
		lightRight = lightRight.Normalized;
		let lightUp = Vector3.Cross(lightForward, lightRight);
		mLightRight = lightRight;
		mLightUp = lightUp;

		for (int cascade < RenderResources.CascadeCount)
		{
			SliceSphere(camera, splits[cascade], splits[cascade + 1], var center, let radius);
			// Snap to shadow texels so the cascade does not shimmer as the camera moves.
			let texel = radius * 2.0f / RenderResources.ShadowTileSize;
			let cx = Vector3.Dot(center, lightRight);
			let cy = Vector3.Dot(center, lightUp);
			center = center + lightRight * (Math.Floor(cx / texel) * texel - cx) + lightUp * (Math.Floor(cy / texel) * texel - cy);

			let eye = center - lightForward * (radius + CasterDistance);
			let lightView = Matrix4.LookAt(eye, center, lightUp);
			let lightProj = Matrix4.Ortho(-radius, radius, -radius, radius, 0.0f, radius * 2.0f + CasterDistance, Gfx.HomogeneousDepth);
			mCascadeView[cascade] = lightView;
			mCascadeProj[cascade] = lightProj;
			mCascadeViewProj[cascade] = lightProj * lightView;
			mCascadeCenter[cascade] = center;
			mCascadeRadius[cascade] = radius;
			mShadowMtx[cascade] = AtlasTransform(cascade) * mCascadeViewProj[cascade];
		}
	}

	/// Where the cascades start and end in front of the camera: mostly logarithmic (detail close by), part even.
	void CascadeSplits(CameraData camera, float shadowDistance, ref float[RenderResources.CascadeCount + 1] splits)
	{
		let near = Math.Max(camera.near, 0.05f);
		let far = Math.Max(Math.Min(camera.far, shadowDistance), near + 1.0f);
		splits[0] = near;
		for (int i = 1; i <= RenderResources.CascadeCount; i++)
		{
			let p = (float)i / RenderResources.CascadeCount;
			let logSplit = near * Math.Pow(far / near, p);
			let uniformSplit = near + (far - near) * p;
			splits[i] = Mathf.Lerp(uniformSplit, logSplit, 0.8f);
		}
		if (camera.orthographic)
		{
			// One cascade covers an orthographic view; clip-space w is constant there.
			mCascadeSplits = .(1.0e9f, 1.0e9f, 1.0e9f, 1.0e9f);
			for (int i = 1; i <= RenderResources.CascadeCount; i++)
				splits[i] = far;
		}
		else
			mCascadeSplits = .(splits[1], splits[2], splits[3], splits[4]);
	}

	/// The sphere round the slice of the camera's view from `near` to `far` in front of it (its radius rounded up to
	/// an eighth, so that it does not change size with every small turn).
	static void SliceSphere(CameraData camera, float near, float far, out Vector3 center, out float radius)
	{
		let v = camera.view.m;
		let camRight = Vector3(v[0], v[4], v[8]);
		let camUp = Vector3(v[1], v[5], v[9]);
		let camForward = Vector3(v[2], v[6], v[10]);
		let tanHalf = Math.Tan(camera.fieldOfView * 0.5f * Mathf.Deg2Rad);
		Vector3[8] corners = default;
		for (int i < 8)
		{
			let z = (i & 4) != 0 ? far : near;
			let halfH = camera.orthographic ? camera.orthographicSize : z * tanHalf;
			let halfW = halfH * camera.aspect;
			corners[i] = camera.position + camForward * z
				+ camRight * ((i & 1) != 0 ? halfW : -halfW)
				+ camUp * ((i & 2) != 0 ? halfH : -halfH);
		}
		center = Vector3.Zero;
		for (int i < 8)
			center = center + corners[i];
		center = center / 8.0f;
		radius = 0;
		for (int i < 8)
			radius = Math.Max(radius, (corners[i] - center).Length);
		radius = Math.Ceiling(radius * 8.0f) / 8.0f;
	}

	/// From a cascade's clip space to its tile of the shadow atlas (a 2 x 2 grid).
	static Matrix4 AtlasTransform(int cascade)
	{
		let tx = (float)(cascade % 2);
		let ty = (float)(cascade / 2);
		Matrix4 bias = default;
		bias.m[0] = 0.25f;
		bias.m[12] = 0.25f + tx * 0.5f;
		if (Gfx.OriginBottomLeft)
		{
			bias.m[5] = 0.25f;
			bias.m[13] = 0.75f - ty * 0.5f;
		}
		else
		{
			bias.m[5] = -0.25f;
			bias.m[13] = 0.25f + ty * 0.5f;
		}
		bias.m[10] = Gfx.HomogeneousDepth ? 0.5f : 1.0f;
		bias.m[14] = Gfx.HomogeneousDepth ? 0.5f : 0.0f;
		bias.m[15] = 1.0f;
		return bias;
	}

	void SubmitShadowCascade(uint16 view, int cascade)
	{
		let center = mCascadeCenter[cascade];
		let radius = mCascadeRadius[cascade];
		let items = mShadowItems.Ptr;
		mShadowVisible.Clear();
		for (int i < mShadowItems.Count)
		{
			let item = &items[i];
			let offset = item.center - center;
			if (Mathf.Abs(Vector3.Dot(offset, mLightRight)) > radius + item.radius)
				continue;
			if (Mathf.Abs(Vector3.Dot(offset, mLightUp)) > radius + item.radius)
				continue;
			mShadowVisible.Add(item);
		}
		SubmitShadowCasters(view);
	}
}
