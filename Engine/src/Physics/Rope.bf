using System;
using System.Collections;

namespace Tallow;

/// A rope (docs/soft-bodies.md "Ropes"): from the object in Start Attached To (this object if none) to the one in
/// End Attached To, or hanging free. Tow or lift with it from code: `Rope.Attach(truck, trailer)`.
/// It sags, swings, drapes over things and is pushed about by what moves through it, simulated as a chain of short
/// stiff lengths that resist bending and twisting (Jolt's Cosserat rods).
///
/// Each end is held where it is on its object, and moves with it. An end on a dynamic Rigidbody also pulls on it:
/// the two ends can get no further apart than the rope is long (it goes slack when they come closer), so a rope
/// holds up a crate, swings it, and is pulled tight by it. The pull acts along the straight line between the ends,
/// or, with Wraps Around on, round what the rope lies over (a rope over a beam works as a pulley). With a Break Force
/// it snaps in two when pulled harder than that.
///
/// The rope draws itself as a tube with the Mesh Renderer on this object (added if there is none).
///
/// In a network session the server ties, changes and snaps ropes (Attach, AttachStart, AttachEnd, LayAlong, Snap
/// and Break Force) on every machine; a client's call goes to the server, for a rope or object that player controls.
/// Each machine simulates the rope itself, between the shared objects.
[Component]
class Rope : Component
{
	/// How long it is, in metres.
	public float length = 3;
	/// How thick it is, in metres.
	public float thickness = 0.04f;
	/// The whole rope's weight in kilograms.
	public float mass = 1;
	/// How many lengths it is made of: more bends more smoothly and costs more. 0 picks about one per 10 cm.
	[Range(0, 256)]
	public int32 segments = 0;
	/// How hard it resists bending: 0 a limp rope, 1 a stiff cable.
	[Range(0, 1)]
	public float bendStiffness = 0.1f;
	/// How fast it loses speed, like moving through thick air.
	[Range(0, 5)]
	public float damping = 0.2f;
	public float friction = 0.6f;
	/// What its first end is tied to. None: this object holds it (or nothing, with Hold Start off).
	public Transform startAttachedTo;
	/// With nothing in Start Attached To: whether this object holds the first end. Off: that end hangs free too.
	public bool holdStart = true;
	/// Where it is tied on that object, relative to it. Zero: on its surface, where it faces along the rope (the top of
	/// a crate hanging from it).
	public Vector3 startOffset = .Zero;
	/// What its other end is tied to. None: it hangs free.
	public Transform endAttachedTo;
	/// Where it is tied on that object, relative to it. Zero: on its surface, where it faces along the rope.
	public Vector3 endOffset = .Zero;
	/// How firmly a body on the end is held turned to the rope, as a knot does: it tips back in line with the rope and
	/// stops spinning about it. 0: it turns freely about where it is tied.
	[Range(0, 1)]
	public float knotStiffness = 0.5f;
	/// How much Wind Zones push it: 0 not at all.
	public float windDrag = 1;
	/// Whether the pull goes round what the rope lies over (a beam, a branch, a post) instead of straight between
	/// the ends: a rope over a beam is a pulley, and lifting one end lowers the other.
	public bool wrapsAround = false;
	/// How hard it can be pulled, in newtons, before it snaps in two (each half staying on its end). 0: never.
	public float breakForce = 0;
	/// Solver passes each step: more is firmer and costs more.
	[Range(1, 32)]
	public int32 iterations = 8;

	/// Sides of the tube drawn.
	const int Sides = 8;

	[CLink] static extern uint32 tn_rope_create(void* world, NativeConfig* config, float* positions, uint32 count, float* pinned, float* center);
	[CLink] static extern void* tn_rope_tie(void* world, uint32 bodyA, float* pointA, uint32 bodyB, float* pointB, float length);
	[CLink] static extern void tn_rope_untie(void* world, void* tie);
	[CLink] static extern float tn_rope_pull(void* tie, float step);
	[CLink] static extern bool tn_rope_wraps(void* world, uint32 bodyId, float* start, float* end, float clearance, uint32* first, uint32* last, float* places);
	[CLink] static extern void* tn_rope_tie_over(void* world, uint32 bodyA, float* pointA, float* fixedA, uint32 bodyB, float* pointB, float* fixedB, float length);
	[CLink] static extern void tn_rope_wind(void* world, uint32 bodyId, float* wind, float radius, float drag, float turbulence, float time, float step);
	[CLink] static extern uint32 tn_soft_read(void* world, uint32 bodyId, float* positions, float* velocities, uint32 capacity);
	[CLink] static extern void tn_soft_move_pinned(void* world, uint32 bodyId, uint32* indices, float* targets, uint32 count, float step);
	[CLink] static extern void tn_soft_ignore(void* world, uint32 bodyId, uint32 ignoredBody);
	[CLink] static extern void tn_soft_forget(void* world, uint32 bodyId);

	/// native/tallow_softbody.cpp's RopeConfig, in the same order.
	[CRepr]
	struct NativeConfig
	{
		public float mass, stretch, bend, damping, friction, restitution, gravityFactor, radius;
		public int32 iterations;
		public uint32 layer;
		public uint64 userData;
	}

	uint32 mBody = uint32.MaxValue;
	bool mReady;
	PhysicsWorld mWorld;
	// The tie that carries the pull between the ends' bodies, and where its ends were fixed in the world (a tie to
	// an object without a Rigidbody is to a point in the world, made again when the object moves).
	void* mTie;
	Vector3 mTiedStart, mTiedEnd;
	float mPull;
	float mStep;
	bool mLetGo;
	// Pulled past Break Force: it snaps after the step. The half its other end kept, once it has.
	bool mSnapping;
	Rope mSnappedOff;
	// Over what it wraps round: the first and last points touching it, where they were when the tie was made.
	bool mWrapped;
	uint32 mWrapFirst, mWrapLast;
	Vector3 mWrapStart, mWrapEnd;
	float mUnwrapping;
	// Where to lay it when it is made (LayAlong, Snap), instead of hanging between its ends.
	List<Vector3> mSeed = new .() ~ delete _;
	// Where each end is tied on its object (Start/End Offset, or the surface point found for a zero offset).
	Vector3 mStartAnchor, mEndAnchor;
	float mKnotPull;
	// Seconds of wind it has had, steps added up: what the flutter goes by.
	float mWindTime;
	// Whether each end was tied to an object when the rope was made.
	bool mStartTied, mEndTied;
	uint32[2] mHeld;
	int mHeldCount;
	List<Vector3> mPositions = new .() ~ delete _;
	List<float> mTargets = new .() ~ delete _;
	Mesh mMesh ~ delete _;

	/// The rope's body id in the physics world, or uint32.MaxValue before it is made.
	public uint32 BodyId => mBody;
	public bool HasBody => mBody != uint32.MaxValue;
	/// Where each point along it is now, in the world, from this end to the other.
	public List<Vector3> Points => mPositions;
	/// How hard it pulled on what it is tied to in the last step, in newtons (0 while slack or not tied to a body).
	public float Pull => mPull;
	/// Whether it is pulled tight: the ends as far apart as the rope is long (round what it wraps, with Wraps Around).
	public bool IsTaut => HasBody && endAttachedTo != null && StartHeld && (mPull > 0.01f || (EndPoint - StartPoint).Length >= length * 0.99f);
	/// Whether the pull goes round something now (Wraps Around).
	public bool IsWrapped => mWrapped;
	/// After it snapped (Break Force, Snap): the half that stayed on its other end.
	public Rope SnappedOff => mSnappedOff;

	/// Where it starts, in the world.
	public Vector3 StartPoint => (StartHeld || mPositions.IsEmpty) ? StartObject.TransformPoint(HasBody ? mStartAnchor : startOffset) : mPositions[0];
	/// What its first end is on.
	Transform StartObject => startAttachedTo ?? Transform;
	/// Where its other end is tied, in the world (where it hangs, if it is free).
	public Vector3 EndPoint => endAttachedTo != null ? endAttachedTo.TransformPoint(HasBody ? mEndAnchor : endOffset) : (mPositions.IsEmpty ? StartPoint - Vector3(0, length, 0) : mPositions.Back);

	public override void Start()
	{
		mReady = true;
		CreateBody();
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

	/// Ties a new rope between two objects: towing (a truck and a trailer) or lifting (a helicopter and a crate). The
	/// offsets are where on each it is tied, relative to it. Length below zero: as far apart as they are now, plus a
	/// little slack. The rope is an object of its own; destroy it (or call Release) to let go. On a client of a
	/// session it returns null: the server ties it (when this player controls one of the two), on every machine.
	public static Rope Attach(GameObject from, GameObject to, Vector3 fromOffset = .Zero, Vector3 toOffset = .Zero, float length = -1, float thickness = 0.04f)
	{
		let apart = (to.Transform.TransformPoint(toOffset) - from.Transform.TransformPoint(fromOffset)).Length;
		let tied = length >= 0 ? length : Math.Max(apart * 1.05f, 0.1f);
		if (NetworkSync.RopeTieRequest(from, to, fromOffset, toOffset, tied, thickness))
			return null;
		let rope = Tie(from, to, fromOffset, toOffset, tied, thickness);
		NetworkSync.RopeChanged(rope, .Tie);
		return rope;
	}

	/// Attach on this machine alone.
	static Rope Tie(GameObject from, GameObject to, Vector3 fromOffset, Vector3 toOffset, float length, float thickness)
	{
		let holder = from.Scene.CreateGameObject("Rope");
		let rope = holder.AddComponent<Rope>();
		rope.startAttachedTo = from.Transform;
		rope.startOffset = fromOffset;
		rope.endAttachedTo = to.Transform;
		rope.endOffset = toOffset;
		rope.thickness = thickness;
		rope.length = length;
		if (from.Scene.IsPlaying)
			rope.Start();
		return rope;
	}

	/// Ties its first end to an object (any object: a player, a vehicle, a crate), or to nothing: it lets go and
	/// that end hangs free. Keeps its length.
	public void AttachStart(Transform to, Vector3 offset = .Zero)
	{
		if (NetworkSync.RopeRequest(this, .TieStart, to, offset))
			return;
		NetworkSync.RopeChanged(this, .TieStart, to, offset);
		startAttachedTo = to;
		startOffset = offset;
		holdStart = to != null;
		if (HasBody)
			Rebuild();
	}

	/// Ties its other end to an object, or to nothing (it lets go and that end hangs free). Keeps its length.
	public void AttachEnd(Transform to, Vector3 offset = .Zero)
	{
		if (NetworkSync.RopeRequest(this, .TieEnd, to, offset))
			return;
		NetworkSync.RopeChanged(this, .TieEnd, to, offset);
		endAttachedTo = to;
		endOffset = offset;
		if (HasBody)
			Rebuild();
	}

	/// Lets go of what its other end holds.
	public void Release() => AttachEnd(null);

	/// Lays the rope along a path (points in the world, from its start to its end), as long as the path is: over a
	/// beam, round a post, along a wall. The ends stay tied as they are; it is made again there now if it runs.
	public void LayAlong(Span<Vector3> path)
	{
		if (path.Length < 2 || NetworkSync.RopeRequest(this, .LayAlong, null, .Zero, path))
			return;
		NetworkSync.RopeChanged(this, .LayAlong, null, .Zero, path);
		float total = 0;
		for (int i = 1; i < path.Length; i++)
			total += (path[i] - path[i - 1]).Length;
		if (total < 1.0e-4f)
			return;
		length = total;
		let count = Math.Clamp(segments > 0 ? (int)segments : (int)Math.Round(length / 0.1f), 2, 256) + 1;
		// The same distance between each point, walking the path.
		mSeed.Clear();
		int leg = 1;
		float legStart = 0;
		for (int i < count)
		{
			let at = total * i / (float)(count - 1);
			while (leg < path.Length - 1 && legStart + (path[leg] - path[leg - 1]).Length < at)
			{
				legStart += (path[leg] - path[leg - 1]).Length;
				leg++;
			}
			let legLength = Math.Max((path[leg] - path[leg - 1]).Length, 1.0e-6f);
			mSeed.Add(Vector3.Lerp(path[leg - 1], path[leg], Mathf.Clamp01((at - legStart) / legLength)));
		}
		if (HasBody)
			Rebuild();
	}

	/// Snaps it in two in the middle, as Break Force does: this rope keeps its first end, and a new one (returned,
	/// and in SnappedOff) keeps the other. Both halves hang from what held them, or fall if nothing did. In a session
	/// the server snaps it on every machine; on a client it returns null.
	public Rope Snap()
	{
		mSnapping = false;
		if (!HasBody || NetworkSync.RopeRequest(this, .Snap))
			return null;
		let other = SnapHere();
		if (other != null)
			NetworkSync.RopeChanged(this, .Snap);
		return other;
	}

	/// Snap on this machine alone.
	Rope SnapHere()
	{
		let count = mPositions.Count;
		if (tn_soft_read(mWorld.[Friend]mSystem, mBody, (float*)mPositions.Ptr, null, (uint32)count) != (uint32)count || count < 5)
			return null;
		let middle = count / 2;
		let share = middle / (float)(count - 1);

		let holder = Scene.CreateGameObject("Rope (snapped)");
		let other = holder.AddComponent<Rope>();
		other.length = length * (1 - share);
		other.mass = mass * (1 - share);
		other.segments = (int32)(count - 1 - middle);
		other.thickness = thickness;
		other.bendStiffness = bendStiffness;
		other.damping = damping;
		other.friction = friction;
		other.windDrag = windDrag;
		other.wrapsAround = wrapsAround;
		other.breakForce = breakForce;
		other.iterations = iterations;
		other.startAttachedTo = endAttachedTo;
		other.startOffset = endOffset;
		other.holdStart = endAttachedTo != null;
		for (int i = count - 1; i >= middle; i--)
			other.mSeed.Add(mPositions[i]);
		let renderer = GetComponent<MeshRenderer>();
		if (renderer != null)
		{
			let drawn = holder.AddComponent<MeshRenderer>();
			drawn.color = renderer.color;
			drawn.roughness = renderer.roughness;
			drawn.material.Set(renderer.material);
			drawn.texture.Set(renderer.texture);
		}

		length *= share;
		mass *= share;
		segments = (int32)middle;
		endAttachedTo = null;
		for (int i <= middle)
			mSeed.Add(mPositions[i]);
		Rebuild();
		if (Scene.IsPlaying)
			other.Start();
		mSnappedOff = other;
		return other;
	}

	/// Whether its first end is held by something.
	bool StartHeld => startAttachedTo != null || holdStart;

	/// Makes the rope again from its fields (after changing them while it runs), hanging between its ends.
	public void Rebuild()
	{
		DestroyBody();
		CreateBody();
	}

	/// The point on an object's surface (its Box Collider, or its mesh's bounds) facing a point in the world, relative to
	/// the object; zero when it has neither.
	static Vector3 SurfaceToward(Transform on, Vector3 toward)
	{
		var centre = Vector3.Zero;
		var half = Vector3.Zero;
		if (let collider = on.GameObject.GetComponent<BoxCollider>())
		{
			centre = collider.center;
			half = collider.size * 0.5f;
		}
		else if (let mesh = on.GameObject.GetComponent<MeshRenderer>()?.ActiveMesh)
		{
			centre = mesh.Bounds.Center;
			half = mesh.Bounds.Size * 0.5f;
		}
		if (half == .Zero)
			return .Zero;
		let direction = on.InverseTransformPoint(toward) - centre;
		// How far along the direction the box's nearest face is.
		float reach = float.MaxValue;
		for (int axis < 3)
		{
			let d = Math.Abs(direction[axis]);
			if (d > 1.0e-6f)
				reach = Math.Min(reach, half[axis] / d);
		}
		return reach == float.MaxValue ? centre : centre + direction * reach;
	}

	/// The knot at one end, before a step: a dynamic body there is turned towards lying in line with the rope (where
	/// it is tied, on the far side of its centre from the rope), and its spin about the rope is slowed. Only as much as
	/// the rope pulls: a slack rope steers nothing.
	void TurnByKnot(Rigidbody body, Vector3 tied, Vector3 along)
	{
		if (body == null || body.isKinematic || knotStiffness <= 0 || along.LengthSquared < 1.0e-8f)
			return;
		let taut = Mathf.Clamp01(mKnotPull / Math.Max(body.mass * 9.81f, 0.001f));
		if (taut <= 0.01f)
			return;
		let rope = along.Normalized;
		let centre = body.Transform.Position;
		var arm = tied - centre;
		let reach = Math.Max(arm.Length, 0.1f);
		let spin = body.AngularVelocity;
		let weight = body.mass * 9.81f;
		// Tied off its centre, the rope's pull already turns it; the knot adds stiffness and calms it. Tied at its
		// centre, the knot is all that keeps it from spinning freely.
		var torque = -spin * (knotStiffness * body.mass * reach * reach * 4);
		if (arm.LengthSquared > 1.0e-6f)
			torque = torque + Vector3.Cross(arm.Normalized, rope) * (knotStiffness * weight * reach * 2);
		// Spin about the rope itself is held back harder: a knot does not let it twist round and round.
		torque = torque - rope * (Vector3.Dot(spin, rope) * knotStiffness * body.mass * reach * reach * 8);
		body.AddTorque(torque * taut);
	}

	/// A dynamic Rigidbody on an object or above it: what a rope's end pulls on.
	static Rigidbody PulledBody(Transform at)
	{
		for (var up = at; up != null; up = up.Parent)
		{
			if (let body = up.GameObject.GetComponent<Rigidbody>())
			{
				body.EnsureBody();
				return body.HasBody ? body : null;
			}
		}
		return null;
	}

	void CreateBody()
	{
		if (mBody != uint32.MaxValue)
			return;
		let world = Scene.Physics;
		world.[Friend]EnsureCreated();
		let system = world.[Friend]mSystem;
		if (system == null)
			return;
		let tied = endAttachedTo != null;
		// Each end on its object's surface facing the other (or, with nothing at the other end, facing down the rope
		// hanging from it; facing up from a rope that hangs from nothing else).
		let startCentre = StartObject.Position;
		let endCentre = tied ? endAttachedTo.Position : startCentre - Vector3(0, length, 0);
		mStartAnchor = (startOffset != .Zero || !StartHeld) ? startOffset : SurfaceToward(StartObject, tied ? endCentre : startCentre - Vector3(0, 1, 0));
		mEndAnchor = (!tied || endOffset != .Zero) ? endOffset : SurfaceToward(endAttachedTo, StartHeld ? StartObject.TransformPoint(mStartAnchor) : endCentre + Vector3(0, 1, 0));
		let count = mSeed.Count >= 3 ? mSeed.Count : Math.Clamp(segments > 0 ? (int)segments : (int)Math.Round(length / 0.1f), 2, 256) + 1;
		if (mSeed.Count >= 3)
		{
			mPositions.Set(mSeed);
			mSeed.Clear();
		}
		else if (StartHeld || !tied)
		{
			let start = StartObject.TransformPoint(mStartAnchor);
			LayOut(start, tied ? EndPoint : start - Vector3(0, length, 0), length, count, mPositions);
		}
		else
		{
			// Held only at its far end: hanging down from there.
			let end = EndPoint;
			LayOut(end, end - Vector3(0, length, 0), length, count, mPositions);
			for (int i < mPositions.Count / 2)
				Swap!(mPositions[i], mPositions[mPositions.Count - 1 - i]);
		}

		var center = Vector3.Zero;
		for (let p in mPositions)
			center = center + p;
		center = center / mPositions.Count;
		let positions = scope List<float>(count * 3);
		for (let p in mPositions)
		{
			positions.Add(p.x - center.x);
			positions.Add(p.y - center.y);
			positions.Add(p.z - center.z);
		}
		let pinned = scope List<float>();
		pinned.Resize(count);
		mHeldCount = 0;
		if (StartHeld)
		{
			pinned[0] = 1;
			mHeld[mHeldCount++] = 0;
		}
		if (tied)
		{
			pinned[count - 1] = 1;
			mHeld[mHeldCount++] = (uint32)(count - 1);
		}

		NativeConfig config = default;
		config.mass = Math.Max(mass, 0.001f);
		config.stretch = 1.0e-7f;
		// Compliance (how far a bend gives under force) from 1 (limp) to 1e-4 (a stiff cable).
		config.bend = Math.Pow(10.0f, -4.0f * Mathf.Clamp01(bendStiffness));
		config.damping = damping;
		config.friction = friction;
		config.restitution = 0;
		config.gravityFactor = 1;
		config.radius = Math.Max(thickness * 0.5f, 0.001f);
		config.iterations = Math.Clamp(iterations, 1, 32);
		config.layer = PhysicsWorld.[Friend]ObjectLayer(PhysicsWorld.[Friend]LayerMoving, Transform);
		config.userData = (uint64)GameObject.Id;
		mBody = tn_rope_create(system, &config, positions.Ptr, (uint32)count, pinned.Ptr, (float*)&center);
		if (mBody == uint32.MaxValue)
			return;
		mWorld = world;
		world.[Friend]AddRope(this);
		mStartTied = startAttachedTo != null;
		mEndTied = tied;

		// It does not catch on what its ends are tied to.
		let startBody = PulledBody(StartObject);
		let endBody = tied ? PulledBody(endAttachedTo) : null;
		if (startBody != null)
			tn_soft_ignore(system, mBody, startBody.BodyId);
		if (endBody != null && endBody != startBody)
			tn_soft_ignore(system, mBody, endBody.BodyId);

		var renderer = GetComponent<MeshRenderer>();
		if (renderer == null)
			renderer = GameObject.AddComponent<MeshRenderer>();
		delete mMesh;
		mMesh = new Mesh();
		mMesh.Name.Set("Rope");
		BuildTube();
		mMesh.UploadDynamic();
		renderer.RuntimeMesh = mMesh;
	}

	void DestroyBody()
	{
		if (mWorld != null)
		{
			let system = mWorld.[Friend]mSystem;
			if (mTie != null)
				tn_rope_untie(system, mTie);
			if (mBody != uint32.MaxValue)
			{
				tn_soft_forget(system, mBody);
				mWorld.[Friend]RemoveRope(this);
			}
		}
		mTie = null;
		mWrapped = false;
		mBody = uint32.MaxValue;
		mWorld = null;
		mPull = 0;
		let renderer = GetComponent<MeshRenderer>();
		if (renderer != null && renderer.RuntimeMesh == mMesh)
			renderer.RuntimeMesh = null;
	}

	/// Points from start towards end along a rope `length` long: hanging between them in a curve as long as the
	/// rope, or, when they are further apart than that, a straight line from start as far towards end as it reaches.
	public static void LayOut(Vector3 start, Vector3 end, float length, int count, List<Vector3> output)
	{
		output.Clear();
		let span = (end - start).Length;
		if (span >= length)
		{
			let toward = span > 1.0e-6f ? (end - start) / span : Vector3(0, -1, 0);
			for (int i < count)
				output.Add(start + toward * (length * i / (float)(count - 1)));
			return;
		}
		// The sag that makes a parabola through both ends as long as the rope.
		float sag = 0;
		if (span < length * 0.999f)
		{
			float low = 0, high = length;
			for (int i < 40)
			{
				sag = (low + high) * 0.5f;
				if (CurveLength(start, end, sag, 64) < length)
					low = sag;
				else
					high = sag;
			}
		}
		for (int i < count)
			output.Add(CurvePoint(start, end, sag, i / (float)(count - 1)));
	}

	static Vector3 CurvePoint(Vector3 start, Vector3 end, float sag, float t)
	{
		return Vector3.Lerp(start, end, t) - Vector3(0, sag * 4 * t * (1 - t), 0);
	}

	static float CurveLength(Vector3 start, Vector3 end, float sag, int steps)
	{
		float total = 0;
		var previous = start;
		for (int i = 1; i <= steps; i++)
		{
			let p = CurvePoint(start, end, sag, i / (float)steps);
			total += (p - previous).Length;
			previous = p;
		}
		return total;
	}

	/// Before each physics step: the ends go where their objects hold them, and the pull is tied between their
	/// bodies.
	void BeforeStep(float step)
	{
		if (mBody == uint32.MaxValue || mWorld == null)
			return;
		let system = mWorld.[Friend]mSystem;
		mStep = step;
		if (LetsGo())
			return;
		let start = StartPoint;
		let end = EndPoint;
		mTargets.Clear();
		for (int i < mHeldCount)
		{
			let p = mHeld[i] == 0 ? start : end;
			mTargets.Add(p.x);
			mTargets.Add(p.y);
			mTargets.Add(p.z);
		}
		if (mHeldCount > 0)
			tn_soft_move_pinned(system, mBody, &mHeld, mTargets.Ptr, (uint32)mHeldCount, step);
		mPull = mTie != null ? tn_rope_pull(mTie, step) : 0;
		// The pull the knots go by: it drops out for a step whenever the tie is made again, so it is held a moment.
		mKnotPull = Math.Max(mPull, mKnotPull * Math.Max(1 - step * 8, 0));
		// In a session the server decides when it breaks.
		if (breakForce > 0 && mPull > breakForce && !NetworkSync.IsClientOf(Scene))
			mSnapping = true;
		if (windDrag > 0)
		{
			var wind = Wind.At(Scene, StartPoint) * SoftBody.[Friend]WindSpeed;
			if (wind.LengthSquared > 0.0001f)
			{
				mWindTime += step;
				tn_rope_wind(system, mBody, (float*)&wind, Math.Max(thickness * 0.5f, 0.001f), windDrag, Wind.Turbulence(Scene), mWindTime + (float)(GameObject.Id % 97), step);
			}
		}

		// The pull: needed when both ends are held and either is on a dynamic Rigidbody.
		if (endAttachedTo == null || !StartHeld)
		{
			if (mTie != null)
			{
				tn_rope_untie(system, mTie);
				mTie = null;
			}
			return;
		}
		let startBody = PulledBody(StartObject);
		let endBody = PulledBody(endAttachedTo);
		// The knots: each end's body turned by the rope's direction where it leaves it.
		if (knotStiffness > 0 && mPositions.Count >= 2)
		{
			let count = mPositions.Count;
			uint32 read = tn_soft_read(system, mBody, (float*)mPositions.Ptr, null, (uint32)count);
			if (read == (uint32)count)
			{
				TurnByKnot(startBody, start, mPositions[Math.Min(2, count - 1)] - start);
				if (endBody != startBody)
					TurnByKnot(endBody, end, mPositions[Math.Max(count - 3, 0)] - end);
			}
		}
		let startPulls = startBody != null && !startBody.isKinematic;
		let endPulls = endBody != null && !endBody.isKinematic;
		if (!startPulls && !endPulls)
		{
			if (mTie != null)
			{
				tn_rope_untie(system, mTie);
				mTie = null;
			}
			return;
		}
		// A tie to the world (or to a kinematic body) is made again when that end has moved, and one round what it
		// wraps when that has changed.
		var moved = (startBody == null && (start - mTiedStart).LengthSquared > 1.0e-4f) || (endBody == null && (end - mTiedEnd).LengthSquared > 1.0e-4f);
		var from = start;
		var to = end;
		uint32 first = 0, last = 0;
		Vector3[2] places = default;
		var wrapped = wrapsAround && tn_rope_wraps(system, mBody, (float*)&from, (float*)&to, Math.Max(thickness, 0.01f) + 0.03f, &first, &last, (float*)&places);
		// Contacts come and go from step to step as the rope settles: it only comes off what it wraps round after a
		// moment without touching it.
		if (wrapped)
			mUnwrapping = 0;
		else if (mWrapped && wrapsAround && (mUnwrapping += step) < 0.25f)
		{
			wrapped = true;
			first = mWrapFirst;
			last = mWrapLast;
			places[0] = mWrapStart;
			places[1] = mWrapEnd;
		}
		if (wrapped != mWrapped)
			moved = true;
		else if (wrapped && (first != mWrapFirst || last != mWrapLast || (places[0] - mWrapStart).LengthSquared > 4.0e-4f || (places[1] - mWrapEnd).LengthSquared > 4.0e-4f))
			moved = true;
		if (mTie != null && !moved)
			return;
		if (mTie != null)
			tn_rope_untie(system, mTie);
		let startId = startBody?.BodyId ?? uint32.MaxValue;
		let endId = endBody?.BodyId ?? uint32.MaxValue;
		if (wrapped)
		{
			// The rope between the first and last points it wraps round is fixed; the rest is shared by the two ends.
			// The tie goes tight a little before the rope itself does (it sags, and bends round corners), so the
			// ends never pull the rope through what it lies over.
			let between = length * (last - first) / (float)(mPositions.Count - 1);
			let slack = length * 0.04f + thickness * 4;
			mTie = tn_rope_tie_over(system, startId, (float*)&from, (float*)&places[0], endId, (float*)&to, (float*)&places[1], Math.Max(length - between - slack, 0.01f));
			mWrapFirst = first;
			mWrapLast = last;
			mWrapStart = places[0];
			mWrapEnd = places[1];
		}
		else
			mTie = tn_rope_tie(system, startId, (float*)&from, endId, (float*)&to, length);
		mWrapped = wrapped;
		mTiedStart = start;
		mTiedEnd = end;
	}

	/// Whether what an end was tied to is being destroyed or gone (the scene empties reference fields to deleted
	/// objects): that end lets go, and the rope is made again after the step, not while the world steps.
	bool LetsGo()
	{
		if (mEndTied && (endAttachedTo == null || endAttachedTo.GameObject.IsDestroyed))
		{
			endAttachedTo = null;
			mLetGo = true;
		}
		if (mStartTied && (startAttachedTo == null || startAttachedTo.GameObject.IsDestroyed))
		{
			startAttachedTo = null;
			holdStart = false;
			mLetGo = true;
		}
		return mLetGo;
	}

	public override void LateUpdate()
	{
		if (LetsGo())
		{
			mLetGo = false;
			Rebuild();
		}
		if (mSnapping)
			Snap();
		ReadBack();
	}

	/// The simulation's points into Points and the tube drawn.
	void ReadBack()
	{
		if (mBody == uint32.MaxValue || mWorld == null || mMesh == null)
			return;
		let count = mPositions.Count;
		let read = tn_soft_read(mWorld.[Friend]mSystem, mBody, (float*)mPositions.Ptr, null, (uint32)count);
		if (read != (uint32)count)
			return;
		BuildTube();
		mMesh.UpdateDynamic();
	}

	/// A tube round the points, in this object's space: a ring of Sides vertices at each point, turned along the
	/// rope (each ring's frame carried from the last, so the tube does not twist).
	void BuildTube()
	{
		let toLocal = Transform.WorldToLocal;
		let count = mPositions.Count;
		let radius = thickness * 0.5f;
		mMesh.Vertices.Clear();
		mMesh.Indices.Clear();
		var side = Vector3(1, 0, 0);
		for (int i < count)
		{
			let along = (mPositions[Math.Min(i + 1, count - 1)] - mPositions[Math.Max(i - 1, 0)]).Normalized;
			// Keep the frame at right angles to the rope, as close as it can be to the last one.
			side = (side - along * Vector3.Dot(side, along));
			if (side.LengthSquared < 1.0e-8f)
				side = Vector3.Cross(along, Math.Abs(along.y) < 0.9f ? Vector3.Up : Vector3(1, 0, 0));
			side = side.Normalized;
			let up = Vector3.Cross(along, side);
			for (int k < Sides)
			{
				let angle = k * Math.PI_f * 2 / Sides;
				let normal = side * Math.Cos(angle) + up * Math.Sin(angle);
				let world = mPositions[i] + normal * radius;
				mMesh.AddVertex(toLocal.TransformPoint(world), toLocal.TransformDirection(normal).Normalized, .White, .(k / (float)Sides, i / (float)(count - 1)));
			}
		}
		for (int i < count - 1)
		{
			for (int k < Sides)
			{
				let a = (uint32)(i * Sides + k), b = (uint32)(i * Sides + (k + 1) % Sides);
				let c = a + (uint32)Sides, d = b + (uint32)Sides;
				mMesh.AddTriangle(a, c, b);
				mMesh.AddTriangle(b, c, d);
			}
		}
		mMesh.RecalculateBounds();
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected || HasBody)
			return;
		// Before it runs: where it will hang.
		let points = scope List<Vector3>();
		let start = StartPoint;
		LayOut(start, endAttachedTo != null ? EndPoint : start - Vector3(0, length, 0), length, 24, points);
		for (int i = 1; i < points.Count; i++)
			DebugDraw.Line(points[i - 1], points[i], .(0.9f, 0.75f, 0.4f, 1));
	}
}
