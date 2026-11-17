// Generated from Bobber.tgraph by the Tallow graph compiler.
// Edit the graph and compile it again; changes made here are overwritten.
using System;
using Tallow;

namespace EcsBench.Graphs;

[Component]
class Bobber : Script
{
	public override void Update(TickInput input, float deltaTime)
	{
		Transform.Translate(Vector3(0f, (Math.Sin((Time.Time * 2f)) * deltaTime), 0f));
		Transform.Rotate(Vector3(0f, (deltaTime * 45f), 0f));
	}

}
