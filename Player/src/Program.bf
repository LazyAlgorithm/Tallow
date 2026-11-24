using System;

namespace Tallow.Player;

/// The precompiled player: the engine without the editor, for games whose gameplay is C#. Tallow.Build export
/// copies it into a C# game's build as the game's executable; GameMain finds the game files beside it.
///
/// For the web it is a library instead (BeefApplication_StaticLib, linked into .NET's WebAssembly): the page starts
/// .NET, whose start-up (Tallow.ManagedRuntime's WebHost) calls BeefStart, which runs Main here. Main then returns
/// to .NET once the browser has the frame loop.
class Program
{
	public static int Main(String[] args)
	{
		CrashReports.UseConsoleWhenUnattended(args);
#if BF_PLATFORM_WASM
		WebPlatform.ReturnFromMainLoop = true;
#endif
		return GameMain.Run(args);
	}
}
