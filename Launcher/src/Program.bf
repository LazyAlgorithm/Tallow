using System;
using System.Collections;
using System.IO;
using Tallow;
using Tallow.Editor;
using Bgfx;

namespace Tallow.Launcher;

/// The project hub: pick a recent project, add an existing one, or create a new one.
/// Opening a project compiles its scripts and starts its editor.
///
/// Command line: --create <folder> [--sample | --showcase]   create a project without the window
///               --open <folder>                build and open a project's editor directly
///               --build-project <folder>       compile without opening a window
class LauncherApp : Application
{
	String mName = new .("MyGame") ~ delete _;
	String mLocation = new .() ~ delete _;
	String mExisting = new .() ~ delete _;
	String mMessage = new .() ~ delete _;
	String mPendingOpen = new .() ~ delete _;
	String mEngineRoot = new .() ~ delete _;
	ProjectTemplate mTemplate = .Sample;
	/// Tools Tallow needs that were not found, when the launcher started.
	List<String> mMissingTools = new .() ~ DeleteContainerAndItems!(_);
	bool mMessageIsError;
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
		{
			ImGui.TextColored(.(1.0f, 0.55f, 0.4f, 1), MissingMessage(.. scope .()));
			ImGui.Spacing();
		}

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
		if (!mMessage.IsEmpty)
			DrawLauncherMessage();
		ImGui.End();
		ImGui.tn_imgui_render(250);

		// The build blocks, so start it a few frames after the "Compiling" message is on screen.
		if (mOpenCountdown > 0 && --mOpenCountdown == 0)
			OpenPendingProject();
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
		if (ImGui.RadioButton("Exhibition Campus (24 interactive exhibits)", mTemplate == .Showcase))
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
			if (File.Exists(scope $"{mExisting}/project.tallow"))
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
		let error = scope String();
		if (OpenProject(mPendingOpen, error))
			Running = false;
		else
			SetMessage(error, true);
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
		text.Append(". Install the required development tools through Tallow Manager, then restart the launcher.");
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
				if (!LauncherApp.OpenProject(args[i + 1], error, args[i] == "--build-project"))
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
