using System;

namespace Tallow;

/// The game's window: whether it fills the screen.
///
///   GameWindow.Fullscreen = true;        // switch now; a settings menu's toggle does this
///   if (GameWindow.Fullscreen) ...
///
/// A built game starts the way File > Build... was set ("Start in fullscreen"), unless it is started with
/// --fullscreen or --windowed. A game that lets the player choose sets GameWindow.Fullscreen to the saved choice when
/// it starts, and can leave it alone until the player has made one, so that the build's setting is the default.
static class GameWindow
{
	/// False inside the editor, where the game is drawn in the Game view and the window is the editor's.
	public static bool Allowed = true;
	/// How the build was set to start, or what --fullscreen / --windowed asked for. Read-only for games.
	public static bool StartsFullscreen;
	/// The window's size when the game starts in a window, in points (0: the engine's 1600 by 900). Set from the
	/// project's windowWidth and windowHeight; a small tool or launcher sets something smaller.
	public static int32 StartWidth;
	public static int32 StartHeight;
	/// Whether Escape closes the game when nothing else uses it. On by default; a launcher or a game with its own
	/// pause menu sets escapeQuits = 0 in its project.
	public static bool EscapeQuits = true;

	static bool sWanted;
	static bool sChosen;
	static bool sApplied;

	/// Whether the window fills the screen (borderless, at the desktop's resolution). Setting it switches at once;
	/// in the editor and on a server with no window it is remembered and nothing else happens.
	public static bool Fullscreen
	{
		get => sChosen ? sWanted : StartsFullscreen;
		set
		{
			sWanted = value;
			sChosen = true;
			Apply();
		}
	}

	/// Flips between fullscreen and a window.
	public static void ToggleFullscreen()
	{
		Fullscreen = !Fullscreen;
	}

	/// The application calls this when it creates the window: true if the window should start out fullscreen.
	public static bool TakeStartState()
	{
		sApplied = Allowed && Fullscreen;
		return sApplied;
	}

	static void Apply()
	{
		let app = Application.Instance;
		if (app == null || app.Window == null || !Allowed || sApplied == sWanted)
			return;
		if (SDL.SDL_SetWindowFullscreen(app.Window, sWanted))
			sApplied = sWanted;
	}
}
