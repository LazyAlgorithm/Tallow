using System;
using System.IO;

namespace Tallow;

/// Editor-free packaged game entry point. Distribution layout: game.tessera, Assets/, Engine/assets/.
static class GameMain
{
	/// Runs once in a built game after its files and manifest are found, before its window opens: the place to load
	/// settings that decide how the window opens (fullscreen, say). GamePaths and DataAsset work from here on.
	public static Event<delegate void()> BeforeWindow ~ _.Dispose();

	public static int Run(String[] args)
	{
		let root = scope String();
		FindGameFolder(args, root);
		// A packed game: its assets, the engine's shaders and its manifest are in game.tpak, as if beside it, with
		// each scene's own files in a pack of their own when the build split them.
		AssetPack.MountGame(root);
		let manifest = scope String();
		if (AssetPack.ReadAllText(scope $"{root}/game.tessera" , manifest) case .Err)
		{
			Console.WriteLine("Missing game.tessera (or game.tpak). Use --game <package folder>.");
			return 1;
		}
#if BF_PLATFORM_WASM
		// In a browser this function is left for good once the game starts (see WebPlatform.RunMainLoop) while the game
		// keeps running, so the game must not live on its stack.
		let app = new GameApp();
#else
		let app = scope GameApp();
#endif
		OpenLog();
		Watchdog.Start();
		ReadManifest(manifest, app);
		Assets.ProjectPath.Set(scope $"{root}/Assets");
		GamePaths.SetGameFolder(root);
		// Physics layers, tags and world states.
		ProjectConfig.Load();
		Environment.SetEnvironmentVariable("TESSERA_ROOT", root);
		if (!ReadCommandLine(args, app))
			return 1;
		BeforeWindow();
		return app.Run(args);
	}

	/// The game's folder: where the program is, unless --game names another.
	static void FindGameFolder(String[] args, String root)
	{
		let basePath = SDL.SDL_GetBasePath();
		if (basePath != null)
			root.Set(StringView(basePath));
		for (int i = 0; i + 1 < args.Count; i++)
		{
			if (args[i] == "--game")
				root.Set(args[i + 1]);
		}
	}

	/// A built game has no console: it keeps a log beside it (or in the temporary folder if that is read-only),
	/// which also says what the game was doing if it ever stops moving (Watchdog).
	static void OpenLog()
	{
		let logPath = scope String();
		Environment.GetExecutableFilePath(logPath);
		let slash = Math.Max(logPath.LastIndexOf('/'), logPath.LastIndexOf('\\'));
		if (slash >= 0)
			logPath.RemoveToEnd(slash + 1);
		logPath.Append("log.txt");
		if (Log.OpenFile(logPath))
			return;
		logPath.Clear();
		System.IO.Path.GetTempPath(logPath);
		logPath.Append("/tessera-game-log.txt");
		Log.OpenFile(logPath);
	}

	/// The settings the editor's Build window wrote into game.tessera, one "key = value" a line.
	static void ReadManifest(StringView manifest, GameApp app)
	{
		for (let line in manifest.Split('\n'))
		{
			let eq = line.IndexOf('=');
			if (eq < 0)
				continue;
			var key = line.Substring(0, eq);
			var value = line.Substring(eq + 1);
			key.Trim();
			value.Trim();
			switch (key)
			{
			case "name":
				app.GameName.Set(value);
				Achievements.SaveName.Set(value);
				WebRtc.AppName.Set(value);
				GamePaths.Game.Set(value);
				GamePaths.Refresh();
			case "company":
				if (!value.IsEmpty)
				{
					GamePaths.Company.Set(value);
					GamePaths.Refresh();
				}
			case "startScene":
				app.StartScene.Set(value);
			case "audioHrtf":
				Audio.Hrtf = value == "1";
			case "fullscreen":
				GameWindow.StartsFullscreen = value == "1";
			case "windowWidth":
				GameWindow.StartWidth = (int32)Math.Max(SceneSerializer.ParseInt(value), 0);
			case "windowHeight":
				GameWindow.StartHeight = (int32)Math.Max(SceneSerializer.ParseInt(value), 0);
			case "escapeQuits":
				GameWindow.EscapeQuits = value != "0";
			case "antiCheat":
				// With the anti-cheat on, a built game also closes its memory to other programs and watches itself.
				if (value == "1")
				{
					AntiCheat.Enabled = true;
					Log.Info(AntiCheat.Harden() ? "Anti-cheat on: this game's memory is closed to other programs." : "Anti-cheat on. (This system would not close the game's memory to other programs.)");
				}
			case "voiceChat":
				VoiceChat.Enabled = value == "1";
			case "voicePushToTalk":
				VoiceChat.PushToTalk = value == "1";
			case "voiceProximity":
				VoiceChat.Proximity = value == "1";
			case "voiceTeamOnly":
				VoiceChat.TeamOnly = value == "1";
			case "voiceKey":
				if (Enum.Parse<KeyCode>(value) case .Ok(let voiceKey))
					VoiceChat.PushToTalkKey = voiceKey;
			case "steamAppId":
				Steam.AppId = (uint32)Math.Max(SceneSerializer.ParseInt(value), 0);
			case "loadSaveAtStart":
				SaveSystem.LoadAtStart = value == "1";
			case "saveSlot":
				if (!value.IsEmpty)
					SaveSystem.StartSlot.Set(value);
			}
		}
	}

	/// The switches a built game takes (README.md and docs/networking.md list them). False: the game should not start.
	static bool ReadCommandLine(String[] args, GameApp app)
	{
		for (int i = 0; i < args.Count; i++)
		{
			let arg = args[i];
			let hasValue = i + 1 < args.Count;
			if (arg == "--server")
			{
				app.Headless = true;
				NetworkSession.ModeOverride = .Server;
			}
			else if (arg == "--host")
				NetworkSession.ModeOverride = .Host;
			else if (arg == "--bot")
				NetworkSession.BotOverride = true;
			else if (arg == "--connect" && hasValue)
			{
				NetworkSession.ModeOverride = .Client;
				NetworkSession.AddressOverride.Set(args[++i]);
			}
			else if (arg == "--port" && hasValue)
				NetworkSession.PortOverride = SceneSerializer.ParseInt(args[++i]);
			else if (arg == "--lag" && hasValue)
				NetworkManager.SimulatedLagMs = Math.Max(0, SceneSerializer.ParseInt(args[++i]));
			else if (arg == "--loss" && hasValue)
				NetworkManager.SimulatedLossPercent = Mathf.Clamp(SceneSerializer.ParseFloat(args[++i]), 0, 100);
			else if (arg == "--jitter" && hasValue)
				NetworkManager.SimulatedJitterMs = Math.Max(0, SceneSerializer.ParseInt(args[++i]));
			else if (arg == "--teststall")
				Watchdog.TestStall = true;
			else if (arg == "--netstats")
				NetworkManager.LogStats = true;
			else if (arg == "--editor")
			{
				Console.WriteLine("This game was built without the editor.");
				return false;
			}
		}
		return true;
	}
}
