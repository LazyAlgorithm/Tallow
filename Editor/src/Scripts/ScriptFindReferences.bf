using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Find All References (Shift+F12, Navigate menu): every use of the symbol at the caret across the project's scripts,
/// from the compiler (unsaved edits included), listed by file and line with the line's text. Clicking one opens it
/// with the caret on the name. Uses of an engine API symbol inside the engine's own C# source are listed too and
/// open read-only.
extension EditorApp
{
	class ScriptFoundReference
	{
		public String path = new .() ~ delete _;
		public String preview = new .() ~ delete _;
		public int32 line;
		public int32 column;
		public int32 byteStart;
	}

	List<ScriptFoundReference> mFoundReferences = new .() ~ DeleteContainerAndItems!(_);
	String mFoundReferencesName = new .() ~ delete _;
	String mFoundReferencesText = new .() ~ delete _;
	String mFoundReferencesTextPath = new .() ~ delete _;
	bool mFoundReferencesOpen;
	bool mFoundReferencesFocus;
	int mFoundReferencesSelected = -1;

	void FindScriptReferences(ScriptDocument document, int cursor = -1)
	{
		if (document == null || mSemantic.running || !ScriptMayResolve(document.path))
			return;
		ClearAndDeleteItems!(mFoundReferences);
		mFoundReferencesName.Clear();
		mFoundReferencesSelected = -1;
		mFoundReferencesOpen = true;
		mFoundReferencesFocus = true;
		RequestSemantic(document, "references", cursor);
	}

	/// One "reference" line of a "references" request: path, byte start and length, the name.
	void AddFoundReference(StringView path, int start, int length, StringView name)
	{
		if (mFoundReferencesTextPath != path)
		{
			mFoundReferencesTextPath.Set(path);
			mFoundReferencesText.Clear();
			let index = mSemantic.Find(path);
			if (index >= 0)
				mFoundReferencesText.Set(mSemantic.sources[index].text);
			else if (!ReadScriptSource(path, mFoundReferencesText))
				mFoundReferencesText.Clear();
		}
		let text = mFoundReferencesText;
		if (start < 0 || length <= 0 || start + length > text.Length || text.Substring(start, length) != name)
			return;
		int lineStart = 0;
		int32 line = 0;
		for (int i < start)
		{
			if (text[i] == '\n')
			{
				line++;
				lineStart = i + 1;
			}
		}
		int lineEnd = text.IndexOf('\n', start);
		if (lineEnd < 0)
			lineEnd = text.Length;
		let reference = new ScriptFoundReference();
		reference.path.Set(path);
		reference.line = line;
		reference.byteStart = (int32)start;
		// Columns as characters, for the list only.
		reference.column = (int32)StringView(text, lineStart, start - lineStart).Length;
		var preview = StringView(text, lineStart, lineEnd - lineStart);
		preview.Trim();
		reference.preview.Set(preview.Length > 160 ? preview.Substring(0, 160) : preview);
		reference.preview.Replace('\t', ' ');
		mFoundReferences.Add(reference);
		mFoundReferencesName.Set(name);
	}

	void FinishFoundReferences(bool failed)
	{
		mFoundReferencesTextPath.Clear();
		mFoundReferencesText.Clear();
		// The compiler walks files in its own order: list them by path, then position.
		mFoundReferences.Sort(scope (a, b) =>
		{
			int order = String.Compare(a.path, b.path, true);
			return order != 0 ? order : a.byteStart <=> b.byteStart;
		});
		if (failed)
			mSemantic.status.Set("Find References: the compiler could not answer. See Console.");
		else if (mFoundReferences.IsEmpty)
			mSemantic.status.Set("Find References: no symbol at the caret, or it is not used.");
		else
			mSemantic.status.Set(scope $"{mFoundReferences.Count} reference{mFoundReferences.Count == 1 ? "" : "s"} to {mFoundReferencesName}");
	}

	void OpenFoundReference(ScriptFoundReference reference)
	{
		OpenScript(reference.path, reference.line);
		if (let opened = FindScript(reference.path))
			tn_code_goto_byte(opened.handle, reference.byteStart);
	}

	void DrawFoundReferences()
	{
		if (!mFoundReferencesOpen)
			return;
		if (mFoundReferencesFocus)
		{
			ImGui.SetNextWindowFocus();
			mFoundReferencesFocus = false;
		}
		ImGui.SetNextWindowSize(.(640, 280), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("References###FindReferences", &mFoundReferencesOpen))
		{
			if (mSemantic.running && mSemantic.operation == "references")
				ImGui.TextDisabled("Searching...");
			else
				ImGui.TextWrapped(mSemantic.operation == "references" ? mSemantic.status.CStr() : "");
			ImGui.Separator();
			ImGui.BeginChild("references-list", .(0, 0));
			let project = scope String(Project.Current.Path);
			project.Replace('\\', '/');
			String last = scope .();
			for (int i < mFoundReferences.Count)
			{
				let reference = mFoundReferences[i];
				let shown = scope String(reference.path);
				shown.Replace('\\', '/');
				if (shown.StartsWith(project) && shown.Length > project.Length)
					shown.Remove(0, project.Length + 1);
				if (shown != last)
				{
					ImGui.TextColored(EditorTheme.Accent, shown.CStr());
					last.Set(shown);
				}
				ImGui.PushID((int32)i);
				if (ImGui.Selectable(scope $"    {reference.line + 1}:{reference.column + 1}  {reference.preview}", mFoundReferencesSelected == i))
				{
					mFoundReferencesSelected = i;
					OpenFoundReference(reference);
				}
				ImGui.PopID();
			}
			ImGui.EndChild();
		}
		ImGui.End();
	}
}
