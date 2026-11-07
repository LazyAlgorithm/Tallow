using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Compiler-backed editing commands. Resolver responses are applied only to the source revision they describe.
extension EditorApp
{
	[CLink] static extern int32 tn_code_take_semantic_request(void* handle, int32* cursor);
	[CLink] static extern void tn_code_invalidate_semantics(void* handle);
	[CLink] static extern void tn_code_discard_semantic_results(void* handle, bool retry);
	[CLink] static extern void tn_code_semantic_signature(void* handle, char8* signature);
	[CLink] static extern void tn_code_semantic_hint(void* handle, int32 cursor, char8* hint);
	[CLink] static extern int32 tn_code_cursor_byte(void* handle);
	[CLink] static extern void tn_code_semantic_results(void* handle, char8* words);
	[CLink] static extern void tn_code_goto_byte(void* handle, int32 offset);
	[CLink] static extern void tn_code_replace_text(void* handle, char8* text);

	ScriptSemantic mSemantic = new .() ~ delete _;
	String mSemanticObserved = new .() ~ delete _;
	String mSemanticObservedPath = new .() ~ delete _;
	String mSemanticHint = new .() ~ delete _;
	float mSemanticChangedAt;
	bool mSemanticNeedsCheck;
	int mSemanticApiRevision;
	bool mRenameOpen;
	bool mSymbolInfoRequested;
	bool mSymbolInfoOpen;
	bool mRenamePreview;
	String mSymbolNewName = new .() ~ delete _;
	String mSymbolRenameName = new .() ~ delete _;
	List<ScriptSymbolReference> mSymbolReferences = new .() ~ delete _;
	int mScriptDiagnosticClearVersion;
	HashSet<String> mPublishedScriptDiagnostics = new .() ~ DeleteContainerAndItems!(_);
	List<ScriptSourceSnapshot> mRenameUndo = new .() ~ DeleteContainerAndItems!(_);

	ScriptDocument FindScript(StringView path)
	{
		let canonical = scope String();
		ScriptSemantic.CanonicalPath(path, canonical);
		for (let document in mScripts)
		{
			if (Path.Equals(document.path, canonical))
				return document;
		}
		return null;
	}

	bool ReadScriptSource(StringView path, String output)
	{
		if (let document = FindScript(path))
		{
			output.Set(StringView(tn_code_get_text(document.handle)));
			return true;
		}
		return File.ReadAllText(path, output, true) case .Ok;
	}

	bool SemanticSourcesCurrent()
	{
		let text = scope String();
		for (let source in mSemantic.sources)
		{
			text.Clear();
			if (!ReadScriptSource(source.path, text) || text != source.text)
				return false;
		}
		return true;
	}

	void RequestSemantic(ScriptDocument document, StringView operation, int cursor = -1)
	{
		if (document == null || !document.path.EndsWith(".bf") || mSemantic.running)
			return;
		ClearAndDeleteItems!(mSemantic.sources);
		if (operation == "rename" && !mSemantic.AddFolder(scope $"{Project.Current.Path}/src"))
		{
			mSemantic.status.Set("Could not snapshot all project scripts for rename.");
			return;
		}
		for (let open in mScripts)
		{
			if (open.path.EndsWith(".bf"))
				mSemantic.Add(open.path, StringView(tn_code_get_text(open.handle)));
		}
		if (!mSemantic.Start(operation, document.path, cursor < 0 ? tn_code_cursor_byte(document.handle) : cursor, mSymbolNewName))
			mSemantic.status.Set("Could not start Beef language service.");
		if (operation == "diagnostics")
			mSemanticNeedsCheck = false;
	}

	/// Compiler warnings and the engine's prediction warnings both use the current, possibly unsaved, source.
	void AddSnapshotDeterminismWarnings()
	{
		for (let source in mSemantic.sources)
		{
			List<ScriptDeterminism.Warning> warnings = scope .();
			ScriptDeterminism.Check(source.text, warnings);
			for (let warning in warnings)
			{
				let problem = new ScriptProblem();
				problem.file.Set(source.path);
				problem.line = (int32)warning.line;
				problem.message.Set(warning.message);
				delete warning.message;
				mProblems.Add(problem);
			}
		}
	}

	/// Compiler and determinism diagnostics belong in the console, once per distinct source location and message.
	void PublishScriptDiagnostics(bool complete = true)
	{
		if (mScriptDiagnosticClearVersion != Log.ClearVersion)
		{
			ClearAndDeleteItems!(mPublishedScriptDiagnostics);
			mScriptDiagnosticClearVersion = Log.ClearVersion;
		}
		let active = new HashSet<String>();
		// Completion and hover can report only a subset of the workspace's diagnostics.
		if (!complete)
		{
			for (let key in mPublishedScriptDiagnostics)
				active.Add(new String(key));
		}
		for (let problem in mProblems)
		{
			let message = scope $"{problem.file}({problem.line + 1}): {problem.message}";
			let key = scope $"{(problem.isError ? "error" : "warning")} {message}";
			if (active.Contains(key))
				continue;
			if (!mPublishedScriptDiagnostics.Contains(key))
				Log.Add(problem.isError ? .Error : .Warning, message, problem.file, problem.line);
			active.Add(new String(key));
		}
		DeleteContainerAndItems!(mPublishedScriptDiagnostics);
		mPublishedScriptDiagnostics = active;
		ClearAndDeleteItems!(mProblems);
	}

	void CollectSemantic()
	{
		if (!mSemantic.Collect())
			return;
		let document = FindScript(mSemantic.path);
		if (!SemanticSourcesCurrent())
		{
			if (document != null && mSemantic.operation == "completion")
				tn_code_discard_semantic_results(document.handle, document == mActiveScript);
			mSemantic.status.Set("Source changed; requesting fresh diagnostics.");
			mSemanticNeedsCheck = true;
			return;
		}
		let suggestions = scope String();
		let signatures = scope String();
		if (mSemantic.operation == "symbol")
			mSemanticHint.Clear();
		mSymbolReferences.Clear();
		ClearAndDeleteItems!(mProblems);
		bool failed = false;
		for (let line in mSemantic.result.Split('\n'))
		{
			List<StringView> fields = scope .();
			for (let field in line.Split('\t'))
				fields.Add(field);
			if (fields.Count < 2)
				continue;
			switch (fields[0])
			{
			case "error":
				failed = true;
				mSemantic.status.Set("Beef: see Console for details.");
				let problem = new ScriptProblem();
				problem.file.Set(mSemantic.path);
				problem.message.Set(fields[1]);
				problem.isError = true;
				mProblems.Add(problem);
			case "completion":
				suggestions.Append(fields[1]);
				suggestions.Append('\n');
			case "signature","info":
				if (mSemantic.operation == "symbol" && mSemanticHint.Length < 4000)
					mSemanticHint.AppendF("{}\n", fields[1]);
				if (fields[0] == "signature" && mSemantic.operation == "completion" && signatures.Length < 4000)
					signatures.AppendF("{}\n", fields[1]);
			case "definition":
				if (fields.Count >= 4 && mSemantic.operation == "definition")
					OpenScript(fields[1], (int32)SceneSerializer.ParseInt(fields[2]));
			case "diagnostic":
				if (fields.Count >= 6)
				{
					let problem = new ScriptProblem();
					problem.file.Set(fields[1]);
					problem.line = (int32)SceneSerializer.ParseInt(fields[2]);
					problem.isError = fields[4] == "error";
					problem.message.Set(fields[5]);
					mProblems.Add(problem);
				}
			case "reference":
				if (fields.Count >= 5)
				{
					let index = mSemantic.Find(fields[1]);
					let start = SceneSerializer.ParseInt(fields[2]);
					let length = SceneSerializer.ParseInt(fields[3]);
					if (index < 0 || start < 0 || length <= 0 || start + length > mSemantic.sources[index].text.Length || mSemantic.sources[index].text.Substring(start, length) != fields[4])
						failed = true;
					else
						mSymbolReferences.Add(.() { file = index, start = start, length = length });
				}
			}
		}
		AddSnapshotDeterminismWarnings();
		PublishScriptDiagnostics(mSemantic.operation == "diagnostics");
		if (document != null && mSemantic.operation == "completion")
		{
			if (tn_code_cursor_byte(document.handle) == mSemantic.cursor)
				tn_code_semantic_results(document.handle, failed ? "" : suggestions.CStr());
			else
				tn_code_discard_semantic_results(document.handle, document == mActiveScript);
		}
		if (document != null && !signatures.IsEmpty && tn_code_cursor_byte(document.handle) == mSemantic.cursor)
			tn_code_semantic_signature(document.handle, signatures.CStr());
		if (document != null && mSemantic.operation == "symbol")
		{
			tn_code_semantic_hint(document.handle, (int32)mSemantic.cursor, mSemanticHint.CStr());
			mSymbolInfoOpen = mSymbolInfoRequested;
			mSymbolInfoRequested = false;
		}
		if (mSemantic.operation == "rename")
		{
			mRenamePreview = !failed && !mSymbolReferences.IsEmpty && mSymbolNewName == mSemantic.renameName;
			mSymbolRenameName.Set(mSemantic.renameName);
			if (!mRenamePreview)
				mSemantic.status.Set("Rename could not be validated. See diagnostics; no files were changed.");
		}
	}

	void UpdateSemantic(ScriptDocument document)
	{
		if (!document.path.EndsWith(".bf"))
			return;
		if (mSemanticApiRevision != ApiIndex.Revision)
		{
			mSemanticApiRevision = ApiIndex.Revision;
			for (let open in mScripts)
				tn_code_invalidate_semantics(open.handle);
		}
		let text = StringView(tn_code_get_text(document.handle));
		if (mSemanticObserved != text || mSemanticObservedPath != document.path)
		{
			for (let open in mScripts)
			{
				if (open != document)
					tn_code_invalidate_semantics(open.handle);
			}
			mSemanticObserved.Set(text);
			mSemanticObservedPath.Set(document.path);
			mSemanticChangedAt = Time.RealTime;
			mSemanticNeedsCheck = true;
		}
		if (mSemantic.running || mRenameOpen)
			return;
		int32 cursor = 0;
		let request = tn_code_take_semantic_request(document.handle, &cursor);
		if (request != 0)
			RequestSemantic(document, request == 2 ? "symbol" : "completion", cursor);
		else if (mSemanticNeedsCheck && Time.RealTime - mSemanticChangedAt > 1.5f)
			RequestSemantic(document, "diagnostics");
	}

	void DrawSemanticTools(ScriptDocument document)
	{
		bool ready = document != null && document.path.EndsWith(".bf") && !mSemantic.running;
		ImGui.BeginDisabled(!ready);
		if (ImGui.SmallButton("Definition (F12)") || (ready && mScriptsFocused && ImGui.IsKeyPressed(ImGui.Key.F12)))
			RequestSemantic(document, "definition");
		ImGui.SameLine();
		if (ImGui.SmallButton("Symbol / Parameters"))
		{
			mSymbolInfoRequested = true;
			RequestSemantic(document, "symbol");
		}
		ImGui.SameLine();
		if (ImGui.SmallButton("Rename Symbol (F2)") || (ready && mScriptsFocused && ImGui.IsKeyPressed(ImGui.Key.F2)))
		{
			mRenameOpen = true;
			mRenamePreview = false;
			mSymbolNewName.Clear();
			ImGui.OpenPopup("Rename Symbol Across Project");
		}
		ImGui.EndDisabled();
		ImGui.SameLine();
		ImGui.BeginDisabled(mRenameUndo.IsEmpty);
		if (ImGui.SmallButton("Undo Rename"))
			UndoSymbolRename();
		ImGui.EndDisabled();
		if (!mSemantic.status.IsEmpty)
			ImGui.TextDisabled(mSemantic.status.CStr());
		if (mSymbolInfoOpen)
		{
			ImGui.OpenPopup("Symbol Information");
			mSymbolInfoOpen = false;
		}
		if (ImGui.BeginPopup("Symbol Information"))
		{
			ImGui.Text(mSemanticHint.IsEmpty ? "No symbol information at the cursor." : (StringView)mSemanticHint);
			ImGui.EndPopup();
		}
		DrawSymbolRename(document);
	}
}
