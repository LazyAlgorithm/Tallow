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
	/// Built on a Mac (Apple silicon), which builds only macOS and web games (docs/macos.md).
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
	/// Build the editor itself (a copy of Tallow for another machine) instead of the game.
	bool mBuildEditor;
	bool mBuildSucceeded;
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
#if BF_PLATFORM_MACOS
			if (mBuildTarget != .Web)
				mBuildTarget = .MacOS;
#endif
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
		outPath.AppendF("/{}-{}", mBuildEditor ? "Tallow" : Project.Current.Name, mBuildTarget);
	}

	/// Whether this machine can build web games (tools/web/setup.sh has been run).
	bool WebBuildReady()
	{
		return File.Exists(scope $"{Project.Current.EngineRoot}/build/native-web/libtallow_native.a") && Directory.Exists(scope $"{Project.Current.EngineRoot}/Engine/assets/shaders/webgl");
	}

	/// Whether this machine can build Windows games (tools/windows/setup.sh has been run).
	bool WindowsBuildReady()
	{
#if BF_PLATFORM_WINDOWS
		return true;
#else
		let toolchain = scope String();
		if (!(Environment.GetEnvironmentVariable("TALLOW_WIN", toolchain) case .Ok) || toolchain.IsEmpty)
		{
			Environment.GetEnvironmentVariable("HOME", toolchain).IgnoreError();
			toolchain.Append("/.local/share/tallow-win");
		}
		return File.Exists(scope $"{toolchain}/beef/bin/BeefBuild.exe") && File.Exists(scope $"{Project.Current.EngineRoot}/build/native-win/tallow_native.lib");
#endif
	}

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
		if (!mShowBuild)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.pos.x + viewport.size.x * 0.5f, viewport.pos.y + viewport.size.y * 0.4f), ImGui.Cond.Appearing, .(0.5f, 0.5f));
		// As tall as what is in it, every frame: the notes under the buttons come and go.
		ImGui.SetNextWindowSize(.(640, 0), ImGui.Cond.Always);
		if (ImGui.Begin("Build", &mShowBuild, ImGui.WindowFlags.NoDocking | ImGui.WindowFlags.NoCollapse))
		{
			DrawBuildTarget();
			if (!mBuildEditor)
				DrawGameBuildOptions(Project.Current);
			let ready = mBuildTarget == .Linux || mBuildTarget == .MacOS || (mBuildTarget == .Windows ? WindowsBuildReady() : WebBuildReady());
			if (!ready)
				DrawBuildSetupHint();
			let output = scope String();
			DrawBuildFolder(output);
			DrawBuildButtons(ready, output);
		}
		ImGui.End();
	}

	/// The system this editor runs on, which it can always build for.
#if BF_PLATFORM_MACOS
	static BuildTarget NativeTarget => .MacOS;
#else
	static BuildTarget NativeTarget => .Linux;
#endif

	/// What is built (the game or the editor) and for which system. A Windows machine builds Windows games, a Mac
	/// macOS and web ones; the other choices need Linux.
	void DrawBuildTarget()
	{
#if BF_PLATFORM_WINDOWS
		mBuildTarget = .Windows;
		mBuildEditor = false;
#else
	#if BF_PLATFORM_MACOS
		if (mBuildTarget == .Linux || mBuildTarget == .Windows)
			mBuildTarget = .MacOS;
	#endif
		ImGui.SeparatorText("Build");
		if (ImGui.RadioButton("Game", !mBuildEditor))
		{
			mBuildEditor = false;
			mBuildMessage.Clear();
		}
		ImGui.SameLine();
		if (ImGui.RadioButton("Editor", mBuildEditor))
		{
			mBuildEditor = true;
			mBuildMessage.Clear();
			if (mBuildTarget == .Web)
				mBuildTarget = NativeTarget;
		}
		if (mBuildEditor)
		{
			ImGui.SameLine();
			ImGui.TextDisabled("Tallow itself, to use on another machine");
		}
		ImGui.SeparatorText("For");
	#if BF_PLATFORM_MACOS
		// A Mac builds for itself and the web.
		if (ImGui.RadioButton("macOS", mBuildTarget == .MacOS))
		{
			mBuildTarget = .MacOS;
			mBuildMessage.Clear();
		}
	#else
		if (ImGui.RadioButton("Linux", mBuildTarget == .Linux))
		{
			mBuildTarget = .Linux;
			mBuildMessage.Clear();
		}
		ImGui.SameLine();
		if (ImGui.RadioButton("Windows", mBuildTarget == .Windows))
		{
			mBuildTarget = .Windows;
			mBuildMessage.Clear();
		}
	#endif
		// The editor itself does not run in a browser; only games do.
		ImGui.BeginDisabled(mBuildEditor);
		ImGui.SameLine();
		if (ImGui.RadioButton("Web", mBuildTarget == .Web))
		{
			mBuildTarget = .Web;
			mBuildMessage.Clear();
		}
		ImGui.EndDisabled();
		if (mBuildTarget == .Web)
		{
			ImGui.SameLine();
			ImGui.TextDisabled("Played in a browser, on computers and phones");
		}
#endif
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

	/// This machine is not set up to build for the chosen system yet: the command that sets it up, to copy.
	void DrawBuildSetupHint()
	{
		let web = mBuildTarget == .Web;
		ImGui.PushTextWrapPos(0);
		if (web)
			ImGui.TextColored(EditorTheme.Warning, "This machine is not set up to build for the web yet. Run this once in a terminal (it downloads Emscripten, about 1 GB):");
		else
			ImGui.TextColored(EditorTheme.Warning, "This machine is not set up to build for Windows yet. Run this once in a terminal (it downloads about 3 GB, including Microsoft's Windows libraries under their licence):");
		ImGui.PopTextWrapPos();
		let command = web ? scope $"{Project.Current.EngineRoot}/tools/web/setup.sh" : scope $"{Project.Current.EngineRoot}/tools/windows/setup.sh --accept-license";
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
		if (mBuildEditor)
			ImGui.TextDisabled(scope $"The editor is put in {output}. That folder holds the launcher, the editor and the engine, and nothing else: move it anywhere, or copy it to another machine. That machine needs the Beef compiler; the folder's tallow-package.txt says what else. An earlier copy there is replaced.");
		else if (mBuildTarget == .Web)
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
			if (mBuildTarget == .Web && !mBuildEditor)
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
			let command = scope String(Terminal.Python)..Append(" -m http.server ");
			command.AppendF("{} --bind 127.0.0.1 --directory ", Port);
			Terminal.Quote(parent, command);
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
