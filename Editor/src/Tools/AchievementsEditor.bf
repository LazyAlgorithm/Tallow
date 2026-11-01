using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Window > Achievements: the project's list of achievements, saved as Achievements.tach in the asset folder.
/// Each row can be unlocked and locked from here to try the game's reaction, on Steam when the editor is
/// connected to it and in the local progress file otherwise.
extension EditorApp
{
	bool mShowAchievements;
	String mAchievementStatus = new .() ~ delete _;
	bool mAchievementsDirty;

	void DrawAchievements()
	{
		if (!mShowAchievements)
			return;
		ImGui.SetNextWindowSize(.(860, 480), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Achievements", &mShowAchievements, ImGui.WindowFlags.NoCollapse))
		{
			let definitions = Achievements.Definitions;
			DrawAchievementSteam(Project.Current);
			DrawAchievementToolbar(definitions);
			DrawAchievementTable(definitions);
			ImGui.TextDisabled("In code: Achievements.Unlock(\"ID\"). On Steam, create each achievement on the Steamworks site with the same ID;");
			ImGui.TextDisabled("Local only always saves on this machine, including with Steam connected. New achievements default to Local only.");
		}
		ImGui.End();
	}

	/// Where they are kept: the Steam App ID, and whether the editor is connected to Steam.
	void DrawAchievementSteam(Project project)
	{
		ImGui.Text("Steam App ID");
		ImGui.SameLine();
		ImGui.SetNextItemWidth(140);
		if (ImGui.InputInt("##appid", ref project.SteamAppId))
		{
			project.SteamAppId = Math.Max(project.SteamAppId, 0);
			Steam.AppId = (uint32)project.SteamAppId;
			project.Save();
		}
		ImGui.SameLine();
		if (project.SteamAppId == 0)
			ImGui.TextDisabled("0: not using Steam. Achievements are kept in a local file and shown with an in-game pop-up.");
		else if (Steam.IsReady)
			ImGui.TextDisabled(scope String()..AppendF("Connected to Steam as {}. Steam entries affect that account; Local only entries stay on this machine.", Steam.UserName).CStr());
		else
		{
			ImGui.TextDisabled("Not connected to Steam; using the local file.");
			ImGui.SameLine();
			if (ImGui.SmallButton("Connect"))
			{
				if (!Steam.Start())
					mAchievementStatus.Set(scope $"Steam: {Steam.Error}");
			}
		}
		ImGui.Separator();
	}

	/// + Add, Save, Import from Steam and Lock All.
	void DrawAchievementToolbar(List<AchievementInfo> definitions)
	{
		if (ImGui.Button("+ Add"))
		{
			let info = new AchievementInfo();
			info.localOnly = true;
			info.id.Set("NEW_ACHIEVEMENT");
			for (int suffix = 2;; suffix++)
			{
				bool taken = false;
				for (let other in definitions)
					taken |= other.id == info.id;
				if (!taken) break;
				info.id..Clear().AppendF("NEW_ACHIEVEMENT_{}", suffix);
			}
			info.name.Set("New achievement");
			definitions.Add(info);
			mAchievementsDirty = true;
		}
		ImGui.SameLine();
		if (ImGui.Button(mAchievementsDirty ? "Save *" : "Save"))
		{
			if (Achievements.SaveDefinitions())
			{
				mAchievementsDirty = false;
				mAchievementStatus.Set(scope $"Saved {definitions.Count} achievement(s) to {Achievements.FileName}.");
				RefreshAssetList();
			}
			else
				mAchievementStatus.Set("Could not write the achievements file.");
		}
		if (Steam.IsReady && Steam.HasStats)
		{
			ImGui.SameLine();
			if (ImGui.Button("Import from Steam"))
				ImportSteamAchievements(definitions);
		}
		ImGui.SameLine();
		if (ImGui.Button("Lock All"))
			ImGui.OpenPopup("LockAllAchievements");
		if (ImGui.BeginPopup("LockAllAchievements"))
		{
			ImGui.Text(Achievements.OnSteam ? "Reset every achievement and stat on this Steam account for this app?" : "Clear the local achievement progress?");
			if (ImGui.Button("Yes, lock all"))
			{
				Achievements.ClearAll();
				mAchievementStatus.Set("All achievements locked.");
				ImGui.CloseCurrentPopup();
			}
			ImGui.SameLine();
			if (ImGui.Button("Cancel"))
				ImGui.CloseCurrentPopup();
			ImGui.EndPopup();
		}
		ImGui.SameLine(0, 14);
		ImGui.TextDisabled(mAchievementStatus.CStr());
	}

	/// The list: each achievement's ID, name, description and flags, a button to lock or unlock it, and one to
	/// remove it.
	void DrawAchievementTable(List<AchievementInfo> definitions)
	{
		AchievementInfo removed = null;
		if (ImGui.BeginTable("achievements", 7, ImGui.TableFlags.RowBg | ImGui.TableFlags.BordersInnerV | ImGui.TableFlags.Resizable | ImGui.TableFlags.ScrollY, .(0, -44)))
		{
			ImGui.TableSetupColumn("ID (used in code and on Steam)", ImGui.ColumnFlags.WidthStretch, 1.1f);
			ImGui.TableSetupColumn("Name", ImGui.ColumnFlags.WidthStretch, 1.0f);
			ImGui.TableSetupColumn("Description", ImGui.ColumnFlags.WidthStretch, 1.8f);
			ImGui.TableSetupColumn("Hidden", ImGui.ColumnFlags.WidthFixed, 56);
			ImGui.TableSetupColumn("Local only", ImGui.ColumnFlags.WidthFixed, 78);
			ImGui.TableSetupColumn("Test", ImGui.ColumnFlags.WidthFixed, 96);
			ImGui.TableSetupColumn("", ImGui.ColumnFlags.WidthFixed, 26);
			ImGui.TableHeadersRow();
			for (int32 i = 0; i < (int32)definitions.Count; i++)
			{
				let info = definitions[i];
				ImGui.PushID(i);
				ImGui.TableNextRow();
				ImGui.TableNextColumn();
				ImGui.SetNextItemWidth(-1);
				if (ImGui.InputText("##id", info.id))
				{
					// Steam's API names are letters, digits and underscores.
					let clean = scope String();
					for (let c in info.id.RawChars)
						clean.Append((c.IsLetterOrDigit || c == '_') ? c : '_');
					info.id.Set(clean);
					mAchievementsDirty = true;
				}
				ImGui.TableNextColumn();
				ImGui.SetNextItemWidth(-1);
				mAchievementsDirty |= ImGui.InputText("##name", info.name);
				ImGui.TableNextColumn();
				ImGui.SetNextItemWidth(-1);
				mAchievementsDirty |= ImGui.InputText("##description", info.description);
				ImGui.TableNextColumn();
				mAchievementsDirty |= ImGui.Checkbox("##hidden", ref info.hidden);
				ImGui.TableNextColumn();
				mAchievementsDirty |= ImGui.Checkbox("##localOnly", ref info.localOnly);
				ImGui.TableNextColumn();
				let unlocked = Achievements.IsUnlocked(info.id);
				if (ImGui.SmallButton(unlocked ? "Lock" : "Unlock"))
				{
					if (unlocked)
						Achievements.Clear(info.id);
					else
						Achievements.Unlock(info.id);
				}
				if (unlocked)
				{
					ImGui.SameLine();
					ImGui.TextDisabled("earned");
				}
				ImGui.TableNextColumn();
				if (ImGui.SmallButton("x"))
					removed = info;
				ImGui.PopID();
			}
			ImGui.EndTable();
		}
		if (removed != null)
		{
			definitions.Remove(removed);
			delete removed;
			mAchievementsDirty = true;
		}
	}

	/// Adds what the app has on Steam and is missing here; existing rows are left alone.
	void ImportSteamAchievements(List<AchievementInfo> definitions)
	{
		int added = 0;
		for (int i < Steam.AchievementCount)
		{
			let id = scope String();
			Steam.GetAchievementId(i, id);
			if (id.IsEmpty || Achievements.Find(id) != null)
				continue;
			let info = new AchievementInfo();
			info.id.Set(id);
			Steam.GetAchievementAttribute(id, "name", info.name);
			Steam.GetAchievementAttribute(id, "desc", info.description);
			let hidden = scope String();
			Steam.GetAchievementAttribute(id, "hidden", hidden);
			info.hidden = hidden == "1";
			definitions.Add(info);
			added++;
		}
		mAchievementsDirty |= added > 0;
		mAchievementStatus.Set(scope $"Imported {added} achievement(s) from Steam.");
	}
}
