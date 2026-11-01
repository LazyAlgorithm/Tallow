using System;
using System.IO;
using Tallow;
using Tallow.Editor;

namespace GraphVariableTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	public static int Main(String[] args)
	{
		let root = "/tmp/tallow-graph-variable-test";
		Directory.CreateDirectory(root);
		let path = scope $"{root}/Mover.tgraph";
		let subPath = scope $"{root}/Boost.tgraph";
		defer
		{
			File.Delete(path);
			File.Delete(subPath);
			Directory.Delete(root);
		}
		Assets.ProjectPath.Set(root);

		// A subgraph that writes one variable the host declares and one only it knows about.
		let sub = scope NodeGraph();
		let entry = sub.AddNode(NodeLibrary.Find("sub.entry"), .Zero);
		let shared = sub.AddVariable("pace", .Float);
		shared.value.Set("99");
		let boosted = sub.AddVariable("boosted", .Bool);
		let setBoosted = sub.AddVariableNode(boosted, true, .Zero);
		setBoosted.values[2].Set("true");
		sub.Connect(entry.id, 0, setBoosted.id, 0);
		sub.Save(subPath);
		NodeLibrary.RefreshSubgraphs(root);

		let graph = scope NodeGraph();
		graph.name.Set("Mover");
		let speed = graph.AddVariable("speed", .Float);
		speed.value.Set("2.5");
		let label = graph.AddVariable("label", .String);
		label.value.Set("hello \"you\"");
		let home = graph.AddVariable("home", .Vector3);
		home.value.Set("1 2 3");
		home.networked = true;
		let duplicate = graph.AddVariable("speed", .Float);
		bool ok = Check(duplicate.name == "speed2" && graph.AddVariable("Transform", .Bool).name == "Transform2", "new variables get unique, unreserved names");
		ok &= Check(!graph.RenameVariable(duplicate, "speed") && !graph.RenameVariable(duplicate, "Update") && graph.RenameVariable(duplicate, "top speed") && duplicate.name == "top_speed", "rename rejects taken names and makes identifiers");

		let update = graph.AddNode(NodeLibrary.Find("event.update"), .Zero);
		let getSpeed = graph.AddVariableNode(speed, false, .Zero);
		let add = graph.AddNode(NodeLibrary.Find("math.add"), .Zero);
		add.values[1].Set("1");
		let setSpeed = graph.AddVariableNode(speed, true, .Zero);
		let setLabel = graph.AddVariableNode(label, true, .Zero);
		setLabel.values[2].Set("moving");
		let setHome = graph.AddVariableNode(home, true, .Zero);
		let position = graph.AddNode(NodeLibrary.Find("transform.position"), .Zero);
		let boost = graph.AddNode(NodeLibrary.Find("sub:Boost.tgraph"), .Zero);
		let print = graph.AddNode(NodeLibrary.Find("call:Tallow.GraphNodes.PrintNumber"), .Zero);
		ok &= Check(boost != null && print != null, "fixture nodes exist");
		if (!ok) return 1;
		graph.Connect(getSpeed.id, 0, add.id, 0);
		graph.Connect(add.id, 0, setSpeed.id, 2);
		graph.Connect(position.id, 0, setHome.id, 2);
		graph.Connect(getSpeed.id, 0, print.id, 1);
		graph.Connect(update.id, 0, setSpeed.id, 0);
		graph.Connect(setSpeed.id, 0, setLabel.id, 0);
		graph.Connect(setLabel.id, 0, setHome.id, 0);
		graph.Connect(setHome.id, 0, boost.id, 0);
		graph.Connect(boost.id, 0, print.id, 0);

		graph.RenameVariable(speed, "pace");
		ok &= Check(NodeGraph.VariableName(getSpeed) == "pace" && NodeGraph.VariableName(setSpeed) == "pace", "renaming a variable renames its nodes");
		graph.Save(path);
		let loaded = scope NodeGraph();
		ok &= Check(loaded.Load(path) && loaded.variables.Count == 5 && loaded.FindVariable("pace")?.value == "2.5" && loaded.FindVariable("label")?.value == "hello \"you\"" && loaded.FindVariable("home")?.type == .Vector3 && loaded.links.Count == graph.links.Count, "variables survive save and load");
		let code = scope String();
		loaded.Compile("Game", "Mover", "Mover.tgraph", code);
		if (args.Count == 1)
			File.WriteAllText(args[0], code).IgnoreError();
		ok &= Check(code.Contains("\tpublic float pace = 2.5f;\n") && code.Contains("\tpublic String label = new .(\"hello \\\"you\\\"\") ~ delete _;\n") && code.Contains("\t[Sync] public Vector3 home = Vector3(1f, 2f, 3f);\n") && loaded.FindVariable("home").networked && !loaded.FindVariable("pace").networked && code.Contains("\tpublic bool Transform2 = false;\n"), "variables compile to public fields with their defaults");
		ok &= Check(code.Contains("\t\tpace = (pace + 1f);\n") && code.Contains("\t\tlabel.Set(\"moving\");\n") && code.Contains("\t\thome = Transform.Position;\n") && code.Contains("PrintNumber(pace);"), "get and set nodes read and write the fields");
		ok &= Check(code.Contains("\tpublic bool boosted = false;\n") && code.Contains("\t\tboosted = true;\n") && code.IndexOf("public float pace", code.IndexOf("public float pace") + 1) == -1 && !code.Contains("99f"), "subgraph variables are declared once on the host");

		loaded.SetVariableType(loaded.FindVariable("pace"), .Vector3);
		bool retyped = true;
		int links = 0;
		for (let node in loaded.nodes)
		{
			if (node.def.key.StartsWith("var.") && NodeGraph.VariableName(node) == "pace")
				retyped &= node.def.key.EndsWith(".vector");
		}
		for (let link in loaded.links)
		{
			if (loaded.Find(link.fromNode).def.key.StartsWith("var.get.") || link.toPin == 2 && loaded.Find(link.toNode).def.key == "var.set.vector" && NodeGraph.VariableName(loaded.Find(link.toNode)) == "pace")
				links++;
		}
		ok &= Check(retyped && links == 0, "changing a variable's type retypes its nodes and drops mismatched links");
		let count = loaded.nodes.Count;
		loaded.RemoveVariable(loaded.FindVariable("pace"));
		ok &= Check(loaded.nodes.Count == count - 2 && loaded.FindVariable("pace") == null, "removing a variable removes its nodes");

		let orphan = scope NodeGraph();
		let start = orphan.AddNode(NodeLibrary.Find("event.start"), .Zero);
		let stray = orphan.AddNode(NodeLibrary.Find("var.set.float"), .Zero);
		stray.values[1].Set("score");
		stray.values[2].Set("3");
		orphan.Connect(start.id, 0, stray.id, 0);
		code.Clear();
		orphan.Compile("Game", "Orphan", "Orphan.tgraph", code);
		ok &= Check(code.Contains("\tpublic float score = 0f;\n") && code.Contains("\t\tscore = 3f;\n"), "an undeclared variable node still compiles");
		return ok ? 0 : 1;
	}
}
