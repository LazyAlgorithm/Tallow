using System;
using Tallow.Editor;

namespace EcsBench;

class Program
{
	public static int Main(String[] args)
	{
		GameSetup.Register();
		return EditorMain.Run(args);
	}
}
