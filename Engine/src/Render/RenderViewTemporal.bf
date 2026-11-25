using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// What a temporal upscaler (DLSS, FSR 3) is given by the render path for one frame: everything at the scene's
/// (render) resolution except `output`. All textures are the view's own and valid until the next frame.
struct TemporalInputs
{
	/// The scene's HDR picture (RGBA16F) with the screen effects applied, before the bloom and the tonemap, drawn with
	/// the camera's jitter.
	public bgfx.TextureHandle color;
	/// The distance in front of the camera in metres (R32F; R16F where 32-bit cannot be drawn to), SKY_DEPTH (60000)
	/// for the sky and -1 on the viewmodel (post.sh).
	public bgfx.TextureHandle depthLinear;
	/// The depth buffer the depth pass drew (D32F, write-only: for a native image handle), device depth: 0 at the near
	/// plane to 1 at the far plane (1 where Gfx.HomogeneousDepth is false, -1 to 1 where it is true), jittered like the colour.
	public bgfx.TextureHandle depthDevice;
	/// The motion vectors (RGBA16F, x and y the vector, z 1 where it is unreliable): see RenderView.VelocityTexture for the convention.
	public bgfx.TextureHandle velocity;
	public int32 renderWidth, renderHeight, outputWidth, outputHeight;
	/// The jitter this frame's projection has (RenderView.JitterPixels, JitterNdc).
	public Vector2 jitterPixels, jitterNdc;
	/// True on the first frame, after a camera cut and when the size changed: the upscaler must drop its history.
	public bool reset;
	public float nearPlane, farPlane, fieldOfViewY;
	public bool orthographic;
	/// The seconds the last frame took (the frame time the upscalers ask for).
	public float deltaTime;
}

/// Motion vectors, the camera's sub-pixel jitter and temporal antialiasing (TAA), tallowengine.com/docs/temporal.
///
/// A temporal mode (TAA, or later a temporal upscaler) is on for a view when it may use the post passes (AllowPostAa),
/// shows the rendered picture, and the antialiasing setting is TAA (BeginTemporal). Then:
///  - the projection of the scene pass, the depth pass, the decals, the water, the see-through things and the viewmodel
///    is shifted by a sub-pixel jitter (Halton 2, 3), the same in each; shadows, the screen effects' reconstruction
///    of positions, the planar reflection and the editor's views use the unshifted one;
///  - the depth pass is drawn every frame and writes the motion vectors (Velocity convention below) as a second
///    target, with last frame's world matrix per object and the wind as it was a frame ago;
///  - after the tonemap, the TAA pass resolves the picture against its history (fs_taa.sc) and RCAS sharpens it a little.
///
/// View ids (bgfx's are all spoken for): the depth pass is the view the screen effects and decals already use; the sky's
/// motion vector is drawn into it first; the TAA resolve takes one of the five spare post ids (RenderViewAntialias.bf),
/// which TAA does not otherwise need (it replaces FXAA or SMAA) and it runs after the tonemap rather than before the
/// bloom for that reason. No view was added.
///
/// Motion vector convention (what DLSS and FSR 3 take, with a scale of 1; they read x and y of the RGBA16F target): per pixel of the scene's render
/// resolution, the offset from the pixel to where that surface was in the previous frame, in pixels: previous = current +
/// velocity. +x is right, +y is DOWN the picture on every graphics API. The jitter is not in it. It covers solid
/// objects (their transforms, wind sway) and the camera, the sky (the camera's rotation) and the viewmodel; not
/// see-through things or particles (the camera's motion is not applied to them: they get the vector of what is behind),
/// and not the bones of a skinned mesh or a custom vertex shader's displacement (the object's own movement only).
extension RenderView
{
	/// One instance of the depth pass with motion vectors: the world matrix (its w channels carry the tint, for the
	/// colour target) and last frame's as the three rows of a 3x4 matrix.
	[CRepr]
	struct VelocityInstance
	{
		public Matrix4 world;
		public Vector4 prev0, prev1, prev2;
	}

	/// Whether the upscalers' temporal path (UpscaleTemporal) is built into the render path. False: the jitter and motion
	/// vectors are only produced for TAA, and a temporal upscaler falls back to FSR 1. Set by the code that wires it.
	public static bool TemporalUpscaleWired = false;

	/// A cut of the camera longer than this (metres in a frame) drops the history.
	const float TemporalCutDistance = 5.0f;

	/// Whether this frame draws with a jitter and motion vectors (TAA, or a temporal upscaler).
	bool mTemporalOn;
	/// Whether TAA resolves this frame's picture; a temporal upscaler's own frame is mTemporalOn without it.
	bool mTaaOn;
	/// Whether a temporal upscaler (UpscaleTemporal) is the one this frame.
	bool mUpscaleTemporalOn;
	/// The next jitter's Halton index, and the sub-pixel shift this frame has.
	int32 mJitterIndex;
	Vector2 mJitterPixels, mJitterNdc;
	Matrix4 mProjJittered, mViewmodelProjJittered;
	/// This frame's and last frame's view and projection without jitter, for the world and the viewmodel.
	Matrix4 mVelCur, mVelPrev, mVelCurViewmodel, mVelPrevViewmodel;
	/// What the next frame calls last frame's.
	Matrix4 mLastViewProj, mLastViewmodelViewProj;
	Vector3 mLastTemporalPosition;
	int64 mLastTemporalFrame = -1000;
	int32 mLastTemporalWidth, mLastTemporalHeight;
	float mLastRealTime, mPrevRealTime;
	bool mTemporalReset;
	bool mResetRequested;
	float mTemporalDelta;

	bgfx.TextureHandle mVelocityColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mDepthVelFb = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mDepthAlbedoVelFb = .() { idx = uint16.MaxValue };
	bgfx.TextureHandle[2] mTaaHistory = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	bgfx.FrameBufferHandle[2] mTaaFb = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	int32 mTaaWidth, mTaaHeight;
	int mTaaCurrent;
	bool mTaaValid;
	int64 mTaaLastFrame = -1000;
	CameraData mTemporalCamera;

	/// Whether this frame is drawn with a camera jitter and motion vectors.
	public bool TemporalActive => mTemporalOn;
	/// The sub-pixel shift of this frame's projection, in scene pixels (+x right, +y down; -0.5 to 0.5). The projection
	/// moves the picture by this much, which is what FSR 3's and DLSS's jitter offsets are (negate where the API says
	/// the opposite).
	public Vector2 JitterPixels => mJitterPixels;
	/// The same as the shift of normalised device coordinates (+x right, +y up).
	public Vector2 JitterNdc => mJitterNdc;
	/// The motion vectors (RGBA16F: x, y the vector, z 1 where the motion is not known), valid when TemporalActive and the depth pass
	/// has been drawn. In render-resolution pixels, previous = current + velocity, +y down, jitter removed.
	public bgfx.TextureHandle VelocityTexture => mVelocityColor;
	/// The distance in front of the camera (R32F, SKY_DEPTH on the sky, -1 on the viewmodel).
	public bgfx.TextureHandle LinearDepthTexture => mDepthColor;
	/// The device depth buffer of the depth pass (D32F; sampleable, not write-only, when a temporal upscaler is on).
	public bgfx.TextureHandle DeviceDepthTexture => mDepthZ;
	/// The scene's HDR picture at render resolution (before the screen effects, the bloom and the tonemap).
	public bgfx.TextureHandle SceneColorTexture => mSceneColor;
	/// The size the scene is drawn at (smaller than Width and Height with a render scale).
	public int32 RenderWidth => mWidth;
	public int32 RenderHeight => mHeight;
	/// True on the frame that history must be dropped (first frame, a cut, a resize).
	public bool TemporalResetFrame => mTemporalReset;

	/// Drops the history for the next frame (a scene change, a teleport the engine cannot see).
	public void RequestTemporalReset()
	{
		mResetRequested = true;
	}

	static float Halton(int32 index, int32 radix)
	{
		float result = 0;
		float fraction = 1.0f / radix;
		var i = index;
		while (i > 0)
		{
			result += fraction * (i % radix);
			i /= radix;
			fraction /= radix;
		}
		return result;
	}

	/// How many different jitters repeat: 8 for TAA, and for an upscaler 8 times (output / render)^2 as FSR 3 advises.
	int32 JitterPhases()
	{
		if (!mUpscaleTemporalOn)
			return 8;
		let ratio = Math.Max((float)mOutWidth / Math.Max(mWidth, 1), 1.0f);
		return (int32)Math.Ceiling(8.0f * ratio * ratio);
	}

	/// The projection with the picture moved by (ndcX, ndcY) in normalised device coordinates: the clip position gets
	/// that much times its w added (the matrix's first two rows gain the fourth's), which holds for any projection.
	static Matrix4 Jittered(Matrix4 projection, float ndcX, float ndcY)
	{
		var result = projection;
		for (int c < 4)
		{
			result.m[c * 4 + 0] = projection.m[c * 4 + 0] + ndcX * projection.m[c * 4 + 3];
			result.m[c * 4 + 1] = projection.m[c * 4 + 1] + ndcY * projection.m[c * 4 + 3];
		}
		return result;
	}

	/// Decides what temporal mode this frame has and sets up its jitter and matrices: called first in Render.
	void BeginTemporal(CameraData camera)
	{
		mTemporalOn = false;
		mTaaOn = false;
		mUpscaleTemporalOn = false;
		mTemporalReset = false;
		if (Capture || shading != .Rendered || !AllowPostAa)
			return;
		let upscaler = TemporalUpscaleWired && Upscaling.IsTemporal(Upscaling.Effective);
		var taa = !upscaler && ViewAntialias() == .TAA;
		if (taa)
			taa = ClaimPostViews();
		if (!taa && !upscaler)
			return;
		mTemporalOn = true;
		mTaaOn = taa;
		mUpscaleTemporalOn = upscaler;
		mTemporalCamera = camera;

		// The history is dropped on the first frame, after a gap, a size change, a camera cut or by request.
		let frame = Time.FrameCount;
		let moved = (camera.position - mLastTemporalPosition).Length;
		mTemporalReset = mResetRequested || mLastTemporalFrame != frame - 1 || mLastTemporalWidth != mWidth || mLastTemporalHeight != mHeight || moved > TemporalCutDistance;
		mResetRequested = false;

		let phases = JitterPhases();
		mJitterIndex = (mJitterIndex + 1) % phases;
		mJitterPixels = .(Halton(mJitterIndex + 1, 2) - 0.5f, Halton(mJitterIndex + 1, 3) - 0.5f);
		if (JitterOverride.x != 0 || JitterOverride.y != 0)
			mJitterPixels = JitterOverride;
		mJitterNdc = .(2.0f * mJitterPixels.x / mWidth, -2.0f * mJitterPixels.y / mHeight);
		mProjJittered = Jittered(camera.projection, mJitterNdc.x, mJitterNdc.y);
		mViewmodelProjJittered = Jittered(camera.viewmodelProjection, mJitterNdc.x, mJitterNdc.y);

		mVelCur = camera.projection * camera.view;
		mVelCurViewmodel = camera.viewmodelProjection * camera.view;
		mVelPrev = mTemporalReset ? mVelCur : mLastViewProj;
		mVelPrevViewmodel = mTemporalReset ? mVelCurViewmodel : mLastViewmodelViewProj;
		mPrevRealTime = mTemporalReset ? Time.RealTime : mLastRealTime;
		mTemporalDelta = Time.UnscaledDeltaTime;
		mLastViewProj = mVelCur;
		mLastViewmodelViewProj = mVelCurViewmodel;
		mLastTemporalPosition = camera.position;
		mLastTemporalFrame = frame;
		mLastTemporalWidth = mWidth;
		mLastTemporalHeight = mHeight;
		mLastRealTime = Time.RealTime;
	}

	/// A test switch: when not zero, the jitter used every frame (in pixels), to see which way it moves the picture.
	public static Vector2 JitterOverride;

	/// The projection the scene's passes use: the camera's with the jitter when a temporal mode is on.
	Matrix4 SceneProjection(CameraData camera) => mTemporalOn ? mProjJittered : camera.projection;

	Matrix4 ViewmodelProjection(CameraData camera) => mTemporalOn ? mViewmodelProjJittered : camera.viewmodelProjection;

	/// Makes the motion vectors' target the first time it is needed (or after the effect targets were remade).
	bgfx.FrameBufferHandle DepthVelocityFramebuffer()
	{
		let rt = Gfx.TextureRenderTarget;
		let clamp = Gfx.SamplerClamp;
		let point = Gfx.SamplerPoint;
		if (!mVelocityColor.Valid)
		{
			// RGBA16F: x and y are the vector, z says it is not to be trusted (velocity.sh).
			mVelocityColor = bgfx.create_texture_2d((uint16)mWidth, (uint16)mHeight, false, 1, .RGBA16F, rt | clamp | point, null, 0);
		}
		if (mDepthAlbedo)
		{
			if (!mDepthAlbedoVelFb.Valid)
			{
				// Distance, motion vector, colour: the order the shaders write them in (fs_depth_albedo_vel.sc).
				bgfx.TextureHandle[4] attachments = .(mDepthColor, mVelocityColor, mAlbedoColor, mDepthZ);
				mDepthAlbedoVelFb = bgfx.create_frame_buffer_from_handles(4, &attachments, false);
			}
			return mDepthAlbedoVelFb;
		}
		if (!mDepthVelFb.Valid)
		{
			bgfx.TextureHandle[3] attachments = .(mDepthColor, mVelocityColor, mDepthZ);
			mDepthVelFb = bgfx.create_frame_buffer_from_handles(3, &attachments, false);
		}
		return mDepthVelFb;
	}

	void ReleaseVelocityTargets()
	{
		if (mDepthVelFb.Valid)
			bgfx.destroy_frame_buffer(mDepthVelFb);
		mDepthVelFb.idx = uint16.MaxValue;
		if (mVelocityColor.Valid)
			bgfx.destroy_texture(mVelocityColor);
		mVelocityColor.idx = uint16.MaxValue;
	}

	void ReleaseTaaTargets()
	{
		for (int i < 2)
		{
			if (mTaaFb[i].Valid)
				bgfx.destroy_frame_buffer(mTaaFb[i]);
			mTaaFb[i].idx = uint16.MaxValue;
		}
		mTaaWidth = mTaaHeight = 0;
		mTaaValid = false;
	}

	/// This frame's and last frame's matrices, the size and last frame's time, for the motion vector shaders.
	void SetVelocityUniforms(bool viewmodel, bool unreliable = false)
	{
		var cur = viewmodel ? mVelCurViewmodel : mVelCur;
		var prev = viewmodel ? mVelPrevViewmodel : mVelPrev;
		Vector4 parameters = .((float)mWidth, (float)mHeight, mPrevRealTime, unreliable ? 1 : 0);
		bgfx.set_uniform(RenderResources.uVelCur, &cur, 1);
		bgfx.set_uniform(RenderResources.uVelPrev, &prev, 1);
		bgfx.set_uniform(RenderResources.uVelParams, &parameters, 1);
	}

	/// The sky has no geometry: a full-screen triangle at the far plane, drawn first in the depth pass, writes its
	/// distance and the motion vector of the camera's turning (fs_depth_sky_vel.sc).
	void SubmitSkyVelocity(uint16 view)
	{
		SetVelocityUniforms(false);
		bgfx.set_uniform(RenderResources.uCamPos, &mCamPos, 1);
		SubmitFullscreen(view, mDepthAlbedo ? RenderResources.SkyVelAlbedoProgram : RenderResources.SkyVelProgram, Gfx.StateWriteRGB | Gfx.StateWriteA);
	}

	/// Whether an item's motion cannot be worked out from its object's matrix: a mesh whose vertices are rewritten each
	/// frame (cloth, soft bodies, ropes, skinned characters) or a custom vertex shader's movement.
	static bool UnreliableMotion(RenderItem item)
	{
		if (item.mesh.IsDynamic)
			return true;
		let shader = item.material != null ? item.material.Shader : null;
		return shader != null && !shader.vertex.IsEmpty;
	}

	/// What the renderer's matrix was last frame (this frame's when it was not drawn then, or is not an object's).
	static Matrix4 PreviousWorld(RenderProxy renderer, Matrix4 world)
	{
		// Foliage, particles and other proxies of their own stand for many instances, none of which moves.
		if (renderer.GameObject == null)
			return world;
		let frame = Time.FrameCount;
		if (renderer.MotionFrame != frame)
		{
			renderer.MotionPrevWorld = renderer.MotionFrame == frame - 1 ? renderer.MotionWorld : world;
			renderer.MotionWorld = world;
			renderer.MotionFrame = frame;
		}
		return renderer.MotionPrevWorld;
	}

	/// The depth pass's instances with their last-frame matrices. With `colors`, the tint goes in the w of the first three
	/// columns (vs_depth_albedo_vel.sc).
	void FillVelocityInstances(VelocityInstance* data, List<RenderItem> items, int start, int count, bool colors)
	{
		for (int i < count)
		{
			let item = &items.Ptr[start + i];
			var world = item.world;
			world.m[3] = world.m[7] = world.m[11] = 0;
			if (colors)
			{
				InstanceData tinted = default;
				FillInstance(&tinted, item);
				world.m[3] = tinted.color.r;
				world.m[7] = tinted.color.g;
				world.m[11] = tinted.color.b;
			}
			let previous = item.prevSlot > 0 ? mInstancedPrevious[item.prevSlot - 1] : PreviousWorld(item.renderer, item.world);
			data[i].world = world;
			data[i].prev0 = .(previous.m[0], previous.m[4], previous.m[8], previous.m[12]);
			data[i].prev1 = .(previous.m[1], previous.m[5], previous.m[9], previous.m[13]);
			data[i].prev2 = .(previous.m[2], previous.m[6], previous.m[10], previous.m[14]);
		}
	}

	/// Makes the history targets (two of the picture's size) when the size changed.
	void EnsureTaaTargets(int32 width, int32 height)
	{
		if (mTaaFb[0].Valid && mTaaWidth == width && mTaaHeight == height)
			return;
		ReleaseTaaTargets();
		for (int i < 2)
		{
			mTaaHistory[i] = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA16F, Gfx.TextureRenderTarget | Gfx.SamplerClamp, null, 0);
			mTaaFb[i] = bgfx.create_frame_buffer_from_handles(1, &mTaaHistory[i], true);
		}
		mTaaWidth = width;
		mTaaHeight = height;
		mTaaValid = false;
	}

	/// The temporal antialiasing resolve: blends the tonemapped picture `source` with the history along the motion
	/// vectors into the next history, and returns that.
	bgfx.TextureHandle DrawTaa(bgfx.TextureHandle source, int32 width, int32 height)
	{
		EnsureTaaTargets(width, height);
		let write = mTaaCurrent;
		let read = write ^ 1;
		let valid = mTaaValid && !mTemporalReset && mTaaLastFrame == Time.FrameCount - 1 && mVelocityColor.Valid;
		Vector4 parameters = .(1.0f / width, 1.0f / height, valid ? 1 : 0, Math.Clamp(Antialiasing.TaaHistory, 0.0f, 0.98f));
		Vector4 parameters2 = .(Gfx.OriginBottomLeft ? 1.0f : -1.0f, 1.25f, 0, 0);
		bgfx.set_uniform(RenderResources.uTaaParams, &parameters, 1);
		bgfx.set_uniform(RenderResources.uTaaParams2, &parameters2, 1);
		bgfx.set_texture(0, RenderResources.sColor, source, uint32.MaxValue);
		bgfx.set_texture(1, RenderResources.sHistory, mTaaHistory[read], uint32.MaxValue);
		bgfx.set_texture(2, RenderResources.sVelocity, mVelocityColor.Valid ? mVelocityColor : source, uint32.MaxValue);
		bgfx.set_texture(3, RenderResources.sDepth, mDepthColor.Valid ? mDepthColor : source, uint32.MaxValue);
		let view = NextPostView();
		SetUpView(view, "TAA", mTaaFb[write], 0, 0, width, height, 0, 0);
		SubmitFullscreen(view, RenderResources.TaaProgram, Gfx.StateWriteRGB | Gfx.StateWriteA);
		mTaaCurrent = read;
		mTaaValid = true;
		mTaaLastFrame = Time.FrameCount;
		return mTaaHistory[write];
	}

	/// Where DLSS and FSR 3 draw the window-sized picture from the render-sized one (UpscaleTemporal calls this): the
	/// view's pictures and the jitter go to the native upscaler in `inputs`. Returns false until the native side is
	/// wired, when the caller falls back to FSR 1.
	bool ApplyTemporalUpscale(UpscalerKind kind, TemporalInputs inputs, out bgfx.TextureHandle output)
	{
		// The native side (UpscaleNative.bf) takes the texture handles' images, the jitter in pixels, the motion vector
		// scale (1, 1: they are in render pixels) and `inputs.reset`, and writes the output-size picture (RGBA16F) here.
		output = default;
		return false;
	}

	/// What a temporal upscaler is given this frame (valid after the depth pass and the screen effects).
	TemporalInputs MakeTemporalInputs(CameraData camera, bgfx.TextureHandle color)
	{
		TemporalInputs inputs = default;
		inputs.color = color;
		inputs.depthLinear = mDepthColor;
		inputs.depthDevice = mDepthZ;
		inputs.velocity = mVelocityColor;
		inputs.renderWidth = mWidth;
		inputs.renderHeight = mHeight;
		inputs.outputWidth = mOutWidth;
		inputs.outputHeight = mOutHeight;
		inputs.jitterPixels = mJitterPixels;
		inputs.jitterNdc = mJitterNdc;
		inputs.reset = mTemporalReset;
		inputs.nearPlane = camera.near;
		inputs.farPlane = camera.far;
		inputs.fieldOfViewY = camera.fieldOfView;
		inputs.orthographic = camera.orthographic;
		inputs.deltaTime = mTemporalDelta;
		return inputs;
	}
}
