using System;
using Bgfx;

namespace Tallow;

/// Grabs a RenderView's finished picture and writes it as a PNG (the streaming tests' `--compare-shot`, M6b).
/// Call `Step` once per frame after the view rendered until it returns true.
class CompareShot
{
	bgfx.TextureHandle mReadback = .() { idx = uint16.MaxValue };
	uint8[] mPixels ~ delete _;
	uint32 mReady;
	int32 mWait = -1;

	public bool Started => mWait >= 0;
	/// The picture's RGBA pixels (rows top to bottom) once Step returned true.
	public uint8[] Pixels => mPixels;

	public bool Step(RenderView view, int32 width, int32 height, StringView path)
	{
		if (!mReadback.Valid)
			mReadback = bgfx.create_texture_2d((uint16)width, (uint16)height, false, 1, .RGBA8, (uint64)bgfx.TextureFlags.BlitDst | (uint64)bgfx.TextureFlags.ReadBack, null, 0);
		bgfx.TextureRegion region = default;
		region.handle = mReadback;
		region.width = (uint16)width;
		region.height = (uint16)height;
		region.depth = 1;
		if (mWait < 0)
		{
			bgfx.TextureRegion from = default;
			from.handle.idx = view.OutputTexture;
			from.width = (uint16)width;
			from.height = (uint16)height;
			from.depth = 1;
			bgfx.blit(120, &region, &from);
			mWait = 0;
		}
		mWait++;
		if (mWait == 4)
		{
			mPixels = new uint8[width * height * 4];
			Internal.MemSet(mPixels.CArray(), 0, width * height * 4);
			mReady = bgfx.read_texture(&region, mPixels.CArray());
		}
		else if (mWait > 40 && mPixels != null && bgfx.get_stats().gpuFrameNum >= mReady)
		{
			// The picture may come back with alpha 0; the PNG should be opaque.
			for (int i = 3; i < width * height * 4; i += 4)
				mPixels[i] = 255;
			Native.tn_image_write_png(scope String(path).CStr(), mPixels.CArray(), width, height);
			bgfx.destroy_texture(mReadback);
			return true;
		}
		return false;
	}
}
