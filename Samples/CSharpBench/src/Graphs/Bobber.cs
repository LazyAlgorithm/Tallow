// Generated from Bobber.tgraph by the Tallow graph compiler.
// Edit the graph and compile it again; changes made here are overwritten.
using System;
using System.Numerics;
using Tallow;

namespace CSharpBench.Graphs;

public partial class Bobber : Script
{
	public override void Update(TickInput input, float deltaTime)
	{
		Transform.Translate(new Vector3(0f, (MathF.Sin((Time.GameTime * 2f)) * deltaTime), 0f)); // #7
		Transform.Rotate(new Vector3(0f, (deltaTime * 45f), 0f)); // #10
	}

}
