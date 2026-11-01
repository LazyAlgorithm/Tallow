using System;
using System.Collections;

namespace Tallow;

[Reflect(.All)]
enum SoftBodyKind : int32
{
	/// A sheet that hangs, folds and blows: flags, capes, curtains, sails. Pin some of it to hold it up.
	Cloth,
	/// A closed shape that keeps its volume by pushing out: jelly, rubber balls, soft tyres, cushions.
	Jelly,
	/// A body that keeps its shape on its object and dents where it is hit, and stays dented: car bodies, crates,
	/// metal panels. It rides its object's Rigidbody (the shell ignores that body's collider), given one of its Mass
	/// if it has none. How it dents: Dent Mode.
	Shell
}

[Reflect(.All)]
enum ShellDentMode : int32
{
	/// The object's collider takes every hit, so nothing passes into the shell (make the collider the shape of the
	/// mesh); a hit at Dent Speed or faster presses the shell in around where it landed. The shell itself only
	/// follows its object.
	FromImpacts,
	/// The shell meets things itself and is pushed in where it touches them (it can fold round a post), so the
	/// collider sits a little inside the mesh (by about Dent Depth). Things can press into the shell that far.
	FromSurface
}

/// Makes this object's Mesh Renderer soft: its mesh is simulated as cloth or as a squashy body, which falls, folds,
/// collides with colliders, rigidbodies and characters, pushes them and is pushed back. Jolt steps it on the job
/// threads with the rest of the physics.
///
/// Pinned vertices (painted in the editor: select the object and press Paint Pins in its Inspector) are held where
/// they are on the object, and follow the object as it moves, so a cape on a character's back or a flag on a moving
/// ship goes with it. Wind Zones blow on cloth and jelly. A stiffness map, painted the same way, makes parts of it softer.
///
/// The simulation runs on every machine by itself. Pinned cloth follows its object, so it looks the same everywhere
/// when the object is shared; a free soft body's object is shared when a session starts, and on clients the body is
/// drawn towards where the server has it; a shell's dents are made on the server and sent to every client
/// (see docs/soft-bodies.md).
[Component]
class SoftBody : Component
{
	public SoftBodyKind kind = .Cloth;
	/// The whole body's weight in kilograms, shared by the vertices that are not pinned.
	public float mass = 1;
	/// How hard it resists stretching: 1 barely stretches, 0 like elastic.
	[Range(0, 1)]
	public float stiffness = 0.9f;
	/// How hard it resists bending: 0 folds freely (silk), 1 holds its shape (leather, rubber).
	[Range(0, 1)]
	public float bendStiffness = 0.2f;
	/// Jelly: how hard the air inside pushes out (pascals above the air outside), whatever its size. 0 keeps its
	/// shape by its edges alone, 10 a jelly cube, 50 a little puffed up, 200 and more blows it up into a ball.
	public float pressure = 10;
	/// How fast it loses speed, like moving through thick air.
	[Range(0, 5)]
	public float damping = 0.1f;
	/// Jelly: how fast its wobbling dies away and how little it springs back up when it lands, without slowing it
	/// as a whole. 0 wobbles on, 10 settles at once.
	[Range(0, 20)]
	public float wobbleDamping = 3;
	public float friction = 0.4f;
	[Range(0, 1)]
	public float bounciness = 0;
	public float gravityScale = 1;
	/// How far from its surface it keeps other things (its thickness), in metres.
	public float thickness = 0.02f;
	/// How much Wind Zones push it (cloth and jelly; a shell rides its object): 0 not at all. A flag is a cloth plane
	/// pinned along one edge, with a Global Wind Zone in the scene.
	public float windDrag = 1;
	/// Solver passes each step: more is stiffer and costs more.
	[Range(1, 32)]
	public int32 iterations = 5;
	/// Shell: what dents it: hits on its object's collider, or things pushing on the shell itself.
	public ShellDentMode dentMode = .FromImpacts;
	/// Shell: how far one impact can push the surface in, in metres.
	public float dentDepth = 0.15f;
	/// Shell: how far the surface springs back from, in metres. Pushed further than this, it stays dented.
	public float springBack = 0.03f;
	/// Shell: how fast something must hit it to dent it, in metres a second (3 is about 11 km/h). Slower knocks,
	/// leaning on it and loads resting on it spring back however hard they press.
	public float dentSpeed = 3;
	/// The vertices held in place, by number ("0-12 40 41"): Paint Pins in the editor writes these.
	public String pins = new .() ~ delete _;
	/// Where it is softer than Stiffness says, by vertex ("12=0.5 13=0.25"): painted in the editor.
	public String stiffnessMap = new .() ~ delete _;

	/// Seconds of wind it has had, steps added up: what gusts and flutter go by.
	float mWindTime;

	/// How long a jelly takes to fill with its air, in seconds.
	const float AirTime = 0.5f;
	/// Wind Zones' strength is a feel (1 a breeze, 6 a gale); this is how many metres a second each is.
	const float WindSpeed = 4;

	[CLink] static extern uint32 tn_soft_create(void* world, NativeConfig* config, float* positions, uint32 vertexCount, uint32* triangles, uint32 triangleCount, float* pinned, float* stiffness, float* center, float* objectMatrix);
	[CLink] static extern void tn_soft_ignore(void* world, uint32 bodyId, uint32 ignoredBody);
	[CLink] static extern void tn_soft_forget(void* world, uint32 bodyId);
	[CLink] static extern void tn_soft_skin(void* world, uint32 bodyId, float* objectMatrix, float* objectNext, float step);
	[CLink] static extern uint32 tn_soft_dents(void* world, uint32 bodyId, float* output, uint32 capacity);
	[CLink] static extern uint32 tn_soft_dent_revision(void* world, uint32 bodyId);
	[CLink] static extern void tn_soft_set_dents(void* world, uint32 bodyId, float* dents, uint32 count, float* objectMatrix);
	[CLink] static extern uint32 tn_soft_read(void* world, uint32 bodyId, float* positions, float* velocities, uint32 capacity);
	[CLink] static extern void tn_soft_move_pinned(void* world, uint32 bodyId, uint32* indices, float* targets, uint32 count, float step);
	[CLink] static extern void tn_soft_set_positions(void* world, uint32 bodyId, float* positions, float* velocities, uint32 count);
	[CLink] static extern void tn_soft_wind(void* world, uint32 bodyId, float* wind, float drag, float turbulence, float time, float step);
	[CLink] static extern uint32 tn_soft_touching(void* world, uint32 bodyId, uint32* output, uint32 capacity);
	[CLink] static extern void tn_soft_world_destroyed(void* world);
	[CLink] static extern void tn_soft_shift(void* world, uint32 bodyId, float* offset);
	[CLink] static extern void tn_soft_set_pressure(void* world, uint32 bodyId, float pressure);
	[CLink] static extern void tn_soft_damp_wobble(void* world, uint32 bodyId, float rate, float step);
	[CLink] static extern void tn_soft_proxies(void* world, uint32* bodies, int32* closed, float* reach, uint32 count);

	/// native/tallow_softbody.cpp's Config, in the same order.
	[CRepr]
	struct NativeConfig
	{
		public float mass, stretch, shear, bend, pressure, damping, friction, restitution, gravityFactor, vertexRadius, dentDepth, dentYield, dentSpeed, stepTime;
		public int32 iterations, doubleSided, longRange, dihedral, shell, impacts;
		public uint32 layer;
		public uint64 userData;
	}

	uint32 mBody = uint32.MaxValue;
	bool mReady;
	PhysicsWorld mWorld;
	// The mesh drawn (the renderer's own, copied so its vertices can move), and for each of its vertices the welded
	// vertex of the simulation it follows: a mesh splits a vertex where its texture or shading has a seam, the
	// simulation must not.
	Mesh mMesh ~ delete _;
	List<int32> mRenderToSim = new .() ~ delete _;
	// The simulation's vertices where they rest on the object, its triangles, and which are pinned.
	List<Vector3> mRest = new .() ~ delete _;
	List<uint32> mTriangles = new .() ~ delete _;
	List<uint32> mPinned = new .() ~ delete _;
	List<float> mTargets = new .() ~ delete _;
	List<Vector3> mPositions = new .() ~ delete _;
	List<Vector3> mNormals = new .() ~ delete _;
	// A free body's middle, from its object's position (where the middle was when it was made).
	Vector3 mCarried;
	// A jelly's air (Jolt's pressure: pressure times volume), let in over its first moments: all at once, it
	// tangles the small faces round a sphere's poles.
	float mAir;
	float mAge;
	// A shell's own Rigidbody, which its vertices do not collide with (uint32.MaxValue until it is found).
	uint32 mIgnored = uint32.MaxValue;
	// A shell's Convex Collider follows its dents: the dents it was last wrapped to, steps left until the next wrap
	// (once a crash has settled), and the shape it wraps.
	uint32 mHullRevision;
	int mHullWait;
	Mesh mHull ~ delete _;
	// Made on a client of a session: a shell that does not dent by itself, taking the server's dents instead.
	bool mDentsFromServer;

	/// The body's id in the physics world, or uint32.MaxValue before it is made.
	public uint32 BodyId => mBody;
	public bool HasBody => mBody != uint32.MaxValue;
	/// Whether it has come to rest and stopped being simulated (until something touches it or its object moves).
	public bool IsSleeping => mWorld != null && mWorld.IsSleeping(mBody);
	/// How many vertices the simulation has (the mesh's, with its seams joined).
	public int SimulatedVertexCount => mRest.Count;
	/// Where each simulated vertex is now, in the world (updated every frame while it runs).
	public List<Vector3> Positions => mPositions;

	public override void Start()
	{
		mReady = true;
		if (kind == .Shell)
			GiveShellABody();
		CreateBody();
	}

	/// A shell rides its object's Rigidbody (it has no gravity of its own), and a Rigidbody only moves with a collider.
	/// With no collider on its object, it gets a Convex Collider round the mesh (which follows its dents); with no Rigidbody on the object or above
	/// it, one of this soft body's Mass. So it falls, is pushed and hits things like any body.
	void GiveShellABody()
	{
		Rigidbody rigid = null;
		for (var up = Transform; up != null && rigid == null; up = up.Parent)
			rigid = up.GameObject.GetComponent<Rigidbody>();
		// A Rigidbody higher up moves with its own colliders.
		if (rigid != null && rigid.GameObject != GameObject)
			return;
		if (GetComponent<Collider>() == null)
		{
			let mesh = GetComponent<MeshRenderer>()?.ActiveMesh;
			if (mesh == null || mesh.Vertices.Count < 4)
				return;
			// A convex wrap of the mesh, which follows its dents.
			GameObject.AddComponent<ConvexCollider>();
			// A Rigidbody that started without a collider made no body: it can now.
			rigid?.RebuildBody();
		}
		if (rigid == null)
		{
			rigid = GameObject.AddComponent<Rigidbody>();
			rigid.mass = Math.Max(mass, 0.001f);
			rigid.EnsureBody();
		}
	}

	public override void OnEnable()
	{
		if (mReady)
			CreateBody();
	}

	public override void OnDisable()
	{
		DestroyBody();
	}

	/// Makes the body again from the mesh and settings (after changing them while it runs). It starts at rest.
	public void Rebuild()
	{
		DestroyBody();
		CreateBody();
	}

	void DestroyBody()
	{
		if (mBody != uint32.MaxValue && mWorld != null)
		{
			tn_soft_forget(mWorld.[Friend]mSystem, mBody);
			mWorld.[Friend]RemoveSoftBody(mBody);
		}
		mIgnored = uint32.MaxValue;
		mBody = uint32.MaxValue;
		mWorld = null;
		let renderer = GetComponent<MeshRenderer>();
		if (renderer != null && renderer.RuntimeMesh == mMesh)
			renderer.RuntimeMesh = null;
	}

	void CreateBody()
	{
		if (mBody != uint32.MaxValue)
			return;
		let renderer = GetComponent<MeshRenderer>();
		let source = renderer?.ActiveMesh;
		if (source == null || source.Vertices.Count < 3 || source.Indices.Count < 3)
		{
			Log.Warning(scope $"Soft Body on '{GameObject.Name}' needs a Mesh Renderer with a mesh.");
			return;
		}
		let world = Scene.Physics;
		world.[Friend]EnsureCreated();
		let system = world.[Friend]mSystem;
		if (system == null)
			return;
		Weld(source, mRest, mTriangles, mRenderToSim);

		// The simulation works in the world; the mesh drawn stays in the object's own space.
		let toWorld = Transform.LocalToWorld;
		var center = Vector3.Zero;
		for (let rest in mRest)
			center = center + toWorld.TransformPoint(rest);
		center = center / mRest.Count;
		let positions = scope List<float>(mRest.Count * 3);
		for (let rest in mRest)
		{
			let p = toWorld.TransformPoint(rest) - center;
			positions.Add(p.x);
			positions.Add(p.y);
			positions.Add(p.z);
		}
		let pinned = scope List<float>();
		pinned.Resize(mRest.Count);
		mPinned.Clear();
		ParsePins(pins, mRest.Count, mPinned);
		for (let index in mPinned)
			pinned[(int)index] = 1;
		let stiffnesses = scope List<float>();
		stiffnesses.Resize(mRest.Count);
		for (int i < mRest.Count)
			stiffnesses[i] = 1;
		ParseStiffness(stiffnessMap, stiffnesses);

		NativeConfig config = default;
		let cloth = kind == .Cloth;
		let shell = kind == .Shell;
		config.mass = Math.Max(mass, 0.001f);
		// Compliance (how far a constraint gives under force) from 1e-2 (stiffness 0) to 1e-6 (stiffness 1).
		config.stretch = Compliance(stiffness);
		config.shear = Compliance(stiffness * 0.9f);
		// A shell's shape comes from its object; bending would only fight its dents.
		// Cloth bends by distance (an edge across each pair of faces), jelly by angle, which needs the larger figure.
		config.bend = (bendStiffness <= 0 || shell) ? -1 : Compliance(bendStiffness) * (cloth ? 1 : 100);
		// Jolt's pressure is the amount of gas (pressure times volume), so the same setting holds any size alike.
		mAir = kind != .Jelly ? 0 : Math.Max(pressure, 0) * Volume(positions, mTriangles);
		mAge = 0;
		config.pressure = 0;
		config.damping = damping;
		config.friction = friction;
		config.restitution = bounciness;
		// A shell is carried by its object, which has the weight.
		config.gravityFactor = shell ? 0 : gravityScale;
		config.vertexRadius = Math.Max(thickness, 0);
		config.dentDepth = Math.Max(dentDepth, 0.001f);
		config.dentYield = Math.Max(springBack, 0);
		mDentsFromServer = shell && NetworkSync.IsClientOf(Scene);
		config.dentSpeed = mDentsFromServer ? 1.0e9f : Math.Max(dentSpeed, 0);
		config.shell = shell ? 1 : 0;
		config.impacts = (shell && dentMode == .FromImpacts) ? 1 : 0;
		config.iterations = Math.Clamp(iterations, 1, 32);
		config.stepTime = Time.FixedDeltaTime;
		config.doubleSided = (cloth || shell) ? 1 : 0;
		config.longRange = cloth ? 1 : 0;
		// Jelly bends by the angle between faces: by distance, many thin faces meeting at a point (a sphere's poles)
		// shiver. Cloth bends by distance: by angle, a cloth folded sharply (draped over something) gains speed at
		// the folds and flails.
		config.dihedral = cloth ? 0 : 1;
		config.layer = PhysicsWorld.[Friend]ObjectLayer(PhysicsWorld.[Friend]LayerMoving, Transform);
		config.userData = (uint64)GameObject.Id;
		var objectMatrix = toWorld;
		mBody = tn_soft_create(system, &config, positions.Ptr, (uint32)mRest.Count, mTriangles.Ptr, (uint32)(mTriangles.Count / 3), pinned.Ptr, stiffnesses.Ptr, (float*)&center, &objectMatrix.m[0]);
		if (mBody == uint32.MaxValue)
		{
			Log.Warning(scope $"Soft Body on '{GameObject.Name}': its mesh has no faces the simulation can use.");
			return;
		}
		mWorld = world;
		world.[Friend]AddSoftBody(mBody, this);
		mCarried = center - Transform.Position;

		// The renderer draws a copy whose vertices follow the simulation.
		delete mMesh;
		mMesh = new Mesh();
		mMesh.Name.Set(source.Name);
		mMesh.Vertices.AddRange(source.Vertices);
		mMesh.Indices.AddRange(source.Indices);
		mMesh.UploadDynamic();
		renderer.RuntimeMesh = mMesh;
		ReadBack();
	}

	/// The volume a closed mesh holds (from its faces, packed x, y, z), in cubic metres.
	static float Volume(List<float> positions, List<uint32> triangles)
	{
		float sixVolume = 0;
		for (int t = 0; t + 2 < triangles.Count; t += 3)
		{
			let a = Vector3(positions[(int)triangles[t] * 3], positions[(int)triangles[t] * 3 + 1], positions[(int)triangles[t] * 3 + 2]);
			let b = Vector3(positions[(int)triangles[t + 1] * 3], positions[(int)triangles[t + 1] * 3 + 1], positions[(int)triangles[t + 1] * 3 + 2]);
			let c = Vector3(positions[(int)triangles[t + 2] * 3], positions[(int)triangles[t + 2] * 3 + 1], positions[(int)triangles[t + 2] * 3 + 2]);
			sixVolume += Vector3.Dot(a, Vector3.Cross(b, c));
		}
		return Math.Abs(sixVolume) / 6;
	}

	static float Compliance(float stiffness) => Math.Pow(10.0f, -6.0f + 4.0f * (1.0f - Mathf.Clamp01(stiffness)));

	/// Joins the mesh's vertices that share a place (split at texture or shading seams) into the simulation's
	/// vertices: where each rests, the triangles between them, and which one each of the mesh's vertices is.
	public static void Weld(Mesh source, List<Vector3> rest, List<uint32> triangles, List<int32> renderToSim)
	{
		rest.Clear();
		triangles.Clear();
		renderToSim.Clear();
		let byPlace = scope Dictionary<int64, int32>();
		for (let vertex in source.Vertices)
		{
			let p = vertex.position;
			// A millimetre grid: vertices closer than that are one.
			let key = ((int64)Math.Round(p.x * 1000) & 0x1FFFFF) | (((int64)Math.Round(p.y * 1000) & 0x1FFFFF) << 21) | (((int64)Math.Round(p.z * 1000) & 0x1FFFFF) << 42);
			if (!byPlace.TryGetValue(key, var index))
			{
				index = (int32)rest.Count;
				byPlace[key] = index;
				rest.Add(p);
			}
			renderToSim.Add(index);
		}
		for (int i = 0; i + 2 < source.Indices.Count; i += 3)
		{
			let a = (uint32)renderToSim[(int)source.Indices[i]], b = (uint32)renderToSim[(int)source.Indices[i + 1]], c = (uint32)renderToSim[(int)source.Indices[i + 2]];
			if (a == b || b == c || a == c)
				continue;
			triangles.Add(a);
			triangles.Add(b);
			triangles.Add(c);
		}
	}

	/// Whether the server says where this body is: a free soft body on a networked object, on a client.
	bool FollowsServer => Free && Scene.Network != null && !Scene.Network.IsServer && GetComponent<NetworkIdentity>() != null;

	/// A body with nothing holding it to its object, which carries its object instead.
	bool Free => mPinned.IsEmpty && kind != .Shell;

	/// Whether it moves its object by itself (cloth or jelly with nothing pinned): such an object is shared when a
	/// network session starts, like a Rigidbody's.
	public bool MovesByItself
	{
		get
		{
			if (kind == .Shell)
				return false;
			if (mBody != uint32.MaxValue)
				return mPinned.IsEmpty;
			for (let c in pins.RawChars)
			{
				if (c.IsDigit)
					return false;
			}
			return true;
		}
	}

	/// The middle of the simulated vertices, as last read.
	Vector3 Middle()
	{
		var sum = Vector3.Zero;
		for (let p in mPositions)
			sum = sum + p;
		return sum / Math.Max(mPositions.Count, 1);
	}

	/// A free body carries its object (ReadBack puts the object where the body is). When something else moved the
	/// object since (a script, or the server's position arriving on a client), the body goes with it: at once, or
	/// on a client eased towards it unless far off.
	void FollowMovedObject()
	{
		if (!Free || mPositions.Count != mRest.Count || mBody == uint32.MaxValue || mWorld == null)
			return;
		let gap = Transform.Position - (Middle() - mCarried);
		if (gap.LengthSquared < 1.0e-8f)
			return;
		var shift = (FollowsServer && gap.LengthSquared < 4) ? gap * 0.2f : gap;
		tn_soft_shift(mWorld.[Friend]mSystem, mBody, (float*)&shift);
		for (var p in ref mPositions)
			p = p + shift;
	}

	/// Before each physics step: pinned vertices go where the object holds them, and the wind blows.
	void BeforeStep(float step)
	{
		if (mBody == uint32.MaxValue || mWorld == null)
			return;
		let system = mWorld.[Friend]mSystem;
		FollowMovedObject();
		if (kind == .Jelly)
			tn_soft_damp_wobble(system, mBody, wobbleDamping, step);
		if (mAir > 0 && mAge < AirTime)
		{
			mAge += step;
			tn_soft_set_pressure(system, mBody, mAir * Math.Min(mAge / AirTime, 1));
		}
		if (kind == .Shell)
		{
			var own = GetComponent<Rigidbody>();
			for (var up = Transform.Parent; own == null && up != null; up = up.Parent)
				own = up.GameObject.GetComponent<Rigidbody>();
			if (mIgnored == uint32.MaxValue && own != null && own.BodyId != uint32.MaxValue)
			{
				mIgnored = own.BodyId;
				tn_soft_ignore(system, mBody, mIgnored);
			}
			// The shell is held where its object will be once this step has moved its rigidbody.
			var objectMatrix = Transform.LocalToWorld;
			var objectNext = objectMatrix;
			if (own != null && own.BodyId != uint32.MaxValue && !own.isKinematic)
			{
				let pivot = own.Transform.Position;
				let spin = own.AngularVelocity;
				let angle = spin.Length * step;
				let turn = angle > 1.0e-6f ? Quaternion.AngleAxis(angle * Mathf.Rad2Deg, spin / spin.Length) : Quaternion.Identity;
				objectNext = Matrix4.Translate(pivot + own.Velocity * step) * Matrix4.Rotation(turn) * Matrix4.Translate(-pivot) * objectMatrix;
			}
			tn_soft_skin(system, mBody, &objectMatrix.m[0], &objectNext.m[0], step);
		}
		else if (!mPinned.IsEmpty)
		{
			let toWorld = Transform.LocalToWorld;
			mTargets.Clear();
			for (let index in mPinned)
			{
				let p = toWorld.TransformPoint(mRest[(int)index]);
				mTargets.Add(p.x);
				mTargets.Add(p.y);
				mTargets.Add(p.z);
			}
			tn_soft_move_pinned(system, mBody, mPinned.Ptr, mTargets.Ptr, (uint32)mPinned.Count, step);
		}
		// A shell rides its object, so the wind does not blow it about.
		if (windDrag > 0 && kind != .Shell)
		{
			var wind = Wind.At(Scene, Transform.Position) * WindSpeed;
			if (wind.LengthSquared > 0.0001f)
			{
				// Gusts come and go, a little differently for each object; the air also differs across it.
				let phase = (float)(GameObject.Id % 97);
				mWindTime += step;
				wind = wind * (1.0f + 0.35f * Math.Sin(mWindTime * 1.7f + phase) + 0.15f * Math.Sin(mWindTime * 4.3f + phase * 0.5f));
				tn_soft_wind(system, mBody, (float*)&wind, windDrag, Wind.Turbulence(Scene), mWindTime + phase, step);
			}
		}
	}

	/// Before each physics step: closed soft bodies near other soft bodies get proxies, surfaces the others can meet
	/// (the physics engine only has soft bodies meet rigid bodies).
	static void UpdateProxies(PhysicsWorld world, Dictionary<uint32, SoftBody> bodies, List<Rope> ropes)
	{
		if (bodies.Count + ropes.Count < 2 || bodies.IsEmpty)
			return;
		let ids = scope List<uint32>(bodies.Count);
		let closed = scope List<int32>(bodies.Count);
		let reach = scope List<float>(bodies.Count);
		for (let (id, soft) in bodies)
		{
			ids.Add(id);
			closed.Add(soft.kind == .Cloth ? 0 : 1);
			reach.Add(Math.Max(soft.thickness, 0.005f) * 2 + 0.05f);
		}
		// Ropes meet the proxies of closed bodies, as cloth does.
		for (let rope in ropes)
		{
			ids.Add(rope.BodyId);
			closed.Add(0);
			reach.Add(Math.Max(rope.thickness, 0.005f) + 0.05f);
		}
		tn_soft_proxies(world.[Friend]mSystem, ids.Ptr, closed.Ptr, reach.Ptr, (uint32)ids.Count);
	}

	public override void FixedUpdate()
	{
		// A session started or ended since the shell was made: made again to dent by itself or not, keeping its dents.
		if (kind == .Shell && mBody != uint32.MaxValue && NetworkSync.IsClientOf(Scene) != mDentsFromServer)
		{
			let dents = scope List<Vector3>();
			GetDents(dents);
			Rebuild();
			ApplyDents(dents);
		}
		FollowDents();
	}

	/// A shell's Convex Collider (on its object, with its Rigidbody) is wrapped again round the dented shape once
	/// the denting has stopped for a fifth of a second, so things stop at the dent rather than where the surface was.
	void FollowDents()
	{
		if (kind != .Shell || mBody == uint32.MaxValue || mWorld == null)
			return;
		let revision = tn_soft_dent_revision(mWorld.[Friend]mSystem, mBody);
		if (revision != mHullRevision)
		{
			mHullRevision = revision;
			mHullWait = Math.Max((int)Math.Round(0.2f / Math.Max(Time.FixedDeltaTime, 0.001f)), 1);
			return;
		}
		if (mHullWait == 0 || --mHullWait > 0)
			return;
		NetworkSync.DentsSettled(this);
		let convex = GetComponent<ConvexCollider>();
		let rigid = GetComponent<Rigidbody>();
		if (convex == null || rigid == null || mRest.Count < 4)
			return;
		let dents = scope List<Vector3>();
		GetDents(dents);
		if (dents.Count != mRest.Count)
			return;
		if (mHull == null)
			mHull = new Mesh();
		mHull.Vertices.Clear();
		for (int i < mRest.Count)
		{
			MeshVertex vertex = default;
			vertex.position = mRest[i] + dents[i];
			mHull.Vertices.Add(vertex);
		}
		convex.HullMesh = mHull;
		rigid.RebuildBody();
		// The body is a new one: the shell rides it from now on.
		mIgnored = uint32.MaxValue;
	}

	public override void LateUpdate()
	{
		ReadBack();
	}

	/// The simulation's vertices into Positions and the mesh drawn.
	void ReadBack()
	{
		if (mBody == uint32.MaxValue || mWorld == null || mMesh == null)
			return;
		FollowMovedObject();
		mPositions.Resize(mRest.Count);
		let read = tn_soft_read(mWorld.[Friend]mSystem, mBody, (float*)mPositions.Ptr, null, (uint32)mRest.Count);
		if (read != (uint32)mRest.Count)
			return;
		// Normals from the faces round each vertex, in the world.
		mNormals.Resize(mRest.Count);
		for (int i < mNormals.Count)
			mNormals[i] = .Zero;
		for (int t = 0; t + 2 < mTriangles.Count; t += 3)
		{
			let a = mTriangles[t], b = mTriangles[t + 1], c = mTriangles[t + 2];
			let normal = Vector3.Cross(mPositions[(int)b] - mPositions[(int)a], mPositions[(int)c] - mPositions[(int)a]);
			mNormals[(int)a] = mNormals[(int)a] + normal;
			mNormals[(int)b] = mNormals[(int)b] + normal;
			mNormals[(int)c] = mNormals[(int)c] + normal;
		}
		// A free body carries its object (where the server says it is, on a client).
		if (Free && !FollowsServer)
			Transform.Position = Middle() - mCarried;
		let toLocal = Transform.WorldToLocal;
		for (int v < mMesh.Vertices.Count)
		{
			let sim = mRenderToSim[v];
			var vertex = ref mMesh.Vertices[v];
			vertex.position = toLocal.TransformPoint(mPositions[sim]);
			let normal = toLocal.TransformDirection(mNormals[sim]);
			if (normal.LengthSquared > 1.0e-12f)
				vertex.normal = normal.Normalized;
		}
		mMesh.RecalculateBounds();
		mMesh.UpdateDynamic();
	}

	/// The bodies (by physics body id) its vertices have touched since this was last called.
	public void TouchingBodies(List<uint32> output)
	{
		output.Clear();
		if (mBody == uint32.MaxValue || mWorld == null)
			return;
		uint32[64] found = ?;
		let count = tn_soft_touching(mWorld.[Friend]mSystem, mBody, &found, 64);
		for (uint32 i < count)
			output.Add(found[i]);
	}

	/// A shell's dents: for each simulated vertex, how far it has been pushed from where it was made, in the object's
	/// own space. Empty for other kinds. Save these, or send them, and give them back with SetDents.
	public void GetDents(List<Vector3> output)
	{
		output.Clear();
		if (kind != .Shell || mBody == uint32.MaxValue || mWorld == null)
			return;
		output.Resize(mRest.Count);
		let count = tn_soft_dents(mWorld.[Friend]mSystem, mBody, (float*)output.Ptr, (uint32)output.Count);
		output.Resize((int)count);
	}

	/// Dents a shell as GetDents gave them (one for each simulated vertex). In a session the server's dents are
	/// everyone's: there it dents every machine's shell, and a client's call goes to the server, for an object that
	/// player controls.
	public void SetDents(Span<Vector3> dents)
	{
		if (kind != .Shell || mBody == uint32.MaxValue || mWorld == null || NetworkSync.DentsRequest(this, dents))
			return;
		ApplyDents(dents);
	}

	/// Takes every dent out of a shell (in a session, as SetDents).
	public void Repair() => SetDents(default);

	/// SetDents on this machine alone.
	void ApplyDents(Span<Vector3> dents)
	{
		if (kind != .Shell || mBody == uint32.MaxValue || mWorld == null)
			return;
		var objectMatrix = Transform.LocalToWorld;
		tn_soft_set_dents(mWorld.[Friend]mSystem, mBody, dents.IsEmpty ? null : (float*)dents.Ptr, (uint32)dents.Length, &objectMatrix.m[0]);
		ReadBack();
	}

	/// How deep its deepest dent is, in metres (0 for other kinds).
	public float DeepestDent()
	{
		let dents = scope List<Vector3>();
		GetDents(dents);
		float deepest = 0;
		for (let dent in dents)
			deepest = Math.Max(deepest, dent.Length);
		return deepest;
	}

	/// Puts the simulated vertices at places in the world, still (a network correction, or a reset).
	public void SetPositions(Span<Vector3> positions)
	{
		if (mBody == uint32.MaxValue || mWorld == null || positions.Length != mRest.Count)
			return;
		tn_soft_set_positions(mWorld.[Friend]mSystem, mBody, (float*)positions.Ptr, null, (uint32)positions.Length);
		ReadBack();
	}

	/// Reads "0-12 40 41" into vertex numbers below count.
	public static void ParsePins(StringView text, int count, List<uint32> output)
	{
		for (let word in text.Split(' ', .RemoveEmptyEntries))
		{
			let dash = word.IndexOf('-');
			let first = int.Parse(dash < 0 ? word : word.Substring(0, dash)) case .Ok(let value) ? value : -1;
			let last = dash < 0 ? first : (int.Parse(word.Substring(dash + 1)) case .Ok(let value) ? value : -1);
			for (int i = Math.Max(first, 0); i <= last && i < count; i++)
			{
				if (!output.Contains((uint32)i))
					output.Add((uint32)i);
			}
		}
	}

	/// Writes vertex numbers as "0-12 40 41".
	public static void FormatPins(List<uint32> pinned, String output)
	{
		let sorted = scope List<uint32>(pinned);
		sorted.Sort();
		int i = 0;
		while (i < sorted.Count)
		{
			int j = i;
			while (j + 1 < sorted.Count && sorted[j + 1] <= sorted[j] + 1)
				j++;
			if (!output.IsEmpty)
				output.Append(' ');
			if (j > i)
				output.AppendF("{}-{}", sorted[i], sorted[j]);
			else
				output.AppendF("{}", sorted[i]);
			i = j + 1;
		}
	}

	/// Reads "12=0.5 13=0.25" into a stiffness for each vertex (the rest stay as they are).
	public static void ParseStiffness(StringView text, List<float> stiffnesses)
	{
		for (let word in text.Split(' ', .RemoveEmptyEntries))
		{
			let equals = word.IndexOf('=');
			if (equals < 0)
				continue;
			let index = int.Parse(word.Substring(0, equals)) case .Ok(let value) ? value : -1;
			if (index >= 0 && index < stiffnesses.Count)
				stiffnesses[index] = Mathf.Clamp01(SceneSerializer.ParseFloat(word.Substring(equals + 1)));
		}
	}

	/// Writes the stiffnesses below 1 as "12=0.5 13=0.25".
	public static void FormatStiffness(List<float> stiffnesses, String output)
	{
		for (int i < stiffnesses.Count)
		{
			if (stiffnesses[i] >= 0.999f)
				continue;
			if (!output.IsEmpty)
				output.Append(' ');
			output.AppendF("{}={}", i, Math.Round(stiffnesses[i] * 100) / 100);
		}
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected || mPinned.IsEmpty || mPositions.Count != mRest.Count)
			return;
		for (let index in mPinned)
			DebugDraw.Sphere(mPositions[(int)index], 0.03f, .(1, 0.55f, 0.1f, 1));
	}
}
