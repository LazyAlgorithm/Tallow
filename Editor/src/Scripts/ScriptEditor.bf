using System;
using System.Collections;
using System.Diagnostics;
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
		/// The file's modification time when it was last read or saved here; a different time on disk
		/// means another program (an external IDE, git) changed it.
		public DateTime diskTime;
		/// Changed both on disk and here: warned about once, until the next save or reload.
		public bool diskConflict;
	}

	System.Diagnostics.Stopwatch mDiskCheckClock = new .(true) ~ delete _;

	static DateTime ScriptDiskTime(StringView path)
	{
		if (File.GetLastWriteTimeUtc(path) case .Ok(let time))
			return time;
		return default;
	}

	/// Picks up edits made to open scripts by other programs. A document with no unsaved changes
	/// here is reloaded; one with unsaved changes keeps them and gets a warning, so saving is a
	/// deliberate choice to overwrite the other program's version.
	void CheckOpenScriptsOnDisk(bool now = false)
	{
		if (!now && mDiskCheckClock.ElapsedMilliseconds < 500)
			return;
		mDiskCheckClock.Restart();
		for (let document in mScripts)
		{
			let time = ScriptDiskTime(document.path);
			if (time == default || time == document.diskTime)
				continue;
			let text = scope String();
			if (File.ReadAllText(document.path, text, true) case .Err)
				continue;
			if (StringView(tn_code_get_text(document.handle)) == text)
			{
				document.diskTime = time; // Saved with identical text (formatter, git checkout of the same).
				document.diskConflict = false;
				continue;
			}
			if (!tn_code_is_dirty(document.handle))
			{
				tn_code_reload_text(document.handle, text.CStr());
				document.diskTime = time;
				document.diskConflict = false;
				Log.Info(scope $"Reloaded {document.name}: it was changed outside the editor.");
				RefreshScriptDiagnostics();
			}
			else if (!document.diskConflict)
			{
				document.diskConflict = true;
				Log.Warning(scope $"{document.name} was changed outside the editor while it has unsaved changes here. Saving will replace the other version; close it without saving to load that one.");
			}
		}
	}

	class ScriptProblem
	{
		public String file = new .() ~ delete _;
		public String message = new .() ~ delete _;
		public int32 line = -1;
		public int32 column;
		public bool isError;
		public ScriptProblemKind kind;
		/// For a problem in a graph's generated C#: file is the graph and line the node's id (or -1 for the graph).
		public bool inGraph;
	}

	/// Points a problem in a graph's generated C# at the graph, and the node whose code it is in.
	static void MapToGraph(ScriptProblem problem)
	{
		let graphPath = scope String();
		if (!problem.file.EndsWith(".cs") || !FindSourceGraph(problem.file, graphPath))
			return;
		let code = scope String();
		if (File.ReadAllText(problem.file, code) case .Err)
			return;
		let node = GraphCSharp.NodeAt(code, problem.line);
		let place = scope String();
		if (node >= 0)
		{
			let graph = scope NodeGraph();
			if (graph.Load(graphPath))
			{
				let found = graph.Find(node);
				if (found != null)
					place.AppendF(" (node \"{}\")", found.def.title);
			}
		}
		problem.message.Insert(0, scope $"graph{place}: ");
		problem.file.Set(graphPath);
		// Node ids start at 1: 0 means the graph itself (the Console only opens entries with a line).
		problem.line = Math.Max(node, 0);
		problem.column = 0;
		problem.inGraph = true;
	}

	[CLink] static extern void* tn_code_create(char8* text, int32 language);
	[CLink] static extern void tn_code_destroy(void* handle);
	[CLink] static extern char8* tn_code_get_text(void* handle);
	[CLink] static extern void tn_code_render(void* handle, char8* id, float width, float height);
	[CLink] static extern bool tn_code_is_dirty(void* handle);
	[CLink] static extern void tn_code_mark_saved(void* handle);
	[CLink] static extern void tn_code_reload_text(void* handle, char8* text);
	[CLink] static extern void tn_code_clear_diagnostics(void* handle);
	[CLink] static extern void tn_code_add_diagnostic(void* handle, int32 line, int32 column, int32 kind, bool isError, char8* message);
	[CLink] static extern void tn_code_set_read_only(void* handle, bool readOnly);
	[CLink] static extern void tn_code_set_semantic_navigation(void* handle, bool enabled);
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
	bool mManagedRecheckQueued;
	/// A C# file was saved while playing: once it compiles, the running scripts move to the new code.
	bool mHotReloadAfterCompile;
	// Clear only the success toast after one second; build failures stay visible.
	Stopwatch mManagedCompileNoticeClock = new .(true) ~ delete _;
	bool mManagedCompileNoticePending;
	String mCheckLog = new .() ~ delete _;

	/// Opens a script in the Scripts tab (or switches to it if it is already open).
	/// Path of the graph a script was generated from, if that graph exists.
	static bool FindSourceGraph(StringView scriptPath, String graphPath)
	{
		if (!scriptPath.EndsWith(".bf") && !scriptPath.EndsWith(".cs"))
			return false;
		graphPath.Append(scriptPath.Substring(0, scriptPath.Length - 3));
		graphPath.Append(".tgraph");
		return File.Exists(graphPath);
	}

	/// Canonical paths keep symlinks from making an engine or external file look like a project file.
	static bool ScriptInside(StringView path, StringView folder)
	{
		let root = scope String();
		ScriptSemantic.CanonicalPath(folder, root);
		if (!root.EndsWith('/'))
			root.Append('/');
#if BF_PLATFORM_WINDOWS
		return path.StartsWith(root, .OrdinalIgnoreCase);
#else
		return path.StartsWith(root);
#endif
	}

	bool ScriptMayEdit(StringView path)
	{
		if (Project.Current == null)
			return false;
		let canonical = scope String();
		ScriptSemantic.CanonicalPath(path, canonical);
		if (!ScriptInside(canonical, Project.Current.Path))
			return false;
		// An engine checkout can sit inside a project, or a project can sit inside the engine checkout.
		// In the first case the engine subtree stays read-only; in the second the project remains editable.
		let engine = scope String();
		ScriptSemantic.CanonicalPath(Project.Current.EngineRoot, engine);
		return !ScriptInside(engine, Project.Current.Path) || !ScriptInside(canonical, engine);
	}

	bool EngineApiSource(StringView path)
	{
		return Project.Current != null && path.EndsWith(".cs", .OrdinalIgnoreCase) &&
			ScriptInside(path, scope $"{Project.Current.EngineRoot}/Managed/Tallow.API");
	}

	bool EngineBeefSource(StringView path)
	{
		return Project.Current != null && path.EndsWith(".bf", .OrdinalIgnoreCase) &&
			File.Exists(scope $"{Project.Current.Path}/BeefSpace.toml") &&
			(ScriptInside(path, scope $"{Project.Current.EngineRoot}/Engine/src") ||
			 ScriptInside(path, scope $"{Project.Current.EngineRoot}/Editor/src"));
	}

	bool ScriptMayResolve(StringView path)
	{
		return Project.Current != null && (path.EndsWith(".cs") || path.EndsWith(".bf")) &&
			(ScriptMayEdit(path) && ScriptInside(path, scope $"{Project.Current.Path}/src") ||
			 EngineApiSource(path) || EngineBeefSource(path));
	}

	/// Turns a graph into an ordinary script: the generated code stays, the graph is removed.
	void ConvertGraphToScript(StringView graphPath)
	{
		let scriptPath = GraphScriptPath(graphPath, .. scope String());
		if (!File.Exists(scriptPath))
		{
			let graph = scope NodeGraph();
			if (!graph.Load(graphPath))
				return;
			Path.GetFileNameWithoutExtension(graphPath, graph.name..Clear());
			let fileName = scope String();
			Path.GetFileName(graphPath, fileName);
			let generated = scope String();
			graph.csharp = mManagedGameplay;
			graph.Compile(GraphNamespace(graphPath, .. scope .()), graph.name, fileName, generated);
			if (File.WriteAllText(scriptPath, generated) case .Err)
			{
				Log.Error(scope $"Could not write {scriptPath}");
				return;
			}
		}
		// Drop the "generated, do not edit" header: from here on the script is the source.
		let code = scope String();
		if (File.ReadAllText(scriptPath, code, true) case .Err)
		{
			Log.Error(scope $"Could not read {scriptPath}");
			return;
		}
		while (code.StartsWith("//"))
		{
			let lineEnd = code.IndexOf('\n');
			if (lineEnd < 0)
				break;
			code.Remove(0, lineEnd + 1);
		}
		if (File.WriteAllText(scriptPath, code) case .Err)
		{
			Log.Error(scope $"Could not write {scriptPath}");
			return;
		}
		if (File.Delete(graphPath) case .Err)
		{
			Log.Error(scope $"Could not remove {graphPath}");
			return;
		}
		let companions = scope List<String>();
		defer
		{
			ClearAndDeleteItems!(companions);
		}
		AssetDatabase.GetCompanions(graphPath, companions);
		for (let companion in companions)
		{
			if (File.Delete(companion) case .Err)
				Log.Warning(scope $"Could not remove {companion}");
		}
		AssetDatabase.Refresh();
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

	/// Closes the graph and generated-code tabs after their files are deleted from Project.
	void CloseDeletedGraph(StringView graphPath)
	{
		let stem = graphPath.Substring(0, graphPath.Length - ".tgraph".Length);
		if (mPendingOpenScript == scope $"{stem}.cs" || mPendingOpenScript == scope $"{stem}.bf")
			mPendingOpenScript.Clear();
		for (int i = mScripts.Count - 1; i >= 0; i--)
		{
			let document = mScripts[i];
			if (document.path != scope $"{stem}.cs" && document.path != scope $"{stem}.bf")
				continue;
			if (mActiveScript == document)
				mActiveScript = null;
			if (mSelectScript == document)
				mSelectScript = null;
			mScripts.RemoveAt(i);
			tn_code_destroy(document.handle);
			delete document;
		}
		if (mGraph != null && mGraphPath == graphPath)
		{
			delete mGraph;
			mGraph = null;
			mGraphPath.Clear();
			mShowGraph = false;
			mGraphFocus = false;
		}
	}

	/// Shows the code a graph compiles to, read-only.
	void ViewGraphCode(StringView graphPath)
	{
		let graph = scope NodeGraph();
		if (!graph.Load(graphPath))
		{
			Log.Error(scope $"Could not read {graphPath}");
			return;
		}
		Path.GetFileNameWithoutExtension(graphPath, graph.name..Clear());
		graph.csharp = mManagedGameplay;
		graph.Validate();
		if (graph.IsSubgraph)
		{
			Log.Warning("A subgraph has no script of its own; view the generated code of a graph that uses it.");
			return;
		}
		let code = scope String();
		graph.Compile(GraphNamespace(graphPath, .. scope .()), graph.name, Path.GetFileName(graphPath, .. scope .()), code);
		let scriptPath = GraphScriptPath(graphPath, .. scope String());
		if (File.WriteAllText(scriptPath, code) case .Err)
		{
			Log.Error(scope $"Could not write {scriptPath}");
			return;
		}
		ReloadGeneratedScript(scriptPath);
		OpenScript(scriptPath);
		mGraphFocus = false;
		StartErrorCheck();
	}

	/// The graph is the source of this file; replace any open editor buffer with its new output.
	void ReloadGeneratedScript(StringView path)
	{
		let document = FindScript(path);
		if (document == null)
			return;
		let code = scope String();
		if (File.ReadAllText(path, code, true) case .Err)
			return;
		document.readOnly = true;
		tn_code_set_read_only(document.handle, true);
		tn_code_reload_text(document.handle, code.CStr());
		document.diskTime = ScriptDiskTime(path);
		document.diskConflict = false;
		RefreshScriptDiagnostics();
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
			document.diskTime = ScriptDiskTime(path);
			document.readOnly = !ScriptMayEdit(path) || FindSourceGraph(path, scope String());
			tn_code_set_read_only(document.handle, document.readOnly);
			tn_code_set_semantic_navigation(document.handle, ScriptMayResolve(path));
			mScripts.Add(document);
			RefreshScriptDiagnostics();
		}
		else
		{
			let readOnly = !ScriptMayEdit(path) || FindSourceGraph(path, scope String());
			if (document.readOnly != readOnly)
			{
				document.readOnly = readOnly;
				tn_code_set_read_only(document.handle, readOnly);
			}
			tn_code_set_semantic_navigation(document.handle, ScriptMayResolve(path));
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
		if (document.readOnly || !ScriptMayEdit(document.path) || FindSourceGraph(document.path, scope String()) || !tn_code_is_dirty(document.handle))
			return;
		let text = StringView(tn_code_get_text(document.handle));
		if (File.WriteAllText(document.path, text) case .Err)
		{
			Log.Error(scope $"Could not save {document.path}");
			return;
		}
		tn_code_mark_saved(document.handle);
		document.diskTime = ScriptDiskTime(document.path);
		document.diskConflict = false;
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
			// Take this save into the file monitor's picture now. Otherwise its next poll (every 0.5 s) sees the file
			// the editor just wrote as changed by another program, while the build started below is compiling it,
			// and queues a second full build: Save-to-Play took twice the build time. The build reads every file
			// from disk when it starts, so a file another program changed at the same moment is still built.
			if (mManagedGameplay)
				mScriptMonitor.Poll(Assets.ProjectPath);
			// Saving while dotnet is compiling must invalidate the in-flight
			// result. Rebuild the latest saved source before enabling Play.
			if (mCheckRunning)
				mManagedRecheckQueued = true;
			if (mPlay != .Edit)
			{
				if (Project.Current.ReloadMode == .Manual)
					mStatus.Set("C# changed: File > Reload Scripts (Ctrl+R) loads it into Play.");
				else
				{
					// Hot reload: compile now, swap the code in between frames when it built.
					mHotReloadAfterCompile = true;
					mStatus.Set("Compiling C# to reload it into Play...");
					if (!mCheckRunning)
						StartManagedErrorCheck();
				}
			}
			else if (Project.Current.ReloadMode != .Manual && !mCheckRunning)
				StartManagedErrorCheck();
		}
		else if (mManagedGameplay)
		{
			// The precompiled editor cannot load Beef gameplay, so a saved
			// .bf or text file neither needs a native reload nor may block
			// Play waiting for one. Keep the graph-source index current.
			ApiIndex.RefreshProject();
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

	/// Moves the running C# scripts to the code just compiled (CSharpRuntime.ReloadGame), between frames.
	void HotReloadCSharp()
	{
		let kept = CSharpRuntime.ReloadGame(Project.Current.Path);
		if (kept == CSharpNetReload.Waiting)
		{
			mStatus.Set("C# built: it loads when the host reloads the same code.");
			return;
		}
		if (kept < 0)
		{
			mStatus.Set("C# hot reload failed. See Console.");
			return;
		}
		Log.Info(scope $"C# reloaded into Play: {kept} script{(kept == 1 ? "" : "s")} kept their fields.");
		mHotReloadsDone++;
		mStatus.Set("C# reloaded into Play.");
	}

	/// Compiles the project on a worker thread so typing is never blocked.
	void StartErrorCheck()
	{
		// C# projects are checked by the .NET SDK whatever file is in front
		// (a graph, a .tui...). BeefBuild never runs for them.
		if (mManagedGameplay)
		{
			if (HasCSharpSources(scope $"{Project.Current.Path}/src"))
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
		// Record the exact source tree this check starts from, including a script just made in the editor.
		mScriptMonitor.Poll(Assets.ProjectPath);
		mCheckManaged = true;
		mManagedGameplay = true;
		NodeLibrary.CSharp = true;
		mManagedBuildReady = false;
		mCheckWasReload = false;
		mCheckRunning = true;
		mCheckFinished = false;
		mCheckThread = new Thread(new () =>
			{
				let project = Project.Current;
				Directory.CreateDirectory(scope $"{project.Path}/build").IgnoreError();
				let logFile = scope $"{project.Path}/build/csharp-build.log";
				let command = scope String();
				Terminal.AppendBuildTool(project.EngineRoot, command);
				command.Append(" --project ");
				Terminal.Quote(project.Path, command);
				command.Append(" --engine-root ");
				Terminal.Quote(project.EngineRoot, command);
				command.Append(" > ");
				Terminal.Quote(logFile, command);
				command.Append(" 2>&1");
				mCheckSucceeded = Terminal.Run(command) == 0;
				if (mCheckSucceeded && !Terminal.ManagedRuntimeCurrent(project.EngineRoot))
				{
					let runtime = scope String("dotnet build ");
					Terminal.Quote(scope $"{project.EngineRoot}/Managed/Tallow.ManagedRuntime/Tallow.ManagedRuntime.csproj" , runtime);
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
			MapToGraph(problem);
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
		if (mCheckManaged && mManagedRecheckQueued)
		{
			// The compiler may have read a source that was changed, renamed or deleted mid-build.
			// Publish diagnostics and reload assemblies only after checking the current sources.
			mManagedRecheckQueued = false;
			StartManagedErrorCheck();
			return;
		}
		ClearAndDeleteItems!(mProblems);
		if (mCheckManaged)
		{
			ParseManagedDiagnostics(mCheckLog);
			PublishScriptDiagnostics();
			if (!mCheckSucceeded)
			{
				// Some SDK/assembly-definition failures have no source location,
				// and therefore never enter the underlined-source diagnostic list.
				// Always include the actual compiler error in the Console.
				bool foundError = false;
				for (let line in mCheckLog.Split('\n'))
				{
					if (line.Contains(": error ") || line.Contains("error NETSDK") ||
						line.Contains("error MSB") || line.Contains("C# gameplay build failed:"))
					{
						Log.Error(line);
						foundError = true;
					}
				}
				if (!foundError)
				{
					if (mCheckLog.IsEmpty)
						Log.Error("C# compilation failed. Check the SDK and project configuration.");
					else
						Log.Error(mCheckLog);
				}
			}
			mManagedBuildReady = mCheckSucceeded;
			// A class renamed in this build: point the open scene at its new name.
			if (mCheckSucceeded && mPlay == .Edit && CSharpScriptIdentity.Repair(mScene, Project.Current.Path) > 0)
				MarkDirty();
			// Graphs can get and hold the game's scripts. An open graph keeps pointing at the replaced
			// node library (NodeLibrary retires it); it is freed once no graph is open.
			if (mCheckSucceeded)
			{
				ReloadEditorExtensions();
				NodeLibrary.RefreshCSharpScripts(Project.Current.Path);
				if (mGraph == null)
					NodeLibrary.FreeRetired();
			}
			mStatus.Set(mCheckSucceeded ? "C# assemblies compiled." : "C# compilation failed. See Console.");
			mManagedCompileNoticePending = mCheckSucceeded;
			if (mManagedCompileNoticePending)
				mManagedCompileNoticeClock.Restart();
			mCheckManaged = false;
			if (mPlayAfterCompile && mPlay == .Edit)
			{
				mPlayAfterCompile = false;
				if (mCheckSucceeded)
					StartPlay();
			}
			if (mHotReloadAfterCompile)
			{
				mHotReloadAfterCompile = false;
				if (mCheckSucceeded && mPlay != .Edit)
					HotReloadCSharp();
				else if (mPlay != .Edit)
					mStatus.Set("C# did not compile; the game keeps running the code it started with.");
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
		DrawFoundReferences();
	}

	/// Compact editor-local menu. The main application menu remains available
	/// for scene operations, while these commands apply to the selected script.
	void DrawScriptToolbar(ScriptDocument active)
	{
		if (!ImGui.BeginMenuBar())
			return;
		if (ImGui.BeginMenu("File"))
		{
			if (ImGui.MenuItem("Save Script", "Ctrl+S", false, active != null && !active.readOnly && ScriptMayEdit(active.path)))
				SaveScript(active);
			if (ImGui.MenuItem("Save All Scripts", null, false, mScripts.Count > 0))
				SaveAllScripts();
			ImGui.Separator();
			if (ImGui.MenuItem("Check Errors"))
			{
				SaveAllScripts();
				StartErrorCheck();
			}
			bool csharp = active != null && active.path.EndsWith(".cs");
			if (ImGui.MenuItem(csharp ? "Compile & Reload" : "Rebuild & Reload", "Ctrl+R"))
			{
				SaveAllScripts();
				RequestRebuild();
			}
			ImGui.EndMenu();
		}
		if (ImGui.BeginMenu("Edit"))
		{
			bool editable = active != null && !active.readOnly && ScriptMayEdit(active.path);
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
			bool ready = active != null && ScriptMayResolve(active.path) && !mSemantic.running;
			if (ImGui.MenuItem("Go to Definition", "F12", false, ready))
				RequestSemantic(active, "definition");
			if (ImGui.MenuItem("Find All References", "Shift+F12", false, ready))
				FindScriptReferences(active);
			if (ImGui.MenuItem("Symbol / Parameters", null, false, ready))
			{
				mSymbolInfoRequested = true;
				RequestSemantic(active, "symbol");
			}
			if (ImGui.MenuItem("Rename Symbol", "F2", false, ready && !active.readOnly && ScriptMayEdit(active.path)))
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

	/// One tab per open file. Generated code and files outside the project are read-only.
	void DrawScriptTabs(ScriptDocument active)
	{
		if (active != null && active.readOnly)
		{
			ImGui.SetCursorPosX(6);
			let graphPath = scope String();
			if (FindSourceGraph(active.path, graphPath))
			{
				ImGui.TextColored(EditorTheme.Warning, "Generated from a graph: read-only. Edit the graph, or");
				ImGui.SameLine();
				if (ImGui.SmallButton("Convert to Script") && ScriptMayEdit(active.path))
					ConvertGraphToScript(graphPath);
			}
			else
				ImGui.TextColored(EditorTheme.Warning, EngineApiSource(active.path) || ScriptInside(active.path, Project.Current.EngineRoot) ?
					"Engine source: read-only." : "Outside the project: read-only.");
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
