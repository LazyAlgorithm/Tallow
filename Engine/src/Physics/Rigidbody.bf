using System;
using System.Collections;

namespace Tallow;

/// Makes the object a simulated body. Needs a Collider on the same GameObject.
[Component]
class Rigidbody : Component
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

	uint32 mBody = uint32.MaxValue;

	/// The body's id in the physics world, for PhysicsWorld calls; uint32.MaxValue when there is none.
	public uint32 BodyId => mBody;
	/// Whether the body is in the physics world (it is while the scene plays).
	public bool HasBody => mBody != uint32.MaxValue;

	bool mReady;

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

	/// Creates the body now if it does not exist yet (normally this happens in Start).
	public void EnsureBody()
	{
		mReady = true;
		CreateBody();
	}

	void CreateBody()
	{
		if (mBody != uint32.MaxValue)
			return;
		let collider = GetComponent<Collider>();
		if (collider == null)
		{
			Log.Warning(scope $"Rigidbody on '{GameObject.Name}' has no Collider and will not simulate.");
			return;
		}
		mBody = Scene.Physics.CreateBody(Transform, collider.GetShape(), this);
	}

	public override void OnDestroy()
	{
		mReady = false;
	}

	/// Recreates the body after its collider changed size, keeping position and velocity.
	public void RebuildBody()
	{
		if (!HasBody)
		{
			if (mReady)
				CreateBody();
			return;
		}
		let state = State;
		OnDisable();
		CreateBody();
		if (HasBody)
			SetState(state);
	}

	public override void OnDisable()
	{
		if (mBody != uint32.MaxValue)
		{
			Scene.Physics.DestroyBody(mBody);
			mBody = uint32.MaxValue;
		}
	}

	/// How fast the body moves, in metres a second, in the world.
	public Vector3 Velocity
	{
		get => Scene.Physics.GetLinearVelocity(mBody);
		set
		{
			Scene.Physics.SetLinearVelocity(mBody, value);
		}
	}

	/// How fast the body spins, in radians a second about each world axis.
	public Vector3 AngularVelocity
	{
		get => Scene.Physics.GetAngularVelocity(mBody);
		set
		{
			Scene.Physics.SetAngularVelocity(mBody, value);
		}
	}

	/// Pushes the body by a force (in newtons) through its centre, over the next physics step.
	public void AddForce(Vector3 force) => Scene.Physics.AddForce(mBody, force);
	/// Turns the body by a torque (newton metres about each world axis), over the next physics step.
	public void AddTorque(Vector3 torque) => Scene.Physics.AddTorque(mBody, torque);
	/// Pushes the body by a force at a point in the world, which also turns it.
	public void AddForceAtPosition(Vector3 force, Vector3 worldPoint) => Scene.Physics.AddForceAtPosition(mBody, force, worldPoint);
	/// How fast a point of the body is moving, its spin included.
	public Vector3 GetPointVelocity(Vector3 worldPoint) => Scene.Physics.GetPointVelocity(mBody, worldPoint);
	/// Changes the body's momentum at once (a hit, a jump), through its centre.
	public void AddImpulse(Vector3 impulse) => Scene.Physics.AddImpulse(mBody, impulse);
	/// Sleep until disturbed by physics; the body stays dynamic and collision-enabled.
	public void Sleep() => Scene.Physics.Sleep(mBody);
	/// Whether the body is resting and not being simulated.
	public bool IsSleeping => HasBody && Scene.Physics.IsSleeping(mBody);
	/// The body's position, rotation and velocities, to save or send and put back with SetState.
	public BodyState State => Scene.Physics.GetState(mBody);
	/// Puts the body back in a state from State.
	public void SetState(BodyState state) => Scene.Physics.SetState(mBody, state);
}
