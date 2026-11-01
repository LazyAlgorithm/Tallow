using System;

namespace Tallow;

[Reflect(.All)]
enum CharacterShape : int32
{
	Capsule,
	Box
}

/// Moves an object through the world by sweeping a shape, using Jolt's virtual character: it climbs steps, stays on
/// slopes up to a limit, follows the floor downhill and pushes dynamic bodies. It replaces a Rigidbody and collider on
/// anything that walks.
///
/// The controller only moves when a script tells it to, once per fixed tick:
///
///   controller.SimpleMove(direction * speed, Time.FixedDeltaTime, jumpPressed ? 6 : 0);   // gravity handled for you
///   controller.Move(velocity, Time.FixedDeltaTime);                                         // full control
///
/// A Capsule slides around obstacles most smoothly. A Box matches crates and furniture; Edge Radius rounds its edges
/// so it does not catch on seams and small lips. The box stays axis-aligned unless Turn Shape With Object is on,
/// because turning a long box next to a wall can push a corner into the wall.
[Component]
class CharacterController : Component
{
	public CharacterShape shape = .Capsule;
	/// Capsule: radius and total height, tips included.
	public float radius = 0.35f;
	public float height = 1.8f;
	/// Box: full width, height and depth.
	public Vector3 boxSize = .(0.8f, 1.0f, 0.8f);
	/// Box: how far its edges and corners are rounded.
	public float edgeRadius = 0.1f;
	/// Middle of the shape relative to the object's origin. Use (0, height / 2, 0) when the origin is at the feet.
	public Vector3 center;
	/// Tallest step it walks up, and how far it follows the floor down.
	public float stepHeight = 0.4f;
	/// Steepest slope, in degrees, it can stand and walk on.
	public float maxSlope = 50;
	public float mass = 70;
	/// Force, in newtons, it can push dynamic bodies with.
	public float pushStrength = 100;
	/// Multiplies the scene's gravity in SimpleMove.
	public float gravityScale = 1;
	/// Turn the collision shape with the object's rotation. Leave off for boxes unless they are square.
	public bool turnShapeWithObject;
	/// Seconds after leaving the ground during which a jump is still allowed. It covers the few ticks a rounded
	/// shape spends rolling over the edge of a step, and forgives a jump pressed just past a ledge.
	public float jumpGrace = 0.12f;
	/// Other soft characters ease this one aside instead of stopping against it like a wall. Turn off for a
	/// character that should be a solid obstacle. Call ApplyShape after changing it while playing.
	public bool softCharacterContact = true;
	/// How quickly overlapping soft characters are separated, in metres per second for each metre of overlap.
	public float separationSpeed = 8;
	/// Swims in Water deeper than Swim Depth instead of walking on the bottom: SimpleMove floats it with its head out
	/// of the water, slows it and lets the current carry it, and a jump swims up (and out, at an edge).
	public bool canSwim = true;
	/// How deep the water has to be over its feet for it to swim, in metres.
	public float swimDepth = 1.2f;
	/// Swimming speed as a share of the speed SimpleMove or Swim is given.
	[Range(0, 2)]
	public float swimSpeed = 0.6f;

	void* mCharacter;
	Jolt.CharacterState mState;
	Vector3 mLastPosition;
	Quaternion mLastRotation = .Identity;
	bool mReady;
	// How far past a step's edge to look for footing: the rounded part of the bottom has to clear the edge.
	float mStepReach = 0.15f;
	// Size of the shape as last described, for the push between characters.
	float mPushRadius, mHalfHeight;
	Vector3 mShapeCenter;
	bool mSoft;
	float mAirTime;
	bool mSwimming;
	int32 mSwimTick = int32.MinValue / 2;
	// How far below the surface the feet float, worked out when swimming begins.
	float mFloatDepth;

	/// False in edit mode and while disabled; Move then just shifts the transform.
	public bool HasCharacter => mCharacter != null && Scene.Physics.HasCharacter(mCharacter);
	public bool IsGrounded => HasCharacter && mState.groundState == 0;
	/// Grounded, or airborne for no longer than Jump Grace without having jumped. SimpleMove uses this to decide
	/// whether a jump is allowed; use it for anything else that should not flicker on step edges.
	public bool CanJump => HasCharacter && mAirTime <= jumpGrace;
	/// Seconds since it last stood on the ground; 0 while grounded.
	public float AirTime => mAirTime;
	/// Touching ground that is steeper than Max Slope.
	public bool IsOnSteepGround => HasCharacter && mState.groundState == 1;
	/// Velocity after the last move, so it already reflects walls and floors that stopped it.
	public Vector3 Velocity => mState.velocity;
	public Vector3 GroundNormal => mState.groundNormal;
	/// Velocity of whatever it stands on, for example a moving platform.
	public Vector3 GroundVelocity => mState.groundVelocity;
	/// Swimming: as of the last SimpleMove or Swim, or, for a character nothing moves here (another player's, in a
	/// network session), whether it is in water deeper than swimDepth. For animations.
	public bool IsSwimming => (Time.Tick - mSwimTick <= 2) ? mSwimming : InDeepWater(0);

	/// Whether the water over the feet is deeper than swimDepth less slack.
	bool InDeepWater(float slack)
	{
		if (!canSwim || Scene == null)
			return false;
		let middle = Transform.Position + center;
		let half = shape == .Capsule ? height * 0.5f : boxSize.y * 0.5f;
		let water = Water.At(Scene, middle, half);
		if (water == null)
			return false;
		float surface;
		Vector3 current;
		return water.SurfaceAt(middle, out surface, ?, out current) && surface - (middle.y - half) >= swimDepth - slack;
	}

	public override void Start()
	{
		mReady = true;
		Create(.Zero);
	}

	public override void OnEnable()
	{
		if (mReady)
			Create(.Zero);
	}

	public override void OnDisable()
	{
		Destroy();
	}

	public override void OnDestroy()
	{
		mReady = false;
	}

	Vector3 WorldScale
	{
		get
		{
			Vector3 position, scale;
			Quaternion rotation;
			Transform.LocalToWorld.Decompose(out position, out rotation, out scale);
			return Vector3.Abs(scale);
		}
	}

	/// The shape as configured, in world units, and the height above the origin below which a contact is the floor.
	ShapeDesc Describe(out float supportHeight)
	{
		let scale = WorldScale;
		ShapeDesc desc = default;
		desc.center = center * scale;
		float halfHeight, rounding;
		if (shape == .Box)
		{
			desc.kind = .Box;
			desc.halfExtents = Vector3.Max(boxSize * scale * 0.5f, .(0.02f));
			let smallest = Math.Min(desc.halfExtents.x, Math.Min(desc.halfExtents.y, desc.halfExtents.z));
			rounding = Mathf.Clamp(edgeRadius, 0.005f, smallest);
			desc.convexRadius = rounding;
			halfHeight = desc.halfExtents.y;
			mPushRadius = (desc.halfExtents.x + desc.halfExtents.z) * 0.5f;
		}
		else
		{
			desc.kind = .Capsule;
			rounding = Math.Max(radius * Math.Max(scale.x, scale.z), 0.02f);
			halfHeight = Math.Max(height * scale.y * 0.5f, rounding + 0.01f);
			desc.radius = rounding;
			desc.halfHeight = halfHeight - rounding;
			mPushRadius = rounding;
		}
		// Anything touching the rounded part of the bottom supports the character. That includes the edge of a step it
		// has half climbed, which is what lets it keep stepping instead of dropping back.
		supportHeight = desc.center.y - halfHeight + Math.Max(rounding, 0.05f);
		mStepReach = rounding;
		mHalfHeight = halfHeight;
		mShapeCenter = desc.center;
		return desc;
	}

	Quaternion ShapeRotation => turnShapeWithObject ? Transform.Rotation : Quaternion.Identity;

	bool Create(Vector3 velocity)
	{
		if (HasCharacter)
			return true;
		let desc = Describe(let supportHeight);
		mSoft = softCharacterContact;
		mCharacter = Scene.Physics.CreateCharacter(Transform, desc, ShapeRotation, maxSlope, mass, pushStrength, supportHeight, mSoft);
		if (mCharacter == null)
		{
			Log.Warning(scope $"CharacterController on '{GameObject.Name}' could not create its shape.");
			return false;
		}
		Scene.Physics.Controllers.Add(this);
		if (velocity != .Zero)
			Scene.Physics.SetCharacterState(mCharacter, Transform.Position, ShapeRotation, velocity, mSoft);
		mState = Scene.Physics.GetCharacterState(mCharacter);
		mAirTime = mState.groundState == 0 ? 0 : float.MaxValue;
		mLastPosition = Transform.Position;
		mLastRotation = ShapeRotation;
		return true;
	}

	void Destroy()
	{
		if (mCharacter != null)
		{
			Scene.Physics.Controllers.Remove(this);
			Scene.Physics.DestroyCharacter(mCharacter);
		}
		mCharacter = null;
		mState = default;
	}

	/// Carries a transform that something else moved (a script, the network, the editor) into the character.
	void Sync()
	{
		let rotation = ShapeRotation;
		if ((Transform.Position - mLastPosition).LengthSquared < 1.0e-10f && Math.Abs(Quaternion.Dot(rotation, mLastRotation)) > 0.999999f)
			return;
		Scene.Physics.SetCharacterState(mCharacter, Transform.Position, rotation, mState.velocity, mSoft);
		mState = Scene.Physics.GetCharacterState(mCharacter);
		mLastPosition = Transform.Position;
		mLastRotation = rotation;
	}

	/// Velocity that eases this character out of other soft characters it overlaps. The heavier one moves less.
	Vector3 Separation()
	{
		var push = Vector3.Zero;
		if (!mSoft)
			return push;
		let mine = Transform.Position + mShapeCenter;
		for (let other in Scene.Physics.Controllers)
		{
			if (other == this || !other.mSoft || !other.HasCharacter)
				continue;
			let theirs = other.Transform.Position + other.mShapeCenter;
			if (Math.Abs(mine.y - theirs.y) >= mHalfHeight + other.mHalfHeight)
				continue;
			var away = Vector3(mine.x - theirs.x, 0, mine.z - theirs.z);
			let distance = away.Length;
			let overlap = mPushRadius + other.mPushRadius - distance;
			if (overlap <= 0)
				continue;
			// Standing exactly inside each other gives no direction; the two then part along X, the same way on every machine.
			away = distance > 0.0001f ? away / distance : Vector3(GameObject.Id > other.GameObject.Id ? 1 : -1, 0, 0);
			push += away * (overlap * separationSpeed * other.mass / Math.Max(mass + other.mass, 0.001f));
		}
		let limit = 4.0f;
		return push.LengthSquared > limit * limit ? push.Normalized * limit : push;
	}

	/// Moves for one step at exactly this velocity. Gravity is not added; use SimpleMove for a walking character.
	public void Move(Vector3 velocity, float deltaTime)
	{
		if (!HasCharacter)
		{
			Transform.Position += velocity * deltaTime;
			return;
		}
		Sync();
		let push = Separation();
		mState = Scene.Physics.MoveCharacter(mCharacter, velocity + push, deltaTime, stepHeight, mStepReach, mSoft);
		// Being nudged aside is not this character's own speed; leaving it in would make the next step build on it.
		mState.velocity -= push;
		Transform.Position = mState.position;
		mLastPosition = Transform.Position;
		if (mState.groundState == 0)
			mAirTime = 0;
		else if (mAirTime < 1000)
			mAirTime += deltaTime;
	}

	/// Walks at the given horizontal velocity for one step. Falling speed and gravity are kept for you, the character
	/// rides whatever it stands on, and a jumpSpeed above zero jumps if it is on the ground.
	public void SimpleMove(Vector3 horizontalVelocity, float deltaTime, float jumpSpeed = 0)
	{
		if (UpdateSwimming(horizontalVelocity, deltaTime, jumpSpeed, false))
			return;
		Vector3 velocity;
		// "Moving towards the ground" keeps a character that has just jumped from being glued back down.
		if (IsGrounded && mState.velocity.y - mState.groundVelocity.y < 0.1f)
		{
			velocity = mState.groundVelocity;
			if (jumpSpeed > 0)
			{
				velocity.y += jumpSpeed;
				mAirTime = float.MaxValue;
			}
		}
		else if (jumpSpeed > 0 && mAirTime <= jumpGrace)
		{
			// Just off the ground without having jumped: on the lip of a step, or a moment past a ledge.
			velocity = .(0, jumpSpeed, 0);
			mAirTime = float.MaxValue;
		}
		else
			velocity = .(0, mState.velocity.y, 0);
		velocity += Scene.Physics.Gravity * (gravityScale * deltaTime);
		velocity.x += horizontalVelocity.x;
		velocity.z += horizontalVelocity.z;
		Move(velocity, deltaTime);
	}

	/// Swims at a velocity in any direction, for diving and coming up (towards where the player looks, say); with no
	/// up or down in it the character floats to the surface. Out of deep water it walks as SimpleMove does, with the
	/// level part of the velocity.
	public void Swim(Vector3 velocity, float deltaTime, float jumpSpeed = 0)
	{
		if (!UpdateSwimming(velocity, deltaTime, jumpSpeed, true))
			SimpleMove(.(velocity.x, 0, velocity.z), deltaTime, jumpSpeed);
	}

	/// In water deeper than swimDepth over the feet (or nearly, once swimming): moves for one step as a swimmer and
	/// returns true. The water is found by the waves' simulation clock, so a predicting client and the server agree.
	bool UpdateSwimming(Vector3 wanted, float deltaTime, float jumpSpeed, bool dive)
	{
		let wasSwimming = mSwimming;
		mSwimming = false;
		mSwimTick = Time.Tick;
		if (!canSwim || !HasCharacter)
			return false;
		let middle = Transform.Position + center;
		let half = shape == .Capsule ? height * 0.5f : boxSize.y * 0.5f;
		let water = Water.At(Scene, middle, half);
		if (water == null)
			return false;
		float surface;
		Vector3 current;
		if (!water.SurfaceAt(middle, out surface, ?, out current))
			return false;
		let deep = surface - (middle.y - half);
		// Once swimming it keeps on while touching bottom a little shallower, so it does not flick between the two.
		if (deep < (wasSwimming ? swimDepth - 0.25f : swimDepth))
			return false;
		mSwimming = true;
		// Floating: the feet hang this far down, leaving the head out of the water.
		mFloatDepth = Math.Max(half * 2 * 0.78f, swimDepth + 0.1f);
		var velocity = mState.velocity;
		var target = Vector3(wanted.x * swimSpeed + current.x, 0, wanted.z * swimSpeed + current.z);
		if (dive && Math.Abs(wanted.y) > 0.01f)
			target.y = wanted.y * swimSpeed;
		else
		{
			// Rises when deeper than floating and settles when not: the waves lift and drop it with them.
			target.y = Math.Clamp((deep - mFloatDepth) * 2.5f, -1.5f, 2.0f) + current.y * 0.5f;
			if (jumpSpeed > 0)
				target.y = deep < mFloatDepth + 0.4f ? jumpSpeed * 0.8f : Math.Max(target.y, 2.0f);
		}
		// The water holds it back: velocity eases towards what is wanted instead of jumping to it.
		let ease = 1 - Math.Exp(-4.0f * deltaTime);
		velocity += (target - velocity) * ease;
		if (dive && Math.Abs(wanted.y) <= 0.01f && deep > mFloatDepth + 0.5f)
			velocity.y = Math.Max(velocity.y, 0.6f);
		Move(velocity, deltaTime);
		// Leaving the water is not standing on ground: no jump comes free with it.
		mAirTime = jumpGrace + 0.01f;
		return true;
	}

	/// Puts the character somewhere with a given velocity, for respawns and for network corrections.
	/// airTime restores how long it had been off the ground; leave it out to work that out from where it lands.
	public void Teleport(Vector3 position, Vector3 velocity = .Zero, float airTime = -1)
	{
		Transform.Position = position;
		if (!HasCharacter)
			return;
		Scene.Physics.SetCharacterState(mCharacter, position, ShapeRotation, velocity, mSoft);
		mState = Scene.Physics.GetCharacterState(mCharacter);
		mLastPosition = Transform.Position;
		mLastRotation = ShapeRotation;
		mAirTime = airTime >= 0 ? airTime : (mState.groundState == 0 ? 0 : float.MaxValue);
	}

	/// Applies the shape fields after changing them. Returns false, leaving the old shape in use, when the new shape
	/// does not fit where the character stands; maxPenetration is how much overlap is forgiven.
	public bool ApplyShape(float maxPenetration = 0.03f)
	{
		if (!HasCharacter)
			return true;
		Sync();
		let desc = Describe(let supportHeight);
		if (!Scene.Physics.TrySetCharacterShape(mCharacter, desc, maxPenetration, mSoft))
			return false;
		// The floor band depends on the shape, so the character is rebuilt around the shape that was just accepted.
		Rebuild();
		// In multiplayer the server decides and every machine follows; see NetworkSync.
		NetworkSync.ShapeChanged(this);
		return HasCharacter;
	}

	/// Makes the character again from the current fields, keeping its motion.
	void Rebuild()
	{
		let velocity = mState.velocity;
		let airTime = mAirTime;
		Destroy();
		if (Create(velocity))
			mAirTime = airTime;
	}

	/// Takes a shape decided on another machine, without asking whether it fits here: the server has already checked.
	public void ApplyRemoteShape(CharacterShape newShape, float newRadius, float newHeight, Vector3 newBoxSize, float newEdgeRadius, Vector3 newCenter)
	{
		if (shape == newShape && radius == newRadius && height == newHeight && boxSize == newBoxSize && edgeRadius == newEdgeRadius && center == newCenter)
			return;
		shape = newShape;
		radius = newRadius;
		height = newHeight;
		boxSize = newBoxSize;
		edgeRadius = newEdgeRadius;
		center = newCenter;
		if (HasCharacter)
			Rebuild();
	}

	/// Becomes a capsule of this size if it fits here. On false nothing changes.
	public bool SetCapsule(float newRadius, float newHeight, Vector3 newCenter = .Zero)
	{
		let old = (shape, radius, height, center);
		shape = .Capsule;
		radius = newRadius;
		height = newHeight;
		center = newCenter;
		if (ApplyShape())
			return true;
		(shape, radius, height, center) = old;
		return false;
	}

	/// Becomes a box of this size if it fits here. On false nothing changes.
	public bool SetBox(Vector3 newSize, float newEdgeRadius = 0.1f, Vector3 newCenter = .Zero)
	{
		let old = (shape, boxSize, edgeRadius, center);
		shape = .Box;
		boxSize = newSize;
		edgeRadius = newEdgeRadius;
		center = newCenter;
		if (ApplyShape())
			return true;
		(shape, boxSize, edgeRadius, center) = old;
		return false;
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected)
			return;
		let color = Color(0.5f, 1, 0.5f, 1);
		let desc = Describe(let supportHeight);
		let middle = Transform.Position + desc.center;
		if (shape == .Box)
		{
			let matrix = Matrix4.TRS(middle, ShapeRotation, .One);
			Gizmos.Lines.Box(.(-desc.halfExtents, desc.halfExtents), matrix, color);
			return;
		}
		let top = middle + .(0, desc.halfHeight, 0);
		let bottom = middle - .(0, desc.halfHeight, 0);
		Gizmos.Lines.Sphere(top, desc.radius, color);
		Gizmos.Lines.Sphere(bottom, desc.radius, color);
		for (let side in Vector3[?](.(desc.radius, 0, 0), .(-desc.radius, 0, 0), .(0, 0, desc.radius), .(0, 0, -desc.radius)))
			Gizmos.Lines.Line(top + side, bottom + side, color);
	}
}
