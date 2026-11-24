using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// What File > Build makes a game for.
enum BuildTarget
{
	Linux,
	Windows,
	/// Intel or Apple silicon, as the engine's macOS player is (tallowengine.com/docs/macos).
	MacOS,
	/// A folder of web files (WebAssembly) to put on any web server, played in a browser on computers and phones.
	Web
}

/// File > Build Game: pick the system to build for and a folder, and get a folder holding the game and only what
/// it needs to run, which can be moved or sent to somebody else.
extension EditorApp
{
	bool mShowBuild;
	BuildTarget mBuildTarget;
	/// The local web server started by Play in Browser, so a second press does not start another.
	bool mWebServerStarted;
	bool mBuildSucceeded;
	/// A build asked for (Build, or --build-now) while the script error check runs: it starts when the check ends.
	bool mBuildNowPending;
	String mBuildFolder = new .() ~ delete _;
	String mBuildMessage = new .() ~ delete _;

	// The desktop's folder dialog answers later, perhaps on another thread: it leaves its answer here.
	static Monitor sPickLock = new .() ~ delete _;
	static String sPicked = new .() ~ delete _;
	static bool sPickReady;

	static void OnFolderPicked(void* userData, char8** files, int32 filter)
	{
		if (files == null || files[0] == null)
			return;
		using (sPickLock.Enter())
		{
			sPicked.Set(StringView(files[0]));
			sPickReady = true;
		}
	}

	void BuildChoicePath(String outPath) => outPath.AppendF("{}/build/build-target.txt", Project.Current.Path);

	void OpenBuildWindow()
	{
		mShowBuild = true;
		mBuildMessage.Clear();
		mBuildSucceeded = false;
		// The folder and system chosen last time, kept with the project's other build files.
		let text = scope String();
		if (mBuildFolder.IsEmpty && File.ReadAllText(BuildChoicePath(.. scope .()), text) case .Ok)
		{
			var lines = text.Split('\n');
			if (lines.GetNext() case .Ok(let system))
				mBuildTarget = system == "windows" ? .Windows : system == "web" ? .Web : system == "macos" ? .MacOS : .Linux;
			// macOS games are built on a Mac only.
			if (mBuildTarget == .MacOS && HostTarget != .MacOS)
				mBuildTarget = HostTarget;
			if (lines.GetNext() case .Ok(let folder))
				mBuildFolder.Set(folder);
		}
		if (mBuildFolder.IsEmpty)
			mBuildFolder.AppendF("{}/Builds", Project.Current.Path);
	}

	/// The game's own folder inside the chosen one, named for the game and the system.
	void BuildOutputFolder(String outPath)
	{
		outPath.Append(mBuildFolder);
		while (outPath.Length > 1 && (outPath.EndsWith('/') || outPath.EndsWith('\\')))
			outPath.RemoveFromEnd(1);
		outPath.AppendF("/{}-{}", Project.Current.Name, mBuildTarget);
	}

	/// A C# project (no Beef of its own). Only C# games are exported; a Beef project needs an older Tallow.
	static bool IsCSharpProject => !File.Exists(scope $"{Project.Current.Path}/BeefProj.toml");

	/// The engine's precompiled player for a desktop system, as the export ships it.
	static void PlayerPath(BuildTarget target, String outPath)
	{
		let platform = target == .Windows ? "Win64" : target == .MacOS ? "macOS" : "Linux64";
		outPath.AppendF("{}/Player/build/Release_{}/TallowPlayer/TallowPlayer{}", Project.Current.EngineRoot, platform, target == .Windows ? ".exe" : "");
	}

	/// The system this editor runs on, as a build target.
	static BuildTarget HostTarget
	{
		get
		{
#if BF_PLATFORM_WINDOWS
			return .Windows;
#elif BF_PLATFORM_MACOS
			return .MacOS;
#else
			return .Linux;
#endif
		}
	}

	/// Whether the engine has the player for a desktop system: engine packages carry Linux, Windows and macOS ones;
	/// an engine source checkout builds the one for this machine.
	static bool PlayerAvailable(BuildTarget target) =>
		File.Exists(PlayerPath(target, .. scope .())) || (target == HostTarget && Directory.Exists(scope $"{Project.Current.EngineRoot}/Player/src"));

	/// Whether the engine has the web player's pieces (packages carry them; a source checkout makes them with
	/// Tallow.Build web-setup --engine-pieces).
	static bool WebPiecesAvailable()
	{
		let root = Project.Current.EngineRoot;
		return File.Exists(scope $"{root}/build/native-web-dotnet/libtallow_native.a") && Directory.Exists(scope $"{root}/Engine/assets/shaders/webgl")
			&& (File.Exists(scope $"{root}/build/web-player/libTallowPlayer_Release.a") || Directory.Exists(scope $"{root}/Player/src"));
	}

	/// Whether a .NET with the wasm-tools workload (what web exports compile with) is installed: Tallow.Build
	/// web-setup puts it into Tallow's own .NET or a private copy.
	static bool WebDotNetReady()
	{
		let roots = scope List<String>();
		defer { ClearAndDeleteItems!(roots); }
		for (let name in StringView[2]("TALLOW_WEB_DOTNET", "DOTNET_ROOT"))
		{
			let value = new String();
			if ((Environment.GetEnvironmentVariable(name, value) case .Ok) && !value.IsEmpty)
				roots.Add(value);
			else
				delete value;
		}
		let home = scope String();
		if (!(Environment.GetEnvironmentVariable("TALLOW_WEB_HOME", home) case .Ok) || home.IsEmpty)
		{
			home.Clear();
#if BF_PLATFORM_WINDOWS
			Environment.GetEnvironmentVariable("LOCALAPPDATA", home).IgnoreError();
			home.Append("/tallow-web");
#elif BF_PLATFORM_MACOS
			Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
			home.Append("/Library/Application Support/tallow-web");
#else
			if (!(Environment.GetEnvironmentVariable("XDG_DATA_HOME", home) case .Ok) || home.IsEmpty)
			{
				home.Clear();
				Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
				home.Append("/.local/share");
			}
			home.Append("/tallow-web");
#endif
		}
		if (Directory.Exists(scope $"{home}/dotnet"))
			for (let entry in Directory.EnumerateDirectories(scope $"{home}/dotnet"))
				roots.Add(entry.GetFilePath(.. new .()));
		for (let root in roots)
		{
			if (!Directory.Exists(scope $"{root}/packs"))
				continue;
			for (let pack in Directory.EnumerateDirectories(scope $"{root}/packs"))
			{
				let name = pack.GetFileName(.. scope .());
				if (name.StartsWith("Microsoft.NET.Runtime.Emscripten.") && name.Contains(".Sdk."))
					return true;
			}
		}
		return false;
	}

	/// Whether NativeAOT can compile the game for a system here: on that system itself, and Windows also on Linux
	/// (with tools/windows/setup.sh's Windows SDK). The web always runs .NET in the page; macOS has JIT so far.
	public static bool NativeAotAvailable(BuildTarget target)
	{
		if (target == .Linux)
			return HostTarget == .Linux;
		if (target == .Windows)
			return HostTarget == .Windows || HostTarget == .Linux;
		return false;
	}

	/// Whether the chosen system can be built for now.
	bool TargetReady(BuildTarget target) => target == .Web ? WebPiecesAvailable() && WebDotNetReady() : PlayerAvailable(target);

	void DrawBuildWindow()
	{
		using (sPickLock.Enter())
		{
			if (sPickReady)
			{
				mBuildFolder.Set(sPicked);
				sPickReady = false;
				mBuildMessage.Clear();
			}
		}
		if (mBuildNowPending && !mCheckRunning && mBusyFrames == 0)
		{
			mBuildNowPending = false;
			mWantBuildGame = true;
			mBusyFrames = 3;
		}
		if (!mShowBuild)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.pos.x + viewport.size.x * 0.5f, viewport.pos.y + viewport.size.y * 0.4f), ImGui.Cond.Appearing, .(0.5f, 0.5f));
		// As tall as what is in it, every frame: the notes under the buttons come and go.
		ImGui.SetNextWindowSize(.(640, 0), ImGui.Cond.Always);
		if (ImGui.Begin("Build", &mShowBuild, ImGui.WindowFlags.NoDocking | ImGui.WindowFlags.NoCollapse))
		{
			DrawBuildTarget();
			DrawGameBuildOptions(Project.Current);
			let ready = IsCSharpProject && TargetReady(mBuildTarget);
			if (!ready)
				DrawBuildSetupHint();
			let output = scope String();
			DrawBuildFolder(output);
			DrawBuildButtons(ready, output);
		}
		ImGui.End();
	}

	/// Which system the game is built for: Linux, Windows and the web from any machine (as far as the engine has the
	/// player for it), macOS on a Mac only.
	void DrawBuildTarget()
	{
		if (mBuildTarget == .MacOS && HostTarget != .MacOS)
			mBuildTarget = HostTarget;
		ImGui.SeparatorText("For");
		for (let target in BuildTarget[4](.Linux, .Windows, .MacOS, .Web))
		{
			if (target == .MacOS && HostTarget != .MacOS)
				continue;
			if (target != .Linux)
				ImGui.SameLine();
			if (ImGui.RadioButton(target == .MacOS ? "macOS" : target.ToString(.. scope .()), mBuildTarget == target))
			{
				mBuildTarget = target;
				mBuildMessage.Clear();
			}
		}
		if (mBuildTarget == .Web)
		{
			ImGui.SameLine();
			ImGui.TextDisabled("Played in a browser, on computers and phones");
		}
	}

	/// A game's options: starting full screen, and how its assets are packed. A web page fills the browser window,
	/// and full screen is the player's choice; its assets are always packed.
	void DrawGameBuildOptions(Project project)
	{
		if (mBuildTarget != .Web)
		{
			ImGui.SeparatorText("Window");
			if (ImGui.Checkbox("Start in fullscreen", ref project.Fullscreen))
				project.Save();
			ImGui.SameLine();
			ImGui.TextDisabled(project.Fullscreen ? "The game fills the screen when it starts" : "The game starts in a window");
		}
		// A C# game is compiled to native code (NativeAOT) or runs on .NET (JIT). A web build always has .NET inside
		// the page; NativeAOT compiles only on the system it is for (and Windows on Linux).
		let nativeAot = project.NativeAot && NativeAotAvailable(mBuildTarget);
		if (IsCSharpProject && mBuildTarget != .Web)
		{
			ImGui.SeparatorText("C# runtime");
			if (!NativeAotAvailable(mBuildTarget))
				ImGui.TextDisabled(mBuildTarget == .MacOS ? "macOS builds run C# on .NET (JIT)" : scope $"Built here, C# runs on .NET (JIT): NativeAOT for {mBuildTarget} is compiled on {mBuildTarget}");
			else
			{
				if (ImGui.RadioButton("NativeAOT (recommended, default)", project.NativeAot))
				{
					project.NativeAot = true;
					project.Save();
				}
				ImGui.SameLine();
				ImGui.TextDisabled("Compiled to native code: no .NET or game assemblies shipped, quick to start");
				if (ImGui.RadioButton("JIT (compatibility/debug)", !project.NativeAot))
				{
					project.NativeAot = false;
					project.Save();
				}
				ImGui.SameLine();
				ImGui.TextDisabled("The game's assemblies on .NET, as in the editor");
			}
			if (!nativeAot)
			{
				if (ImGui.Checkbox("Include .NET", ref project.BundleDotNet))
					project.Save();
				ImGui.SameLine();
				ImGui.TextDisabled(project.BundleDotNet ? "Players need nothing installed (about 70 MB more)" : scope $"Smaller, but players must install .NET {CSharpRuntime.RequiredDotNetMajor}");
			}
		}
		ImGui.SeparatorText("Assets");
		ImGui.BeginDisabled(mBuildTarget == .Web);
		if (ImGui.Checkbox("Compress textures", ref project.CompressTextures))
			project.Save();
		ImGui.SameLine();
		ImGui.TextDisabled(mBuildTarget == .Web ? "Web builds keep pictures as they are" : project.CompressTextures ? "A quarter to an eighth of the video memory, and quicker to load" : "Pictures as they are, decoded when loaded");
		if (ImGui.Checkbox("Pack assets into one file", ref project.PackAssets))
			project.Save();
		ImGui.EndDisabled();
		ImGui.SameLine();
		ImGui.TextDisabled(project.PackAssets ? "game.tpak: not readable or editable with ordinary tools" : "Loose files, as they are in the project");
		if (!project.PackAssets)
			return;
		if (ImGui.Checkbox("Compress the pack", ref project.PackCompress))
			project.Save();
		ImGui.SameLine();
		ImGui.TextDisabled(project.PackCompress ? "Smaller to send; files are unpacked as they load" : "Full size; nothing to unpack when loading");
		if (ImGui.Checkbox("A pack for each scene", ref project.PackSplit))
			project.Save();
		ImGui.SameLine();
		ImGui.TextDisabled(project.PackSplit ? "What only one scene uses goes in its own pack: updates stay small" : "Everything in game.tpak");
		if (project.PackSplit)
		{
			ImGui.SetNextItemWidth(-1);
			if (ImGui.InputText("##packshared", project.PackShared, 0, "Always shared, e.g. Models/prop_*.glb; Audio/*"))
				project.Save();
			ImGui.TextDisabled("Files your scripts load by a name they build: a build cannot find those by reading.");
		}
	}

	/// This machine or engine is not set up to build for the chosen system yet: why, and the command that sets it up.
	void DrawBuildSetupHint()
	{
		ImGui.PushTextWrapPos(0);
		defer ImGui.PopTextWrapPos();
		if (!IsCSharpProject)
		{
			ImGui.TextColored(EditorTheme.Warning, "This project has Beef gameplay scripts. This Tallow builds C# games only: convert the scripts to C#, or build the project with an older Tallow.");
			return;
		}
		let root = Project.Current.EngineRoot;
		if (mBuildTarget != .Web)
		{
			ImGui.TextColored(EditorTheme.Warning, scope $"This engine has no {mBuildTarget == .MacOS ? "macOS" : mBuildTarget.ToString(.. scope .())} player. The engine downloads on the release page carry the Linux and Windows players (and the macOS one, for Macs); an engine built from source has the one for the machine that built it.");
			return;
		}
		let command = scope String();
		Terminal.AppendBuildTool(root, command);
		if (!WebPiecesAvailable())
		{
			ImGui.TextColored(EditorTheme.Warning, "This engine has no web player. The engine downloads on the release page carry it; in an engine source checkout, with the Beef compiler and CMake installed, make it with:");
			command.Append(" web-setup --engine-pieces");
		}
		else
		{
			ImGui.TextColored(EditorTheme.Warning, "This machine is not set up to build for the web yet. Run this once in a terminal (it installs .NET's WebAssembly tools, about 1 GB):");
			command.Append(" web-setup");
		}
		ImGui.Text(command);
		ImGui.SameLine();
		if (ImGui.SmallButton("Copy"))
			ImGui.SetClipboardText(command);
	}

	/// The folder to build into, and what will be put there. `output` is set to the build's own folder inside it.
	void DrawBuildFolder(String output)
	{
		ImGui.SeparatorText("Folder");
		ImGui.SetNextItemWidth(ImGui.GetContentRegionAvail().x - 110);
		if (ImGui.InputText("##buildfolder", mBuildFolder))
			mBuildMessage.Clear();
		ImGui.SameLine();
		if (ImGui.Button("Choose...", .(100, 0)))
			SDL.SDL_ShowOpenFolderDialog( => OnFolderPicked, null, Window, mBuildFolder.IsEmpty ? null : mBuildFolder.CStr(), false);
		BuildOutputFolder(output);
		ImGui.PushTextWrapPos(0);
		if (mBuildTarget == .Web)
			ImGui.TextDisabled(scope $"The game is put in {output}: a web page (index.html) with the game and its assets. Put that folder on any web server, such as GitHub Pages or itch.io, and share the address. Play in Browser tries it on this machine. An earlier build of the game there is replaced.");
		else
			ImGui.TextDisabled(scope $"The game is put in {output}. That folder holds everything the game needs and nothing else: move it anywhere, or send it to somebody. An earlier build of the game there is replaced.");
		ImGui.PopTextWrapPos();
	}

	/// Build, and once a build has worked, Show Folder (and for the web, Play in Browser); then what happened.
	void DrawBuildButtons(bool ready, StringView output)
	{
		let building = mWantBuildGame;
		ImGui.Spacing();
		ImGui.BeginDisabled(!ready || building || mBuildFolder.IsEmpty);
		if (ImGui.Button(building ? "Building..." : "Build", .(140, 0)))
		{
			File.WriteAllText(BuildChoicePath(.. scope .()), scope $"{mBuildTarget.ToString(.. scope .())..ToLower()}\n{mBuildFolder}\n").IgnoreError();
			mBuildMessage.Set("Building. This takes a minute; the editor does not respond until it is done.");
			mBuildSucceeded = false;
			mWantBuildGame = true;
			mBusyFrames = 3;
		}
		ImGui.EndDisabled();
		if (mBuildSucceeded)
		{
			ImGui.SameLine();
			if (ImGui.Button("Show Folder"))
				ShowInFileManager(output);
			if (mBuildTarget == .Web)
			{
				ImGui.SameLine();
				if (ImGui.Button("Play in Browser"))
					PlayInBrowser(output);
			}
		}
		if (!mBuildMessage.IsEmpty)
		{
			ImGui.PushTextWrapPos(0);
			ImGui.Text(mBuildMessage);
			ImGui.PopTextWrapPos();
		}
	}

	/// Serves a web build from this machine (a page loaded from a file cannot fetch its own assets) and opens it in
	/// the desktop's browser.
	void PlayInBrowser(StringView folder)
	{
		const int Port = 8765;
		if (!mWebServerStarted)
		{
			// Serves the build folder's parent, so a rebuild (which replaces the folder) is picked up without a restart.
			let parent = System.IO.Path.GetDirectoryPath(folder, .. scope .());
			let command = scope String();
			Terminal.AppendBuildTool(Project.Current.EngineRoot, command);
			command.Append(" serve ");
			Terminal.Quote(parent, command);
			command.AppendF(" --port {}", Port);
			Terminal.RunDetached(command);
			mWebServerStarted = true;
		}
		let name = System.IO.Path.GetFileName(folder, .. scope .());
		Terminal.Open(scope $"http://127.0.0.1:{Port}/{name}/");
	}

	/// Opens a folder in the desktop's file manager.
	void ShowInFileManager(StringView folder)
	{
		Terminal.Open(folder);
	}
}
