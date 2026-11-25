using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// --skybox-test <folder>: writes a small skybox of every kind into a scratch project in the folder (.hdr, .exr, .png
/// and .jpg panoramas, .ktx and .dds cubemaps, two six-face folders), draws each as the Custom sky (Skybox.bf) and
/// writes a screenshot of each. Every skybox holds the same picture (red towards +Z, green towards +X, blue up), so
/// each shot must show red ahead, green to the right and blue above: the import, the face order and the drawing agree.
/// Also checks rotation, exposure and tint, that a cached skybox is not imported again, that a picture that is not a
/// panorama fails to the physical sky, and that the settings save and load. Then two balls (rough white, mirror) under
/// the default sky and under an all-red skybox: the skybox's cube must be the sky's reflection cube and its ambient
/// light, so both turn red (S2b). Needs a window.
class SkyboxTestApp : Application
{
	const int32 ShotWidth = 480;
	const int32 ShotHeight = 270;
	const int SettleFrames = 12;

	public int32 Result;

	struct Phase
	{
		public String name;
		public String skybox;
		public float rotation;
		public float exposure;
		public Color tint = .(1, 1, 1);
	}

	Scene mScene ~ delete _;
	RenderView mView ~ delete _;
	Camera mCamera;
	String mDir = new .() ~ delete _;
	List<Phase> mPhases = new .() ~ { for (let p in _) { delete p.name; delete p.skybox; } delete _; };
	int mPhase = -1;
	int mFrame;
	CompareShot mShot ~ delete _;
	// Two balls lit by the sky alone (a rough white one at the left, a mirror at the right), shown in the lit phases.
	GameObject mBalls;
	// Per shot: the colour in the middle, at the right and left edges' middle, and the top and bottom middle (0..1).
	List<Vector3[5]> mSamples = new .() ~ delete _;

	protected override bool LoadsPlayerQuality => false;

	public this()
	{
		Title.Set("Skybox test");
		Width = ShotWidth;
		Height = ShotHeight;
	}

	void Check(bool ok, StringView what)
	{
		Console.WriteLine(scope $"skybox-test: {ok ? "ok" : "FAIL"} {what}");
		if (!ok)
			Result = 1;
	}

	/// The test picture, linear: red towards +Z, green towards +X, blue up.
	static void Pattern(Vector3 dir, float* rgba)
	{
		rgba[0] = Math.Max(dir.z, 0) * 0.8f + 0.04f;
		rgba[1] = Math.Max(dir.x, 0) * 0.8f + 0.04f;
		rgba[2] = Math.Max(dir.y, 0) * 0.8f + 0.04f;
		rgba[3] = 1;
	}

	/// cube.sh cubeDirection.
	static Vector3 CubeDirection(int face, float s, float t)
	{
		Vector3 dir;
		switch (face)
		{
		case 0: dir = .(1, -t, -s);
		case 1: dir = .(-1, -t, s);
		case 2: dir = .(s, 1, t);
		case 3: dir = .(s, -1, -t);
		case 4: dir = .(s, -t, 1);
		default: dir = .(-s, -t, -1);
		}
		return dir.Normalized;
	}

	static void Panorama(float[] pixels, int32 width, int32 height)
	{
		for (int32 y < height)
		{
			for (int32 x < width)
			{
				let lon = ((x + 0.5f) / width - 0.5f) * 2 * Math.PI_f;
				let lat = (0.5f - (y + 0.5f) / height) * Math.PI_f;
				Pattern(.(Math.Cos(lat) * Math.Sin(lon), Math.Sin(lat), Math.Cos(lat) * Math.Cos(lon)), &pixels[(y * width + x) * 4]);
			}
		}
	}

	static void Face(float* pixels, int face, int32 size)
	{
		for (int32 y < size)
			for (int32 x < size)
				Pattern(CubeDirection(face, (x + 0.5f) / size * 2 - 1, (y + 0.5f) / size * 2 - 1), &pixels[(y * size + x) * 4]);
	}

	bool Write(StringView path, int32 kind, int32 width, int32 height, float* pixels)
	{
		let ok = Native.tn_skybox_write_test_picture(scope String(path).CStr(), kind, width, height, pixels);
		Check(ok, scope $"wrote {path}");
		return ok;
	}

	void AddPhase(StringView name, StringView skybox, float rotation = 0, float exposure = 0, Color tint = .(1, 1, 1))
	{
		mPhases.Add(.() { name = new .(name), skybox = new .(skybox), rotation = rotation, exposure = exposure, tint = tint });
	}

	protected override bool OnInit()
	{
		if (!GetArg("--skybox-test", mDir) || mDir.IsEmpty || mDir.StartsWith("--"))
			mDir.Set(scope $"{Path.GetTempPath(.. scope .())}tallow-skybox-test");
		let assets = scope $"{mDir}/Project/Assets";
		let skies = scope $"{assets}/Skies";
		// A fresh project each run, so the first loads import and the cache check means something.
		if (Directory.Exists(scope $"{mDir}/Project"))
			Directory.DelTree(scope $"{mDir}/Project").IgnoreError();
		Directory.CreateDirectory(scope $"{skies}/faces").IgnoreError();
		Directory.CreateDirectory(scope $"{skies}/faces_named").IgnoreError();
		Assets.ProjectPath.Set(assets);

		const int32 PanoW = 256;
		const int32 PanoH = 128;
		const int32 FaceSize = 32;
		let pano = scope float[PanoW * PanoH * 4];
		Panorama(pano, PanoW, PanoH);
		let cube = scope float[FaceSize * FaceSize * 4 * 6];
		for (int face < 6)
			Face(&cube[FaceSize * FaceSize * 4 * face], face, FaceSize);
		Write(scope $"{skies}/pano.png", 0, PanoW, PanoH, pano.Ptr);
		Write(scope $"{skies}/pano.jpg", 1, PanoW, PanoH, pano.Ptr);
		Write(scope $"{skies}/pano.hdr", 2, PanoW, PanoH, pano.Ptr);
		Write(scope $"{skies}/pano.exr", 3, PanoW, PanoH, pano.Ptr);
		Write(scope $"{skies}/cube.ktx", 4, FaceSize, FaceSize, cube.Ptr);
		Write(scope $"{skies}/cube.dds", 5, FaceSize, FaceSize, cube.Ptr);
		StringView[6] faceNames = .("px", "nx", "py", "ny", "pz", "nz");
		StringView[6] longNames = .("right", "left", "up", "down", "front", "back");
		for (int face < 6)
		{
			Write(scope $"{skies}/faces/{faceNames[face]}.png", 0, FaceSize, FaceSize, &cube[FaceSize * FaceSize * 4 * face]);
			Write(scope $"{skies}/faces_named/{longNames[face]}.hdr", 2, FaceSize, FaceSize, &cube[FaceSize * FaceSize * 4 * face]);
		}
		// All red: the lighting check's skybox.
		let red = scope float[PanoW * PanoH * 4];
		for (int i < PanoW * PanoH)
		{
			red[i * 4] = 1;
			red[i * 4 + 1] = 0.02f;
			red[i * 4 + 2] = 0.02f;
			red[i * 4 + 3] = 1;
		}
		Write(scope $"{skies}/red.hdr", 2, PanoW, PanoH, red.Ptr);
		// Not a panorama: a square picture.
		Write(scope $"{skies}/square.png", 0, 64, 64, pano.Ptr);

		Check(Skybox.IsSkyboxAsset("Skies/pano.png") && Skybox.IsSkyboxAsset("Skies/pano.hdr") && Skybox.IsSkyboxAsset("Skies/cube.dds") && Skybox.IsSkyboxAsset("Skies/faces"), "skybox assets recognised");
		Check(!Skybox.IsSkyboxAsset("Skies/square.png") && !Skybox.IsSkyboxAsset("Skies"), "a square picture and a plain folder are not skyboxes");

		for (let kind in StringView[?]("pano.hdr", "pano.exr", "pano.png", "pano.jpg", "cube.ktx", "cube.dds", "faces", "faces_named"))
			AddPhase(kind, scope $"Skies/{kind}");
		AddPhase("rotated", "Skies/pano.hdr", 90);
		AddPhase("exposure", "Skies/pano.hdr", 0, 1);
		AddPhase("tint", "Skies/pano.hdr", 0, 0, .(0, 1, 1));
		// Lighting from the sky (S2b): the balls under the default sky, then under the red skybox.
		AddPhase("lit-default", "");
		AddPhase("lit-red", "Skies/red.hdr");

		mScene = new Scene();
		let cameraObject = mScene.CreateGameObject("Camera");
		mCamera = cameraObject.AddComponent<Camera>();
		mCamera.fieldOfView = 90;
		mCamera.farClip = 2000;
		cameraObject.Transform.Position = .(0, 0, 0);
		cameraObject.Transform.Rotation = Quaternion.LookRotation(.(0, 0, 1), .(0, 1, 0));
		mBalls = mScene.CreateGameObject("Balls");
		for (int i < 2)
		{
			let ball = mScene.CreateGameObject(i == 0 ? "Rough" : "Mirror");
			ball.Transform.SetParent(mBalls.Transform);
			ball.Transform.Position = .(i == 0 ? -1.2f : 1.2f, 0, 3);
			ball.Transform.LocalScale = .(1.6f, 1.6f, 1.6f);
			let renderer = ball.AddComponent<MeshRenderer>();
			renderer.mesh.Set("builtin:sphere_smooth");
			// The mirror is grey, so it shows against a sky of one colour (it gives back half of it).
			renderer.color = i == 0 ? .White : Color(0.5f, 0.5f, 0.5f);
			renderer.metallic = i == 0 ? 0 : 1;
			renderer.roughness = i == 0 ? 0.9f : 0.15f;
		}
		mBalls.SetActive(false);

		// The skybox settings are saved with the scene; a scene without one saves none.
		{
			let text = scope String();
			SceneSerializer.Save(mScene, text);
			Check(!text.Contains("skybox"), "a scene without a skybox saves no skybox lines");
			let env = mScene.Environment;
			env.skyMode = .Custom;
			env.skybox.Set("Skies/pano.hdr");
			env.skyboxRotation = 45;
			env.skyboxExposure = -1.5f;
			env.skyboxTint = .(1, 0.5f, 0.25f);
			text.Clear();
			SceneSerializer.Save(mScene, text);
			let back = scope Scene();
			SceneSerializer.Load(back, text);
			let b = back.Environment;
			Check(b.skyMode == .Custom && b.skybox == "Skies/pano.hdr" && b.skyboxRotation == 45 && b.skyboxExposure == -1.5f && b.skyboxTint.g == 0.5f && b.skyboxTint.b == 0.25f, "skybox settings saved and loaded");
			let copy = scope SceneEnvironment();
			copy.CopyFrom(env);
			Check(copy.skybox == env.skybox && copy.skyboxRotation == 45 && copy.skyboxTint.b == 0.25f, "skybox settings copied");
			env.Reset();
			Check(env.skybox.IsEmpty && env.skyMode == .Gradient, "reset clears the skybox");
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
		let lit = phase.name.StartsWith("lit");
		mBalls.SetActive(lit);
		// lit-default keeps the default sky (Gradient, with its ambient colours).
		if (!lit || !phase.skybox.IsEmpty)
			env.skyMode = .Custom;
		env.skybox.Set(phase.skybox);
		env.skyboxRotation = phase.rotation;
		env.skyboxExposure = phase.exposure;
		env.skyboxTint = phase.tint;
		env.bloom = 0;
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
		// The lit phases wait for the sky's reflection cube to be made again from the new sky.
		if (mFrame < (mPhases[mPhase].name.StartsWith("lit") ? 120 : SettleFrames))
			return;
		if (mShot == null)
			mShot = new CompareShot();
		let phase = mPhases[mPhase];
		let path = scope $"{mDir}/{phase.name}.png";
		if (mShot.Step(mView, ShotWidth, ShotHeight, path))
		{
			Check(Skybox.Active(mScene.Environment) == !phase.skybox.IsEmpty, scope $"{phase.name}: drawn from the skybox");
			Measure(phase, mShot.Pixels);
			mFrame = -1;
		}
	}

	Vector3 At(uint8[] pixels, int x, int y)
	{
		Vector3 sum = .Zero;
		for (int dy = -2; dy <= 2; dy++)
			for (int dx = -2; dx <= 2; dx++)
			{
				let i = (Math.Clamp(y + dy, 0, ShotHeight - 1) * ShotWidth + Math.Clamp(x + dx, 0, ShotWidth - 1)) * 4;
				sum += Vector3(pixels[i], pixels[i + 1], pixels[i + 2]) / 255.0f;
			}
		return sum / 25;
	}

	void Measure(Phase phase, uint8[] pixels)
	{
		Vector3[5] s = .(At(pixels, ShotWidth / 2, ShotHeight / 2), At(pixels, ShotWidth - 6, ShotHeight / 2), At(pixels, 5, ShotHeight / 2),
			At(pixels, ShotWidth / 2, 5), At(pixels, ShotWidth / 2, ShotHeight - 6));
		if (phase.name.StartsWith("lit"))
		{
			// The balls' middles: the rough one at the left, the mirror at the right.
			let x = (int)(ShotWidth * 0.5f * (1 - 1.2f / 3 / ((float)ShotWidth / ShotHeight)));
			s[1] = At(pixels, ShotWidth - x, ShotHeight / 2);
			s[2] = At(pixels, x, ShotHeight / 2);
		}
		mSamples.Add(s);
		Console.WriteLine(scope $"skybox-test: {phase.name} middle {s[0].x:F2} {s[0].y:F2} {s[0].z:F2}, right {s[1].x:F2} {s[1].y:F2} {s[1].z:F2}, left {s[2].x:F2} {s[2].y:F2} {s[2].z:F2}, top {s[3].x:F2} {s[3].y:F2} {s[3].z:F2}, bottom {s[4].x:F2} {s[4].y:F2} {s[4].z:F2}, face {Skybox.FaceSize(phase.skybox)} px");
		if (phase.rotation != 0 || phase.exposure != 0 || phase.tint.r != 1 || phase.name.StartsWith("lit"))
			return;
		Check(s[0].x > s[0].y * 1.5f && s[0].x > s[0].z * 1.5f, scope $"{phase.name}: red ahead (+Z)");
		Check(s[1].y > s[2].y + 0.2f, scope $"{phase.name}: green to the right (+X)");
		Check(s[3].z > s[4].z + 0.2f, scope $"{phase.name}: blue above (+Y)");
		Check(Skybox.FaceSize(phase.skybox) == (phase.name.StartsWith("pano") ? 64 : 32), scope $"{phase.name}: face size");
	}

	void Finish()
	{
		Check(mSamples.Count == mPhases.Count, "every shot taken");
		if (mSamples.Count == mPhases.Count)
		{
			let plain = mSamples[0];
			let rotated = mSamples[mPhases.Count - 5];
			let brighter = mSamples[mPhases.Count - 4];
			let tinted = mSamples[mPhases.Count - 3];
			let litDefault = mSamples[mPhases.Count - 2];
			let litRed = mSamples[mPhases.Count - 1];
			// The red skybox's cube is the sky's reflection cube and its ambient light: both balls turn red.
			Check(litRed[2].x > 2 * litRed[2].z && litRed[2].x > 0.05f, scope $"red skybox: ambient light red (rough ball {litRed[2].x:F2} {litRed[2].y:F2} {litRed[2].z:F2})");
			Check(litRed[1].x > 2 * litRed[1].z && litRed[1].x > 0.05f && litRed[1].x < litRed[0].x * 0.8f, scope $"red skybox: reflections red (mirror ball {litRed[1].x:F2} {litRed[1].y:F2} {litRed[1].z:F2})");
			Check(!(litDefault[2].x > 2 * litDefault[2].z) && !(litDefault[1].x > 2 * litDefault[1].z), scope $"default sky: balls not red (rough {litDefault[2].x:F2} {litDefault[2].y:F2} {litDefault[2].z:F2}, mirror {litDefault[1].x:F2} {litDefault[1].y:F2} {litDefault[1].z:F2})");
			// Turned 90 degrees clockwise seen from above: what was to the left (-X: no red, no green) is ahead, red to the right.
			Check(rotated[0].x < plain[0].x * 0.5f && rotated[0].y < 0.4f && rotated[1].x > 0.6f, "rotation 90 turns the skybox clockwise (-X ahead, +Z to the right)");
			Check(brighter[0].x > plain[0].x + 0.05f, "exposure +1 is brighter");
			Check(tinted[0].x < plain[0].x * 0.3f && tinted[1].y > plain[1].y * 0.8f, "tint (0, 1, 1) takes the red out");
		}
		// The cache: loading every skybox again after forgetting them reads the cache files, no import.
		let imports = Skybox.Imports;
		Skybox.Forget();
		for (let phase in mPhases)
			if (!phase.skybox.IsEmpty)
				Skybox.Get(phase.skybox);
		Check(Skybox.Imports == imports, scope $"cached skyboxes not imported again ({imports} imports)");
		// A picture that is not a panorama: no skybox, the physical sky instead.
		let env = mScene.Environment;
		env.skybox.Set("Skies/square.png");
		Check(!Skybox.Active(env), "a square picture fails (drawn as the physical sky)");
		Console.WriteLine(Result == 0 ? "skybox-test: PASS" : "skybox-test: FAILED");
		Close();
	}
}
