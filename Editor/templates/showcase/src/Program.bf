using System;
using Tallow.Editor;

namespace {NAMESPACE};

class Program
{
	public static int Main(String[] args)
	{
		GameSetup.Register();
		return EditorMain.Run(args);
	}
}
