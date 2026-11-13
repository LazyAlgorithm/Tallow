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
				if (type == .Flow || type == .Object || type == .Enum)
					continue;
				let set = NodeLibrary.Find(scope $"var.set.{NodeGraph.TypeSuffix(type)}");
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
			FlowTestGraph(folder);
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
				if (values[i] != null)
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
		let code = scope String();
		graph.Compile(Project.Current.Name, "GraphFlowTest", "test", code);
		File.WriteAllText(scope $"{folder}/GraphFlowTest.bf", code).IgnoreError();
		graph.Save(scope $"{folder}/GraphFlowTest.tgraph");
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
}
