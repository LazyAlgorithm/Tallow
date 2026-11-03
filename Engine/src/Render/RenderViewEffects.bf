using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// The screen effects (ambient occlusion, depth of field, motion blur), bloom and the tonemap, after the scene is drawn.
extension RenderView
{
	void ReleaseEffectTargets()
	{
		void Release(ref bgfx.FrameBufferHandle fb)
		{
			if (fb.Valid)
				bgfx.destroy_frame_buffer(fb);
			fb.idx = uint16.MaxValue;
		}
		Release(ref mDepthFb);
		Release(ref mPostFb[0]);
		Release(ref mPostFb[1]);
		Release(ref mAoFb);
		Release(ref mDofFb);
	}

	/// Makes the screen effects' targets, at the scene's size, the first time they are needed.
	void EnsureEffectTargets()
	{
		if (mDepthFb.Valid)
			return;
		let rt = Gfx.TextureRenderTarget;
		let clamp = Gfx.SamplerClamp;
		let point = Gfx.SamplerPoint;
		let writeOnly = Gfx.TextureWriteOnly;
		// Distance in front of the camera: 32-bit where it can be drawn to (precise far away), else 16-bit.
		let depthFormat = bgfx.is_texture_valid(0, false, 1, .R32F, rt | clamp | point) ? bgfx.TextureFormat.R32F : bgfx.TextureFormat.R16F;
		bgfx.TextureHandle[2] depthTextures;
		depthTextures[0] = bgfx.create_texture_2d((uint16)mWidth, (uint16)mHeight, false, 1, depthFormat, rt | clamp | point, null, 0);
		depthTextures[1] = bgfx.create_texture_2d((uint16)mWidth, (uint16)mHeight, false, 1, .D32F, rt | writeOnly, null, 0);
		mDepthColor = depthTextures[0];
		mDepthFb = bgfx.create_frame_buffer_from_handles(2, &depthTextures, true);
		for (int i < 2)
		{
			mPostColor[i] = bgfx.create_texture_2d((uint16)mWidth, (uint16)mHeight, false, 1, .RGBA16F, rt | clamp, null, 0);
			mPostFb[i] = bgfx.create_frame_buffer_from_handles(1, &mPostColor[i], true);
		}
		mHalfWidth = Math.Max(mWidth / 2, 4);
		mHalfHeight = Math.Max(mHeight / 2, 4);
		mAoColor = bgfx.create_texture_2d((uint16)mHalfWidth, (uint16)mHalfHeight, false, 1, .RGBA8, rt | clamp, null, 0);
		mAoFb = bgfx.create_frame_buffer_from_handles(1, &mAoColor, true);
		mDofColor = bgfx.create_texture_2d((uint16)mHalfWidth, (uint16)mHalfHeight, false, 1, .RGBA16F, rt | clamp, null, 0);
		mDofFb = bgfx.create_frame_buffer_from_handles(1, &mDofColor, true);
	}

	/// Ambient occlusion, depth of field and motion blur (docs/post-processing.md), as the scene asks and the
	/// player's settings (ScreenEffects) allow. Each reads the picture so far and writes the next; returns the last.
	bgfx.TextureHandle DrawScreenEffects(CameraData camera, SceneEnvironment env)
	{
		var picture = mSceneColor;
		let ao = ScreenEffects.AmbientOcclusion && ShowAmbientOcclusion && env.ambientOcclusion > MinimumEffect;
		let dof = ScreenEffects.DepthOfField && ShowDepthOfField && env.depthOfField > MinimumEffect;
		let motionAmount = Math.Clamp(env.motionBlur, 0.0f, 1.0f) * Math.Clamp(ScreenEffects.MotionBlurAmount, 0.0f, 2.0f);
		let motion = ScreenEffects.MotionBlur && ShowMotionBlur && motionAmount > MinimumEffect;
		let worldViewProj = camera.projection * camera.view;
		if (ao || dof || motion)
		{
			EnsureEffectTargets();
			SetPostCamera(camera);
			EnsureDepthPass(camera);
			int next = 0;
			if (ao)
			{
				DrawAmbientOcclusion(env, picture, next);
				picture = mPostColor[next];
				next ^= 1;
			}
			if (dof)
			{
				DrawDepthOfField(env, picture, next);
				picture = mPostColor[next];
				next ^= 1;
			}
			if (motion)
			{
				DrawMotionBlur(camera, worldViewProj, motionAmount, picture, next);
				picture = mPostColor[next];
				next ^= 1;
			}
		}
		mPrevViewProj = worldViewProj;
		mPrevPosition = camera.position;
		mHasPrev = true;
		return picture;
	}

	void DrawAmbientOcclusion(SceneEnvironment env, bgfx.TextureHandle picture, int target)
	{
		Vector4 aoParams = .(Math.Max(env.occlusionRadius, 0.05f), Math.Clamp(env.ambientOcclusion, 0.0f, 2.0f), 1.0f / mWidth, 1.0f / mHeight);
		SetPostUniforms();
		bgfx.set_uniform(RenderResources.uAoParams, &aoParams, 1);
		bgfx.set_texture(0, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		EffectPass((uint16)(ViewBase + AoView), "Ambient occlusion", mAoFb, mHalfWidth, mHalfHeight, RenderResources.AoProgram);

		Vector4 applyParams = .(0, 0, 1.0f / mHalfWidth, 1.0f / mHalfHeight);
		SetPostUniforms();
		bgfx.set_uniform(RenderResources.uAoParams, &applyParams, 1);
		bgfx.set_texture(0, RenderResources.sColor, picture, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sAo, mAoColor, uint32.MaxValue);
		bgfx.set_texture(2, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		EffectPass((uint16)(ViewBase + AoApplyView), "Occlusion apply", mPostFb[target], mWidth, mHeight, RenderResources.AoApplyProgram);
	}

	void DrawDepthOfField(SceneEnvironment env, bgfx.TextureHandle picture, int target)
	{
		let focus = env.autoFocus ? -1.0f : Math.Max(env.focusDistance, 0.0f);
		let reach = Math.Clamp(env.depthOfField, 0.0f, 2.0f) * SceneEnvironment.DepthOfFieldReach;
		Vector4 dofParams = .(focus, Math.Max(env.focusRange, 0.01f), reach, (float)mHeight / mWidth);
		SetPostUniforms();
		bgfx.set_uniform(RenderResources.uDofParams, &dofParams, 1);
		bgfx.set_texture(0, RenderResources.sColor, picture, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		EffectPass((uint16)(ViewBase + DofBlurView), "Depth of field blur", mDofFb, mHalfWidth, mHalfHeight, RenderResources.DofBlurProgram);

		SetPostUniforms();
		bgfx.set_uniform(RenderResources.uDofParams, &dofParams, 1);
		bgfx.set_texture(0, RenderResources.sColor, picture, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		bgfx.set_texture(2, RenderResources.sBlur, mDofColor, uint32.MaxValue);
		EffectPass((uint16)(ViewBase + DofCombineView), "Depth of field", mPostFb[target], mWidth, mHeight, RenderResources.DofCombineProgram);
	}

	void DrawMotionBlur(CameraData camera, Matrix4 worldViewProj, float amount, bgfx.TextureHandle picture, int target)
	{
		// A cut (a respawn, a new camera) is not a movement to smear.
		let moved = (camera.position - mPrevPosition).Length;
		var previous = (mHasPrev && moved < MotionBlurCutDistance) ? mPrevViewProj : worldViewProj;
		Vector4 motionParams = .(amount, 0.06f, 0, 0);
		SetPostUniforms();
		bgfx.set_uniform(RenderResources.uMotionParams, &motionParams, 1);
		bgfx.set_uniform(RenderResources.uPrevViewProj, &previous, 1);
		bgfx.set_texture(0, RenderResources.sColor, picture, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sDepth, mDepthColor, uint32.MaxValue);
		EffectPass((uint16)(ViewBase + MotionView), "Motion blur", mPostFb[target], mWidth, mHeight, RenderResources.MotionBlurProgram);
	}

	/// Bloom: keeps what is bright at a quarter of the size, then blurs it across and down. The result is in
	/// mBloomColor[0].
	void DrawBloom(SceneEnvironment env, bgfx.TextureHandle picture)
	{
		void Pass(uint16 view, StringView name, bgfx.FrameBufferHandle target, bgfx.TextureHandle source, bgfx.ProgramHandle program, Vector4 parameters)
		{
			var values = parameters;
			SetUpView(view, name, target, 0, 0, mBloomWidth, mBloomHeight);
			bgfx.set_uniform(RenderResources.uBloomParams, &values, 1);
			bgfx.set_texture(0, RenderResources.sColor, source, uint32.MaxValue);
			SubmitFullscreen(view, program, Gfx.StateWriteRGB | Gfx.StateWriteA);
		}
		let threshold = Math.Max(env.bloomThreshold, 0);
		let bright = Vector4(threshold, Math.Max(threshold * 0.5f, 0.05f), 1.0f / mWidth, 1.0f / mHeight);
		Pass((uint16)(ViewBase + BloomView), "Bloom bright", mBloomFb[0], picture, RenderResources.BloomDownProgram, bright);
		Pass((uint16)(ViewBase + BloomView + 1), "Bloom across", mBloomFb[1], mBloomColor[0], RenderResources.BloomBlurProgram, .(0, 0, 1.0f / mBloomWidth, 0));
		Pass((uint16)(ViewBase + BloomView + 2), "Bloom down", mBloomFb[0], mBloomColor[1], RenderResources.BloomBlurProgram, .(0, 0, 0, 1.0f / mBloomHeight));
	}

	/// Brings the HDR picture down to the screen's range, with exposure, vignette, colour grading and bloom (0: none).
	void DrawTonemap(SceneEnvironment env, bgfx.TextureHandle picture, float bloom)
	{
		let view = (uint16)(ViewBase + TonemapView);
		SetUpView(view, "Tonemap", mOutputFb, 0, 0, mOutWidth, mOutHeight);
		let exposure = env.exposure * Math.Clamp(ScreenEffects.Brightness, 0.25f, 4.0f);
		Vector4 postParams = .(exposure, Math.Max(env.vignette, 0), Math.Max(env.saturation, 0), bloom);
		bgfx.set_uniform(RenderResources.uPostParams, &postParams, 1);
		let lookup = PostProcess.GetLookup(env.colorLookup, let lookupSize);
		Vector4 gradeParams = .(Math.Max(env.contrast, 0), Math.Clamp(env.temperature, -1.0f, 1.0f), Math.Clamp(env.tint, -1.0f, 1.0f),
			Math.Clamp(env.colorLookupStrength, 0.0f, 1.0f));
		let filter = Linear(env.colorFilter);
		Vector4 gradeFilter = .(filter.x, filter.y, filter.z, (float)lookupSize);
		bgfx.set_uniform(RenderResources.uGradeParams, &gradeParams, 1);
		bgfx.set_uniform(RenderResources.uGradeFilter, &gradeFilter, 1);
		bgfx.set_texture(0, RenderResources.sColor, picture, uint32.MaxValue);
		// With no bloom the sampler still needs something; its contribution is multiplied by zero.
		bgfx.set_texture(1, RenderResources.sBloom, bloom > 0 ? mBloomColor[0] : picture, uint32.MaxValue);
		bgfx.set_texture(2, RenderResources.sLut, lookup, uint32.MaxValue);
		SubmitFullscreen(view, RenderResources.TonemapProgram, Gfx.StateWriteRGB | Gfx.StateWriteA);
	}

	/// The camera's frame for the screen effects' shaders (Engine/shaders/post.sh): its right, up and forward in the
	/// world (the rows of the view matrix), the projection's spread, and which way texture v runs.
	void SetPostCamera(CameraData camera)
	{
		let view = camera.view;
		let projection = camera.projection;
		mPostRight = .(view.m[0], view.m[4], view.m[8], 1.0f / projection.m[0]);
		mPostUp = .(view.m[1], view.m[5], view.m[9], 1.0f / projection.m[5]);
		mPostForward = .(view.m[2], view.m[6], view.m[10], camera.orthographic ? 1 : 0);
		mPostEye = .(camera.position, Gfx.OriginBottomLeft ? 1 : -1);
	}

	void SetPostUniforms()
	{
		bgfx.set_uniform(RenderResources.uPostRight, &mPostRight, 1);
		bgfx.set_uniform(RenderResources.uPostUp, &mPostUp, 1);
		bgfx.set_uniform(RenderResources.uPostForward, &mPostForward, 1);
		bgfx.set_uniform(RenderResources.uPostEye, &mPostEye, 1);
	}

	/// One full-screen step of the screen effects into a target (its uniforms and textures already set).
	void EffectPass(uint16 view, StringView name, bgfx.FrameBufferHandle target, int32 width, int32 height, bgfx.ProgramHandle program)
	{
		SetUpView(view, name, target, 0, 0, width, height);
		SubmitFullscreen(view, program, Gfx.StateWriteRGB | Gfx.StateWriteA);
	}

	/// Draws the depth pass, once a frame, for the decals and the screen effects that need it.
	void EnsureDepthPass(CameraData camera)
	{
		if (mDepthDrawn)
			return;
		EnsureEffectTargets();
		SubmitDepthPass((uint16)(ViewBase + DepthView), camera);
		mDepthDrawn = true;
	}

	/// The depth pass: how far in front of the camera each solid surface is, for the screen effects. The world's
	/// solid objects first, then the viewmodel's over them, marked -1 so the effects leave it alone. Nothing drawn is
	/// the sky, 60000 (SKY_DEPTH in post.sh).
	void SubmitDepthPass(uint16 view, CameraData camera)
	{
		var viewMatrix = camera.view;
		var projMatrix = camera.projection;
		bgfx.set_palette_color_rgba32f(DepthPalette, 60000.0f, 0, 0, 1);
		bgfx.set_view_name(view, "Depth", 5);
		bgfx.set_view_frame_buffer(view, mDepthFb);
		bgfx.set_view_rect(view, 0, 0, (uint16)mWidth, (uint16)mHeight, 0, 1);
		bgfx.set_view_clear_mrt(view, Gfx.ClearColor | Gfx.ClearDepth, 1.0f, 0, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette, DepthPalette);
		bgfx.set_view_transform(view, &viewMatrix, &projMatrix);
		bgfx.set_view_mode(view, .Sequential);
		bgfx.touch(view);
		let worldViewProj = projMatrix * viewMatrix;
		let viewmodelViewProj = camera.viewmodelProjection * viewMatrix;
		for (int pass < 3)
		{
			let items = pass == 0 ? mItems : (pass == 1 ? mViewmodelItems : mFoliageItems);
			int start = 0;
			while (start < items.Count)
			{
				int end = start + 1;
				while (end < items.Count && items[end].mesh == items[start].mesh && items[end].material == items[start].material && items[end].renderer.windSway == items[start].renderer.windSway && Mirrored(items[end].world) == Mirrored(items[start].world))
					end++;
				SubmitDepthBatch(view, items, start, end - start, pass == 1 ? viewmodelViewProj : worldViewProj, pass == 1);
				start = end;
			}
		}
	}

	const uint8 DepthPalette = 15;

	void SubmitDepthBatch(uint16 view, List<RenderItem> items, int start, int count, Matrix4 viewProj, bool viewmodel)
	{
		let stride = (uint16)sizeof(InstanceData);
		let drawCount = Math.Min(count, (int)bgfx.get_avail_instance_data_buffer((uint32)count, stride));
		if (drawCount <= 0)
			return;
		bgfx.InstanceDataBuffer buffer = default;
		bgfx.alloc_instance_data_buffer(&buffer, (uint32)drawCount, stride);
		let data = (InstanceData*)buffer.data;
		for (int i < drawCount)
		{
			data[i].world = items[start + i].world;
			data[i].color = .(1, 1, 1, 1);
		}
		let first = items[start];
		let mesh = first.mesh;
		if (mesh.IsDynamic)
			bgfx.set_dynamic_vertex_buffer(0, mesh.DynamicBuffer, 0, (uint32)mesh.VertexCount);
		else
			bgfx.set_vertex_buffer(0, mesh.VertexBuffer, 0, (uint32)mesh.VertexCount);
		bgfx.set_index_buffer(mesh.IndexBuffer, 0, (uint32)mesh.IndexCount);
		bgfx.set_instance_data_buffer(&buffer, 0, (uint32)drawCount);
		var matrix = viewProj;
		Vector4 depthParams = .(viewmodel ? 1 : 0, 0, 0, 0);
		SetWindUniforms(first.renderer.windSway);
		bgfx.set_uniform(RenderResources.uDepthViewProj, &matrix, 1);
		bgfx.set_uniform(RenderResources.uDepthParams, &depthParams, 1);
		uint64 cull = FacingCull(Mirrored(first.world) ? Gfx.StateCullCw : Gfx.StateCullCcw);
		if ((first.material != null && first.material.doubleSided) || !first.renderer.backFaceCulling)
			cull = 0;
		// The viewmodel is over everything, so it is not depth tested.
		uint64 depth = Gfx.StateWriteZ | Gfx.StateDepthLess;
		if (viewmodel)
			depth = 0;
		bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA | depth | cull, 0);
		bgfx.submit(view, RenderResources.DepthProgram, 0, 0xff);
	}
}
