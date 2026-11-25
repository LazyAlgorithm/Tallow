using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Bgfx;

namespace Tallow;

/// --streaming-test textures: a corridor of quads, each with its own big picture, and a camera flying down it. Checks
/// that the cooked pages hold exactly the mip chains, that after the camera stops every picture on screen has the
/// level it wants, that the pool never goes over its budget (a small one, so pictures are evicted on the way), that no
/// frame uploads more than a few pages, and that pictures far away stay at their tail. Needs a window.
///
///   --streaming-test textures [--texture-count N] [--texture-size PX] [--streaming-budget tex=MB] [--streaming-test-dir path]
class TextureStreamTestApp : Application
{
	const int FlyFrames = 900;
	const int SettleFrames = 360;

	public int32 Result;

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	String mDir = new .() ~ delete _;
	int32 mCount = 96;
	int32 mSize = 1024;
	int mFrame;
	float mMaxUploadMB;
	double mMaxFrameMs;
	int64 mOverBudget;
	int32 mMaxResident;
	Stopwatch mWatch = new .() ~ delete _;
	List<String> mNames = new .() ~ DeleteContainerAndItems!(_);
	int64 mSettleStart;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Texture streaming test");
		Width = 960;
		Height = 540;
	}

	void Check(bool ok, StringView what)
	{
		if (!ok)
		{
			Result = 1;
			Console.WriteLine(scope $"streaming-test textures: FAIL {what}");
		}
	}

	/// --compare-shot file.png: screenshot of the settled view; --compare-whole: same run with texture streaming off (the whole-load
	/// path), for comparing the two pictures (M6b).
	String mShotPath = new .() ~ delete _;
	bool mWhole;

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
			StreamedTextures.Enabled = false;
		if (GetArg("--texture-count", text) && int32.Parse(text) case .Ok(let n))
			mCount = Math.Clamp(n, 4, 400);
		if (GetArg("--texture-size", text..Clear()) && int32.Parse(text) case .Ok(let s))
			mSize = Math.Clamp(s, 256, 4096);
		if (!GetArg("--streaming-test-dir", mDir))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-texstream-{mSize}");
		Directory.CreateDirectory(mDir);
		Assets.ProjectPath.Set(mDir);
		StreamedTextures.MinSize = 256;
		// Room for about a dozen pictures at the biggest level: the corridor shows more than that over its length.
		if (!GetArg("--streaming-budget", text..Clear()))
			StreamingCore.SetBudget(.TextureMip, (int64)mSize * mSize * 4 * 14);
		MakePictures();

		mScene = new Scene();
		mScene.Environment.fogDensity = 0;
		let cameraObject = mScene.CreateGameObject("Camera");
		mCameraObject = cameraObject;
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 60;
		mCamera.farClip = 600;
		let sun = mScene.CreateGameObject("Sun");
		sun.Transform.Rotation = Quaternion.Euler(40, -30, 0);
		sun.AddComponent<Light>().intensity = 1.2f;

		// Four columns of quads along z, 7 m apart.
		for (int32 i < mCount)
		{
			let quad = mScene.CreateGameObject("Quad");
			let column = i % 4;
			let row = i / 4;
			quad.Transform.Position = .((column - 1.5f) * 4.4f, 2, 8 + row * 7);
			quad.Transform.LocalScale = .(4, 4, 1);
			let renderer = quad.AddComponent<MeshRenderer>();
			renderer.mesh.Set("builtin:quad");
			let name = scope $"streamtest-{i}";
			let material = Material.Create(name);
			material.texture.Set(mNames[i]);
			material.doubleSided = true;
			material.unlit = true;
			renderer.material = name;
		}
		cameraObject.Transform.Position = .(0, 2, -4);
		mView = new RenderView(10);
		mView.CapturesReflections = false;
		mView.AllowPostAa = false;
		mScene.StartPlay();
		Console.WriteLine(scope $"streaming-test textures: {mCount} pictures of {mSize} x {mSize}, budget {StreamingCore.Pool(.TextureMip).Budget / 1048576} MB, folder {mDir}");
		return true;
	}

	void MakePictures()
	{
		for (int32 i < mCount)
		{
			let name = new String()..AppendF("tex{}.png", i);
			mNames.Add(name);
			let full = scope $"{mDir}/{name}";
			if (File.Exists(full))
				continue;
			let pixels = new uint8[mSize * mSize * 4];
			defer delete pixels;
			for (int32 y < mSize)
			{
				for (int32 x < mSize)
				{
					let o = (y * mSize + x) * 4;
					let checker = (((x >> 5) + (y >> 5)) & 1) == 0;
					pixels[o] = (uint8)((x * 255 / mSize + i * 31) & 255);
					pixels[o + 1] = (uint8)((y * 255 / mSize + i * 17) & 255);
					pixels[o + 2] = (uint8)(checker ? 220 : 40);
					pixels[o + 3] = 255;
				}
			}
			Native.tn_image_write_png(full.CStr(), pixels.CArray(), mSize, mSize);
		}
	}

	protected override void OnUpdate()
	{
		mScene.Update();
		AssetLoader.Update();
		StreamingCore.Update(mFrame);
		StreamedTextures.Update(mFrame);
		let pool = StreamingCore.Pool(.TextureMip);
		if (pool.Resident + pool.Pending > pool.Budget)
			mOverBudget++;
		mMaxUploadMB = Math.Max(mMaxUploadMB, StreamingCore.LastFrameUploadMB);
		mMaxResident = Math.Max(mMaxResident, (int32)(pool.Resident / 1048576));
	}

	protected override void OnRender()
	{
		let t = Math.Min((float)mFrame / FlyFrames, 1.0f);
		mCameraObject.Transform.Position = .(0, 2, -4 + t * (8 + (mCount / 4) * 7 - 4 - 14));
		mWatch.Restart();
		mView.Resize(960, 540);
		mView.Render(mScene, mCamera.GetCameraData(960.0f / 540.0f));
		mWatch.Stop();
		if (mFrame > 30)
			mMaxFrameMs = Math.Max(mMaxFrameMs, mWatch.Elapsed.TotalMilliseconds);
		mFrame++;
		if (mFrame >= FlyFrames + SettleFrames)
		{
			// Frames are fast and reading is not: wait until the pictures on screen have their levels (or give up).
			if (mSettleStart == 0)
				mSettleStart = Internal.GetTickCountMicro();
			if (mWhole || mShot.Started || AllSettled() || Internal.GetTickCountMicro() - mSettleStart > 30000000)
				Finish();
		}
	}

	bool AllSettled()
	{
		var settled = true;
		var visible = 0;
		StreamedTextures.ForEach(new [&] (st) =>
		{
			if (mFrame - st.LastUsed <= 2)
			{
				visible++;
				if (st.CurrentPage != st.Wanted)
					settled = false;
			}
		});
		return settled && visible > 0;
	}

	void Finish()
	{
		if (!TakeShot())
			return;
		if (mWhole)
		{
			Console.WriteLine("streaming-test textures: whole-load run done");
			Close();
			return;
		}
		let pool = StreamingCore.Pool(.TextureMip);
		var visible = 0;
		var atWanted = 0;
		var streamed = 0;
		var big = 0;
		var worstGap = 0;
		StreamedTextures.ForEach(new [&] (st) =>
		{
			streamed++;
			if (st.TopPage >= 0)
				big++;
			if (mFrame - st.LastUsed <= 2)
			{
				visible++;
				if (StreamingCore.Log)
					Console.WriteLine(scope $"  {st.Path}: wanted {st.Wanted}, page {st.CurrentPage}, requested {st.Requested}@{st.RequestedFrame}, frame {mFrame}");
				let gap = st.CurrentPage - st.Wanted;
				if (gap == 0)
					atWanted++;
				worstGap = Math.Max(worstGap, Math.Abs(gap));
			}
		});
		Console.WriteLine(scope $"streaming-test textures: {streamed} streamed, {visible} on screen, {atWanted} at their wanted level (worst gap {worstGap}), {big} above their tail");
		Console.WriteLine(scope $"streaming-test textures: resident {pool.Resident / 1048576} MB of {pool.Budget / 1048576} MB (peak {mMaxResident} MB), {pool.EvictedPages} evicted, {StreamedTextures.Swaps} swaps, {StreamedTextures.Drops} drops, {StreamingCore.Requests} requests");
		Console.WriteLine(scope $"streaming-test textures: most uploaded in a frame {mMaxUploadMB:0.0} MB, slowest frame {mMaxFrameMs:0.0} ms, latency {StreamingCore.AverageLatencyMs:0.0} ms, failures {StreamingCore.Failures}");
		Check(streamed == mCount, scope $"every picture should stream ({streamed} of {mCount})");
		Check(visible > 0 && atWanted == visible, scope $"after settling every picture on screen should be at its wanted level ({atWanted} of {visible})");
		Check(mOverBudget == 0, scope $"the pool went over its budget in {mOverBudget} frames");
		Check(pool.EvictedPages + StreamedTextures.Drops > 0 || mCount < 20, "a small budget should have made pictures give up their levels");
		Check(mMaxUploadMB < 6.0f * mSize * mSize * 4 / 1.0e6f, scope $"a frame uploaded {mMaxUploadMB:0.0} MB");
		Check(big < streamed, "pictures far away should stay at their tail");
		CheckPages();
		Console.WriteLine(Result == 0 ? "streaming-test textures: PASS" : "streaming-test textures: FAIL");
		Close();
	}

	/// The cooked pages are the mip chains the whole-load path makes.
	void CheckPages()
	{
		let st = StreamedTextures.Find(mNames[0]);
		if (st == null)
		{
			Check(false, "the first picture is not streamed");
			return;
		}
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(scope String(scope $"{mDir}/{mNames[0]}").CStr(), &width, &height);
		if (pixels == null)
		{
			Check(false, "could not read the first picture");
			return;
		}
		defer Native.tn_image_free(pixels);
		for (int32 page = 0; page <= st.TailPage; page++)
		{
			let expected = Textures.MakeMips(.(pixels, width * height * 4), width, height, st.Kind, page, let w, let h, let levels);
			defer delete expected;
			let got = scope List<uint8>();
			let ok = st.File.Read(page, got) case .Ok && expected != null && got.Count == expected.Count && Internal.MemCmp(got.Ptr, expected.Ptr, got.Count) == 0;
			Check(ok && w == st.LevelWidth(page) && levels == st.Levels - page, scope $"page {page} is not the mip chain from level {page}");
		}
	}
}
