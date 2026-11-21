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
	public int bumped = 0;
	public float doubled = 0f;
	public int triggerEnters = 0;
	public int triggerStays = 0;
	public int triggerExits = 0;
	public int collisionEnters = 0;
	public int collisionStays = 0;
	public int collisionExits = 0;
	public GameObject contact;
	public Vector3 contactPoint = new Vector3(0f, 0f, 0f);
	public Vector3 contactNormal = new Vector3(0f, 0f, 0f);
	public float contactSpeed = 0f;

	public override void Start()
	{
		base.Start();
		turned = (GraphRuntime.Euler(0f, 90f, 0f) * new Vector3(0f, 0f, 1f)); // #3
		length = new Vector3(3f, 4f, 0f).Length(); // #5
		label = ("graph " + GraphRuntime.Text(7)); // #8
		self = (Scene.Find("Graph") ?? default); // #10
		{ var t18 = Transform; if (GraphRuntime.IsValid(t18)) t18.Position = new Vector3(1f, 2f, 3f); } // #18
		lerped = Tallow.Mathf.Lerp(0f, 10f, 0.25f); // #22
		doubled = Sub_Doubled(21f); // #28
	}

	public override void Update(TickInput input, float deltaTime)
	{
		frames = (frames + 1); // #14
		elapsed = (elapsed + deltaTime); // #17
		position = (Transform?.Position ?? default); // #20
	}

	public void Custom_Bump()
	{
		bumped = (bumped + 1); // #26
	}

	public void Custom_Heal()
	{
		Scene.Query<InGame.Health>().ForEach((EcsEntity ecsEntity30, ref InGame.Health ecsData30) => // #30
		{
			if (ecsEntity30.GameObject is not GameObject ecsObject30 || !ecsObject30.ActiveInHierarchy) return;
			{ var ecsEntity32 = ecsObject30.Entity; if (ecsEntity32.TryGet(out InGame.Health ecsSet32)) { ecsSet32.Value = (ecsData30.Value + 1f); ecsEntity32.Set(ecsSet32); } } // #32
		});
	}

	public override void OnTriggerEnter(GameObject other)
	{
		triggerEnters = (triggerEnters + 1); // #36
		contact = other; // #37
	}

	public override void OnTriggerStay(GameObject other)
	{
		triggerStays = (triggerStays + 1); // #41
	}

	public override void OnTriggerExit(GameObject other)
	{
		triggerExits = (triggerExits + 1); // #45
	}

	public override void OnCollisionEnter(Collision collision)
	{
		collisionEnters = (collisionEnters + 1); // #49
		contact = collision.GameObject; // #50
		contactPoint = collision.Point; // #51
		contactNormal = collision.Normal; // #52
		contactSpeed = collision.RelativeSpeed; // #53
	}

	public override void OnCollisionStay(Collision collision)
	{
		collisionStays = (collisionStays + 1); // #57
	}

	public override void OnCollisionExit(Collision collision)
	{
		collisionExits = (collisionExits + 1); // #61
	}

	float Sub_Doubled(float amount)
	{
		return (amount * 2f);
	}

}
