// Generated from GraphOrder.tgraph by the Tallow graph compiler.
// Edit the graph and compile it again; changes made here are overwritten.
using System;
using Tallow;

namespace EcsBench.Graphs;

[Component]
class GraphOrder : Script
{
	bool doOnce8 = false;
	bool doOnce11 = false;

	public override void Awake()
	{
		base.Awake();
		Log.Info("GRAPHORDER awake");
	}

	public override void OnEnable()
	{
		base.OnEnable();
		Log.Info("GRAPHORDER enable");
	}

	public override void Start()
	{
		base.Start();
		Log.Info("GRAPHORDER start");
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (!doOnce8)
		{
			doOnce8 = true;
			Log.Info("GRAPHORDER update");
		}
	}

	public override void LateUpdate(TickInput input, float deltaTime)
	{
		if (!doOnce11)
		{
			doOnce11 = true;
			Log.Info("GRAPHORDER late");
		}
	}

}
