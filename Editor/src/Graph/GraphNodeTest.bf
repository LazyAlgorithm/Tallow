using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Test switch --graph-node-test <text>: for every visual scripting node whose title has the text in it, makes a
/// graph of On Update and that node (its flow linked, its inputs left as they start), compiles it into
/// src/GraphNodeTest/GraphNodeTestN.bf and logs GRAPH-NODE-TEST lines. Build the project afterwards to see whether
/// each compiles. Its outputs go into Set Variable nodes, so value nodes' code is compiled too. "*" takes every
/// hand-written (not read from source) node.
extension EditorApp
{
	int32 mGraphNodeTestFrames = -1;

	void TickGraphNodeTest()
	{
		if (mGraphNodeTestFrames < 0)
		{
			mGraphNodeTestFrames = HasArg("--graph-node-test") ? 10 : 0;
			return;
		}
		if (mGraphNodeTestFrames > 0 && --mGraphNodeTestFrames == 0)
			RunGraphNodeTest();
	}

	void RunGraphNodeTest()
	{
		let text = scope String();
		GetArg("--graph-node-test", text);
		let folder = scope $"{Assets.ProjectPath}/GraphNodeTest";
		Directory.CreateDirectory(folder).IgnoreError();
		int count = 0;
		for (let def in NodeLibrary.Defs)
		{
			let all = text == "*";
			if ((all ? def.fromApi : !def.title.Contains(text, true)) || def.kind == .Event || def.isShader || def.kind == .Param || def.kind == .Return)
				continue;
			let graph = scope NodeGraph();
			let name = scope $"GraphNodeTest{count++}";
			graph.name.Set(name);
			let update = graph.AddNode(NodeLibrary.Find("event.update"), .(40, 60));
			let node = graph.AddNode(def, .(300, 60));
			var last = update;
			if (!def.inputs.IsEmpty && def.inputs[0].type == .Flow)
			{
				graph.Connect(update.id, 0, node.id, 0);
				last = node;
			}
			// Each value the node hands out is stored in a variable of its own.
			for (int32 i < (int32)def.outputs.Count)
			{
				let type = def.outputs[i].type;
				if (type == .Flow || type == .Enum)
					continue;
				let setKey = scope $"var.set.{NodeGraph.TypeSuffix(type)}";
				if (type == .Object && def.outputs[i].typeName != null && def.outputs[i].typeName != "GameObject")
					setKey.AppendF(":{}", def.outputs[i].typeName);
				let set = NodeLibrary.Find(setKey);
				if (set == null || set.inputs[2].type != type)
					continue;
				let store = graph.AddNode(set, .(560, 60 + i * 80));
				store.values[1].Set(scope $"v{i}");
				var from = 0;
				for (int32 k < (int32)last.def.outputs.Count)
				{
					if (last.def.outputs[k].type == .Flow)
					{
						from = k;
						break;
					}
				}
				graph.Connect(last.id, (int32)from, store.id, 0);
				graph.Connect(node.id, i, store.id, 2);
				last = store;
			}
			let code = scope String();
			graph.Compile(Project.Current.Name, name, "test", code);
			File.WriteAllText(scope $"{folder}/{name}.bf", code).IgnoreError();
			let body = scope String(code);
			body.Replace('\n', ' ');
			Log.Info(scope $"GRAPH-NODE-TEST {name} key={def.key} title={def.title}: {body}");
		}
		if (text == "*")
		{
			FlowTestGraph(folder);
			OverloadTestGraph(folder);
		}
		Log.Info(scope $"GRAPH-NODE-TEST DONE {count}");
	}

	/// One graph using the flow-control nodes together (written as GraphFlowTest.bf), to read and to build.
	void FlowTestGraph(StringView folder)
	{
		let graph = scope NodeGraph();
		graph.name.Set("GraphFlowTest");
		GraphNode Node(StringView key, params Span<StringView> values)
		{
			let placed = graph.nodes.Count;
			let node = graph.AddNode(NodeLibrary.Find(key), .(40 + (placed % 5) * 250, 40 + (placed / 5) * 230));
			for (int i < values.Length)
			{
				if (!values[i].IsEmpty)
					node.values[i].Set(values[i]);
			}
			return node;
		}
		GraphNode Print(StringView text) => Node("debug.log", null, text);
		let start = Node("event.start");
		let sequence = Node("flow.sequence");
		graph.Connect(start.id, 0, sequence.id, 0);
		graph.Connect(sequence.id, 0, Print("first").id, 0);
		let call = Node("flow.callcustom", null, "Say Hi");
		graph.Connect(sequence.id, 1, call.id, 0);
		graph.Connect(call.id, 0, Print("after call").id, 0);
		let loop = Node("flow.forbreak", null, null, "0", "10");
		graph.Connect(sequence.id, 2, loop.id, 0);
		let greater = Node("math.igreater", null, "2");
		graph.Connect(loop.id, 1, greater.id, 0);
		let branch = Node("flow.branch");
		graph.Connect(loop.id, 0, branch.id, 0);
		graph.Connect(greater.id, 0, branch.id, 1);
		graph.Connect(branch.id, 0, loop.id, 1);
		graph.Connect(loop.id, 2, Print("loop done").id, 0);
		let custom = Node("event.custom", "Say Hi");
		let once = Node("flow.doonce");
		graph.Connect(custom.id, 0, once.id, 0);
		graph.Connect(once.id, 0, Print("hi once").id, 0);
		let update = Node("event.update");
		let flip = Node("flow.flipflop");
		graph.Connect(update.id, 0, flip.id, 0);
		let gate = Node("flow.gate");
		graph.Connect(flip.id, 0, gate.id, 0);
		graph.Connect(flip.id, 1, gate.id, 3);
		let delay = Node("flow.delay", null, "0.5");
		graph.Connect(gate.id, 0, delay.id, 0);
		graph.Connect(delay.id, 0, Print("delayed").id, 0);
		let jump = Node("event.actionpressed", "Jump");
		let switchString = Node("flow.switchstring", null, "b", "a", "b");
		graph.Connect(jump.id, 0, switchString.id, 0);
		graph.Connect(switchString.id, 1, Print("case b").id, 0);
		graph.Connect(switchString.id, 4, Print("default").id, 0);
		for (int i < 2)
		{
			let comment = new GraphComment();
			comment.title.Set(i == 0 ? "Start: sequence, custom event and loop" : "Do Once runs once per object");
			comment.position = i == 0 ? Vector2(15, -10) : Vector2(15, 430);
			comment.size = i == 0 ? Vector2(1280, 420) : Vector2(560, 200);
			if (i == 1)
				comment.color = .(0.55f, 0.35f, 0.30f, 1);
			graph.comments.Add(comment);
		}
		let code = scope String();
		graph.Compile(Project.Current.Name, "GraphFlowTest", "test", code);
		File.WriteAllText(scope $"{folder}/GraphFlowTest.bf", code).IgnoreError();
		graph.Save(scope $"{folder}/GraphFlowTest.tgraph");
	}

	/// Links values of each type into nodes with versions (Add, Multiply, Print, Split, Equal...) and checks each
	/// switches to the right one (GRAPH-OVERLOAD lines), then writes the graph as GraphOverloadTest.bf to build.
	void OverloadTestGraph(StringView folder)
	{
		let graph = scope NodeGraph();
		graph.name.Set("GraphOverloadTest");
		let update = graph.AddNode(NodeLibrary.Find("event.update"), .(0, 0));
		var last = update;
		int failures = 0;
		GraphNode Variable(PinType type, StringView name, StringView typeName = "GameObject")
		{
			let variable = graph.AddVariable(name, type);
			variable.typeName.Set(typeName);
			return graph.AddVariableNode(variable, false, .(0, 0));
		}
		void Chain(GraphNode node)
		{
			if (!graph.TryConnect(last, 0, node, 0))
				Log.Error("GRAPH-OVERLOAD could not chain flow");
			last = node;
		}
		void Expect(GraphNode node, StringView key, StringView what)
		{
			let ok = node.def.key == key;
			failures += ok ? 0 : 1;
			Log.Info(scope $"GRAPH-OVERLOAD {ok ? "ok" : "FAIL"} {what}: {node.def.key} (wanted {key})");
		}
		// Store a node's first output in a new variable so its code is compiled.
		int stored = 0;
		void Keep(GraphNode node, int32 output = 0)
		{
			let pin = node.def.outputs[output];
			let variable = graph.AddVariable(scope $"kept{stored++}", pin.type);
			if (pin.typeName != null)
				variable.typeName.Set(pin.typeName);
			let set = graph.AddVariableNode(variable, true, .(0, 0));
			Chain(set);
			if (!graph.TryConnect(node, output, set, 2))
				Log.Error(scope $"GRAPH-OVERLOAD could not keep {node.def.key}");
		}
		let v3 = Variable(.Vector3, "position");
		let v2 = Variable(.Vector2, "stick");
		let rot = Variable(.Quaternion, "facing");
		let col = Variable(.Color, "tint");
		let num = Variable(.Float, "speed");
		let whole = Variable(.Int, "count");
		let flag = Variable(.Bool, "flag");
		let body = Variable(.Object, "body", "Rigidbody");
		let target = Variable(.Object, "target");

		let addV = graph.AddNode(NodeLibrary.Find("math.any.add"), .(0, 0));
		graph.TryConnect(v3, 0, addV, 0);
		Expect(addV, "math.vadd", "Add with a vector");
		Keep(addV);
		let addI = graph.AddNode(NodeLibrary.Find("math.any.add"), .(0, 0));
		graph.TryConnect(whole, 0, addI, 0);
		Expect(addI, "math.iadd", "Add with an integer");
		Keep(addI);
		let mul = graph.AddNode(NodeLibrary.Find("math.any.mul"), .(0, 0));
		graph.TryConnect(v3, 0, mul, 0);
		Expect(mul, "math.vscale", "Multiply with a vector");
		graph.TryConnect(v3, 0, mul, 1);
		Expect(mul, "math.vmul", "Multiply vector by vector");
		Keep(mul);
		let mulR = graph.AddNode(NodeLibrary.Find("math.any.mul"), .(0, 0));
		graph.TryConnect(rot, 0, mulR, 0);
		graph.TryConnect(v3, 0, mulR, 1);
		Expect(mulR, "math.qmul", "Multiply rotation by vector");
		Keep(mulR);
		let mulC = graph.AddNode(NodeLibrary.Find("math.mul"), .(0, 0));
		graph.TryConnect(col, 0, mulC, 0);
		Expect(mulC, "math.cscale", "Multiply with a color");
		Keep(mulC);
		let lerp = graph.AddNode(NodeLibrary.Find("math.any.lerp"), .(0, 0));
		graph.TryConnect(rot, 0, lerp, 1);
		Expect(lerp, "math.slerp", "Lerp with rotations");
		Keep(lerp);
		let equal = graph.AddNode(NodeLibrary.Find("math.any.equal"), .(0, 0));
		graph.TryConnect(v2, 0, equal, 0);
		Expect(equal, "math.v2equal", "Equal with 2D vectors");
		Keep(equal);
		let addOut = graph.AddNode(NodeLibrary.Find("math.any.add"), .(0, 0));
		let setV2 = graph.AddVariableNode(graph.FindVariable("stick"), true, .(0, 0));
		Chain(setV2);
		graph.TryConnect(addOut, 0, setV2, 2);
		Expect(addOut, "math.v2add", "Add linked into a 2D vector");

		void Split(GraphNode source, StringView key)
		{
			let split = graph.AddNode(NodeLibrary.Find("math.split"), .(0, 0));
			graph.TryConnect(source, 0, split, 0);
			Expect(split, key, "Split");
			Keep(split, 1);
		}
		Split(v3, "math.split");
		Split(v2, "math.v2break");
		Split(rot, "math.rbreak");
		Split(col, "math.cbreak");
		void Print(GraphNode source, StringView key)
		{
			let print = graph.AddNode(NodeLibrary.Find("debug.log"), .(0, 0));
			Chain(print);
			graph.TryConnect(source, 0, print, 1);
			Expect(print, key, "Print");
		}
		Print(num, "debug.print.float");
		Print(whole, "debug.print.int");
		Print(flag, "debug.print.bool");
		Print(v2, "debug.print.vector2");
		Print(v3, "debug.print.vector");
		Print(rot, "debug.print.rotation");
		Print(col, "debug.print.color");
		Print(body, "debug.print.object");
		Print(target, "debug.print.object");
		let toText = graph.AddNode(NodeLibrary.Find("text.float"), .(0, 0));
		graph.TryConnect(rot, 0, toText, 0);
		Expect(toText, "text.rotation", "To String with a rotation");
		let print = graph.AddNode(NodeLibrary.Find("debug.log"), .(0, 0));
		Chain(print);
		graph.TryConnect(toText, 0, print, 1);
		Expect(print, "debug.log", "Print String keeps text");

		// Object references: a component off an object, and Is Valid on a handle and on an object.
		let getBody = graph.AddNode(NodeLibrary.Find("game.getcomponent:Rigidbody"), .(0, 0));
		graph.TryConnect(target, 0, getBody, 0);
		let setBody = graph.AddVariableNode(graph.FindVariable("body"), true, .(0, 0));
		Chain(setBody);
		if (!graph.TryConnect(getBody, 0, setBody, 2))
		{
			failures++;
			Log.Error("GRAPH-OVERLOAD FAIL Get Rigidbody into a Rigidbody variable");
		}
		for (let source in GraphNode[?](body, target))
		{
			let valid = graph.AddNode(NodeLibrary.Find("flow.isvalid"), .(0, 0));
			Chain(valid);
			graph.TryConnect(source, 0, valid, 1);
		}
		Log.Info(scope $"GRAPH-OVERLOAD DONE failures={failures}");
		let code = scope String();
		graph.Compile(Project.Current.Name, "GraphOverloadTest", "test", code);
		File.WriteAllText(scope $"{folder}/GraphOverloadTest.bf", code).IgnoreError();
		graph.Save(scope $"{folder}/GraphOverloadTest.tgraph");
	}

	/// Test switch --graph-menu-test <graph file>: opens the graph with the add-node menu showing, and logs the menu's
	/// tree (GRAPH-MENU lines: each submenu with how many nodes it lists). With --graph-compile-test as well, it only
	/// compiles the graph to <graph file>.test.bf.
	void TickGraphMenuTest()
	{
		if (!HasArg("--graph-menu-test"))
			return;
		if (++mGraphMenuTestWait == 30)
			OpenNodeSearch(.(300, 200), false);
		if (mGraphMenuTestWait != 10)
			return;
		if (HasArg("--graph-compile-test"))
		{
			// Compiles a graph file to <graph>.test.bf, to compare with what an older editor wrote.
			let file = GetArg("--graph-menu-test", .. scope String());
			let graph = scope NodeGraph();
			Path.GetFileNameWithoutExtension(file, graph.name);
			graph.Load(file);
			let code = scope String();
			graph.Compile(Project.Current.Name, graph.name, scope String()..Append(Path.GetFileName(file, .. scope .())), code);
			File.WriteAllText(scope $"{file}.test.bf", code).IgnoreError();
			Log.Info(scope $"GRAPH-COMPILE-TEST wrote {file}.test.bf");
			return;
		}
		let path = GetArg("--graph-menu-test", .. scope String());
		OpenGraph(path);
		void Walk(NodeMenu menu, int depth)
		{
			for (let sub in menu.menus)
			{
				if (depth < 2)
					Log.Info(scope $"GRAPH-MENU {scope String(' ', depth * 2)}{sub.name} ({sub.items.Count})");
				Walk(sub, depth + 1);
			}
		}
		Walk(NodeMenuTree(), 0);
	}

	int mGraphMenuTestWait;

	/// Test switch --write-first-person-template <folder>: writes the new-project character graph (see
	/// FirstPersonTemplate) to the folder, normally the engine's Editor/templates/empty/Scripts.
	void TickFirstPersonTemplate()
	{
		if (!HasArg("--write-first-person-template") || ++mFirstPersonWait != 10)
			return;
		FirstPersonTemplate.Write(GetArg("--write-first-person-template", .. scope String()));
	}

	int mFirstPersonWait;
}
