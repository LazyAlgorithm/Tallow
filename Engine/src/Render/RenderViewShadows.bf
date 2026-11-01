using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// The sun's shadows (four cascades fitted round the camera's view, drawn into the shadow atlas) and the point and
/// spot lights' (tiles of a second atlas, docs/lighting.md).
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
			SubmitShadowCascade(view, cascade);
		}
		let filterRadius = mCascadeRadius[0] * 2.0f / RenderResources.ShadowTileSize * 1.5f;
		mShadowParams = .(1.0f / RenderResources.ShadowAtlasSize, ShadowBias, 1.0f, filterRadius);
	}

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
		List<RenderItem> visible = scope .();
		for (let tile in mLights.Tiles)
		{
			mShadowPassViewProj = tile.drawViewProj;
			mShadowScissor = .(tile.x, tile.y, tile.size, tile.size);
			visible.Clear();
			for (let item in mShadowItems)
			{
				if (tile.frustum.IntersectsSphere(item.center, item.radius))
					visible.Add(item);
			}
			int start = 0;
			while (start < visible.Count)
			{
				int end = start + 1;
				while (end < visible.Count && visible[end].mesh == visible[start].mesh && visible[end].renderer.windSway == visible[start].renderer.windSway)
					end++;
				SubmitBatch(view, visible, start, end - start, true);
				start = end;
			}
		}
		mShadowScissor = default;
	}

	/// How far behind a cascade's view things can stand and still cast a shadow into it.
	const float CasterDistance = 150.0f;

	/// Fits the four cascades: each a slice of the camera's view, wrapped in a sphere and seen from the sun.
	void ComputeCascades(CameraData camera, Vector3 lightDirection, float shadowDistance)
	{
		float[RenderResources.CascadeCount + 1] splits = default;
		CascadeSplits(camera, shadowDistance, ref splits);

		let lightForward = lightDirection.Normalized;
		var lightRight = Vector3.Cross(Vector3.Up, lightForward);
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
		List<RenderItem> visible = scope .();
		for (let item in mShadowItems)
		{
			let offset = item.center - center;
			if (Mathf.Abs(Vector3.Dot(offset, mLightRight)) > radius + item.radius)
				continue;
			if (Mathf.Abs(Vector3.Dot(offset, mLightUp)) > radius + item.radius)
				continue;
			visible.Add(item);
		}
		int start = 0;
		while (start < visible.Count)
		{
			int end = start + 1;
			while (end < visible.Count && visible[end].mesh == visible[start].mesh && visible[end].renderer.windSway == visible[start].renderer.windSway)
				end++;
			SubmitBatch(view, visible, start, end - start, true);
			start = end;
		}
	}
}
