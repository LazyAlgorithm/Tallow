using System;
using System.Collections;
using System.IO;
using Tallow;

namespace {NAMESPACE};

class Exhibit
{
	public String title = new .() ~ delete _, detail = new .() ~ delete _, action = new .() ~ delete _;
	public Vector3 at;
	public Color color;
	public int index;
	public this(int i, StringView name, StringView description, StringView hint, Vector3 position, Color tint)
	{
		index = i;
		title.Set(name);
		detail.Set(description);
		action.Set(hint);
		at = position;
		color = tint;
	}
}
[Component]
class Exhibition : NetworkBehaviour
{
	public static Exhibition Active;
	[NonSerialized] public List<Exhibit> exhibits = new .() ~ DeleteContainerAndItems!(_);
	public Camera camera;
	public GameObject visitor;
	[NonSerialized] public bool Directory, Overview;
	[Sync] public bool Night;
	public bool Effects = true;
	public bool authoredScene;
	[Saved] public uint32 Visited;
	[Sync, Saved] public int32 savedVisits;
	public String status = new .("Welcome. Walk freely, or press M to open the exhibition directory.") ~ delete _;
	public float statusUntil = 12;
	public int nearest = -1;
	public float nearestDistance;
	public Water ocean, pool;
	public WindZone wind;
	public DialogueRunner talk;
	public SequencePlayer sequence;
	public SharedTerminal terminal;
	public NavigationSurface nav, flight;
	public bool NavReady, FlightReady;
	public int TileUpdates;
	public GameObject obstacle;
	[Sync] public bool GateClosed = true;
	[NonSerialized] public List<NavigationAgent> walkers = new .() ~ delete _, drones = new .() ~ delete _;
	[NonSerialized] public List<SoftBody> softs = new .() ~ delete _;
	[NonSerialized] public List<Rope> ropes = new .() ~ delete _;
	[NonSerialized] public List<VoxelObject> voxels = new .() ~ delete _;
	[NonSerialized] public List<ParticleSystem> emitters = new .() ~ delete _;
	[NonSerialized] public List<SkinnedMeshRenderer> skins = new .() ~ delete _;
	public Animator puppet;
	[NonSerialized] public List<MeshRenderer> samples = new .() ~ delete _;
	[NonSerialized] public List<Light> lamps = new .() ~ delete _;
	[NonSerialized] public List<(Rigidbody body, Vector3 home, int sector)> props = new .() ~ delete _;
	List<Mesh> meshes = new .() ~ DeleteContainerAndItems!(_);
	public VoxelTerrain terrain;
	public LimbIK limb;
	public ReflectionProbe probe;
	public UIDocument document;
	public BehaviorTreeRunner behavior;
	public MeshRenderer shaderSample;
	public GameObject ikTarget;
	Vector3 ikHome;
	SaveHandle saveHandle;
	bool pendingSave;
	bool terrainReady;
	int terrainStrokes;
	public Light sun;
	public AudioSource speaker;
	public Decal decal;
	public Rigidbody pendulum;
	public GameObject lift;
	Vector3 liftHome;
	int frames;
	float routeTimer;
	bool reverse, lowWater;
	float saveValue;
	float sampleAge;
	static Color Ink => .(0.055f, 0.085f, 0.13f);
	static Color Chalk => .(0.77f, 0.83f, 0.87f);
	static Color Cyan => .(0.1f, 0.8f, 0.95f);
	public bool IsAuthority => Scene.Network == null || Scene.Network.Mode == .Offline || Scene.Network.IsServer;
	public void BuildForEditing()
	{
		Active = this;
		GameObject.AddComponent<ExhibitionHUD>();
		let env = Scene.Environment;
		env.skyZenith = .(0.08f, 0.22f, 0.44f);
		env.skyHorizon = .(0.68f, 0.8f, 0.9f);
		env.ambientIntensity = 0.65f;
		env.fogDensity = 0.0015f;
		env.bloom = 0.22f;
		env.shadowDistance = 130;
		let c = Scene.CreateGameObject("Visitor camera");
		camera = c.AddComponent<Camera>();
		camera.fieldOfView = 74;
		camera.farClip = 10000;
		camera.nearClip = 0.08f;
		c.Transform.Position = .(0, 1.67f, -31);
		c.AddComponent<AudioListener>();
		let light = Scene.CreateGameObject("Sun");
		light.Transform.Rotation = Quaternion.Euler(48, -35, 0);
		sun = light.AddComponent<Light>();
		sun.intensity = 1.8f;
		wind = Scene.CreateGameObject("Sea breeze").AddComponent<WindZone>();
		wind.strength = 1.1f;
		wind.gusts = 0.45f;
		Architecture();
		Catalogue();
		BuildExhibits();
		authoredScene = true;
		Log.Info(scope $"SHOWCASE_READY exhibits={exhibits.Count} objects={Scene.Objects.Count}");
	}

	GameObject Box(StringView name, Vector3 at, Vector3 size, Color color, bool solid = true)
	{
		var o = Scene.CreateGameObject(name);
		o.Transform.Position = at;
		o.Transform.LocalScale = size;
		let r = o.AddComponent<MeshRenderer>();
		r.color = color;
		r.roughness = 0.65f;
		if (solid)
			o.AddComponent<BoxCollider>();
		return o;
	}

	GameObject Orb(StringView name, Vector3 at, float radius, Color color)
	{
		var o = Box(name, at, Vector3(radius * 2), color, false);
		let r = o.GetComponent<MeshRenderer>();
		r.mesh.Set("builtin:sphere");
		r.flatShading = false;
		return o;
	}

	Rigidbody Prop(StringView name, Vector3 at, Vector3 size, Color color, int sector, float mass = 10)
	{
		var o = Box(name, at, size, color);
		let b = o.AddComponent<Rigidbody>();
		b.mass = mass;
		props.Add((b, at, sector));
		return b;
	}

	void Glow(GameObject o, Color color, float intensity = 2)
	{
		let r = o.GetComponent<MeshRenderer>();
		r.emissive = color;
		r.emissiveIntensity = intensity;
	}

	void Architecture()
	{
		for (int z < 8)
		{
			for (int x < 8)
			{
				if (x >= 6 && (z == 4 || z == 5)) continue;
				let at = Vector3(-42 + x * 12, -0.35f, -30 + z * 12);
				Box("Plaza tile", at, .(11.94f, 0.7f, 11.94f), ((x + z) % 2) == 0 ? .(0.32f, 0.39f, 0.44f) : .(0.35f, 0.42f, 0.47f));
			}
		}
		Box("Pool bottom", .(36, -4.4f, 24), .(24, 0.8f, 24), .(0.13f, 0.28f, 0.32f));
		Box("Water bridge", .(36, -0.12f, 24), .(24, 0.24f, 2), Chalk);
		for (int row < 2)
		{
			for (int i < 4)
			{
				let x = -33 + i * 22;
				let zz = 70 + row * 22;
				Box("Pier gallery", .(x, -0.35f, zz), .(20, 0.7f, 17), .(0.29f, 0.36f, 0.4f));
				Box("Pier connection", .(x, -0.35f, zz - 11), .(3, 0.7f, 10), Chalk);
				for (int side < 2)
					Box("Pier pile", .(x + (side == 0 ? -8 : 8), -4, zz), .(0.45f, 8, 0.45f), Ink);
			}
		}
		Box("Central ocean promenade", .(0, -0.35f, 80), .(4, 0.7f, 44), Chalk);
		for (int row < 2)
			Box("Pier crosswalk", .(0, -0.35f, 62 + row * 22), .(94, 0.7f, 2), Chalk);
		for (int i < 7)
			Box("Ocean exit step", .(-48 - i * 0.6f, -0.2f - i * 0.35f, 0), .(1.2f, 0.3f, 3), Chalk);
		for (int i < 34)
		{
			let z = -34 + i * 4;
			Glow(Box("Central guide strip", .(0, 0.018f, z), .(0.14f, 0.025f, 1.9f), Cyan, false), Cyan, 1.2f);
		}
		for (int x = -1; x <= 1; x += 2)
		{
			Box("Atrium upright", .(x * 3.8f, 4.5f, 8), .(0.6f, 9, 0.6f), Chalk);
			Glow(Box("Atrium light", .(x * 3.44f, 4.5f, 8), .(0.1f, 8.4f, 0.66f), Cyan, false), Cyan);
		}
		Box("Atrium lintel", .(0, 8.8f, 8), .(8.2f, 0.6f, 0.6f), Chalk);
		for (int i < 14)
		{
			let t = i * Math.PI_f * 2 / 14;
			var o = Orb("Kinetic sculpture", .(Math.Cos(t) * 2.2f, 5 + Math.Sin(t * 2) * 0.7f, 8 + Math.Sin(t) * 2.2f), 0.19f, Cyan);
			Glow(o, Cyan, 2);
			o.AddComponent<DisplayMotion>().spin = .(0, 30, 0);
		}
		// Walkable rails leave both pool entrances and the ocean edge open for swimming.
		Box("West curb", .(-48, 0.15f, 12), .(0.4f, 0.3f, 96), Chalk);
		Box("Arrival curb", .(0, 0.15f, -36), .(96, 0.3f, 0.4f), Chalk);
	}

	void Add(StringView name, StringView detail, StringView action)
	{
		let i = exhibits.Count;
		let row = i / 4;
		let col = i % 4;
		let at = Vector3(-33 + col * 22, 0, -24 + row * 22 + (row >= 4 ? 6 : 0));
		Color[6] colors = .(.(0.1f, 0.8f, 0.95f), .(1, 0.6f, 0.22f), .(0.6f, 0.5f, 1), .(0.25f, 0.85f, 0.55f), .(1, 0.4f, 0.55f), .(0.4f, 0.7f, 1));
		let e = new Exhibit(i, name, detail, action, at, colors[row]);
		exhibits.Add(e);
		if (i != 11)
			Box("Exhibit plinth", at + Vector3(0, 0.08f, 0), .(17, 0.16f, 15), .(0.23f, 0.29f, 0.34f));
		Box("Information pylon", at + Vector3(-7.4f, 1.35f, -6.1f), .(0.5f, 2.7f, 0.5f), Ink);
		Glow(Box("Exhibit beacon", at + Vector3(-7.4f, 2.85f, -6.1f), .(0.62f, 0.25f, 0.62f), e.color, false), e.color);
		Box("Category stripe", at + Vector3(0, 0.2f, -7.1f), .(16, 0.04f, 0.14f), e.color, false);
	}

	void Catalogue()
	{
		Add("Character playground", "Capsule/box controller, steps, slopes, pushing, sprinting, jumping and swimming.", "Switch collision shape");
		Add("Material laboratory", "Metallic/roughness samples, transparency, emissive glow and GPU instancing.", "Change material finish");
		Add("Light pavilion", "Directional, point and spot lights, shadows, environment and day/night comparison.", "Toggle day / night");
		Add("Decal print shop", "Projected alpha decals, overlapping layers and surface projection.", "Stamp a new decal");
		Add("Rigid-body yard", "Jolt dynamics, contacts, stacking, impulses and character interaction.", "Push the stack");
		Add("Mechanisms", "A jointed pendulum and a kinematic moving platform you can ride.", "Swing the pendulum");
		Add("Deformation studio", "Pinned cloth, pressure jelly and a dentable shell. Walk into the soft objects.", "Drop a heavy impactor");
		Add("Rope workshop", "Loaded rope rigs: a hanging crate, a two-rope suspended platform and a swinging cargo box.", "Push the suspended load");
		Add("Walking navigation", "Polygon navmesh paths, crowd avoidance and local tiled rebuilds around a movable gate.", "Move gate / rebuild tiles");
		Add("Flight navigation", "Separate volumetric grid navigation for flying agents routing in three dimensions.", "Send drones to other side");
		Add("Destruction quarry", "Real voxel object carving, interior surfaces, detached fragments and terrain sculpting.", "Excavate target");
		Add("Water basin", "Finite water, waves, rigid/soft buoyancy and swimming. Endless sea surrounds the campus.", "Switch realistic / low-poly");
		Add("Wind garden", "Instanced grass, trees and bushes; the same wind affects plants, cloth and ropes.", "Change wind strength");
		Add("Animation gallery", "Transform Animator state machine and rigged-model GPU skinning side by side.", "Change animation / skinning");
		Add("Particle foundry", "Instanced mesh particles, trails, bursts, gravity, colour and lifetime changes.", "Trigger particle burst");
		Add("Spatial sound room", "Walk around the speaker; attenuation, stereo position, occlusion and a reverb zone.", "Play spatial audio");
		Add("Dialogue kiosk", "Branching dialogue, variables, subtitles and interactive choices.", "Talk to the guide");
		Add("Sequence theatre", "An actual timeline moves the sculpture and displays timed subtitles.", "Play timeline");
		Add("Multiplayer observatory", "Run host/join launchers for a shared tour. Synced console, moving bodies and network counters.", "Toggle shared console");
		Add("Interface / persistence", "This directory, live profiler summary, quality controls and a persistent visit counter.", "Save visit / load record");
		Add("Terrain laboratory", "Editable voxel terrain tiles, density brushes, collision updates and terrain materials.", "Sculpt terrain tile");
		Add("Inverse kinematics", "A real two-bone IK arm follows the moving target; weight blends the solver on and off.", "Blend inverse kinematics");
		Add("Rendering observatory", "Reflection probe capture, roughness mipmaps, LOD switching and ambient occlusion.", "Cycle level of detail");
		Add("Shader / developer studio", "A live surface shader pulses and displaces its mesh. The source project opens in the editor.", "Change shader speed");
	}

	void BuildExhibits()
	{
		var a = exhibits[0].at;
		for (int i < 6)
			Box("Walkable stair", a + Vector3(-4 + i * 1.25f, 0.12f + i * 0.15f, 0), .(1.25f, 0.24f + i * 0.3f, 3), Chalk);
		let ramp = Box("Walkable slope", a + Vector3(3, 0.65f, 1), .(3, 0.25f, 5), Cyan);
		ramp.Transform.Rotation = Quaternion.Euler(-18, 0, 0);
		a = exhibits[1].at;
		for (int i < 6)
		{
			var o = Orb("Material sphere", a + Vector3(-5 + i * 2, 1.25f, 0), 0.85f, .(0.87f, 0.54f, 0.2f));
			let r = o.GetComponent<MeshRenderer>();
			r.metallic = i / 5f;
			r.roughness = 0.08f + i / 7f;
			samples.Add(r);
			Box("Sample pedestal", a + Vector3(-5 + i * 2, 0.25f, 0), .(1.5f, 0.5f, 1.5f), Ink);
		}
		let glass = Orb("Transparent glass", a + Vector3(-3, 1.3f, 4), 1, .(0.15f, 0.8f, 0.9f, 0.32f));
		glass.GetComponent<MeshRenderer>().roughness = 0.08f;
		Glow(Orb("Emissive pearl", a + Vector3(3, 1.4f, 4), 0.9f, Cyan), Cyan, 3);
		a = exhibits[2].at;
		Box("Lamp pavilion roof", a + Vector3(0, 5, 1), .(14, 0.4f, 10), Ink);
		for (int i < 3)
		{
			Box("Lamp column", a + Vector3(-5 + i * 5, 2.5f, 4), .(0.35f, 5, 0.35f), Chalk);
			var o = Orb("Lamp", a + Vector3(-4 + i * 4, 3.8f, 1), 0.25f, i == 0 ? .Red : i == 1 ? .Green : .Blue);
			let l = o.AddComponent<Light>();
			l.type = i == 2 ? .Spot : .Point;
			l.color = i == 0 ? .(1, 0.2f, 0.12f) : i == 1 ? .(0.1f, 1, 0.6f) : .(0.25f, 0.4f, 1);
			l.intensity = 8;
			l.range = 10;
			l.castShadows = true;
			if (i == 2)
				o.Transform.Rotation = Quaternion.Euler(90, 0, 0);
			lamps.Add(l);
			Glow(o, l.color);
		}
		a = exhibits[3].at;
		Box("Print wall", a + Vector3(0, 2.1f, 3), .(12, 4.2f, 0.4f), Chalk);
		let d = Scene.CreateGameObject("Projected ring");
		d.Transform.Position = a + Vector3(0, 2, 2.72f);
		decal = d.AddComponent<Decal>();
		decal.texture.Set("Textures/ring.png");
		decal.size = .(3, 3, 1);
		decal.color = Cyan;
		a = exhibits[4].at;
		for (int y < 4)
		{
			for (int x < 4 - y)
				Prop("Stack crate", a + Vector3(-3 + x * 1.05f + y * 0.5f, 0.7f + y * 1.01f, 1), .(0.95f, 0.95f, 0.95f), .(0.95f, 0.57f, 0.22f), 4);
		}
		a = exhibits[5].at;
		let anchor = Prop("Joint anchor", a + Vector3(-3, 5, 0), .(0.4f, 0.4f, 0.4f), Ink, 5);
		anchor.isKinematic = true;
		anchor.useGravity = false;
		pendulum = Prop("Pendulum bob", a + Vector3(-3, 2, 0), .(1, 1, 1), Cyan, 5, 15);
		let j = pendulum.GameObject.AddComponent<Joint>();
		j.connectedTo = anchor;
		j.anchor = .(0, 3, 0);
		let rod = Box("Pendulum arm", .Zero, .(0.08f, 3, 0.08f), Chalk, false);
		rod.Transform.SetParent(pendulum.Transform, false);
		rod.Transform.LocalPosition = .(0, 1.5f, 0);
		Box("Pendulum support", a + Vector3(-3, 5.5f, 0), .(5, 0.3f, 0.5f), Chalk);
		for (int side = -1; side <= 1; side += 2)
			Box("Pendulum post", a + Vector3(-3 + side * 2.4f, 2.7f, 0), .(0.2f, 5.4f, 0.5f), Chalk);
		let platform = Prop("Moving platform", a + Vector3(4, 0.8f, 0), .(3, 0.3f, 3), .(1, 0.65f, 0.2f), 5);
		platform.isKinematic = true;
		platform.useGravity = false;
		lift = platform.GameObject;
		liftHome = lift.Transform.Position;
		BuildSoft();
		BuildRopes();
		BuildNavigation();
		BuildDestruction();
		BuildWater();
		BuildGarden();
		BuildAnimation();
		BuildSoundAndStory();
		BuildAdvanced();
	}

	void BuildSoft()
	{
		var a = exhibits[6].at;
		let sheet = DemoMeshes.Sheet(16, 3);
		meshes.Add(sheet);
		let cloth = Scene.CreateGameObject("Pinned cloth");
		cloth.Transform.Position = a + Vector3(-4, 3.5f, 0);
		cloth.AddComponent<MeshRenderer>().RuntimeMesh = sheet;
		cloth.GetComponent<MeshRenderer>().color = .(1, 0.35f, 0.2f);
		cloth.GetComponent<MeshRenderer>().backFaceCulling = false;
		var s = cloth.AddComponent<SoftBody>();
		s.kind = .Cloth;
		s.pins.Set("272-288");
		softs.Add(s);
		Box("Cloth rail", a + Vector3(-4, 3.6f, 1.5f), .(3.7f, 0.18f, 0.18f), Ink);
		for (int side = -1; side <= 1; side += 2)
			Box("Cloth post", a + Vector3(-4 + side * 1.75f, 1.8f, 1.5f), .(0.15f, 3.6f, 0.15f), Chalk);
		let shape = DemoMeshes.Box(.(0.75f, 0.75f, 0.75f), 4);
		meshes.Add(shape);
		let jelly = Scene.CreateGameObject("Jelly cushion");
		jelly.Transform.Position = a + Vector3(0, 1.1f, 0);
		jelly.AddComponent<MeshRenderer>().RuntimeMesh = shape;
		jelly.GetComponent<MeshRenderer>().color = .(0.25f, 0.85f, 0.55f);
		s = jelly.AddComponent<SoftBody>();
		s.kind = .Jelly;
		softs.Add(s);
		let shell = Scene.CreateGameObject("Dentable shell");
		shell.Transform.Position = a + Vector3(4, 1, 0);
		shell.AddComponent<MeshRenderer>().RuntimeMesh = shape;
		shell.GetComponent<MeshRenderer>().color = .(0.3f, 0.5f, 0.9f);
		shell.AddComponent<ConvexCollider>();
		let b = shell.AddComponent<Rigidbody>();
		b.mass = 50;
		props.Add((b, shell.Transform.Position, 6));
		s = shell.AddComponent<SoftBody>();
		s.kind = .Shell;
		s.dentSpeed = 2;
		softs.Add(s);
	}

	void BuildRopes()
	{
		var a = exhibits[7].at;
		for (int i < 3)
		{
			Box("Rope beam", a + Vector3(-5 + i * 5, 5, 0), .(3.2f, 0.2f, 0.2f), Chalk);
			Box("Rope post", a + Vector3(-6.5f + i * 5, 2.5f, 0), .(0.2f, 5, 0.2f), Ink);
			var o = Scene.CreateGameObject("Rope demonstration");
			o.Transform.Position = a + Vector3(-5 + i * 5, 4.9f, 0);
			let r = o.AddComponent<Rope>();
			r.length = 3.3f;
			r.segments = 32;
			r.thickness = 0.055f;
			ropes.Add(r);
			if (i == 0)
			{
				let load = Prop("Hanging rope crate", a + Vector3(-5, 1.35f, 0), .(0.85f, 0.85f, 0.85f), .(0.9f, 0.3f, 0.2f), 7, 12);
				r.endAttachedTo = load.Transform;
			}
			if (i == 1)
			{
				let load = Prop("Rope suspended platform", a + Vector3(1, 1.35f, 0), .(3, 0.35f, 1.6f), Cyan, 7, 20);
				r.endAttachedTo = load.Transform;
				r.endOffset = .(-0.33333334f, 0.5f, 0);
				let end = Scene.CreateGameObject("Platform second rope anchor");
				end.Transform.Position = a + Vector3(2, 4.9f, 0);
				let second = end.AddComponent<Rope>();
				second.length = 3.3f;
				second.segments = 32;
				second.thickness = 0.055f;
				second.endAttachedTo = load.Transform;
				second.endOffset = .(0.33333334f, 0.5f, 0);
				ropes.Add(second);
				Box("Platform far post", a + Vector3(3, 2.5f, 0), .(0.2f, 5, 0.2f), Ink);
			}
			if (i == 2)
			{
				let load = Prop("Rope load", a + Vector3(5, 1.35f, 0), .(0.8f, 0.8f, 0.8f), .(1, 0.65f, 0.2f), 7, 12);
				r.endAttachedTo = load.Transform;
			}
		}
	}

	void BuildNavigation()
	{
		var a = exhibits[8].at;
		var n = Scene.CreateGameObject("Tiled walking NavMesh");
		n.Transform.Position = a + Vector3(-9, -0.5f, -7);
		nav = n.AddComponent<NavigationSurface>();
		nav.size = .(18, 5, 14);
		nav.cellSize = 0.4f;
		nav.agentRadius = 0.35f;
		nav.includeRenderMeshes = false;
		for (int i < 3)
			Box("Nav maze wall", a + Vector3(-3 + i * 3, 1, ((i % 2) * 2 - 1) * 2.5f), .(0.5f, 2, 5), Chalk);
		obstacle = Box("Rebuildable gate", a + Vector3(1, 0.8f, 0), .(3.5f, 1.6f, 0.6f), .(0.6f, 0.5f, 1));
		for (int i < 5)
		{
			var o = Scene.CreateGameObject("NavMesh walker");
			o.Transform.Position = a + Vector3(-6 + i * 0.8f, 1, -4);
			let m = o.AddComponent<MeshRenderer>();
			m.mesh.Set("builtin:capsule");
			m.color = .(0.65f, 0.5f, 1);
			o.Transform.LocalScale = .(0.65f, 0.8f, 0.65f);
			let c = o.AddComponent<CharacterController>();
			c.radius = 0.28f;
			c.height = 1.5f;
			let agent = o.AddComponent<NavigationAgent>();
			agent.surface = nav;
			agent.baseOffset = .(0, -0.8f, 0);
			agent.radius = 0.32f;
			walkers.Add(agent);
			if (i == 4)
			{
				behavior = o.AddComponent<BehaviorTreeRunner>();
				behavior.tree.Set("AI/patrol.tbt");
				behavior.tickInterval = 0.1f;
				behavior.Enabled = false;
			}
		}
		let route = Scene.CreateGameObject("Patrol route");
		for (int i < 4)
		{
			var point = Scene.CreateGameObject("Patrol point");
			point.Transform.SetParent(route.Transform, false);
			point.Transform.Position = a + Vector3((i < 2 ? -6 : 6), 0.15f, ((i % 2) == 0 ? -4 : 4));
		}
		a = exhibits[9].at;
		n = Scene.CreateGameObject("Volumetric flight grid");
		n.Transform.Position = a + Vector3(-8, 1, -6);
		flight = n.AddComponent<NavigationSurface>();
		flight.flying = true;
		flight.backend = .Grid;
		flight.size = .(16, 7, 12);
		flight.cellSize = 0.75f;
		flight.agentRadius = 0.3f;
		flight.includeRenderMeshes = false;
		for (int i < 3)
			Box("Flight obstacle", a + Vector3(-3 + i * 3, 3.5f, 0), .(0.5f, 5, 2), Chalk);
		for (int i < 4)
		{
			var o = Orb("Flight drone", a + Vector3(-6, 2 + i * 1.2f, -3 + i * 2), 0.35f, Cyan);
			Glow(o, Cyan, 1.2f);
			let agent = o.AddComponent<NavigationAgent>();
			agent.surface = flight;
			agent.radius = 0.35f;
			drones.Add(agent);
		}
	}

	void BuildDestruction()
	{
		var a = exhibits[10].at;
		for (int i < 3)
		{
			var o = Scene.CreateGameObject("Carvable specimen");
			o.Transform.Position = a + Vector3(-4 + i * 4, 1.9f, 1);
			o.AddComponent<MeshRenderer>();
			o.AddComponent<MeshCollider>();
			let v = o.AddComponent<VoxelObject>();
			v.shape = i == 0 ? .Box : i == 1 ? .Sphere : .Cylinder;
			v.size = 3;
			v.resolution = 24;
			v.anchored = true;
			v.color = i == 0 ? .(0.7f, 0.6f, 0.45f) : i == 1 ? .(0.4f, 0.58f, 0.72f) : .(0.72f, 0.4f, 0.32f);
			v.interiorColor = .(0.27f, 0.2f, 0.16f);
			v.OnValidate();
			voxels.Add(v);
		}
	}

	void BuildWater()
	{
		ocean = Scene.CreateGameObject("Endless sea").AddComponent<Water>();
		ocean.Transform.Position = .(0, -0.9f, 0);
		ocean.endless = true;
		ocean.depth = 80;
		ocean.waveHeight = 0.35f;
		ocean.gridSpacing = 0.8f;
		pool = Scene.CreateGameObject("Finite buoyancy pool").AddComponent<Water>();
		pool.Transform.Position = .(36, -0.45f, 24);
		pool.size = .(24, 24);
		pool.depth = 4;
		pool.waveHeight = 0.18f;
		pool.flow = .(0.15f, 0);
		pool.gridSpacing = 0.5f;
		for (int i < 6)
			Prop("Floating crate", .(28 + (i % 3) * 5, -0.45f, 17 + (i / 3) * 14), .(1, 1, 1), (i % 2) == 0 ? Cyan : .(1, 0.65f, 0.2f), 11, 40);
		let sheet = DemoMeshes.Sheet(8, 2);
		meshes.Add(sheet);
		var o = Scene.CreateGameObject("Floating cloth");
		o.Transform.Position = .(39, -0.35f, 18);
		o.AddComponent<MeshRenderer>().RuntimeMesh = sheet;
		o.GetComponent<MeshRenderer>().color = .(1, 0.4f, 0.25f);
		var s = o.AddComponent<SoftBody>();
		s.kind = .Cloth;
		softs.Add(s);
		o = Scene.CreateGameObject("Floating rope");
		o.Transform.Position = .(40, -0.3f, 31);
		let rope = o.AddComponent<Rope>();
		rope.holdStart = false;
		rope.length = 4;
		rope.segments = 24;
		ropes.Add(rope);
		// Stepping stones make it easy to leave the pool without teleporting.
		for (int i < 8)
			Box("Pool exit step", .(26 + i * 0.6f, -3.5f + i * 0.46f, 13), .(1.25f, 0.4f, 2), Chalk);
	}

	void BuildGarden()
	{
		var a = exhibits[12].at;
		Box("Garden bed", a + Vector3(0, 0.25f, 1), .(15, 0.5f, 10), .(0.23f, 0.35f, 0.23f));
		var o = Scene.CreateGameObject("Instanced planting");
		let grass = o.AddComponent<Foliage>();
		grass.color = .(0.55f, 0.85f, 0.4f);
		grass.viewDistance = 85;
		for (int z < 20)
		{
			for (int x < 28)
				grass.Add(a + Vector3(-6.7f + x * 0.5f, 0.52f, -3.5f + z * 0.48f), (x * 41 + z * 79) % 360, 0.7f + ((x + z) % 4) * 0.15f);
		}
		let trees = Scene.CreateGameObject("Instanced trees").AddComponent<Foliage>();
		trees.mesh.Set("builtin:tree");
		trees.castShadows = true;
		trees.sway = 0.3f;
		for (int i < 5)
			trees.Add(a + Vector3(-6 + i * 3, 0.5f, 4), i * 47, 1.4f);
	}

	void BuildAnimation()
	{
		var a = exhibits[13].at;
		let model = Prefab.Instantiate(Scene, "Prefabs/character.tprefab");
		if (model != null)
		{
			model.Transform.Position = a + Vector3(-4, 0.3f, 0);
			puppet = model.GetComponent<Animator>();
			puppet.controller.Set("Animations/character.tcontroller");
		}
		for (int i < 3)
		{
			var o = Scene.CreateGameObject("GPU skinned performer");
			o.Transform.Position = a + Vector3(i * 2.5f, 0.3f, 0);
			var s = o.AddComponent<SkinnedMeshRenderer>();
			s.model.Set("Models/Person_Rigged.glb");
			s.speed = 0.65f + i * 0.45f;
			s.gpuSkinning = true;
			s.exposeBones = true;
			s.OnValidate();
			let anim = o.AddComponent<Animator>();
			anim.clips.Set("Animations/skin_wave.tanim");
			anim.defaultClip.Set("ShowcaseWave");
			anim.speed = s.speed;
			skins.Add(s);
		}
		a = exhibits[14].at;
		for (int i < 3)
		{
			var o = Scene.CreateGameObject("Particle emitter");
			o.Transform.Position = a + Vector3(-4 + i * 4, 0.5f, 0);
			let p = o.AddComponent<ParticleSystem>();
			p.rate = 28;
			p.maxParticles = 200;
			p.lifetime = 2.5f;
			p.startSize = 0.13f;
			p.speed = 4 + i;
			p.startColor = i == 0 ? .(1, 0.6f, 0.15f) : i == 1 ? Cyan : .(0.8f, 0.3f, 1);
			p.endColor = p.startColor;
			p.endColor.a = 0;
			p.gravity = i == 1 ? .(0, 0.5f, 0) : .(0, -3, 0);
			emitters.Add(p);
			Glow(Orb("Emitter socket", o.Transform.Position, 0.3f, p.startColor), p.startColor);
		}
	}

	void BuildSoundAndStory()
	{
		var a = exhibits[15].at;
		Box("Acoustic wall", a + Vector3(0, 2, 1.5f), .(10, 4, 0.4f), Ink);
		var o = Box("Spatial speaker", a + Vector3(-3, 1.3f, 0), .(1, 2.6f, 1), Chalk);
		speaker = o.AddComponent<AudioSource>();
		speaker.audioClip.Set("Audio/exhibition.wav");
		speaker.playOnStart = false;
		speaker.volume = 0.45f;
		speaker.maxDistance = 22;
		speaker.spatial = true;
		let reverb = Scene.CreateGameObject("Reverb listening zone");
		reverb.Transform.Position = a;
		reverb.AddComponent<AudioReverbZone>().radius = 8;
		a = exhibits[16].at;
		Box("Guide kiosk", a + Vector3(0, 1, 0), .(3, 2, 1), Ink);
		Glow(Orb("Guide presence", a + Vector3(0, 2.9f, 0), 0.65f, .(1, 0.4f, 0.55f)), .(1, 0.4f, 0.55f));
		o = Scene.CreateGameObject("Exhibition guide");
		talk = o.AddComponent<DialogueRunner>();
		talk.dialogue.Set("Dialogue/guide.tdialogue");
		talk.autoAdvance = true;
		talk.shared = true;
		talk.onlyOwnerChooses = false;
		a = exhibits[17].at;
		o = Orb("Timeline sculpture", a + Vector3(0, 2, 0), 1.2f, .(1, 0.65f, 0.2f));
		Box("Timeline pedestal", a + Vector3(0, 0.5f, 0), .(4, 1, 4), Ink);
		sequence = Scene.CreateGameObject("Sequence player").AddComponent<SequencePlayer>();
		sequence.sequence.Set("Sequences/sculpture.tsequence");
		sequence.useCameraShots = false;
		sequence.shared = true;
		a = exhibits[18].at;
		o = Orb("Shared console", a + Vector3(0, 1.7f, 0), 1, Cyan);
		terminal = o.AddComponent<SharedTerminal>();
		Box("Network console base", a + Vector3(0, 0.3f, 0), .(5, 0.6f, 3), Ink);
		a = exhibits[19].at;
		for (int i < 5)
		{
			let o2 = Box("Display bar", a + Vector3(-4 + i * 2, 1 + i * 0.2f, 0), .(1.2f, 2 + i * 0.4f, 1.2f), .(1, 0.4f, 0.55f));
			Glow(o2, .(1, 0.4f, 0.55f), 0.5f);
		}
	}

	public override void Update()
	{
		frames++;
		RefreshAuthoredMarkers();
		ApplySharedChanges();
		if (frames == 6)
		{
			GameObject.AddComponent<ShowcaseValidation>();
			GameObject.AddComponent<CooperativeValidation>();
			let arg = scope String();
			if (Application.Instance.GetArg("--station", arg))
				Travel(SceneSerializer.ParseInt(arg));
			if (Application.Instance.HasArg("--overview"))
				Overview = true;
		}
		if (frames == 5)
		{
			NavReady = nav.Data != null || nav.Bake();
			FlightReady = flight.Data != null || flight.Bake();
			if (behavior != null)
				behavior.Enabled = NavReady;
			Route();
			Log.Info(scope $"SHOWCASE_NAV walking={NavReady} flight={FlightReady}");
		}
		if (!authoredScene && terrain != null && !terrainReady && terrain.ChunkCount > 0 && terrain.PendingChunks == 0)
		{
			terrainReady = true;
			terrain.ModifySphere(exhibits[20].at + Vector3(0, 0.5f, 0), 4, 2);
		}
		if (ikTarget != null)
			ikTarget.Transform.Position = ikHome + Vector3(Math.Sin(Time.Time) * 0.8f, Math.Sin(Time.Time * 0.7f) * 0.8f, Math.Cos(Time.Time) * 0.7f);
		if (pendingSave && saveHandle.Done)
		{
			pendingSave = false;
			Notice(saveHandle.Succeeded ? scope $"Engine save completed. Saved visits: {savedVisits}" : "Save failed; inspect the engine log.");
		}
		routeTimer += Time.DeltaTime;
		if (routeTimer > 7)
		{
			routeTimer = 0;
			reverse = !reverse;
			if (IsAuthority)
				Route();
		}
		if (puppet != null)
			puppet.SetFloat("speed", 1.8f);
		if (visitor != null)
		{
			if (visitor.Transform.Position.y < -12)
				Travel(0);
			nearest = -1;
			nearestDistance = float.MaxValue;
			for (let e in exhibits)
			{
				var d = e.at - visitor.Transform.Position;
				d.y = 0;
				if (d.Length < nearestDistance)
				{
					nearestDistance = d.Length;
					nearest = e.index;
				}
			}
			if (nearestDistance < 11)
				Visited |= 1u << nearest;
		}
		if (Overview)
		{
			camera.Transform.Position = .(70, 70, -64);
			camera.Transform.Rotation = Quaternion.LookRotation(Vector3(0, 0, 20) - camera.Transform.Position, .Up);
		}
		if (Input.GetKeyDown(.M))
			Directory = !Directory;
		if (Input.GetKeyDown(.Tab))
		{
			Overview = !Overview;
			Directory = false;
		}
		if (Input.GetKeyDown(.Escape))
		{
			Directory = !Directory;
		}
		if (Input.GetKeyDown(.E) && !Directory && nearestDistance < 13 && (talk.View != .Line && talk.View != .Choices))
			Use(nearest);
		if (Input.GetKeyDown(.R) && !Directory && nearestDistance < 13)
			Reset(nearest);
		if (Input.GetMouseButtonDown(0) && !Directory && !GUI.MouseOverControl && !Overview)
			InteractRay();
	}

	public override void FixedUpdate()
	{
		if (lift != null && IsAuthority)
			lift.Transform.Position = liftHome + Vector3(0, 0.65f + Math.Sin(Time.Time * 0.7f) * 0.6f, Math.Sin(Time.Time * 0.4f) * 1.5f);
	}

	void Route()
	{
		for (int i < walkers.Count - 1)
		{
			if (NavReady)
				walkers[i].SetDestination(exhibits[8].at + Vector3(reverse ? -6 : 6, 0.15f, -3 + i * 1.4f), 2.5f, 0.4f);
		}
		for (int i < drones.Count)
		{
			if (FlightReady)
				drones[i].SetDestination(exhibits[9].at + Vector3(reverse ? -6 : 6, 2 + i * 1.2f, -3 + i * 2), 2.5f, 0.4f);
		}
	}

	public void Notice(StringView text)
	{
		status.Set(text);
		statusUntil = Time.RealTime + 6;
	}

	public void Travel(int i)
	{
		if (visitor == null || i < 0 || i >= exhibits.Count) return;
		if (!IsAuthority)
		{
			Overview = false;
			Directory = false;
			visitor.GetComponent<VisitorMotor>().Face(0);
			Request(3, i);
			return;
		}

		Overview = false;
		Directory = false;
		let e = exhibits[i];
		visitor.GetComponent<CharacterController>().Teleport(e.at + Vector3(0, 1.1f, -5.5f));
		visitor.GetComponent<VisitorMotor>().Face(0);
		Notice(e.title);
	}

	public void Use(int i)
	{
		if (i < 0 || i >= exhibits.Count) return;
		if (!IsAuthority && i != 0)
		{
			Request(0, i);
			return;
		}

		switch (i)
		{
		case 0:
			let c = visitor?.GetComponent<CharacterController>();
			if (c != null)
			{
				c.shape = c.shape == .Capsule ? .Box : .Capsule;
				c.ApplyShape();
				Notice(scope $"Controller: {c.shape}");
			}
		case 1:
			materialMode = 1 - materialMode;
			Notice("Material finishes changed.");
		case 2:
			Night = !Night;
			Notice("Shared lighting comparison changed.");
		case 3:
			decalMode++;
			Notice("Shared projected decal changed.");
		case 4:
			for (let p in props)
			{
				if (p.sector == 4 && p.body.HasBody)
					p.body.AddImpulse(.(0, 25, 55));
			}
			Notice("Impulse applied to the stack.");
		case 5:
			if (pendulum.HasBody)
				pendulum.AddImpulse(.(65, 0, 0));
			Notice("Joint pendulum swinging. Walk onto the moving platform.");
		case 6:
			SpawnImpactor();
			Notice("Heavy impactor dropped onto the shell. Walk into cloth and jelly.");
		case 7:
			for (let p in props)
			{
				if (p.sector == 7 && p.body.HasBody)
					p.body.AddImpulse(.(25, 0, 15));
			}
			Notice("Rope load pushed.");
		case 8:
			GateClosed = !GateClosed;
			obstacle.Transform.Position = HomePosition(obstacle) + (GateClosed ? Vector3.Zero : Vector3(0, -3.8f, 0));
			obstacle.GetComponent<BoxCollider>().Refresh();
			var a = exhibits[8].at;
			let ok = nav.Rebuild(.(a + Vector3(-2, -0.5f, -2), a + Vector3(4, 3, 2)));
			TileUpdates++;
			Route();
			Notice(scope $"Local navmesh rebuild: {ok}. Gate {(GateClosed ? "closed" : "open")}.");
		case 9:
			reverse = !reverse;
			Route();
			Notice("Flight destinations changed in the volume grid.");
		case 10:
			let v = voxels[(int)(Time.Time * 0.3f) % voxels.Count];
			v.Carve(v.Transform.Position + Vector3(0, 0, -1), 0.9f);
			Notice("Voxel surface and collision rebuilt locally; detached pieces can fall.");
		case 11:
			lowWater = !lowWater;
			ocean.UseLook(lowWater ? .LowPoly : .Realistic);
			pool.UseLook(lowWater ? .LowPoly : .Realistic);
			ocean.waveHeight = 0.35f;
			pool.waveHeight = 0.18f;
			Notice("Water look changed. Walk off the bridge to swim; Space swims upward.");
		case 12:
			sharedWind = sharedWind < 2 ? 4 : 1.1f;
			Notice("Shared wind strength changed.");
		case 13:
			animationMode = 1 - animationMode;
			Notice("Shared animation and skinning demonstration changed.");
		case 14:
			for (let p in emitters)
			{
				p.burst = 60;
				p.Play();
			}
			Notice("Particle bursts triggered.");
		case 15:
			speaker.Play();
			Notice("Spatial sound playing. Walk behind the wall and out of the reverb zone.");
		case 16:
			talk.Play();
			Notice("Guide dialogue started; choose an answer below.");
		case 17:
			sequence.Play();
			Notice("Sequence timeline started.");
		case 18:
			terminal.presses++;
			Notice(scope $"Shared console count {terminal.presses}. Host/Join launchers enable a real UDP tour.");
		case 19: SaveVisit();
		case 20:
			terrainStrokes++;
			terrain.ModifySphere(exhibits[20].at + Vector3(Math.Sin(terrainStrokes) * 2, 0.8f, 0), 2.5f, (terrainStrokes % 2) == 0 ? 2 : -2);
			Notice("Terrain density changed; only touched chunks update.");
		case 21:
			sharedIk = !sharedIk;
			Notice("Shared IK weight changed.");
		case 22:
			sharedLod = sharedLod >= 2 ? -1 : sharedLod + 1;
			Notice("Shared LOD demonstration changed.");
		case 23:
			shaderMode = 1 - shaderMode;
			Notice("Shared shader speed changed.");
		}
	}

	public void Reset(int i)
	{
		if (!IsAuthority)
		{
			Request(1, i);
			return;
		}
		for (let p in props)
		{
			if (p.sector == i && p.body.HasBody)
			{
				var s = p.body.State;
				s.position = p.home;
				s.rotation = HomeRotation(p.body.GameObject);
				s.linearVelocity = .Zero;
				s.angularVelocity = .Zero;
				p.body.SetState(s);
			}
		}
		if (i == 0 && visitor != null)
		{
			let c = visitor.GetComponent<CharacterController>();
			c.shape = .Capsule;
			c.ApplyShape();
		}
		if (i == 1)
			materialMode = 0;
		if (i == 1)
		{
			for (int n < samples.Count)
			{
				samples[n].metallic = finishes[n].metal;
				samples[n].roughness = finishes[n].rough;
			}
		}
		if (i == 2 && Night)
			Use(2);
		if (i == 6)
		{
			for (int n = props.Count - 1; n >= 0; n--)
			{
				if (props[n].sector == 6 && props[n].body.GameObject.Name == "Heavy soft-body impactor")
				{
					Scene.Destroy(props[n].body.GameObject);
					props.RemoveAt(n);
				}
			}
			for (int n < 3)
			{
				let soft = softs[n];
				soft.Transform.Position = HomePosition(soft.GameObject);
				soft.Transform.Rotation = HomeRotation(soft.GameObject);
				soft.GetComponent<MeshRenderer>().RuntimeMesh = null;
				soft.Rebuild();
				if (soft.kind == .Shell)
					soft.Repair();
			}
		}
		if (i == 7)
		{
			for (let rope in ropes)
			{
				if (StationOf(rope.GameObject) == 7)
					rope.Rebuild();
			}
		}
		if (i == 12)
			sharedWind = baseWind;
		if (i == 13)
			animationMode = 0;
		if (i == 13)
		{
			for (let skin in skins)
			{
				skin.gpuSkinning = true;
				skin.speed = 1;
			}
		}
		if (i == 14)
		{
			for (let emitter in emitters)
			{
				emitter.burst = 0;
				emitter.Play();
			}
		}
		if (i == 15)
			speaker.Stop();
		if (i == 16)
			talk.Stop();
		if (i == 18)
			terminal.presses = 0;
		if (i == 21)
			sharedIk = true;
		if (i == 22)
			sharedLod = -1;
		if (i == 23)
			shaderMode = 0;
		if (i == 23 && shaderSample.Material != null)
			shaderSample.Material.SetFloat("speed", baseShader);
		if (i == 10)
		{
			for (let v in voxels)
				v.ResetShape();
		}
		if (i == 17)
			sequence.Stop();
		Notice("Exhibit reset. Directory > Restart restores the complete campus.");
	}

	void InteractRay()
	{
		if (!IsAuthority)
		{
			RequestRay();
			return;
		}
		let at = camera.Transform.Position;
		let dir = camera.Transform.Forward;
		RaycastHit hit;
		if (!Scene.Physics.Raycast(at + dir * 0.65f, dir, 18, out hit)) return;
		if (hit.gameObject != null)
		{
			let voxel = hit.gameObject.GetComponent<VoxelObject>();
			if (voxel != null)
			{
				voxel.Carve(hit.point, 0.55f);
				return;
			}
			let b = hit.gameObject.GetComponent<Rigidbody>();
			if (b != null && b.HasBody && !b.isKinematic)
				b.AddImpulse(dir * 22 + Vector3(0, 4, 0));
		}
	}

	public void SaveVisit()
	{
		savedVisits++;
		saveHandle = SaveSystem.Save("exhibition");
		pendingSave = true;
		Notice("Saving visit state through the engine SaveSystem...");
	}

	public void LoadVisit()
	{
		saveHandle = SaveSystem.Load("exhibition");
		pendingSave = true;
		Notice("Loading saved visit state...");
	}

	void BuildAdvanced()
	{
		var a = exhibits[20].at;
		var o = Scene.CreateGameObject("Editable terrain tile");
		o.Transform.Position = a + Vector3(-6, 0.3f, -6);
		terrain = o.AddComponent<VoxelTerrain>();
		terrain.mode = .Fixed;
		terrain.sizeX = 1;
		terrain.sizeZ = 1;
		terrain.tileSize = 1;
		terrain.voxelSize = 0.75f;
		terrain.viewDistance = 1;
		terrain.minChunkY = -1;
		terrain.maxChunkY = 0;
		terrain.flatHeight = 0;
		terrain.AddTile(0, 0);
		terrain.OnValidate();
		a = exhibits[21].at;
		o = Scene.CreateGameObject("IK arm rig");
		o.Transform.Position = a + Vector3(-3, 2.5f, 0);
		let upper = Scene.CreateGameObject("Upper arm bone");
		upper.Transform.SetParent(o.Transform, false);
		let middle = Scene.CreateGameObject("Forearm bone");
		middle.Transform.SetParent(upper.Transform, false);
		middle.Transform.LocalPosition = .(2, 0, 0);
		let tip = Scene.CreateGameObject("Hand bone");
		tip.Transform.SetParent(middle.Transform, false);
		tip.Transform.LocalPosition = .(2, 0, 0);
		for (let bone in Transform[?](upper.Transform, middle.Transform))
		{
			let segment = Box("IK arm segment", .Zero, .(2, 0.22f, 0.22f), Cyan, false);
			segment.Transform.SetParent(bone, false);
			segment.Transform.LocalPosition = .(1, 0, 0);
			let joint = Orb("IK joint", .Zero, 0.23f, Chalk);
			joint.Transform.SetParent(bone, false);
			joint.Transform.LocalPosition = .Zero;
		}
		ikHome = a + Vector3(0, 3, 0);
		ikTarget = Orb("IK target", ikHome, 0.3f, .(1, 0.6f, 0.2f));
		Glow(ikTarget, .(1, 0.6f, 0.2f));
		limb = o.AddComponent<LimbIK>();
		limb.upper = upper.Transform;
		limb.middle = middle.Transform;
		limb.tip = tip.Transform;
		limb.target = ikTarget.Transform;
		limb.rotationWeight = 0;
		Box("IK pedestal", a + Vector3(-3, 1, 0), .(1, 2, 1), Ink);
		a = exhibits[22].at;
		o = Scene.CreateGameObject("Local reflection probe");
		o.Transform.Position = a + Vector3(0, 2, 0);
		probe = o.AddComponent<ReflectionProbe>();
		probe.size = .(18, 9, 18);
		probe.resolution = 64;
		let shiny = Orb("Probe mirror", a + Vector3(-4, 1.6f, 0), 1.3f, Chalk).GetComponent<MeshRenderer>();
		shiny.metallic = 1;
		shiny.roughness = 0.08f;
		o = Scene.CreateGameObject("LOD specimen");
		o.Transform.Position = a + Vector3(3, 1.5f, 0);
		for (int i < 3)
		{
			let level = Box(scope $"Specimen_LOD{i}" , .Zero, Vector3(2), i == 0 ? Cyan : i == 1 ? .(1, 0.65f, 0.2f) : .(1, 0.4f, 0.55f), false);
			level.GetComponent<MeshRenderer>().mesh.Set(i == 0 ? "builtin:sphere" : i == 1 ? "builtin:cylinder" : "builtin:cube");
			level.Transform.SetParent(o.Transform, false);
			level.Transform.LocalPosition = .Zero;
		}
		o.AddComponent<LODGroup>();
		a = exhibits[23].at;
		shaderSample = Orb("Custom surface shader", a + Vector3(0, 2, 0), 1.5f, Chalk).GetComponent<MeshRenderer>();
		shaderSample.material.Set("Materials/glow.tmat");
		Box("Shader pedestal", a + Vector3(0, 0.5f, 0), .(4, 1, 4), Ink);
		o = Scene.CreateGameObject("UI document exhibit");
		o.AddComponent<DocumentPanel>();
		document = o.AddComponent<UIDocument>();
		document.document.Set("UI/exhibit.tui");
		document.Enabled = false;
	}

	public override void OnDestroy()
	{
		if (Active == this)
			Active = null;
	}
}
[Component]
class SharedTerminal : NetworkBehaviour
{
	[Sync, Saved] public int32 presses;
	public override void Update()
	{
		let r = GetComponent<MeshRenderer>();
		r.color = (presses % 2) == 0 ? .(0.1f, 0.8f, 0.95f) : .(1, 0.4f, 0.55f);
		r.emissive = r.color;
		r.emissiveIntensity = 1.5f;
	}
}
[Component]
class DisplayMotion : Component
{
	public Vector3 spin = .(0, 20, 0);
	public override void Update()
	{
		Transform.Rotation = Quaternion.Euler(spin * Time.Time);
	}
}
