using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// The Scripts tab: a code editor in the style of Visual Studio's dark theme with syntax
/// colouring, bracket matching, foldable blocks, find/replace, completion and undo/redo.
/// Saving a script compiles the project in the background and updates in-editor diagnostics.
enum ScriptProblemKind
{
	Compiler,
	Optimization,
	Determinism
}

extension EditorApp
{
	class ScriptDocument
	{
		public String path = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public void* handle;
		public bool open = true;
		/// Code generated from a graph: shown for reference, edited through the graph.
		public bool readOnly;
	}

	class ScriptProblem
	{
		public String file = new .() ~ delete _;
		public String message = new .() ~ delete _;
		public int32 line = -1;
		public int32 column;
		public bool isError;
		public ScriptProblemKind kind;
	}

	[CLink] static extern void* tn_code_create(char8* text, int32 language);
	[CLink] static extern void tn_code_destroy(void* handle);
	[CLink] static extern char8* tn_code_get_text(void* handle);
	[CLink] static extern void tn_code_render(void* handle, char8* id, float width, float height);
	[CLink] static extern bool tn_code_is_dirty(void* handle);
	[CLink] static extern void tn_code_mark_saved(void* handle);
	[CLink] static extern void tn_code_clear_diagnostics(void* handle);
	[CLink] static extern void tn_code_add_diagnostic(void* handle, int32 line, int32 column, int32 kind, bool isError, char8* message);
	[CLink] static extern void tn_code_set_read_only(void* handle, bool readOnly);
	[CLink] static extern void tn_code_undo(void* handle);
	[CLink] static extern void tn_code_redo(void* handle);
	[CLink] static extern void tn_code_cut(void* handle);
	[CLink] static extern void tn_code_copy(void* handle);
	[CLink] static extern void tn_code_paste(void* handle);
	[CLink] static extern void tn_code_select_all(void* handle);
	[CLink] static extern bool tn_code_has_selection(void* handle);
	[CLink] static extern bool tn_code_can_undo(void* handle);
	[CLink] static extern bool tn_code_can_redo(void* handle);
	[CLink] static extern void tn_code_focus(void* handle);
	[CLink] static extern void tn_code_goto_line(void* handle, int32 line);
	[CLink] static extern bool igBeginTabBar(char8* id, int32 flags);
	[CLink] static extern void igEndTabBar();
	[CLink] static extern bool igBeginTabItem(char8* label, bool* open, int32 flags);
	[CLink] static extern void igEndTabItem();

	List<ScriptDocument> mScripts = new .() ~
		{
			for (let d in _)
			{
				tn_code_destroy(d.handle);
				delete d;
			}
			delete _;
		};
	List<ScriptProblem> mProblems = new .() ~ DeleteContainerAndItems!(_);
	// Full diagnostic snapshots stay alive for open code tabs; partial completion queries must not erase them.
	List<ScriptProblem> mDisplayedScriptProblems = new .() ~ DeleteContainerAndItems!(_);
	ScriptDocument mActiveScript;
	ScriptDocument mSelectScript;
	bool mScriptsFocused;
	bool mFocusScripts;
	// Background compile.
	Thread mCheckThread ~ delete _;
	bool mCheckRunning;
	bool mCheckFinished;
	bool mCheckSucceeded;
	bool mCheckManaged;
	bool mManagedBuildReady;
	String mCheckLog = new .() ~ delete _;

	/// Opens a script in the Scripts tab (or switches to it if it is already open).
	/// Path of the graph a script was generated from, if that graph exists.
	static bool FindSourceGraph(StringView scriptPath, String graphPath)
	{
		if (!scriptPath.EndsWith(".bf"))
			return false;
		graphPath.Append(scriptPath.Substring(0, scriptPath.Length - 3));
		graphPath.Append(".tgraph");
		return File.Exists(graphPath);
	}

	/// Turns a graph into an ordinary script: the generated code stays, the graph is removed.
	void ConvertGraphToScript(StringView graphPath)
	{
		let scriptPath = scope String(graphPath.Substring(0, graphPath.Length - 7));
		scriptPath.Append(".bf");
		if (!File.Exists(scriptPath))
		{
			let graph = scope NodeGraph();
			if (!graph.Load(graphPath))
				return;
			Path.GetFileNameWithoutExtension(graphPath, graph.name..Clear());
			let fileName = scope String();
			Path.GetFileName(graphPath, fileName);
			let generated = scope String();
			graph.Compile(Project.Current.Name, graph.name, fileName, generated);
			File.WriteAllText(scriptPath, generated).IgnoreError();
		}
		// Drop the "generated, do not edit" header: from here on the script is the source.
		let code = scope String();
		if (File.ReadAllText(scriptPath, code, true) case .Ok)
		{
			while (code.StartsWith("//"))
			{
				let lineEnd = code.IndexOf('\n');
				if (lineEnd < 0)
					break;
				code.Remove(0, lineEnd + 1);
			}
			File.WriteAllText(scriptPath, code).IgnoreError();
		}
		if (File.Delete(graphPath) case .Err)
		{
			Log.Error(scope $"Could not remove {graphPath}");
			return;
		}
		if (mGraph != null && mGraphPath == graphPath)
		{
			delete mGraph;
			mGraph = null;
		}
		// Reopen the script as a normal, editable document.
		for (let document in mScripts)
		{
			if (document.path == scriptPath)
			{
				document.open = false;
				tn_code_mark_saved(document.handle);
			}
		}
		mPendingOpenScript.Set(scriptPath);
		Log.Info(scope $"Converted to script: {scriptPath}");
		RefreshAssetList();
	}

	String mPendingOpenScript = new .() ~ delete _;

	/// Shows the code a graph compiles to, read-only.
	void ViewGraphCode(StringView graphPath)
	{
		OpenGraph(graphPath);
		CompileGraph();
		let scriptPath = scope String(graphPath.Substring(0, graphPath.Length - 7));
		scriptPath.Append(".bf");
		OpenScript(scriptPath);
	}

	void OpenScript(StringView sourcePath, int32 line = -1)
	{
		let path = scope String();
		ScriptSemantic.CanonicalPath(sourcePath, path);
		mShowScripts = true;
		mDockScripts = true;
		ScriptDocument document = null;
		for (let existing in mScripts)
		{
			if (Path.Equals(existing.path, path, .Lenient))
				document = existing;
		}
		if (document == null)
		{
			let text = scope String();
			if (File.ReadAllText(path, text, true) case .Err)
			{
				Log.Error(scope $"Could not open {path}");
				return;
			}
			// The native graph-source index supplies type colouring; C# uses Roslyn.
			if (path.EndsWith(".bf"))
				ApiIndex.Ensure();
			document = new ScriptDocument();
			document.path.Set(path);
			Path.GetFileName(path, document.name);
			document.handle = tn_code_create(text.CStr(), path.EndsWith(".tui") ? 1 : (path.EndsWith(".tcss") ? 2 : ((path.EndsWith(".tshader") || path.EndsWith(".tcompute")) ? 3 : (path.EndsWith(".cs") ? 4 : (path.EndsWith(".tasmdef") ? 5 : 0)))));
			document.readOnly = FindSourceGraph(path, scope String());
			tn_code_set_read_only(document.handle, document.readOnly);
			mScripts.Add(document);
			RefreshScriptDiagnostics();
		}
		mSelectScript = document;
		mFocusScripts = true;
		if (line >= 0)
			tn_code_goto_line(document.handle, line);
		tn_code_focus(document.handle);
	}

	/// Refresh squiggles for every open script from the most recent complete diagnostics snapshot.
	void RefreshScriptDiagnostics()
	{
		for (let document in mScripts)
		{
			tn_code_clear_diagnostics(document.handle);
			if (!document.path.EndsWith(".bf") && !document.path.EndsWith(".cs"))
				continue;
			for (let problem in mDisplayedScriptProblems)
			{
				if (problem.line < 0 || !Path.Equals(problem.file, document.path, .Lenient))
					continue;
				tn_code_add_diagnostic(document.handle, problem.line, problem.column, (int32)problem.kind, problem.isError, problem.message.CStr());
			}
		}
	}

	void SaveScript(ScriptDocument document)
	{
		if (document.readOnly || !tn_code_is_dirty(document.handle))
			return;
		let text = StringView(tn_code_get_text(document.handle));
		if (File.WriteAllText(document.path, text) case .Err)
		{
			Log.Error(scope $"Could not save {document.path}");
			return;
		}
		tn_code_mark_saved(document.handle);
		if (document.path.EndsWith(".tui") || document.path.EndsWith(".tcss"))
			OnUiSourceSaved(document.path);
		else if (document.path.EndsWith(".tshader") || document.path.EndsWith(".tcompute"))
		{
			// Saving a shader compiles it; objects using it change at once. Mistakes go to the Console.
			let relative = scope String();
			Assets.MakeRelative(document.path, relative);
			CompileShader(relative);
		}
		else if (document.path.EndsWith(".cs") || document.path.EndsWith(".tasmdef"))
		{
			mManagedBuildReady = false;
			if (mPlay != .Edit)
				mStatus.Set("C# changed; stop and restart Play to load the new code.");
			else if (Project.Current.ReloadMode != .Manual)
				StartManagedErrorCheck();
		}
		else
		{
			// Refresh the native graph-source index used by the legacy visual compiler.
			ApiIndex.RefreshProject();
			mScriptsNeedReload = true;
			if (Project.Current.ReloadMode != .Manual)
				StartErrorCheck();
		}
	}

	void SaveAllScripts()
	{
		for (let document in mScripts)
		{
			if (tn_code_is_dirty(document.handle))
				SaveScript(document);
		}
	}

	/// Compiles the project on a worker thread so typing is never blocked.
	void StartErrorCheck()
	{
		if (mActiveScript != null && (mActiveScript.path.EndsWith(".cs") || mActiveScript.path.EndsWith(".tasmdef")))
		{
			StartManagedErrorCheck();
			return;
		}
		if (mReloadReady && Project.Current.ReloadMode != .Manual)
		{
			QueueScriptReload(true);
			return;
		}
		mCheckWasReload = false;
		mCheckManaged = false;
		if (mCheckRunning)
			return;
		if (mCheckThread != null)
		{
			mCheckThread.Join();
			delete mCheckThread;
			mCheckThread = null;
		}
		mCheckRunning = true;
		mCheckFinished = false;
		mCheckThread = new Thread(new () =>
			{
				let project = Project.Current;
				mCheckSucceeded = project.Build(false);
				mCheckLog.Clear();
				project.ReadBuildLog(mCheckLog);
				Interlocked.Store(ref mCheckFinished, true);
			});
		mCheckThread.Start(false);
	}

	/// Compile trusted gameplay assemblies using the .NET SDK directly.
	/// This does not invoke the native script reloader or any Python helper.
	void StartManagedErrorCheck()
	{
		if (mCheckRunning)
			return;
		if (mCheckThread != null)
		{
			mCheckThread.Join();
			DeleteAndNullify!(mCheckThread);
		}
		mCheckManaged = true;
		mManagedBuildReady = false;
		mCheckWasReload = false;
		mCheckRunning = true;
		mCheckFinished = false;
		mCheckThread = new Thread(new () =>
			{
				let project = Project.Current;
				Directory.CreateDirectory(scope $"{project.Path}/build").IgnoreError();
				let logFile = scope $"{project.Path}/build/csharp-build.log";
				let command = scope String("dotnet run --project ");
				Terminal.Quote(scope $"{project.EngineRoot}/Managed/Tallow.Build/Tallow.Build.csproj", command);
				command.Append(" -- --project ");
				Terminal.Quote(project.Path, command);
				command.Append(" --engine-root ");
				Terminal.Quote(project.EngineRoot, command);
				command.Append(" > ");
				Terminal.Quote(logFile, command);
				command.Append(" 2>&1");
				mCheckSucceeded = Terminal.Run(command) == 0;
				if (mCheckSucceeded)
				{
					let runtime = scope String("dotnet build ");
					Terminal.Quote(scope $"{project.EngineRoot}/Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj", runtime);
					runtime.Append(" --configuration Debug --nologo --verbosity minimal >> ");
					Terminal.Quote(logFile, runtime);
					runtime.Append(" 2>&1");
					mCheckSucceeded = Terminal.Run(runtime) == 0;
				}
				mCheckLog.Clear();
				File.ReadAllText(logFile, mCheckLog).IgnoreError();
				Interlocked.Store(ref mCheckFinished, true);
			});
		mCheckThread.Start(false);
	}

	/// MSBuild diagnostics: path/File.cs(line,column): error CS1234: message [project].
	void ParseManagedDiagnostics(StringView output)
	{
		for (let line in output.Split('\n'))
		{
			let start = line.IndexOf(".cs(");
			if (start < 0)
				continue;
			let open = start + 3;
			let close = line.IndexOf(')', open);
			if (close <= open)
				continue;
			let suffix = line.Substring(close + 1);
			let errorIndex = suffix.IndexOf(": error ");
			let warningIndex = suffix.IndexOf(": warning ");
			bool isError = errorIndex >= 0;
			let marker = isError ? errorIndex : warningIndex;
			if (marker < 0)
				continue;
			let location = line.Substring(open + 1, close - open - 1);
			let comma = location.IndexOf(',');
			if (comma <= 0)
				continue;
			let problem = new ScriptProblem();
			problem.file.Set(line.Substring(0, open));
			problem.line = (int32)SceneSerializer.ParseInt(location.Substring(0, comma)) - 1;
			problem.column = (int32)Math.Max(SceneSerializer.ParseInt(location.Substring(comma + 1)) - 1, 0);
			problem.isError = isError;
			problem.message.Set(suffix.Substring(marker + (isError ? 8 : 10)));
			problem.message.Trim();
			let projectSuffix = problem.message.IndexOf(" [");
			if (projectSuffix > 0)
				problem.message.Remove(projectSuffix, problem.message.Length - projectSuffix);
			if (!isError && IsOptimizationWarning(problem.message))
				problem.kind = .Optimization;
			mProblems.Add(problem);
		}
	}

	static int LastIndexOfText(StringView text, StringView part)
	{
		for (int i = text.Length - part.Length; i >= 0; i--)
		{
			if (text.Substring(i, part.Length) == part)
				return i;
		}
		return -1;
	}

	/// Parse BeefBuild's line/column diagnostics into the same model used by the language service.
	static bool IsOptimizationWarning(StringView message)
	{
		return message.Contains("unused") || message.Contains("Unused") ||
			message.Contains("optim") || message.Contains("Optim") ||
			message.Contains("performance") || message.Contains("Performance") ||
			message.Contains("allocation") || message.Contains("Allocation");
	}

	void ParseCompilerDiagnostics(StringView output)
	{
		for (let line in output.Split('\n'))
		{
			let isError = line.StartsWith("ERROR:");
			if (!isError && !line.StartsWith("WARNING"))
				continue;
			// BeefBuild: ERROR: message at line 12:5 in /path/File.bf
			let atIndex = LastIndexOfText(line, " at line ");
			let inIndex = LastIndexOfText(line, " in ");
			if (atIndex < 0 || inIndex < atIndex)
				continue;
			let colon = line.IndexOf(':');
			if (colon < 0 || colon >= atIndex)
				continue;
			let problem = new ScriptProblem();
			problem.isError = isError;
			problem.message.Set(line.Substring(colon + 1, atIndex - colon - 1));
			problem.message.Trim();
			let location = line.Substring(atIndex + 9, inIndex - atIndex - 9);
			let split = location.IndexOf(':');
			problem.line = SceneSerializer.ParseInt(split > 0 ? location.Substring(0, split) : location) - 1;
			problem.column = split > 0 ? (int32)Math.Max(SceneSerializer.ParseInt(location.Substring(split + 1)) - 1, 0) : 0;
			problem.file.Set(line.Substring(inIndex + 4));
			problem.file.Trim();
			if (!isError && IsOptimizationWarning(problem.message))
				problem.kind = .Optimization;
			mProblems.Add(problem);
		}
	}

	void CollectCheckResults()
	{
		if (!mCheckRunning || !Interlocked.Load(ref mCheckFinished))
			return;
		// Release the thread now: joining a finished thread a second time (the next save, or quitting) waits on
		// whatever thread the system has since given its slot to, and the editor freezes.
		if (mCheckThread != null)
		{
			mCheckThread.Join();
			DeleteAndNullify!(mCheckThread);
		}
		mCheckRunning = false;
		ClearAndDeleteItems!(mProblems);
		if (mCheckManaged)
		{
			ParseManagedDiagnostics(mCheckLog);
			PublishScriptDiagnostics();
			mManagedBuildReady = mCheckSucceeded;
			mStatus.Set(mCheckSucceeded ? "C# assemblies compiled." : "C# compilation failed. See Console.");
			mCheckManaged = false;
			if (mPlayAfterCompile && mPlay == .Edit)
			{
				mPlayAfterCompile = false;
				if (mCheckSucceeded)
					StartPlay();
			}
			return;
		}
		ParseCompilerDiagnostics(mCheckLog);
		AddDeterminismWarnings(scope $"{Project.Current.Path}/src" , 0);
		PublishScriptDiagnostics();
		if (mCheckWasReload)
		{
			FinishScriptReload();
			mCheckWasReload = false;
			return;
		}
		if (mCheckSucceeded)
		{
			Log.Info("Scripts compiled. Use File > Rebuild & Reload to run the new code.");
			if (mPlayAfterCompile && mPlay == .Edit)
			{
				// A standalone error check may have been in progress when Play
				// was requested. The checked binary is not an activated reload.
				if (mScriptsNeedReload)
				{
					if (mReloadReady)
					{
						QueueScriptReload(true, true);
						mStatus.Set("Waiting to compile scripts before Play...");
					}
					else
					{
						mPlayAfterCompile = false;
						mStatus.Set("Script reload is unavailable. Full Rebuild & Restart before Play.");
					}
				}
				else
				{
					mPlayAfterCompile = false;
					StartPlay();
				}
			}
			else
				mStatus.Clear();
		}
		else
		{
			Log.Error("Scripts have errors; see the Console.");
			mPlayAfterCompile = false;
			mStatus.Set("Script compilation failed. See Console.");
		}
	}

	/// Networked code that would come out differently on different machines (ScriptDeterminism), as warnings.
	void AddDeterminismWarnings(StringView folder, int depth)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name.StartsWith('.') || !name.EndsWith(".bf", .OrdinalIgnoreCase))
				continue;
			let path = scope $"{folder}/{name}";
			let source = scope String();
			if (File.ReadAllText(path, source) case .Err)
				continue;
			if (!source.Contains("TickInput") && !source.Contains("Simulate("))
				continue;
			List<ScriptDeterminism.Warning> warnings = scope .();
			ScriptDeterminism.Check(source, warnings);
			for (let warning in warnings)
			{
				let problem = new ScriptProblem();
				problem.isError = false;
				problem.kind = .Determinism;
				problem.file.Set(path);
				problem.line = (int32)warning.line;
				problem.message.Set(warning.message);
				delete warning.message;
				mProblems.Add(problem);
			}
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.StartsWith('.') && name != "build")
				AddDeterminismWarnings(scope $"{folder}/{name}" , depth + 1);
		}
	}

	void DrawScripts()
	{
		CollectSemantic();
		if (!mShowScripts)
			return;
		if (mDockScripts && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockScripts = false;
		}
		if (!mPendingOpenScript.IsEmpty)
		{
			// A converted script is reopened once its read-only tab has closed.
			bool stillOpen = false;
			for (let document in mScripts)
				stillOpen |= document.path == mPendingOpenScript;
			if (!stillOpen)
			{
				OpenScript(mPendingOpenScript);
				mPendingOpenScript.Clear();
			}
		}
		if (mFocusScripts && Time.FrameCount > 5)
		{
			ImGui.SetWindowFocus("Scripts");
			mFocusScripts = false;
		}
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		ImGui.PushStyleColor(ImGui.Col.WindowBg, EditorTheme.CodeBackground);
		let visible = ImGui.Begin("Scripts", &mShowScripts, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse | ImGui.WindowFlags.MenuBar);
		ImGui.PopStyleColor();
		ImGui.PopStyleVar();
		mScriptsFocused = false;
		if (visible)
		{
			mScriptsFocused = ImGui.IsWindowFocused(ImGui.HoveredFlags.ChildWindows | ImGui.HoveredFlags.RootWindow);
			if (mScripts.Count == 0)
			{
				ImGui.SetCursorPosX(16);
				ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 14);
				ImGui.TextDisabled("Double-click a script in the Project window to edit it here.");
			}
			else
			{
				let active = mActiveScript;
				DrawScriptToolbar(active);
				DrawSemanticTools(active);
				DrawScriptTabs(active);
			}
		}
		ImGui.End();
	}

	/// Compact editor-local menu. The main application menu remains available
	/// for scene operations, while these commands apply to the selected script.
	void DrawScriptToolbar(ScriptDocument active)
	{
		if (!ImGui.BeginMenuBar())
			return;
		if (ImGui.BeginMenu("File"))
		{
			if (ImGui.MenuItem("Save Script", "Ctrl+S", false, active != null && !active.readOnly))
				SaveScript(active);
			if (ImGui.MenuItem("Save All Scripts", null, false, mScripts.Count > 0))
				SaveAllScripts();
			ImGui.Separator();
			if (ImGui.MenuItem("Check Errors"))
			{
				SaveAllScripts();
				StartErrorCheck();
			}
			if (active != null && active.path.EndsWith(".cs"))
				ImGui.TextDisabled("Native C# Play integration is in progress.");
			else if (ImGui.MenuItem("Rebuild & Reload"))
			{
				SaveAllScripts();
				RequestRebuild();
			}
			ImGui.EndMenu();
		}
		if (ImGui.BeginMenu("Edit"))
		{
			bool editable = active != null && !active.readOnly;
			bool selected = active != null && tn_code_has_selection(active.handle);
			if (ImGui.MenuItem("Undo", "Ctrl+Z", false, editable && tn_code_can_undo(active.handle)))
				tn_code_undo(active.handle);
			if (ImGui.MenuItem("Redo", "Ctrl+Y", false, editable && tn_code_can_redo(active.handle)))
				tn_code_redo(active.handle);
			ImGui.Separator();
			if (ImGui.MenuItem("Cut", "Ctrl+X", false, editable && selected))
				tn_code_cut(active.handle);
			if (ImGui.MenuItem("Copy", "Ctrl+C", false, selected))
				tn_code_copy(active.handle);
			if (ImGui.MenuItem("Paste", "Ctrl+V", false, editable))
				tn_code_paste(active.handle);
			if (ImGui.MenuItem("Select All", "Ctrl+A", false, active != null))
				tn_code_select_all(active.handle);
			ImGui.EndMenu();
		}
		if (ImGui.BeginMenu("Navigate"))
		{
			bool ready = active != null && (active.path.EndsWith(".cs") || active.path.EndsWith(".bf")) && !mSemantic.running;
			if (ImGui.MenuItem("Go to Definition", "F12", false, ready))
				RequestSemantic(active, "definition");
			if (ImGui.MenuItem("Symbol / Parameters", null, false, ready))
			{
				mSymbolInfoRequested = true;
				RequestSemantic(active, "symbol");
			}
			if (ImGui.MenuItem("Rename Symbol", "F2", false, ready))
				BeginScriptSymbolRename();
			if (ImGui.MenuItem("Undo Symbol Rename", null, false, !mRenameUndo.IsEmpty))
				UndoSymbolRename();
			ImGui.EndMenu();
		}
		if (mCheckRunning)
		{
			ImGui.SameLine(0, 14);
			ImGui.TextColored(EditorTheme.Warning, "Compiling...");
		}
		ImGui.EndMenuBar();
	}

	/// One tab per open file, each a code editor. A script made from a
	/// graph is read-only, with a button to turn it into an ordinary script.
	void DrawScriptTabs(ScriptDocument active)
	{
		if (active != null && active.readOnly)
		{
			ImGui.SetCursorPosX(6);
			ImGui.TextColored(EditorTheme.Warning, "Generated from a graph: read-only. Edit the graph, or");
			ImGui.SameLine();
			if (ImGui.SmallButton("Convert to Script"))
			{
				let graphPath = scope String();
				if (FindSourceGraph(active.path, graphPath))
					ConvertGraphToScript(graphPath);
			}
		}
		ScriptDocument close = null;
		if (igBeginTabBar("##scripts", 1 | 4 | 64))
		{
			for (let document in mScripts)
			{
				var flags = (int32)0;
				if (tn_code_is_dirty(document.handle))
					flags |= 1; // unsaved dot
				if (mSelectScript == document)
					flags |= 2; // select this tab
				ImGui.PushID(Internal.UnsafeCastToPtr(document));
				if (igBeginTabItem(document.name.CStr(), &document.open, flags))
				{
					mActiveScript = document;
					let avail = ImGui.GetContentRegionAvail();
					tn_code_render(document.handle, "##code", avail.x, Math.Max(avail.y, 60));
					UpdateSemantic(document);
					igEndTabItem();
				}
				ImGui.PopID();
				if (!document.open)
					close = document;
			}
			mSelectScript = null;
			igEndTabBar();
		}
		if (close != null)
		{
			if (tn_code_is_dirty(close.handle))
				SaveScript(close);
			if (mActiveScript == close)
				mActiveScript = null;
			mScripts.Remove(close);
			tn_code_destroy(close.handle);
			delete close;
		}
	}

}
