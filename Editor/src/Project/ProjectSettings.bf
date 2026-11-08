using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// File > Project Settings: start scene, Beef libraries and extra linker flags.
/// The Beef workspace files are regenerated from these settings on every build.
extension EditorApp
{
	bool mShowSettings;
	String mLibraryInput = new .() ~ delete _;
	String mSettingsMessage = new .() ~ delete _;

	void DrawProjectSettings()
	{
		if (!mShowSettings)
			return;
		let project = Project.Current;
		ImGui.SetNextWindowSize(.(620, 460), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Project Settings", &mShowSettings, ImGui.WindowFlags.NoDocking | ImGui.WindowFlags.NoCollapse))
		{
			DrawGeneralSettings(project);
			DrawScriptReloadSettings(project);
			DrawProjectConfigSettings();
			DrawLibrarySettings(project);
			ImGui.SeparatorText("Native libraries");
			ImGui.TextWrapped("Extra linker arguments for C libraries, for example -lcurl or the path to a .a file.");
			ImGui.SetNextItemWidth(-1);
			if (ImGui.InputText("##link", project.LinkFlags))
				project.Save();

			ImGui.Spacing();
			if (!mSettingsMessage.IsEmpty)
				ImGui.TextColored(EditorTheme.Warning, mSettingsMessage.CStr());
			if (ImGui.Button("Rebuild & Reload", .(160, 28)))
				RequestRebuild();
		}
		ImGui.End();
	}

	/// Reload policy is a development-time project option, not a gameplay dependency.
	void DrawScriptReloadSettings(Project project)
	{
		ImGui.SeparatorText("Scripting");
		if (BeginPropertyTable("scriptreload"))
		{
			BeginProperty("Script Reload");
			let selected = scope String();
			project.ReloadMode.ToString(selected);
			ImGui.SetNextItemWidth(-1);
			if (ImGui.BeginCombo("##scriptreload", selected.CStr()))
			{
				for (let (name, mode) in Enum.GetEnumerator<ScriptReloadMode>())
				{
					if (ImGui.Selectable(scope String(name).CStr(), mode == project.ReloadMode))
					{
						project.ReloadMode = mode;
						project.Save();
						if (mode == .Manual)
						{
							mReloadQueued = false;
							mReloadForceConservative = false;
							mScriptMonitor.Poll(Assets.ProjectPath);
						}
					}
				}
				ImGui.EndCombo();
			}
			ImGui.EndTable();
		}
		switch (project.ReloadMode)
		{
		case .Automatic:
			ImGui.TextWrapped("Default: fast method patching for compatible body-only edits; structural reload for changes to declarations. Falls back to structural reload when method validation fails.");
		case .Conservative:
			ImGui.TextWrapped("Always compile and migrate the full script library, including method-only edits. Use this to investigate hot-reload compatibility.");
		case .Manual:
			ImGui.TextWrapped("Save without compiling or activating scripts. Use File > Reload Scripts when ready. Check Errors remains available.");
		}
		if (ImGui.Button("Force Structural Script Reload"))
			ForceConservativeScriptReload();
	}

	/// The start scene, audio, anti-cheat, saving, voice chat and Steam.
	void DrawGeneralSettings(Project project)
	{
		ImGui.SeparatorText("General");
		if (BeginPropertyTable("general"))
		{
			BeginProperty("Start Scene");
			if (ImGui.InputText("##start", project.StartScene))
				project.Save();
			BeginProperty("Headphone 3D Audio");
			if (ImGui.Checkbox("##hrtf", ref project.AudioHrtf))
			{
				Audio.Hrtf = project.AudioHrtf;
				project.Save();
			}
			BeginProperty("Anti-Cheat");
			if (ImGui.Checkbox("##anticheat", ref project.AntiCheat))
				project.Save();
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Watches network sessions for cheating: controls no honest game sends, speed hacks, message floods, changed game files, debuggers and injected libraries, edited memory and automated aim. What is found is logged, and players are removed for what only a changed game does. See the Anti-cheat page of the documentation.");
			BeginProperty("Load Save At Start");
			if (ImGui.Checkbox("##loadsave", ref project.LoadSaveAtStart))
				project.Save();
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("When the game starts, the save in the slot below is put back before any script runs ([Saved] fields, objects made while playing, SavedTransform). See the Saving page of the documentation.");
			if (project.LoadSaveAtStart)
			{
				BeginProperty("Save Slot");
				ImGui.SetNextItemWidth(-1);
				if (ImGui.InputText("##saveslot", project.SaveSlot))
					project.Save();
			}
			DrawVoiceSettings(project);
			BeginProperty("Steam App ID");
			if (ImGui.InputInt("##steam", ref project.SteamAppId))
			{
				project.SteamAppId = Math.Max(project.SteamAppId, 0);
				Steam.AppId = (uint32)project.SteamAppId;
				project.Save();
			}
			ImGui.EndTable();
		}
	}

	/// Voice chat, and with it on: push to talk (and its key), proximity and team-only voice. In a property table.
	void DrawVoiceSettings(Project project)
	{
		BeginProperty("Voice Chat");
		if (ImGui.Checkbox("##voice", ref project.VoiceChat))
			project.Save();
		if (project.VoiceChat)
		{
			BeginProperty("Push To Talk");
			if (ImGui.Checkbox("##voiceptt", ref project.VoicePushToTalk))
				project.Save();
			if (project.VoicePushToTalk)
			{
				BeginProperty("Push To Talk Key");
				let current = scope String();
				project.VoiceKey.ToString(current);
				ImGui.SetNextItemWidth(-1);
				if (ImGui.BeginCombo("##voicekey", current.CStr()))
				{
					for (let (name, value) in Enum.GetEnumerator<KeyCode>())
					{
						if (value == .None)
							continue;
						if (ImGui.Selectable(scope String(name).CStr(), value == project.VoiceKey))
						{
							project.VoiceKey = value;
							project.Save();
						}
					}
					ImGui.EndCombo();
				}
			}
			BeginProperty("Proximity Voice");
			if (ImGui.Checkbox("##voicenear", ref project.VoiceProximity))
				project.Save();
			BeginProperty("Team Only Voice");
			if (ImGui.Checkbox("##voiceteam", ref project.VoiceTeamOnly))
				project.Save();
		}
	}

	/// The Beef libraries the scripts can use: each with a Remove button, and a box to add one from Git or a folder.
	void DrawLibrarySettings(Project project)
	{
		ImGui.SeparatorText("Libraries");
		ImGui.TextWrapped("Beef libraries your scripts can use. Paste a Git address to download one into the project's Libraries folder, or a folder path to reference a library that lives elsewhere.");
		List<(String name, String path)> libraries = scope .();
		defer
		{
			for (let l in libraries)
			{
				delete l.name;
				delete l.path;
			}
		}
		project.CollectLibraries(libraries);
		String removeReference = null;
		String removeFolder = null;
		if (libraries.Count == 0)
			ImGui.TextDisabled("No libraries added.");
		for (int32 i = 0; i < (int32)libraries.Count; i++)
		{
			let library = libraries[i];
			ImGui.PushID(i);
			if (ImGui.SmallButton("Remove"))
			{
				bool referenced = false;
				for (let reference in project.Libraries)
				{
					if (reference == library.path)
					{
						removeReference = reference;
						referenced = true;
					}
				}
				if (!referenced)
					removeFolder = library.path;
			}
			ImGui.SameLine();
			ImGui.Text(library.name);
			ImGui.SameLine();
			ImGui.TextDisabled(library.path.CStr());
			ImGui.PopID();
		}
		if (removeReference != null)
		{
			project.Libraries.Remove(removeReference);
			delete removeReference;
			project.Save();
			mSettingsMessage.Set("Removed. Rebuild & Reload to apply.");
		}
		if (removeFolder != null)
		{
			// Downloaded libraries are moved aside rather than deleted outright.
			let name = scope String();
			Path.GetFileName(removeFolder, name);
			Directory.CreateDirectory(scope $"{project.Path}/Libraries/.removed").IgnoreError();
			if (Directory.Move(removeFolder, scope $"{project.Path}/Libraries/.removed/{name}") case .Ok)
				mSettingsMessage.Set("Moved to Libraries/.removed. Rebuild & Reload to apply.");
			else
				mSettingsMessage.Set("Could not remove that library folder.");
		}

		ImGui.SetNextItemWidth(-90);
		ImGui.InputText("##library", mLibraryInput, 0, "https://github.com/user/library  or  /path/to/library");
		ImGui.SameLine();
		if (ImGui.Button("Add", .(80, 0)))
			AddLibrary(mLibraryInput);
	}

	void AddLibrary(StringView inputIn)
	{
		var input = inputIn;
		input.Trim();
		let project = Project.Current;
		if (input.IsEmpty)
			return;
		if (input.StartsWith("http://") || input.StartsWith("https://") || input.StartsWith("git@"))
		{
			var name = scope String();
			var trimmed = input;
			if (trimmed.EndsWith(".git"))
				trimmed.RemoveFromEnd(4);
			while (trimmed.EndsWith('/'))
				trimmed.RemoveFromEnd(1);
			Path.GetFileName(trimmed, name);
			let target = scope $"{project.Path}/Libraries/{name}";
			if (name.IsEmpty || Directory.Exists(target))
			{
				mSettingsMessage.Set("A library with that name is already in the Libraries folder.");
				return;
			}
			Directory.CreateDirectory(scope $"{project.Path}/Libraries").IgnoreError();
			let command = scope String("git clone --depth 1 ");
			Terminal.Quote(input, command);
			command.Append(" ");
			Terminal.Quote(target, command);
			command.AppendF(" > {} 2>&1", Terminal.Null);
			if (Terminal.Run(command) != 0 || !File.Exists(scope $"{target}/BeefProj.toml"))
			{
				mSettingsMessage.Set("Download failed, or the repository has no BeefProj.toml at its top level.");
				return;
			}
		}
		else
		{
			if (!File.Exists(scope $"{input}/BeefProj.toml"))
			{
				mSettingsMessage.Set("That folder is not a Beef library (no BeefProj.toml).");
				return;
			}
			project.Libraries.Add(new String(input));
			project.Save();
		}
		mLibraryInput.Clear();
		mSettingsMessage.Set("Library added. Rebuild & Reload to use it in scripts.");
	}
}
