using System;
using Tallow.Editor;

namespace EcsBench;

class Program
{
	public static int Main(String[] args)
	{
		if (args.Count == 2 && args[0] == "--generate-graph-fixture")
			return GraphFixture.Write(args[1]);
		GameSetup.Register();
		return EditorMain.Run(args);
	}
}
