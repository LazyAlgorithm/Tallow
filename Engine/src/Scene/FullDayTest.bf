using System;
using System.Collections;
using System.Diagnostics;
using System.IO;

namespace Tallow;

/// `--daynight-test --full-day <seconds> [--shots <folder>]` (D1e, tallowengine.com/docs/day-night): plays a whole
/// day in that many real seconds (default 60) in a small scene (ground, boxes, a sun, a moon and a street light marked
/// Only At Night) with the physical sky and reflections on, and checks the scene reacts: the sky's reflection cube is
/// re-made in steps (no more than once every Reflections.SkyMinimumFrames frames, and no frame-time spike when it
/// is), the sun's shadows are drawn by day and not at night (the moon's with Moon Shadows on), the street light is
/// off at noon and on at 23:00. Then,
/// with the clock stopped at 15:00, a screenshot pair: the same time twice (identical shadows) and one second of a
/// 24-minute day later (only shadow edges move: no swimming). Needs a window; add --profile-report for the
/// profiler's view.
class FullDayTestApp : Application
{
	const int32 ShotWidth = 640;
	const int32 ShotHeight = 360;
	const int WarmUpFrames = 90;
	const int SettleFrames = 45;

	public int32 Result;

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	Light mStreetLight;
	float mSeconds = 60;
	String mDir = new .() ~ delete _;
	Stopwatch mClock = new .() ~ delete _;
	Stopwatch mDayClock = new .() ~ delete _;
	int64 mLastTicks;
	int mFrame;
	// Frame times (ms) during the day, after the warm-up, and whether a sky rebuild was under way in that frame.
	List<float> mFrameMs = new .() ~ delete _;
	List<bool> mRebuilding = new .() ~ delete _;
	int32 mCapturesAtStart;
	int64 mLastCaptureFrame = -1;
	int32 mMinCaptureGap = int32.MaxValue;
	float mLastHour;
	bool mSawNoon, mSawLate, mSawMidnight;
	int32 mLightsNoon, mLightsLate;
	bool mShadowsNoon, mShadowsMidnight;
	// 0: the day; -1: a moonlit night; 1, 2, 3: the screenshot pair's shots.
	int mStage;
	int mStageFrame;
	CompareShot mShot ~ delete _;
	List<uint8[]> mShots = new .() ~ DeleteContainerAndItems!(_);

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Full day test");
		Width = ShotWidth;
		Height = ShotHeight;
	}

	void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"full-day: {ok ? "ok" : "FAIL"} {what}");
		if (!ok)
			Result = 1;
	}

	protected override bool OnInit()
	{
		let seconds = scope String();
		if (GetArg("--full-day", seconds) && float.Parse(seconds) case .Ok(let value) && value > 1)
			mSeconds = value;
		if (!GetArg("--shots", mDir) || mDir.IsEmpty || mDir.StartsWith("--"))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-full-day-test");
		Directory.CreateDirectory(mDir);

		mScene = new Scene();
		let cameraObject = mScene.CreateGameObject("Camera");
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 60;
		mCamera.farClip = 1000;
		cameraObject.Transform.Position = .(0, 9, -20);
		cameraObject.Transform.Rotation = Quaternion.LookRotation(Vector3(0, -9, 20).Normalized, .(0, 1, 0));
		let sunObject = mScene.CreateGameObject("Sun");
		let sun = sunObject.AddComponent<Light>();
		sun.intensity = 1.5f;
		let moonObject = mScene.CreateGameObject("Moon");
		let moon = moonObject.AddComponent<Light>();
		moon.intensity = 0.05f;
		let ground = mScene.CreateGameObject("Ground");
		let groundRenderer = ground.AddComponent<MeshRenderer>();
		groundRenderer.mesh.Set("builtin:plane");
		groundRenderer.color = .FromBytes(150, 150, 140);
		ground.Transform.LocalScale = .(60, 1, 60);
		for (int i < 5)
		{
			let building = mScene.CreateGameObject("Building");
			let renderer = building.AddComponent<MeshRenderer>();
			renderer.mesh.Set("builtin:cube");
			renderer.color = .FromBytes(200, 190, 170);
			let height = 2.0f + i * 1.5f;
			building.Transform.Position = .(-8 + i * 4, height * 0.5f, 2 + (i % 2) * 3);
			building.Transform.LocalScale = .(2, height, 2);
		}
		let lamp = mScene.CreateGameObject("Street light");
		lamp.Transform.Position = .(0, 3, -4);
		mStreetLight = lamp.AddComponent<Light>();
		mStreetLight.type = .Point;
		mStreetLight.range = 12;
		mStreetLight.intensity = 3;
		mStreetLight.castShadows = false;
		mStreetLight.color = .(1, 0.8f, 0.55f);
		mStreetLight.onlyAtNight = true;

		let env = mScene.Environment;
		env.skyMode = .Physical;
		env.dayNight = true;
		env.autoColors = true;
		env.sunIntensity = Atmosphere.ReferenceSunIntensity;
		env.sunLight = sunObject.Id;
		env.moonLight = moonObject.Id;
		// The moon's shadows off, so the night has none (the moon's own are optional).
		env.moonShadows = false;
		env.dayOfYear = 172;
		env.latitude = 40;
		env.timeOfDay = 0;
		env.dayLengthMinutes = mSeconds / 60;
		env.dayNightPaused = true;
		env.shadowDistance = 60;
		// Only At Night is saved with the light.
		{
			let text = scope String();
			SceneSerializer.Save(mScene, text);
			let back = scope Scene();
			SceneSerializer.Load(back, text);
			bool found = false;
			for (let light in back.Lights)
				found |= light.onlyAtNight && light.type == .Point;
			Check(found, "Only At Night saved and loaded");
		}
		Check(DayNight.NightFactor(env) == 1, "midnight: Only At Night fully on");
		env.timeOfDay = 12;
		Check(DayNight.NightFactor(env) == 0, "noon: Only At Night off");
		env.timeOfDay = 0;
		env.dayNight = false;
		Check(DayNight.NightFactor(env) == 1, "Day / Night off: Only At Night always on");
		env.dayNight = true;
		DayNight.Apply(mScene);
		mView = new RenderView(10);
		mView.AllowPostAa = false;
		mScene.StartPlay();
		mClock.Start();
		Console.WriteLine(scope $"full-day: a day in {mSeconds} s, shots in {mDir}");
		return true;
	}

	protected override void OnUpdate()
	{
		mScene.Update();
		AssetLoader.Update();
	}

	protected override void OnRender()
	{
		let now = mClock.ElapsedMicroseconds;
		let frameMs = (float)((now - mLastTicks) / 1000.0);
		mLastTicks = now;
		mView.Resize(ShotWidth, ShotHeight);
		let capturesBefore = Reflections.SkyCaptures;
		mView.Render(mScene, mCamera.GetCameraData((float)ShotWidth / ShotHeight));
		mFrame++;
		if (mStage == 0)
			DayFrame(frameMs, capturesBefore);
		else if (mStage < 0)
			MoonFrame();
		else
			ShotFrame();
	}

	void DayFrame(float frameMs, int32 capturesBefore)
	{
		let env = mScene.Environment;
		if (mFrame == WarmUpFrames)
		{
			// Warmed up (shaders and tables made): start the clock.
			env.dayNightPaused = false;
			mCapturesAtStart = Reflections.SkyCaptures;
			mLastHour = env.timeOfDay;
			mDayClock.Start();
			return;
		}
		if (mFrame < WarmUpFrames)
			return;
		mFrameMs.Add(frameMs);
		let captured = Reflections.SkyCaptures != capturesBefore;
		// A rebuild draws the faces then one filter level a frame: mark the frames round each one finishing.
		mRebuilding.Add(captured);
		if (captured)
		{
			if (mLastCaptureFrame >= 0)
				mMinCaptureGap = Math.Min(mMinCaptureGap, (int32)(mFrame - mLastCaptureFrame));
			mLastCaptureFrame = mFrame;
		}
		let hour = env.timeOfDay;
		bool Crossed(float at) => mLastHour < at && hour >= at;
		if (Crossed(12))
		{
			mSawNoon = true;
			mLightsNoon = mView.LightCount;
			mShadowsNoon = mView.SunShadowsDrawn;
			Console.WriteLine(scope $"full-day: 12:00 lights {mView.LightCount}, sun shadows {mView.SunShadowsDrawn}, night factor {DayNight.NightFactor(env):F2}");
		}
		if (Crossed(23))
		{
			mSawLate = true;
			mLightsLate = mView.LightCount;
			Console.WriteLine(scope $"full-day: 23:00 lights {mView.LightCount}, sun shadows {mView.SunShadowsDrawn}, night factor {DayNight.NightFactor(env):F2}");
		}
		if (hour < 0.5f || hour >= 23.5f)
		{
			mSawMidnight = true;
			mShadowsMidnight |= mView.SunShadowsDrawn;
		}
		mLastHour = hour;
		if (mDayClock.Elapsed.TotalSeconds >= mSeconds)
			FinishDay();
	}

	void FinishDay()
	{
		let env = mScene.Environment;
		env.dayNightPaused = true;
		let frames = mFrameMs.Count;
		let captures = Reflections.SkyCaptures - mCapturesAtStart;
		let sorted = scope List<float>(mFrameMs);
		sorted.Sort();
		let median = sorted[frames / 2];
		let p99 = sorted[Math.Min(frames - 1, frames * 99 / 100)];
		let worst = sorted[frames - 1];
		// Frames with a rebuild finishing, against the rest.
		float rebuildWorst = 0, otherWorst = 0, rebuildSum = 0, otherSum = 0;
		int rebuildCount = 0;
		for (int i < frames)
		{
			if (mRebuilding[i])
			{
				rebuildWorst = Math.Max(rebuildWorst, mFrameMs[i]);
				rebuildSum += mFrameMs[i];
				rebuildCount++;
			}
			else
			{
				otherWorst = Math.Max(otherWorst, mFrameMs[i]);
				otherSum += mFrameMs[i];
			}
		}
		let rebuildMean = rebuildCount > 0 ? rebuildSum / rebuildCount : 0;
		let otherMean = frames > rebuildCount ? otherSum / (frames - rebuildCount) : 0;
		Console.WriteLine(scope $"full-day: {frames} frames, frame ms median {median:F2} p99 {p99:F2} max {worst:F2}");
		Console.WriteLine(scope $"full-day: {captures} sky rebuilds (closest {mMinCaptureGap} frames apart); rebuild frames mean {rebuildMean:F2} ms max {rebuildWorst:F2}, others mean {otherMean:F2} max {otherWorst:F2}");
		// The sun turns 360 degrees: at most one rebuild every half degree, and one every SkyMinimumFrames frames.
		Check(captures > 4, "the sky's cube is re-made as the sun moves");
		Check(captures <= (int32)(360 / Reflections.SkyAngleStep) + 1 && captures <= frames / Reflections.SkyMinimumFrames + 2, "the sky's cube is not re-made every frame");
		Check(mMinCaptureGap >= Reflections.SkyMinimumFrames, scope $"rebuilds at least {Reflections.SkyMinimumFrames} frames apart");
		// No spike from a rebuild: those frames cost about what the others do (budget: a 30 fps frame, or twice the
		// usual frame on a slow machine).
		let budget = Math.Max(1000.0f / 30, median * 2);
		Check(rebuildWorst <= budget, scope $"no rebuild frame over budget ({rebuildWorst:F2} <= {budget:F2} ms)");
		Check(rebuildMean <= otherMean * 1.5f + 1, "rebuild frames cost about what others do");
		Check(mSawNoon && mSawLate, "the day passed noon and 23:00");
		Check(mShadowsNoon, "sun shadows at noon");
		Check(mSawMidnight && !mShadowsMidnight, "no shadows round midnight (sun down, Moon Shadows off)");
		Check(mLightsLate == mLightsNoon + 1, "the Only At Night light is off at noon and on at 23:00");
		// Moon Shadows: a night with the moon well up and well lit, and the sun far down.
		env.moonShadows = true;
		for (int32 day = 0; day < 365 && !mMoonNight; day++)
		{
			env.dayOfYear = day;
			for (float hour in float[?](22, 23, 0, 1, 2))
			{
				env.timeOfDay = hour;
				if (DayNight.SunElevation(env) < -15 && DayNight.MoonDirection(env).y > 0.4f && DayNight.MoonIllumination(env) > 0.6f)
				{
					mMoonNight = true;
					break;
				}
			}
		}
		Check(mMoonNight, "found a moonlit night");
		DayNight.Apply(mScene);
		mStage = -1;
		mStageFrame = 0;
	}

	bool mMoonNight;

	void MoonFrame()
	{
		mStageFrame++;
		if (mStageFrame < 3)
			return;
		let env = mScene.Environment;
		Console.WriteLine(scope $"full-day: moonlit night day {env.dayOfYear} {env.timeOfDay}:00, shadows {mView.SunShadowsDrawn}");
		Check(mView.SunShadowsDrawn, "Moon Shadows: the moon casts the shadows at night");
		env.moonShadows = false;
		// The screenshot pair at 15:00.
		env.dayOfYear = 172;
		env.timeOfDay = 15;
		DayNight.Apply(mScene);
		mStage = 1;
		mStageFrame = 0;
	}

	void ShotFrame()
	{
		mStageFrame++;
		if (mStageFrame < SettleFrames)
			return;
		if (mShot == null)
			mShot = new CompareShot();
		let names = StringView[?]("shadow-a", "shadow-a-again", "shadow-b");
		if (!mShot.Step(mView, ShotWidth, ShotHeight, scope $"{mDir}/{names[mStage - 1]}.png"))
			return;
		let pixels = new uint8[ShotWidth * ShotHeight * 4];
		mShot.Pixels.CopyTo(pixels);
		mShots.Add(pixels);
		DeleteAndNullify!(mShot);
		mStage++;
		mStageFrame = 0;
		if (mStage == 3)
		{
			// One second of a 24-minute day later: a quarter of a degree.
			mScene.Environment.timeOfDay = 15 + 1 / 60.0f;
			DayNight.Apply(mScene);
		}
		if (mStage > 3)
			Finish();
	}

	/// The share of the ground's pixels (the lower two thirds) that differ by more than 12 levels in any channel.
	float Changed(uint8[] a, uint8[] b)
	{
		int changed = 0, total = 0;
		for (int y = ShotHeight / 3; y < ShotHeight; y++)
		{
			for (int x < ShotWidth)
			{
				let i = (y * ShotWidth + x) * 4;
				total++;
				for (int c < 3)
				{
					if (Math.Abs((int)a[i + c] - (int)b[i + c]) > 12)
					{
						changed++;
						break;
					}
				}
			}
		}
		return (float)changed / total;
	}

	void Finish()
	{
		let same = Changed(mShots[0], mShots[1]);
		let later = Changed(mShots[0], mShots[2]);
		Console.WriteLine(scope $"full-day: shadow pair changed pixels: same time {same * 100:F3}%, one second later {later * 100:F3}%");
		Check(same < 0.001f, "the same time twice: the same shadows");
		Check(later < 0.02f, "one second later: only shadow edges move (no swimming)");
		Console.WriteLine(Result == 0 ? "full-day: PASS" : "full-day: FAILED");
		Close();
	}
}
