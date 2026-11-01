using System;
using System.Collections;
using System.IO;
using Tallow;
using Tallow.Editor;

namespace GraphApiTests;

/// Visual scripting nodes are generated from the engine's source. This writes every generated node out as Beef
/// (to the path given as the first argument) so the whole set can be compiled, and checks a few graphs by hand.
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static void EngineRoot(String output, String file = Compiler.CallerFilePath)
	{
		var path = (StringView)file;
		for (int i < 4)
		{
			let slash = path.LastIndexOf('/');
			if (slash > 0)
				path = path.Substring(0, slash);
		}
		output.Set(path);
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		let root = scope String();
		EngineRoot(root);
		ApiIndex.Build(root, "");
		let defs = NodeLibrary.Defs;
		int api = NodeLibrary.ApiNodeCount;
		ok &= Check(api > 1500, scope $"{api} nodes were generated from the engine's source ({defs.Count} in all)");
		bool Has(StringView key) => NodeLibrary.Find(key) != null;
		ok &= Check(Has("api:AudioSource.Play/0") && Has("api:AudioSource.volume") && Has("api:AudioSource.volume=") && Has("api:Audio.Hrtf=") && Has("api:VoiceChat.Enabled=") && Has("api:VoiceChat.Mute/2"), "audio and voice chat have nodes");
		ok &= Check(Has("api:CharacterController.SimpleMove/3") && Has("api:NavigationAgent.SetDestination/3") && Has("api:Achievements.Unlock/1") && Has("api:SpawnPoints.Next/2") && Has("api:Transform.Position") && Has("api:Rigidbody.<get>") && Has("api:Light.<add>"), "so do movement, navigation, achievements, spawn points, transforms and components");
		ok &= Check(Has("api:InputActions.Pressed/1") && Has("api:InputActions.Held/1") && Has("api:InputActions.Value/1") && Has("api:InputActions.Vector/1") && Has("api:InputActions.Delta/1") && Has("api:InputActions.SetMapEnabled/2")
			&& Has("api:Gamepad.GetButton/2") && Has("api:Gamepad.GetButtonDown/2") && Has("api:Gamepad.LeftStick") && Has("api:Gamepad.RightTrigger") && Has("api:Gamepad.Rumble/4") && Has("api:Input.UsingGamepad"), "input actions and controllers have nodes");
		ok &= Check(Has("net.tick") && Has("net.event") && Has("net.send") && Has("flow.for") && Has("flow.while") && Has("input.key") && Has("event.gui"), "network, loop, key and event nodes exist");

		// ---- every generated node, as code ----
		if (args.Count > 0)
		{
			let all = scope String();
			all.Append("using System;\nusing Tallow;\nnamespace GraphProbe;\nclass AllNodes : Component\n{\n");
			int index = 0;
			for (let def in defs)
			{
				if (!def.fromApi)
					continue;
				let graph = scope NodeGraph();
				let node = graph.AddNode(def, .(0, 0));
				graph.Validate();
				all.AppendF("\t// {}\n\tvoid N{}()\n\t{{\n", def.key, index++);
				if (def.kind == .Value)
				{
					all.Append("\t\tvar value = ");
					graph.ExpressionOf(node, 0, all);
					all.Append(";\n");
				}
				else
					graph.StatementOf(node, all, 2);
				all.Append("\t}\n");
			}
			all.Append("}\n");
			File.WriteAllText(args[0], all).IgnoreError();
			Console.WriteLine(scope $"INFO: wrote {index} nodes to {args[0]}");
		}

		// ---- a graph by hand: cast a ray, and if it hits something with a light, turn the light red ----
		{
			let graph = scope NodeGraph();
			let start = graph.AddNode(NodeLibrary.Find("event.update"), .(0, 0));
			// Five inputs: the object, origin, direction, distance and layer mask (the hit is an output).
			let rayDef = NodeLibrary.Find("api:PhysicsWorld.Raycast/5");
			let ray = rayDef != null ? graph.AddNode(rayDef, .(200, 0)) : null;
			ok &= Check(ray != null, "Physics.Raycast has a node with its out parameter as an output");
			if (ray != null)
			{
				let branch = graph.AddNode(NodeLibrary.Find("flow.branch"), .(400, 0));
				let hitObject = graph.AddNode(NodeLibrary.Find("api:RaycastHit.gameObject"), .(400, 100));
				let getLight = graph.AddNode(NodeLibrary.Find("api:Light.<get>"), .(600, 100));
				let setColor = graph.AddNode(NodeLibrary.Find("api:Light.color="), .(800, 0));
				let loop = graph.AddNode(NodeLibrary.Find("flow.for"), .(1000, 0));
				let log = graph.AddNode(NodeLibrary.Find("debug.lognumber"), .(1200, 0));
				graph.Validate();
				graph.Connect(start.id, 0, ray.id, 0);
				graph.Connect(ray.id, 0, branch.id, 0);
				graph.Connect(ray.id, 1, branch.id, 1); // Result -> Condition
				int32 hitPin = -1;
				for (int32 i < (int32)ray.def.outputs.Count)
				{
					if (ray.def.outputs[i].typeName != null && ray.def.outputs[i].typeName == "RaycastHit")
						hitPin = i;
				}
				graph.Connect(ray.id, hitPin, hitObject.id, 0); // hit -> RaycastHit target
				graph.Connect(hitObject.id, 0, getLight.id, 0); // its object -> Get Light
				graph.Connect(branch.id, 0, setColor.id, 0);
				graph.Connect(getLight.id, 0, setColor.id, 1); // light -> target
				setColor.values[2].Set("1 0 0 1");
				graph.Connect(setColor.id, 0, loop.id, 0);
				loop.values[1].Set("1");
				loop.values[2].Set("3");
				graph.Connect(loop.id, 0, log.id, 0);
				graph.Connect(loop.id, 1, log.id, 2); // whole-number index -> number pin
				let code = scope String();
				graph.Compile("Game", "RayLight", "RayLight.tgraph", code);
				ok &= Check(code.Contains("class RayLight : Component") && code.Contains("bool r") && code.Contains("RaycastHit o") && code.Contains("out o") && code.Contains(".GetComponent<Light>()") && code.Contains("Color(1f, 0f, 0f, 1f)") && code.Contains("for (int32 i") && code.Contains("(float)(i"), "a ray cast, a component lookup, a property set and a loop compile to the expected code");
				if (args.Count > 1)
					File.WriteAllText(args[1], code).IgnoreError();
			}
		}
		// ---- a network script without thinking about it ----
		{
			let graph = scope NodeGraph();
			let tick = graph.AddNode(NodeLibrary.Find("net.tick"), .(0, 0));
			let move = graph.AddNode(NodeLibrary.Find("api:CharacterController.SimpleMove/3"), .(200, 0));
			let scale = graph.AddNode(NodeLibrary.Find("math.vscale"), .(100, 100));
			let event = graph.AddNode(NodeLibrary.Find("net.event"), .(0, 300));
			let send = graph.AddNode(NodeLibrary.Find("net.send"), .(400, 0));
			let play = graph.AddNode(NodeLibrary.Find("api:AudioSource.Play/0"), .(200, 300));
			graph.Validate();
			graph.AddVariable("speed", .Float).networked = true;
			graph.Connect(tick.id, 0, move.id, 0);
			graph.Connect(tick.id, 3, scale.id, 0); // Move Direction
			scale.values[1].Set("5");
			graph.Connect(scale.id, 0, move.id, 2);
			graph.Connect(tick.id, 1, move.id, 3); // Delta Time
			graph.Connect(move.id, 0, send.id, 0);
			send.values[1].Set("stepped");
			event.values[0].Set("stepped");
			graph.Connect(event.id, 0, play.id, 0);
			let code = scope String();
			graph.Compile("Game", "Walker", "Walker.tgraph", code);
			ok &= Check(code.Contains("class Walker : NetworkScript") && code.Contains("public override void OnTick(TickInput input, float deltaTime)") && code.Contains("GetComponent<CharacterController>().SimpleMove((input.MoveDirection * 5f), deltaTime") && code.Contains("[Sync] public float speed"), "using On Tick turns the graph into a Network Script: input, prediction and synced variables with no extra setup");
			ok &= Check(code.Contains("NetworkSync.SendEvent(this, \"stepped\"") && code.Contains("public override void OnNetworkEvent(StringView name, float value)") && code.Contains("if (name == \"stepped\")") && code.Contains("GetComponent<AudioSource>().Play();"), "network events are sent and received by name");
			if (args.Count > 2)
				File.WriteAllText(args[2], code).IgnoreError();
		}
		return ok ? 0 : 1;
	}
}
