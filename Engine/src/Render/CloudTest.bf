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

/// `--cloud-test lighting [--cloud-test-folder <dir>]`: the volumetric cloud lighting (C2b) on the physical sky, from
/// one camera: noon towards and away from the sun, sunset and night (the moon up), the first of each pair cloudless (so
/// the cloud is the pixels that changed), and the sun with a clear sky and behind an overcast deck. Writes a screenshot
/// of each and checks: the sunward deck is brighter than the one away from the sun; the noon deck has shaded bases
/// below lit tops (a wide range inside the cloud); the sunset deck is warmer (lit undersides); the night deck is
/// moonlit but much darker; and the overcast deck
/// hides the sun's disc. GPU time of the "Volumetric clouds" pass is logged. Needs Vulkan, Direct3D or Metal.
class CloudLightingTestApp : Application
{
	const int32 ShotWidth = 640;
	const int32 ShotHeight = 360;
	const int SettleFrames = 16;
	/// The weather clock the shots are drawn at, so the wind does not drift between phases.
	const double CloudTime = 3600.0;
	/// The share of the picture above the horizon that the cloud statistics use.
	const int32 SkyRows = ShotHeight * 7 / 10;
	/// A pixel counts as cloud when its colour moved at least this much from the cloudless shot (sum of rgb).
	const int64 MaskDiff = 24;

	public int32 Result;

	struct Phase
	{
		public StringView name;
		public bool clouds;
		public float coverage;
		/// The sun's height to find in the afternoon (degrees), or NaN: night with the moon up.
		public float elevation;
		/// The camera's pitch (degrees, positive up).
		public float pitch;
		/// Look towards the sun (or the moon at night), else directly away from it.
		public bool toward;
		/// Look exactly at the sun: its disc in the picture's middle (the sun-behind-cloud shot).
		public bool atSun;
		/// The camera's height (m): above the slab's top (3300 m) sees the deck's tops, below it the bases.
		public float height;
	}

	struct CloudStats
	{
		/// Pixels the cloud changed against its cloudless partner.
		public int32 count;
		public float meanLum;
		/// The 20th and 95th brightest of the cloud's luminances: shaded bases against lit tops.
		public float p20;
		public float p95;
		/// Mean red minus mean blue: how warm (sunset) the cloud is.
		public float warmth;
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
	// The shots the checks compare, by name.
	uint8[] mNoonClear ~ delete _;
	uint8[] mNoonClouds ~ delete _;
	uint8[] mSunsetClear ~ delete _;
	uint8[] mNightClear ~ delete _;
	uint8[] mBehindClear ~ delete _;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Cloud lighting test");
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
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-cloud-lighting");
		Directory.CreateDirectory(mDir);
		Clouds.OverrideSeconds = CloudTime;
		Profiler.Enabled = true;
		// Clear then cloudy pairs (the clear shot is the mask's partner), then away from the sun, then the sun behind
		// the deck.
		mPhases.Add(.() { name = "noon-clear", clouds = false, coverage = 0, elevation = 55, pitch = 30, toward = true, height = 200 });
		mPhases.Add(.() { name = "noon-clouds", clouds = true, coverage = 0.45f, elevation = 55, pitch = 30, toward = true, height = 200 });
		mPhases.Add(.() { name = "noon-away", clouds = true, coverage = 0.45f, elevation = 55, pitch = 30, toward = false, height = 200 });
		mPhases.Add(.() { name = "sunset-clear", clouds = false, coverage = 0, elevation = 6, pitch = 10, toward = true, height = 200 });
		mPhases.Add(.() { name = "sunset-clouds", clouds = true, coverage = 0.4f, elevation = 6, pitch = 10, toward = true, height = 200 });
		mPhases.Add(.() { name = "night-clear", clouds = false, coverage = 0, elevation = float.NaN, pitch = 30, toward = true, height = 200 });
		mPhases.Add(.() { name = "night-clouds", clouds = true, coverage = 0.45f, elevation = float.NaN, pitch = 30, toward = true, height = 200 });
		mPhases.Add(.() { name = "behind-clear", clouds = false, coverage = 0, elevation = 45, pitch = 0, toward = true, atSun = true, height = 200 });
		mPhases.Add(.() { name = "behind-cloud", clouds = true, coverage = 0.95f, elevation = 45, pitch = 0, toward = true, atSun = true, height = 200 });

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
		env.moonSize = 1;
		// No fog over the sky: the cloud pass is what this test measures.
		env.volumetricFog = false;
		env.clouds = phase.clouds;
		env.cloudMode = .Volumetric;
		env.cloudCoverage = phase.coverage;
		Vector3 look;
		if (phase.elevation.IsNaN)
		{
			// Night: the day and hour with the moon highest and well lit (as --cloud-test sky).
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
			let moon = DayNight.MoonDirection(env);
			let flat = Vector3(moon.x, 0, moon.z);
			let yaw = flat.Length > 1e-4f ? flat.Normalized : Vector3(0, 0, 1);
			look = yaw * Math.Cos(phase.pitch * Mathf.Deg2Rad) + .(0, 1, 0) * Math.Sin(phase.pitch * Mathf.Deg2Rad);
		}
		else
		{
			// The afternoon hour with the sun at this height.
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
			if (phase.atSun)
				look = sun;
			else
			{
				let flat = Vector3(sun.x, 0, sun.z).Normalized;
				let yaw = phase.toward ? flat : -flat;
				look = yaw * Math.Cos(phase.pitch * Mathf.Deg2Rad) + .(0, 1, 0) * Math.Sin(phase.pitch * Mathf.Deg2Rad);
			}
		}
		look = look.Normalized;
		mCamera.fieldOfView = 75;
		mCamera.farClip = 20000;
		mCameraObject.Transform.Position = .(0, phase.height, 0);
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
		int64 sum = 0;
		for (int y < SkyRows)
			for (int x < ShotWidth)
			{
				let i = (y * ShotWidth + x) * 4;
				sum += pixels[i] + pixels[i + 1] + pixels[i + 2];
			}
		Check(sum > 0, scope $"{phase.name}: not black");
		if (!RenderView.CloudsRunnable)
			return;
		// Keep every cloudless shot, and the noon deck the others are compared with.
		if (phase.name == "noon-clear") { mNoonClear = pixels; return; }
		if (phase.name == "noon-clouds") { mNoonClouds = pixels; }
		else if (phase.name == "sunset-clear") { mSunsetClear = pixels; return; }
		else if (phase.name == "night-clear") { mNightClear = pixels; return; }
		else if (phase.name == "behind-clear") { mBehindClear = pixels; return; }

		// Every cloudless shot is done; the cloudy pairs are checked as they arrive.
		if (phase.name == "noon-clouds")
		{
			Check(mNoonClear != null, "noon: a cloudless partner exists");
			if (mNoonClear == null)
				return;
			let stats = Stats(mNoonClear, pixels);
			Console.WriteLine(scope $"cloud-test: noon cloud: {stats.count} px, mean {stats.meanLum:F1}, p20 {stats.p20:F1}, p95 {stats.p95:F1}, warmth {stats.warmth:F1}");
			Check(stats.count > 2000, scope $"noon: the deck covers the sky ({stats.count} px changed)");
			Check(stats.p95 - stats.p20 > 20, scope $"noon: lit tops and shaded bases ({stats.p20:F1}..{stats.p95:F1})");
			Check(stats.p95 > 170, scope $"noon: the sunlit tops and edges are white (p95 {stats.p95:F1})");
			Check(stats.p20 < 140, scope $"noon: the bases are grey, not white (p20 {stats.p20:F1})");
			Check(stats.meanLum < 250, scope $"noon: the deck is not blown white (mean {stats.meanLum:F1})");
			Check(gpu > 0, scope $"noon: the raymarch reports GPU time ({gpu:F3} ms)");
		}
		else if (phase.name == "noon-away")
		{
			if (mNoonClouds == null)
				return;
			let toward = MeanLum(mNoonClouds);
			let away = MeanLum(pixels);
			Console.WriteLine(scope $"cloud-test: noon sunward mean {toward:F1}, away {away:F1}");
			Check(toward > away + 2, scope $"noon: the sunward deck is brighter than away from the sun ({toward:F1} vs {away:F1})");
		}
		else if (phase.name == "sunset-clouds")
		{
			if (mSunsetClear == null || mNoonClouds == null || mNoonClear == null)
				return;
			let sunset = Stats(mSunsetClear, pixels);
			let noon = Stats(mNoonClear, mNoonClouds);
			Console.WriteLine(scope $"cloud-test: sunset cloud: {sunset.count} px, mean {sunset.meanLum:F1}, warmth {sunset.warmth:F1} (noon {noon.warmth:F1})");
			Check(sunset.count > 2000, scope $"sunset: the deck covers the sky ({sunset.count} px changed)");
			Check(sunset.warmth > noon.warmth + 8, scope $"sunset: the lit undersides are warmer ({sunset.warmth:F1} vs {noon.warmth:F1})");
		}
		else if (phase.name == "night-clouds")
		{
			if (mNightClear == null || mNoonClouds == null || mNoonClear == null)
				return;
			let night = Stats(mNightClear, pixels);
			let noon = Stats(mNoonClear, mNoonClouds);
			Console.WriteLine(scope $"cloud-test: night cloud: {night.count} px, mean {night.meanLum:F1} (noon {noon.meanLum:F1})");
			Check(night.count > 1000, scope $"night: the moonlit deck covers the sky ({night.count} px changed)");
			Check(night.meanLum > 0.5, scope $"night: the deck is moonlit, not black (mean {night.meanLum:F1})");
			Check(night.meanLum < noon.meanLum * 0.5, scope $"night: the deck is much darker than at noon ({night.meanLum:F1} vs {noon.meanLum:F1})");
		}
		else if (phase.name == "behind-cloud")
		{
			if (mBehindClear == null)
				return;
			// The sun's disc sits in the middle of the picture; an overcast deck in front of it must hide it.
			let clear = Region(0.4f, 0.4f, 0.6f, 0.6f, mBehindClear);
			let cloud = Region(0.4f, 0.4f, 0.6f, 0.6f, pixels);
			Console.WriteLine(scope $"cloud-test: sun behind a cloud: clear max {clear.maxLum:F1} / mean {clear.meanLum:F1}, cloud max {cloud.maxLum:F1} / mean {cloud.meanLum:F1}");
			Check(cloud.maxLum < clear.maxLum, scope $"the overcast deck hides the sun's disc (max {cloud.maxLum:F1} < {clear.maxLum:F1})");
			Check(cloud.maxLum < 250, scope $"the sun behind the deck is not a blown hole (max {cloud.maxLum:F1})");
		}
	}

	/// Statistics of the pixels the cloud changed against its cloudless partner (the pair's first shot), over the sky
	/// part of the picture; zero when there is no partner to compare with.
	static CloudStats Stats(uint8[] clear, uint8[] clouds)
	{
		CloudStats stats = default;
		if (clear == null || clouds == null || clear.Count != clouds.Count)
			return stats;
		var lum = scope List<float>();
		float rSum = 0;
		float bSum = 0;
		for (int32 y = 0; y < SkyRows; y++)
			for (int32 x = 0; x < ShotWidth; x++)
			{
				let i = (y * ShotWidth + x) * 4;
				let diff = Math.Abs((int32)clear[i] - (int32)clouds[i]) + Math.Abs((int32)clear[i + 1] - (int32)clouds[i + 1]) + Math.Abs((int32)clear[i + 2] - (int32)clouds[i + 2]);
				if (diff < MaskDiff)
					continue;
				lum.Add(Lum(clouds, i));
				rSum += clouds[i];
				bSum += clouds[i + 2];
			}
		stats.count = (int32)lum.Count;
		if (lum.Count == 0)
			return stats;
		lum.Sort();
		stats.p20 = lum[(int32)((lum.Count - 1) * 0.2f)];
		stats.p95 = lum[(int32)((lum.Count - 1) * 0.95f)];
		float total = 0;
		for (let value in lum)
			total += value;
		stats.meanLum = total / lum.Count;
		stats.warmth = (rSum - bSum) / lum.Count;
		return stats;
	}

	struct RegionStats
	{
		public float meanLum;
		public float maxLum;
	}

	/// The mean and brightest luminance of the picture's [x0, y0) - [x1, y1) share (fractions of the picture).
	static RegionStats Region(float x0, float y0, float x1, float y1, uint8[] pixels)
	{
		RegionStats stats = default;
		if (pixels == null)
			return stats;
		int32 a = (int32)(ShotWidth * x0);
		int32 b = (int32)(ShotWidth * x1);
		int32 c = (int32)(ShotHeight * y0);
		int32 d = (int32)(ShotHeight * y1);
		float total = 0;
		int32 count = 0;
		for (int32 y = c; y < d; y++)
			for (int32 x = a; x < b; x++)
			{
				let l = Lum(pixels, (y * ShotWidth + x) * 4);
				total += l;
				stats.maxLum = Math.Max(stats.maxLum, l);
				count++;
			}
		stats.meanLum = count > 0 ? total / count : 0;
		return stats;
	}

	/// The mean luminance of the sky part of a shot.
	static float MeanLum(uint8[] pixels)
	{
		if (pixels == null)
			return 0;
		float total = 0;
		for (int32 y = 0; y < SkyRows; y++)
			for (int32 x = 0; x < ShotWidth; x++)
				total += Lum(pixels, (y * ShotWidth + x) * 4);
		return total / (SkyRows * ShotWidth);
	}

	static float Lum(uint8[] pixels, int32 i) => pixels[i] * 0.2126f + pixels[i + 1] * 0.7152f + pixels[i + 2] * 0.0722f;

	void Finish()
	{
		Console.WriteLine(Result == 0 ? "cloud-test lighting: PASS" : "cloud-test lighting: FAILED");
		Close();
	}
}

/// `--cloud-test temporal [--cloud-test-folder <dir>]`: the temporal blend and the step budget (C2c). The weather
/// clock is advanced a frame at a time so the wind drifts deterministically. Shots: a still camera settled for a while
/// and one frame more (no shimmer: the consecutive frames are nearly the same), a teleport to a new place and the one
/// frame after it (the history must be dropped, so no ghost of the old view is blended in), the same place once it has
/// settled again, a smooth pan (the history stays, reprojected), that place settled, a ray-count debug view and a
/// budget shot. Writes a screenshot of each and checks: the cut drops the history and the cut frame matches the settled
/// one at the new place; the pan keeps the history and the moving frame matches the settled one at its end; the still
/// frames converge; the debug view shows varying ray counts; and the pass stays inside 1.5 ms at High (half res,
/// 48 steps). Needs Vulkan, Direct3D or Metal.
class CloudTemporalTestApp : Application
{
	const int32 ShotWidth = 640;
	const int32 ShotHeight = 360;
	const int32 SettleFrames = 32;
	/// Frames of the smooth pan: slow enough that every step stays under the history's 5 m cut.
	const int32 PanFrames = 20;
	/// The share of the picture above the horizon that the comparisons use.
	const int32 SkyRows = ShotHeight * 7 / 10;
	/// The weather clock the shots are drawn at; the cloud time moves on a frame at a time from here.
	const double CloudTime = 3600.0;
	/// The cloud pass's budget at High quality, half resolution and 48 steps (the spec's C2c check).
	const float BudgetMs = 1.5f;
	/// The most the settled frames' mean difference may be (of 255): temporal noise, not shimmer.
	const float ShimmerLimit = 4.0f;
	/// The most a cut or pan frame's mean difference from the settled frame may be: a ghost would be far larger.
	const float GhostLimit = 6.0f;

	public int32 Result;

	struct Phase
	{
		public StringView name;
		public Vector3 position;
		/// Degrees added to the sun's azimuth (the camera looks near the sun).
		public float yawOffset;
		public float pitch;
		public int32 settle;
		public GpuDriven.DebugView debug;
		/// Move from the previous phase's pose to this one over PanFrames (the moving camera).
		public bool pan;
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
	double mClock;
	float mBaseYaw;
	CompareShot mShot ~ delete _;
	// The shots the checks compare, by name.
	uint8[] mSettledA ~ delete _;
	uint8[] mCut ~ delete _;
	uint8[] mSettledQ ~ delete _;
	uint8[] mMoving ~ delete _;
	/// Whether the capture frame used last frame's layer (the cut must not, the stills and the pan must).
	bool mCaptureHistoryValid;
	/// Whether every frame of the pan reused the history.
	bool mPanHistoryValid = true;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Cloud temporal test");
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
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-cloud-temporal");
		Directory.CreateDirectory(mDir);
		Clouds.OverrideSeconds = CloudTime;
		Profiler.Enabled = true;
		// The still, one frame more, the budget shot (early, before the GPU has run flat out for a minute), a
		// teleport, the new place settled, a pan to a third place, it settled and the ray-count debug view.
		mPhases.Add(.() { name = "settled-a", position = .(0, 200, 0), yawOffset = 0, pitch = 20, settle = SettleFrames });
		mPhases.Add(.() { name = "settled-b", position = .(0, 200, 0), yawOffset = 0, pitch = 20, settle = 1 });
		mPhases.Add(.() { name = "budget", position = .(0, 200, 0), yawOffset = 0, pitch = 20, settle = 2 });
		mPhases.Add(.() { name = "cut", position = .(60, 200, 40), yawOffset = 20, pitch = 20, settle = 1 });
		mPhases.Add(.() { name = "settled-q", position = .(60, 200, 40), yawOffset = 20, pitch = 20, settle = SettleFrames });
		mPhases.Add(.() { name = "moving", position = .(90, 220, 70), yawOffset = 35, pitch = 22, settle = PanFrames + 1, pan = true });
		mPhases.Add(.() { name = "settled-r", position = .(90, 220, 70), yawOffset = 35, pitch = 22, settle = SettleFrames });
		mPhases.Add(.() { name = "rays", position = .(90, 220, 70), yawOffset = 35, pitch = 22, settle = 2, debug = .Clouds });

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

	void SetPose(Vector3 position, float yawOffset, float pitch)
	{
		let yaw = (mBaseYaw + yawOffset) * Mathf.Deg2Rad;
		let p = pitch * Mathf.Deg2Rad;
		let look = Vector3(Math.Sin(yaw) * Math.Cos(p), Math.Sin(p), Math.Cos(yaw) * Math.Cos(p)).Normalized;
		mCameraObject.Transform.Position = position;
		mCameraObject.Transform.Rotation = Quaternion.LookRotation(look, .(0, 1, 0));
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
		env.clouds = true;
		env.cloudMode = .Volumetric;
		env.cloudCoverage = 0.45f;
		// The afternoon hour with the sun 45 degrees up (as --cloud-test volume).
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
		mBaseYaw = Math.Atan2(sun.x, sun.z) * Mathf.Rad2Deg;
		mCamera.fieldOfView = 75;
		mCamera.farClip = 20000;
		DayNight.Apply(mScene);
		GpuDriven.View = phase.debug;
		if (!phase.pan)
			SetPose(phase.position, phase.yawOffset, phase.pitch);
		mCaptureHistoryValid = false;
		mPanHistoryValid = true;
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
		let phase = mPhases[mPhase];
		if (phase.pan)
		{
			// From the previous phase's pose to this one, eased, a frame at a time: the camera moves and turns
			// smoothly, so the history may still be reused (reprojected).
			let from = mPhases[mPhase - 1];
			float t = Math.Clamp((float)mFrame / PanFrames, 0.0f, 1.0f);
			t = t * t * (3.0f - 2.0f * t);
			let position = from.position + (phase.position - from.position) * t;
			SetPose(position, from.yawOffset + (phase.yawOffset - from.yawOffset) * t, from.pitch + (phase.pitch - from.pitch) * t);
		}
		// The cloud clock moves on a frame at a time, so the wind drift (and its reprojection) is deterministic.
		Clouds.OverrideSeconds = CloudTime + mClock;
		mClock += 1.0 / 60.0;
		mView.Resize(ShotWidth, ShotHeight);
		mView.Render(mScene, mCamera.GetCameraData((float)ShotWidth / ShotHeight));
		if (phase.pan)
			mPanHistoryValid &= mView.CloudHistoryValid;
		mFrame++;
		if (mFrame < phase.settle)
			return;
		if (mShot == null)
		{
			mCaptureHistoryValid = mView.CloudHistoryValid;
			mShot = new CompareShot();
		}
		let path = scope $"{mDir}/{phase.name}.png";
		if (mShot.Step(mView, ShotWidth, ShotHeight, path))
		{
			let pixels = mShot.Pixels;
			let copy = new uint8[pixels.Count];
			Internal.MemCpy(copy.CArray(), pixels.CArray(), pixels.Count);
			CheckShot(phase, copy);
			mFrame = -1;
		}
	}

	void CheckShot(Phase phase, uint8[] pixels)
	{
		let gpu = ProfilerModules.VolumetricCloudsMs;
		Console.WriteLine(scope $"cloud-test: {phase.name}: pixels {RenderView.VolumetricCloudPixels}, steps {RenderView.CloudSteps}, rays {RenderView.VolumetricCloudRays}, GPU {gpu:F3} ms, history {(mCaptureHistoryValid ? "kept" : "dropped")}");
		float total = 0;
		float minLum = 255;
		float maxLum = 0;
		for (int32 y = 0; y < SkyRows; y++)
			for (int32 x = 0; x < ShotWidth; x++)
			{
				let l = Lum(pixels, (y * ShotWidth + x) * 4);
				total += l;
				minLum = Math.Min(minLum, l);
				maxLum = Math.Max(maxLum, l);
			}
		Check(total > 0, scope $"{phase.name}: not black");
		if (!RenderView.CloudsRunnable)
			return;
		if (phase.name == "settled-a")
		{
			mSettledA = pixels;
			Check(mCaptureHistoryValid, "settled: last frame's layer is reused");
		}
		else if (phase.name == "settled-b")
		{
			if (mSettledA == null)
				return;
			let d = MeanDiff(mSettledA, pixels);
			Console.WriteLine(scope $"cloud-test: settled frame-to-frame mean difference {d:F2} of 255");
			Check(mCaptureHistoryValid, "settled: the second frame still reuses the layer");
			Check(d < ShimmerLimit, scope $"still camera: no shimmer between frames (mean difference {d:F2} < {ShimmerLimit:F1})");
			mSettledA = null;
		}
		else if (phase.name == "cut")
		{
			mCut = pixels;
			Check(!mCaptureHistoryValid, "a camera cut drops the history (no ghost of the old view)");
		}
		else if (phase.name == "settled-q")
		{
			mSettledQ = pixels;
			Check(mCaptureHistoryValid, "after the cut the history builds again");
			if (mCut != null)
			{
				let d = MeanDiff(mCut, pixels);
				Console.WriteLine(scope $"cloud-test: cut frame to settled frame mean difference {d:F2} of 255");
				Check(d < GhostLimit, scope $"the cut frame is the new view, not a ghost (mean difference {d:F2} < {GhostLimit:F1})");
			}
		}
		else if (phase.name == "moving")
		{
			mMoving = pixels;
			Check(mPanHistoryValid, "a smooth pan keeps the history (reprojected by the slab midpoint)");
		}
		else if (phase.name == "settled-r")
		{
			if (mMoving == null)
				return;
			let d = MeanDiff(mMoving, pixels);
			Console.WriteLine(scope $"cloud-test: moving frame to settled frame mean difference {d:F2} of 255");
			Check(d < GhostLimit, scope $"the moving frame is the settled view, not a ghost (mean difference {d:F2} < {GhostLimit:F1})");
		}
		else if (phase.name == "rays")
		{
			Console.WriteLine(scope $"cloud-test: ray count view {minLum:F0}..{maxLum:F0} of 255, mean {total / (SkyRows * ShotWidth):F0}");
			Check(maxLum > 0, "the debug view shows the ray counts");
			Check(maxLum - minLum > 12, scope $"ray counts vary across the sky ({minLum:F0}..{maxLum:F0})");
		}
		else if (phase.name == "budget")
		{
			Check(RenderView.VolumetricCloudPixels > 0 && RenderView.VolumetricCloudRays > 0, "the pass has pixels and rays");
			Check(gpu > 0 && gpu <= BudgetMs, scope $"the cloud pass is inside its budget ({gpu:F3} ms <= {BudgetMs:F1} ms at High, half res, {RenderView.CloudSteps} steps)");
		}
	}

	/// The mean absolute difference of two shots over the sky part, per channel (0..255).
	static float MeanDiff(uint8[] a, uint8[] b)
	{
		if (a == null || b == null || a.Count != b.Count)
			return float.MaxValue;
		int64 sum = 0;
		for (int32 y = 0; y < SkyRows; y++)
			for (int32 x = 0; x < ShotWidth; x++)
			{
				let i = (y * ShotWidth + x) * 4;
				for (int32 c < 3)
					sum += Math.Abs((int32)a[i + c] - (int32)b[i + c]);
			}
		return (float)sum / (SkyRows * ShotWidth * 3);
	}

	static float Lum(uint8[] pixels, int32 i) => pixels[i] * 0.2126f + pixels[i + 1] * 0.7152f + pixels[i + 2] * 0.0722f;

	void Finish()
	{
		GpuDriven.View = .Off;
		Console.WriteLine(Result == 0 ? "cloud-test temporal: PASS" : "cloud-test temporal: FAILED");
		Close();
	}
}
