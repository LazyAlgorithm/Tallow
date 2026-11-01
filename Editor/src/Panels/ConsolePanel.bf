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
				Log.Clear();
			ImGui.SameLine();
			ImGui.TextDisabled(scope String()..AppendF("{} messages", Log.Entries.Count).CStr());
			ImGui.Separator();
			ImGui.BeginChild("log");
			ImGui.PushMonoFont();
			for (int i < Log.Entries.Count)
			{
				let entry = Log.Entries[i];
				switch (entry.level)
				{
				case .Info: ImGui.Text(entry.text);
				case .Warning: ImGui.TextColored(EditorTheme.Warning, entry.text.CStr());
				case .Error: ImGui.TextColored(EditorTheme.Error, entry.text.CStr());
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
}
