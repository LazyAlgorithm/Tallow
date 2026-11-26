using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Bgfx;

namespace Tallow;

/// --gpu-bench <scene> [--frames N] [--out file.json] [--bench-timeout S]: generated benchmark scenes, each drawn the usual
/// way and then from clusters picked on the graphics card, back to back, along the same camera path. Needs a window and
/// Vulkan or Metal. Exit code 0 when both runs reached the end of the path and the JSON was written, 1 otherwise.
///
/// Scenes (all generated, fixed seeds, nothing to download; names or numbers):
///   1 mixed    11 big meshes (a million triangles and more each, 13 million in all) in a ring, the camera orbits them
///   2 crowd    10 000+ copies of a 10 000 triangle mesh in a grid, the camera flies over it
///   3 closeup  one 2 million triangle mesh, the camera comes from far away to the surface
///   4 stream   a 2 million triangle mesh streamed through a geometry budget of a thirty-second of its size, flown in and along
///   5 tiny     16 meshes of a million triangles each, far away (a few pixels per triangle at most): the M7 gate scene
///   6 fog      a colonnade in thick volumetric fog with a low sun behind it (light shafts), the camera flying down it
///
/// Per run the JSON has: mean/p95/max of the CPU time of the render call and bgfx's frame CPU and GPU times (ms), the mean GPU
/// time of each pass (cull phase 1, occluder draws, HZB + phase 2, main draw, shadows, VT feedback; the passes of the GPU path
/// read 0 in the old run), triangles (submitted to bgfx, drawn from clusters, and the sum), clusters, instances, pool and resident
/// megabytes, and streaming requests/misses/uploads/pages asked for. `--frames` is the length of the path (300), a run that takes
/// longer than `--bench-timeout` seconds (120) is cut and marked.
///
/// The profiler is on during the runs (it feeds the per-pass times), the same in both. The old run goes first: the cluster
/// hierarchies are built before either run starts, so building time is not in the numbers (it is in "buildSeconds").
class GpuBenchApp : Application
{
	enum Stage
	{
		Building,
		Warm,
		Run,
		Done
	}

	const int WarmFrames = 20;
	const int ViewWidth = 1280;
	const int ViewHeight = 720;

	/// 0 when both runs finished and the file was written.
	public int32 Result;

	class Run
	{
		public String mode = new .() ~ delete _;
		public bool timedOut;
		public int frames;
		public double seconds;
		public List<double> renderMs = new .() ~ delete _;
		public List<double> bgfxCpuMs = new .() ~ delete _;
		public List<double> gpuMs = new .() ~ delete _;
		public double cullMs, occluderMs, hzbMs, mainMs, shadowMs, vtMs, fogMs;
		public double submittedTriangles, clusterTriangles, clusters, instances, draws, computes;
		public int64 maxClusterTriangles, maxClusters, maxSwClusters, maxSwTriangles, maxHwClusters;
		public double poolMB, residentGeoMB, residentTexMB, residentVtMB, peakPoolMB, peakResidentGeoMB;
		public int64 requests, misses, uploads, pagesRequested;
		public int64 groupsMissingEnd;
		public int64 failures;
	}

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	List<Mesh> mMeshes = new .() ~ delete _;
	List<Run> mRuns = new .() ~ DeleteContainerAndItems!(_);
	Run mRun;
	Stage mStage = .Building;
	int mStageFrames;
	int mMode; // 0 old path, 1 GPU path
	int mFrames = 300;
	int mTimeoutSeconds = 120;
	int mSceneId;
	String mSceneName = new .() ~ delete _;
	String mSceneInfo = new .() ~ delete _;
	String mOut = new .() ~ delete _;
	int64 mStartTime;
	int64 mRunStart;
	double mBuildSeconds;
	int64 mCookedBytes;
	int mPageCount;
	int64 mSceneTriangles;
	int64 mSceneInstances;
	Stopwatch mFrameWatch = new .() ~ delete _;
	bool mVsyncOff;
	bool mBudgetSet;
	int64 mRequests0, mMisses0, mUploads0, mPagesRequested0, mFailures0;
	String mError = new .() ~ delete _;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("GPU benchmark");
		Width = ViewWidth;
		Height = ViewHeight;
	}

	void Spawn(Mesh mesh, Vector3 position, float scale, int index)
	{
		let object = mScene.CreateGameObject("Bench");
		object.Transform.Position = position;
		object.Transform.LocalScale = .(scale, scale, scale);
		let renderer = object.AddComponent<MeshRenderer>();
		renderer.mesh.Set(mesh.Name);
		renderer.color = .(0.35f + 0.65f * ((index * 37) % 11) / 10.0f, 0.35f + 0.65f * ((index * 17) % 7) / 6.0f, 0.4f + 0.6f * ((index * 53) % 5) / 4.0f);
		renderer.roughness = 0.4f + (index % 4) * 0.15f;
		mSceneInstances++;
		mSceneTriangles += mesh.Indices.Count / 3;
	}

	Mesh AddMesh(StringView name, int segments, int rings)
	{
		let mesh = Primitives.CreateSphere(segments, rings);
		let adopted = Assets.AdoptMesh(name, mesh);
		adopted.Name.Set(name);
		mMeshes.Add(adopted);
		return adopted;
	}

	protected override bool OnInit()
	{
		let text = scope String();
		GetArg("--gpu-bench", text);
		if (text.StartsWith("--") || text.IsEmpty)
			text.Set("1");
		switch (text)
		{
		case "1", "mixed": mSceneId = 1; mSceneName.Set("mixed");
		case "2", "crowd": mSceneId = 2; mSceneName.Set("crowd");
		case "3", "closeup": mSceneId = 3; mSceneName.Set("closeup");
		case "4", "stream": mSceneId = 4; mSceneName.Set("stream");
		case "5", "tiny": mSceneId = 5; mSceneName.Set("tiny");
		case "6", "fog": mSceneId = 6; mSceneName.Set("fog");
		default:
			Console.WriteLine(scope $"gpu-bench: unknown scene '{text}' (1 mixed, 2 crowd, 3 closeup, 4 stream, 5 tiny, 6 fog)");
			Result = 1;
			return false;
		}
		text.Clear();
		if (GetArg("--frames", text) && int32.Parse(text) case .Ok(let n))
			mFrames = Math.Clamp(n, 10, 100000);
		// --frames is the length of the path here, not a limit on the program's frames.
		ClearFrameLimit();
		text.Clear();
		if (GetArg("--bench-timeout", text) && int32.Parse(text) case .Ok(let n))
			mTimeoutSeconds = Math.Clamp(n, 5, 3600);
		if (!GetArg("--out", mOut) || mOut.IsEmpty)
			mOut.Set(scope $"gpu-bench-{mSceneName}.json");
		GpuDriven.Override = 1;
		GpuDriven.StatsInterval = 1;
		GpuDriven.FeedbackInterval = 2;
		GpuDriven.MinTriangles = 2000;

		mScene = new Scene();
		mScene.Environment.fogDensity = 0;
		mCameraObject = mScene.CreateGameObject("Camera");
		mCamera = mCameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 60;
		mCamera.farClip = 5000;
		let sun = mScene.CreateGameObject("Sun");
		sun.Transform.Rotation = Quaternion.Euler(52, -35, 0);
		let light = sun.AddComponent<Light>();
		light.castShadows = mSceneId != 5;
		light.intensity = 1.4f;

		switch (mSceneId)
		{
		case 1:
			// Mixed big meshes: three kinds of sphere (1.0 M, 1.96 M, 0.7 M triangles) in a ring: 5 + 3 + 3 = 13 M triangles.
			let a = AddMesh("bench-mixed-a", 1000, 500);
			let b = AddMesh("bench-mixed-b", 1400, 700);
			let c = AddMesh("bench-mixed-c", 700, 500);
			let count = 11;
			for (int i < count)
			{
				let angle = (float)i / count * Math.PI_f * 2;
				let mesh = (i % 11) < 5 ? a : ((i % 11) < 8 ? b : c);
				Spawn(mesh, .(Math.Sin(angle) * 30, 0, Math.Cos(angle) * 30), 12, i);
			}
			mSceneInfo.Set("11 big spheres (1.0 M, 1.96 M and 0.7 M triangles) in a ring, camera orbit");
		case 2:
			let ball = AddMesh("bench-crowd", 100, 50);
			let side = 101;
			for (int i < side * side)
			{
				let ix = i % side;
				let iz = i / side;
				Spawn(ball, .((ix - side * 0.5f) * 2.4f, 0, iz * 2.4f), 0.9f + (i % 5) * 0.12f, i);
			}
			let floor = mScene.CreateGameObject("Floor");
			floor.Transform.Position = .(0, -1.0f, 120);
			floor.Transform.LocalScale = .(400, 1, 400);
			let floorRenderer = floor.AddComponent<MeshRenderer>();
			floorRenderer.mesh.Set("builtin:plane");
			floorRenderer.color = .(0.55f, 0.6f, 0.5f);
			mSceneInfo.Set("10 201 spheres of 10 000 triangles in a grid, camera flies over");
		case 3:
			let ball = AddMesh("bench-closeup", 1000, 1000);
			Spawn(ball, .(0, 0, 0), 120, 1);
			mSceneInfo.Set("one sphere of 2 M triangles, radius 60: from 2000 m away to 6 m above the surface");
		case 4:
			let ball = AddMesh("bench-stream", 1400, 700);
			Spawn(ball, .(0, 0, 0), 120, 2);
			mSceneInfo.Set("one sphere of 1.96 M triangles, geometry budget 1/32 of the cooked size, fly in and along the surface");
		case 6:
			// A colonnade in thick fog, the sun low behind it (camera looking along +Z): light shafts between the pillars.
			let ground = mScene.CreateGameObject("Ground");
			ground.Transform.Position = .(0, 0, 90);
			ground.Transform.LocalScale = .(400, 1, 400);
			let groundRenderer = ground.AddComponent<MeshRenderer>();
			groundRenderer.mesh.Set("builtin:plane");
			groundRenderer.color = .(0.42f, 0.44f, 0.40f);
			for (int i < 12)
			{
				for (int side = -1; side <= 1; side += 2)
				{
					let pillar = mScene.CreateGameObject("Pillar");
					pillar.Transform.Position = .(side * 6.0f, 7, 8 + i * 11);
					pillar.Transform.LocalScale = .(2.6f, 14, 2.6f);
					let renderer = pillar.AddComponent<MeshRenderer>();
					renderer.mesh.Set("builtin:cube");
					renderer.color = .(0.58f, 0.54f, 0.48f);
					mSceneInstances++;
					mSceneTriangles += 12;
				}
			}
			// The sun ahead of the camera and a little down, so shafts come towards it.
			sun.Transform.Rotation = Quaternion.LookRotation(Vector3(0, -0.22f, -1).Normalized, .Up);
			light.intensity = 2.2f;
			let env = mScene.Environment;
			env.volumetricFog = true;
			env.vfDensity = 0.06f;
			env.vfHeight = 0;
			env.vfFalloff = 0.03f;
			env.vfAnisotropy = 0.7f;
			env.vfAlbedo = .(1, 1, 1);
			env.vfSunScattering = 2;
			env.vfAmbient = 0.1f;
			env.vfDistance = 160;
			env.shadowDistance = 120;
			mSceneInfo.Set("a colonnade in thick volumetric fog with a low sun behind it (light shafts), camera flying down it");
		default:
			let ball = AddMesh("bench-tiny", 1000, 500);
			for (int i < 16)
				Spawn(ball, .(((i % 4) - 1.5f) * 8, ((i / 4) - 1.5f) * 8, 150), 2, i);
			mSceneInfo.Set("16 spheres of 1 M triangles, radius 1, 150 m away (a few pixels wide): triangles under a pixel");
		}
		Console.WriteLine(scope $"gpu-bench: scene {mSceneName}: {mSceneInstances} instances, {mSceneTriangles / 1000000.0:0.0} M triangles, {mFrames} frames per run, window {Width} x {Height}");

		mView = new RenderView(10);
		mView.CapturesReflections = false;
		mView.AllowPostAa = false;
		mScene.StartPlay();
		Tallow.Profiler.Enabled = true;
		bgfx.set_debug((uint32)bgfx.DebugFlags.Profiler, .() { idx = uint16.MaxValue }, 0);
		mStartTime = Internal.GetTickCountMicro();
		return true;
	}

	protected override void OnUpdate()
	{
		if (!mVsyncOff)
		{
			// Frames as fast as they go, so the timings mean something.
			Gfx.SetVsync(false);
			mVsyncOff = true;
		}
		mScene.Update();
		AssetLoader.Update();
		StreamingCore.Update((int)Time.FrameCount);
	}

	/// The camera at `t` (0 to 1) along the path of this scene. Same for both runs.
	void Pose(float t)
	{
		Vector3 position = .(0, 0, -50);
		Vector3 angles = .(0, 0, 0);
		switch (mSceneId)
		{
		case 1:
			// Half an orbit round the ring at 70 m, 22 m up, looking at the middle.
			let angle = -1.2f + t * 2.4f;
			position = .(Math.Sin(angle) * 70, 22, -Math.Cos(angle) * 70);
			angles = .(Math.Atan(22.0f / 70.0f) * 57.2958f, -angle * 57.2958f, 0);
		case 2:
			position = .(0, 14, -22 + t * 200);
			angles = .(24, 0, 0);
		case 3:
			// Far away to near, evenly in the logarithm of the distance (2000 m to 66 m from the middle).
			let distance = 2000.0f * Math.Pow(66.0f / 2000.0f, t);
			position = .(0, 0, -distance);
		case 4:
			if (t < 0.5f)
				position = .(0, 0, -400 + (t / 0.5f) * (400 - 66));
			else
			{
				let angle = (t - 0.5f) / 0.5f * 2.5f;
				position = .(0, Math.Sin(angle) * 66, -Math.Cos(angle) * 66);
				angles = .(angle * 57.2958f, 0, 0);
			}
		case 6:
			// Down the middle of the colonnade at eye height, towards the sun.
			position = .(0, 3, -14 + t * 155);
			angles = .(2, 0, 0);
		default:
			position = .(-12 + t * 24, 2, 0);
			angles = .(0, 0, 0);
		}
		mCameraObject.Transform.Position = position;
		mCameraObject.Transform.Rotation = Quaternion.Euler(angles.x, angles.y, angles.z);
	}

	protected override void OnRender()
	{
		let t = (mStage == .Run) ? (float)mStageFrames / Math.Max(mFrames - 1, 1) : 0.0f;
		Pose(Math.Min(t, 1.0f));
		mView.Resize(ViewWidth, ViewHeight);
		mFrameWatch.Restart();
		mView.Render(mScene, mCamera.GetCameraData((float)ViewWidth / ViewHeight));
		mFrameWatch.Stop();
		let renderMs = mFrameWatch.Elapsed.TotalMilliseconds;
		mStageFrames++;

		switch (mStage)
		{
		case .Building:
			if (!GpuDriven.Available)
			{
				Abort("the graphics card or backend cannot draw from clusters (GpuDriven.Available is false)");
				return;
			}
			bool ready = true;
			for (let mesh in mMeshes)
			{
				GpuDriven.Lookup(mesh);
				if (mesh.GpuFailed)
				{
					Abort(scope $"the clusters of {mesh.Name} were not built");
					return;
				}
				if (mesh.GpuEntry == null)
					ready = false;
			}
			GpuDriven.Update();
			let waited = (Internal.GetTickCountMicro() - mStartTime) / 1000000.0;
			if (ready)
			{
				mBuildSeconds = waited;
				if (mSceneId == 4)
				{
					let pages = mMeshes[0].GpuEntry.pages;
					mPageCount = pages.PageCount;
					for (int i < pages.PageCount)
						mCookedBytes += pages.PageBytesOf[i];
				}
				Console.WriteLine(scope $"gpu-bench: clusters built after {waited:0.0} s");
				StartRun(0);
			}
			else if (waited > 180)
				Abort("the clusters were not built in 180 s");
		case .Warm:
			if (mMode == 1 && mSceneId == 4 && !mBudgetSet && GpuDriven.StreamedMeshes > 0 && !HasArg("--streaming-budget"))
			{
				// A pool a fraction of the mesh, as in --streaming-test geometry.
				StreamingCore.SetBudget(.GeoPage, (int64)Math.Max(mCookedBytes / 32, 7 << 17));
				mBudgetSet = true;
			}
			if (mStageFrames >= WarmFrames)
				BeginMeasure();
		case .Run:
			Sample(renderMs);
			let elapsed = (Internal.GetTickCountMicro() - mRunStart) / 1000000.0;
			if (mStageFrames >= mFrames || elapsed > mTimeoutSeconds)
			{
				mRun.timedOut = mStageFrames < mFrames;
				EndRun(elapsed);
			}
		case .Done:
		}
	}

	void StartRun(int mode)
	{
		mMode = mode;
		mRun = new Run();
		mRun.mode.Set(mode == 0 ? "old" : "gpu");
		mRuns.Add(mRun);
		GpuDriven.Override = (int32)mode;
		mStage = .Warm;
		mStageFrames = 0;
		Console.WriteLine(scope $"gpu-bench: run {mRun.mode}");
	}

	void BeginMeasure()
	{
		mStage = .Run;
		mStageFrames = 0;
		mRunStart = Internal.GetTickCountMicro();
		mRequests0 = StreamingCore.Requests;
		mMisses0 = StreamingCore.Misses;
		mUploads0 = StreamingCore.Uploads;
		mFailures0 = StreamingCore.Failures;
		mPagesRequested0 = GpuDriven.PagesRequested;
	}

	static double PoolMB(StreamKind kind)
	{
		let pool = StreamingCore.Pool(kind);
		return pool == null ? 0 : (double)pool.Resident / 1048576.0;
	}

	void Sample(double renderMs)
	{
		let run = mRun;
		let stats = bgfx.get_stats();
		run.renderMs.Add(renderMs);
		run.bgfxCpuMs.Add(stats.cpuTimerFreq > 0 ? (double)(stats.cpuTimeEnd - stats.cpuTimeBegin) * 1000.0 / stats.cpuTimerFreq : 0);
		run.gpuMs.Add((stats.gpuTimerFreq > 0 && stats.gpuTimeEnd > stats.gpuTimeBegin) ? (double)(stats.gpuTimeEnd - stats.gpuTimeBegin) * 1000.0 / stats.gpuTimerFreq : 0);
		run.cullMs += ProfilerModules.CullMs;
		run.occluderMs += ProfilerModules.OccluderMs;
		run.hzbMs += ProfilerModules.HzbMs;
		run.mainMs += ProfilerModules.MainMs;
		run.shadowMs += ProfilerModules.ShadowMs;
		run.vtMs += ProfilerModules.VtMs;
		run.fogMs += ProfilerModules.VolumetricFogMs;
		double submitted = 0;
		for (let count in stats.numPrims)
			submitted += count;
		run.submittedTriangles += submitted;
		run.clusterTriangles += GpuDriven.Triangles;
		run.clusters += GpuDriven.Clusters;
		run.instances += GpuDriven.FrameInstances;
		run.draws += stats.numDraw;
		run.computes += stats.numCompute;
		run.maxClusterTriangles = Math.Max(run.maxClusterTriangles, GpuDriven.Triangles);
		run.maxClusters = Math.Max(run.maxClusters, GpuDriven.Clusters);
		run.maxSwClusters = Math.Max(run.maxSwClusters, GpuDriven.SwClusters);
		run.maxSwTriangles = Math.Max(run.maxSwTriangles, GpuDriven.SwTriangles);
		run.maxHwClusters = Math.Max(run.maxHwClusters, GpuDriven.HwClusters);
		let pool = (double)GpuDriven.PoolWordsInUse * 4 / 1048576.0;
		let geo = PoolMB(.GeoPage);
		run.poolMB += pool;
		run.residentGeoMB += geo;
		run.residentTexMB += PoolMB(.TextureMip);
		run.residentVtMB += PoolMB(.VtTile);
		run.peakPoolMB = Math.Max(run.peakPoolMB, pool);
		run.peakResidentGeoMB = Math.Max(run.peakResidentGeoMB, geo);
	}

	void EndRun(double seconds)
	{
		let run = mRun;
		run.frames = mStageFrames;
		run.seconds = seconds;
		run.requests = StreamingCore.Requests - mRequests0;
		run.misses = StreamingCore.Misses - mMisses0;
		run.uploads = StreamingCore.Uploads - mUploads0;
		run.failures = StreamingCore.Failures - mFailures0;
		run.pagesRequested = GpuDriven.PagesRequested - mPagesRequested0;
		run.groupsMissingEnd = GpuDriven.GroupsMissing;
		let n = Math.Max(run.renderMs.Count, 1);
		Console.WriteLine(scope $"gpu-bench: {run.mode}: {run.frames} frames in {seconds:0.0} s{(run.timedOut ? " (TIMED OUT)" : "")}, render {Mean(run.renderMs):0.00} ms, gpu {Mean(run.gpuMs):0.00} ms, {run.submittedTriangles / n / 1000000.0:0.00} M triangles submitted, {run.clusterTriangles / n / 1000000.0:0.00} M from clusters");
		if (run.timedOut)
			Result = 1;
		if (mMode == 0)
			StartRun(1);
		else
			Finish();
	}

	static double Mean(List<double> values)
	{
		if (values.Count == 0)
			return 0;
		double sum = 0;
		for (let v in values)
			sum += v;
		return sum / values.Count;
	}

	static double Percentile(List<double> values, double p)
	{
		if (values.Count == 0)
			return 0;
		let sorted = scope List<double>();
		sorted.AddRange(values);
		sorted.Sort(scope (a, b) => a <=> b);
		return sorted[Math.Min((int)(p * sorted.Count), sorted.Count - 1)];
	}

	static double Max(List<double> values)
	{
		double best = 0;
		for (let v in values)
			best = Math.Max(best, v);
		return best;
	}

	static void Stat(String json, StringView name, List<double> values, bool last = false)
	{
		json.AppendF($"      \"{name}\": {{ \"mean\": {Mean(values):0.000}, \"p95\": {Percentile(values, 0.95):0.000}, \"max\": {Max(values):0.000} }}{(last ? "" : ",")}\n");
	}

	void Abort(StringView why)
	{
		Console.WriteLine(scope $"gpu-bench: FAIL: {why}");
		mError.Set(why);
		Result = 1;
		Finish();
	}

	void Finish()
	{
		if (mStage == .Done)
			return;
		mStage = .Done;
		let json = scope String();
		json.Append("{\n");
		json.AppendF($"  \"scene\": \"{mSceneName}\",\n  \"description\": \"{mSceneInfo}\",\n");
		json.AppendF($"  \"frames\": {mFrames},\n  \"window\": [{ViewWidth}, {ViewHeight}],\n");
		json.AppendF($"  \"sceneInstances\": {mSceneInstances},\n  \"sceneTrianglesOldPath\": {mSceneTriangles},\n");
		json.AppendF($"  \"buildSeconds\": {mBuildSeconds:0.0},\n");
		json.AppendF($"  \"geometryPages\": {mPageCount},\n  \"geometryCookedMB\": {mCookedBytes / 1048576.0:0.0},\n");
		json.AppendF($"  \"geometryBudgetMB\": {StreamingCore.Pool(.GeoPage) == null ? 0.0 : StreamingCore.Pool(.GeoPage).Budget / 1048576.0:0.0},\n");
		json.AppendF($"  \"gpuAvailable\": {GpuDriven.Available ? "true" : "false"},\n");
		json.AppendF($"  \"error\": \"{mError}\",\n");
		json.Append("  \"runs\": [\n");
		for (let run in mRuns)
		{
			let n = Math.Max(run.renderMs.Count, 1);
			json.Append("    {\n");
			json.AppendF($"      \"mode\": \"{run.mode}\",\n      \"framesDone\": {run.frames},\n      \"seconds\": {run.seconds:0.00},\n      \"timedOut\": {run.timedOut ? "true" : "false"},\n");
			Stat(json, "cpuMsRender", run.renderMs);
			Stat(json, "cpuMsBgfxFrame", run.bgfxCpuMs);
			Stat(json, "gpuMsFrame", run.gpuMs);
			json.AppendF($"      \"gpuMsPass\": {{ \"cullPhase1\": {run.cullMs / n:0.000}, \"occluderDraws\": {run.occluderMs / n:0.000}, \"hzbPhase2\": {run.hzbMs / n:0.000}, \"mainDraw\": {run.mainMs / n:0.000}, \"shadows\": {run.shadowMs / n:0.000}, \"vtFeedback\": {run.vtMs / n:0.000}, \"volumetricFog\": {run.fogMs / n:0.000} }},\n");
			json.AppendF($"      \"trianglesSubmittedMean\": {run.submittedTriangles / n:0},\n      \"trianglesFromClustersMean\": {run.clusterTriangles / n:0},\n      \"trianglesFromClustersMax\": {run.maxClusterTriangles},\n");
			json.AppendF($"      \"trianglesTotalMean\": {(run.submittedTriangles + run.clusterTriangles) / n:0},\n");
			json.AppendF($"      \"clustersMean\": {run.clusters / n:0},\n      \"clustersMax\": {run.maxClusters},\n      \"swClustersMax\": {run.maxSwClusters},\n      \"swTrianglesMax\": {run.maxSwTriangles},\n      \"hwClustersMax\": {run.maxHwClusters},\n      \"instancesMean\": {run.instances / n:0},\n");
			json.AppendF($"      \"drawsMean\": {run.draws / n:0.0},\n      \"computesMean\": {run.computes / n:0.0},\n");
			json.AppendF($"      \"poolMBMean\": {run.poolMB / n:0.0},\n      \"poolMBPeak\": {run.peakPoolMB:0.0},\n      \"residentGeometryMBMean\": {run.residentGeoMB / n:0.0},\n      \"residentGeometryMBPeak\": {run.peakResidentGeoMB:0.0},\n");
			json.AppendF($"      \"residentTextureMBMean\": {run.residentTexMB / n:0.0},\n      \"residentVirtualTextureMBMean\": {run.residentVtMB / n:0.0},\n");
			json.AppendF($"      \"streaming\": {{ \"requests\": {run.requests}, \"misses\": {run.misses}, \"uploads\": {run.uploads}, \"pagesAskedFor\": {run.pagesRequested}, \"groupsMissingAtEnd\": {run.groupsMissingEnd}, \"failures\": {run.failures} }}\n");
			json.AppendF($"    }}{(run == mRuns[mRuns.Count - 1] ? "" : ",")}\n");
		}
		json.Append("  ]\n}\n");
		if (File.WriteAllText(mOut, json) case .Ok)
			Console.WriteLine(scope $"gpu-bench: wrote {mOut}");
		else
		{
			Console.WriteLine(scope $"gpu-bench: FAIL: could not write {mOut}");
			Result = 1;
		}
		if (mRuns.Count < 2)
			Result = 1;
		Console.WriteLine(Result == 0 ? "gpu-bench: PASS" : "gpu-bench: FAIL");
		Close();
	}
}
