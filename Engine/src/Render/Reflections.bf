using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Captures what can be seen from a point into a cube, for the shiny surfaces inside its box to mirror: floors,
/// metal, glass, water, wet streets (docs/reflections.md). Without one, surfaces mirror the sky, which looks wrong
/// indoors: put a probe in each room, sized to its walls. It captures when it is first drawn, and again with
/// Capture() (or every refreshInterval seconds). What is in the box is lit by its cube, fading into the sky or the
/// next probe over blendDistance from its edges.
///
/// A handle (ComponentHandle): its settings are ReflectionProbeData's fields, in the object's entity; its cube is
/// kept outside them (ReflectionProbeState).
[Component, HandleFields]
struct ReflectionProbe : ComponentHandle<ReflectionProbeData>
{
	/// Its cube and capture progress; null until it is first captured.
	ReflectionProbeState State => ComponentState<ReflectionProbeState>.Get(mGameObject.Scene.World, mGameObject.Entity);
	/// The same, made if missing: only for a valid probe (the state is freed when the component goes).
	ReflectionProbeState MadeState => ComponentState<ReflectionProbeState>.Make(mGameObject.Scene.World, mGameObject.Entity);

	/// The cube with its rougher levels, once captured.
	public bgfx.TextureHandle Cube
	{
		get
		{
			let state = State;
			return state != null ? state.cube : .() { idx = uint16.MaxValue };
		}
	}

	/// Whether it has been captured (until then it reflects nothing and surfaces use the sky).
	public bool Captured => State?.captured ?? false;
	/// The last of the cube's levels (roughness 1).
	public int32 LastLevel => State?.lastLevel ?? 0;

	/// Captures it again (over the next frames; it keeps its old cube until then).
	public void Capture()
	{
		if (let state = State)
			state.wanted = true;
	}

	/// The box in the world.
	public Bounds WorldBox
	{
		get
		{
			let transform = Transform;
			let world = transform.LocalToWorld;
			let scale = Vector3(world.Right.Length, world.Up.Length, world.Forward.Length);
			let size = this.size;
			let half = Vector3(Math.Abs(size.x * scale.x), Math.Abs(size.y * scale.y), Math.Abs(size.z * scale.z)) * 0.5f;
			let center = transform.Position;
			return .(center - half, center + half);
		}
	}

	/// Where it sees from, in the world.
	public Vector3 CapturePoint => Transform.Position + captureOffset;

	/// How far a point is outside the box (0 inside it).
	public float Outside(Vector3 point)
	{
		let area = WorldBox;
		let dx = Math.Max(Math.Max(area.min.x - point.x, point.x - area.max.x), 0);
		let dy = Math.Max(Math.Max(area.min.y - point.y, point.y - area.max.y), 0);
		let dz = Math.Max(Math.Max(area.min.z - point.z, point.z - area.max.z), 0);
		return Math.Sqrt(dx * dx + dy * dy + dz * dz);
	}

	/// How much of its reflection a point gets: 1 inside the box, fading to 0 blendDistance outside it (as the
	/// shaders work it out for each pixel).
	public float Weight(Vector3 point) => 1 - Math.Clamp(Outside(point) / Math.Max(blendDistance, 0.001f), 0, 1);

	/// Whether it should be captured now: never yet, asked to, moved or changed in the editor, or due a refresh.
	public bool WantsCapture(int32 generation)
	{
		let state = State;
		if (state == null || state.wanted || !state.captured || generation != state.generation)
			return true;
		let scene = Scene;
		if (scene != null && scene.IsPlaying)
			return refreshInterval > 0 && Time.Time - state.capturedAt >= refreshInterval;
		return Hash() != state.capturedState;
	}

	int64 Hash()
	{
		let area = WorldBox;
		let eye = CapturePoint;
		int64 hash = resolution;
		Reflections.Mix(ref hash, area.min);
		Reflections.Mix(ref hash, area.max);
		Reflections.Mix(ref hash, eye);
		return hash;
	}

	/// The cube to capture into, made at this size (a new one when the size changed).
	public bgfx.TextureHandle CubeFor(int32 cubeSize) => MadeState.CubeFor(cubeSize);

	/// Called by Reflections when a capture starts, and when it is finished.
	public void CaptureStarted(int32 generation)
	{
		let state = MadeState;
		state.wanted = false;
		state.generation = generation;
		state.capturedState = Hash();
		state.capturedAt = Time.Time;
	}

	public void CaptureFinished(int32 lastLevel)
	{
		let state = MadeState;
		state.captured = true;
		state.lastLevel = lastLevel;
		// The first time, shiny things in view could only mirror the sky. Once more, and they mirror this cube.
		if (!state.secondPass)
		{
			state.secondPass = true;
			state.wanted = true;
		}
	}

	static void OnRemove(void* world, uint64 entity)
	{
		Reflections.Forget(world, entity);
		ComponentState<ReflectionProbeState>.Release(world, entity);
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		let probe = gameObject.GetComponent<ReflectionProbe>();
		let tint = selected ? Color(0.4f, 0.85f, 1.0f, 1) : Color(0.3f, 0.7f, 0.9f, 0.5f);
		Gizmos.Lines.Box(probe.WorldBox, .Identity, tint);
		let eye = probe.CapturePoint;
		Gizmos.Lines.Line(eye - .(0.25f, 0, 0), eye + .(0.25f, 0, 0), tint);
		Gizmos.Lines.Line(eye - .(0, 0.25f, 0), eye + .(0, 0.25f, 0), tint);
		Gizmos.Lines.Line(eye - .(0, 0, 0.25f), eye + .(0, 0, 0.25f), tint);
	}
}

/// A Reflection Probe's settings.
[Component, HandleData]
struct ReflectionProbeData
{
	/// The box it covers, in metres around the object (scaled with it, not turned with it).
	public Vector3 size = .(10, 10, 10);
	/// Where it sees from, from the object's position: lift it off the floor to the height of an eye.
	public Vector3 captureOffset = .Zero;
	/// How far outside the box, in metres, its reflections fade into the sky's (or another probe's). Make the box
	/// the size of the room: things just outside it, and walls standing on its edge, still get its reflections.
	public float blendDistance = 1;
	/// Lines reflections up with the box's walls, so they sit right wherever a surface is in it: on for a room,
	/// off for open places.
	public bool boxProjection = true;
	/// Multiplies what it reflects.
	[Range(0, 4)]
	public float intensity = 1;
	/// Where boxes overlap, the higher importance wins (and with the same, the smaller box).
	public int32 importance = 0;
	/// The cube's size in pixels: 32 to 512, or 0 for the quality setting's (128 at High).
	public int32 resolution = 0;
	/// While playing, captures again every this many seconds (0: only when first drawn and on Capture()). For a
	/// changing time of day or moving things; each capture draws the scene six times, one face a frame.
	public float refreshInterval = 0;

	public this() { }
}

/// What a Reflection Probe keeps outside its data: its cube and how far its capturing has got.
class ReflectionProbeState
{
	public bgfx.TextureHandle cube = .() { idx = uint16.MaxValue };
	public int32 cubeSize;
	public bool captured;
	public int32 lastLevel;
	public bool wanted = true;
	public bool secondPass;
	public float capturedAt;
	// What it looked like when captured: a change to where it is or how it is set captures it again in the editor.
	public int64 capturedState;
	public int32 generation = -1;

	public ~this()
	{
		ReleaseCube();
	}

	public bgfx.TextureHandle CubeFor(int32 size)
	{
		if (cube.Valid && cubeSize == size)
			return cube;
		ReleaseCube();
		cube = bgfx.create_texture_cube((uint16)size, true, 1, .RGBA16F, Gfx.TextureRenderTarget | Gfx.SamplerClamp, null, 0);
		cubeSize = size;
		captured = false;
		return cube;
	}

	void ReleaseCube()
	{
		if (cube.Valid && Gfx.Initialized)
			bgfx.destroy_texture(cube);
		cube.idx = uint16.MaxValue;
		captured = false;
		secondPass = false;
	}
}

/// Reflections (docs/reflections.md): the sky's cube, which every surface mirrors, and the reflection probes'.
/// Each cube is drawn and then filtered into levels for rougher surfaces (a GGX blur, rougher down the mip levels),
/// a little each frame so that nothing stalls: the sky in one frame plus one per level, a probe in six (one face
/// each) plus one per level. The sky's cube is made again when the sky or the sun changes.
static class Reflections
{
	/// The bgfx views capturing uses: a RenderView's worth for drawing a probe's face, then six for the faces of the
	/// cube being filled. Drawn after the game's and the editor's views.
	public const uint16 CaptureViewBase = 10 + RenderView.ViewCount * 8;
	public const uint16 FaceViewBase = CaptureViewBase + RenderView.ViewCount;
	/// The cubes' smallest level: rougher than this is not worth a level of its own.
	const int32 SmallestLevel = 4;
	const int32 SkySize = 64;

	/// Reflection cubes at all (off: the ambient colours stand in for the sky, as before them).
	public static bool Enabled = true;
	/// Reflection probes (off: surfaces mirror only the sky). A quality setting.
	public static bool ProbesEnabled = true;
	/// The size of a probe's cube when it does not choose one. A quality setting.
	public static int32 Resolution = 128;
	/// How many captures have finished (sky and probes), since the start.
	public static int32 Captures;
	public static int32 SkyCaptures;

	/// Whether this graphics card can draw into cube maps of 16-bit floats.
	public static bool Supported
	{
		get
		{
			if (!sCheckedSupport)
			{
				sCheckedSupport = true;
				let caps = bgfx.get_caps();
				let wanted = (uint32)(bgfx.CapsFormatFlags.TextureCube | bgfx.CapsFormatFlags.TextureFramebuffer);
				sSupported = caps != null && (caps.formats[(int)bgfx.TextureFormat.RGBA16F] & wanted) == wanted;
				if (!sSupported)
					Log.Info("Reflections: this graphics card cannot draw into cube maps; surfaces mirror the ambient colours");
			}
			return sSupported;
		}
	}

	static bool sCheckedSupport, sSupported;

	public static bgfx.UniformHandle sReflectionProbe, sReflectionSky, sSource;
	public static bgfx.UniformHandle uReflection, uAmbientParams, uProbeMin, uProbeMax, uProbePos, uEnvFace, uEnvFilter, uEnvViewProj;
	static bgfx.ProgramHandle sSkyProgram, sCopyProgram, sFilterProgram;
	static bool sReady;

	static RenderView sCaptureView ~ delete _;
	// The cube a capture is drawn into first, whose mip levels the filter reads.
	static bgfx.TextureHandle sSourceCube = .() { idx = uint16.MaxValue };
	static bgfx.FrameBufferHandle[6] sSourceFaces = .(.() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue }, .() { idx = uint16.MaxValue });
	static int32 sSourceSize;
	static bgfx.TextureHandle sSkyCube = .() { idx = uint16.MaxValue };
	static bool sSkyReady;
	static int32 sSkyLastLevel;
	static int64 sSkyState = int64.MinValue;
	static int64 sUpdatedFrame = -1;
	// Bound where a draw has no cube to use (nothing reads it then).
	static bgfx.TextureHandle sBlackCube = .() { idx = uint16.MaxValue };
	static int32 sGeneration;
	static int32 sAppliedResolution = -1;

	// The capture under way: the sky (sJobProbe default) or a probe; sStep counts its frames.
	static bool sJobRunning;
	static bool sJobSky;
	static ReflectionProbe sJobProbe;
	static Scene sJobScene;
	// The job's probe as its World and entity, which outlast the probe's GameObject (Forget).
	static void* sJobWorld;
	static uint64 sJobEntity;
	static int32 sStep;
	static int32 sJobSize;
	static int64 sJobSkyState;

	/// The probes in the scene being drawn that are ready, for RenderView to choose from.
	public static List<ReflectionProbe> Ready = new .() ~ delete _;
	// Ready's entities, and their World's.
	static List<uint64> sReadyEntities = new .() ~ delete _;
	static void* sReadyWorld;

	/// A probe is going away (its component's OnRemove, given its World and entity): the capture under way, and the
	/// list of ready probes, must not keep it.
	public static void Forget(void* world, uint64 entity)
	{
		if (world == sReadyWorld)
		{
			let index = sReadyEntities.IndexOf(entity);
			if (index >= 0)
			{
				Ready.RemoveAt(index);
				sReadyEntities.RemoveAt(index);
			}
		}
		if (sJobRunning && sJobProbe.GameObject != null && world == sJobWorld && entity == sJobEntity)
		{
			sJobProbe = default;
			sJobRunning = false;
		}
	}

	static void EnsureCreated()
	{
		if (sReady)
			return;
		sReady = true;
		sReflectionProbe = bgfx.create_uniform("s_reflectionProbe", .Sampler, 1);
		sReflectionSky = bgfx.create_uniform("s_reflectionSky", .Sampler, 1);
		sSource = bgfx.create_uniform("s_source", .Sampler, 1);
		uReflection = bgfx.create_uniform("u_reflection", .Vec4, 1);
		uAmbientParams = bgfx.create_uniform("u_ambientParams", .Vec4, 1);
		uProbeMin = bgfx.create_uniform("u_probeMin", .Vec4, 1);
		uProbeMax = bgfx.create_uniform("u_probeMax", .Vec4, 1);
		uProbePos = bgfx.create_uniform("u_probePos", .Vec4, 1);
		uEnvFace = bgfx.create_uniform("u_envFace", .Vec4, 1);
		uEnvFilter = bgfx.create_uniform("u_envFilter", .Vec4, 1);
		uEnvViewProj = bgfx.create_uniform("u_envViewProj", .Mat4, 1);
		sSkyProgram = Gfx.LoadProgram("vs_fullscreen", "fs_env_sky");
		sCopyProgram = Gfx.LoadProgram("vs_fullscreen", "fs_env_copy");
		sFilterProgram = Gfx.LoadProgram("vs_fullscreen", "fs_env_filter");
		uint32[6] black = .(0xff000000, 0xff000000, 0xff000000, 0xff000000, 0xff000000, 0xff000000);
		sBlackCube = bgfx.create_texture_cube(1, false, 1, .RGBA8, 0, bgfx.copy(&black, sizeof(decltype(black))), 0);
	}

	/// The last level of a cube of this size: halving down to SmallestLevel.
	public static int32 LastLevelFor(int32 size)
	{
		int32 last = 0;
		var s = size;
		while (s > SmallestLevel)
		{
			s /= 2;
			last++;
		}
		return last;
	}

	/// The size of a probe's cube: its own, or the quality setting's.
	public static int32 SizeOf(ReflectionProbe probe)
	{
		let wanted = probe.resolution > 0 ? probe.resolution : Resolution;
		var size = (int32)32;
		while (size < wanted && size < 512)
			size *= 2;
		return size;
	}

	/// Called by each RenderView as it starts drawing a scene: the first in a frame advances the capture under way
	/// (or starts the next), and every one gathers the scene's ready probes. sunDir and sunColor are the sun's as
	/// the view set them (the sky's cube shows its glow).
	public static void Update(Scene scene, Vector4 sunDir, Vector4 sunColor, bool advance)
	{
		Ready.Clear();
		sReadyEntities.Clear();
		sReadyWorld = Internal.UnsafeCastToPtr(scene.World);
		if (!Enabled || !Gfx.Initialized || !Supported)
			return;
		EnsureCreated();
		if (Resolution != sAppliedResolution)
		{
			sAppliedResolution = Resolution;
			sGeneration++;
		}
		if (ProbesEnabled)
		{
			for (let probe in scene.Components<ReflectionProbe>(.. scope .()))
			{
				if (probe.GameObject.ActiveInHierarchy && probe.GameObject.InActiveWorld && probe.Captured)
				{
					Ready.Add(probe);
					sReadyEntities.Add(probe.GameObject.Entity.id);
				}
			}
		}
		if (!advance || sUpdatedFrame == Time.FrameCount)
			return;
		sUpdatedFrame = Time.FrameCount;
		if (sJobRunning && (sJobScene != scene || (sJobProbe.GameObject != null && (sJobProbe.GameObject.IsDestroyed || !sJobProbe || sJobProbe.Scene != scene))))
			sJobRunning = false;
		if (!sJobRunning)
			StartNext(scene, sunDir, sunColor);
		if (sJobRunning)
			Step(scene, sunDir, sunColor);
	}

	static int64 SkyState(SceneEnvironment env, Vector4 sunDir, Vector4 sunColor)
	{
		int64 hash = 17;
		for (let color in Color[?](env.skyZenith, env.skyHorizon, env.skyGround))
			Mix(ref hash, .(color.r, color.g, color.b));
		Mix(ref hash, .(sunDir.x, sunDir.y, sunDir.z));
		Mix(ref hash, .(sunColor.x, sunColor.y, sunColor.z));
		return hash;
	}

	/// Adds a vector to a running hash.
	public static void Mix(ref int64 hash, Vector3 value)
	{
		for (var number in float[3](value.x, value.y, value.z))
			hash = hash * 1099511628211 ^ (int64) * (uint32*)&number;
	}

	static void StartNext(Scene scene, Vector4 sunDir, Vector4 sunColor)
	{
		let skyState = SkyState(scene.Environment, sunDir, sunColor);
		if (skyState != sSkyState || !sSkyCube.Valid)
		{
			sJobRunning = true;
			sJobSky = true;
			sJobProbe = default;
			sJobScene = scene;
			sJobSize = SkySize;
			sJobSkyState = skyState;
			sStep = 0;
			if (!sSkyCube.Valid)
				sSkyCube = bgfx.create_texture_cube((uint16)SkySize, true, 1, .RGBA16F, Gfx.TextureRenderTarget | Gfx.SamplerClamp, null, 0);
			return;
		}
		if (!ProbesEnabled)
			return;
		for (let probe in scene.Components<ReflectionProbe>(.. scope .()))
		{
			if (!probe.GameObject.ActiveInHierarchy || !probe.GameObject.InActiveWorld || !probe.WantsCapture(sGeneration))
				continue;
			sJobRunning = true;
			sJobSky = false;
			sJobProbe = probe;
			sJobWorld = Internal.UnsafeCastToPtr(scene.World);
			sJobEntity = probe.GameObject.Entity.id;
			sJobScene = scene;
			sJobSize = SizeOf(probe);
			sStep = 0;
			probe.CaptureStarted(sGeneration);
			return;
		}
	}

	/// Points the source cube's six faces at a cube of this size.
	static void EnsureSource(int32 size)
	{
		if (sSourceCube.Valid && sSourceSize == size)
			return;
		for (int face < 6)
		{
			if (sSourceFaces[face].Valid)
				bgfx.destroy_frame_buffer(sSourceFaces[face]);
		}
		if (sSourceCube.Valid)
			bgfx.destroy_texture(sSourceCube);
		sSourceSize = size;
		// Its mip levels are made as each face is drawn: the filter reads them where its samples are sparse.
		sSourceCube = bgfx.create_texture_cube((uint16)size, true, 1, .RGBA16F, Gfx.TextureRenderTarget | Gfx.SamplerClamp, null, 0);
		for (int face < 6)
			sSourceFaces[face] = FaceTarget(sSourceCube, 0, (uint16)face, true);
	}

	static bgfx.FrameBufferHandle FaceTarget(bgfx.TextureHandle cube, uint16 level, uint16 face, bool makeMips)
	{
		bgfx.Attachment attachment = default;
		attachment.access = .Write;
		attachment.handle = cube;
		attachment.mip = level;
		attachment.layer = face;
		attachment.numLayers = 1;
		attachment.flags = makeMips ? 1 : 0;
		return bgfx.create_frame_buffer_from_attachment(1, &attachment, false);
	}

	/// One frame of the capture under way.
	static void Step(Scene scene, Vector4 sunDir, Vector4 sunColor)
	{
		EnsureSource(sJobSize);
		let lastLevel = LastLevelFor(sJobSize);
		if (sJobSky)
		{
			if (sStep == 0)
			{
				let env = scene.Environment;
				var zenith = Linear(env.skyZenith);
				var horizon = Linear(env.skyHorizon);
				var ground = Linear(env.skyGround);
				var dir = sunDir;
				var color = sunColor;
				for (int face < 6)
				{
					let view = (uint16)(FaceViewBase + face);
					SetUpFaceView(view, "Reflection Sky", sSourceFaces[face], sJobSize);
					Vector4 faceParams = .(face, Gfx.OriginBottomLeft ? 1 : 0, 0, 0);
					bgfx.set_uniform(uEnvFace, &faceParams, 1);
					bgfx.set_uniform(RenderResources.uSunDir, &dir, 1);
					bgfx.set_uniform(RenderResources.uSunColor, &color, 1);
					bgfx.set_uniform(RenderResources.uSkyZenith, &zenith, 1);
					bgfx.set_uniform(RenderResources.uSkyHorizon, &horizon, 1);
					bgfx.set_uniform(RenderResources.uSkyGround, &ground, 1);
					SubmitFullscreen(view, sSkyProgram);
				}
			}
			else
				Filter(sSkyCube, sStep - 1, lastLevel);
			sStep++;
			if (sStep > lastLevel + 1)
			{
				sJobRunning = false;
				sSkyReady = true;
				sSkyLastLevel = lastLevel;
				sSkyState = sJobSkyState;
				SkyCaptures++;
				Captures++;
			}
			return;
		}

		let probe = sJobProbe;
		if (sStep < 6)
			CaptureFace(scene, probe, sStep);
		else
			Filter(probe.CubeFor(sJobSize), sStep - 6, lastLevel);
		sStep++;
		if (sStep > 6 + lastLevel)
		{
			sJobRunning = false;
			probe.CaptureFinished(lastLevel);
			Captures++;
		}
	}

	// Each face's camera: looking along +X, -X, +Y, -Y, +Z, -Z.
	static Vector3[6] sFaceForward = .(.(1, 0, 0), .(-1, 0, 0), .(0, 1, 0), .(0, -1, 0), .(0, 0, 1), .(0, 0, -1));
	static Vector3[6] sFaceUp = .(.(0, 1, 0), .(0, 1, 0), .(0, 0, -1), .(0, 0, 1), .(0, 1, 0), .(0, 1, 0));

	/// Draws the scene from the probe along one face's direction, and copies it into that face of the source cube.
	static void CaptureFace(Scene scene, ReflectionProbe probe, int face)
	{
		if (sCaptureView == null)
		{
			sCaptureView = new RenderView(CaptureViewBase);
			sCaptureView.Capture = true;
		}
		sCaptureView.Resize(sJobSize, sJobSize);
		let eye = probe.CapturePoint;
		let forward = sFaceForward[face];
		CameraData camera = default;
		camera.position = eye;
		camera.forward = forward;
		camera.near = 0.05f;
		camera.far = 1000;
		camera.fieldOfView = 90;
		camera.aspect = 1;
		camera.view = Matrix4.LookAt(eye, eye + forward, sFaceUp[face]);
		camera.projection = Matrix4.Perspective(90, 1, camera.near, camera.far, Gfx.HomogeneousDepth);
		camera.viewmodelLayer = -1;
		camera.viewmodelProjection = camera.projection;
		sCaptureView.Render(scene, camera);

		// The copy finds each texel's direction in the picture, with the camera at the origin.
		var atOrigin = camera.projection * Matrix4.LookAt(.Zero, forward, sFaceUp[face]);
		let view = (uint16)FaceViewBase;
		SetUpFaceView(view, "Reflection Face", sSourceFaces[face], sJobSize);
		Vector4 faceParams = .(face, Gfx.OriginBottomLeft ? 1 : 0, 0, 0);
		bgfx.set_uniform(uEnvFace, &faceParams, 1);
		bgfx.set_uniform(uEnvViewProj, &atOrigin, 1);
		bgfx.set_texture(0, sSource, sCaptureView.SceneColor, uint32.MaxValue);
		SubmitFullscreen(view, sCopyProgram);
	}

	/// Fills one level of a cube, all six faces, from the source cube: level 0 as it is, the last at roughness 1.
	static void Filter(bgfx.TextureHandle cube, int32 level, int32 lastLevel)
	{
		let size = Math.Max(sJobSize >> level, 1);
		for (int face < 6)
		{
			let view = (uint16)(FaceViewBase + face);
			let target = FaceTarget(cube, (uint16)level, (uint16)face, false);
			SetUpFaceView(view, "Reflection Filter", target, size);
			Vector4 faceParams = .(face, Gfx.OriginBottomLeft ? 1 : 0, 0, 0);
			Vector4 filter = .(lastLevel > 0 ? (float)level / lastLevel : 0, sJobSize, LastLevelFor(sJobSize) + 2, 0);
			bgfx.set_uniform(uEnvFace, &faceParams, 1);
			bgfx.set_uniform(uEnvFilter, &filter, 1);
			bgfx.set_texture(0, sSource, sSourceCube, uint32.MaxValue);
			SubmitFullscreen(view, sFilterProgram);
			// Freed once the frame has drawn it.
			bgfx.destroy_frame_buffer(target);
		}
	}

	static void SetUpFaceView(uint16 view, StringView name, bgfx.FrameBufferHandle target, int32 size)
	{
		bgfx.set_view_name(view, name.Ptr, (int32)name.Length);
		bgfx.set_view_frame_buffer(view, target);
		bgfx.set_view_rect(view, 0, 0, (uint16)size, (uint16)size, 0, 1);
		bgfx.set_view_clear(view, 0, 0, 1.0f, 0);
		var identity = Matrix4.Identity;
		bgfx.set_view_transform(view, &identity, &identity);
		bgfx.touch(view);
	}

	static void SubmitFullscreen(uint16 view, bgfx.ProgramHandle program)
	{
		if (bgfx.get_avail_transient_vertex_buffer(3, &Gfx.ScreenLayout) < 3)
			return;
		bgfx.TransientVertexBuffer buffer = default;
		bgfx.alloc_transient_vertex_buffer(&buffer, 3, &Gfx.ScreenLayout);
		let vertices = (ScreenVertex*)buffer.data;
		let top = Gfx.OriginBottomLeft ? 1.0f : 0.0f;
		let bottom = Gfx.OriginBottomLeft ? 0.0f : 1.0f;
		vertices[0].position = .(-1, -1, 0);
		vertices[0].uv = .(0, bottom);
		vertices[1].position = .(-1, 3, 0);
		vertices[1].uv = .(0, bottom + (top - bottom) * 2.0f);
		vertices[2].position = .(3, -1, 0);
		vertices[2].uv = .(2, bottom);
		bgfx.set_transient_vertex_buffer(0, &buffer, 0, 3);
		bgfx.set_state(Gfx.StateWriteRGB | Gfx.StateWriteA, 0);
		bgfx.submit(view, program, 0, 0xff);
	}

	static Vector4 Linear(Color c) => .(Math.Pow(Math.Max(c.r, 0), 2.2f), Math.Pow(Math.Max(c.g, 0), 2.2f), Math.Pow(Math.Max(c.b, 0), 2.2f), c.a);

	/// The probe for a thing at center, radius across (-1: none, the sky alone): of those whose box (and blend
	/// distance) it reaches, one whose light reaches its middle before one it only reaches into (a big floor stays
	/// with its room's probe, not a doorway's beside it); then the most important; then the smallest. The shaders fade it
	/// in for each pixel.
	public static int32 Pick(Vector3 center, float radius)
	{
		int32 best = -1;
		float bestVolume = 0;
		bool bestHolds = false;
		for (int32 i < (int32)Ready.Count)
		{
			let probe = Ready[i];
			let outside = probe.Outside(center);
			let blend = Math.Max(probe.blendDistance, 0.001f);
			if (outside - radius >= blend)
				continue;
			// Its light reaches the middle (a floor whose top is the box's bottom is in the room).
			let holds = outside < blend;
			let extents = probe.WorldBox.Extents;
			let volume = extents.x * extents.y * extents.z;
			var better = best < 0 || (holds && !bestHolds);
			if (!better && holds == bestHolds)
				better = probe.importance > Ready[best].importance || (probe.importance == Ready[best].importance && volume < bestVolume);
			if (better)
			{
				best = i;
				bestVolume = volume;
				bestHolds = holds;
			}
		}
		return best;
	}

	/// Binds the sky's cube and, for a draw lit by a probe (-1: none), the probe's, with their uniforms. ambient is
	/// the scene's ambient intensity when its ambient light comes from them (0: from its ambient colours).
	public static void Bind(int32 probe, float intensity, float ambient)
	{
		if (!sReady)
			EnsureCreated();
		let on = Enabled && sSkyReady && sSkyCube.Valid;
		let sky = on ? sSkyCube : sBlackCube;
		ReflectionProbe chosen = (on && probe >= 0 && probe < Ready.Count) ? Ready[probe] : default;
		let hasProbe = chosen.GameObject != null;
		Vector4 reflection = .(on ? 1 : 0, sSkyLastLevel, hasProbe ? Math.Max(chosen.intensity, 0.0001f) : 0, intensity);
		Vector4 min = .(0, 0, 0, 0), max = .(0, 0, 0, 0), position = .(0, 0, 0, 0);
		if (hasProbe)
		{
			let area = chosen.WorldBox;
			min = .(area.min, chosen.boxProjection ? 1 : 0);
			max = .(area.max, chosen.blendDistance);
			position = .(chosen.CapturePoint, chosen.LastLevel);
		}
		Vector4 ambientParams = .(on && ambient > 0 ? 1 : 0, ambient, 0, 0);
		bgfx.set_uniform(uReflection, &reflection, 1);
		bgfx.set_uniform(uAmbientParams, &ambientParams, 1);
		bgfx.set_uniform(uProbeMin, &min, 1);
		bgfx.set_uniform(uProbeMax, &max, 1);
		bgfx.set_uniform(uProbePos, &position, 1);
		bgfx.set_texture(13, sReflectionProbe, hasProbe ? chosen.Cube : sky, uint32.MaxValue);
		bgfx.set_texture(14, sReflectionSky, sky, uint32.MaxValue);
	}

	/// Writes how many reflection cubes were captured.
	public static void LogTotals()
	{
		if (Captures > 0)
			Log.Info(scope $"Reflections: {SkyCaptures} of the sky and {Captures - SkyCaptures} of probes captured");
	}

	/// Frees the cubes (at shutdown).
	public static void Shutdown()
	{
		if (!sReady || !Gfx.Initialized)
			return;
		DeleteAndNullify!(sCaptureView);
		for (int face < 6)
		{
			if (sSourceFaces[face].Valid)
				bgfx.destroy_frame_buffer(sSourceFaces[face]);
			sSourceFaces[face].idx = uint16.MaxValue;
		}
		if (sSourceCube.Valid)
			bgfx.destroy_texture(sSourceCube);
		if (sSkyCube.Valid)
			bgfx.destroy_texture(sSkyCube);
		bgfx.destroy_texture(sBlackCube);
		bgfx.destroy_uniform(sReflectionProbe);
		bgfx.destroy_uniform(sReflectionSky);
		bgfx.destroy_uniform(sSource);
		for (let uniform in bgfx.UniformHandle[?](uReflection, uAmbientParams, uProbeMin, uProbeMax, uProbePos, uEnvFace, uEnvFilter, uEnvViewProj))
			bgfx.destroy_uniform(uniform);
		for (let program in bgfx.ProgramHandle[?](sSkyProgram, sCopyProgram, sFilterProgram))
			bgfx.destroy_program(program);
		sSourceCube.idx = sSkyCube.idx = sBlackCube.idx = uint16.MaxValue;
		sSkyState = int64.MinValue;
		sSkyReady = false;
		sReady = false;
	}
}
