using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// `--cloud-test settings`: prints the cloud settings with no window, checks that a scene saves and reloads every
/// one of them, that a scene without them loads with clouds off (the class defaults), and that Environment.Reset
/// puts them back to off.
static class CloudTest
{
	static int sFailed;

	static void Check(bool ok, StringView what)
	{
		if (!ok)
		{
			sFailed++;
			Console.WriteLine(scope $"FAIL: {what}");
		}
	}

	static void Print(StringView label, SceneEnvironment env)
	{
		Console.WriteLine(scope $"{label}: clouds={env.clouds} mode={(int32)env.cloudMode} coverage={env.cloudCoverage} density={env.cloudDensity} altitude={env.cloudHeight} thickness={env.cloudThickness} wind={env.cloudWindSpeed} m/s at {env.cloudWindDirection} deg seed={env.cloudSeed} anisotropy={env.cloudAnisotropy} ambient={env.cloudAmbient} tint=({env.cloudTint.r}, {env.cloudTint.g}, {env.cloudTint.b}, {env.cloudTint.a}) distance={env.cloudDistance} resolution={env.cloudResolution}");
	}

	public static int RunSettings()
	{
		// A distinct value in every field, so a line that is lost or swapped shows up in the comparison.
		let scene = scope Scene();
		let env = scene.Environment;
		env.clouds = true;
		env.cloudMode = .TwoD;
		env.cloudCoverage = 0.73f;
		env.cloudDensity = 0.031f;
		env.cloudHeight = 2345;
		env.cloudThickness = 1234;
		env.cloudWindSpeed = 17.5f;
		env.cloudWindDirection = 218;
		env.cloudSeed = 987654;
		env.cloudAnisotropy = -0.35f;
		env.cloudAmbient = 0.42f;
		env.cloudTint = .(0.9f, 0.93f, 1.0f);
		env.cloudDistance = 15500;
		env.cloudResolution = 0.75f;
		Print("set", env);

		// Save and reload.
		let text = scope String();
		SceneSerializer.Save(scene, text);
		Console.WriteLine("saved scene:");
		Console.Write(text);
		let loaded = scope Scene();
		SceneSerializer.Load(loaded, text);
		let back = loaded.Environment;
		Print("reloaded", back);
		Check(back.clouds, "clouds on");
		Check(back.cloudMode == .TwoD, "cloud mode");
		Check(back.cloudCoverage == 0.73f, "cloud coverage");
		Check(back.cloudDensity == 0.031f, "cloud density");
		Check(back.cloudHeight == 2345, "cloud altitude");
		Check(back.cloudThickness == 1234, "cloud thickness");
		Check(back.cloudWindSpeed == 17.5f, "cloud wind speed");
		Check(back.cloudWindDirection == 218, "cloud wind direction");
		Check(back.cloudSeed == 987654, "cloud seed");
		Check(back.cloudAnisotropy == -0.35f, "cloud anisotropy");
		Check(back.cloudAmbient == 0.42f, "cloud ambient");
		Check(back.cloudTint.r == 0.9f && back.cloudTint.g == 0.93f && back.cloudTint.b == 1.0f && back.cloudTint.a == 1.0f, "cloud tint");
		Check(back.cloudDistance == 15500, "cloud distance");
		Check(back.cloudResolution == 0.75f, "cloud resolution");
		Check(text.Contains("env cloudSeed 987654\n"), "the seed is written as a whole number");

		// An old scene (no cloud lines) loads with clouds off and every field at the class default, and saves none.
		let old = scope Scene();
		SceneSerializer.Load(old, "scene \"Old\"\nenv fogDensity 0.01\n");
		let fresh = scope SceneEnvironment();
		let o = old.Environment;
		Print("old scene", o);
		Check(!o.clouds && o.cloudMode == fresh.cloudMode && o.cloudCoverage == fresh.cloudCoverage &&
			o.cloudDensity == fresh.cloudDensity && o.cloudHeight == fresh.cloudHeight &&
			o.cloudThickness == fresh.cloudThickness && o.cloudWindSpeed == fresh.cloudWindSpeed &&
			o.cloudWindDirection == fresh.cloudWindDirection && o.cloudSeed == fresh.cloudSeed &&
			o.cloudAnisotropy == fresh.cloudAnisotropy && o.cloudAmbient == fresh.cloudAmbient &&
			o.cloudTint == fresh.cloudTint && o.cloudDistance == fresh.cloudDistance &&
			o.cloudResolution == fresh.cloudResolution, "an old scene loads with clouds off and the class defaults");
		let oldText = scope String();
		SceneSerializer.Save(old, oldText);
		Check(!oldText.Contains("env clouds") && !oldText.Contains("env cloudMode") && !oldText.Contains("env cloudCoverage") &&
			!oldText.Contains("env cloudDensity") && !oldText.Contains("env cloudHeight") && !oldText.Contains("env cloudThickness") &&
			!oldText.Contains("env cloudWindSpeed") && !oldText.Contains("env cloudWindDirection") && !oldText.Contains("env cloudSeed") &&
			!oldText.Contains("env cloudAnisotropy") && !oldText.Contains("env cloudAmbient") && !oldText.Contains("env cloudTint") &&
			!oldText.Contains("env cloudDistance") && !oldText.Contains("env cloudResolution"),
			"a scene with clouds off saves no cloud lines");

		// Reset puts clouds back to off with the default values.
		let reset = scope SceneEnvironment();
		reset.clouds = true;
		reset.cloudCoverage = 0.9f;
		reset.cloudSeed = 42;
		reset.Reset();
		let defaults = scope SceneEnvironment();
		Check(!reset.clouds && reset.cloudCoverage == defaults.cloudCoverage && reset.cloudSeed == defaults.cloudSeed,
			"Environment.Reset puts clouds back to off and the defaults");

		// Out-of-range values are clamped on load.
		let clamped = scope Scene();
		SceneSerializer.Load(clamped, "scene \"Clamped\"\nenv cloudMode 9\nenv cloudCoverage 2\nenv cloudAnisotropy -4\nenv cloudDistance 1\nenv cloudResolution 5\nenv cloudThickness 0\n");
		let c = clamped.Environment;
		Check(c.cloudMode == .TwoD && c.cloudCoverage == 1 && c.cloudAnisotropy == -0.9f && c.cloudDistance == 500 &&
			c.cloudResolution == 1 && c.cloudThickness == 1, "cloud values are clamped on load");

		Console.WriteLine(sFailed == 0 ? "CLOUD TEST PASS" : scope $"CLOUD TEST FAIL ({sFailed})");
		return sFailed == 0 ? 0 : 1;
	}
}

/// `--cloud-test sky [--cloud-test-folder <dir>]`: draws the 2D cloud backup on the physical sky at noon, golden hour
/// and night, clear (coverage 0) and overcast (coverage 1), plus a Gradient scene with clouds off and on. Writes a
/// screenshot of each into the folder and checks: clouds appear and disappear with coverage; the mirror ball's
/// reflection cube carries the same clouds; a Gradient sky is pixel-identical with clouds on, so clouds apply to
/// Physical/Custom only. Needs a window.
class CloudTestApp : Application
{
	const int32 ShotWidth = 640;
	const int32 ShotHeight = 360;
	const int SettleFrames = 24;

	public int32 Result;

	struct Phase
	{
		public StringView name;
		public bool physical;
		public bool clouds;
		public float coverage;
		// The sun's height to find in the afternoon (degrees), or NaN: night with the moon up.
		public float elevation;
	}

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	GameObject mSunObject;
	GameObject mMirror;
	String mDir = new .() ~ delete _;
	List<Phase> mPhases = new .() ~ delete _;
	int mPhase = -1;
	int mFrame;
	CompareShot mShot ~ delete _;
	uint8[] mPrevious ~ delete _;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Cloud test");
		Width = ShotWidth;
		Height = ShotHeight;
	}

	void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"cloud-test: {ok ? "ok" : "FAIL"} {what}");
		if (!ok)
			Result = 1;
	}

	protected override bool OnInit()
	{
		if (!GetArg("--cloud-test-folder", mDir) || mDir.IsEmpty || mDir.StartsWith("--"))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-cloud-test");
		Directory.CreateDirectory(mDir);
		mPhases.Add(.() { name = "gradient-clear", physical = false, clouds = false, coverage = 0 });
		mPhases.Add(.() { name = "gradient-clouds", physical = false, clouds = true, coverage = 1 });
		mPhases.Add(.() { name = "noon-clear", physical = true, clouds = true, coverage = 0, elevation = 90 });
		mPhases.Add(.() { name = "noon-clouds", physical = true, clouds = true, coverage = 1, elevation = 90 });
		mPhases.Add(.() { name = "golden-clear", physical = true, clouds = true, coverage = 0, elevation = 6 });
		mPhases.Add(.() { name = "golden-clouds", physical = true, clouds = true, coverage = 1, elevation = 6 });
		mPhases.Add(.() { name = "night-clear", physical = true, clouds = true, coverage = 0, elevation = float.NaN });
		mPhases.Add(.() { name = "night-clouds", physical = true, clouds = true, coverage = 1, elevation = float.NaN });

		mScene = new Scene();
		let cameraObject = mScene.CreateGameObject("Camera");
		mCameraObject = cameraObject;
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 80;
		mCamera.farClip = 4000;
		mSunObject = mScene.CreateGameObject("Sun");
		mSunObject.Transform.EulerAngles = .(20, -30, 0);
		let light = mSunObject.AddComponent<Light>();
		light.intensity = 1.5f;
		let ground = mScene.CreateGameObject("Ground");
		let renderer = ground.AddComponent<MeshRenderer>();
		renderer.mesh.Set("builtin:plane");
		renderer.color = .FromBytes(112, 158, 92);
		ground.Transform.LocalScale = .(100, 1, 100);
		// A mirror ball in the middle of the sky: what it shows is the reflection cube, so the cube carries the clouds.
		mMirror = mScene.CreateGameObject("Mirror");
		let mirrorRenderer = mMirror.AddComponent<MeshRenderer>();
		mirrorRenderer.mesh.Set("builtin:sphere_smooth");
		mirrorRenderer.color = .(0.5f, 0.5f, 0.5f);
		mirrorRenderer.metallic = 1;
		mirrorRenderer.roughness = 0.15f;
		mMirror.SetActive(false);
		mView = new RenderView(10);
		mView.AllowPostAa = false;
		// No dynamic GI rays: they are Monte Carlo, so two shots of the same sky would never match exactly.
		ScreenEffects.GlobalIllumination = .Ambient;
		mScene.StartPlay();
		return true;
	}

	void StartPhase(Phase phase)
	{
		let env = mScene.Environment;
		env.Reset();
		mCamera.fieldOfView = 80;
		mCamera.farClip = 4000;
		mCameraObject.Transform.Position = .(0, 2, 0);
		env.clouds = phase.clouds;
		env.cloudMode = .TwoD;
		env.cloudCoverage = phase.coverage;
		mMirror.SetActive(phase.physical);
		if (!phase.physical)
		{
			// The Gradient sky, unchanged by clouds (it does not use the physical include).
			mSunObject.Transform.EulerAngles = .(20, -30, 0);
			mCameraObject.Transform.EulerAngles = .(-8, 150, 0);
			return;
		}
		env.skyMode = .Physical;
		env.dayNight = true;
		env.dayNightPaused = true;
		env.autoColors = true;
		env.sunIntensity = Atmosphere.ReferenceSunIntensity;
		env.sunLight = mSunObject.Id;
		Vector3 look;
		if (phase.elevation.IsNaN)
		{
			// Night: the day and hour with the moon highest and well lit, the sun far below (as --sky-test).
			float best = -90;
			int32 bestDay = 0;
			float bestHour = 0;
			for (int32 day = 0; day < 365; day += 2)
			{
				env.dayOfYear = day;
				for (float hour in float[?](21, 22, 23, 0, 1, 2, 3))
				{
					env.timeOfDay = hour;
					let moon = DayNight.MoonDirection(env);
					if (DayNight.SunElevation(env) < -18 && DayNight.MoonIllumination(env) > 0.6f && moon.y > Math.Sin(best * Mathf.Deg2Rad) && moon.y < Math.Sin(50 * Mathf.Deg2Rad))
					{
						best = Math.Asin(moon.y) * Mathf.Rad2Deg;
						bestDay = day;
						bestHour = hour;
					}
				}
			}
			env.dayOfYear = bestDay;
			env.timeOfDay = bestHour;
			look = DayNight.MoonDirection(env);
		}
		else
		{
			// The afternoon hour with the sun at this height (noon: its highest).
			float bestHour = 12;
			float bestError = float.MaxValue;
			for (float hour = 12; hour < 21; hour += 0.005f)
			{
				env.timeOfDay = hour;
				let error = phase.elevation >= 89 ? -DayNight.SunElevation(env) : Math.Abs(DayNight.SunElevation(env) - phase.elevation);
				if (error < bestError)
				{
					bestError = error;
					bestHour = hour;
				}
			}
			env.timeOfDay = bestHour;
			let sun = DayNight.SunDirection(env);
			look = Vector3(sun.x, 0, sun.z).Normalized;
			look.y = 0.25f;
		}
		look = look.Normalized;
		mCameraObject.Transform.Rotation = Quaternion.LookRotation(look, .(0, 1, 0));
		// Along the look direction, so its middle is the picture's middle in both shots of a pair.
		mMirror.Transform.Position = mCameraObject.Transform.Position + look * 4.5f;
		mMirror.Transform.LocalScale = .(1.6f, 1.6f, 1.6f);
		DayNight.Apply(mScene);
	}

	protected override void OnUpdate()
	{
		mScene.Update();
		AssetLoader.Update();
	}

	protected override void OnRender()
	{
		if (mPhase < 0 || (mShot != null && mFrame < 0))
		{
			mPhase++;
			if (mPhase >= mPhases.Count)
			{
				Finish();
				return;
			}
			StartPhase(mPhases[mPhase]);
			mFrame = 0;
			DeleteAndNullify!(mShot);
		}
		mView.Resize(ShotWidth, ShotHeight);
		mView.Render(mScene, mCamera.GetCameraData((float)ShotWidth / ShotHeight));
		mFrame++;
		if (mFrame < SettleFrames)
			return;
		if (mShot == null)
			mShot = new CompareShot();
		let path = scope $"{mDir}/{mPhases[mPhase].name}.png";
		if (mShot.Step(mView, ShotWidth, ShotHeight, path))
		{
			let pixels = mShot.Pixels;
			let copy = new uint8[pixels.Count];
			Internal.MemCpy(copy.CArray(), pixels.CArray(), pixels.Count);
			CheckShot(mPhases[mPhase], copy);
			delete mPrevious;
			mPrevious = copy;
			mFrame = -1;
		}
	}

	void CheckShot(Phase phase, uint8[] pixels)
	{
		// Not black.
		int64 sum = 0;
		for (int y < ShotHeight / 2)
			for (int x < ShotWidth)
			{
				let i = (y * ShotWidth + x) * 4;
				sum += pixels[i] + pixels[i + 1] + pixels[i + 2];
			}
		Check(sum > 0, scope $"{phase.name}: not black");
		// Each pair is a clear shot then the same sky overcast; the odd one is compared with its partner.
		if (mPhase % 2 == 0)
			return;
		// Each pair is a clear shot then the same sky overcast.
		let diff = Diff(mPrevious, pixels, 0, 0, ShotWidth, ShotHeight);
		if (!phase.physical)
			Check(diff == 0, scope $"Gradient sky unchanged by clouds (diff {diff})");
		else
		{
			Check(diff > 20000, scope $"{phase.name}: clouds change the sky (diff {diff})");
			// The middle of the mirror ball: only what the reflection cube gave it can differ there.
			if (mPhase == 3)
			{
				let ball = Diff(mPrevious, pixels, ShotWidth * 44 / 100, ShotHeight * 44 / 100, ShotWidth * 56 / 100, ShotHeight * 56 / 100);
				Check(ball > 1000, scope $"reflection cube shows the clouds (diff {ball})");
			}
		}
	}

	static int64 Diff(uint8[] a, uint8[] b, int32 x0, int32 y0, int32 x1, int32 y1)
	{
		if (a == null || b == null || a.Count != b.Count)
			return int64.MaxValue;
		int64 sum = 0;
		for (int32 y = y0; y < y1; y++)
			for (int32 x = x0; x < x1; x++)
			{
				let i = (y * ShotWidth + x) * 4;
				for (int32 c < 3)
					sum += Math.Abs((int32)a[i + c] - (int32)b[i + c]);
			}
		return sum;
	}

	void Finish()
	{
		Console.WriteLine(Result == 0 ? "cloud-test: PASS" : "cloud-test: FAILED");
		Close();
	}
}

/// `--cloud-test volume [--cloud-test-folder <dir>]`: the volumetric raymarch (C2a) at half resolution on the physical
/// sky, from one camera: clouds off, coverage 0, then clear / broken / overcast cover. Writes a screenshot of each and
/// checks: coverage 0 is pixel-identical to clouds off; each cover changes the sky; and the "Volumetric clouds" pass
/// reports GPU time. Needs Vulkan, Direct3D or Metal (else the run reports the 2D fallback).
class CloudVolumeTestApp : Application
{
	const int32 ShotWidth = 640;
	const int32 ShotHeight = 360;
	const int SettleFrames = 16;
	/// The weather clock the shots are drawn at, so the wind does not drift between phases and they can be compared.
	const double CloudTime = 3600.0;

	public int32 Result;

	struct Phase
	{
		public StringView name;
		public bool clouds;
		public float coverage;
	}

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	GameObject mSunObject;
	String mDir = new .() ~ delete _;
	List<Phase> mPhases = new .() ~ delete _;
	int mPhase = -1;
	int mFrame;
	CompareShot mShot ~ delete _;
	uint8[] mOff ~ delete _;
	uint8[] mClear ~ delete _;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Cloud volume test");
		Width = ShotWidth;
		Height = ShotHeight;
	}

	void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"cloud-test: {ok ? "ok" : "FAIL"} {what}");
		if (!ok)
			Result = 1;
	}

	protected override bool OnInit()
	{
		if (!GetArg("--cloud-test-folder", mDir) || mDir.IsEmpty || mDir.StartsWith("--"))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-cloud-volume");
		Directory.CreateDirectory(mDir);
		Clouds.OverrideSeconds = CloudTime;
		Profiler.Enabled = true;
		mPhases.Add(.() { name = "off", clouds = false, coverage = 0 });
		mPhases.Add(.() { name = "zero", clouds = true, coverage = 0 });
		mPhases.Add(.() { name = "clear", clouds = true, coverage = 0.15f });
		mPhases.Add(.() { name = "broken", clouds = true, coverage = 0.45f });
		mPhases.Add(.() { name = "overcast", clouds = true, coverage = 0.9f });

		mScene = new Scene();
		let cameraObject = mScene.CreateGameObject("Camera");
		mCameraObject = cameraObject;
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 75;
		mCamera.farClip = 20000;
		mSunObject = mScene.CreateGameObject("Sun");
		mSunObject.Transform.EulerAngles = .(20, -30, 0);
		let light = mSunObject.AddComponent<Light>();
		light.intensity = 1.5f;
		let ground = mScene.CreateGameObject("Ground");
		let renderer = ground.AddComponent<MeshRenderer>();
		renderer.mesh.Set("builtin:plane");
		renderer.color = .FromBytes(112, 158, 92);
		ground.Transform.LocalScale = .(500, 1, 500);
		mView = new RenderView(10);
		mView.AllowPostAa = false;
		ScreenEffects.GlobalIllumination = .Ambient;
		mScene.StartPlay();
		return true;
	}

	void StartPhase(Phase phase)
	{
		let env = mScene.Environment;
		env.Reset();
		env.skyMode = .Physical;
		env.dayNight = true;
		env.dayNightPaused = true;
		env.autoColors = true;
		env.sunIntensity = Atmosphere.ReferenceSunIntensity;
		env.sunLight = mSunObject.Id;
		// No fog over the sky: the cloud pass is what this test measures.
		env.volumetricFog = false;
		env.clouds = phase.clouds;
		env.cloudMode = .Volumetric;
		env.cloudCoverage = phase.coverage;
		// The afternoon hour with the sun 45 degrees up.
		float bestHour = 12;
		float bestError = float.MaxValue;
		for (float hour = 12; hour < 21; hour += 0.01f)
		{
			env.timeOfDay = hour;
			let error = Math.Abs(DayNight.SunElevation(env) - 45);
			if (error < bestError)
			{
				bestError = error;
				bestHour = hour;
			}
		}
		env.timeOfDay = bestHour;
		let sun = DayNight.SunDirection(env);
		var look = Vector3(sun.x, 0, sun.z).Normalized;
		look.y = 0.35f;
		look = look.Normalized;
		mCamera.fieldOfView = 75;
		mCamera.farClip = 20000;
		mCameraObject.Transform.Position = .(0, 200, 0);
		mCameraObject.Transform.Rotation = Quaternion.LookRotation(look, .(0, 1, 0));
		DayNight.Apply(mScene);
	}

	protected override void OnUpdate()
	{
		mScene.Update();
		AssetLoader.Update();
	}

	protected override void OnRender()
	{
		if (mPhase < 0 || (mShot != null && mFrame < 0))
		{
			mPhase++;
			if (mPhase >= mPhases.Count)
			{
				Finish();
				return;
			}
			StartPhase(mPhases[mPhase]);
			mFrame = 0;
			DeleteAndNullify!(mShot);
		}
		mView.Resize(ShotWidth, ShotHeight);
		mView.Render(mScene, mCamera.GetCameraData((float)ShotWidth / ShotHeight));
		mFrame++;
		if (mFrame < SettleFrames)
			return;
		if (mShot == null)
			mShot = new CompareShot();
		let path = scope $"{mDir}/{mPhases[mPhase].name}.png";
		if (mShot.Step(mView, ShotWidth, ShotHeight, path))
		{
			let pixels = mShot.Pixels;
			let copy = new uint8[pixels.Count];
			Internal.MemCpy(copy.CArray(), pixels.CArray(), pixels.Count);
			CheckShot(mPhases[mPhase], copy);
			mFrame = -1;
		}
	}

	void CheckShot(Phase phase, uint8[] pixels)
	{
		let gpu = ProfilerModules.VolumetricCloudsMs;
		Console.WriteLine(scope $"cloud-test: {phase.name} coverage {phase.coverage}: pixels {RenderView.VolumetricCloudPixels}, GPU {gpu:F3} ms");
		// Not black.
		int64 sum = 0;
		for (int y < ShotHeight / 2)
			for (int x < ShotWidth)
			{
				let i = (y * ShotWidth + x) * 4;
				sum += pixels[i] + pixels[i + 1] + pixels[i + 2];
			}
		Check(sum > 0, scope $"{phase.name}: not black");
		if (!RenderView.CloudsRunnable)
			return;
		if (phase.name == "off") { mOff = pixels; return; }
		if (phase.name == "zero")
		{
			Check(Diff(mOff, pixels, 0, 0, ShotWidth, ShotHeight * 7 / 10) == 0, "coverage 0 is pixel-identical to clouds off");
			return;
		}
		// Every cover changes the sky above the horizon...
		let sky = Diff(mOff, pixels, 0, 0, ShotWidth, ShotHeight * 7 / 10);
		Check(sky > 20000, scope $"{phase.name}: clouds change the sky (diff {sky})");
		// ...and the pass ran, at the step count it was given.
		Check(gpu > 0, scope $"{phase.name}: the raymarch reports GPU time ({gpu:F3} ms)");
		Check(RenderView.VolumetricCloudPixels > 0, scope $"{phase.name}: cloud target has pixels");
		if (phase.name == "clear")
			mClear = pixels;
		else if (phase.name == "overcast" && mClear != null)
		{
			let more = Diff(mClear, pixels, 0, 0, ShotWidth, ShotHeight * 7 / 10);
			Check(more > 20000, scope $"overcast differs from clear (diff {more})");
		}
	}

	static int64 Diff(uint8[] a, uint8[] b, int32 x0, int32 y0, int32 x1, int32 y1)
	{
		if (a == null || b == null || a.Count != b.Count)
			return int64.MaxValue;
		int64 sum = 0;
		for (int32 y = y0; y < y1; y++)
			for (int32 x = x0; x < x1; x++)
			{
				let i = (y * ShotWidth + x) * 4;
				for (int32 c < 3)
					sum += Math.Abs((int32)a[i + c] - (int32)b[i + c]);
			}
		return sum;
	}

	void Finish()
	{
		Console.WriteLine(Result == 0 ? "cloud-test volume: PASS" : "cloud-test volume: FAILED");
		Close();
	}
}
