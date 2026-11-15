using System;

namespace Tallow.Player;

/// The precompiled player: the engine without the editor, for games whose gameplay is C#. tools/build_player.py
/// copies it into a C# game's build as the game's executable; GameMain finds the game files beside it.
class Program
{
	public static int Main(String[] args) => GameMain.Run(args);
}
