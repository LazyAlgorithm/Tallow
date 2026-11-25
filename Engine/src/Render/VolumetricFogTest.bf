using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

/// --vfog-test [folder]: draws volumetric fog (tallowengine.com/docs/day-night) and writes screenshots into the folder
/// (default: a scratch folder): the same scene with it off, with it on, and off again. A wall with a gap has the sun
/// behind it, so with the fog on a shaft of light shows through the gap while the fog behind the wall stays dark.
/// Checks the shaft is brighter than the fog in the wall's shadow, that the off shots match, and logs the pass's GPU
/// time. Needs a window and a backend with compute shaders (Vulkan, Direct3D 11/12 or Metal); elsewhere it skips.
class VolumetricFogTestApp : Application
{
	const int32 ShotWidth = 640;
	const int32 ShotHeight = 360;
	const int SettleFrames = 20;

	public int32 Result;

	struct Phase
	{
		public StringView name;
		public bool volumetric;
	}

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	String mDir = new .() ~ delete _;
	List<Phase> mPhases = new .() ~ delete _;
	int mPhase = -1;
	int mFrame;
	CompareShot mShot ~ delete _;
	// The fog-off shot's pixels (to compare with the fog-off-again shot), and the regions' brightness at each phase.
	uint8[] mOffPixels ~ delete _;
	float mGapOff, mShadowOff, mSkyOff;
	float mGapOn, mShadowOn, mSkyOn;
	int mChangedOff;
	bool mSkip;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Volumetric fog test");
		Width = ShotWidth;
		Height = ShotHeight;
	}

	void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"vfog-test: {ok ? "ok" : "FAIL"} {what}");
		if (!ok)
			Result = 1;
	}

	protected override bool OnInit()
	{
		if (!GetArg("--vfog-test", mDir) || mDir.IsEmpty || mDir.StartsWith("--"))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-vfog-test");
		Directory.CreateDirectory(mDir);
		let renderer = bgfx.get_renderer_type();
		if (renderer != .Vulkan && renderer != .Metal && renderer != .Direct3D11 && renderer != .Direct3D12)
		{
			Console.WriteLine(scope $"vfog-test: skipped (needs Vulkan, Direct3D or Metal; this is {renderer})");
			mSkip = true;
			return true;
		}
		// The GPU pass times only show while the profiler is recording.
		Profiler.Enabled = true;
		mPhases.Add(.() { name = "off" });
		mPhases.Add(.() { name = "on", volumetric = true });
		mPhases.Add(.() { name = "off-again" });

		mScene = new Scene();
		let cameraObject = mScene.CreateGameObject("Camera");
		mCameraObject = cameraObject;
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 50;
		mCamera.farClip = 400;
		cameraObject.Transform.Position = .(0, 2, 0);
		// The ground and a far, dark backdrop, so the gap's light shows against it.
		let ground = mScene.CreateGameObject("Ground");
		let groundRenderer = ground.AddComponent<MeshRenderer>();
		groundRenderer.mesh.Set("builtin:plane");
		groundRenderer.color = .FromBytes(80, 92, 80);
		ground.Transform.LocalScale = .(200, 1, 200);
		let backdrop = mScene.CreateGameObject("Backdrop");
		let backdropRenderer = backdrop.AddComponent<MeshRenderer>();
		backdropRenderer.mesh.Set("builtin:cube");
		backdropRenderer.color = .FromBytes(18, 18, 22);
		backdrop.Transform.Position = .(0, 20, 120);
		backdrop.Transform.LocalScale = .(300, 80, 1);
		// A wall with a two-metre gap at the middle, its face towards the camera.
		let left = mScene.CreateGameObject("Wall left");
		let leftRenderer = left.AddComponent<MeshRenderer>();
		leftRenderer.mesh.Set("builtin:cube");
		leftRenderer.color = .FromBytes(140, 132, 120);
		left.Transform.Position = .(-9, 5, 40);
		left.Transform.LocalScale = .(16, 10, 1);
		let right = mScene.CreateGameObject("Wall right");
		let rightRenderer = right.AddComponent<MeshRenderer>();
		rightRenderer.mesh.Set("builtin:cube");
		rightRenderer.color = .FromBytes(140, 132, 120);
		right.Transform.Position = .(9, 5, 40);
		right.Transform.LocalScale = .(16, 10, 1);
		// The sun behind the wall (coming towards the camera, a little down), so the wall shadows the fog and its gap
		// lets a shaft through.
		let sunObject = mScene.CreateGameObject("Sun");
		let sun = sunObject.AddComponent<Light>();
		sun.intensity = 2.0f;
		sun.castShadows = true;
		sunObject.Transform.Rotation = Quaternion.LookRotation(Vector3(0, -0.2f, -1).Normalized, .Up);

		let env = mScene.Environment;
		env.skyMode = .Physical;
		env.dayNight = false;
		env.autoColors = false;
		env.shadowDistance = 60;
		// No distance fog at all: only the volumetric fog changes the picture.
		env.fogDensity = 0;
		env.volumetricFog = true;
		env.vfDensity = 0.05f;
		env.vfHeight = 0;
		env.vfFalloff = 0.02f;
		env.vfAnisotropy = 0.6f;
		env.vfSunScattering = 1;
		env.vfAmbient = 0.1f;
		env.vfDistance = 80;

		mView = new RenderView(10);
		mView.AllowPostAa = false;
		mScene.StartPlay();
		return true;
	}

	protected override void OnUpdate()
	{
		if (mSkip)
			return;
		mScene.Update();
		AssetLoader.Update();
	}

	float RegionMean(uint8[] pixels, float x0, float x1, float y0, float y1)
	{
		int xa = (int)(x0 * ShotWidth), xb = (int)(x1 * ShotWidth);
		int ya = (int)(y0 * ShotHeight), yb = (int)(y1 * ShotHeight);
		double sum = 0;
		for (int y = ya; y < yb; y++)
		{
			for (int x = xa; x < xb; x++)
			{
				let i = (y * ShotWidth + x) * 4;
				sum += (0.2126 * pixels[i] + 0.7152 * pixels[i + 1] + 0.0722 * pixels[i + 2]) / 255.0;
			}
		}
		return (float)(sum / ((xb - xa) * (yb - ya)));
	}

	int ChangedPixels(uint8[] a, uint8[] b)
	{
		int changed = 0;
		for (int32 i = 0; i < ShotWidth * ShotHeight * 4; i += 4)
		{
			if (Math.Abs((int32)a[i] - b[i]) > 1 || Math.Abs((int32)a[i + 1] - b[i + 1]) > 1 || Math.Abs((int32)a[i + 2] - b[i + 2]) > 1)
				changed++;
		}
		return changed;
	}

	protected override void OnRender()
	{
		if (mSkip)
		{
			Finish();
			return;
		}
		if (mPhase < 0 || (mShot != null && mFrame < 0))
		{
			mPhase++;
			if (mPhase >= mPhases.Count)
			{
				Finish();
				return;
			}
			mScene.Environment.volumetricFog = mPhases[mPhase].volumetric;
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
			let phase = mPhases[mPhase];
			// The gap and the fog behind the wall: where the shaft is and where the wall shadows it; and the sky, which
			// the fog scatters light into.
			let gap = RegionMean(mShot.Pixels, 0.478f, 0.522f, 0.28f, 0.45f);
			let shadow = RegionMean(mShot.Pixels, 0.25f, 0.35f, 0.28f, 0.45f);
			let sky = RegionMean(mShot.Pixels, 0.40f, 0.60f, 0.02f, 0.12f);
			if (phase.volumetric)
			{
				Check(mView.VolumetricFogDrawn, "on: the froxel passes and their apply ran");
				// The profiler has read the frames just drawn (all with the fog on).
				Console.WriteLine(scope $"vfog-test: GPU time volumetric fog {ProfilerModules.VolumetricFogMs:F3} ms");
				Check(ProfilerModules.VolumetricFogMs > 0, "on: the fog pass's GPU time is recorded");
				mGapOn = gap;
				mShadowOn = shadow;
				mSkyOn = sky;
			}
			else
			{
				Check(!mView.VolumetricFogDrawn, scope $"{phase.name}: no volumetric fog drawn");
				if (mOffPixels == null)
				{
					mGapOff = gap;
					mShadowOff = shadow;
					mSkyOff = sky;
					mOffPixels = new uint8[mShot.Pixels.Count];
					Internal.MemCpy(mOffPixels.CArray(), mShot.Pixels.CArray(), (int)mOffPixels.Count);
				}
				else
					mChangedOff = ChangedPixels(mOffPixels, mShot.Pixels);
			}
			mFrame = -1;
		}
	}

	void Finish()
	{
		if (!mSkip && mOffPixels != null && mShadowOn > 0)
		{
			Console.WriteLine(scope $"vfog-test: gap off {mGapOff:F3} on {mGapOn:F3}; shadow off {mShadowOff:F3} on {mShadowOn:F3}; sky off {mSkyOff:F3} on {mSkyOn:F3}");
			Check(mGapOn > mGapOff + 0.10f, "on: the gap is much brighter (a light shaft)");
			Check(mGapOn > mShadowOn * 1.5f, "on: the shaft stands out against the fog behind the wall");
			Check(mSkyOn > mSkyOff + 0.10f, "on: the fog scatters light (the picture changes)");
			Console.WriteLine(scope $"vfog-test: off vs off-again changed pixels {mChangedOff} of {ShotWidth * ShotHeight}");
			Check(mChangedOff < ShotWidth * ShotHeight / 100, "off: the picture is the same as before (no fog)");
		}
		Console.WriteLine(Result == 0 ? "vfog-test: PASS" : "vfog-test: FAILED");
		Close();
	}
}
