using System;
using Bgfx;

namespace Tallow;

/// What an occlusion test needs to know about the picture it reads.
struct GpuOccluder
{
	/// The camera the picture was drawn from.
	public Matrix4 view, projection;
	/// The pyramid: the size of its first level (powers of two) and how many levels it has.
	public int32 baseWidth, baseHeight, levels;
	/// The size in pixels of the picture it was made from.
	public int32 width, height;
	public float near;
	public bgfx.DynamicVertexBufferHandle buffer;
}

/// One camera's occlusion test (GpuDrivenView.bf describes the two phases): the occluders are drawn, as distances in
/// front of the camera, into a target of their own; a pyramid is made of that picture (a compute shader per level, each
/// entry the farthest distance in a square of the level below, cs_hzb_*.sc) and the culling reads the pyramid. Two pyramids
/// are kept: the one of the last frame's finished picture, which the first phase reads (the camera it was drawn from is
/// remembered with it), and one for the picture of this frame's first phase, which the second phase reads.
class GpuOcclusion
{
	public int32 Width, Height;
	bgfx.TextureHandle mDistance = .() { idx = uint16.MaxValue };
	bgfx.TextureHandle mDepth = .() { idx = uint16.MaxValue };
	public bgfx.FrameBufferHandle FrameBuffer = .() { idx = uint16.MaxValue };
	/// 0: the last frame's finished picture; 1: this frame's first phase.
	bgfx.DynamicVertexBufferHandle[2] mPyramids = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	public int32 BaseWidth, BaseHeight, Levels;

	Matrix4 mView, mProjection;
	Vector3 mPosition, mForward;
	int64 mFrame = -1000;
	bool mHasHistory;

	/// A camera that moved further than this since the last picture, or turned further than the angle below, was cut: the
	/// last picture says nothing about what is in view now.
	const float CutDistance = 25.0f;
	const float CutDot = 0.5f;

	public ~this()
	{
		Release();
	}

	public bool Ready => FrameBuffer.Valid && mPyramids[0].Valid;

	public void Release()
	{
		if (!Gfx.Initialized)
			return;
		if (FrameBuffer.Valid)
			bgfx.destroy_frame_buffer(FrameBuffer);
		FrameBuffer.idx = uint16.MaxValue;
		mDistance.idx = mDepth.idx = uint16.MaxValue;
		for (int i < 2)
		{
			if (mPyramids[i].Valid)
				bgfx.destroy_dynamic_vertex_buffer(mPyramids[i]);
			mPyramids[i].idx = uint16.MaxValue;
		}
		mHasHistory = false;
	}

	static int32 PowerOfTwo(int32 n)
	{
		var p = 1;
		while (p < n)
			p *= 2;
		return (int32)p;
	}

	/// Makes the target and the pyramids for a picture of this size (again when the size changed). False when the graphics
	/// card has no 32-bit distance target: no occlusion then.
	public bool Ensure(int32 width, int32 height)
	{
		if (FrameBuffer.Valid && width == Width && height == Height)
			return true;
		Release();
		let rt = Gfx.TextureRenderTarget;
		let clamp = Gfx.SamplerClamp;
		let point = Gfx.SamplerPoint;
		if (!bgfx.is_texture_valid(0, false, 1, .R32F, rt | clamp | point))
			return false;
		Width = width;
		Height = height;
		bgfx.TextureHandle[2] textures;
		textures[0] = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .R32F, rt | clamp | point, null, 0);
		textures[1] = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .D32F, rt | Gfx.TextureWriteOnly, null, 0);
		mDistance = textures[0];
		mDepth = textures[1];
		FrameBuffer = bgfx.create_frame_buffer_from_handles(2, &textures, true);
		// Each entry of the first level stands for 2 x 2 pixels.
		BaseWidth = PowerOfTwo(Math.Max((width + 1) / 2, 1));
		BaseHeight = PowerOfTwo(Math.Max((height + 1) / 2, 1));
		Levels = 1;
		var w = BaseWidth;
		var h = BaseHeight;
		var total = (int)w * h;
		while (w > 1 || h > 1)
		{
			w = Math.Max(w / 2, 1);
			h = Math.Max(h / 2, 1);
			total += (int)w * h;
			Levels++;
		}
		for (int i < 2)
			mPyramids[i] = bgfx.create_dynamic_vertex_buffer((uint32)((total + 3) / 4), &GpuDriven.WordLayout, (uint16)bgfx.BufferFlags.ComputeReadWrite);
		mHasHistory = false;
		return true;
	}

	/// Whether the last finished picture can start this frame's first phase: it was drawn the frame before, at this size,
	/// from about where the camera is.
	public bool CanUseHistory(CameraData camera)
	{
		if (!mHasHistory || mFrame != Time.FrameCount - 1)
			return false;
		return (camera.position - mPosition).Length < CutDistance && Vector3.Dot(camera.forward, mForward) > CutDot;
	}

	/// Remembers the camera the picture now in the history pyramid is drawn from.
	public void SaveCamera(CameraData camera)
	{
		mView = camera.view;
		mProjection = camera.projection;
		mPosition = camera.position;
		mForward = camera.forward;
		mFrame = Time.FrameCount;
		mHasHistory = true;
	}

	public void ForgetHistory()
	{
		mHasHistory = false;
	}

	/// The pyramid of last frame's picture, for the first phase.
	public GpuOccluder History(CameraData camera)
	{
		var o = Describe(0);
		o.view = mView;
		o.projection = mProjection;
		o.near = Math.Max(camera.near, 0.001f);
		return o;
	}

	/// The pyramid of this frame's first picture, for the second phase.
	public GpuOccluder Current(CameraData camera)
	{
		var o = Describe(1);
		o.view = camera.view;
		o.projection = camera.projection;
		o.near = Math.Max(camera.near, 0.001f);
		return o;
	}

	GpuOccluder Describe(int pyramid)
	{
		GpuOccluder o = default;
		o.baseWidth = BaseWidth;
		o.baseHeight = BaseHeight;
		o.levels = Levels;
		o.width = Width;
		o.height = Height;
		o.buffer = mPyramids[pyramid];
		return o;
	}

	/// Makes the pyramid `which` (0: the history, 1: the first phase's) from the target's picture, in a compute view.
	public void Build(uint16 view, int which)
	{
		let target = mPyramids[which];
		bgfx.set_compute_dynamic_vertex_buffer(0, target, .ReadWrite, 0, uint32.MaxValue);
		bgfx.set_texture(1, GpuDriven.sDistance, mDistance, uint32.MaxValue);
		Vector4 size = .(BaseWidth, BaseHeight, Width, Height);
		bgfx.set_uniform(GpuDriven.uHzbSize, &size, 1);
		bgfx.dispatch(view, GpuDriven.HzbCopyProgram, (uint32)((BaseWidth + 7) / 8), (uint32)((BaseHeight + 7) / 8), 1, 0xff);
		var below = 0;
		var belowWidth = (int)BaseWidth;
		var belowHeight = (int)BaseHeight;
		var start = belowWidth * belowHeight;
		for (int level = 1; level < Levels; level++)
		{
			let w = Math.Max(belowWidth / 2, 1);
			let h = Math.Max(belowHeight / 2, 1);
			bgfx.set_compute_dynamic_vertex_buffer(0, target, .ReadWrite, 0, uint32.MaxValue);
			Vector4 write = .(w, h, below, start);
			Vector4 read = .(belowWidth, belowHeight, 0, 0);
			bgfx.set_uniform(GpuDriven.uHzbLevel, &write, 1);
			bgfx.set_uniform(GpuDriven.uHzbLevel2, &read, 1);
			bgfx.dispatch(view, GpuDriven.HzbReduceProgram, (uint32)((w + 7) / 8), (uint32)((h + 7) / 8), 1, 0xff);
			below = start;
			start += w * h;
			belowWidth = w;
			belowHeight = h;
		}
	}
}
