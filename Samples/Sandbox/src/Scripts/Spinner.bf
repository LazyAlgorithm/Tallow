using System;
using Tallow;

namespace Sandbox;

/// Example component: rotates its object. Public fields show up in the Inspector.
[Component]
class Spinner : Script
{
	public Vector3 degreesPerSecond = .(0, 45, 0);

	public override void Update(TickInput input, float deltaTime)
	{
		Transform.Rotate(degreesPerSecond * Time.DeltaTime);
	}
}
