using System;
using System.Collections;
using System.Diagnostics;
using Bgfx;

namespace Tallow;

/// --gpu-driven-test [mesh]: a crowd of a big mesh (a thousand copies of a sphere of about 200 000 triangles by default;
/// "sphere:<segments>x<rings>" or a model file otherwise) with a floor, a sun with shadows and a few small old-path
/// objects, drawn the usual way and then from clusters picked on the graphics card, from the same camera. The two
/// pictures are compared (no missing objects or holes; the level of detail may differ a little), the timings and counts
/// printed, and the exit code is 0 when the check passed and 1 when it did not. Needs a window and Vulkan or Metal.
///
///   --gpu-driven-test [mesh] [--quality ultra]  (the quality's antialiasing and screen effects take part, TAA included)
///   --gpu-driven-instances N                    how many copies (1024)
///   --gpu-driven-save prefix                    keep the pictures as prefix-old.png, prefix-new.png, prefix-empty.png
///
/// After that comparison, three more checks run on the GPU-driven path: an occlusion scene (a wall of a big mesh in front
/// of the crowd; clusters and the card's time with occlusion on and off, and a camera path, with a cut in it, drawn both ways
/// and compared frame by frame: whatever occlusion leaves out must not show), and a point light's shadow tiles drawn from
/// clusters against the usual way.
class GpuDrivenTestApp : Application
{
	enum Stage
	{
		Building,
		OldWarm,
		OldTime,
		OldShot,
		NewWarm,
		NewTime,
		NewShot,
		EmptyShot,
		OccSetup,
		OccWarm,
		OccOn,
		OccOffWarm,
		OccOff,
		PathOn,
		PathOff,
		PathRead,
		TileSetup,
		TileOnShot,
		TileOffShot,
		Done
	}

	const int Size = 640;
	const int WarmFrames = 20;
	const int TimedFrames = 60;

	/// 0 when the check passed.
	public int32 Result;

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	List<GameObject> mCrowd = new .() ~ delete _;
	Mesh mCrowdMesh;
	Stage mStage = .Building;
	int mStageFrames;
	int64 mStartTime;
	String mMeshArg = new .("sphere:320x320") ~ delete _;
	String mSavePrefix = new .() ~ delete _;
	int32 mInstances = 1024;

	bgfx.TextureHandle mReadback = .() { idx = uint16.MaxValue };
	uint8[] mOld ~ delete _;
	uint8[] mNew ~ delete _;
	uint8[] mEmpty ~ delete _;
	uint8[] mShot ~ delete _;
	int mShotWait;
	uint32 mShotReady;

	struct Timing
	{
		public double cpuMs, renderMs, gpuMs;
		public int32 draws, computes;
		public int64 instances, triangles;
	}
	Timing mOldTiming, mNewTiming, mOccOnTiming, mOccOffTiming;
	/// What the culling counted in the occlusion scene, with occlusion on and off.
	int64 mOccOnClusters, mOccOnTriangles, mOccOnFirst, mOccOnSecond, mOccOnDeferred, mOccOnDeferredInstances;
	int64 mOccOffClusters, mOccOffTriangles;
	const int PathFrames = 28;
	bgfx.TextureHandle[PathFrames * 2] mRing;
	List<uint8[]> mRingPixels = new .() ~ DeleteContainerAndItems!(_);
	uint32 mRingReady;
	bool mRingAsked;
	int32[PathFrames] mPathDifferent;
	int32[PathFrames] mPathCovered;
	uint8[] mTileOn ~ delete _;
	uint8[] mTileOff ~ delete _;
	GameObject mWall;
	GameObject mCameraObject;
	GameObject mPointLight;
	Stopwatch mFrameWatch = new .() ~ delete _;
	double mCpuSum, mRenderSum, mGpuSum;
	int mGpuSamples;
	int32 mDrawSum, mComputeSum;
	int64 mInstanceSum, mTriangleSum;
	bool mVsyncOff;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("GPU-driven drawing test");
		Width = 1280;
		Height = 720;
	}

	protected override bool OnInit()
	{
		GetArg("--gpu-driven-test", mMeshArg);
		if (mMeshArg.StartsWith("--") || mMeshArg.IsEmpty)
			mMeshArg.Set("sphere:320x320");
		let count = scope String();
		if (GetArg("--gpu-driven-instances", count) && int32.Parse(count) case .Ok(let n))
			mInstances = Math.Clamp(n, 1, 20000);
		GetArg("--gpu-driven-save", mSavePrefix);
		// The command line's own on/off must not decide this: the test turns it on and off itself.
		GpuDriven.Override = 0;
		GpuDriven.StatsInterval = 5;

		Mesh mesh = null;
		if (mMeshArg.StartsWith("sphere:"))
		{
			let dims = StringView(mMeshArg, 7);
			let x = dims.IndexOf('x');
			if (x > 0 && int32.Parse(dims.Substring(0, x)) case .Ok(let segments) && int32.Parse(dims.Substring(x + 1)) case .Ok(let rings))
				mesh = Primitives.CreateSphere(segments, rings);
		}
		else
			mesh = Assets.BuildModel(mMeshArg);
		if (mesh == null || mesh.Indices.Count < 3)
		{
			Console.WriteLine(scope $"gpu-driven-test: no mesh to draw from '{mMeshArg}'");
			Result = 1;
			return false;
		}
		mCrowdMesh = Assets.AdoptMesh("gpu-driven-test-crowd", mesh);
		Console.WriteLine(scope $"gpu-driven-test: {mInstances} x {mMeshArg} ({mCrowdMesh.Indices.Count / 3} triangles each), window {Width} x {Height}, scene {Size} x {Size}");

		mScene = new Scene();
		mScene.Environment.fogDensity = 0;
		let cameraObject = mScene.CreateGameObject("Camera");
		mCameraObject = cameraObject;
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 50;
		mCamera.farClip = 400;

		let sun = mScene.CreateGameObject("Sun");
		sun.Transform.Rotation = Quaternion.Euler(52, -35, 0);
		let light = sun.AddComponent<Light>();
		light.castShadows = true;
		light.intensity = 1.4f;

		let floor = mScene.CreateGameObject("Floor");
		floor.Transform.Position = .(0, -1.2f, 0);
		floor.Transform.LocalScale = .(140, 1, 140);
		let floorRenderer = floor.AddComponent<MeshRenderer>();
		floorRenderer.mesh.Set("builtin:plane");
		floorRenderer.color = .(0.55f, 0.6f, 0.5f);

		// The crowd: a grid of spheres, in two kinds of surface (flat shaded ones are a bin of their own).
		let side = (int32)Math.Ceiling(Math.Sqrt((float)mInstances));
		let spacing = 2.4f;
		for (int32 i < mInstances)
		{
			let ix = i % side;
			let iz = i / side;
			let ball = mScene.CreateGameObject("Ball");
			ball.Transform.Position = .((ix - side * 0.5f) * spacing, 0, iz * spacing);
			ball.Transform.LocalScale = Vector3(0.9f + (i % 5) * 0.12f, 0.9f + (i % 3) * 0.1f, 1.1f - (i % 4) * 0.08f);
			let renderer = ball.AddComponent<MeshRenderer>();
			renderer.mesh.Set("gpu-driven-test-crowd");
			renderer.color = .(0.35f + 0.65f * ((i * 37) % 11) / 10.0f, 0.35f + 0.65f * ((i * 17) % 7) / 6.0f, 0.4f + 0.6f * ((i * 53) % 5) / 4.0f);
			renderer.metallic = (i % 9 == 0) ? 0.8f : 0;
			renderer.roughness = 0.4f + (i % 4) * 0.15f;
			renderer.flatShading = i % 7 == 0;
			mCrowd.Add(ball);
		}

		// A few objects of the usual path (small meshes): they must stay as they are in both pictures.
		StringView[5] small = .("builtin:cube", "builtin:capsule", "builtin:cylinder", "builtin:cone", "builtin:sphere");
		for (int i < 5)
		{
			let piece = mScene.CreateGameObject("Small");
			piece.Transform.Position = .(-6.0f + i * 3.0f, 0, -3.5f);
			piece.Transform.LocalScale = .(1.5f, 1.5f, 1.5f);
			let renderer = piece.AddComponent<MeshRenderer>();
			renderer.mesh.Set(small[i]);
			renderer.color = .(0.9f, 0.3f + 0.15f * i, 0.2f);
		}

		cameraObject.Transform.Position = .(0, 14, -22);
		cameraObject.Transform.Rotation = Quaternion.Euler(24, 0, 0);

		mView = new RenderView(10);
		mView.CapturesReflections = false;
		mView.AllowPostAa = false;
		mScene.StartPlay();
		bgfx.set_debug((uint32)bgfx.DebugFlags.Profiler, .() { idx = uint16.MaxValue }, 0);
		mStartTime = Internal.GetTickCountMicro();
		return true;
	}

	protected override void OnUpdate()
	{
		if (!mVsyncOff)
		{
			// Frames as fast as they go, so that the timings mean something.
			Gfx.SetVsync(false);
			mVsyncOff = true;
		}
		mScene.Update();
		StreamingCore.Update((int)Time.FrameCount);
	}

	protected override void OnRender()
	{
		let camera = mCamera;
		PosePath();
		mView.Resize(Size, Size);
		mFrameWatch.Restart();
		mView.Render(mScene, camera.GetCameraData(1.0f));
		mFrameWatch.Stop();
		let renderMs = mFrameWatch.Elapsed.TotalMilliseconds;
		CapturePath();
		mStageFrames++;

		switch (mStage)
		{
		case .Building:
			if (!GpuDriven.Available)
			{
				Console.WriteLine("gpu-driven-test: FAIL: the graphics card or backend cannot draw this way (see above)");
				Fail();
				return;
			}
			// The usual path draws until the clusters are built.
			GpuDriven.Lookup(mCrowdMesh);
			GpuDriven.Update();
			if (mCrowdMesh.GpuEntry != null)
			{
				let seconds = (Internal.GetTickCountMicro() - mStartTime) / 1000000.0;
				Console.WriteLine(scope $"gpu-driven-test: clusters built after {seconds:0.0} s ({GpuDriven.BuildMilliseconds} ms of building, {mCrowdMesh.GpuEntry.clusterCount} clusters, pool {GpuDriven.PoolWords * 4 / 1048576} MB)");
				Next(.OldWarm);
			}
			else if (mCrowdMesh.GpuFailed || (Internal.GetTickCountMicro() - mStartTime) > 180000000)
			{
				Console.WriteLine("gpu-driven-test: FAIL: the clusters were not built");
				Fail();
			}
		case .OldWarm:
			GpuDriven.Override = 0;
			if (mStageFrames >= WarmFrames)
				Next(.OldTime);
		case .OldTime:
			Sample(renderMs);
			if (mStageFrames >= TimedFrames)
			{
				mOldTiming = Average();
				Next(.OldShot);
			}
		case .OldShot:
			if (Shoot(ref mOld))
				Next(.NewWarm);
		case .NewWarm:
			GpuDriven.Override = 1;
			if (mStageFrames >= WarmFrames)
				Next(.NewTime);
		case .NewTime:
			Sample(renderMs);
			if (mStageFrames >= TimedFrames)
			{
				mNewTiming = Average();
				Next(.NewShot);
			}
		case .NewShot:
			if (Shoot(ref mNew))
			{
				for (let ball in mCrowd)
					ball.SetActive(false);
				Next(.EmptyShot);
			}
		case .EmptyShot:
			if (Shoot(ref mEmpty))
				Next(.OccSetup);
		case .OccSetup:
			SetUpOcclusion();
			Next(.OccWarm);
		case .OccWarm:
			if (mStageFrames >= WarmFrames + 10)
				Next(.OccOn);
		case .OccOn:
			Sample(renderMs);
			if (mStageFrames >= TimedFrames)
			{
				mOccOnTiming = Average();
				mOccOnClusters = GpuDriven.Clusters;
				mOccOnTriangles = GpuDriven.Triangles;
				mOccOnFirst = GpuDriven.ClustersFirst;
				mOccOnSecond = GpuDriven.ClustersSecond;
				mOccOnDeferred = GpuDriven.DeferredClusters;
				mOccOnDeferredInstances = GpuDriven.DeferredInstances;
				GpuDriven.Occlusion = false;
				Next(.OccOffWarm);
			}
		case .OccOffWarm:
			if (mStageFrames >= WarmFrames + 10)
				Next(.OccOff);
		case .OccOff:
			Sample(renderMs);
			if (mStageFrames >= TimedFrames)
			{
				mOccOffTiming = Average();
				mOccOffClusters = GpuDriven.Clusters;
				mOccOffTriangles = GpuDriven.Triangles;
				GpuDriven.Occlusion = true;
				Next(.PathOn);
			}
		case .PathOn:
			if (mStageFrames >= PathWarm + PathFrames)
			{
				GpuDriven.Occlusion = false;
				Next(.PathOff);
			}
		case .PathOff:
			if (mStageFrames >= PathWarm + PathFrames)
				Next(.PathRead);
		case .PathRead:
			if (ReadPath())
				Next(.TileSetup);
		case .TileSetup:
			SetUpTiles();
			Next(.TileOnShot);
		case .TileOnShot:
			if (mStageFrames == 1)
			{
				GpuDriven.LocalShadows = true;
				GpuDriven.Occlusion = true;
			}
			if (mStageFrames > WarmFrames && Shoot(ref mTileOn))
				Next(.TileOffShot);
		case .TileOffShot:
			if (mStageFrames == 1)
				GpuDriven.LocalShadows = false;
			if (mStageFrames > WarmFrames && Shoot(ref mTileOff))
				Next(.Done);
		case .Done:
			Finish();
		}
	}

	// ---- the occlusion scene, the camera path and the shadow tiles

	/// Frames the path stays at its first pose before it starts (so that the culling has a picture of last frame to start from).
	const int PathWarm = 6;
	Mesh mWallMesh;

	/// Where the camera is at step `k` of the path: across the crowd behind the wall, with a cut half way (the camera jumps
	/// further than the culling trusts last frame's picture).
	void PathPose(int k)
	{
		let t = (float)k / (PathFrames - 1);
		var x = -12.0f + 24.0f * t;
		var z = -18.0f;
		let y = 6.5f + 1.5f * Math.Sin(t * 6.2831853f);
		if (k >= PathFrames / 2)
		{
			x += 30.0f;
			z -= 6.0f;
		}
		mCameraObject.Transform.Position = .(x, y, z);
		mCameraObject.Transform.Rotation = Quaternion.Euler(9, Math.Sin(t * 6.2831853f) * 8.0f, 0);
	}

	/// Puts the camera where this stage wants it, before the frame is drawn.
	void PosePath()
	{
		switch (mStage)
		{
		case .OccSetup, .OccWarm, .OccOn, .OccOffWarm, .OccOff, .TileSetup, .TileOnShot, .TileOffShot:
			PathPose(0);
		case .PathOn, .PathOff:
			PathPose(Math.Max(mStageFrames - PathWarm, 0));
		default:
		}
	}

	/// After the frame is drawn: keeps its picture when it is a step of the path.
	void CapturePath()
	{
		if (mStage != .PathOn && mStage != .PathOff)
			return;
		let k = mStageFrames - PathWarm;
		if (k < 0 || k >= PathFrames)
			return;
		let index = (mStage == .PathOn ? 0 : PathFrames) + k;
		if (!mRing[index].Valid)
			mRing[index] = bgfx.create_texture_2d(Size, Size, false, 1, .RGBA8, (uint64)bgfx.TextureFlags.BlitDst | (uint64)bgfx.TextureFlags.ReadBack, null, 0);
		bgfx.TextureRegion region = default;
		region.handle = mRing[index];
		region.width = Size;
		region.height = Size;
		region.depth = 1;
		bgfx.TextureRegion from = default;
		from.handle.idx = mView.OutputTexture;
		from.width = Size;
		from.height = Size;
		from.depth = 1;
		bgfx.blit(120, &region, &from);
	}

	void SetUpOcclusion()
	{
		for (let ball in mCrowd)
			ball.SetActive(true);
		// A wall of a big mesh (the GPU-driven path draws it, so it hides the rows behind it).
		mWallMesh = Assets.AdoptMesh("gpu-driven-test-wall", Primitives.CreateSphere(120, 70));
		mWall = mScene.CreateGameObject("Wall");
		if (HasArg("--no-wall"))
			mWall.SetActive(false);
		mWall.Transform.Position = .(0, 2.0f, -3.0f);
		mWall.Transform.LocalScale = .(60, 6.0f, 1.5f);
		let renderer = mWall.AddComponent<MeshRenderer>();
		renderer.mesh.Set("gpu-driven-test-wall");
		renderer.color = .(0.6f, 0.58f, 0.55f);
		mCamera.occlusionCulling = true;
		GpuDriven.Override = 1;
		GpuDriven.Occlusion = true;
	}

	void SetUpTiles()
	{
		mPointLight = mScene.CreateGameObject("Lamp");
		mPointLight.Transform.Position = .(0, 5.0f, 9.0f);
		let light = mPointLight.AddComponent<Light>();
		light.type = .Point;
		light.range = 45;
		light.intensity = 40;
		light.color = .(1.0f, 0.8f, 0.6f);
		light.castShadows = true;
		GpuDriven.Override = 1;
	}

	/// Asks for every picture of the path, then compares each step drawn with occlusion to the same step drawn without.
	bool ReadPath()
	{
		if (!mRingAsked)
		{
			for (int i < PathFrames * 2)
			{
				if (!mRing[i].Valid)
				{
					Console.WriteLine("gpu-driven-test: FAIL: a step of the path was not captured");
					Result = 1;
					mRingAsked = true;
					return true;
				}
				mRingPixels.Add(new uint8[Size * Size * 4]);
				bgfx.TextureRegion region = default;
				region.handle = mRing[i];
				region.width = Size;
				region.height = Size;
				region.depth = 1;
				mRingReady = Math.Max(mRingReady, bgfx.read_texture(&region, mRingPixels[i].CArray()));
			}
			mRingAsked = true;
			return false;
		}
		if (mRingPixels.Count == 0)
			return true;
		if (mStageFrames < 6 || bgfx.get_stats().gpuFrameNum < mRingReady)
			return false;
		for (int k < PathFrames)
		{
			var different = 0;
			var covered = 0;
			let on = mRingPixels[k];
			let off = mRingPixels[PathFrames + k];
			for (int p < Size * Size)
			{
				if (Differs(on, off, p * 4, 10))
					different++;
				if (off[p * 4] != off[0] || off[p * 4 + 1] != off[1] || off[p * 4 + 2] != off[2])
					covered++;
			}
			mPathDifferent[k] = (int32)different;
			mPathCovered[k] = (int32)covered;
		}
		if (!mSavePrefix.IsEmpty)
		{
			for (let k in int[?](0, 9, 13, 14, PathFrames - 1))
			{
				Save(mRingPixels[k], scope $"{mSavePrefix}-path{k}-occluded.png");
				Save(mRingPixels[PathFrames + k], scope $"{mSavePrefix}-path{k}-plain.png");
			}
		}
		return true;
	}

	void Next(Stage stage)
	{
		mStage = stage;
		mStageFrames = 0;
		mCpuSum = mRenderSum = mGpuSum = 0;
		mGpuSamples = 0;
		mDrawSum = mComputeSum = 0;
		mInstanceSum = mTriangleSum = 0;
		mShotWait = 0;
	}

	void Fail()
	{
		Result = 1;
		Close();
		mStage = .Done;
	}

	void Sample(double renderMs)
	{
		let stats = bgfx.get_stats();
		mRenderSum += renderMs;
		if (stats.cpuTimerFreq > 0)
			mCpuSum += (double)(stats.cpuTimeEnd - stats.cpuTimeBegin) * 1000.0 / stats.cpuTimerFreq;
		if (stats.gpuTimerFreq > 0 && stats.gpuTimeEnd > stats.gpuTimeBegin)
		{
			mGpuSum += (double)(stats.gpuTimeEnd - stats.gpuTimeBegin) * 1000.0 / stats.gpuTimerFreq;
			mGpuSamples++;
		}
		mDrawSum += (int32)stats.numDraw;
		mComputeSum += (int32)stats.numCompute;
		for (let count in stats.numPrims)
			mTriangleSum += count;
	}

	Timing Average()
	{
		Timing t = default;
		t.renderMs = mRenderSum / TimedFrames;
		t.cpuMs = mCpuSum / TimedFrames;
		t.gpuMs = mGpuSamples > 0 ? mGpuSum / mGpuSamples : 0;
		t.draws = mDrawSum / TimedFrames;
		t.computes = mComputeSum / TimedFrames;
		t.triangles = mTriangleSum / TimedFrames;
		return t;
	}

	/// Copies the finished picture out of the view and reads it back, a few frames later. True when `pixels` has it.
	bool Shoot(ref uint8[] pixels)
	{
		if (!mReadback.Valid)
			mReadback = bgfx.create_texture_2d(Size, Size, false, 1, .RGBA8, (uint64)bgfx.TextureFlags.BlitDst | (uint64)bgfx.TextureFlags.ReadBack, null, 0);
		bgfx.TextureRegion region = default;
		region.handle = mReadback;
		region.width = Size;
		region.height = Size;
		region.depth = 1;
		if (mShotWait == 0)
		{
			bgfx.TextureRegion from = default;
			from.handle.idx = mView.OutputTexture;
			from.width = Size;
			from.height = Size;
			from.depth = 1;
			bgfx.blit(120, &region, &from);
		}
		mShotWait++;
		if (mShotWait == 4)
		{
			DeleteAndNullify!(mShot);
			mShot = new uint8[Size * Size * 4];
			Internal.MemSet(mShot.CArray(), 0, Size * Size * 4);
			mShotReady = bgfx.read_texture(&region, mShot.CArray());
		}
		else if (mShotWait > 40 && bgfx.get_stats().gpuFrameNum >= mShotReady)
		{
			delete pixels;
			pixels = mShot;
			mShot = null;
			return true;
		}
		return false;
	}

	/// Compares the pictures, prints the numbers and ends the run.
	void Finish()
	{
		Close();
		mStage = .Done;
		if (mOld == null || mNew == null || mEmpty == null || mTileOn == null || mTileOff == null)
		{
			Result = 1;
			return;
		}
		if (!mSavePrefix.IsEmpty)
		{
			Save(mOld, scope $"{mSavePrefix}-old.png");
			Save(mNew, scope $"{mSavePrefix}-new.png");
			Save(mEmpty, scope $"{mSavePrefix}-empty.png");
		}
		// Covered: the pixels the crowd changes from the same scene without it. A coarser level of detail moves a silhouette
		// in by up to a few pixels, so a pixel is a hole when the other picture has nothing covered within three pixels.
		let oldMask = new bool[Size * Size];
		let newMask = new bool[Size * Size];
		defer { delete oldMask; delete newMask; }
		for (int p < Size * Size)
		{
			oldMask[p] = Differs(mOld, mEmpty, p * 4, 12);
			newMask[p] = Differs(mNew, mEmpty, p * 4, 12);
		}
		let oldNear = Dilate(oldMask, 3);
		let newNear = Dilate(newMask, 3);
		defer { delete oldNear; delete newNear; }
		int64 oldCovered = 0, newCovered = 0, holes = 0, extra = 0, both = 0, bigDifferences = 0;
		double difference = 0;
		for (int p < Size * Size)
		{
			let at = p * 4;
			let oldChanged = oldMask[p];
			let newChanged = newMask[p];
			if (oldChanged) oldCovered++;
			if (newChanged) newCovered++;
			if (oldChanged && !newNear[p]) holes++;
			if (newChanged && !oldNear[p]) extra++;
			if (oldChanged && newChanged)
			{
				both++;
				var sum = 0;
				for (int c < 3)
					sum += Math.Abs((int)mOld[at + c] - (int)mNew[at + c]);
				difference += sum / 3.0;
				if (sum / 3 > 40)
					bigDifferences++;
			}
		}
		let meanDifference = both > 0 ? difference / both : 0;
		Console.WriteLine("gpu-driven-test: timings per frame (ms)       old path     GPU-driven");
		Console.WriteLine(scope $"  CPU, view.Render call                 {mOldTiming.renderMs,10:0.00}     {mNewTiming.renderMs,10:0.00}");
		Console.WriteLine(scope $"  CPU, bgfx frame                       {mOldTiming.cpuMs,10:0.00}     {mNewTiming.cpuMs,10:0.00}");
		Console.WriteLine(scope $"  GPU                                   {mOldTiming.gpuMs,10:0.00}     {mNewTiming.gpuMs,10:0.00}");
		Console.WriteLine(scope $"  draw calls                            {mOldTiming.draws,10}     {mNewTiming.draws,10}");
		Console.WriteLine(scope $"  compute dispatches                    {mOldTiming.computes,10}     {mNewTiming.computes,10}");
		Console.WriteLine(scope $"  triangles (bgfx, all passes)          {mOldTiming.triangles,10}     {mNewTiming.triangles,10}");
		Console.WriteLine(scope $"gpu-driven-test: GPU-driven: {GpuDriven.Clusters} clusters, {GpuDriven.Triangles} triangles drawn in the scene, {GpuDriven.ClustersLost} clusters and {GpuDriven.NodesLost} nodes over budget, {RenderView.InstancesDropped} instances dropped");
		Console.WriteLine(scope $"gpu-driven-test: covered pixels: old {oldCovered}, new {newCovered}; holes {holes}, extra {extra}; mean colour difference {meanDifference:0.00} / 255 over {both}, {bigDifferences} pixels over 40");

		var failures = 0;
		void Check(bool ok, StringView text)
		{
			if (!ok)
			{
				Console.WriteLine(scope $"gpu-driven-test: FAIL: {text}");
				failures++;
			}
		}
		Check(oldCovered > Size * Size / 20, "the crowd covers hardly anything: the scene is not what the test expects");
		Check(mNewTiming.computes > 0, "no compute dispatches in the GPU-driven frames: the path was not used");
		Check(mNewTiming.triangles < mOldTiming.triangles, "no fewer triangles drawn with the GPU-driven path");
		Check(mOldTiming.gpuMs <= 0 || mNewTiming.gpuMs < mOldTiming.gpuMs, "the graphics card takes longer with the GPU-driven path");
		Check(holes * 400 <= oldCovered, scope $"holes: {holes} pixels the old path draws and the GPU-driven path does not");
		Check(extra * 400 <= oldCovered, scope $"extra: {extra} pixels only the GPU-driven path draws");
		let slack = mMeshArg.StartsWith("sphere:") ? 1.0 : 3.0;
		Check(meanDifference < 12.0 * slack, scope $"the pictures differ by {meanDifference:0.00} / 255 on average");
		Check(bigDifferences * 10 <= both * slack, scope $"{bigDifferences} pixels differ a lot");

		// The occlusion scene.
		Console.WriteLine(scope $"gpu-driven-test: occlusion scene (a wall in front of the crowd), per frame           occlusion on     off");
		Console.WriteLine(scope $"  clusters drawn in the scene                {mOccOnClusters,10}     {mOccOffClusters,10}   (first phase {mOccOnFirst}, second {mOccOnSecond}; put off by the first: {mOccOnDeferred} clusters of {mOccOnDeferredInstances} instances)");
		Console.WriteLine(scope $"  triangles drawn in the scene               {mOccOnTriangles,10}     {mOccOffTriangles,10}");
		Console.WriteLine(scope $"  GPU (ms)                                   {mOccOnTiming.gpuMs,10:0.00}     {mOccOffTiming.gpuMs,10:0.00}");
		Console.WriteLine(scope $"  CPU, view.Render call (ms)                 {mOccOnTiming.renderMs,10:0.00}     {mOccOffTiming.renderMs,10:0.00}");
		Console.WriteLine(scope $"  compute dispatches / draw calls            {mOccOnTiming.computes,5}/{mOccOnTiming.draws,-5}     {mOccOffTiming.computes,5}/{mOccOffTiming.draws,-5}");
		Check(mOccOffClusters > 0 && mOccOnClusters * 10 < mOccOffClusters * 9, "occlusion left out fewer than a tenth of the clusters");
		Check(mOccOnTiming.computes > mOccOffTiming.computes, "no extra compute dispatches with occlusion on: it was not used");
		var worst = 0;
		var total = 0;
		var worstAt = 0;
		for (int k < PathFrames)
		{
			total += mPathDifferent[k];
			if (mPathDifferent[k] > worst)
			{
				worst = mPathDifferent[k];
				worstAt = k;
			}
		}
		Console.WriteLine(scope $"gpu-driven-test: camera path of {PathFrames} frames (a cut at {PathFrames / 2}), drawn with occlusion and without, compared pixel by pixel: {total} pixels differ in all, at most {worst} in a frame (frame {worstAt}), covered pixels in the middle frame {mPathCovered[PathFrames / 2]}");
		var line = scope String("  differing pixels per frame:");
		for (int k < PathFrames)
			line.AppendF(" {}", mPathDifferent[k]);
		Console.WriteLine(line);
		Check(worst * 2000 <= Size * Size, scope $"popping: {worst} pixels differ in one frame between the occluded and the plain picture");

		// The shadow tiles of a point light.
		if (!mSavePrefix.IsEmpty)
		{
			Save(mTileOn, scope $"{mSavePrefix}-tiles-gpu.png");
			Save(mTileOff, scope $"{mSavePrefix}-tiles-usual.png");
		}
		var tileBig = 0;
		var tileSum = 0.0;
		for (int p < Size * Size)
		{
			var sum = 0;
			for (int c < 3)
				sum += Math.Abs((int)mTileOn[p * 4 + c] - (int)mTileOff[p * 4 + c]);
			tileSum += sum / 3.0;
			if (sum / 3 > 40)
				tileBig++;
		}
		Console.WriteLine(scope $"gpu-driven-test: point light shadow tiles from clusters against the usual way: mean difference {tileSum / (Size * Size):0.00} / 255, {tileBig} pixels over 40");
		Check(tileBig * 50 <= Size * Size, scope $"the point light's shadows differ in {tileBig} pixels");
		Check(tileSum / (Size * Size) < 6.0, "the point light's pictures differ on average");
		Console.WriteLine(failures == 0 ? "gpu-driven-test: PASS" : "gpu-driven-test: FAILED");
		Result = failures == 0 ? 0 : 1;
	}

	/// The mask grown by `radius` pixels each way.
	static bool[] Dilate(bool[] mask, int radius)
	{
		let across = new bool[Size * Size];
		let result = new bool[Size * Size];
		for (int y < Size)
		{
			for (int x < Size)
			{
				for (int d = -radius; d <= radius && !across[y * Size + x]; d++)
				{
					let sx = x + d;
					if (sx >= 0 && sx < Size && mask[y * Size + sx])
						across[y * Size + x] = true;
				}
			}
		}
		for (int y < Size)
		{
			for (int x < Size)
			{
				for (int d = -radius; d <= radius && !result[y * Size + x]; d++)
				{
					let sy = y + d;
					if (sy >= 0 && sy < Size && across[sy * Size + x])
						result[y * Size + x] = true;
				}
			}
		}
		delete across;
		return result;
	}

	static bool Differs(uint8[] a, uint8[] b, int at, int limit)
	{
		for (int c < 3)
		{
			if (Math.Abs((int)a[at + c] - (int)b[at + c]) > limit)
				return true;
		}
		return false;
	}

	void Save(uint8[] pixels, StringView path)
	{
		if (!Native.tn_image_write_png(scope String(path).CStr(), pixels.CArray(), Size, Size))
			Console.WriteLine(scope $"gpu-driven-test: could not write {path}");
	}

	protected override void OnShutdown()
	{
		if (mReadback.Valid && Gfx.Initialized)
			bgfx.destroy_texture(mReadback);
		if (mScene != null)
			mScene.StopPlay();
	}
}
