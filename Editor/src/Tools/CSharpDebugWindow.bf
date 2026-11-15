using System;
using System.Diagnostics;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Window > C# Debugging: how to attach Visual Studio Code, Rider or Visual Studio to the editor, whose
/// process runs the game's C# (built Debug, with symbols) while playing. Breakpoints, stepping and locals then
/// come from the IDE's .NET debugger; a stopped breakpoint pauses the whole editor until it continues.
extension EditorApp
{
	bool mShowCSharpDebugging;
	String mCSharpDebugStatus = new .() ~ delete _;
	Stopwatch mCSharpDebugCheck = new .(true) ~ delete _;
	bool mCSharpDebugChecked;
	bool mCSharpDebugReady;

	const String LaunchJson = """
		{
		  "version": "0.2.0",
		  "configurations": [
		    {
		      "name": "Attach to Tallow",
		      "type": "coreclr",
		      "request": "attach",
		      "processId": "${command:pickProcess}",
		      "justMyCode": true
		    }
		  ]
		}

		""";

	/// Writes .vscode/launch.json with an attach configuration, unless the project already has its own.
	bool WriteVSCodeLaunch(String message)
	{
		if (Project.Current == null)
			return false;
		let folder = scope $"{Project.Current.Path}/.vscode";
		let path = scope $"{folder}/launch.json";
		if (File.Exists(path))
		{
			let existing = scope String();
			File.ReadAllText(path, existing).IgnoreError();
			if (existing.Contains("Attach to Tallow"))
				message.Set(".vscode/launch.json already has \"Attach to Tallow\".");
			else
				message.Set(".vscode/launch.json exists and was left alone. Copy the configuration into it instead.");
			return false;
		}
		Directory.CreateDirectory(folder).IgnoreError();
		if (File.WriteAllText(path, LaunchJson) case .Err)
		{
			message.Set(scope $"Could not write {path}.");
			return false;
		}
		message.Set("Wrote .vscode/launch.json. In VS Code: Run and Debug > Attach to Tallow, then pick TallowLauncher.");
		return true;
	}

	void DrawCSharpDebugging()
	{
		if (!mShowCSharpDebugging)
			return;
		ImGui.SetNextWindowSize(.(620, 520), 4);
		if (ImGui.Begin("C# Debugging", &mShowCSharpDebugging))
		{
			let pid = Process.CurrentId;
			ImGui.Text(scope $"Editor process ID: {pid}");
			ImGui.SameLine();
			if (ImGui.SmallButton("Copy##pid"))
				ImGui.SetClipboardText(scope $"{pid}".CStr());
#if BF_PLATFORM_LINUX
			// CoreCLR opens /tmp/clr-debug-pipe-<pid>-<key>-in/out for debuggers as it starts. Looked for once a second.
			if (mCSharpDebugCheck.ElapsedMilliseconds > 1000 || !mCSharpDebugChecked)
			{
				mCSharpDebugCheck.Restart();
				mCSharpDebugChecked = true;
				mCSharpDebugReady = false;
				let prefix = scope $"clr-debug-pipe-{pid}-";
				for (let entry in Directory.EnumerateFiles("/tmp"))
				{
					let name = entry.GetFileName(.. scope .());
					if (name.StartsWith(prefix) && name.EndsWith("-in"))
					{
						mCSharpDebugReady = true;
						break;
					}
				}
			}
			let ready = mCSharpDebugReady;
			if (ready)
				ImGui.TextColored(.(0.45f, 0.85f, 0.5f, 1), "The .NET runtime is running and accepts debuggers.");
			else
				ImGui.TextDisabled("The .NET runtime starts with the first C# build or Play.");
#endif
			if (Project.Current != null)
			{
				let solution = scope String();
				Path.GetFileName(Project.Current.Path, solution);
				ImGui.TextDisabled(scope $"Solution for IDEs: {solution}.slnx (written by every C# build).".CStr());
			}
			ImGui.Separator();
			ImGui.Text("Visual Studio Code (C# Dev Kit or the C# extension)");
			if (ImGui.Button("Write .vscode/launch.json"))
				WriteVSCodeLaunch(mCSharpDebugStatus);
			ImGui.SameLine();
			if (ImGui.Button("Copy configuration"))
				ImGui.SetClipboardText(LaunchJson.CStr());
			let code = scope String();
			if (Project.Current != null && Toolchain.FindOnPath("code", code))
			{
				ImGui.SameLine();
				if (ImGui.Button("Open in VS Code"))
				{
					let command = scope String();
					Terminal.Quote(code, command);
					command.Append(' ');
					Terminal.Quote(Project.Current.Path, command);
					Terminal.RunDetached(command);
				}
			}
			if (!mCSharpDebugStatus.IsEmpty)
				ImGui.TextWrapped(mCSharpDebugStatus.CStr());
			ImGui.Separator();
			ImGui.Text("Rider or Visual Studio");
			ImGui.TextWrapped(scope String()..AppendF("Open the solution, then Run > Attach to Process (Debug > Attach to Process in Visual Studio) and pick TallowLauncher, process {}, with the .NET Core / CoreCLR debugger.", pid).CStr());
			ImGui.Separator();
			ImGui.TextWrapped("Set breakpoints in your scripts and press Play. When one is hit the whole editor stops until you continue: the game runs on the editor's main thread. A C# rebuild during Play loads a new copy of your scripts; the IDE picks up its symbols by itself.");
			ImGui.TextWrapped("To watch values without stopping, select the object while playing: the Inspector shows live values, and \"Debug: all fields (live)\" lists every field.");
		}
		ImGui.End();
	}
}
