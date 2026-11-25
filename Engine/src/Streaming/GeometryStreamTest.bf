using System;
using System.Collections;
using System.Diagnostics;
using Bgfx;

namespace Tallow;

/// --streaming-test geometry: one huge sphere (virtual geometry: its pages stream in through the pool) and a camera that
/// flies in to the surface, then along it, with a pool budget a fraction of the mesh. Checks that the mesh really streams
/// in pages, that the pool never goes over its budget, that pages are asked for and some are evicted, that the picture
/// has no holes (the culling always has clusters to draw) and that, once the camera stops, no group it wants is missing.
/// Needs a window.
///
///   --streaming-test geometry [--geometry-segments N] [--streaming-budget geo=MB]
class GeometryStreamTestApp : Application
{
	const int FlyFrames = 400;
	const int SlideFrames = 400;
	const int SettleFrames = 200;

	public int32 Result;

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	Mesh mMesh;
	int mFrame;
	int32 mSegments = 700;
	int64 mOverBudget;
	int64 mEmptyFrames;
	int64 mPeakResident;
	int64 mSettleStart;
	int64 mWaitStart;
	int mTotalBytes;
	int mPageCount;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Geometry streaming test");
		Width = 960;
		Height = 540;
	}

	void Check(bool ok, StringView what)
	{
		if (!ok)
		{
			Result = 1;
			Console.WriteLine(scope $"streaming-test geometry: FAIL {what}");
		}
	}

	protected override bool OnInit()
	{
		let text = scope String();
		if (GetArg("--geometry-segments", text) && int32.Parse(text) case .Ok(let n))
			mSegments = Math.Clamp(n, 128, 2000);
		GpuDriven.Override = 1;
		GpuDriven.StatsInterval = 5;
		GpuDriven.FeedbackInterval = 2;
		GpuDriven.MinTriangles = 2000;
		let mesh = Primitives.CreateSphere(mSegments, mSegments / 2);
		mMesh = Assets.AdoptMesh("geometry-stream-test", mesh);
		Console.WriteLine(scope $"streaming-test geometry: sphere of {mMesh.Indices.Count / 3} triangles");

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
		renderer.mesh.Set("geometry-stream-test");
		renderer.color = .(0.8f, 0.6f, 0.4f);
		mCameraObject.Transform.Position = .(0, 0, -400);
		mView = new RenderView(10);
		mView.CapturesReflections = false;
		mView.AllowPostAa = false;
		mScene.StartPlay();
		return true;
	}

	protected override void OnUpdate()
	{
		mScene.Update();
		AssetLoader.Update();
		StreamingCore.Update(mFrame);
		let pool = StreamingCore.Pool(.GeoPage);
		if (pool != null)
		{
			if (pool.Resident + pool.Pending > pool.Budget)
				mOverBudget++;
			mPeakResident = Math.Max(mPeakResident, pool.Resident);
		}
	}

	protected override void OnRender()
	{
		// The hierarchy is built on a worker thread: draw (the old way) until it is in the pool, then start the flight.
		if (mMesh.GpuEntry == null)
		{
			if (mWaitStart == 0)
				mWaitStart = Internal.GetTickCountMicro();
			mView.Resize(960, 540);
			mView.Render(mScene, mCamera.GetCameraData(960.0f / 540.0f));
			if (Internal.GetTickCountMicro() - mWaitStart > 120000000)
				Finish();
			return;
		}
		// In from far away to 6 m above the surface, then along it.
		if (mFrame < FlyFrames)
		{
			let t = (float)mFrame / FlyFrames;
			mCameraObject.Transform.Position = .(0, 0, -400 + t * (400 - 66));
		}
		else
		{
			let t = Math.Min((float)(mFrame - FlyFrames) / SlideFrames, 1.0f);
			let angle = t * 2.5f;
			mCameraObject.Transform.Position = .(0, Math.Sin(angle) * 66, -Math.Cos(angle) * 66);
			mCameraObject.Transform.Rotation = Quaternion.Euler(angle * 57.2958f, 0, 0);
		}
		mView.Resize(960, 540);
		mView.Render(mScene, mCamera.GetCameraData(960.0f / 540.0f));
		mFrame++;
		if (mFrame > 5 && mMesh.GpuEntry != null && mTotalBytes == 0)
		{
			let pages = mMesh.GpuEntry.pages;
			mPageCount = pages.PageCount;
			for (int i < pages.PageCount)
				mTotalBytes += pages.PageBytesOf[i];
			// A pool a fraction of the mesh (unless the command line chose).
			if (GpuDriven.StreamedMeshes > 0 && !HasArg("--streaming-budget"))
				StreamingCore.SetBudget(.GeoPage, (int64)Math.Max(mTotalBytes / 32, 7 << 17));
		}
		if (mFrame > 120 && GpuDriven.Triangles <= 0)
			mEmptyFrames++;
		if (mFrame >= FlyFrames + SlideFrames + SettleFrames)
		{
			if (mSettleStart == 0)
			{
				mSettleStart = Internal.GetTickCountMicro();
				// A pool this small thrashes at the end of the slide; with room the view settles.
				if (!HasArg("--streaming-budget"))
					StreamingCore.SetBudget(.GeoPage, (int64)Math.Max(mTotalBytes / 8, 4 << 20));
			}
			if (GpuDriven.GroupsMissing == 0 || Internal.GetTickCountMicro() - mSettleStart > 20000000)
				Finish();
		}
	}

	void Finish()
	{
		let pool = StreamingCore.Pool(.GeoPage);
		Console.WriteLine(scope $"streaming-test geometry: {mPageCount} pages, {mTotalBytes / 1048576} MB cooked, budget {pool.Budget / 1048576} MB, peak resident {mPeakResident / 1048576} MB");
		Console.WriteLine(scope $"streaming-test geometry: {GpuDriven.PagesRequested} pages asked for, {pool.EvictedPages} evicted, {GpuDriven.FeedbackReads} feedback reads, {GpuDriven.GroupsMissing} groups missing, {GpuDriven.Triangles} triangles drawn, failures {StreamingCore.Failures}");
		Check(mMesh.GpuEntry != null && GpuDriven.StreamedMeshes == 1, "the sphere should stream its pages");
		Check(mPageCount > ClusterPages.WholeMeshPages, scope $"too few pages ({mPageCount})");
		Check(mOverBudget == 0, scope $"the pool went over its budget in {mOverBudget} frames");
		Check(GpuDriven.PagesRequested > 0 && GpuDriven.FeedbackReads > 0, "the culling's feedback should ask for pages");
		Check(pool.EvictedPages > 0, "a pool a thirty-second of the mesh should have evicted pages");
		Check(mEmptyFrames == 0, scope $"{mEmptyFrames} frames drew nothing (holes)");
		Check(GpuDriven.GroupsMissing == 0, scope $"{GpuDriven.GroupsMissing} wanted groups still missing after settling");
		Check(StreamingCore.Failures == 0, "reads failed");
		Console.WriteLine(Result == 0 ? "streaming-test geometry: PASS" : "streaming-test geometry: FAIL");
		Close();
	}
}
