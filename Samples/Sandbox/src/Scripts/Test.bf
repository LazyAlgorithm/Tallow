using System;
using Tallow;

namespace Sandbox;

[Component]
class Test : Script
{
	public float speed = 1.0f;
	public ParticleSystem particalSystem;

	public override void Start()
	{
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (Input.GetKeyDown(.Space))
		{
			particalSystem.Enabled = !particalSystem.Enabled;
		}
	}
}
