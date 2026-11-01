using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Map Warning window: when the game has a MapRules.txt (what a scene needs to be one of its maps), saving a
/// scene that lacks something opens it, listing what. Maps themselves are made in the game (its map editor writes
/// .tmap files with MapFiles.Export); the game's own scenes are checked here so that they stay playable as maps.
extension EditorApp
{
	/// What MapRules.txt asks for that the scene lacks, shown in the Map Warning window.
	List<String> mMapRuleProblems = new .() ~ DeleteContainerAndItems!(_);
	bool mOpenMapWarning;
	/// Frames until the --save-scene test switch saves.
	int32 mSaveSceneSwitchFrames;

	/// Fills mMapRuleProblems for the scene as it is now.
	void CheckMapRules()
	{
		ClearAndDeleteItems!(mMapRuleProblems);
		if (!MapRules.Exists)
			return;
		let text = scope String();
		SceneSerializer.Save(mScene, text);
		MapRules.Check(text, mMapRuleProblems);
	}

	/// After a save: opens the Map Warning window if the scene could not be played as a map, unless MapRules.txt
	/// says it is not one.
	void WarnIfNotMap()
	{
		if (!MapRules.Exists || mScene.Path.IsEmpty || MapRules.Ignores(mScene.Path))
			return;
		CheckMapRules();
		if (mMapRuleProblems.Count == 0)
			return;
		for (let problem in mMapRuleProblems)
			Log.Warning(scope $"{mScene.Name} is not ready to be a map: {problem}");
		mOpenMapWarning = true;
	}

	void DrawMapWarningPopup()
	{
		if (mSaveSceneSwitchFrames > 0 && --mSaveSceneSwitchFrames == 0)
			SaveScene();
		if (mOpenMapWarning)
		{
			mOpenMapWarning = false;
			ImGui.OpenPopup("Map Warning");
		}
		if (!ImGui.BeginPopupModal("Map Warning", null, ImGui.WindowFlags.AlwaysAutoResize))
			return;
		ImGui.Text(scope $"The scene is saved, but it cannot be played as a map of {Project.Current.Name} yet:");
		ImGui.Spacing();
		for (let problem in mMapRuleProblems)
			ImGui.BulletText(problem);
		ImGui.Spacing();
		ImGui.TextDisabled(scope $"The game's {MapRules.FileName} sets what a map needs. A map without it is not listed in the game.");
		if (ImGui.Button("OK", .(120, 0)))
			ImGui.CloseCurrentPopup();
		ImGui.SameLine();
		if (ImGui.Button("This scene is not a map", .(200, 0)))
		{
			if (MapRules.Ignore(mScene.Path) case .Ok)
				Log.Info(scope $"{mScene.Name} is no longer checked as a map (ignore line added to {MapRules.FileName}).");
			ImGui.CloseCurrentPopup();
		}
		ImGui.EndPopup();
	}
}
