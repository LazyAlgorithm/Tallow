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
	public Vector3 position = new Vector3(0f, 0f, 0f);
	public float lerped = 0f;

	public override void Start()
	{
		base.Start();
		turned = (GraphRuntime.Euler(0f, 90f, 0f) * new Vector3(0f, 0f, 1f)); // #3
		length = new Vector3(3f, 4f, 0f).Length(); // #5
		label = ("graph " + GraphRuntime.Text(7)); // #8
		self = (Scene.Find("Graph") ?? default); // #10
		{ var t18 = Transform; if (GraphRuntime.IsValid(t18)) t18.Position = new Vector3(1f, 2f, 3f); } // #18
		lerped = Tallow.Mathf.Lerp(0f, 10f, 0.25f); // #22
	}

	public override void Update(TickInput input, float deltaTime)
	{
		frames = (frames + 1); // #14
		elapsed = (elapsed + deltaTime); // #17
		position = (Transform?.Position ?? default); // #20
	}

}
