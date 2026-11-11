using System;
using System.Collections;

namespace Tallow;

/// A Rigidbody's settings, in its entity (Rigidbody is the handle).
[Component, HandleData]
struct RigidbodyData
{
	/// The body's mass, in kilograms.
	public float mass = 1.0f;
	/// Whether gravity pulls the body.
	public bool useGravity = true;
	/// Multiplies scene gravity for this body; useGravity=false still disables gravity.
	[Range(0, 10)]
	public float gravityScale = 1;
	/// Moved only by its transform or code, never by forces or collisions: it pushes other bodies but is not pushed
	/// (moving platforms, doors).
	public bool isKinematic = false;
	/// How much the body grips what it slides on: 0 is ice.
	[Range(0, 2)]
	public float friction = 0.5f;
	/// How much of its speed the body keeps when it hits something: 0 does not bounce, 1 bounces back as fast.
	[Range(0, 1)]
	public float bounciness = 0.0f;
	/// How quickly the body slows down on its own, as if through air.
	public float linearDamping = 0.05f;
	/// How quickly the body stops spinning on its own.
	public float angularDamping = 0.05f;
	/// Keeps the body from turning (characters that should stay upright).
	public bool freezeRotation = false;
	/// Checks the body's whole path each step, so that something fast does not pass through thin walls. Costs more.
	public bool continuousCollision = false;
	/// Lets the body stop being simulated while it lies still, until something touches it.
	public bool allowSleeping = true;
	/// Debris rests on scenery and is drawn like anything else, but nothing that moves is stopped by it: characters
	/// and other bodies pass through, and rays and shape queries ignore it. For corpses, dropped items, rubble.
	public bool debris = false;

	public this() { }
}

/// Makes the object a simulated body. Needs a Collider on the same GameObject.
///
/// A handle (ComponentHandle): its settings are RigidbodyData's fields; its body in the physics world is kept in
/// RigidbodyState. The body is made once the scene plays and the component is switched on and its object active
/// (Rigidbody.SyncAll, after the Starts of each frame and tick), and taken out of the world when it is switched off,
/// its object made inactive, the component removed or play stopped, as Start, OnEnable and OnDisable did.
[Component, HandleFields]
struct Rigidbody : ComponentHandle<RigidbodyData>
{
	RigidbodyState Runtime
	{
		get
		{
			CheckValid();
			let state = ComponentState<RigidbodyState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			state.scene = mGameObject.Scene;
			state.gameObject = mGameObject;
			return state;
		}
	}

	/// The body's id in the physics world, for PhysicsWorld calls; uint32.MaxValue when there is none.
	public uint32 BodyId
	{
		get
		{
			if (!IsValid)
				return uint32.MaxValue;
			let state = ComponentState<RigidbodyState>.Get(mGameObject.Scene.World, mGameObject.Entity);
			return state != null ? state.body : uint32.MaxValue;
		}
	}

	/// Whether the body is in the physics world (it is while the scene plays).
	public bool HasBody => BodyId != uint32.MaxValue;

	/// Creates the body now if it does not exist yet (normally the next SyncAll does).
	public void EnsureBody()
	{
		Runtime.ready = true;
		CreateBody();
	}

	void CreateBody()
	{
		let state = Runtime;
		if (state.body != uint32.MaxValue)
			return;
		let collider = mGameObject.GetComponent<Collider>();
		if (collider == null)
		{
			if (!state.warned)
				Log.Warning(scope $"Rigidbody on '{mGameObject.Name}' has no Collider and will not simulate.");
			state.warned = true;
			return;
		}
		state.body = mGameObject.Scene.Physics.CreateBody(Transform, collider.GetShape(), &Data);
	}

	void DestroyBody()
	{
		let state = ComponentState<RigidbodyState>.Get(mGameObject.Scene.World, mGameObject.Entity);
		if (state != null)
			state.DestroyBody();
	}

	/// Recreates the body after its collider changed size, keeping position and velocity.
	public void RebuildBody()
	{
		if (!HasBody)
		{
			if (Runtime.ready)
				CreateBody();
			return;
		}
		let state = State;
		DestroyBody();
		CreateBody();
		if (HasBody)
			SetState(state);
	}

	/// Makes and takes away bodies to match the components (the scene calls it after running Starts): a switched-on
	/// Rigidbody on an active object has a body while the scene plays; any other has none.
	public static void SyncAll(Scene scene)
	{
		let playing = scene.IsPlaying;
		// Bodies that should go: switched off, object inactive, or the scene stopped.
		for (let (entity, state) in ComponentState<RigidbodyState>.In(scene.World, .. scope .()))
		{
			if (state.body == uint32.MaxValue)
			{
				if (!playing)
					state.ready = false;
				continue;
			}
			let gameObject = state.gameObject;
			let body = gameObject.GetComponent<Rigidbody>();
			if (!playing || !body || !body.enabled || !gameObject.ActiveInHierarchy)
				state.DestroyBody();
			if (!playing)
				state.ready = false;
		}
		if (!playing)
			return;
		for (let body in scene.Components<Rigidbody>(.. scope .()))
		{
			if (!body.GameObject.ActiveInHierarchy || body.HasBody)
				continue;
			body.Runtime.ready = true;
			body.CreateBody();
		}
	}

	static void OnRemove(void* world, uint64 entity) => ComponentState<RigidbodyState>.Release(world, entity);

	/// Switched off while playing: the body leaves the physics world at once, as OnDisable did. Waiting for the next
	/// SyncAll is too late for a network replay, which runs ticks without it: a body switched off by a restored state
	/// would go on being simulated through the replayed ticks. Switched on, it is made at the next SyncAll (or by
	/// EnsureBody).
	static void OnSwitched(GameObject gameObject, bool on)
	{
		if (on)
			return;
		if (let state = ComponentState<RigidbodyState>.Get(gameObject.Scene.World, gameObject.Entity))
			state.DestroyBody();
	}

	/// How fast the body moves, in metres a second, in the world.
	public Vector3 Velocity
	{
		get => HasBody ? Scene.Physics.GetLinearVelocity(BodyId) : .Zero;
		set
		{
			if (HasBody)
				Scene.Physics.SetLinearVelocity(BodyId, value);
		}
	}

	/// How fast the body spins, in radians a second about each world axis.
	public Vector3 AngularVelocity
	{
		get => HasBody ? Scene.Physics.GetAngularVelocity(BodyId) : .Zero;
		set
		{
			if (HasBody)
				Scene.Physics.SetAngularVelocity(BodyId, value);
		}
	}

	/// Pushes the body by a force (in newtons) through its centre, over the next physics step.
	public void AddForce(Vector3 force) { if (HasBody) Scene.Physics.AddForce(BodyId, force); }
	/// Turns the body by a torque (newton metres about each world axis), over the next physics step.
	public void AddTorque(Vector3 torque) { if (HasBody) Scene.Physics.AddTorque(BodyId, torque); }
	/// Pushes the body by a force at a point in the world, which also turns it.
	public void AddForceAtPosition(Vector3 force, Vector3 worldPoint) { if (HasBody) Scene.Physics.AddForceAtPosition(BodyId, force, worldPoint); }
	/// How fast a point of the body is moving, its spin included.
	public Vector3 GetPointVelocity(Vector3 worldPoint) => HasBody ? Scene.Physics.GetPointVelocity(BodyId, worldPoint) : .Zero;
	/// Changes the body's momentum at once (a hit, a jump), through its centre.
	public void AddImpulse(Vector3 impulse) { if (HasBody) Scene.Physics.AddImpulse(BodyId, impulse); }
	/// Sleep until disturbed by physics; the body stays dynamic and collision-enabled.
	public void Sleep() { if (HasBody) Scene.Physics.Sleep(BodyId); }
	/// Whether the body is resting and not being simulated.
	public bool IsSleeping => HasBody && Scene.Physics.IsSleeping(BodyId);
	/// The body's position, rotation and velocities, to save or send and put back with SetState.
	public BodyState State => HasBody ? Scene.Physics.GetState(BodyId) : default;
	/// Puts the body back in a state from State.
	public void SetState(BodyState state) { if (HasBody) Scene.Physics.SetState(BodyId, state); }
}

/// What a Rigidbody keeps outside its data: its body in the scene's physics world.
class RigidbodyState
{
	public Scene scene;
	public GameObject gameObject;
	public uint32 body = uint32.MaxValue;
	/// Started: the scene plays and the body may be made.
	public bool ready;
	/// The missing-collider warning was given.
	public bool warned;

	public void DestroyBody()
	{
		if (body != uint32.MaxValue && scene?.Physics != null)
			scene.Physics.DestroyBody(body);
		body = uint32.MaxValue;
	}

	public ~this()
	{
		DestroyBody();
	}
}
