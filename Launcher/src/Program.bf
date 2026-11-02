using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;
using Tallow.Editor;
using Bgfx;

namespace Tallow.Launcher;

/// The project hub: pick a recent project, add an existing one, or create a new one.
/// Opening a project compiles its scripts and starts its editor.
///
/// Command line: --create <folder> [--sample | --showcase]   create a project without the window
///               --open <folder> [--upgrade]               open a project, moving an older one to this engine
///               --open <folder>                build and open a project's editor directly
///               --build-project <folder>       compile without opening a window
class LauncherApp : Application
{
	String mName = new .("MyGame") ~ delete _;
	String mLocation = new .() ~ delete _;
	String mExisting = new .() ~ delete _;
	String mMessage = new .() ~ delete _;
	String mPendingOpen = new .() ~ delete _;
	String mUpgradeFrom = new .() ~ delete _;
	String mUpgradeTo = new .() ~ delete _;
	bool mUpgradePrompt;
	String mEngineRoot = new .() ~ delete _;
	ProjectTemplate mTemplate = .Sample;
	/// Tools Tallow needs that were not found, when the launcher started.
	List<String> mMissingTools = new .() ~ DeleteContainerAndItems!(_);
	bool mMessageIsError;
	bool mSetupPending;
	bool mSetupFailed;
	bool mSetupRunning;
	bool mSetupFinished;
	int32 mSetupExitCode;
	Thread mSetupThread ~ { if (_ != null) { _.Join(); delete _; } };
	int32 mOpenCountdown;
	int32 mSelected = -1;

	public this()
	{
		Width = 980;
		Height = 620;
		Title.Set("Tallow");
	}

	protected override bool OnInit()
	{
		let ini = new String();
		RecentProjects.GetConfigFolder(ini);
		ini.Append("launcher.ini");
		mIni = ini;
		if (!ImGui.tn_imgui_init(Window, mIni.CStr(), 1.0f))
			return false;
		ProjectGenerator.FindEngineRoot(mEngineRoot);
		if (!mEngineRoot.IsEmpty)
			SetWindowIcon(scope $"{mEngineRoot}/icon.png");
		RecentProjects.Load();
		Toolchain.Apply();
		Toolchain.FindMissing(mMissingTools);
		let home = scope String();
#if BF_PLATFORM_WINDOWS
		Environment.GetEnvironmentVariable("USERPROFILE", home).IgnoreError();
		home.Replace('\\', '/');
#else
		Environment.GetEnvironmentVariable("HOME", home).IgnoreError();
#endif
		if (!home.IsEmpty)
			mLocation.AppendF("{}/TallowProjects", home);
		else
			mLocation.Set("TallowProjects");
		return true;
	}

	String mIni ~ delete _;

	protected override void OnShutdown()
	{
		if (Gfx.Initialized)
			ImGui.tn_imgui_shutdown();
	}

	protected override void OnEvent(ref SDL.Event event)
	{
		ImGui.tn_imgui_event(&event);
	}

	void SetMessage(StringView text, bool error)
	{
		mMessage.Set(text);
		mMessageIsError = error;
	}

	void RequestOpen(StringView path)
	{
		if (mMissingTools.Count > 0)
		{
			// Compiling would only fail: say what is missing first.
			SetMessage(MissingMessage(.. scope .()), true);
			return;
		}
		mPendingOpen.Set(path);
		mOpenCountdown = 3;
		SetMessage(scope $"Compiling {path} ..." , false);
	}

	/// Asks the engine's version tool about a project: "same", or "upgrade"/"newer" with the two versions after it.
	static void CheckProjectVersion(StringView path, String verdict, String from, String to)
	{
		verdict.Set("same");
		let root = scope String();
		if (!ProjectGenerator.FindEngineRoot(root))
			return;
		Directory.CreateDirectory(scope $"{path}/.tallow-reload").IgnoreError();
		let output = scope $"{path}/.tallow-reload/version-check.txt";
		if (RunVersionTool("check", path, root, output) != 0)
			return;
		let text = scope String();
		if (File.ReadAllText(output, text) case .Err)
			return;
		text.Trim();
		int part = 0;
		for (let word in text.Split('\t'))
		{
			(part == 0 ? verdict : (part == 1 ? from : to)).Set(word);
			part++;
		}
	}

	static int RunVersionTool(StringView action, StringView path, StringView root, StringView output)
	{
		let command = scope String();
		command.AppendF("{} ", Terminal.Python);
		Terminal.Quote(scope $"{root}/tools/engine_versions.py", command);
		command.AppendF(" {} ", action);
		Terminal.Quote(path, command);
		command.Append(" ");
		Terminal.Quote(root, command);
		command.Append(" > ");
		Terminal.Quote(output, command);
		return Terminal.Run(command);
	}

	/// The command-line version of the upgrade warning: --upgrade says yes to it.
	public static bool PrepareProject(StringView path, bool upgrade, String error)
	{
		Toolchain.Apply();
		let verdict = scope String();
		let from = scope String();
		let to = scope String();
		CheckProjectVersion(path, verdict, from, to);
		if (verdict == "same")
			return true;
		if (verdict == "upgrade" && upgrade)
			return UpgradeProject(path, error);
		if (verdict == "upgrade")
			error.Set(scope $"This project uses {from}, which is not installed. Add --upgrade to move it to {to}.");
		else
			error.Set(scope $"This project needs a newer engine ({from}) than this one ({to}).");
		return false;
	}

	/// Moves a project to the engine this launcher belongs to.
	public static bool UpgradeProject(StringView path, String error)
	{
		Toolchain.Apply();
		let root = scope String();
		if (!ProjectGenerator.FindEngineRoot(root) || RunVersionTool("upgrade", path, root, scope $"{path}/.tallow-reload/version-check.txt") != 0)
		{
			error.Set(scope $"{path} could not be upgraded to this Tallow engine.");
			return false;
		}
		return true;
	}

	/// Builds the project and starts its editor. Returns false with the compiler output on failure.
	public static bool OpenProject(StringView path, String error, bool buildOnly = false)
	{
		Toolchain.Apply();
		let project = scope Project();
		if (!project.Load(path))
		{
			error.Set(scope $"{path} is not a Tallow project (no project.tallow).");
			return false;
		}
		// Exact-version validation runs before any generated build files are changed.
		let lockPath = scope $"{project.Path}/tallow-engine.lock.json";
		if (File.Exists(lockPath))
		{
			let command = scope String();
			command.AppendF("{} ", Terminal.Python);
			Terminal.Quote(scope $"{project.EngineRoot}/tools/engine_versions.py", command);
			command.Append(" verify ");
			Terminal.Quote(project.Path, command);
			command.Append(" ");
			Terminal.Quote(project.EngineRoot, command);
			if (Terminal.Run(command) != 0)
			{
				error.Set("This project requires its pinned Tallow engine build. Open it with that version or install the missing version in Engine Manager.");
				return false;
			}
		}
		if (!project.Build(false))
		{
			error.Set("The project did not compile:\n");
			project.ReadBuildLog(error);
			return false;
		}
		if (buildOnly)
			return true;
		RecentProjects.Add(project.Path);
		let command = scope String();
		let exe = scope String();
		project.GetExecutablePath(exe, false);
		Terminal.Quote(exe, command);
		command.Append(" --editor --project ");
		Terminal.Quote(project.Path, command);
		Terminal.RunDetached(command);
		return true;
	}

	protected override void OnRender()
	{
		bgfx.set_view_clear(0, Gfx.ClearColor | Gfx.ClearDepth, BackgroundColor, 1.0f, 0);
		bgfx.touch(0);
		ImGui.tn_imgui_new_frame();

		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(viewport.workPos);
		ImGui.SetNextWindowSize(viewport.workSize);
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(22, 18));
		ImGui.Begin("Launcher", null, ImGui.WindowFlags.NoDecoration | ImGui.WindowFlags.NoMove | ImGui.WindowFlags.NoSavedSettings);
		ImGui.PopStyleVar();

		ImGui.Text("TALLOW");
		ImGui.SameLine();
		ImGui.TextDisabled("Projects");
		ImGui.Separator();
		ImGui.Spacing();
		if (mMissingTools.Count > 0)
			ImGui.BeginDisabled(true);

		let busy = mOpenCountdown > 0;
		ImGui.BeginDisabled(busy);
		let total = ImGui.GetContentRegionAvail();
		let footer = mMessageIsError && !mMessage.IsEmpty ? Math.Min(260.0f, Math.Max(total.y * 0.4f, 120.0f)) : 64.0f;

		ImGui.BeginChild("recent", .(total.x * 0.56f, total.y - footer), ImGui.ChildBorders);
		DrawRecentProjects();
		ImGui.EndChild();
		ImGui.SameLine();
		ImGui.BeginChild("create", .(0, total.y - footer), ImGui.ChildBorders);
		DrawNewProject();
		ImGui.EndChild();
		ImGui.Spacing();
		DrawProjectButtons();
		ImGui.EndDisabled();
		if (mMissingTools.Count > 0)
			ImGui.EndDisabled();
		if (!mMessage.IsEmpty)
			DrawLauncherMessage();
		ImGui.End();
		// Open and render the modal from the same ImGui popup ID scope.
		if (mMissingTools.Count > 0)
		{
			ImGui.OpenPopup("Development tools required");
			DrawSetupDialog();
		}
		if (mUpgradePrompt)
		{
			ImGui.OpenPopup("Project from another version");
			DrawUpgradeDialog();
		}
		ImGui.tn_imgui_render(250);
		if (mSetupPending)
		{
			mSetupPending = false;
			InstallMissingTools();
		}
		if (mSetupFinished)
		{
			mSetupThread.Join();
			delete mSetupThread;
			mSetupThread = null;
			mSetupFinished = false;
			mSetupRunning = false;
			if (mSetupExitCode != 0)
			{
				SetMessage(scope $"Dependency setup failed (exit {mSetupExitCode}). Check toolchain/install.log for details.", true);
				mSetupFailed = true;
			}
			else
			{
				Toolchain.Apply();
				ClearAndDeleteItems!(mMissingTools);
				Toolchain.FindMissing(mMissingTools);
				if (!mMissingTools.IsEmpty)
				{
					SetMessage("The installer finished, but required tools are still missing. Check toolchain/install.log.", true);
					mSetupFailed = true;
				}
			}
		}

		// The build blocks, so start it a few frames after the "Compiling" message is on screen.
		if (mOpenCountdown > 0 && --mOpenCountdown == 0)
			OpenPendingProject();
	}

	/// The standalone launcher owns first-run setup: Manager is never required.
	void DrawSetupDialog()
	{
		if (!ImGui.BeginPopupModal("Development tools required", null, ImGui.WindowFlags.AlwaysAutoResize))
			return;
		if (mSetupRunning)
		{
			ImGui.TextWrapped("Installing development tools in the background. This may take several minutes.");
			ImGui.TextWrapped("Installation log: Tallow/toolchain/install.log (under your Local AppData folder)");
		}
		else
		{
			ImGui.TextWrapped("Tallow needs the following tools to create, open and build projects:");
			for (let tool in mMissingTools)
				ImGui.BulletText(tool.CStr());
			if (mSetupFailed)
			{
				ImGui.TextWrapped("Setup did not complete. You can retry installation.");
				ImGui.TextWrapped(mMessage.CStr());
			}
			if (ImGui.Button(mSetupFailed ? "Retry installation" : "Install dependencies", .(190, 36)))
			{
				mSetupFailed = false;
				mSetupPending = true;
			}
			ImGui.SameLine();
			if (ImGui.Button("Exit Tallow", .(140, 36)))
				Running = false;
		}
		ImGui.EndPopup();
	}

	void InstallMissingTools()
	{
#if BF_PLATFORM_WINDOWS
		let script = scope $"{mEngineRoot}/tools/setup_dependencies.ps1";
		if (!File.Exists(script))
		{
			SetMessage("The shared development-tool installer is missing from this Tallow package.", true);
			mSetupFailed = true;
			return;
		}
		mSetupRunning = true;
		mSetupFinished = false;
		mSetupExitCode = -1;
		mSetupThread = new Thread(new => SetupWorker);
		mSetupThread.Start(false);
#else
		SetMessage("Automatic toolchain setup is not yet implemented for this operating system.", true);
		mSetupFailed = true;
#endif
	}

	/// Runs the same packaged Windows installer used by Manager without blocking rendering.
	void SetupWorker()
	{
#if BF_PLATFORM_WINDOWS
		let script = scope $"{mEngineRoot}/tools/setup_dependencies.ps1";
		let folder = scope String(Toolchain.Folder);
		Directory.CreateDirectory(folder).IgnoreError();
		let log = scope $"{folder}/install.log";
		let command = scope String("powershell.exe -NoProfile -ExecutionPolicy Bypass -File ");
		Terminal.Quote(script, command);
		command.Append(" > ");
		Terminal.Quote(log, command);
		command.Append(" 2>&1");
		mSetupExitCode = Terminal.Run(command);
#endif
		mSetupFinished = true;
	}

	/// What the window is cleared to behind the interface (RGBA).
	const uint32 BackgroundColor = 0x262626ff;

	/// The left side: the projects opened before, newest first. A double-click opens one.
	void DrawRecentProjects()
	{
		ImGui.TextDisabled("Recent projects");
		ImGui.Spacing();
		if (RecentProjects.Paths.Count == 0)
			ImGui.TextWrapped("No projects yet. Create one on the right.");
		for (int32 i = 0; i < (int32)RecentProjects.Paths.Count; i++)
		{
			let path = RecentProjects.Paths[i];
			let name = scope String();
			Path.GetFileName(path, name);
			ImGui.PushID(i);
			if (ImGui.Selectable("##row", mSelected == i, ImGui.SelectableFlags.AllowDoubleClick, .(0, 40)))
			{
				mSelected = i;
				if (ImGui.IsMouseDoubleClicked(0))
					RequestOpen(path);
			}
			let min = ImGui.GetCursorScreenPos();
			ImGui.DrawText(.(min.x + 8, min.y - 42), .(0.9f, 0.9f, 0.9f, 1), name.CStr());
			ImGui.DrawText(.(min.x + 8, min.y - 24), .(0.55f, 0.55f, 0.55f, 1), path.CStr());
			ImGui.PopID();
		}
	}

	/// The right side: making a new project, or adding one that is already on disk.
	void DrawNewProject()
	{
		ImGui.TextDisabled("New project");
		ImGui.Spacing();
		ImGui.Text("Name");
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##name", mName);
		ImGui.Text("Location");
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##location", mLocation);
		ImGui.Text("Template");
		if (ImGui.RadioButton("Empty", mTemplate == .Empty))
			mTemplate = .Empty;
		if (ImGui.RadioButton("Voxel sandbox", mTemplate == .Sample))
			mTemplate = .Sample;
		if (ImGui.RadioButton("Tallow Gallery (showcase of six areas)", mTemplate == .Showcase))
			mTemplate = .Showcase;
		ImGui.Spacing();
		if (ImGui.Button("Create Project", .(-1, 32)))
			CreateFromForm();

		ImGui.Spacing();
		ImGui.Separator();
		ImGui.Spacing();
		ImGui.TextDisabled("Add existing project");
		ImGui.Spacing();
		ImGui.Text("Project folder");
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##existing", mExisting);
		if (ImGui.Button("Add and Open", .(-1, 28)))
		{
			if (File.Exists(scope $"{mExisting}/project.tallow") || File.Exists(scope $"{mExisting}/project.tessera"))
				RequestOpen(mExisting);
			else
				SetMessage("That folder does not contain a project.tallow file.", true);
		}
	}

	/// Open and Remove from list, for the project chosen on the left.
	void DrawProjectButtons()
	{
		let hasSelection = mSelected >= 0 && mSelected < RecentProjects.Paths.Count;
		ImGui.BeginDisabled(!hasSelection);
		if (ImGui.Button("Open", .(140, 32)))
			RequestOpen(RecentProjects.Paths[mSelected]);
		ImGui.SameLine();
		if (ImGui.Button("Remove from list", .(160, 32)))
		{
			RecentProjects.Remove(scope String(RecentProjects.Paths[mSelected]));
			mSelected = -1;
		}
		ImGui.EndDisabled();
	}

	/// What happened last: a note, or an error with buttons to copy it and to open the build log.
	void DrawLauncherMessage()
	{
		if (mMessageIsError)
		{
			ImGui.Spacing();
			if (ImGui.Button("Copy error"))
				ImGui.SetClipboardText(mMessage.CStr());
			let logPath = scope $"{mPendingOpen}/build/build.log";
			if (!mPendingOpen.IsEmpty && File.Exists(logPath))
			{
				ImGui.SameLine();
				if (ImGui.Button("Open build log"))
					Terminal.Open(logPath);
			}
		}
		else
			ImGui.SameLine(0, 18);
		ImGui.BeginChild("message", .(0, mMessageIsError ? 0 : 40), 0, ImGui.WindowFlags.HorizontalScrollbar);
		if (mMessageIsError)
			ImGui.TextColored(.(1.0f, 0.45f, 0.4f, 1), mMessage.CStr());
		else
			ImGui.TextColored(.(1.0f, 0.82f, 0.35f, 1), mMessage.CStr());
		ImGui.EndChild();
	}

	void OpenPendingProject()
	{
		let verdict = scope String();
		Toolchain.Apply();
		CheckProjectVersion(mPendingOpen, verdict, mUpgradeFrom, mUpgradeTo);
		if (verdict == "upgrade")
		{
			mUpgradePrompt = true;
			return;
		}
		if (verdict == "newer")
		{
			SetMessage(scope $"This project needs a newer engine ({mUpgradeFrom}) than this one ({mUpgradeTo}). Install it in Engine Manager.", true);
			return;
		}
		FinishOpen();
	}

	void FinishOpen()
	{
		let error = scope String();
		if (OpenProject(mPendingOpen, error))
			Running = false;
		else
			SetMessage(error, true);
	}

	/// The warning shown before a project from another engine version is moved to this one.
	void DrawUpgradeDialog()
	{
		if (!ImGui.BeginPopupModal("Project from another version", null, ImGui.WindowFlags.AlwaysAutoResize))
			return;
		ImGui.Text(scope $"This project was last used with {mUpgradeFrom}, which is not installed.");
		ImGui.Text(scope $"It can be opened by upgrading it to {mUpgradeTo}.");
		ImGui.Spacing();
		ImGui.Text("Scripts may need changes after upgrading, and older engines may not open it again.");
		ImGui.Text("Files that change are copied to .tallow-upgrade-backup in the project folder.");
		ImGui.Spacing();
		if (ImGui.Button("Upgrade and Open", .(190, 36)))
		{
			mUpgradePrompt = false;
			ImGui.CloseCurrentPopup();
			let error = scope String();
			if (UpgradeProject(mPendingOpen, error))
				mOpenCountdown = 3;
			else
				SetMessage(error, true);
		}
		ImGui.SameLine();
		if (ImGui.Button("Cancel", .(140, 36)))
		{
			mUpgradePrompt = false;
			ImGui.CloseCurrentPopup();
		}
		ImGui.EndPopup();
	}

	void MissingMessage(String text)
	{
		text.Append("Missing: ");
		for (int i < mMissingTools.Count)
		{
			if (i > 0)
				text.Append(", ");
			text.Append(mMissingTools[i]);
		}
		text.Append(". Use Install dependencies to set up the development tools.");
	}

	void CreateFromForm()
	{
		if (mEngineRoot.IsEmpty)
		{
			SetMessage("The engine folder was not found. Set TALLOW_ROOT.", true);
			return;
		}
		let folder = scope $"{mLocation}/{mName}";
		Directory.CreateDirectory(mLocation).IgnoreError();
		let error = scope String();
		if (!ProjectGenerator.Create(folder, mName, mEngineRoot, mTemplate, error))
		{
			SetMessage(error, true);
			return;
		}
		RecentProjects.Add(folder);
		RequestOpen(folder);
	}
}

class Program
{
#if BF_PLATFORM_WINDOWS
	[CLink, CallingConvention(.Stdcall)] static extern int32 AttachConsole(uint32 processId);
	[CLink, CallingConvention(.Stdcall)] static extern void* GetStdHandle(uint32 handle);

	static void UseCommandConsole()
	{
		// CLI commands may reuse their caller's console; GUI startup never allocates one.
		// Preserve explicitly redirected output (the build regression captures it through a pipe).
		let output = GetStdHandle(0xFFFFFFF5);
		if ((output == null || (int)output == -1) && AttachConsole(0xFFFFFFFF) != 0)
			Console.ReopenHandles();
	}
#endif
	public static int Main(String[] args)
	{
		for (int i < args.Count)
		{
			if (args[i] == "--create" && i + 1 < args.Count)
			{
#if BF_PLATFORM_WINDOWS
				UseCommandConsole();
#endif
				return CreateFromCommandLine(args[i + 1], args);
			}
			if ((args[i] == "--open" || args[i] == "--build-project") && i + 1 < args.Count)
			{
#if BF_PLATFORM_WINDOWS
				UseCommandConsole();
#endif
				Gfx.LocateEngineAssets();
				let error = scope String();
				if (!LauncherApp.PrepareProject(args[i + 1], args.Contains("--upgrade"), error) ||
					!LauncherApp.OpenProject(args[i + 1], error, args[i] == "--build-project"))
				{
					Console.WriteLine(error);
					return 1;
				}
				return 0;
			}
		}
		let app = scope LauncherApp();
		return app.Run(args);
	}

	static int CreateFromCommandLine(StringView folderIn, String[] args)
	{
		var folder = folderIn;
		while (folder.EndsWith('/') && folder.Length > 1)
			folder.RemoveFromEnd(1);
		let name = scope String();
		Path.GetFileName(folder, name);
		ProjectTemplate template = .Empty;
		for (let arg in args)
		{
			if (arg == "--sample")
				template = .Sample;
			if (arg == "--showcase")
				template = .Showcase;
		}
		let root = scope String();
		// No window here, so locate the engine relative to this executable.
		Gfx.LocateEngineAssets();
		if (!ProjectGenerator.FindEngineRoot(root))
		{
			Console.WriteLine("Engine folder not found. Set TALLOW_ROOT.");
			return 1;
		}
		let error = scope String();
		if (!ProjectGenerator.Create(folder, name, root, template, error))
		{
			Console.WriteLine(error);
			return 1;
		}
		Console.WriteLine("Created {} at {}", name, folder);
		return 0;
	}
}
