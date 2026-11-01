using System;
using Tallow;

namespace Sandbox;

/// Example component: rotates its object. Public fields show up in the Inspector.
[Component]
class Spinner : Component
{
	public Vector3 degreesPerSecond = .(0, 45, 0);

	public override void Update()
	{
		Transform.Rotate(degreesPerSecond * Time.DeltaTime);
	}
}
