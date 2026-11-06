using System;
using System.IO;
using Tallow;
using Tallow.Editor;

namespace EcsBench;

/// Generates real visual-script output, which the next sample build compiles into EcsChecks.
static class GraphFixture
{
	public static int Write(StringView output)
	{
		let graph = scope NodeGraph();
		let value = graph.AddVariable("tickDelta", .Float);
		value.networked = true;
		graph.AddVariable("steps", .Int).value.Set("7");
		let tick = graph.AddNode(NodeLibrary.Find("event.update"), .Zero);
		let set = graph.AddVariableNode(value, true, .(200, 0));
		graph.Connect(tick.id, 0, set.id, 0);
		graph.Connect(tick.id, 1, set.id, 2);
		let path = scope $"{output}.tgraph";
		graph.Save(path);
		defer
		{
			File.Delete(path).IgnoreError();
		}
		let loaded = scope NodeGraph();
		if (!loaded.Load(path) || loaded.FindVariable("steps")?.type != .Int || !loaded.FindVariable("tickDelta").networked)
		{
			Console.WriteLine("Graph variable type/replication round trip failed");
			return 1;
		}
		let code = scope String();
		loaded.Compile("EcsBench", "GeneratedTickProbe", "Phase7Fixture.tgraph", code);
		if (!code.Contains("class GeneratedTickProbe : Script") || !code.Contains("[Sync] public float tickDelta") ||
			!code.Contains("Update(TickInput input, float deltaTime)") || !code.Contains("tickDelta = deltaTime;"))
		{
			Console.WriteLine("Graph output no longer matches the gameplay API");
			return 1;
		}
		if (File.WriteAllText(output, code) case .Err)
			return 1;
		Console.WriteLine("Generated Phase 7 graph fixture: {}", output);
		return 0;
	}
}
