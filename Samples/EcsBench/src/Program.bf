using System;
using Tallow;
using Tallow.Editor;

namespace EcsBench;

class Program
{
	public static int Main(String[] args)
	{
		if (args.Count > 0 && args[0] == "--check-scripts")
			return ScriptPathChecks.Run();
		if (args.Count > 0 && args[0] == "--profile-scripts")
		{
			int count = 10000;
			if (args.Count > 1 && int.Parse(args[1]) case .Ok(let parsed))
				count = parsed;
			return ScriptPathProfile.Run(count);
		}

		if (args.Count > 0 && args[0] == "--profile-ecs")
		{
			int count = 10000;
			if (args.Count > 1 && int.Parse(args[1]) case .Ok(let parsed))
				count = parsed;
			return EcsMicroProfile.Run(count);
		}
		if (args.Count > 0 && args[0] == "--profile-scene")
		{
			int count = 1000;
			if (args.Count > 1 && int.Parse(args[1]) case .Ok(let parsed))
				count = parsed;
			return SceneMicroProfile.Run(count);
		}
		GameSetup.Register();
		return EditorMain.Run(args);
	}
}
