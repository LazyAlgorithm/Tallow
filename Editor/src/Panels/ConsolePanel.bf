using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Console panel.
extension EditorApp
{
	bool mConsoleShowDetails;

	void DrawConsole()
	{
		if (ImGui.Begin("Console"))
		{
			if (ImGui.Button("Clear"))
			{
				Log.Clear();
				ClearAndDeleteItems!(mPublishedScriptDiagnostics);
			}
			ImGui.SameLine();
			ImGui.Checkbox("Stack traces / details", &mConsoleShowDetails);
			ImGui.SameLine();
			ImGui.TextDisabled(scope String()..AppendF("{} unique messages", Log.Entries.Count).CStr());
			ImGui.Separator();
			ImGui.BeginChild("log");
			ImGui.PushMonoFont();
			for (int i < Log.Entries.Count)
			{
				let entry = Log.Entries[i];
				// Keep every console row one line, even when a stack trace is attached.
				let firstBreak = entry.text.IndexOf('\n');
				let preview = scope String();
				preview.Set(firstBreak >= 0 ? StringView(entry.text).Substring(0, firstBreak) : StringView(entry.text));
				if (preview.EndsWith("\r"))
					preview.RemoveFromEnd(1);
				if (entry.repeats > 1)
					preview.AppendF("  (x{})", entry.repeats);
				if (entry.file != null && entry.line >= 0)
				{
					ImGui.PushID((int32)i);
					ImGui.PushStyleColor(ImGui.Col.Text, entry.level == .Error ? EditorTheme.Error : EditorTheme.Warning);
					if (ImGui.Selectable(preview.CStr()))
						OpenConsoleDiagnostic(entry);
					ImGui.PopStyleColor();
					ImGui.PopID();
				}
				else
				{
					switch (entry.level)
					{
					case .Info: ImGui.Text(preview);
					case .Warning: ImGui.TextColored(EditorTheme.Warning, preview.CStr());
					case .Error: ImGui.TextColored(EditorTheme.Error, preview.CStr());
					}
				}
				if (mConsoleShowDetails && firstBreak >= 0 && firstBreak + 1 < entry.text.Length)
				{
					ImGui.Indent();
					ImGui.TextWrapped(entry.text.CStr() + firstBreak + 1);
					ImGui.Unindent();
				}
			}
			ImGui.PopFont();
			if (mLogVersion != Log.Version)
			{
				mLogVersion = (int32)Log.Version;
				ImGui.SetScrollHereY(1.0f);
			}
			ImGui.EndChild();
		}
		ImGui.End();
	}

	/// Opens the structured source location carried by a compiler or determinism diagnostic.
	bool OpenConsoleDiagnostic(Log.Entry entry)
	{
		if (entry.file == null || entry.line < 0 || !File.Exists(entry.file))
			return false;
		OpenScript(entry.file, entry.line);
		return true;
	}
}
