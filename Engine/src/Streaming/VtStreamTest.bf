using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

/// --streaming-test vt: a big sphere (drawn from clusters) with one huge picture, a camera flying down to its surface and
/// along it. Checks the cooked tiles hold the picture, that the feedback pass asked for tiles and they arrived (the
/// finer levels are resident), that the cache's budget held while tiles were evicted, and that nothing failed. Needs a window.
///
///   --streaming-test vt [--vt-size PX] [--streaming-budget vt=MB] [--streaming-test-dir path]
class VtStreamTestApp : Application
{
	const int FlyFrames = 420;
	const int SlideFrames = 360;
	const int QuietFrames = 90;

	public int32 Result;

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	Mesh mMesh;
	String mDir = new .() ~ delete _;
	int32 mSize = 4096;
	int mFrame;
	int64 mOverBudget;
	int64 mLastUploads;
	int mQuietSince;
	int64 mWaitStart;
	int64 mSettleStart;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Virtual texture test");
		Width = 960;
		Height = 540;
	}

	void Check(bool ok, StringView what)
	{
		if (!ok)
		{
			Result = 1;
			Console.WriteLine(scope $"streaming-test vt: FAIL {what}");
		}
	}

	/// --compare-shot file.png: screenshot of the settled view; --compare-whole: same run with virtual textures off (the picture
	/// is loaded whole), for comparing the two pictures (M6b).
	String mShotPath = new .() ~ delete _;
	bool mWhole;
	bool mOldPath; // --compare-old (with --compare-whole): also draw the usual way, no clusters

	CompareShot mShot = new .() ~ delete _;

	bool TakeShot()
	{
		return mShotPath.IsEmpty || mShot.Step(mView, 960, 540, mShotPath);
	}

	protected override bool OnInit()
	{
		let text = scope String();
		GetArg("--compare-shot", mShotPath);
		mWhole = HasArg("--compare-whole");
		if (mWhole)
		{
			VirtualTextures.Enabled = false;
			StreamedTextures.Enabled = false;
		}
		mOldPath = mWhole && HasArg("--compare-old");
		if (GetArg("--vt-size", text) && int32.Parse(text) case .Ok(let s))
			mSize = Math.Clamp(s, 1024, 16384);
		if (!GetArg("--streaming-test-dir", mDir))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-vt-{mSize}");
		Directory.CreateDirectory(mDir);
		Assets.ProjectPath.Set(mDir);
		VirtualTextures.AutoSize = mSize;
		// A small cache (40 slots) so tiles are evicted as the camera moves.
		if (!GetArg("--streaming-budget", text..Clear()))
			StreamingCore.SetBudget(.VtTile, (int64)VirtualTextures.TileBytes * 40);
		MakePicture();

		GpuDriven.Override = mOldPath ? 0 : 1;
		GpuDriven.StatsInterval = 5;
		GpuDriven.FeedbackInterval = 2;
		GpuDriven.MinTriangles = 2000;
		mMesh = Assets.AdoptMesh("vt-stream-test", Primitives.CreateSphere(128, 64));

		mScene = new Scene();
		mScene.Environment.fogDensity = 0;
		mCameraObject = mScene.CreateGameObject("Camera");
		mCamera = mCameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 60;
		mCamera.farClip = 2000;
		let sun = mScene.CreateGameObject("Sun");
		sun.Transform.Rotation = Quaternion.Euler(40, -30, 0);
		sun.AddComponent<Light>().intensity = 1.3f;
		let ball = mScene.CreateGameObject("Ball");
		ball.Transform.LocalScale = .(60, 60, 60);
		let renderer = ball.AddComponent<MeshRenderer>();
		renderer.mesh.Set("vt-stream-test");
		let material = Material.Create("vt-stream-test");
		material.texture.Set("vt.png");
		renderer.material = "vt-stream-test";
		mCameraObject.Transform.Position = .(0, 0, -400);
		mView = new RenderView(10);
		mView.CapturesReflections = false;
		mView.AllowPostAa = false;
		mScene.StartPlay();
		Console.WriteLine(scope $"streaming-test vt: picture {mSize} x {mSize}, folder {mDir}");
		return true;
	}

	void MakePicture()
	{
		let full = scope $"{mDir}/vt.png";
		if (File.Exists(full))
			return;
		let pixels = new uint8[mSize * mSize * 4];
		defer delete pixels;
		for (int32 y < mSize)
		{
			for (int32 x < mSize)
			{
				let o = (y * mSize + x) * 4;
				let checker = (((x >> 6) + (y >> 6)) & 1) == 0;
				pixels[o] = (uint8)(x * 255 / mSize);
				pixels[o + 1] = (uint8)(y * 255 / mSize);
				pixels[o + 2] = (uint8)(checker ? 220 : 40);
				pixels[o + 3] = 255;
			}
		}
		Native.tn_image_write_png(full.CStr(), pixels.CArray(), mSize, mSize);
	}

	protected override void OnUpdate()
	{
		mScene.Update();
		AssetLoader.Update();
		StreamingCore.Update(mFrame);
		VirtualTextures.Update(mFrame);
		let pool = StreamingCore.Pool(.VtTile);
		if (pool != null && pool.Resident + pool.Pending > pool.Budget)
			mOverBudget++;
	}

	protected override void OnRender()
	{
		// The clusters are built on a worker thread: draw (the old way) until they are in the pool, then start the flight.
		if (mMesh.GpuEntry == null && !mOldPath)
		{
			if (mWaitStart == 0)
				mWaitStart = Internal.GetTickCountMicro();
			mView.Resize(960, 540);
			mView.Render(mScene, mCamera.GetCameraData(960.0f / 540.0f));
			if (Internal.GetTickCountMicro() - mWaitStart > 120000000)
				Finish();
			return;
		}
		if (mFrame < FlyFrames)
		{
			let t = (float)mFrame / FlyFrames;
			mCameraObject.Transform.Position = .(0, 0, -400 + t * (400 - 33));
		}
		else
		{
			let t = Math.Min((float)(mFrame - FlyFrames) / SlideFrames, 1.0f);
			let angle = t * 1.2f;
			mCameraObject.Transform.Position = .(0, Math.Sin(angle) * 33, -Math.Cos(angle) * 33);
			mCameraObject.Transform.Rotation = Quaternion.Euler(angle * 57.2958f, 0, 0);
		}
		mView.Resize(960, 540);
		mView.Render(mScene, mCamera.GetCameraData(960.0f / 540.0f));
		mFrame++;
		if (mFrame >= FlyFrames + SlideFrames)
		{
			if (mSettleStart == 0)
				mSettleStart = Internal.GetTickCountMicro();
			if (VirtualTextures.SlotUploads != mLastUploads)
			{
				mLastUploads = VirtualTextures.SlotUploads;
				mQuietSince = mFrame;
			}
			if (mShot.Started || mFrame - mQuietSince >= QuietFrames || Internal.GetTickCountMicro() - mSettleStart > 30000000)
				Finish();
		}
	}

	void Finish()
	{
		if (!TakeShot())
			return;
		if (mWhole)
		{
			Console.WriteLine("streaming-test vt: whole-load run done");
			Close();
			return;
		}
		let pool = StreamingCore.Pool(.VtTile);
		let vt = VirtualTextures.Find("vt.png");
		Console.WriteLine(scope $"streaming-test vt: {VirtualTextures.Count} virtual textures, {VirtualTextures.FeedbackReads} feedback reads, last read wanted {VirtualTextures.TilesWanted} tiles (finest level wanted {VirtualTextures.FinestWanted}), {VirtualTextures.SlotUploads} tile uploads, {pool.EvictedPages} evicted, {VirtualTextures.SlotsUsed} of {VirtualTextures.Slots} slots used, failures {StreamingCore.Failures}");
		Check(mMesh.GpuEntry != null, "the sphere should be drawn from clusters");
		Check(vt != null, "the picture should be a virtual texture");
		if (vt != null)
		{
			var fine = 0;
			for (int32 y < vt.TilesY[0])
			{
				for (int32 x < vt.TilesX[0])
				{
					if (vt.SlotOf[vt.PageOf(0, x, y)] >= 0)
						fine++;
				}
			}
			Console.WriteLine(scope $"streaming-test vt: {vt.Levels} levels, {vt.Resident} tiles resident, {fine} at the finest level");
			Check(fine > 0, "tiles of the finest level should be resident after flying to the surface");
			CheckTiles(vt);
		}
		Check(VirtualTextures.FeedbackReads > 0 && VirtualTextures.TilesWanted > 0, "the feedback pass should ask for tiles");
		Check(VirtualTextures.SlotUploads > 4, "tiles should have been uploaded");
		Check(pool.EvictedPages > 0, "a small cache should have evicted tiles");
		Check(VirtualTextures.SlotsUsed <= VirtualTextures.Slots && VirtualTextures.SlotsUsed >= 0, "the slots should balance");
		Check(mOverBudget == 0, scope $"the pool went over its budget in {mOverBudget} frames");
		Check(StreamingCore.Failures == 0, scope $"{StreamingCore.Failures} reads failed");
		Console.WriteLine(Result == 0 ? "streaming-test vt: PASS" : "streaming-test vt: FAIL");
		Close();
	}

	/// The cooked tiles hold the picture: a pixel in the middle of the first tile, and the one in its border.
	void CheckTiles(VirtualTexture vt)
	{
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(scope String(scope $"{mDir}/vt.png").CStr(), &width, &height);
		if (pixels == null)
		{
			Check(false, "could not read the picture");
			return;
		}
		defer Native.tn_image_free(pixels);
		Check(vt.Width == width && vt.Height == height, "the cooked size should match the picture");
		let got = scope List<uint8>();
		Check(vt.File.Read(vt.PageOf(0, 1, 1), got) case .Ok && got.Count == VirtualTextures.TileBytes, "tile (1,1) should read back");
		if (got.Count != VirtualTextures.TileBytes)
			return;
		// Tile (1,1) starts at pixel (128,128); its first inner texel is at (4,4) and its first border texel at (0,0) = pixel (124,124).
		var same = true;
		for (int c < 4)
		{
			same &= got[(4 * VirtualTextures.Physical + 4) * 4 + c] == pixels[(128 * width + 128) * 4 + c];
			same &= got[c] == pixels[(124 * width + 124) * 4 + c];
		}
		Check(same, "tile (1,1) should hold the picture's pixels, border included");
	}
}
