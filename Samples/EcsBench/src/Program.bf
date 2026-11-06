using System;
using Tallow.Editor;

namespace EcsBench;

class Program
{
	public static int Main(String[] args)
	{
		if (args.Count == 2 && args[0] == "--generate-graph-fixture")
			return GraphFixture.Write(args[1]);
		if (args.Count == 3 && args[0] == "--check-semantic-client")
			return SemanticClientChecks.Run(args[1], args[2]);
		if (args.Count == 1 && args[0] == "--check-lifetimes")
			return EcsChecks.RunLifetimeChecks();
		if (args.Count == 3 && args[0] == "--bench-script-cpu")
		{
			if (int.Parse(args[1]) case .Ok(let count) && int.Parse(args[2]) case .Ok(let frames))
				return ScriptCpuBench.Run(count, frames);
			return 1;
		}
		if (args.Count == 1 && args[0] == "--check-references")
			return EcsChecks.RunReferenceChecks();
		GameSetup.Register();
		return EditorMain.Run(args);
	}
}
