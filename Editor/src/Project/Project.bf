using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// A game project on disk: a Beef workspace that links the engine, plus scenes and assets.
///
///   MyGame/project.tallow     name, start scene, engine location
///   MyGame/BeefSpace.toml      workspace referencing the Tallow engine projects
///   MyGame/src/                game code (Program.bf, Scripts/)
///   MyGame/scenes/             .tscene files
///   MyGame/assets/             models and textures
class Project
{
	public String Name = new .() ~ delete _;
	public String Path = new .() ~ delete _;
	public String StartScene = new .("Scenes/Main.tscene") ~ delete _;
	/// 0 when the game does not use Steam.
	public int32 SteamAppId;
	/// A project remembers where the engine is. When that folder is gone (the project or the engine was moved, or
	/// came from another machine), find the engine again: the one this program belongs to, or the one the project
	/// sits inside, as the bundled samples do. The project file is updated so that builds use the right engine.
	void RelocateEngine()
	{
		// A checked-in sample records its engine relative to the project, never to the caller's working folder.
		if (!EngineRoot.IsEmpty && !Assets.IsAbsolute(EngineRoot))
		{
			let resolved = scope String();
			ProjectGenerator.Normalize(scope $"{Path}/{EngineRoot}" , resolved);
			EngineRoot.Set(resolved);
		}
		// Resolve relative paths above, but never relocate a pinned project.
		if (File.Exists(scope $"{Path}/tallow-engine.lock.json"))
			return;
		if (!EngineRoot.IsEmpty && Directory.Exists(scope $"{EngineRoot}/Engine/src"))
			return;
		let found = scope String();
		var folder = scope String(Path);
		for (int depth < 6)
		{
			let slash = folder.LastIndexOf('/');
			if (slash <= 0)
				break;
			folder.RemoveToEnd(slash);
			if (Directory.Exists(scope $"{folder}/Engine/src") && Directory.Exists(scope $"{folder}/Editor/src"))
			{
				found.Set(folder);
				break;
			}
		}
		if (found.IsEmpty && !ProjectGenerator.FindEngineRoot(found))
			return;
		if (!EngineRoot.IsEmpty)
			Log.Info(scope $"The engine was not at {EngineRoot}; using {found}.");
		EngineRoot.Set(found);
		Save();
	}

	/// Hands the voice settings to the engine.
	public void ApplyVoice()
	{
		Tallow.AntiCheat.Enabled = AntiCheat;
		Tallow.VoiceChat.Enabled = VoiceChat;
		Tallow.VoiceChat.PushToTalk = VoicePushToTalk;
		Tallow.VoiceChat.PushToTalkKey = VoiceKey;
		Tallow.VoiceChat.Proximity = VoiceProximity;
		Tallow.VoiceChat.TeamOnly = VoiceTeamOnly;
	}

	/// Start with headphone 3D audio (HRTF) on. Games can change Audio.Hrtf at run time.
	public bool AudioHrtf = false;
	/// A built game starts fullscreen (File > Build...). Games can change GameWindow.Fullscreen at run time.
	public bool Fullscreen = false;
	/// Initial game window size; zero keeps the runtime default.
	public int32 WindowWidth, WindowHeight;
	/// Games with an Escape menu turn this off.
	public bool EscapeQuits = true;
	/// A built game's assets go into one pack file (game.tpak) rather than loose files.
	/// The engine's anti-cheat watches network sessions (see AntiCheat). Games can also turn it on from code.
	public bool AntiCheat = false;
	public bool PackAssets = true;
	/// Pictures get compressed copies for the graphics card (BC1 / BC3 .ktx with mip levels): a quarter to an eighth of
	/// the video memory, and quicker to load (docs/textures.md). Not for web builds.
	public bool CompressTextures = true;
	/// Files in the pack are compressed: a smaller game to send, for a little work each time a file is loaded.
	public bool PackCompress = true;
	/// Each scene's own files go into a pack of their own beside game.tpak, so that an update to one map rewrites one
	/// small file, and a web build can start before every map has downloaded.
	public bool PackSplit = true;
	/// SaveSystem.LoadAtStart for this game: put the save in SaveSlot back as the first scene starts.
	public bool LoadSaveAtStart;
	public String SaveSlot = new .("default") ~ delete _;
	/// Wildcards, separated by ';', for files that scripts load by a name they put together (Models/prop_*.glb):
	/// a build cannot see those, so they always go into the shared pack.
	public String PackShared = new .() ~ delete _;
	/// Voice chat between players of a network session, and how it starts out. Games can change VoiceChat.* at run time.
	public bool VoiceChat, VoicePushToTalk, VoiceProximity, VoiceTeamOnly;
	public KeyCode VoiceKey = .V;
	public String EngineRoot = new .() ~ delete _;
	/// Extra Beef libraries referenced by folder (libraries inside the project's Libraries folder are found automatically).
	public List<String> Libraries = new .() ~ DeleteContainerAndItems!(_);
	/// Extra linker arguments, e.g. "-lcurl" or a path to a .a file.
	public String LinkFlags = new .() ~ delete _;

	/// Folder shown as "Assets" in the editor: scripts, models, scenes, textures and prefabs.
	/// On disk it is the Beef project's src folder, so scripts placed anywhere inside are compiled.
	public void GetAssetPath(String outPath) => outPath.AppendF("{}/src", Path);

	public static Project Current ~ delete _;

	public bool Load(StringView path)
	{
		Path.Set(path);
		Path.Replace('\\', '/');
		while (Path.EndsWith('/') && Path.Length > 1)
			Path.RemoveFromEnd(1);
		let text = scope String();
		if (File.ReadAllText(scope $"{Path}/project.tallow" , text) case .Err)
			return false;
		for (let line in text.Split('\n'))
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
			case "name": Name.Set(value);
			case "startScene": StartScene.Set(value);
			case "steamAppId": SteamAppId = Math.Max(SceneSerializer.ParseInt(value), 0);
			case "audioHrtf": AudioHrtf = value == "1";
			case "fullscreen": Fullscreen = value == "1";
			case "windowWidth": WindowWidth = (int32)Math.Max(SceneSerializer.ParseInt(value), 0);
			case "windowHeight": WindowHeight = (int32)Math.Max(SceneSerializer.ParseInt(value), 0);
			case "escapeQuits": EscapeQuits = value != "0";
			case "antiCheat": AntiCheat = value == "1";
			case "packAssets": PackAssets = value != "0";
			case "packCompress": PackCompress = value != "0";
			case "compressTextures": CompressTextures = value != "0";
			case "packSplit": PackSplit = value != "0";
			case "loadSaveAtStart": LoadSaveAtStart = value == "1";
			case "saveSlot": if (!value.IsEmpty) SaveSlot.Set(value);
			case "packShared": PackShared.Set(value);
			case "voiceChat": VoiceChat = value == "1";
			case "voicePushToTalk": VoicePushToTalk = value == "1";
			case "voiceProximity": VoiceProximity = value == "1";
			case "voiceTeamOnly": VoiceTeamOnly = value == "1";
			case "voiceKey": if (Enum.Parse<KeyCode>(value) case .Ok(let voiceKey)) VoiceKey = voiceKey;
			case "engine": EngineRoot.Set(value);
			case "library": Libraries.Add(new String(value));
			case "link": LinkFlags.Set(value);
			}
		}
		if (!Name.IsEmpty)
			RelocateEngine();
		return !Name.IsEmpty;
	}

	public void Save()
	{
		let text = scope String();
		text.AppendF("name = {}\nstartScene = {}\nengine = {}\n", Name, StartScene, EngineRoot);
		if (SteamAppId > 0)
			text.AppendF("steamAppId = {}\n", SteamAppId);
		if (AudioHrtf)
			text.Append("audioHrtf = 1\n");
		if (Fullscreen)
			text.Append("fullscreen = 1\n");
		if (WindowWidth > 0)
			text.AppendF("windowWidth = {}\n", WindowWidth);
		if (WindowHeight > 0)
			text.AppendF("windowHeight = {}\n", WindowHeight);
		if (!EscapeQuits)
			text.Append("escapeQuits = 0\n");
		if (AntiCheat)
			text.Append("antiCheat = 1\n");
		if (!PackAssets)
			text.Append("packAssets = 0\n");
		if (!PackCompress)
			text.Append("packCompress = 0\n");
		if (!CompressTextures)
			text.Append("compressTextures = 0\n");
		if (!PackSplit)
			text.Append("packSplit = 0\n");
		if (LoadSaveAtStart)
			text.Append("loadSaveAtStart = 1\n");
		if (SaveSlot != "default")
			text.AppendF("saveSlot = {}\n", SaveSlot);
		if (!PackShared.IsEmpty)
			text.AppendF("packShared = {}\n", PackShared);
		if (VoiceChat)
			text.Append("voiceChat = 1\n");
		if (VoicePushToTalk)
			text.Append("voicePushToTalk = 1\n");
		if (VoiceProximity)
			text.Append("voiceProximity = 1\n");
		if (VoiceTeamOnly)
			text.Append("voiceTeamOnly = 1\n");
		if (VoiceKey != .V)
			text.AppendF("voiceKey = {}\n", VoiceKey);
		ApplyVoice();
		for (let library in Libraries)
			text.AppendF("library = {}\n", library);
		if (!LinkFlags.IsEmpty)
			text.AppendF("link = {}\n", LinkFlags);
		File.WriteAllText(scope $"{Path}/project.tallow" , text).IgnoreError();
	}

	/// Path of the executable BeefBuild produces for this project.
	public void GetExecutablePath(String outPath, bool release)
	{
#if BF_PLATFORM_WINDOWS
		outPath.AppendF("{}/build/{}_Win64/{}/{}.exe", Path, release ? "Release" : "Debug", Name, Name);
		#elif BF_PLATFORM_MACOS
		outPath.AppendF("{}/build/{}_macOS/{}/{}", Path, release ? "Release" : "Debug", Name, Name);
	#else
		outPath.AppendF("{}/build/{}_Linux64/{}/{}", Path, release ? "Release" : "Debug", Name, Name);
#endif
	}

	/// Reads the project name out of a Beef library's BeefProj.toml.
	public static bool ReadLibraryName(StringView folder, String outName)
	{
		let text = scope String();
		if (File.ReadAllText(scope $"{folder}/BeefProj.toml" , text) case .Err)
			return false;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.StartsWith("Name") && line.Contains('='))
			{
				let first = line.IndexOf('"');
				let last = line.LastIndexOf('"');
				if (first >= 0 && last > first)
				{
					outName.Append(line.Substring(first + 1, last - first - 1));
					return true;
				}
			}
		}
		return false;
	}

	/// Every Beef library this project uses: those dropped into Libraries/ plus the referenced folders.
	public void CollectLibraries(List<(String name, String path)> libraries)
	{
		void Add(StringView folder)
		{
			let name = new String();
			if (!ReadLibraryName(folder, name) || name == "Tallow" || name == "TallowEditor" || name == Name)
			{
				delete name;
				return;
			}
			for (let existing in libraries)
			{
				if (existing.name == name)
				{
					delete name;
					return;
				}
			}
			libraries.Add((name, new String(folder)));
		}
		let folder = scope $"{Path}/Libraries";
		if (Directory.Exists(folder))
		{
			for (let entry in Directory.EnumerateDirectories(folder))
			{
				let name = scope String();
				entry.GetFileName(name);
				Add(scope $"{folder}/{name}");
			}
		}
		for (let library in Libraries)
			Add(library);
	}

	/// Regenerates BeefSpace.toml and BeefProj.toml from project.tallow. They are build output:
	/// libraries and link flags are managed in the editor (File > Project Settings), never by hand.
	public void WriteBuildFiles()
	{
		List<(String name, String path)> libraries = scope .();
		defer
		{
			for (let l in libraries)
			{
				delete l.name;
				delete l.path;
			}
		}
		CollectLibraries(libraries);

		let space = scope String();
		space.AppendF("FileVersion = 1\nProjects = {{{0} = {{Path = \".\"}}, Tallow = {{Path = \"{1}/Engine\"}}, TallowEditor = {{Path = \"{1}/Editor\"}}", Name, EngineRoot);
		for (let library in libraries)
			space.AppendF(", {} = {{Path = \"{}\"}}", library.name, library.path);
		space.AppendF("}}\n\n[Workspace]\nStartupProject = \"{}\"\n", Name);
		// Beef's own linker (LLVM's) on Windows: it needs Microsoft's libraries but not Microsoft's linker.
		space.Append("\n[Configs.Debug.Win64]\nToolset = \"LLVM\"\n\n[Configs.Release.Win64]\nToolset = \"LLVM\"\n");
		File.WriteAllText(scope $"{Path}/BeefSpace.toml" , space).IgnoreError();

		let native = scope $"{EngineRoot}/build/native";
		let link = scope String("-Wl,--start-group ");
		for (let archive in StringView[?]("libtallow_native.a", "bgfx/cmake/bgfx/libbgfx.a", "bgfx/cmake/bimg/libbimg.a", "bgfx/cmake/bimg/libbimg_decode.a", "bgfx/cmake/bx/libbx.a", "SDL/libSDL3.a", "joltc/libjoltc.a", "_deps/joltphysics-build/libJolt.a", "enet/libenet.a"))
			link.AppendF("\\\"{}/{}\\\" ", native, archive);
		link.AppendF("-Wl,--end-group -lstdc++ -lm -ldl -lpthread -lGL -lX11 {}", LinkFlags);
		let proj = scope String();
		proj.Append("FileVersion = 1\nDependencies = {corlib = \"*\", Tallow = \"*\", TallowEditor = \"*\"");
		for (let library in libraries)
			proj.AppendF(", {} = \"*\"", library.name);
#if BF_PLATFORM_WINDOWS
		let targetType = "BeefGUIApplication";
#else
		let targetType = "BeefConsoleApplication";
#endif
		proj.AppendF("}}\n\n[Project]\nName = \"{0}\"\nTargetType = \"{1}\"\nStartupObject = \"{0}.Program\"\n", Name, targetType);
		proj.AppendF("\n[Configs.Debug.Linux64]\nOtherLinkFlags = \"$(LinkFlags) -rdynamic {0}\"\n\n[Configs.Release.Linux64]\nCLibType = \"Dynamic\"\nOtherLinkFlags = \"$(LinkFlags) {0}\"\n", link);
		// The same libraries as built for Windows (build/native-win), and the Windows libraries they call into. The
		// native libraries use the static C runtime, so the game must too. The project's own link flags are written
		// for Linux's linker and are left out.
		let nativeWin = scope $"{EngineRoot}/build/native-win";
		let linkWin = scope String();
		for (let archive in StringView[?]("tallow_native.lib", "bgfx/cmake/bgfx/bgfx.lib", "bgfx/cmake/bimg/bimg.lib", "bgfx/cmake/bimg/bimg_decode.lib", "bgfx/cmake/bx/bx.lib", "SDL/SDL3-static.lib", "joltc/joltc.lib", "_deps/joltphysics-build/Jolt.lib", "enet/enet.lib"))
		{
			// These quotes survive TOML parsing and keep Hub/user folders with spaces intact for lld-link.
			linkWin.AppendF("\\\"{}/{}\\\" ", nativeWin, archive);
		}
		linkWin.Append("user32.lib gdi32.lib shell32.lib winmm.lib imm32.lib ole32.lib oleaut32.lib version.lib setupapi.lib advapi32.lib ws2_32.lib psapi.lib uuid.lib cfgmgr32.lib dbghelp.lib");
		// The debug build also writes a map of where everything in it is: script reload links against that.
		proj.AppendF("\n[Configs.Debug.Win64]\nCLibType = \"Static\"\nOtherLinkFlags = \"$(LinkFlags) {0} /MAP\"\n\n[Configs.Release.Win64]\nCLibType = \"Static\"\nOtherLinkFlags = \"$(LinkFlags) {0}\"\n", linkWin);
		File.WriteAllText(scope $"{Path}/BeefProj.toml" , proj).IgnoreError();
	}

	/// Stages a shipping executable built against Tallow only, plus its runtime assets.
	/// outputPath is the game's own folder; an earlier build of a game found there is replaced.
	public bool BuildPlayer(StringView outputPath, BuildTarget target)
	{
		WriteBuildFiles();
		Directory.CreateDirectory(scope $"{Path}/build").IgnoreError();
		let command = scope String(Terminal.Python)..Append(' ');
		Terminal.Quote(scope $"{EngineRoot}/tools/build_player.py" , command);
		command.Append(' ');
		Terminal.Quote(Path, command);
		command.AppendF(" --platform {} --replace --output ", target.ToString(.. scope .())..ToLower());
		Terminal.Quote(outputPath, command);
		command.Append(" > ");
		Terminal.Quote(scope $"{Path}/build/build.log" , command);
		command.Append(" 2>&1");
		return Terminal.Run(command) == 0;
	}

	/// Puts a copy of Tallow itself (launcher, editor, engine) for Linux, Windows or macOS in outputPath.
	public bool PackageEngine(StringView outputPath, BuildTarget target)
	{
		Directory.CreateDirectory(scope $"{Path}/build").IgnoreError();
		let command = scope String(Terminal.Python)..Append(' ');
		Terminal.Quote(scope $"{EngineRoot}/tools/package_engine.py" , command);
		command.AppendF(" --platform {} --folder ", target.ToString(.. scope .())..ToLower());
		Terminal.Quote(outputPath, command);
		command.Append(" > ");
		Terminal.Quote(scope $"{Path}/build/build.log" , command);
		command.Append(" 2>&1");
		return Terminal.Run(command) == 0;
	}

	/// Compiles the project's workspace. Output goes to build/build.log inside the project.
	public bool Build(bool release)
	{
		WriteBuildFiles();
		let command = scope String();
		let beef = scope String();
		if (!(Environment.GetEnvironmentVariable("BEEFBUILD", beef) case .Ok) || beef.IsEmpty)
			beef.Set("BeefBuild");
		Directory.CreateDirectory(scope $"{Path}/build").IgnoreError();
		Terminal.Quote(beef, command);
		command.Append(" -workspace=");
		Terminal.Quote(Path, command);
		command.AppendF(" -config={} -verbosity=minimal > ", release ? "Release" : "Debug");
		Terminal.Quote(scope $"{Path}/build/build.log" , command);
		command.Append(" 2>&1");
		let exe = scope String();
		GetExecutablePath(exe, release);
#if BF_PLATFORM_WINDOWS
		// Windows will not let a running program's file be written, but will let it be renamed: when the editor
		// rebuilds itself, move the running file aside for the linker and put it back if the build fails.
		let aside = scope $"{exe}.old";
		File.Delete(aside).IgnoreError();
		let moved = File.Exists(exe) && File.Move(exe, aside) case .Ok;
		let status = Terminal.Run(command);
		if (moved && !File.Exists(exe))
			File.Move(aside, exe).IgnoreError();
#else
		let status = Terminal.Run(command);
#endif
		return status == 0 && File.Exists(exe);
	}

	public void ReadBuildLog(String outText)
	{
		File.ReadAllText(scope $"{Path}/build/build.log" , outText).IgnoreError();
	}
}
