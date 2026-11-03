using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Decals (docs/decals.md): after the solid scene, each visible decal's box is drawn over the scene target, and
/// fs_decal.sc lays the picture on the surfaces the depth pass found inside it.
extension RenderView
{
	struct DecalItem
	{
		public Matrix4 volume;
		public StringView texture;
		public Color color;
		public Vector4 parameters;
		public bool unlit;
		public int32 order;
		/// Where the decal came in the gathering, to keep equal orders in a steady sequence.
		public int32 index;
	}

	/// Placed decals (by order, then as they are in the scene), then spawned ones, oldest first.
	void DrawDecals(Scene scene, CameraData camera, Frustum frustum)
	{
		VisibleDecals = 0;
		mDecalItems.Clear();
		Decals.Expire(scene);
		let unitBox = Bounds(.(-0.5f), .(0.5f));
		for (let component in scene.ComponentsOfType(typeof(Decal)))
		{
			let decal = (Decal)component;
			if (!decal.IsActiveAndEnabled || !decal.GameObject.InActiveWorld || HidesHere(decal.GameObject) || decal.opacity <= 0 || decal.color.a <= 0)
				continue;
			let volume = decal.BoxMatrix;
			if (!frustum.Intersects(unitBox.Transformed(volume)))
				continue;
			DecalItem item;
			item.volume = volume;
			item.texture = decal.texture;
			item.color = .(decal.color.r, decal.color.g, decal.color.b, decal.color.a * decal.opacity);
			item.parameters = DecalParameters(decal.metallic, decal.roughness, decal.angleLimit);
			item.unlit = decal.unlit;
			item.order = decal.order;
			item.index = (int32)mDecalItems.Count;
			mDecalItems.Add(item);
		}
		mDecalItems.Sort(scope (a, b) => a.order != b.order ? a.order <=> b.order : a.index <=> b.index);
		for (let spawned in scene.SpawnedDecals)
		{
			let fade = Decals.Fade(spawned);
			if (fade <= 0 || !frustum.Intersects(unitBox.Transformed(spawned.volume)))
				continue;
			DecalItem item;
			item.volume = spawned.volume;
			item.texture = spawned.texture;
			item.color = .(spawned.color.r, spawned.color.g, spawned.color.b, spawned.color.a * fade);
			item.parameters = DecalParameters(0, 0.8f, spawned.angleLimit);
			item.unlit = false;
			item.order = int32.MaxValue;
			item.index = (int32)mDecalItems.Count;
			mDecalItems.Add(item);
		}
		if (mDecalItems.IsEmpty)
			return;
		let mesh = Assets.GetMesh("builtin:cube");
		if (mesh == null || !mesh.HasGpuData)
			return;

		EnsureDepthPass(camera);
		let view = (uint16)(ViewBase + DecalView);
		var viewMatrix = camera.view;
		var projMatrix = camera.projection;
		SetUpView(view, "Decals", mSceneFb, 0, 0, mWidth, mHeight);
		bgfx.set_view_transform(view, &viewMatrix, &projMatrix);
		// In order: later decals are laid over earlier ones.
		bgfx.set_view_mode(view, .Sequential);
		for (let item in mDecalItems)
		{
			var volume = item.volume;
			var inverse = volume.Inverse;
			let linear = Linear(item.color);
			var color = Vector4(linear.x, linear.y, linear.z, item.color.a);
			let forward = volume.TransformDirection(.(0, 0, 1));
			var axis = Vector4(forward.LengthSquared > 1e-12f ? forward.Normalized : Vector3.Forward, item.unlit ? 1 : 0);
			var parameters = item.parameters;
			SetFrameUniforms();
			bgfx.set_uniform(RenderResources.uDecalBox, &volume, 1);
			bgfx.set_uniform(RenderResources.uDecalInverse, &inverse, 1);
			bgfx.set_uniform(RenderResources.uDecalColor, &color, 1);
			bgfx.set_uniform(RenderResources.uDecalAxis, &axis, 1);
			bgfx.set_uniform(RenderResources.uDecalParams, &parameters, 1);
			bgfx.set_texture(0, RenderResources.sAlbedo, Assets.GetTexture(item.texture), (uint32)Gfx.SamplerClamp);
			bgfx.set_texture(1, RenderResources.sShadowMap, RenderResources.ShadowMap, uint32.MaxValue);
			bgfx.set_texture(12, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
			bgfx.set_vertex_buffer(0, mesh.VertexBuffer, 0, (uint32)mesh.VertexCount);
			bgfx.set_index_buffer(mesh.IndexBuffer, 0, (uint32)mesh.IndexCount);
			// The box's far side, where it is behind the scene: the camera may stand inside the box, and only the
			// pixels whose surface could be in the box are shaded.
			let cull = FacingCull(Mirrored(volume) ? Gfx.StateCullCcw : Gfx.StateCullCw);
			bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateDepthGequal | cull | Gfx.StateBlendAlpha, 0);
			bgfx.submit(view, RenderResources.DecalProgram, 0, 0xff);
			DrawCalls++;
			VisibleDecals++;
		}
	}

	/// The shader's metallic, roughness and the cosines of the angle limit and of where its fade starts.
	static Vector4 DecalParameters(float metallic, float roughness, float angleLimit)
	{
		let limit = Math.Clamp(angleLimit, 1.0f, 90.0f);
		let start = Math.Max(limit - 15.0f, 0.0f);
		return .(metallic, roughness, Math.Cos(limit * Mathf.Deg2Rad), Math.Cos(start * Mathf.Deg2Rad));
	}
}
