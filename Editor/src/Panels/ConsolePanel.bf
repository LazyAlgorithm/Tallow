using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Console panel.
extension EditorApp
{
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
			ImGui.TextDisabled(scope String()..AppendF("{} messages", Log.Entries.Count).CStr());
			ImGui.Separator();
			ImGui.BeginChild("log");
			ImGui.PushMonoFont();
			for (int i < Log.Entries.Count)
			{
				let entry = Log.Entries[i];
				if (entry.file != null && entry.line >= 0)
				{
					ImGui.PushID((int32)i);
					ImGui.PushStyleColor(ImGui.Col.Text, entry.level == .Error ? EditorTheme.Error : EditorTheme.Warning);
					if (ImGui.Selectable(entry.text.CStr()))
						OpenConsoleDiagnostic(entry);
					ImGui.PopStyleColor();
					ImGui.PopID();
				}
				else
				{
					switch (entry.level)
					{
					case .Info: ImGui.Text(entry.text);
					case .Warning: ImGui.TextColored(EditorTheme.Warning, entry.text.CStr());
					case .Error: ImGui.TextColored(EditorTheme.Error, entry.text.CStr());
					}
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
