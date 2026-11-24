using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// Platform modules (Tallow.Build platform-install/-remove) and what Android games need (android-status/-set/
/// -install-ndk), for the Platforms window and the Build window. Each command runs on a thread of its own, so the
/// windows keep drawing, and android-status is asked again after every one.
static class PlatformModules
{
	static Monitor sLock = new .() ~ delete _;
	static Dictionary<String, String> sAndroid = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static String sStatus = new .() ~ delete _;
	static bool sBusy;
	static bool sFailed;
	static bool sChecked;

	/// The Android Studio folder typed or chosen in the window, for when Tallow did not find it.
	public static String StudioFolder = new .() ~ delete _;

	// The desktop's dialogs answer later, perhaps on another thread.
	static String sPicked = new .() ~ delete _;
	static bool sPickedStudio, sPickedModule;

	/// A command is running.
	public static bool Busy => Volatile.Read(ref sBusy);
	/// android-status has answered at least once.
	public static bool Checked => Volatile.Read(ref sChecked);

	/// What the last command said, and whether it failed.
	public static bool GetStatus(String output)
	{
		using (sLock.Enter())
			output.Append(sStatus);
		return Volatile.Read(ref sFailed);
	}

	/// A value android-status gave (studio, sdk, java, ndk, ready, message...).
	public static void Android(StringView key, String output)
	{
		using (sLock.Enter())
		{
			if (sAndroid.TryGetValueAlt(key, let value))
				output.Append(value);
		}
	}

	public static bool AndroidReady => Android("ready", .. scope .()) == "1";

	/// Whether the engine has the Android player (the module's files).
	public static bool AndroidInstalled(StringView engineRoot)
	{
		for (let abi in StringView[2]("arm64-v8a", "x86_64"))
			if (!File.Exists(scope $"{engineRoot}/Player/build/Release_Android/{abi}/libmain.so"))
				return false;
		return File.Exists(scope $"{engineRoot}/Player/build/Release_Android/classes.dex");
	}

	/// An engine built from source makes its modules itself (an engine package has tallow-version.json).
	public static bool SourceEngine(StringView engineRoot) =>
		Directory.Exists(scope $"{engineRoot}/Player/src") && !File.Exists(scope $"{engineRoot}/tallow-version.json");

	/// Runs Tallow.Build with args and returns its exit code; output gets what it printed.
	static int RunTool(StringView engineRoot, StringView args, String output)
	{
		let log = scope String();
		Path.GetTempPath(log);
		log.AppendF("/tallow-platforms-{}-{}.txt", System.Diagnostics.Process.CurrentId, Thread.CurrentThread.Id);
		let command = scope String();
		Terminal.AppendBuildTool(engineRoot, command);
		command.AppendF(" {} > ", args);
		Terminal.Quote(log, command);
		command.Append(" 2>&1");
		let code = Terminal.Run(command);
		File.ReadAllText(log, output).IgnoreError();
		File.Delete(log).IgnoreError();
		return code;
	}

	static void ReadAndroidStatus(StringView engineRoot)
	{
		let text = scope String();
		RunTool(engineRoot, "android-status", text);
		using (sLock.Enter())
		{
			for (let entry in sAndroid)
			{
				delete entry.key;
				delete entry.value;
			}
			sAndroid.Clear();
			for (let line in text.Split('\n'))
			{
				let eq = line.IndexOf(" = ");
				if (eq <= 0)
					continue;
				sAndroid[new String(line.Substring(0, eq))] = new String(line.Substring(eq + 3)..Trim());
			}
		}
		Volatile.Write(ref sChecked, true);
	}

	/// Runs a Tallow.Build command (empty: only asks android-status again), saying `doing` meanwhile.
	static void Start(StringView engineRoot, StringView args, StringView doing)
	{
		if (Busy)
			return;
		Volatile.Write(ref sBusy, true);
		Volatile.Write(ref sFailed, false);
		using (sLock.Enter())
			sStatus.Set(doing);
		let root = new String(engineRoot);
		let command = new String(args);
		let thread = new Thread(new () =>
			{
				if (!command.IsEmpty)
				{
					let output = scope String();
					let code = RunTool(root, command, output);
					// Its last line says what happened (or what went wrong).
					var last = StringView();
					for (let line in output.Split('\n', .RemoveEmptyEntries))
						if (!line.IsWhiteSpace)
							last = line;
					using (sLock.Enter())
						sStatus.Set(last);
					if (code != 0)
						Volatile.Write(ref sFailed, true);
				}
				else
				{
					using (sLock.Enter())
						sStatus.Clear();
				}
				ReadAndroidStatus(root);
				delete root;
				delete command;
				Volatile.Write(ref sBusy, false);
			});
		thread.Start(true);
	}

	public static void Refresh(StringView engineRoot) => Start(engineRoot, "", "Looking for Android Studio...");

	static void Arg(StringView text, String command)
	{
		command.Append(' ');
		Terminal.Quote(text, command);
	}

	public static void InstallAndroid(StringView engineRoot, StringView fromZip = default)
	{
		let command = scope String("platform-install android --engine-root");
		Arg(engineRoot, command);
		if (!fromZip.IsEmpty)
		{
			command.Append(" --from");
			Arg(fromZip, command);
		}
		Start(engineRoot, command, "Downloading the Android platform (about 70 MB)...");
	}

	public static void RemoveAndroid(StringView engineRoot)
	{
		let command = scope String("platform-remove android --engine-root");
		Arg(engineRoot, command);
		Start(engineRoot, command, "Removing the Android platform...");
	}

	/// Installs a built game on the connected phone or running emulator, and starts it.
	public static void RunOnDevice(StringView engineRoot, StringView buildFolder)
	{
		let command = scope String("android-run");
		Arg(buildFolder, command);
		Start(engineRoot, command, "Installing on the device...");
	}

	public static void InstallNdk(StringView engineRoot) =>
		Start(engineRoot, "android-install-ndk", "Installing Android's NDK into the SDK (about 700 MB, once)...");

	public static void UseStudioFolder(StringView engineRoot)
	{
		let command = scope String("android-set --studio");
		Arg(StudioFolder, command);
		Start(engineRoot, command, "Looking in that folder...");
	}

	static void OnStudioPicked(void* userData, char8** files, int32 filter)
	{
		if (files == null || files[0] == null)
			return;
		using (sLock.Enter())
		{
			sPicked.Set(StringView(files[0]));
			sPickedStudio = true;
		}
	}

	static void OnModulePicked(void* userData, char8** files, int32 filter)
	{
		if (files == null || files[0] == null)
			return;
		using (sLock.Enter())
		{
			sPicked.Set(StringView(files[0]));
			sPickedModule = true;
		}
	}

	public static void ChooseStudioFolder(void* window) =>
		SDL.SDL_ShowOpenFolderDialog( => OnStudioPicked, null, window, StudioFolder.IsEmpty ? null : StudioFolder.CStr(), false);

	public static void ChooseModuleFile(void* window)
	{
		SDL.DialogFileFilter filter = .() { name = "Tallow platform module", pattern = "zip" };
		SDL.SDL_ShowOpenFileDialog( => OnModulePicked, null, window, &filter, 1, null, false);
	}

	/// Takes what a dialog chose, once a frame: a Studio folder is used at once, a module file installed.
	public static void TakePicked(StringView engineRoot)
	{
		let picked = scope String();
		bool studio, module;
		using (sLock.Enter())
		{
			studio = sPickedStudio;
			module = sPickedModule;
			sPickedStudio = sPickedModule = false;
			picked.Set(sPicked);
		}
		if (studio)
		{
			StudioFolder.Set(picked);
			UseStudioFolder(engineRoot);
		}
		if (module)
			InstallAndroid(engineRoot, picked);
	}
}

/// The Platforms window (Build > Platforms...): the systems this Tallow builds games for. Linux, Windows, macOS and
/// the web come with every Tallow; others are modules added and removed here, so the download stays small and
/// platforms that cannot be public (consoles) are added from a file.
extension EditorApp
{
	bool mShowPlatforms;

	void OpenPlatformsWindow()
	{
		mShowPlatforms = true;
		PlatformModules.Refresh(Project.Current.EngineRoot);
	}

	void DrawPlatformsWindow()
	{
		if (Project.Current == null)
			return;
		let root = Project.Current.EngineRoot;
		PlatformModules.TakePicked(root);
		if (!mShowPlatforms)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.pos.x + viewport.size.x * 0.5f, viewport.pos.y + viewport.size.y * 0.4f), ImGui.Cond.Appearing, .(0.5f, 0.5f));
		ImGui.SetNextWindowSize(.(620, 0), ImGui.Cond.Always);
		if (ImGui.Begin("Platforms", &mShowPlatforms, ImGui.WindowFlags.NoDocking | ImGui.WindowFlags.NoCollapse))
		{
			ImGui.PushTextWrapPos(0);
			ImGui.TextDisabled("The systems this Tallow builds games for. Linux, Windows, macOS and the web come with every Tallow; add others here when you need them.");
			ImGui.SeparatorText("Included");
			ImGui.Text("Linux, Windows, macOS, Web");

			ImGui.SeparatorText("Android");
			let installed = PlatformModules.AndroidInstalled(root);
			let busy = PlatformModules.Busy;
			ImGui.Text(installed ? "Installed" : "Not installed");
			ImGui.SameLine();
			ImGui.TextDisabled("Phones and tablets, Android 10 and later");
			ImGui.BeginDisabled(busy);
			if (!installed && PlatformModules.SourceEngine(root))
				ImGui.TextDisabled("This engine was built from source: make the Android player with tools/android/build_player.sh.");
			else if (!installed)
			{
				if (ImGui.Button("Add Android"))
					PlatformModules.InstallAndroid(root);
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("Downloads the Android player made with this Tallow version (about 70 MB) from Tallow's release page.");
			}
			else if (ImGui.Button("Remove Android"))
				PlatformModules.RemoveAndroid(root);
			ImGui.SameLine();
			if (ImGui.Button("Add from file..."))
				PlatformModules.ChooseModuleFile(Window);
			ImGui.EndDisabled();
			DrawAndroidRequirements(root);

			let status = scope String();
			let failed = PlatformModules.GetStatus(status);
			if (!status.IsEmpty)
			{
				ImGui.Spacing();
				if (failed)
					ImGui.TextColored(EditorTheme.Warning, status);
				else
					ImGui.TextDisabled(status);
			}

			ImGui.SeparatorText("Consoles");
			ImGui.TextDisabled("Console platforms come from each console maker's developer programme and are never part of the public Tallow. Once you have a console module, add its file with Add from file.");
			ImGui.PopTextWrapPos();
		}
		ImGui.End();
	}

	/// What Android games need: Android Studio, found (where) or not, with a folder to use when it was not found,
	/// and the NDK (installed by the first Android build, or here).
	void DrawAndroidRequirements(StringView root)
	{
		ImGui.PushTextWrapPos(0);
		defer ImGui.PopTextWrapPos();
		if (!PlatformModules.Checked)
		{
			ImGui.TextDisabled("Looking for Android Studio...");
			return;
		}
		let message = PlatformModules.Android("message", .. scope .());
		let studio = PlatformModules.Android("studio", .. scope .());
		let sdk = PlatformModules.Android("sdk", .. scope .());
		let ndk = PlatformModules.Android("ndk", .. scope .());
		if (message.IsEmpty)
		{
			ImGui.TextDisabled(scope $"Android Studio: {(studio.IsEmpty ? "found" : studio)}");
			ImGui.TextDisabled(scope $"Android SDK: {sdk}");
			if (ndk.IsEmpty)
			{
				ImGui.TextDisabled("NDK: not yet; the first Android build installs it into the SDK (about 700 MB, once).");
				ImGui.SameLine();
				ImGui.BeginDisabled(PlatformModules.Busy);
				if (ImGui.SmallButton("Install now"))
					PlatformModules.InstallNdk(root);
				ImGui.EndDisabled();
			}
			else
				ImGui.TextDisabled(scope $"NDK: {ndk}");
			return;
		}
		ImGui.TextColored(EditorTheme.Warning, message);
		if (ImGui.Button("Get Android Studio"))
			Terminal.Open("https://developer.android.com/studio");
		ImGui.TextDisabled("Installed somewhere Tallow does not look? Choose Android Studio's folder (or its SDK folder):");
		ImGui.SetNextItemWidth(ImGui.GetContentRegionAvail().x - 220);
		ImGui.InputText("##androidstudio", PlatformModules.StudioFolder, 0, "Android Studio folder");
		ImGui.SameLine();
		ImGui.BeginDisabled(PlatformModules.Busy);
		if (ImGui.Button("Choose..."))
			PlatformModules.ChooseStudioFolder(Window);
		ImGui.SameLine();
		ImGui.BeginDisabled(PlatformModules.StudioFolder.IsEmpty);
		if (ImGui.Button("Use"))
			PlatformModules.UseStudioFolder(root);
		ImGui.EndDisabled();
		ImGui.SameLine();
		if (ImGui.Button("Check again"))
			PlatformModules.Refresh(root);
		ImGui.EndDisabled();
	}
}
