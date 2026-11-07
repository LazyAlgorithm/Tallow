using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Project-wide rename uses compiler occurrences, applies to unsaved buffers, and keeps one transaction to undo.
extension EditorApp
{
	void DrawSymbolRename(ScriptDocument document)
	{
		if (!ImGui.BeginPopupModal("Rename Symbol Across Project", null, ImGui.WindowFlags.AlwaysAutoResize))
			return;
		ImGui.Text("New symbol name");
		ImGui.TextWrapped("Renames code references. Saved field names and type names in scenes or prefabs are unchanged.");
		ImGui.SetNextItemWidth(360);
		if (ImGui.InputText("##symbolname", mSymbolNewName))
			mRenamePreview = false;
		ImGui.BeginDisabled(mSemantic.running || mSymbolNewName.IsEmpty);
		if (ImGui.Button("Find and Validate References"))
		{
			mRenamePreview = false;
			RequestSemantic(document, "rename");
		}
		ImGui.EndDisabled();
		ImGui.TextWrapped(mSemantic.status.CStr());
		if (mRenamePreview)
		{
			ImGui.Text(scope $"{mSymbolReferences.Count} symbol occurrences. Changes stay unsaved until Save All.");
			ImGui.BeginChild("rename-preview", .(600, 200), ImGui.ChildBorders);
			for (let reference in mSymbolReferences)
			{
				let source = mSemantic.sources[reference.file];
				int line = 1;
				for (int i < reference.start)
				{
					if (source.text[i] == '\n')
						line++;
				}
				ImGui.Text(scope $"{source.path}:{line}");
			}
			ImGui.EndChild();
			if (ImGui.Button("Apply Rename") && ApplySymbolRename())
			{
				mRenameOpen = false;
				ImGui.CloseCurrentPopup();
			}
			ImGui.SameLine();
		}
		if (ImGui.Button("Cancel"))
		{
			mRenameOpen = false;
			mRenamePreview = false;
			ImGui.CloseCurrentPopup();
		}
		ImGui.EndPopup();
	}

	bool ApplySymbolRename()
	{
		if (!mRenamePreview || mSymbolRenameName != mSymbolNewName || !SemanticSourcesCurrent())
		{
			mRenamePreview = false;
			mSemantic.status.Set("Source changed since the preview. Validate the rename again.");
			return false;
		}
		mSymbolReferences.Sort(scope (a, b) => a.file != b.file ? a.file <=> b.file : b.start <=> a.start);
		for (let source in mSemantic.sources)
			source.replacement.Set(source.text);
		let sourceRoot = scope String();
		ScriptSemantic.CanonicalPath(scope $"{Project.Current.Path}/src/" , sourceRoot);
		sourceRoot.Append('/');
		int previousFile = -1;
		int previousStart = int.MaxValue;
		for (let reference in mSymbolReferences)
		{
			let source = mSemantic.sources[reference.file];
			if (reference.file != previousFile)
				previousStart = int.MaxValue;
			if (reference.start == previousStart)
				continue;
			if (!source.path.StartsWith(sourceRoot) || FindSourceGraph(source.path, scope String()) || reference.start + reference.length > previousStart)
			{
				mSemantic.status.Set("Rename contains a generated, external or overlapping reference and cannot be applied.");
				return false;
			}
			source.replacement.Remove(reference.start, reference.length);
			source.replacement.Insert(reference.start, mSymbolRenameName);
			previousFile = reference.file;
			previousStart = reference.start;
		}
		// Open and verify every affected buffer before changing any. A failed file read cannot leave half a rename.
		for (let source in mSemantic.sources)
		{
			if (source.replacement == source.text)
				continue;
			OpenScript(source.path);
			let document = FindScript(source.path);
			if (document == null || document.readOnly || StringView(tn_code_get_text(document.handle)) != source.text)
			{
				mSemantic.status.Set("Could not open every reference unchanged. No rename was applied.");
				return false;
			}
		}
		ClearAndDeleteItems!(mRenameUndo);
		for (let source in mSemantic.sources)
		{
			if (source.replacement == source.text)
				continue;
			let undo = new ScriptSourceSnapshot();
			undo.path.Set(source.path);
			undo.text.Set(source.text);
			undo.replacement.Set(source.replacement);
			mRenameUndo.Add(undo);
			tn_code_replace_text(FindScript(source.path).handle, source.replacement.CStr());
		}
		mSemantic.status.Set(scope $"Renamed in {mRenameUndo.Count} files. Save All to write the changes, or Undo Rename.");
		mRenamePreview = false;
		mSemanticNeedsCheck = true;
		return true;
	}

	void UndoSymbolRename()
	{
		let current = scope String();
		for (let source in mRenameUndo)
		{
			current.Clear();
			if (!ReadScriptSource(source.path, current) || current != source.replacement)
			{
				mSemantic.status.Set("A renamed file was edited again. Undo those edits before Undo Rename.");
				return;
			}
		}
		for (let source in mRenameUndo)
		{
			OpenScript(source.path);
			let document = FindScript(source.path);
			if (document == null || document.readOnly)
				return;
		}
		for (let source in mRenameUndo)
			tn_code_replace_text(FindScript(source.path).handle, source.text.CStr());
		ClearAndDeleteItems!(mRenameUndo);
		mSemantic.status.Set("Rename undone in every affected buffer. Save All to write the restored source.");
		mSemanticNeedsCheck = true;
	}
}
