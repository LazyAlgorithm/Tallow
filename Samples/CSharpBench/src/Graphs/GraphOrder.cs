// Generated from GraphOrder.tgraph by the Tallow graph compiler.
// Edit the graph and compile it again; changes made here are overwritten.
using System;
using System.Numerics;
using Tallow;

namespace CSharpBench.Graphs;

public partial class GraphOrder : Script
{
	bool doOnce8 = false;
	bool doOnce11 = false;

	public override void Awake()
	{
		base.Awake();
		Log.Info("GRAPHORDER awake"); // #2
	}

	public override void OnEnable()
	{
		base.OnEnable();
		Log.Info("GRAPHORDER enable"); // #4
	}

	public override void Start()
	{
		base.Start();
		Log.Info("GRAPHORDER start"); // #6
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (!doOnce8)
		{
			doOnce8 = true;
			Log.Info("GRAPHORDER update"); // #9
		}
	}

	public override void LateUpdate(TickInput input, float deltaTime)
	{
		if (!doOnce11)
		{
			doOnce11 = true;
			Log.Info("GRAPHORDER late"); // #12
		}
	}

}
