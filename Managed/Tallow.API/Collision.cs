using System.Numerics;

namespace Tallow;

/// <summary>What <see cref="Script.OnCollisionEnter"/> and <see cref="Script.OnCollisionExit"/> are told.</summary>
/// <param name="GameObject">The other object. Not valid on exit when it was destroyed.</param>
/// <param name="Point">Where they first touched, in world space (zero on exit).</param>
/// <param name="Normal">The contact normal, out of the other object towards this one (zero on exit).</param>
/// <param name="RelativeSpeed">Closing speed along the normal when they touched, in m/s (zero on exit).</param>
public readonly record struct Collision(GameObject GameObject, Vector3 Point, Vector3 Normal, float RelativeSpeed);

/// <summary>What <see cref="Script.OnControllerHit"/> is told: something this object's CharacterController ran into.</summary>
/// <param name="GameObject">What was hit (not valid for bodies without an object).</param>
/// <param name="Point">Where, in world space.</param>
/// <param name="Normal">Out of what was hit, towards the character (up for flat ground).</param>
/// <param name="MoveSpeed">How fast the character was asked to move, in m/s.</param>
public readonly record struct ControllerHit(GameObject GameObject, Vector3 Point, Vector3 Normal, float MoveSpeed);
