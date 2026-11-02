using System;
using System.Collections;
using Tallow;

namespace {NAMESPACE};

/// The Tallow Gallery: a courtyard, a hall of reflections, a room of lights and a yard of things to knock over.
/// The first run of an empty scene builds it; --author-scene then saves it as Scenes/Gallery.tscene, so all of it is
/// ordinary objects that can be moved in the editor. What is left here is what moves while playing.
[Component]
class Gallery : Component
{
	public bool built;

	struct Room
	{
		public StringView name, about;
		public Vector3 min, max;
	}

	static Room[5] sRooms = .(
		.() { name = "Hall of Reflections", about = "Each probe box matches its room, so the walls line up in the floor and in every sphere.", min = .(-14, 0, 1), max = .(14, 9, 19) },
		.() { name = "Room of Lights", about = "Clustered point lights with shadows, a spot light, and emissive tubes through bloom.", min = .(14, 0, 3), max = .(28, 7, 17) },
		.() { name = "Physics Yard", about = "Walk into the stack, or press E to shove what you are looking at. The ball hangs on a rope.", min = .(16, 0, -34), max = .(44, 12, -4) },
		.() { name = "Pool Garden", about = "Built-in water, grass and bushes that sway in the wind, and a character skinned on the GPU.", min = .(-44, 0, -34), max = .(-8, 12, -4) },
		.() { name = "Courtyard", about = "Sun, shadows, wind in the flag. The Hall of Reflections is straight ahead.", min = .(-8, 0, -34), max = .(16, 12, 1) }
	);

	Transform mWalker;
	Transform[3] mOrbiters;
	Light[2] mBraziers;
	Visitor mVisitor;
	UIDocument mHud;
	int mRoom = -1;
	float mWalkAngle;
	uint32 mSeed;

	// Materials the rooms share.
	static readonly Color Stone = .(0.62f, 0.6f, 0.56f);
	static readonly Color Marble = .(0.13f, 0.14f, 0.17f);
	static readonly Color Timber = .(0.46f, 0.3f, 0.17f);
	static readonly Color Leaf = .(0.2f, 0.42f, 0.2f);

	public override void Awake()
	{
		if (!built)
			Build();
	}

	public override void Start()
	{
		let app = Application.Instance;
		String root = scope .();
		if (app.HasArg("--author-scene") && app.GetArg("--project", root))
		{
			let ok = SceneSerializer.SaveToFile(Scene, scope $"{root}/src/Scenes/Gallery.tscene");
			Console.WriteLine(scope $"AUTHORED_SCENE_SAVED,{ok},{Scene.Objects.Count}");
			app.Running = false;
			return;
		}
		// What moves is found by name, so that it can be rearranged in the editor.
		mWalker = Scene.Find("Walking figure")?.Transform;
		for (int i < mOrbiters.Count)
			mOrbiters[i] = Scene.Find(scope $"Orbiting light {i}").Transform;
		for (int i < mBraziers.Count)
			mBraziers[i] = Scene.Find(scope $"Brazier light {i}").GetComponent<Light>();
		let camera = Scene.FindComponent<Camera>();
		let person = Scene.CreateGameObject("Visitor");
		person.Transform.Position = .(4, 1.1f, -28);
		let body = person.AddComponent<CharacterController>();
		body.radius = 0.34f;
		body.height = 1.8f;
		body.pushStrength = 180;
		mVisitor = person.AddComponent<Visitor>();
		mVisitor.view = camera;
		let hud = Scene.CreateGameObject("Hud");
		mHud = hud.AddComponent<UIDocument>();
		mHud.document.Set("UI/hud.tui");
		String value = scope .();
		if (app.GetArg("--view", value))
			Stand(SceneSerializer.ParseInt(value));
		if (app.HasArg("--self-test"))
			Console.WriteLine(scope $"SHOWCASE_READY rooms={sRooms.Count} probes={Scene.FindComponents<ReflectionProbe>(.. scope .()).Count} objects={Scene.Objects.Count}");
	}

	/// Test switch --view N: stand somewhere worth a screenshot.
	void Stand(int view)
	{
		(Vector3 at, float yaw, float pitch)[?] places = .(
			(.(4, 1.1f, -28), 0, 0), (.(0, 1.1f, 3), 0, 6), (.(-12, 1.1f, 3), 50, 6), (.(15, 1.6f, 6), 62, 6),
			(.(19, 1.1f, -28), 40, 4), (.(-14, 1.1f, -9), 240, 10), (.(-34, 1.1f, -11), 60, 4));
		let place = places[Math.Clamp(view, 0, places.Count - 1)];
		mVisitor.GetComponent<CharacterController>().Teleport(place.at);
		mVisitor.yaw = place.yaw;
		mVisitor.pitch = place.pitch;
	}

	public override void Update()
	{
		if (!Scene.IsPlaying || mVisitor == null)
			return;
		let t = Time.RealTime;
		// The lights go round their room, each at its own pace.
		for (int i < mOrbiters.Count)
		{
			let angle = t * (0.5f + i * 0.17f) + i * 2.1f;
			mOrbiters[i].Position = Vector3(21 + Math.Cos(angle) * 4.2f, 2.4f + Math.Sin(t + i) * 0.8f, 10 + Math.Sin(angle) * 4.2f);
		}
		for (int i < mBraziers.Count)
			mBraziers[i].intensity = 9 + Math.Sin(t * 11 + i) * 1.5f + Math.Sin(t * 23 + i * 3) * 1.1f;
		if (mWalker != null)
		{
			mWalkAngle += Time.DeltaTime * 0.45f;
			mWalker.Position = Vector3(-30 + Math.Cos(mWalkAngle) * 4.5f, 0, -8 + Math.Sin(mWalkAngle) * 2.5f);
			mWalker.Rotation = Quaternion.Euler(0, -Math.RadiansToDegrees(mWalkAngle), 0);
		}
		if (Input.GetKeyDown(.E))
			Shove();
		ShowRoom();
	}

	/// Pushes whatever rigid body the visitor is looking at.
	void Shove()
	{
		let view = mVisitor.view.Transform;
		if (Scene.Physics.Raycast(view.Position, view.Forward, 14, let hit) && hit.gameObject != null)
			hit.gameObject.GetComponent<Rigidbody>()?.AddImpulse(view.Forward * 60);
	}

	void ShowRoom()
	{
		let at = mVisitor.Transform.Position;
		int room = 4;
		for (int i < sRooms.Count)
		{
			let r = sRooms[i];
			if (at.x >= r.min.x && at.x <= r.max.x && at.z >= r.min.z && at.z <= r.max.z)
			{
				room = i;
				break;
			}
		}
		if (room == mRoom)
			return;
		mRoom = room;
		mHud.Find("room")?.SetText(sRooms[room].name);
		mHud.Find("about")?.SetText(sRooms[room].about);
	}

	// Building.

	GameObject Box(StringView name, Vector3 at, Vector3 size, Color color, float roughness = 0.8f, float metallic = 0, bool solid = true)
	{
		let o = Scene.CreateGameObject(name);
		o.Transform.Position = at;
		o.Transform.LocalScale = size;
		let r = o.AddComponent<MeshRenderer>();
		r.color = color;
		r.roughness = roughness;
		r.metallic = metallic;
		if (solid)
			o.AddComponent<BoxCollider>();
		return o;
	}

	GameObject Ball(StringView name, Vector3 at, float radius, Color color, float roughness, float metallic)
	{
		let o = Box(name, at, Vector3(radius * 2), color, roughness, metallic, false);
		let r = o.GetComponent<MeshRenderer>();
		r.mesh.Set("builtin:sphere_smooth");
		r.flatShading = false;
		o.AddComponent<SphereCollider>();
		return o;
	}

	GameObject Glow(StringView name, Vector3 at, Vector3 size, Color color, float strength)
	{
		let o = Box(name, at, size, color, 0.5f, 0, false);
		let r = o.GetComponent<MeshRenderer>();
		r.emissive = color;
		r.emissiveIntensity = strength;
		r.castShadows = false;
		return o;
	}

	Light Lamp(StringView name, Vector3 at, Color color, float intensity, float range, bool shadows = false)
	{
		let o = Scene.CreateGameObject(name);
		o.Transform.Position = at;
		let light = o.AddComponent<Light>();
		light.type = .Point;
		light.color = color;
		light.intensity = intensity;
		light.range = range;
		light.castShadows = shadows;
		return light;
	}

	/// A box the size of the room, seeing from about eye height. Box projection is what lines reflections up with
	/// the walls, and it is only right when the box is the room.
	void Probe(StringView name, Vector3 min, Vector3 max, int32 resolution)
	{
		let o = Scene.CreateGameObject(name);
		o.Transform.Position = (min + max) * 0.5f;
		let probe = o.AddComponent<ReflectionProbe>();
		probe.size = max - min;
		probe.captureOffset = .(0, 1.7f - (max.y - min.y) * 0.5f, 0);
		probe.boxProjection = true;
		probe.blendDistance = 0.5f;
		probe.resolution = resolution;
	}

	void Build()
	{
		built = true;
		let sun = Scene.CreateGameObject("Sun");
		sun.Transform.Rotation = Quaternion.Euler(50, -35, 0);
		let light = sun.AddComponent<Light>();
		light.type = .Directional;
		light.intensity = 1.5f;
		let camera = Scene.CreateGameObject("Camera");
		camera.Transform.Position = .(4, 1.8f, -28);
		let lens = camera.AddComponent<Camera>();
		lens.fieldOfView = 74;
		lens.nearClip = 0.08f;
		lens.farClip = 1200;
		Box("Ground", .(0, -0.5f, 0), .(180, 1, 180), .(0.36f, 0.45f, 0.26f), 0.95f);
		Box("Courtyard paving", .(4, 0.01f, -16), .(24, 0.02f, 34), Stone, 0.7f, 0, false);
		BuildHall();
		BuildLightRoom();
		BuildYard();
		BuildGarden();
		BuildCourtyard();
	}

	void BuildHall()
	{
		// The walls stand just outside the probe's box, so its box is the room.
		let floor = Box("Hall floor", .(0, 0.02f, 10), .(28, 0.04f, 18), .(0.1f, 0.1f, 0.12f), 0.07f, 1, false);
		floor.GetComponent<MeshRenderer>().flatShading = false;
		Box("Hall roof", .(0, 9.25f, 10), .(29, 0.5f, 19), Marble);
		Box("Hall north wall", .(0, 4.5f, 19.25f), .(29, 9, 0.5f), Marble, 0.4f);
		Box("Hall west wall", .(-14.25f, 4.5f, 10), .(0.5f, 9, 19), Marble, 0.4f);
		Box("Hall south wall left", .(-8.25f, 4.5f, 0.75f), .(12.5f, 9, 0.5f), Marble, 0.4f);
		Box("Hall south wall right", .(8.25f, 4.5f, 0.75f), .(12.5f, 9, 0.5f), Marble, 0.4f);
		Box("Hall south lintel", .(0, 6.75f, 0.75f), .(4, 4.5f, 0.5f), Marble, 0.4f);
		Box("Hall east wall south", .(14.25f, 4.5f, 4.5f), .(0.5f, 9, 8), Marble, 0.4f);
		Box("Hall east wall north", .(14.25f, 4.5f, 15.5f), .(0.5f, 9, 8), Marble, 0.4f);
		Box("Hall east lintel", .(14.25f, 6.75f, 10), .(0.5f, 4.5f, 3), Marble, 0.4f);
		Probe("Hall reflection probe", .(-14, 0, 1), .(14, 9, 19), 512);
		// Strips of light in the ceiling: what the floor mirrors, and what lights the room.
		for (int i < 3)
		{
			let z = 5 + i * 5.0f;
			Glow(scope $"Ceiling strip {i}", .(0, 8.9f, z), .(22, 0.08f, 0.5f), .(1, 0.95f, 0.85f), 5);
			Lamp(scope $"Ceiling lamp {i}", .(-7, 8, z), .(1, 0.94f, 0.84f), 26, 18);
			Lamp(scope $"Ceiling lamp {i} east", .(7, 8, z), .(1, 0.94f, 0.84f), 26, 18);
		}
		// Colour on every wall, so that where a reflection comes from can be read.
		Glow("West band", .(-13.9f, 3, 10), .(0.1f, 0.5f, 16), .(0.15f, 0.4f, 1), 2.5f);
		Glow("North band", .(0, 3, 18.9f), .(26, 0.5f, 0.1f), .(1, 0.28f, 0.18f), 2.5f);
		Box("Red plinth", .(-9, 1.5f, 15), .(2, 3, 2), .(0.72f, 0.09f, 0.08f), 0.45f);
		Box("Blue plinth", .(9, 1.5f, 15), .(2, 3, 2), .(0.08f, 0.2f, 0.7f), 0.45f);
		// Five spheres from a mirror to brushed steel: roughness down the mips of the probe's cube.
		for (int i < 5)
		{
			let x = -8 + i * 4.0f;
			Box(scope $"Sphere stand {i}", .(x, 0.45f, 8), .(1.1f, 0.9f, 1.1f), Marble, 0.3f);
			Ball(scope $"Steel sphere, roughness {i * 0.2f:0.0}", .(x, 1.9f, 8), 1, .(0.92f, 0.92f, 0.94f), Math.Max(i * 0.2f, 0.02f), 1);
		}
		Ball("Gold sphere", .(-9, 3.9f, 15), 0.9f, .(1, 0.76f, 0.34f), 0.15f, 1);
		Ball("Copper sphere", .(9, 3.9f, 15), 0.9f, .(0.95f, 0.55f, 0.4f), 0.28f, 1);
		Ball("Great mirror", .(0, 2.6f, 14.5f), 2.4f, .(0.96f, 0.96f, 0.97f), 0.02f, 1);
		Ball("Glazed ceramic", .(-5, 0.8f, 4), 0.8f, .(0.82f, 0.82f, 0.78f), 0.12f, 0);
		Ball("Red lacquer", .(5, 0.8f, 4), 0.8f, .(0.7f, 0.05f, 0.05f), 0.12f, 0);
	}

	void BuildLightRoom()
	{
		Box("Light room floor", .(21, 0.02f, 10), .(14, 0.04f, 14), .(0.24f, 0.24f, 0.26f), 0.25f, 0, false);
		Box("Light room roof", .(21, 7.25f, 10), .(15, 0.5f, 15), Marble);
		Box("Light room north wall", .(21, 3.5f, 17.25f), .(15, 7, 0.5f), .(0.3f, 0.3f, 0.32f));
		Box("Light room south wall", .(21, 3.5f, 2.75f), .(15, 7, 0.5f), .(0.3f, 0.3f, 0.32f));
		Box("Light room east wall", .(28.25f, 3.5f, 10), .(0.5f, 7, 15), .(0.3f, 0.3f, 0.32f));
		Probe("Light room reflection probe", .(14, 0, 3), .(28, 7, 17), 128);
		Color[3] colors = .(.(1, 0.25f, 0.2f), .(0.2f, 1, 0.45f), .(0.25f, 0.45f, 1));
		for (int i < 3)
		{
			let lamp = Lamp(scope $"Orbiting light {i}", .(21, 2.4f, 10), colors[i], 9, 12, true);
			let bulb = Glow(scope $"Bulb {i}", .Zero, Vector3(0.22f), colors[i], 9);
			let round = bulb.GetComponent<MeshRenderer>();
			round.mesh.Set("builtin:sphere_smooth");
			round.flatShading = false;
			bulb.Transform.SetParent(lamp.Transform, false);
			bulb.Transform.LocalPosition = .Zero;
		}
		let spot = Scene.CreateGameObject("Spot light");
		spot.Transform.Position = .(21, 6.8f, 10);
		spot.Transform.Rotation = Quaternion.Euler(90, 0, 0);
		let cone = spot.AddComponent<Light>();
		cone.type = .Spot;
		cone.spotAngle = 38;
		cone.range = 10;
		cone.intensity = 50;
		Ball("Lit sphere", .(21, 1.3f, 10), 1.3f, .(0.8f, 0.8f, 0.78f), 0.5f, 0);
		for (int i < 8)
		{
			let angle = i * Math.PI_f / 4;
			Box(scope $"Shadow pillar {i}", .(21 + Math.Cos(angle) * 2.8f, 1.2f, 10 + Math.Sin(angle) * 2.8f), .(0.5f, 2.4f, 0.5f), .(0.72f, 0.72f, 0.72f), 0.6f);
		}
		for (int i < 4)
			Glow(scope $"Neon tube {i}", .(16 + i * 3.4f, 5.6f, 16.85f), .(2.4f, 0.1f, 0.1f), (i % 2 == 0) ? Color(1, 0.2f, 0.65f) : Color(0.2f, 0.85f, 1), 7);
	}

	void BuildYard()
	{
		for (int row < 6)
			for (int i < 6 - row)
				MakeCrate(.(30 + (i - (5 - row) * 0.5f) * 1.04f, 0.5f + row * 1.01f, -24));
		for (int i < 14)
		{
			let o = Box(scope $"Domino {i}", .(20 + i * 0.95f, 0.8f, -12), .(0.22f, 1.6f, 0.8f), .(0.85f, 0.82f, 0.74f), 0.5f);
			o.AddComponent<Rigidbody>().mass = 6;
		}
		Box("Rope gantry post", .(38, 3.5f, -18), .(0.3f, 7, 0.3f), Timber);
		Box("Rope gantry post 2", .(38, 3.5f, -6), .(0.3f, 7, 0.3f), Timber);
		Box("Rope gantry beam", .(38, 7.1f, -12), .(0.3f, 0.3f, 12.3f), Timber);
		let weight = Ball("Wrecking ball", .(38, 1.8f, -12), 0.8f, .(0.22f, 0.22f, 0.24f), 0.4f, 1);
		weight.AddComponent<Rigidbody>().mass = 120;
		let anchor = Scene.CreateGameObject("Wrecking ball rope");
		anchor.Transform.Position = .(38, 6.9f, -12);
		let rope = anchor.AddComponent<Rope>();
		rope.length = 4.3f;
		rope.segments = 28;
		rope.thickness = 0.06f;
		rope.endAttachedTo = weight.Transform;
		rope.endOffset = .(0, 0.5f, 0);
	}

	float Scatter()
	{
		mSeed = mSeed * 1664525U + 1013904223U;
		return (float)((mSeed >> 16) & 0xFFFF) / 65535;
	}

	void MakeCrate(Vector3 at)
	{
		let o = Box("Crate", at, Vector3(1), Timber, 0.75f);
		o.AddComponent<Rigidbody>().mass = 18;
	}

	void BuildGarden()
	{
		// The rim stands on the ground and holds the water in.
		for (int i < 4)
		{
			let wide = i < 2;
			Box(scope $"Pool rim {i}", .(wide ? -26 : (i == 2 ? -37.4f : -14.6f), 0.3f, wide ? (i == 0 ? -29.4f : -14.6f) : -22), wide ? Vector3(23.4f, 0.6f, 0.8f) : Vector3(0.8f, 0.6f, 15.6f), Stone, 0.7f);
		}
		let surface = Scene.CreateGameObject("Pool water");
		surface.Transform.Position = .(-26, 0.42f, -22);
		let water = surface.AddComponent<Water>();
		water.size = .(22, 14);
		water.depth = 0.42f;
		water.waveHeight = 0.05f;
		water.waveLength = 3;
		water.clarity = 2;
		for (int i < 5)
		{
			let at = Vector3(-41 + i * 6.5f, 0, -2 - (i % 2) * 2.5f);
			Box(scope $"Tree trunk {i}", at + .(0, 1.4f, 0), .(0.42f, 2.8f, 0.42f), Timber, 0.9f);
			for (int layer < 3)
			{
				let leaves = Box(scope $"Tree leaves {i}.{layer}", at + .(0, 3 + layer * 1.25f, 0), Vector3(3.6f - layer * 0.95f, 2.3f, 3.6f - layer * 0.95f), Leaf, 0.9f, 0, false);
				leaves.GetComponent<MeshRenderer>().mesh.Set("builtin:cone");
			}
		}
		// A fixed sequence, so that the scene comes out the same each time it is built.
		mSeed = 7;
		for (int i < 260)
		{
			let at = Vector3(-44 + Scatter() * 34, 0, -36 + Scatter() * 36);
			if (at.x > -38.5f && at.x < -13.5f && at.z > -30.5f && at.z < -13.5f)
				continue;
			let plant = Scene.CreateGameObject((i % 9 == 0) ? "Bush" : "Grass");
			plant.Transform.Position = at;
			plant.Transform.Rotation = Quaternion.Euler(0, Scatter() * 360, 0);
			plant.Transform.LocalScale = Vector3((i % 9 == 0) ? 1.1f : 1 + Scatter());
			let leaf = plant.AddComponent<MeshRenderer>();
			leaf.mesh.Set((i % 9 == 0) ? "builtin:bush" : "builtin:grass");
			leaf.color = .(0.3f + Scatter() * 0.15f, 0.55f, 0.24f);
			leaf.windSway = 1;
			leaf.emissive = leaf.color;
			leaf.emissiveIntensity = 0.3f;
			leaf.backFaceCulling = false;
		}
		let figure = Prefab.Instantiate(Scene, "Prefabs/character.tprefab");
		if (figure != null)
		{
			figure.Name.Set("Walking figure");
			figure.Transform.Position = .(-30, 0, -8);
			figure.GetComponentInChildren<Animator>().defaultClip.Set("Walk");
			figure.GetComponentInChildren<Animator>().controller.Clear();
		}
	}

	void BuildCourtyard()
	{
		Box("Flag pole", .(-3, 4, -14), .(0.16f, 8, 0.16f), .(0.75f, 0.75f, 0.78f), 0.3f, 1);
		let flag = Scene.CreateGameObject("Flag");
		flag.Transform.Position = .(-3, 6.5f, -14);
		flag.Transform.Rotation = Quaternion.Euler(0, 90, 0);
		let cloth = flag.AddComponent<MeshRenderer>();
		cloth.mesh.Set("Models/cloth16.glb");
		cloth.color = .(0.85f, 0.2f, 0.12f);
		cloth.backFaceCulling = false;
		cloth.emissive = cloth.color;
		cloth.emissiveIntensity = 0.35f;
		let soft = flag.AddComponent<SoftBody>();
		soft.pins.Set("272-288");
		let wind = Scene.CreateGameObject("Wind");
		wind.Transform.Rotation = Quaternion.Euler(0, 80, 0);
		wind.AddComponent<WindZone>().strength = 2.5f;
		for (int i < 2)
		{
			let x = i == 0 ? -3.2f : 3.2f;
			Box(scope $"Brazier {i}", .(x, 0.6f, -1.2f), .(1, 1.2f, 1), .(0.2f, 0.2f, 0.22f), 0.5f, 1);
			let flame = Scene.CreateGameObject(scope $"Brazier flame {i}");
			flame.Transform.Position = .(x, 1.3f, -1.2f);
			flame.Transform.Rotation = Quaternion.Euler(-90, 0, 0);
			let fire = flame.AddComponent<ParticleSystem>();
			fire.rate = 90;
			fire.lifetime = 0.9f;
			fire.speed = 1.8f;
			fire.spreadAngle = 12;
			fire.emitRadius = 0.28f;
			fire.gravity = .(0, 1.6f, 0);
			fire.startSize = 0.3f;
			Lamp(scope $"Brazier light {i}", .(x, 2, -1.2f), .(1, 0.55f, 0.2f), 9, 10);
		}
		let seal = Scene.CreateGameObject("Paving seal");
		seal.Transform.Position = .(4, 0.05f, -16);
		seal.Transform.Rotation = Quaternion.Euler(90, 0, 0);
		let mark = seal.AddComponent<Decal>();
		mark.texture.Set("Textures/ring.png");
		mark.size = .(8, 8, 1);
		mark.color = .(0.16f, 0.14f, 0.13f);
	}
}
