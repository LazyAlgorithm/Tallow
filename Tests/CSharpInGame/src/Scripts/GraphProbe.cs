// Generated from GraphProbe.tgraph by the Tallow graph compiler.
// Edit the graph and compile it again; changes made here are overwritten.
using System;
using System.Numerics;
using Tallow;

namespace InGame;

public partial class GraphProbe : Script
{
	public int frames = 0;
	public float elapsed = 0f;
	public Vector3 turned = new Vector3(0f, 0f, 0f);
	public float length = 0f;
	public string label = "";
	public GameObject self;

	public override void Start()
	{
		base.Start();
		turned = (GraphRuntime.Euler(0f, 90f, 0f) * new Vector3(0f, 0f, 1f));
		length = new Vector3(3f, 4f, 0f).Length();
		label = ("graph " + GraphRuntime.Text(7));
		self = (Scene.Find("Graph") ?? default);
	}

	public override void Update(TickInput input, float deltaTime)
	{
		frames = (frames + 1);
		elapsed = (elapsed + deltaTime);
	}

}
