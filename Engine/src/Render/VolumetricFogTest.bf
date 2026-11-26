using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

/// --vfog-test [folder]: draws volumetric fog (tallowengine.com/docs/day-night) and writes screenshots into the folder
/// (default: a scratch folder): the same scene with it off, with it on, and off again. A wall with a gap has the sun
/// behind it, so with the fog on a shaft of light shows through the gap while the fog behind the wall stays dark.
/// A spot light then fills a cone in the fog, with a box in front of it cutting a shadow out of the cone (three shots:
/// the spot off, on with the box, and on without it). Then a Fog Volume's fog shows only where the volume is (the
/// ground nearer than it does not change), and a dark see-through panel inside it is fogged too. The temporal blend is
/// checked on a still camera (no flicker) and just after a camera move (no ghost of where the camera was). Finally the
/// pass's GPU time is logged with 0, 16 and 128 point lights. Needs a window and a backend with compute shaders
/// (Vulkan, Direct3D 11/12 or Metal); elsewhere it skips.
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
		public bool sun;
		public bool spot;
		public float spotVolumetric;
		public bool blocker;
		public int32 lights;
		public bool checkSun;
		public bool checkSpot;
		public bool checkCost;
		// Fog Density for this phase (below 0: the scene's 0.05), the Fog Volume and the see-through panel.
		public float density = -1;
		public bool volume;
		public bool transparent;
		// The temporal blend, whether the camera stands aside, and how many frames to settle for.
		public bool temporal = true;
		public float cameraX;
		public int32 settle = SettleFrames;
		// 0 none, 1 the first of a pair, 2 the second, 3 one frame after the camera moved, 4 the same without the
		// history to compare against.
		public int32 pair;
		public bool checkVolume;
		// The fallback (no compute): the analytic height fog and its screen-space sun shafts (--gpu-driven-caps-off).
		public bool fallback;
		public bool checkFallback;
		// The froxel debug views (GpuDriven.DebugView.FogDensity / FogLight): 0 none, 1 density, 2 light.
		public int32 debugView;
		public bool checkDebug;
	}

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	GameObject mCameraObject;
	Light mSunLight;
	Light mSpotLight;
	MeshRenderer mBlockerRenderer;
	List<Light> mPerfLights = new .() ~ delete _;
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
	// The spot's cone (between it and the box) and its shadow (behind the box) at each spot phase.
	float mConeOff, mShadowBlocked, mShadowOpen;
	float mConeOn;
	// The Fog Volume, and the see-through panel drawn inside it.
	FogVolume mVolume;
	MeshRenderer mPanelRenderer;
	uint8[] mVolumePixels ~ delete _;
	float mVolumeOffInside, mVolumeOffOutside, mVolumeOffPanel;
	int mVolumeOutsideChanged;
	// The first of a shot pair (the still camera's, then the one just after the move) and the second's difference.
	uint8[] mPairPixels ~ delete _;
	int mPairChanged;
	float mPairMean;
	int mGhostChanged;
	float mGhostMean;
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
		mPhases.Add(.() { name = "off", sun = true });
		mPhases.Add(.() { name = "on", volumetric = true, sun = true, checkSun = true });
		mPhases.Add(.() { name = "off-again", sun = true });
		// The spot light in the fog: off, on with the box in front of it, and on without it (to show the shadow).
		mPhases.Add(.() { name = "spot-off", volumetric = true, spot = true });
		mPhases.Add(.() { name = "spot-on", volumetric = true, spot = true, spotVolumetric = 1, blocker = true, checkSpot = true });
		mPhases.Add(.() { name = "spot-nobox", volumetric = true, spot = true, spotVolumetric = 1, checkSpot = true });
		// The cost of the pass with point lights in the fog.
		mPhases.Add(.() { name = "lights0", volumetric = true, checkCost = true });
		mPhases.Add(.() { name = "lights16", volumetric = true, lights = 16, checkCost = true });
		mPhases.Add(.() { name = "lights128", volumetric = true, lights = 128, checkCost = true });
		// A Fog Volume: no height fog at all, so only the volume puts fog in the picture; the see-through panel is in it.
		mPhases.Add(.() { name = "volume-off", volumetric = true, density = 0, transparent = true, checkVolume = true });
		mPhases.Add(.() { name = "volume-on", volumetric = true, density = 0, volume = true, transparent = true, checkVolume = true });
		// The temporal blend: two still frames (no flicker), then one frame just after a camera move and the same frame
		// without the history (no ghost of where the camera stood).
		mPhases.Add(.() { name = "temporal-a", volumetric = true, pair = 1 });
		mPhases.Add(.() { name = "temporal-b", volumetric = true, settle = 1, pair = 2 });
		mPhases.Add(.() { name = "temporal-moved", volumetric = true, cameraX = 0.6f, settle = 1, pair = 3 });
		mPhases.Add(.() { name = "temporal-moved-off", volumetric = true, cameraX = 0.6f, temporal = false, settle = 1, pair = 4 });
		// The froxel debug views: the cells' density and the light they scatter, instead of the lit picture.
		mPhases.Add(.() { name = "debug-density", volumetric = true, sun = true, debugView = 1, checkDebug = true });
		mPhases.Add(.() { name = "debug-light", volumetric = true, sun = true, debugView = 2, checkDebug = true });
		// The fallback where the card cannot run the grid: the same height fog and its screen-space sun shafts
		// (--gpu-driven-caps-off); the gap must still be a bright shaft.
		mPhases.Add(.() { name = "fallback-off", sun = true, fallback = true });
		mPhases.Add(.() { name = "fallback-on", volumetric = true, sun = true, fallback = true, checkFallback = true });

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
		mSunLight = sun;
		sun.intensity = 2.0f;
		sun.castShadows = true;
		sunObject.Transform.Rotation = Quaternion.LookRotation(Vector3(0, -0.2f, -1).Normalized, .Up);
		// A spot light crossing the fog high above the wall, aimed left past a box: the cone shows against the dark
		// backdrop, and the box cuts a shadow out of it to its left.
		let spotObject = mScene.CreateGameObject("Spot");
		let spot = spotObject.AddComponent<Light>();
		mSpotLight = spot;
		spot.type = .Spot;
		spot.color = .(1.0f, 0.95f, 0.85f);
		spot.intensity = 30;
		spot.range = 40;
		spot.spotAngle = 60;
		spot.innerSpotAngle = 40;
		spot.castShadows = true;
		spotObject.Transform.Position = .(8, 10, 25);
		spotObject.Transform.Rotation = Quaternion.LookRotation(Vector3(-6, -0.6f, 0).Normalized, .Up);
		let blocker = mScene.CreateGameObject("Blocker");
		let blockerRenderer = blocker.AddComponent<MeshRenderer>();
		blockerRenderer.mesh.Set("builtin:cube");
		blockerRenderer.color = .FromBytes(40, 40, 46);
		mBlockerRenderer = blockerRenderer;
		blocker.Transform.Position = .(2, 9.4f, 25);
		blocker.Transform.LocalScale = .(2, 2, 2);
		// The point lights the pass's cost is measured with, in the fog in front of the camera.
		for (int k = 0; k < 4; k++)
		{
			for (int j = 0; j < 4; j++)
			{
				for (int i = 0; i < 8; i++)
				{
					let lightObject = mScene.CreateGameObject("Fill");
					let light = lightObject.AddComponent<Light>();
					light.type = .Point;
					light.intensity = 1.5f;
					light.range = 8;
					light.castShadows = false;
					lightObject.Transform.Position = .(-8 + i * (16.0f / 7), 1 + j * 2, 12 + k * 8);
					mPerfLights.Add(light);
				}
			}
		}

		// A Fog Volume between the camera and the wall (and on above it, against the dark backdrop), and a dark
		// see-through panel standing in it.
		let mist = mScene.CreateGameObject("Mist");
		mVolume = mist.AddComponent<FogVolume>();
		mVolume.shape = .Box;
		mVolume.size = .(24, 44, 70);
		mVolume.density = 0.3f;
		mVolume.edgeFade = 0.25f;
		mist.Transform.Position = .(0, 20, 45);
		mVolume.enabled = false;
		let panel = mScene.CreateGameObject("Panel");
		let panelRenderer = panel.AddComponent<MeshRenderer>();
		panelRenderer.mesh.Set("builtin:cube");
		panelRenderer.color = .(0.03f, 0.03f, 0.04f, 0.85f);
		mPanelRenderer = panelRenderer;
		panel.Transform.Position = .(0, 3.5f, 20);
		panel.Transform.LocalScale = .(8, 3, 0.2f);
		mPanelRenderer.enabled = false;

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

	/// How many of the pixels in a rectangle (0..1 across and down) differ by more than one level of grey.
	int RegionChanged(uint8[] a, uint8[] b, float x0, float x1, float y0, float y1)
	{
		int xa = (int)(x0 * ShotWidth), xb = (int)(x1 * ShotWidth);
		int ya = (int)(y0 * ShotHeight), yb = (int)(y1 * ShotHeight);
		int changed = 0;
		for (int y = ya; y < yb; y++)
		{
			for (int x = xa; x < xb; x++)
			{
				let i = (y * ShotWidth + x) * 4;
				if (Math.Abs((int32)a[i] - b[i]) > 1 || Math.Abs((int32)a[i + 1] - b[i + 1]) > 1 || Math.Abs((int32)a[i + 2] - b[i + 2]) > 1)
					changed++;
			}
		}
		return changed;
	}

	/// The average difference between two pictures, in levels of grey (0..255).
	float MeanDiff(uint8[] a, uint8[] b)
	{
		double sum = 0;
		for (int32 i = 0; i < ShotWidth * ShotHeight * 4; i += 4)
			sum += Math.Abs((int32)a[i] - b[i]) + Math.Abs((int32)a[i + 1] - b[i + 1]) + Math.Abs((int32)a[i + 2] - b[i + 2]);
		return (float)(sum / (ShotWidth * ShotHeight * 3));
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
			let phase = mPhases[mPhase];
			mScene.Environment.volumetricFog = phase.volumetric;
			mScene.Environment.vfDensity = phase.density >= 0 ? phase.density : 0.05f;
			mSunLight.enabled = phase.sun;
			mSpotLight.enabled = phase.spot;
			mSpotLight.volumetric = phase.spotVolumetric;
			mBlockerRenderer.enabled = phase.blocker;
			mVolume.enabled = phase.volume;
			mPanelRenderer.enabled = phase.transparent;
			mView.FogTemporalEnabled = phase.temporal;
			// A fallback phase pretends compute is missing; a --gpu-driven-caps-off run keeps pretending throughout.
			GpuDriven.ForceUnavailable = GpuDriven.ForceUnavailable || phase.fallback;
			GpuDriven.View = phase.debugView == 1 ? .FogDensity : (phase.debugView == 2 ? .FogLight : .Off);
			mCameraObject.Transform.Position = .(phase.cameraX, 2, 0);
			for (int i < mPerfLights.Count)
				mPerfLights[i].enabled = i < phase.lights;
			mFrame = 0;
			DeleteAndNullify!(mShot);
		}
		mView.Resize(ShotWidth, ShotHeight);
		mView.Render(mScene, mCamera.GetCameraData((float)ShotWidth / ShotHeight));
		mFrame++;
		if (mFrame < mPhases[mPhase].settle)
			return;
		if (mShot == null)
			mShot = new CompareShot();
		let path = scope $"{mDir}/{mPhases[mPhase].name}.png";
		if (mShot.Step(mView, ShotWidth, ShotHeight, path))
		{
			let phase = mPhases[mPhase];
			if (phase.checkSun)
			{
				// The gap and the fog behind the wall: where the shaft is and where the wall shadows it; and the sky, which
				// the fog scatters light into.
				let gap = RegionMean(mShot.Pixels, 0.478f, 0.522f, 0.28f, 0.45f);
				let shadow = RegionMean(mShot.Pixels, 0.25f, 0.35f, 0.28f, 0.45f);
				let sky = RegionMean(mShot.Pixels, 0.40f, 0.60f, 0.02f, 0.12f);
				Check(mView.VolumetricFogDrawn, "on: the froxel passes and their apply ran");
				// The profiler has read the frames just drawn (all with the fog on).
				Console.WriteLine(scope $"vfog-test: GPU time volumetric fog {ProfilerModules.VolumetricFogMs:F3} ms");
				Check(ProfilerModules.VolumetricFogMs > 0, "on: the fog pass's GPU time is recorded");
				mGapOn = gap;
				mShadowOn = shadow;
				mSkyOn = sky;
			}
			else if (!phase.volumetric && !phase.fallback)
			{
				let gap = RegionMean(mShot.Pixels, 0.478f, 0.522f, 0.28f, 0.45f);
				let shadow = RegionMean(mShot.Pixels, 0.25f, 0.35f, 0.28f, 0.45f);
				let sky = RegionMean(mShot.Pixels, 0.40f, 0.60f, 0.02f, 0.12f);
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
			else if (phase.spot)
			{
				// The cone between the spot and the box, and the shadow the box casts to its left, both against the dark
				// backdrop above the wall.
				let cone = RegionMean(mShot.Pixels, 0.59f, 0.66f, 0.16f, 0.20f);
				let shadow = RegionMean(mShot.Pixels, 0.46f, 0.51f, 0.16f, 0.20f);
				Check(mView.VolumetricFogDrawn, scope $"{phase.name}: the froxel passes and their apply ran");
				if (!phase.checkSpot)
					mConeOff = cone;
				else if (phase.blocker)
				{
					mConeOn = cone;
					mShadowBlocked = shadow;
					Check(mView.ShadowTiles > 0, "spot: the light casts a shadow");
					Console.WriteLine(scope $"vfog-test: spot cone {cone:F3} shadow (box) {shadow:F3}");
				}
				else
				{
					mShadowOpen = shadow;
					Console.WriteLine(scope $"vfog-test: spot shadow (no box) {shadow:F3}");
				}
			}
			if (phase.checkDebug)
			{
				let mean = RegionMean(mShot.Pixels, 0, 1, 0, 1);
				let changed = ChangedPixels(mOffPixels, mShot.Pixels);
				Console.WriteLine(scope $"vfog-test: {phase.name}: mean {mean:F3}, {changed} of {ShotWidth * ShotHeight} pixels differ from the lit picture; {RenderView.VolumetricFogCells} cells, {RenderView.VolumetricFogLights} local lights");
				Check(mView.VolumetricFogDrawn, scope $"{phase.name}: the fog's cells were drawn");
				Check(RenderView.VolumetricFogCells > 0, scope $"{phase.name}: the cell counter is set");
				Check(mean > 0.02f, scope $"{phase.name}: the cells are not black");
				Check(changed > ShotWidth * ShotHeight / 2, scope $"{phase.name}: the debug view replaces the lit scene");
			}
			if (phase.checkFallback)
			{
				// The fallback's height fog and screen-space shafts: the gap must still line up with the sun.
				let gap = RegionMean(mShot.Pixels, 0.478f, 0.522f, 0.28f, 0.45f);
				let sky = RegionMean(mShot.Pixels, 0.40f, 0.60f, 0.02f, 0.12f);
				Console.WriteLine(scope $"vfog-test: fallback gap off {mGapOff:F3} on {gap:F3}; sky off {mSkyOff:F3} on {sky:F3}");
				Check(mView.VolumetricFogDrawn, "fallback: the height fog and its shafts were drawn");
				Check(mView.VolumetricFogFallbackDrawn, "fallback: the compute grid was not used");
				Check(gap > mGapOff + 0.03f, "fallback: the gap is brighter (a sun shaft)");
				Check(sky > mSkyOff + 0.03f, "fallback: the fog scatters light");
			}
			if (phase.checkVolume)
			{
				// The fog over the dark backdrop above the wall (inside the volume), the near ground (in front of it),
				// and the see-through panel standing in it.
				let inside = RegionMean(mShot.Pixels, 0.44f, 0.56f, 0.06f, 0.14f);
				let outside = RegionMean(mShot.Pixels, 0.30f, 0.45f, 0.86f, 0.94f);
				let panel = RegionMean(mShot.Pixels, 0.45f, 0.55f, 0.365f, 0.44f);
				if (!phase.volume)
				{
					mVolumeOffInside = inside;
					mVolumeOffOutside = outside;
					mVolumeOffPanel = panel;
					mVolumePixels = new uint8[mShot.Pixels.Count];
					Internal.MemCpy(mVolumePixels.CArray(), mShot.Pixels.CArray(), (int)mVolumePixels.Count);
				}
				else
				{
					Console.WriteLine(scope $"vfog-test: volume inside {mVolumeOffInside:F3} -> {inside:F3}; ground outside {mVolumeOffOutside:F3} -> {outside:F3}; see-through panel {mVolumeOffPanel:F3} -> {panel:F3}");
					Check(mView.VolumetricFogDrawn, "volume: the fog is drawn from the volume alone (no height fog)");
					Check(inside > mVolumeOffInside + 0.02f, "volume: the fog shows inside it");
					Check(panel > mVolumeOffPanel + 0.01f, "volume: the see-through panel is fogged too");
					mVolumeOutsideChanged = RegionChanged(mVolumePixels, mShot.Pixels, 0.30f, 0.45f, 0.86f, 0.94f);
					Console.WriteLine(scope $"vfog-test: volume outside changed pixels {mVolumeOutsideChanged}");
					Check(mVolumeOutsideChanged == 0, "volume: nothing changes outside it (the near ground)");
				}
			}
			if (phase.pair != 0)
			{
				if (phase.pair == 1 || phase.pair == 3)
				{
					DeleteAndNullify!(mPairPixels);
					mPairPixels = new uint8[mShot.Pixels.Count];
					Internal.MemCpy(mPairPixels.CArray(), mShot.Pixels.CArray(), (int)mPairPixels.Count);
				}
				else if (phase.pair == 2)
				{
					mPairChanged = ChangedPixels(mPairPixels, mShot.Pixels);
					mPairMean = MeanDiff(mPairPixels, mShot.Pixels);
					Console.WriteLine(scope $"vfog-test: still camera, the next frame: {mPairChanged} pixels changed, mean {mPairMean:F2}/255");
					Check(mPairChanged < ShotWidth * ShotHeight / 50, "temporal: the fog does not flicker frame to frame");
					Check(mPairMean < 1.5f, "temporal: the frame-to-frame change is under a level of grey");
				}
				else
				{
					mGhostChanged = ChangedPixels(mPairPixels, mShot.Pixels);
					mGhostMean = MeanDiff(mPairPixels, mShot.Pixels);
					Console.WriteLine(scope $"vfog-test: one frame after the camera moved, against no history: {mGhostChanged} pixels changed, mean {mGhostMean:F2}/255");
					Check(mGhostChanged < ShotWidth * ShotHeight / 50, "temporal: no ghost of where the camera stood");
					Check(mGhostMean < 2.0f, "temporal: the ghost is under two levels of grey");
				}
			}
			if (phase.checkCost)
			{
				Console.WriteLine(scope $"vfog-test: GPU time volumetric fog {ProfilerModules.VolumetricFogMs:F3} ms with {phase.lights} point lights ({mView.LightCount} lights in the view)");
				Check(ProfilerModules.VolumetricFogMs > 0, scope $"cost: the fog pass's GPU time is recorded with {phase.lights} lights");
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
		if (!mSkip && mConeOn > 0)
		{
			Console.WriteLine(scope $"vfog-test: spot cone off {mConeOff:F3} on {mConeOn:F3}; shadow with box {mShadowBlocked:F3} without {mShadowOpen:F3}");
			Check(mConeOn > mConeOff + 0.02f, "spot: the light brightens the fog in its cone");
			Check(mShadowOpen > mShadowBlocked + 0.01f, "spot: the box cuts a shadow out of the cone");
		}
		Console.WriteLine(Result == 0 ? "vfog-test: PASS" : "vfog-test: FAILED");
		Close();
	}
}
