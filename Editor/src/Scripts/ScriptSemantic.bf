using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Compiler-backed analysis, navigation and diagnostics for open script documents.
extension EditorApp
{
	[CLink] static extern int32 tn_code_cursor_offset(void* handle);
	[CLink] static extern void tn_code_semantic_mode(void* handle, bool enabled);
	[CLink] static extern bool tn_code_completion_request(void* handle, out uint64 revision, out int32 cursor);
	[CLink] static extern bool tn_code_completion_result(void* handle, uint64 revision, int32 cursor, char8* words);

	BeefAnalysisClient mAnalysis ~ delete _;
	String mAnalysisProject = new .() ~ delete _;
	String mAnalysisHint = new .() ~ delete _;
	bool mAnalysisAttempted;
	int32 mAnalysisGeneration;
	int32 mAnalysisRequest;
	int32 mAnalysisHintCursor = -1;
	int32 mAnalysisAutoCursor = -1;
	uint64 mAnalysisSeenRevision = uint64.MaxValue;
	uint64 mAnalysisDiagnosedRevision = uint64.MaxValue;
	ScriptDocument mAnalysisDocument;
	Stopwatch mAnalysisIdle = new .(true) ~ delete _;

	void ResetAnalysis()
	{
		DeleteAndNullify!(mAnalysis);
		mAnalysisAttempted = false;
		mAnalysisGeneration++;
		mAnalysisDocument = null;
		mAnalysisSeenRevision = uint64.MaxValue;
		mAnalysisDiagnosedRevision = uint64.MaxValue;
		mAnalysisHint.Clear();
		for (let document in mScripts)
			tn_code_semantic_mode(document.handle, false);
	}

	void PollAnalysis()
	{
		let project = Project.Current;
		if (project == null || mScripts.Count == 0) return;
		if (mAnalysisProject != project.Path)
		{
			ResetAnalysis();
			mAnalysisProject.Set(project.Path);
		}
		if (!mAnalysisAttempted)
		{
			mAnalysisAttempted = true;
#if BF_PLATFORM_LINUX || BF_PLATFORM_WINDOWS
			let service = scope $"{project.EngineRoot}/tools/semantic/service.py";
			let helper = scope $"{project.EngineRoot}/build/semantic/beef-resolve";
		#if BF_PLATFORM_WINDOWS
			helper.Append(".exe");
		#endif
			if (!File.Exists(helper))
			{
				helper.Set(scope $"{project.EngineRoot}/tools/semantic/beef-resolve");
		#if BF_PLATFORM_WINDOWS
				helper.Append(".exe");
		#endif
			}
			if (File.Exists(service) && File.Exists(helper))
			{
				project.WriteBuildFiles();
				mAnalysis = new .(project.Path, service, helper);
			}
#endif
		}
		let ready = mAnalysis?.Ready ?? false;
		for (let document in mScripts)
			tn_code_semantic_mode(document.handle, ready && document.path.EndsWith(".bf"));
		if (!ready) return;
		let response = scope String();
		if (mAnalysis.TakeResult(response))
			ApplyAnalysis(response);
		let active = mActiveScript;
		if (active == null || !active.path.EndsWith(".bf")) return;
		let revision = tn_code_revision(active.handle);
		if (mAnalysisDocument != active || mAnalysisSeenRevision != revision)
		{
			mAnalysisDocument = active;
			mAnalysisSeenRevision = revision;
			mAnalysisDiagnosedRevision = uint64.MaxValue;
			mAnalysisHint.Clear();
			mAnalysisAutoCursor = -1;
			mAnalysisIdle.Restart();
		}
		let currentCursor = tn_code_cursor_offset(active.handle);
		if (currentCursor != mAnalysisHintCursor)
			mAnalysisHint.Clear();
		if (mAnalysisIdle.ElapsedMilliseconds < 200) return;
		if (tn_code_completion_request(active.handle, let requestRevision, let cursor))
		{
			if (requestRevision == revision)
				RequestAnalysis(active, "completion", cursor);
			return;
		}
		if (mAnalysisAutoCursor != currentCursor && currentCursor > 0)
		{
			let text = StringView(tn_code_get_text(active.handle));
			if (currentCursor <= text.Length && (text[currentCursor - 1] == '(' || text[currentCursor - 1] == ','))
			{
				mAnalysisAutoCursor = currentCursor;
				RequestAnalysis(active, "completion", currentCursor);
				return;
			}
		}
		if (mAnalysisIdle.ElapsedMilliseconds >= 750 && mAnalysisDiagnosedRevision != revision)
		{
			mAnalysisDiagnosedRevision = revision;
			RequestAnalysis(active, "diagnostics", -1);
		}
	}

	void RequestAnalysis(ScriptDocument document, StringView kind, int32 cursor)
	{
		if (document == null || !(mAnalysis?.Ready ?? false)) return;
		let request = scope SaveNode(.Object);
		request.Set("id", SaveNode.MakeInt(++mAnalysisRequest));
		request.Set("generation", SaveNode.MakeInt(mAnalysisGeneration));
		request.Set("path", SaveNode.MakeString(document.path));
		request.Set("cursor", SaveNode.MakeInt(cursor));
		request.Set("kind", SaveNode.MakeString(kind));
		let buffers = new SaveNode(.List);
		request.Set("buffers", buffers);
		for (let open in mScripts)
		{
			if (!open.path.EndsWith(".bf")) continue;
			let buffer = new SaveNode(.Object);
			buffer.Set("path", SaveNode.MakeString(open.path));
			buffer.Set("revision", SaveNode.MakeInt((int64)tn_code_revision(open.handle)));
			buffer.Set("text", SaveNode.MakeString(StringView(tn_code_get_text(open.handle))));
			buffers.items.Add(buffer);
		}
		let text = scope String();
		request.ToText(text, false);
		mAnalysis.Submit(text);
	}

	void ApplyAnalysis(StringView response)
	{
		let result = SaveNode.FromText(response);
		defer delete result;
		if (result == null || result["id"]?.AsInteger != mAnalysisRequest || result["generation"]?.AsInteger != mAnalysisGeneration) return;
		if (result["error"] != null) return;
		let versions = result["versions"];
		if (versions == null || versions.keys == null) return;
		for (int i < versions.Count)
		{
			ScriptDocument match = null;
			for (let document in mScripts)
			{
				if (document.path == versions.keys[i])
				{
					match = document;
					break;
				}
			}
			if (match == null || tn_code_revision(match.handle) != (uint64)versions.items[i].AsInteger) return;
		}
		ScriptDocument target = null;
		for (let document in mScripts)
		{
			if (document.path == result["path"]?.text)
			{
				target = document;
				break;
			}
		}
		if (target == null) return;
		let kind = result["kind"]?.text;
		let cursor = (int32)(result["cursor"]?.AsInteger ?? -1);
		if (kind != "diagnostics" && tn_code_cursor_offset(target.handle) != cursor) return;
		if (kind == "completion")
		{
			let words = scope String();
			if (let completions = result["completions"]?.items)
			{
				for (let item in completions)
					words.Append(item.text, "\n");
			}
			tn_code_completion_result(target.handle, (uint64)result["revision"].AsInteger, cursor, words.CStr());
			mAnalysisHint.Clear();
			mAnalysisHintCursor = cursor;
			if (let signatures = result["signatures"]?.items)
			{
				for (let item in signatures)
				{
					if (!mAnalysisHint.IsEmpty)
						mAnalysisHint.Append("   |   ");
					mAnalysisHint.Append(item.text);
				}
			}
		}
		if (kind == "diagnostics")
		{
			tn_code_clear_markers(target.handle);
			if (let diagnostics = result["diagnostics"]?.items)
			{
				for (let diagnostic in diagnostics)
				{
					if (diagnostic["file"]?.text == target.path)
						tn_code_add_marker(target.handle, (int32)diagnostic["line"].AsInteger,
							diagnostic["warning"].AsInteger == 0, diagnostic["message"].text.CStr());
				}
			}
		}
		if (kind == "definition")
		{
			let definition = result["definition"];
			if (definition != null && !definition.IsNull)
				OpenScript(definition["path"].text, (int32)definition["line"].AsInteger);
		}
		if (kind == "hover")
		{
			mAnalysisHintCursor = cursor;
			mAnalysisHint.Clear();
			if (let documentation = result["documentation"]?.items)
			{
				for (let item in documentation)
				{
					if (!mAnalysisHint.IsEmpty)
						mAnalysisHint.Append("\n");
					mAnalysisHint.Append(item.text);
				}
			}
			if (mAnalysisHint.IsEmpty)
				mAnalysisHint.Set("No documentation at this position.");
		}
	}

	void DrawAnalysisToolbar(ScriptDocument active)
	{
		let ready = mAnalysis?.Ready ?? false;
		ImGui.SetCursorPosX(6);
		if (ready)
			ImGui.TextDisabled("Beef compiler");
		else if (mAnalysis != null && !mAnalysis.Failed)
			ImGui.TextDisabled("Starting Beef analysis...");
		else
			ImGui.TextDisabled("Basic completion");
		ImGui.SameLine();
		ImGui.BeginDisabled(!ready || active == null);
		if (ImGui.SmallButton("Definition") && active != null)
			RequestAnalysis(active, "definition", tn_code_cursor_offset(active.handle));
		ImGui.SameLine();
		if (ImGui.SmallButton("Signature") && active != null)
			RequestAnalysis(active, "completion", tn_code_cursor_offset(active.handle));
		ImGui.SameLine();
		if (ImGui.SmallButton("Info") && active != null)
			RequestAnalysis(active, "hover", tn_code_cursor_offset(active.handle));
		ImGui.EndDisabled();
		if (!mAnalysisHint.IsEmpty)
		{
			ImGui.SameLine();
			ImGui.TextDisabled(mAnalysisHint.CStr());
		}
	}
}
