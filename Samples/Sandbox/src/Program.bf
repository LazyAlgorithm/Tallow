using System;
using Tallow.Editor;

namespace Sandbox;

class Program
{
	public static int Main(String[] args)
	{
		GameSetup.Register();
		// Opens the editor when started with --editor, otherwise runs the game.
		return EditorMain.Run(args);
	}
}
