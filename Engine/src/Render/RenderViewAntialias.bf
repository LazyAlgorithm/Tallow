using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Antialiasing and upscaling of the finished picture: the tonemap writes the picture at the scene's size or the
/// window's into an LDR target; then, each when it is on, FXAA or SMAA at that size, FSR 1's EASU up to the window's
/// size, and FSR 1's RCAS sharpening into the output. With none of them the tonemap writes the output itself, as it
/// always did. MSAA is not here: it lives in the scene target (RenderView.Resize).
///
/// bgfx's view ids are all spoken for (see RenderView.ViewCount, the reflection captures and the shader graph preview),
/// so these passes take ids from the five that are left over, ascending in draw order, and only one RenderView a
/// frame gets them: the player's picture, or the editor's Game view (RenderView.AllowPostAa). A view that does not
/// get them uses MSAA for the antialiasing and a plain stretch for the upscaling.
extension RenderView
{
	/// The bgfx view ids the passes after the tonemap use, in draw order: 108 and 109 sit between the asset
	/// preview's mirrored-scene blocks and the modelling views; 252 to 254 are after the shader graph preview and
	/// before ImGui's 255. Nothing else uses them.
	static uint16[5] sPostViews = .(108, 109, 252, 253, 254);
	static uint32 sPostViewsFrame = uint32.MaxValue;
	static RenderView sPostViewsOwner;

	/// Whether the antialiasing passes (FXAA, SMAA) and the upscaler's may run in this view: only the player's picture
	/// and the editor's Game view set it (see the class comment).
	public bool AllowPostAa;

	bgfx.TextureHandle[2] mLdrColor = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	bgfx.FrameBufferHandle[2] mLdrFb = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	int32 mLdrWidth, mLdrHeight;
	bgfx.TextureHandle mUpColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mUpFb = .() { idx = uint16.MaxValue };
	bgfx.TextureHandle mSmaaEdgesColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mSmaaEdgesFb = .() { idx = uint16.MaxValue };
	bgfx.TextureHandle mSmaaWeightsColor = .() { idx = uint16.MaxValue };
	bgfx.FrameBufferHandle mSmaaWeightsFb = .() { idx = uint16.MaxValue };
	/// A temporal upscaler (DLSS, FSR 2) produced the output-size picture this frame (UpscaleTemporal).
	bool mTemporalUpscaled;
	int32 mPostViewNext;

	struct PostPlan
	{
		public AntialiasMode aa;
		/// The picture is made at the scene's size (TAA and FSR 1 work there; a plain stretch happens after).
		public bool sceneSize;
		public bool easu;
		public bool rcas;
		public int32 passes;
	}

	void ReleasePostTargets()
	{
		void Release(ref bgfx.FrameBufferHandle fb)
		{
			if (fb.Valid)
				bgfx.destroy_frame_buffer(fb);
			fb.idx = uint16.MaxValue;
		}
		Release(ref mLdrFb[0]);
		Release(ref mLdrFb[1]);
		Release(ref mUpFb);
		Release(ref mSmaaEdgesFb);
		Release(ref mSmaaWeightsFb);
		ReleaseTaaTargets();
		ReleaseUpscaleContext();
		mLdrWidth = mLdrHeight = 0;
	}

	/// The antialiasing this view uses: the setting as the card can do it; a filter on the finished picture only where
	/// the view has passes for it (AllowPostAa), else multisampling.
	AntialiasMode ViewAntialias()
	{
		if (Capture)
			return .Off;
		var mode = Antialiasing.Resolve(AntialiasingMode);
		// TAA also needs the post passes' view ids (the resolve) and a view that draws every frame.
		if ((Antialiasing.IsPost(mode) || Antialiasing.IsTemporal(mode)) && (!AllowPostAa || shading != .Rendered))
		{
			mode = Antialiasing.Resolve(.MSAA4x);
			if (Antialiasing.IsPost(mode))
				mode = .Off;
		}
		return mode;
	}

	/// The multisampling the scene target has: none for TAA (and for a temporal upscaler, which also needs a plain
	/// picture) and the filters, the mode's own for MSAA.
	int32 ViewSamples()
	{
		if (ViewTemporalUpscaler() != .Off)
			return 0;
		return Antialiasing.Samples(ViewAntialias());
	}

	/// The temporal antialiasing (TAA) resolve is DrawTaa (RenderViewTemporal.bf), after the tonemap: see DrawFinish.

	/// The temporal upscalers' hook (DLSS, FSR 2), called with the HDR scene picture at the scene's size once the
	/// screen effects have run. When it draws the picture at the window's size into `output` and returns true, the
	/// bloom and tonemap run on that and EASU and RCAS are skipped. Returns false until they are built into the render
	/// path, which then uses FSR 1 (Upscaling.Effective already says FSR 1 while the native upscaler is missing).
	bool UpscaleTemporal(UpscalerKind kind, CameraData camera, bgfx.TextureHandle sceneColor, out bgfx.TextureHandle output)
	{
		return ApplyTemporalUpscale(kind, MakeTemporalInputs(camera, sceneColor), out output);
	}

	/// A test switch: TALLOW_DEBUG_VELOCITY=1 shows the motion vectors instead of the picture.
	static bool sDebugVelocityRead;
	static bool sDebugVelocity;
	static bool DebugVelocity
	{
		get
		{
			if (!sDebugVelocityRead)
			{
				sDebugVelocityRead = true;
				let value = scope String();
				sDebugVelocity = Environment.GetEnvironmentVariable("TALLOW_DEBUG_VELOCITY", value) case .Ok && value == "1";
			}
			return sDebugVelocity;
		}
	}

	bool ClaimPostViews()
	{
		let frame = (uint32)Time.FrameCount;
		if (sPostViewsFrame == frame && sPostViewsOwner != this)
			return false;
		sPostViewsFrame = frame;
		sPostViewsOwner = this;
		mPostViewNext = 0;
		return true;
	}

	/// What to do after the tonemap this frame. The view ids are claimed when there is anything to do.
	PostPlan PlanPost()
	{
		var plan = PostPlan();
		if (Capture || shading != .Rendered)
			return plan;
		plan.aa = mTemporalUpscaled ? .Off : ViewAntialias();
		if (plan.aa == .TAA)
		{
			// Decided at the start of the frame (BeginTemporal), which also claimed the view ids.
			if (!mTaaOn)
				plan.aa = .Off;
		}
		else if (!Antialiasing.IsPost(plan.aa))
			plan.aa = .Off;
		if (plan.aa == .SMAA && !Antialiasing.EnsureSmaaTextures())
			plan.aa = .FXAA;
		var upscaler = Upscaling.Effective;
		if (Upscaling.IsTemporal(upscaler) && !mTemporalUpscaled)
			upscaler = .FSR1;
		if (upscaler == .FSR1)
		{
			plan.easu = mWidth < mOutWidth || mHeight < mOutHeight;
			plan.rcas = Upscaling.Sharpness > 0.01f;
		}
		else if (upscaler == .Off || mTemporalUpscaled)
		{
			plan.easu = false;
			plan.rcas = false;
		}
		if (plan.aa == .TAA)
		{
			plan.sceneSize = true;
			// With nothing sharpening already, a light RCAS (which also stretches a smaller scene to the window).
			if (!plan.easu)
				plan.rcas = true;
		}
		plan.passes = (plan.aa == .TAA ? 1 : 0) + (plan.aa == .FXAA ? 1 : (plan.aa == .SMAA ? 3 : 0)) + (plan.easu ? 1 : 0) + (plan.rcas ? 1 : 0);
		if (plan.passes > 0 && (!AllowPostAa || (plan.aa != .TAA && !ClaimPostViews())))
			return PostPlan();
		return plan;
	}

	uint16 NextPostView() => sPostViews[Math.Min(mPostViewNext++, sPostViews.Count - 1)];

	bgfx.TextureHandle MakeLdr(int32 width, int32 height) => bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA8, Gfx.TextureRenderTarget | Gfx.SamplerClamp, null, 0);

	/// Makes the LDR targets the passes pass the picture between: two at `width` x `height` (the tonemap's size).
	void EnsureLdrTargets(int32 width, int32 height)
	{
		if (mLdrFb[0].Valid && mLdrWidth == width && mLdrHeight == height)
			return;
		for (int i < 2)
		{
			if (mLdrFb[i].Valid)
				bgfx.destroy_frame_buffer(mLdrFb[i]);
			mLdrColor[i] = MakeLdr(width, height);
			mLdrFb[i] = bgfx.create_frame_buffer_from_handles(1, &mLdrColor[i], true);
		}
		mLdrWidth = width;
		mLdrHeight = height;
		// SMAA's two follow the size.
		if (mSmaaEdgesFb.Valid)
			bgfx.destroy_frame_buffer(mSmaaEdgesFb);
		if (mSmaaWeightsFb.Valid)
			bgfx.destroy_frame_buffer(mSmaaWeightsFb);
		mSmaaEdgesFb.idx = mSmaaWeightsFb.idx = uint16.MaxValue;
	}

	void EnsureSmaaTargets()
	{
		if (mSmaaEdgesFb.Valid)
			return;
		mSmaaEdgesColor = MakeLdr(mLdrWidth, mLdrHeight);
		mSmaaEdgesFb = bgfx.create_frame_buffer_from_handles(1, &mSmaaEdgesColor, true);
		mSmaaWeightsColor = MakeLdr(mLdrWidth, mLdrHeight);
		mSmaaWeightsFb = bgfx.create_frame_buffer_from_handles(1, &mSmaaWeightsColor, true);
	}

	void EnsureUpscaleTarget()
	{
		if (mUpFb.Valid)
			return;
		mUpColor = MakeLdr(mOutWidth, mOutHeight);
		mUpFb = bgfx.create_frame_buffer_from_handles(1, &mUpColor, true);
	}

	/// One full-screen pass of the antialiasing and upscaling. `size` is the source picture's, for the shader's texel.
	void PostPass(StringView name, bgfx.FrameBufferHandle target, int32 width, int32 height, int32 sourceWidth, int32 sourceHeight, bgfx.ProgramHandle program, uint16 clearFlags = 0)
	{
		let view = NextPostView();
		SetUpView(view, name, target, 0, 0, width, height, clearFlags, 0);
		Vector4 aaParams = .(1.0f / sourceWidth, 1.0f / sourceHeight, (float)sourceWidth, (float)sourceHeight);
		bgfx.set_uniform(RenderResources.uAaParams, &aaParams, 1);
		SubmitFullscreen(view, program, Gfx.StateWriteRGB | Gfx.StateWriteA);
	}

	/// The tonemap, then whatever antialiasing and upscaling is on, into the output.
	void DrawFinish(SceneEnvironment env, bgfx.TextureHandle picture, float bloom)
	{
		if (mTemporalOn && mVelocityColor.Valid && DebugVelocity)
		{
			// A test view (TALLOW_DEBUG_VELOCITY=1): the motion vectors instead of the picture.
			bgfx.set_texture(0, RenderResources.sColor, mVelocityColor, uint32.MaxValue);
			let view = NextPostView();
			SetUpView(view, "Velocity view", mOutputFb, 0, 0, mOutWidth, mOutHeight, 0, 0);
			SubmitFullscreen(view, RenderResources.VelocityViewProgram, Gfx.StateWriteRGB | Gfx.StateWriteA);
			return;
		}
		let plan = PlanPost();
		if (plan.passes == 0)
		{
			DrawTonemap(env, picture, bloom, mOutputFb, mOutWidth, mOutHeight);
			return;
		}
		// The size of the picture the filters work on: the scene's when FSR 1 will enlarge it afterwards.
		let width = (plan.easu || plan.sceneSize) ? mWidth : mOutWidth;
		let height = (plan.easu || plan.sceneSize) ? mHeight : mOutHeight;
		EnsureLdrTargets(width, height);
		DrawTonemap(env, picture, bloom, mLdrFb[0], width, height);
		var source = mLdrColor[0];

		if (plan.aa == .TAA)
		{
			// The resolve keeps its result in its history target, which is the next pass's source.
			source = DrawTaa(source, width, height);
		}
		else if (plan.aa != .Off)
		{
			let last = !plan.easu && !plan.rcas;
			let target = last ? mOutputFb : mLdrFb[1];
			if (plan.aa == .FXAA)
			{
				bgfx.set_texture(0, RenderResources.sColor, source, uint32.MaxValue);
				PostPass("FXAA", target, width, height, width, height, RenderResources.FxaaProgram);
			}
			else
			{
				EnsureSmaaTargets();
				bgfx.set_texture(0, RenderResources.sColor, source, uint32.MaxValue);
				PostPass("SMAA edges", mSmaaEdgesFb, width, height, width, height, RenderResources.SmaaEdgesProgram, Gfx.ClearColor);
				bgfx.set_texture(0, RenderResources.sEdges, mSmaaEdgesColor, uint32.MaxValue);
				bgfx.set_texture(1, RenderResources.sArea, Antialiasing.SmaaArea, uint32.MaxValue);
				bgfx.set_texture(2, RenderResources.sSearch, Antialiasing.SmaaSearch, uint32.MaxValue);
				PostPass("SMAA weights", mSmaaWeightsFb, width, height, width, height, RenderResources.SmaaWeightsProgram, Gfx.ClearColor);
				bgfx.set_texture(0, RenderResources.sColor, source, uint32.MaxValue);
				bgfx.set_texture(1, RenderResources.sBlend, mSmaaWeightsColor, uint32.MaxValue);
				PostPass("SMAA blend", target, width, height, width, height, RenderResources.SmaaBlendProgram);
			}
			source = mLdrColor[1];
		}
		if (plan.easu)
		{
			EnsureUpscaleTarget();
			bgfx.set_texture(0, RenderResources.sColor, source, uint32.MaxValue);
			PostPass("FSR EASU", plan.rcas ? mUpFb : mOutputFb, mOutWidth, mOutHeight, width, height, RenderResources.EasuProgram);
			source = mUpColor;
		}
		if (plan.rcas)
		{
			// Sharpness 0..1 as FSR's scale of stops of reduction: 1 the full amount, 0 none.
			let sharpness = (plan.aa == .TAA && !plan.easu) ? Antialiasing.TaaSharpness : Upscaling.Sharpness;
			let stops = (1.0f - Math.Clamp(sharpness, 0.0f, 1.0f)) * 2.0f;
			Vector4 fsrParams = .(Math.Pow(2.0f, -stops), 0, 0, 0);
			bgfx.set_uniform(RenderResources.uFsrParams, &fsrParams, 1);
			bgfx.set_texture(0, RenderResources.sColor, source, uint32.MaxValue);
			PostPass("FSR RCAS", mOutputFb, mOutWidth, mOutHeight, plan.easu ? mOutWidth : width, plan.easu ? mOutHeight : height, RenderResources.RcasProgram);
		}
	}
}
