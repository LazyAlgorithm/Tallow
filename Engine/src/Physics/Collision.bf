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
