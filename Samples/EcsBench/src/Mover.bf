using System;
using Tallow;

namespace EcsBench;

/// The GameObject version: one component per cube, run by the scene's Update like any game script.
[Component]
class Mover : Component
{
	public Vector3 velocity;
	public Vector3 spin;
	public float halfSize = 10;

	public override void Update(TickInput input, float deltaTime)
	{
		var position = Transform.LocalPosition;
		Workload.Step(ref position, ref velocity, halfSize, deltaTime);
		Transform.LocalPosition = position;
		Transform.Rotate(spin * deltaTime);
	}
}
