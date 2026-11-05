using System;
using System.Collections;

namespace Tallow;

/// How a Water surface is drawn (docs/water.md).
[Reflect(.All)]
enum WaterLook : int32
{
	/// Rolling waves with fine ripples, refraction, reflections of the sky and the scene, foam and caustics.
	Realistic,
	/// Faceted waves in flat colours, with crisp bands of foam: for stylized low-poly games.
	LowPoly
}

/// A body of water: a lake, a pool, a river or (Endless) the sea. Its surface is at the object's height and covers
/// Size (X by Z, scaled and turned with the object); the water reaches Depth below it.
///
/// - Waves are Gerstner waves worked out from the settings below and a clock every machine in a network session
///   shares (the server's tick), so every player sees the same waves without anything being sent for them. The
///   settings are [Sync] and the object is shared by default, so changes made on the server (and the water level, by
///   moving the object) reach everyone.
/// - Rigidbodies float in it with Jolt's buoyancy: by default all of them (Float Rigidbodies), with the water's
///   Buoyancy; a Floater component sets an object's own. Flow is the current: it carries floating things and swimmers.
/// - Characters swim (CharacterController.canSwim).
/// - Drawn with refraction, absorption by depth, reflections, foam at the shore and on crests, and caustics; a camera
///   under the surface sees through the water's colour, cut off exactly at the waterline.
///
///   let water = Water.At(Scene, point);
///   if (water && water.SurfaceAt(point, let height, let normal, let velocity)) ...
///
/// A handle (ComponentHandle): its settings are WaterData's fields; the waves worked out from them and what floated
/// at the last step are its WaterState.
/// A Water's settings, in its entity (Water is the handle). They are [Sync]: the server's reach every client.
[Component, HandleData]
struct WaterData
{
	/// How it is drawn. Choosing one in the GameObject menu also sets the colours and grid to suit it (UseLook).
	[Sync]
	public WaterLook look = .Realistic;
	/// The surface's width (X) and length (Z) in metres, before the object's scale.
	[Sync]
	public Vector2 size = .(40, 40);
	/// How far below the surface the water reaches, in metres: the bottom of what floats things and of the
	/// underwater view.
	[Sync]
	public float depth = 10;
	/// Water to the horizon in every direction (the sea): Size is not used, and the surface follows the camera.
	[Sync]
	public bool endless = false;

	/// Height of the waves from trough to crest, in metres, where all of them meet. 0 is still water.
	[Sync, Range(0, 20)]
	public float waveHeight = 0.4f;
	/// Distance between the crests of the longest waves, in metres; the others are shorter.
	[Sync]
	public float waveLength = 14;
	/// The way the waves travel, in degrees round from +X towards +Z.
	[Sync, Range(0, 360)]
	public float waveDirection = 30;
	/// How far the shorter waves turn away from Wave Direction, in degrees: 0 is a swell all one way, more is choppier.
	[Sync, Range(0, 180)]
	public float waveSpread = 50;
	/// Sharpens crests and widens troughs (0: rounded swells, 1: as sharp as they go).
	[Sync, Range(0, 1)]
	public float choppiness = 0.5f;
	/// Multiplies how fast the waves move (1: as deep water waves of their length do).
	[Sync]
	public float waveSpeed = 1;
	/// Picks another arrangement of the waves.
	[Sync]
	public int32 waveSeed = 1;
	/// The current, in metres a second along X and Z of the world: rivers. It moves the ripples and foam and carries
	/// floating things and swimmers.
	[Sync]
	public Vector2 flow = .Zero;

	/// Colour of the water where it is shallow (and of its lit surface).
	[Sync]
	public Color shallowColor = .(0.12f, 0.52f, 0.55f, 1);
	/// Colour of the water where it is deep.
	[Sync]
	public Color deepColor = .(0.02f, 0.10f, 0.17f, 1);
	/// How far you can see through it, in metres: past this the bottom is lost in Deep Color.
	[Sync]
	public float clarity = 6;
	/// How much what is under the surface is bent by the waves.
	[Sync, Range(0, 0.3f)]
	public float refraction = 0.04f;
	/// How rough the surface is: 0 is a mirror.
	[Sync, Range(0, 1)]
	public float roughness = 0.05f;
	/// How much foam: at the shore, round things standing in the water and on the sharpest crests. 0 is none.
	[Sync, Range(0, 2)]
	public float foam = 1;
	/// How far out from the shore foam reaches, in metres of water depth.
	[Sync]
	public float shoreFoam = 0.6f;
	[Sync]
	public Color foamColor = .White;
	/// The bright lines that light makes through moving water, on what is under it.
	[Sync]
	public bool caustics = true;
	/// The scene mirrored in the water, found on the screen (the sky and reflection probes are mirrored anyway).
	[Sync]
	public bool screenReflections = true;
	/// Metres between the surface's points near the camera. Smaller is smoother and slower; Low Poly looks best
	/// with large facets.
	[Sync]
	public float gridSpacing = 0.5f;

	/// Colour of the water round a camera under the surface.
	[Sync]
	public Color underwaterColor = .(0.10f, 0.36f, 0.40f, 1);
	/// How far a camera under the surface can see, in metres.
	[Sync]
	public float underwaterVisibility = 22;

	/// Every Rigidbody, soft body and rope in the water floats (or sinks) by Buoyancy; off, only those with a Floater do.
	[Sync]
	public bool floatRigidbodies = true;
	/// How strongly things float: 1 neither floats nor sinks, more floats higher, less sinks. A Floater sets an
	/// object's own.
	[Sync]
	public float buoyancy = 1.6f;
	/// How quickly the water slows things moving through it (and brings them to Flow's speed): about this many times
	/// a second for something all under. More settles bobbing sooner.
	[Sync]
	public float waterDrag = 1;
	/// How quickly the water stops things turning in it, likewise.
	[Sync]
	public float waterAngularDrag = 1;

	public this() { }
}

[Component, HandleFields]
struct Water : ComponentHandle<WaterData>
{
	/// Gerstner waves summed for the surface.
	public const int WaveCount = 4;

	/// One wave of the sum: travelling along direction (x, z), wavenumber k = 2 pi / length, amplitude (half its
	/// height), steepness (how far points swing along it) and angular speed.
	public struct Wave
	{
		public Vector2 direction;
		public float k;
		public float amplitude;
		public float steepness;
		public float omega;
	}

	/// The waves and what floated, made the first time they are needed.
	public WaterState State
	{
		get
		{
			CheckValid();
			return ComponentState<WaterState>.Make(mGameObject.Scene.World, mGameObject.Entity);
		}
	}

	// The relative lengths and heights of the four waves, and how far each turns from the main direction (times
	// Wave Spread). The seed nudges the turns.
	static readonly float[WaveCount] sLengths = .(1.0f, 0.62f, 0.38f, 0.24f);
	static readonly float[WaveCount] sHeights = .(1.0f, 0.55f, 0.32f, 0.18f);
	static readonly float[WaveCount] sTurns = .(0.0f, 0.55f, -0.75f, 0.3f);

	/// The surface's height when still, in the world.
	public float Level => Transform.Position.y;
	/// The lowest the water reaches.
	public float Bottom => Level - Math.Max(depth, 0);

	/// The waves as they are now set.
	public Span<Wave> Waves
	{
		get
		{
			let state = UpdateWaves();
			return .(&state.waves[0], WaveCount);
		}
	}

	WaterState UpdateWaves()
	{
		let state = State;
		float[8] key = .(waveHeight, waveLength, waveDirection, waveSpread, choppiness, waveSpeed, (float)waveSeed, 0);
		bool same = true;
		for (int i < key.Count)
			same &= key[i] == state.waveKey[i];
		if (same)
			return state;
		state.waveKey = key;
		float heightSum = 0;
		for (int i < WaveCount)
			heightSum += sHeights[i];
		// A small generator every machine runs the same way: the seed's arrangement is the same everywhere.
		uint32 seed = (uint32)waveSeed * 747796405u + 2891336453u;
		for (int i < WaveCount)
		{
			seed = seed * 1664525u + 1013904223u;
			let jitter = (float)((seed >> 8) & 0xffff) / 65535.0f * 2 - 1;
			let turn = i == 0 ? 0 : (sTurns[i] + jitter * 0.25f);
			let angle = (waveDirection + turn * waveSpread) * Mathf.Deg2Rad;
			var wave = ref state.waves[i];
			wave.direction = .(Math.Cos(angle), Math.Sin(angle));
			let length = Math.Max(waveLength * sLengths[i], 0.05f);
			wave.k = Math.PI_f * 2 / length;
			wave.amplitude = Math.Max(waveHeight, 0) * 0.5f * sHeights[i] / heightSum;
			// Summed over the waves, steepness times k times amplitude stays below 1, where crests would fold over.
			wave.steepness = wave.amplitude > 0 ? Math.Clamp(choppiness, 0, 1) * 0.95f / (wave.k * wave.amplitude * WaveCount) : 0;
			wave.omega = Math.Sqrt(9.81f * wave.k) * waveSpeed;
		}
		return state;
	}

	/// Each wave's phase at a time, worked out in double precision so that waves stay smooth however long a session
	/// runs: the angle the wave has travelled, kept to one turn.
	public void Phases(double time, ref float[WaveCount] phases)
	{
		let state = UpdateWaves();
		for (int i < WaveCount)
			phases[i] = (float)Math.IEEERemainder((double)state.waves[i].omega * time, Math.PI_d * 2);
	}

	// ------------------------------------------------------------------ the shared clock

	/// The waves' time for the simulation (buoyancy, swimming, game code): in a network session the session's tick,
	/// so the server and a client predicting the same tick agree; playing alone, the scene's tick; in the editor,
	/// the time since the program started.
	public static double SimulationTime(Scene scene)
	{
		let network = scene?.Network;
		if (network != null && network.Mode != .Offline)
			return network.Tick / (double)Time.TickRate;
		if (scene != null && scene.IsPlaying)
			return Time.Tick / (double)Time.TickRate;
		return Time.RealTime;
	}

	/// The waves' time for drawing: the same clock, smoothly between ticks, and on a client the server's.
	public static double ViewTime(Scene scene)
	{
		let network = scene?.Network;
		if (network != null && network.Mode != .Offline)
			return (network.ServerTick - 1 + Time.InterpolationAlpha) / (double)Time.TickRate;
		if (scene != null && scene.IsPlaying)
			return (Time.Tick - 1 + Time.InterpolationAlpha) / (double)Time.TickRate;
		return Time.RealTime;
	}

	// ------------------------------------------------------------------ the surface

	/// Whether a point's X and Z are over this water (Endless water is everywhere).
	public bool Covers(Vector3 point)
	{
		if (endless)
			return true;
		let local = Transform.WorldToLocal.TransformPoint(point);
		return Math.Abs(local.x) <= size.x * 0.5f && Math.Abs(local.z) <= size.y * 0.5f;
	}

	/// Where the surface is over a point, at the simulation's time: its height, which way it faces and how fast the
	/// water there moves (the current, and the waves' swing). False when the point is not over this water.
	public bool SurfaceAt(Vector3 point, out float height, out Vector3 normal, out Vector3 velocity)
	{
		return SurfaceAt(point, SimulationTime(Scene), out height, out normal, out velocity);
	}

	/// The surface over a point at a given time on the waves' clock (SimulationTime or ViewTime).
	public bool SurfaceAt(Vector3 point, double time, out float height, out Vector3 normal, out Vector3 velocity)
	{
		height = Level;
		normal = .Up;
		velocity = .(flow.x, 0, flow.y);
		if (!Covers(point))
			return false;
		let state = UpdateWaves();
		float[WaveCount] phases = default;
		Phases(time, ref phases);
		// The waves swing points sideways as well as up: find the point of still water that ends up over this one.
		var origin = Vector2(point.x, point.z);
		let target = origin;
		for (int iteration < 4)
		{
			var shift = Vector2.Zero;
			for (int i < WaveCount)
			{
				let wave = state.waves[i];
				let theta = wave.k * (wave.direction.x * origin.x + wave.direction.y * origin.y) - phases[i];
				shift += wave.direction * (wave.steepness * wave.amplitude * Math.Cos(theta));
			}
			origin = target - shift;
		}
		float up = 0;
		Vector3 n = .(0, 1, 0);
		for (int i < WaveCount)
		{
			let wave = state.waves[i];
			let theta = wave.k * (wave.direction.x * origin.x + wave.direction.y * origin.y) - phases[i];
			let s = Math.Sin(theta);
			let c = Math.Cos(theta);
			up += wave.amplitude * s;
			let ka = wave.k * wave.amplitude;
			n.x -= wave.direction.x * ka * c;
			n.z -= wave.direction.y * ka * c;
			n.y -= wave.steepness * ka * s;
			// The swing's speed: the water at a crest moves with the wave, in a trough against it.
			velocity.x += wave.direction.x * wave.steepness * wave.amplitude * wave.omega * s;
			velocity.z += wave.direction.y * wave.steepness * wave.amplitude * wave.omega * s;
			velocity.y -= wave.amplitude * wave.omega * c;
		}
		height = Level + up;
		normal = n.Normalized;
		return true;
	}

	/// The surface's height over a point (the still level where the point is not over this water).
	public float HeightAt(Vector3 point)
	{
		SurfaceAt(point, let height, ?, ?);
		return height;
	}

	/// How far below the surface a point is (negative above it). Not over this water: float.MinValue.
	public float DepthOf(Vector3 point)
	{
		if (!SurfaceAt(point, let height, ?, ?))
			return float.MinValue;
		return height - point.y;
	}

	/// Whether a point is in the water: over it, below the surface and above the bottom.
	public bool Contains(Vector3 point)
	{
		if (point.y < Bottom)
			return false;
		if (!SurfaceAt(point, let height, ?, ?))
			return false;
		return point.y <= height;
	}

	/// The water over a point that a thing there would be in: over it, with the point above its bottom and no more
	/// than reach above its still level (things above the surface can still have their lower parts in it). Of
	/// several, the one with the highest level. forObject: the thing asking; with world states set apart
	/// (ProjectConfig.SeparateWorldStates) only water sharing one of its world states counts, whatever the scene's
	/// active state. Without it, water outside the scene's active state does not count.
	public static Water At(Scene scene, Vector3 point, float reach = 0, GameObject forObject = null)
	{
		if (scene == null)
			return default;
		Water best = default;
		for (let water in scene.Components<Water>(.. scope .()))
		{
			if (!water.GameObject.ActiveInHierarchy || !Meets(scene, water.GameObject, forObject))
				continue;
			let level = water.Level;
			let top = level + Math.Max(water.waveHeight, 0) + reach;
			if (point.y > top || point.y < water.Bottom - reach || !water.Covers(point))
				continue;
			if (!best || level > best.Level)
				best = water;
		}
		return best;
	}

	/// Whether the water's object and a thing in it take part together: sharing a world state when world states are
	/// set apart, else both in the scene's active state.
	static bool Meets(Scene scene, GameObject water, GameObject thing)
	{
		if (scene.Physics.SeparatesWorldStates)
			return thing == null || scene.Physics.ShareWorld(water, thing);
		return water.InActiveWorld && (thing == null || thing.InActiveWorld);
	}

	/// Sets the colours, grid and waves that suit a look, and the look.
	public void UseLook(WaterLook newLook)
	{
		look = newLook;
		switch (newLook)
		{
		case .Realistic:
			shallowColor = .(0.12f, 0.52f, 0.55f, 1);
			deepColor = .(0.02f, 0.10f, 0.17f, 1);
			underwaterColor = .(0.10f, 0.36f, 0.40f, 1);
			foamColor = .White;
			clarity = 6;
			refraction = 0.04f;
			roughness = 0.05f;
			choppiness = 0.5f;
			gridSpacing = 0.5f;
			caustics = true;
			screenReflections = true;
		case .LowPoly:
			shallowColor = .(0.36f, 0.86f, 0.84f, 1);
			deepColor = .(0.10f, 0.42f, 0.72f, 1);
			underwaterColor = .(0.16f, 0.50f, 0.70f, 1);
			foamColor = .(0.95f, 1.0f, 1.0f, 1);
			clarity = 2.5f;
			refraction = 0.0f;
			roughness = 0.3f;
			choppiness = 0.25f;
			gridSpacing = 1.6f;
			caustics = false;
			screenReflections = false;
		}
	}

	// ------------------------------------------------------------------ floating

	/// Before each physics step (Scene): floats the scene's dynamic Rigidbodies in the water they are in, with Jolt's
	/// buoyancy against the surface under each one's middle.
	public static void Simulate(Scene scene, float deltaTime) => SimulateAt(scene, deltaTime, SimulationTime(scene));

	/// Rollback supplies its historical tick rather than the scene's current clock.
	static void SimulateAt(Scene scene, float deltaTime, double time)
	{
		let waters = scene.Components<Water>(.. scope .());
		if (waters.Count == 0)
			return;
		for (let water in waters)
			water.State.floating.Clear();
		for (let component in scene.ComponentsOfType(typeof(Rigidbody)))
		{
			let body = (Rigidbody)component;
			if (!body.IsActiveAndEnabled || body.isKinematic || !body.HasBody || (!scene.Physics.SeparatesWorldStates && !body.GameObject.InActiveWorld))
				continue;
			let floater = body.GameObject.GetComponent<Floater>();
			if (floater && !floater.IsActiveAndEnabled)
				continue;
			let position = body.Transform.Position;
			// Things as tall as a few metres can reach the water from above its surface.
			let water = At(scene, position, 4, body.GameObject);
			if (!water || (!floater && !water.floatRigidbodies))
				continue;
			if (!water.SurfaceAt(position, time, let height, let normal, let velocity))
				continue;
			let factor = floater ? floater.buoyancy : water.buoyancy;
			let drag = floater ? floater.drag : water.waterDrag;
			let angularDrag = floater ? floater.angularDrag : water.waterAngularDrag;
			// Under the bottom there is no water to push up: the surface is the bottom there.
			let surface = position.y < water.Bottom ? Vector3(position.x, water.Bottom, position.z) : Vector3(position.x, height, position.z);
			if (scene.Physics.ApplyBuoyancy(body.BodyId, surface, normal, factor, drag, angularDrag, velocity, deltaTime))
				water.State.floating.Add(body.BodyId);
		}
		// Jelly, cloth and ropes float vertex by vertex; a shell rides its Rigidbody, which floats above.
		for (let component in scene.ComponentsOfType(typeof(SoftBody)))
		{
			let soft = (SoftBody)component;
			if (soft.kind != .Shell && soft.IsActiveAndEnabled && (scene.Physics.SeparatesWorldStates || soft.GameObject.InActiveWorld))
				FloatSoft(scene, soft.GameObject, soft.BodyId, soft.gravityScale, time, deltaTime);
		}
		for (let component in scene.ComponentsOfType(typeof(Rope)))
		{
			let rope = (Rope)component;
			if (rope.IsActiveAndEnabled && (scene.Physics.SeparatesWorldStates || rope.GameObject.InActiveWorld))
				FloatSoft(scene, rope.GameObject, rope.BodyId, 1, time, deltaTime);
		}
	}

	[CLink] static extern bool tn_soft_bounds(void* world, uint32 bodyId, Vector3* min, Vector3* max);
	[CLink] static extern uint32 tn_soft_float(void* world, uint32 bodyId, float* samples, uint32 nx, uint32 nz, float minX, float minZ, float cellX, float cellZ, float bottom,
		float band, float buoyancy, float drag, float gravity, float step, bool wake);

	/// The most samples of the surface across a soft body each way, and how far apart they are at most.
	const int SoftSamples = 8;
	const float SoftSampleSpacing = 0.5f;
	/// How far round the surface a vertex goes from dry to wholly under: the floating's give.
	const float SoftBand = 0.05f;

	/// Floats one soft body or rope: the surface is sampled on a small grid over it (at most 8 x 8, whatever its
	/// vertex count) and each vertex under it is lifted and dragged, natively.
	static void FloatSoft(Scene scene, GameObject owner, uint32 bodyId, float gravityScale, double time, float deltaTime)
	{
		if (bodyId == uint32.MaxValue || scene.Physics == null)
			return;
		let floater = owner.GetComponent<Floater>();
		if (floater && !floater.IsActiveAndEnabled)
			return;
		let system = scene.Physics.[Friend]mSystem;
		Vector3 min = default, max = default;
		if (!tn_soft_bounds(system, bodyId, &min, &max))
			return;
		let center = (min + max) * 0.5f;
		let water = At(scene, center, (max.y - min.y) * 0.5f + 1, owner);
		if (!water || (!floater && !water.floatRigidbodies) || min.y > water.Level + water.waveHeight + SoftBand || max.y < water.Bottom)
			return;
		let nx = Math.Clamp((int)Math.Ceiling((max.x - min.x) / SoftSampleSpacing) + 1, 2, SoftSamples);
		let nz = Math.Clamp((int)Math.Ceiling((max.z - min.z) / SoftSampleSpacing) + 1, 2, SoftSamples);
		let cellX = Math.Max((max.x - min.x) / (nx - 1), 0.001f), cellZ = Math.Max((max.z - min.z) / (nz - 1), 0.001f);
		float[SoftSamples * SoftSamples * 4] samples = default;
		for (int z < nz)
		{
			for (int x < nx)
			{
				let at = Vector3(min.x + x * cellX, center.y, min.z + z * cellZ);
				let i = (z * nx + x) * 4;
				// Past the edge of a pond the surface is far below: nothing there floats.
				if (!water.SurfaceAt(at, time, let height, ?, let velocity))
				{
					samples[i] = water.Bottom - 100;
					continue;
				}
				samples[i] = height;
				samples[i + 1] = velocity.x;
				samples[i + 2] = velocity.y;
				samples[i + 3] = velocity.z;
			}
		}
		let gravity = Math.Abs(scene.Physics.Gravity.y) * gravityScale;
		let wake = water.waveHeight > 0 || water.flow != .Zero;
		let buoyancy = floater ? floater.buoyancy : water.buoyancy;
		let drag = floater ? floater.drag : water.waterDrag;
		if (tn_soft_float(system, bodyId, &samples, (uint32)nx, (uint32)nz, min.x, min.z, cellX, cellZ, water.Bottom, SoftBand, buoyancy, drag, gravity, deltaTime, wake) > 0)
			water.State.floating.Add(bodyId);
	}

	/// Whether a Rigidbody was in this water at the last physics step.
	public bool IsFloating(Rigidbody body) => body != null && body.HasBody && Floating(body.BodyId);
	/// Whether any of a soft body's vertices were in this water at the last physics step (a shell: its Rigidbody).
	public bool IsFloating(SoftBody soft) => soft != null && soft.HasBody && Floating(soft.BodyId);
	/// Whether any of a rope's points were in this water at the last physics step.
	public bool IsFloating(Rope rope) => rope != null && rope.HasBody && Floating(rope.BodyId);

	bool Floating(uint32 bodyId)
	{
		let state = ComponentState<WaterState>.Get(mGameObject.Scene.World, mGameObject.Entity);
		return state != null && state.floating.Contains(bodyId);
	}

	static void OnRemove(void* world, uint64 entity) => ComponentState<WaterState>.Release(world, entity);

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		let water = gameObject.GetComponent<Water>();
		let transform = gameObject.Transform;
		let endless = water.endless, depth = water.depth, size = water.size;
		let tint = selected ? Color(0.3f, 0.8f, 1.0f, 1) : Color(0.3f, 0.7f, 1.0f, 0.4f);
		if (endless)
		{
			let at = transform.Position;
			Gizmos.Lines.Circle(at, .Up, 4, tint);
			Gizmos.Lines.Line(at, at - Vector3(0, Math.Max(depth, 0), 0), tint);
			return;
		}
		// The surface's rectangle, and when selected the box the water fills.
		let model = transform.LocalToWorld;
		let half = Vector3(size.x * 0.5f, 0, size.y * 0.5f);
		Gizmos.Lines.Box(.(-half, half), model, tint);
		if (selected)
		{
			let scale = Math.Max(model.TransformDirection(.Up).Length, 0.0001f);
			let down = Math.Max(depth, 0) / scale;
			Gizmos.Lines.Box(.(Vector3(-half.x, -down, -half.z), half), model, Color(0.3f, 0.7f, 1.0f, 0.35f));
		}
	}
}

/// A Floater's settings.
[Component, HandleData]
struct FloaterData
{
	/// How strongly it floats: 1 neither floats nor sinks, more floats higher (a cork), less sinks (a stone).
	public float buoyancy = 1.6f;
	/// How quickly the water slows it moving (and brings it to the water's flow): about this many times a second
	/// when it is all under.
	public float drag = 1;
	/// How quickly the water stops it turning, likewise.
	public float angularDrag = 1;

	public this() { }
}

/// Sets how one Rigidbody, soft body or rope floats in Water, in place of the water's own settings; disabled, it
/// does not float at all. Floating needs Water's Float Rigidbodies only for objects without one. (Angular Drag is
/// for Rigidbodies: soft bodies and ropes are slowed vertex by vertex.)
[Component, HandleFields]
struct Floater : ComponentHandle<FloaterData>
{
	/// Whether it was in water at the last physics step.
	public bool InWater
	{
		get
		{
			let body = GameObject.GetComponent<Rigidbody>();
			let soft = GameObject.GetComponent<SoftBody>();
			let rope = GameObject.GetComponent<Rope>();
			for (let water in Scene.FindComponents<Water>(.. scope .()))
			{
				if (water.IsFloating(body) || water.IsFloating(soft) || water.IsFloating(rope))
					return true;
			}
			return false;
		}
	}
}

/// What a Water keeps outside its data: the waves worked out from its settings (made again when one changes) and the
/// bodies that were in it at the last step (for Floater.InWater).
class WaterState
{
	public Water.Wave[Water.WaveCount] waves;
	public float[8] waveKey = .(-1, -1, -1, -1, -1, -1, -1, -1);
	public HashSet<uint32> floating = new .() ~ delete _;
}
