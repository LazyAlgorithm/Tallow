using System;

namespace Tallow;

/// What Component.OnCollisionEnter and OnCollisionExit are told about the other object.
public struct Collision
{
	/// The other object (null in OnCollisionExit when it was destroyed).
	public GameObject gameObject;
	/// Where they first touched, in world space (zero on exit).
	public Vector3 point;
	/// The contact normal pointing out of the other object, towards this one (zero on exit).
	public Vector3 normal;
	/// How fast they were closing along the normal when they touched, in metres a second (zero on exit).
	public float relativeSpeed;
}

/// What Component.OnControllerHit is told: something a CharacterController ran into while moving.
public struct ControllerHit
{
	/// What was hit (null when it has no object, such as a terrain chunk's body).
	public GameObject gameObject;
	/// Where, in world space.
	public Vector3 point;
	/// Out of what was hit, towards the character (up for flat ground).
	public Vector3 normal;
	/// The velocity the character was asked to move at.
	public Vector3 moveVelocity;
}
