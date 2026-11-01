using System;
using Tallow.Editor;

namespace {NAMESPACE};

class Program
{
	public static int Main(String[] args)
	{
		GameSetup.Register();
		for (let arg in args)
		{
			if (arg == "--author-scene")
			{
				let app = scope CampusAuthor();
				return app.Run(args);
			}
		}
		return EditorMain.Run(args);
	}
}
