using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Test switch --graph-node-test <text>: for every visual scripting node whose title has the text in it, makes a
/// graph of On Update and that node (its flow linked, its inputs left as they start), compiles it into
/// src/GraphNodeTest/GraphNodeTestN.bf and logs GRAPH-NODE-TEST lines. Build the project afterwards to see whether
/// each compiles.
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
		let folder = scope $"{Assets.ProjectPath}/src/GraphNodeTest";
		Directory.CreateDirectory(folder).IgnoreError();
		int count = 0;
		for (let def in NodeLibrary.Defs)
		{
			if (!def.title.Contains(text, true) || def.kind == .Event)
				continue;
			let graph = scope NodeGraph();
			let name = scope $"GraphNodeTest{count++}";
			graph.name.Set(name);
			let update = graph.AddNode(NodeLibrary.Find("event.update"), .(40, 60));
			let node = graph.AddNode(def, .(300, 60));
			if (!def.inputs.IsEmpty && def.inputs[0].type == .Flow)
				graph.Connect(update.id, 0, node.id, 0);
			let code = scope String();
			graph.Compile(Project.Current.Name, name, "test", code);
			File.WriteAllText(scope $"{folder}/{name}.bf", code).IgnoreError();
			let body = scope String(code);
			body.Replace('\n', ' ');
			Log.Info(scope $"GRAPH-NODE-TEST {name} key={def.key} title={def.title}: {body}");
		}
		Log.Info(scope $"GRAPH-NODE-TEST DONE {count}");
	}
}
