// Generated fixture, refreshed by --generate-graph-fixture before the CI compile check.
using System;
using Tallow;

namespace EcsBench;

[Component]
class GeneratedTickProbe : Script
{
	[Sync] public float tickDelta = 0;
	public int32 steps = 7;

	public override void Update(TickInput input, float deltaTime)
	{
		tickDelta = deltaTime;
	}
}
