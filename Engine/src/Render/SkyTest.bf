using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// --sky-test <folder>: draws the sky (tallowengine.com/docs/day-night) at set times and writes a screenshot of each
/// into the folder: the old Gradient sky with a hand-placed sun (gradient.png, to compare with a shot from before the
/// physical sky), then the Physical sky at noon, golden hour, sunset and night. Checks the shots are not black, the
/// sunsets are redder than noon and the night shows stars. Needs a window. With --sky-preetham the physical sky is the
/// analytic fallback (as on OpenGL / WebGL).
class SkyTestApp : Application
{
	const int32 ShotWidth = 640;
	const int32 ShotHeight = 360;
	const int SettleFrames = 24;

	public int32 Result;

	struct Phase
	{
		public StringView name;
		public bool physical;
		// The sun's height to find in the afternoon (degrees), or NaN: night with the moon up.
		public float elevation;
		// The camera's field of view (degrees).
		public float fov = 80;
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
	// Each shot's mean colour of the sky (top half), linear-ish 0..1.
	List<Vector3> mMeans = new .() ~ delete _;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Sky test");
		Width = ShotWidth;
		Height = ShotHeight;
	}

	void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"sky-test: {ok ? "ok" : "FAIL"} {what}");
		if (!ok)
			Result = 1;
	}

	protected override bool OnInit()
	{
		if (!GetArg("--sky-test", mDir) || mDir.IsEmpty || mDir.StartsWith("--"))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-sky-test");
		Directory.CreateDirectory(mDir);
		mPhases.Add(.() { name = "gradient", physical = false });
		mPhases.Add(.() { name = "noon", physical = true, elevation = 90 });
		mPhases.Add(.() { name = "golden", physical = true, elevation = 6 });
		mPhases.Add(.() { name = "sunset", physical = true, elevation = 0.5f });
		mPhases.Add(.() { name = "night", physical = true, elevation = float.NaN });
		mPhases.Add(.() { name = "moon", physical = true, elevation = float.NaN, fov = 2 });

		mScene = new Scene();
		let cameraObject = mScene.CreateGameObject("Camera");
		mCameraObject = cameraObject;
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 80;
		mCamera.farClip = 2000;
		cameraObject.Transform.Position = .(0, 2, 0);
		mSunObject = mScene.CreateGameObject("Sun");
		mSunObject.Transform.EulerAngles = .(20, -30, 0);
		let light = mSunObject.AddComponent<Light>();
		light.intensity = 1.5f;
		let ground = mScene.CreateGameObject("Ground");
		let renderer = ground.AddComponent<MeshRenderer>();
		renderer.mesh.Set("builtin:plane");
		renderer.color = .FromBytes(112, 158, 92);
		ground.Transform.LocalScale = .(100, 1, 100);
		// The physical sky's settings are saved with the scene (and a Gradient scene saves none of them).
		{
			let text = scope String();
			SceneSerializer.Save(mScene, text);
			Check(!text.Contains("skyMode"), "a Gradient scene saves no sky mode");
			let env = mScene.Environment;
			env.skyMode = .Physical;
			env.skyBrightness = 1.25f;
			env.starBrightness = 2;
			env.moonSize = 1.5f;
			env.sunDiscSize = 0.75f;
			env.turbidity = 4;
			text.Clear();
			SceneSerializer.Save(mScene, text);
			let back = scope Scene();
			SceneSerializer.Load(back, text);
			let b = back.Environment;
			Check(b.skyMode == .Physical && b.skyBrightness == 1.25f && b.starBrightness == 2 && b.moonSize == 1.5f && b.sunDiscSize == 0.75f && b.turbidity == 4, "physical sky settings saved and loaded");
			env.Reset();
		}
		mView = new RenderView(10);
		mView.AllowPostAa = false;
		mScene.StartPlay();
		return true;
	}

	void StartPhase(Phase phase)
	{
		let env = mScene.Environment;
		env.Reset();
		mCamera.fieldOfView = phase.fov;
		if (!phase.physical)
		{
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
			// Night: the day and hour of the year with the moon highest and well lit, the sun far below.
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
			look = moon;
			Console.WriteLine(scope $"sky-test: night day {bestDay} {bestHour}:00, moon {best:F1} degrees up, lit {DayNight.MoonIllumination(env):F2}");
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
			// Towards the sun, a little above the horizon (high noon: the sky round it).
			look = Vector3(sun.x, 0, sun.z).Normalized;
			look.y = 0.25f;
			Console.WriteLine(scope $"sky-test: {phase.name} at {bestHour:F2} h, sun {DayNight.SunElevation(env):F1} degrees up");
		}
		mCameraObject.Transform.Rotation = Quaternion.LookRotation(look.Normalized, .(0, 1, 0));
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
			Check(!mPhases[mPhase].physical || PhysicalSky.Mode(mScene.Environment) == (PhysicalSky.Supported ? 1 : 2), scope $"{mPhases[mPhase].name}: drawn with the {PhysicalSky.Supported ? "sky tables" : "Preetham sky"}");
			Measure(mPhases[mPhase], mShot.Pixels);
			mFrame = -1;
		}
	}

	void Measure(Phase phase, uint8[] pixels)
	{
		Vector3 sum = .Zero;
		for (int y < ShotHeight / 2)
		{
			for (int x < ShotWidth)
			{
				let i = (y * ShotWidth + x) * 4;
				sum += Vector3(pixels[i], pixels[i + 1], pixels[i + 2]) / 255.0f;
			}
		}
		let mean = sum / (ShotWidth * ShotHeight / 2);
		mMeans.Add(mean);
		// Small bright points (stars): a pixel brighter than its neighbours two pixels away, in the top half.
		int points = 0;
		float brightest = 0;
		for (int y = 2; y < ShotHeight / 2; y++)
		{
			for (int x = 2; x < ShotWidth - 2; x++)
			{
				let v = (float)pixels[(y * ShotWidth + x) * 4 + 1];
				brightest = Math.Max(brightest, v / 255.0f);
				let around = Math.Max(Math.Max((float)pixels[(y * ShotWidth + x - 2) * 4 + 1], (float)pixels[(y * ShotWidth + x + 2) * 4 + 1]),
					Math.Max((float)pixels[((y - 2) * ShotWidth + x) * 4 + 1], (float)pixels[((y + 2) * ShotWidth + x) * 4 + 1]));
				if (v > 40 && v > around * 2)
					points++;
			}
		}
		Console.WriteLine(scope $"sky-test: {phase.name} sky mean {mean.x:F3} {mean.y:F3} {mean.z:F3}, brightest {brightest:F2}, points {points}");
		if (phase.physical)
			Check(mean.x + mean.y + mean.z > 0.01f, scope $"{phase.name}: not black");
		if (phase.elevation.IsNaN && phase.fov > 10)
		{
			Check(points >= 10, "night: stars");
			Check(brightest > 0.4f, "night: the moon");
		}
		else if (phase.elevation.IsNaN)
		{
			// Close up: the moon's lit disc fills a good part of the middle.
			int lit = 0;
			for (int i < ShotWidth * ShotHeight)
				lit += pixels[i * 4 + 1] > 100 ? 1 : 0;
			Console.WriteLine(scope $"sky-test: moon lit pixels {lit}");
			Check(lit > 5000, "moon: a lit disc");
		}
	}

	void Finish()
	{
		Check(mMeans.Count == mPhases.Count, "every shot taken");
		if (mMeans.Count == mPhases.Count)
		{
			// Redness (red over blue): noon < golden hour < sunset; noon is blue.
			float Red(Vector3 c) => c.x / Math.Max(c.z, 1e-3f);
			Check(Red(mMeans[1]) < 1, "noon: a blue sky");
			Check(Red(mMeans[2]) > Red(mMeans[1]) && Red(mMeans[3]) > Red(mMeans[1]), "golden hour and sunset redder than noon");
			Check(mMeans[4].Length < mMeans[1].Length * 0.5f, "night darker than noon");
		}
		Console.WriteLine(Result == 0 ? "sky-test: PASS" : "sky-test: FAILED");
		Close();
	}
}
