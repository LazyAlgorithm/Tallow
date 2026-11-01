using System;
using System.IO;

namespace Tallow;

/// Where a game keeps the player's own files: settings, saves, maps they made. One folder per game per player, in
/// the place each system expects:
///
///   Windows   %APPDATA%\Tallow\<Game>\
///   Linux     ~/.local/share/Tallow/<Game>/      (or $XDG_DATA_HOME)
///   macOS     ~/Library/Application Support/Tallow/<Game>/
///   Web       the browser's storage for the page (kept between visits)
///
///   let path = scope $"{GamePaths.PlayerData}notes.txt";
///
/// The game folder itself (beside the executable, or inside the asset pack) is for reading only; write here.
static class GamePaths
{
	static String sPlayerData ~ delete _;

	/// The publisher's part of the path. Changing it moves where everything is kept, so set it once, early.
	public static String Company = new .("Tallow") ~ delete _;
	/// The game's part of the path: its name, from the build's manifest.
	public static String Game = new .("Game") ~ delete _;

	/// The player's folder for this game, ending in a slash. Made the first time it is asked for.
	public static StringView PlayerData
	{
		get
		{
			if (sPlayerData == null)
			{
				sPlayerData = new String();
				let pref = SDL.SDL_GetPrefPath(Company.CStr(), Game.CStr());
				if (pref != null)
				{
					sPlayerData.Append(StringView(pref));
					SDL.SDL_free(pref);
				}
				else
				{
					// No system folder (a sandbox that refuses one): beside the working folder.
					Directory.GetCurrentDirectory(sPlayerData);
					sPlayerData.Append("/player-data/");
					Directory.CreateDirectory(sPlayerData).IgnoreError();
				}
				sPlayerData.Replace('\\', '/');
				if (!sPlayerData.EndsWith('/'))
					sPlayerData.Append('/');
			}
			return sPlayerData;
		}
	}

	/// Where SaveSystem's file storage keeps saves: PlayerData + "saves/".
	public static void Saves(String path) => path.AppendF("{}saves/", PlayerData);

	/// The game's own folder, ending in a slash: where a built game's program is, or the project's folder when it runs
	/// from the editor or a development build. For reading things that come with the game or are put beside it, such
	/// as a Maps folder (MapFiles.Folder). Empty until the game has started.
	public static String GameFolder = new .() ~ delete _;

	/// Sets GameFolder (with forward slashes and a slash at the end).
	public static void SetGameFolder(StringView folder)
	{
		GameFolder.Set(folder);
		GameFolder.Replace('\\', '/');
		if (!GameFolder.IsEmpty && !GameFolder.EndsWith('/'))
			GameFolder.Append('/');
	}

	/// Call after changing Company or Game, so that the folder is looked up again.
	public static void Refresh() => DeleteAndNullify!(sPlayerData);
}
