using System;
using Tallow;

namespace Sandbox;

[Component]
class Test : Component
{
	public float speed = 1.0f;
	public ParticleSystem particalSystem;

	public override void Start()
	{
	}

	public override void Update()
	{
		if (Input.GetKeyDown(.Space))
		{
			particalSystem.Enabled = !particalSystem.Enabled;
		}
	}
}
