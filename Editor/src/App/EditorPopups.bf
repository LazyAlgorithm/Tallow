using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// Popups and keyboard shortcuts.
extension EditorApp
{
	void DrawPopups()
	{
		if (mOpenNewScript)
		{
			ImGui.OpenPopup("New Script");
			mOpenNewScript = false;
		}
		if (ImGui.BeginPopupModal("New Script", null, ImGui.WindowFlags.AlwaysAutoResize))
		{
			ImGui.Text("Class name");
			ImGui.SetNextItemWidth(280);
			ImGui.InputText("##scriptname", mNewScriptName);
			ImGui.TextDisabled("Created in the folder shown in Project. Rebuild & Reload to use it.");
			if (ImGui.Button("Create", .(120, 0)))
			{
				CreateScript(mNewScriptName);
				ImGui.CloseCurrentPopup();
			}
			ImGui.SameLine();
			if (ImGui.Button("Cancel", .(120, 0)))
				ImGui.CloseCurrentPopup();
			ImGui.EndPopup();
		}

		if (mOpenSaveAs)
		{
			mSceneSaveName.Set(mScene.Name);
			ImGui.OpenPopup("Save Scene As");
			mOpenSaveAs = false;
		}
		if (ImGui.BeginPopupModal("Save Scene As", null, ImGui.WindowFlags.AlwaysAutoResize))
		{
			ImGui.Text("Scene name (saved in Assets/Scenes)");
			ImGui.SetNextItemWidth(320);
			ImGui.InputText("##scenename", mSceneSaveName);
			if (ImGui.Button("Save", .(120, 0)) && ProjectGenerator.IsValidName(mSceneSaveName))
			{
				mScene.Name.Set(mSceneSaveName);
				mScene.Path.Clear();
				Directory.CreateDirectory(scope $"{Assets.ProjectPath}/Scenes").IgnoreError();
				mScene.Path.AppendF("{}/Scenes/{}.tscene", Assets.ProjectPath, mSceneSaveName);
				SaveScene();
				ImGui.CloseCurrentPopup();
			}
			ImGui.SameLine();
			if (ImGui.Button("Cancel", .(120, 0)))
				ImGui.CloseCurrentPopup();
			ImGui.EndPopup();
		}
		DrawMapWarningPopup();
	}

	void HandleShortcuts()
	{
		// While the code editor has focus, keys belong to it; only saving is handled here.
		if (mScriptsFocused)
		{
			if (ImGui.IsKeyDown(ImGui.Key.LeftCtrl) && ImGui.IsKeyPressed(ImGui.Key.S) && mActiveScript != null)
				SaveScript(mActiveScript);
			return;
		}
		let typing = (ImGui.tn_imgui_capture_flags() & 4) != 0;
		// A modelling tool that follows the pointer owns the keyboard until it ends (ModelTools.bf).
		if (typing || ModelToolActive)
			return;
		let ctrl = ImGui.IsKeyDown(ImGui.Key.LeftCtrl);
		// While a model is edited, its own keys (ModelCommands.bf) take Delete, Ctrl+D, Ctrl+R, E, R and F.
		let modelling = mModelEditing;
		if (ctrl && ImGui.IsKeyPressed(ImGui.Key.S))
			SaveScene();
		if (ctrl && ImGui.IsKeyPressed(ImGui.Key.P))
			TogglePlay();
		if (ctrl && ImGui.IsKeyPressed(ImGui.Key.R) && !modelling)
			RequestRebuild();
		if (mPlay == .Playing && mGameFocused)
			return;
		if (ctrl && ImGui.IsKeyPressed(ImGui.Key.D) && !modelling)
			DuplicateSelected();
		// While rigging, Ctrl+Z undoes the rig's changes (RigEditor.bf).
		if (ctrl && ImGui.IsKeyPressed(ImGui.Key.Z))
		{
			let redo = ImGui.IsKeyDown(ImGui.Key.LeftShift);
			if (!RigUndo(redo))
			{
				if (redo)
					Redo();
				else
					Undo();
			}
		}
		if (ctrl && ImGui.IsKeyPressed(ImGui.Key.Y) && !RigUndo(true))
			Redo();
		if (ImGui.IsKeyPressed(ImGui.Key.Delete) && !modelling)
			DeleteSelected();
		if (!mFlying)
			HandleViewKeys(ctrl);
		if (!mFlying && !ctrl)
		{
			if (ImGui.IsKeyPressed(ImGui.Key.W))
				mGizmoOperation = 0;
			if (ImGui.IsKeyPressed(ImGui.Key.E) && !modelling)
				mGizmoOperation = 1;
			if (ImGui.IsKeyPressed(ImGui.Key.R) && !modelling)
				mGizmoOperation = 2;
			if (ImGui.IsKeyPressed(ImGui.Key.T))
				mGizmoOperation = 3;
			if (ImGui.IsKeyPressed(ImGui.Key.End) && Selected != null)
				DropToSurface(Selected);
			if (ImGui.IsKeyPressed(ImGui.Key.LeftBracket, true))
				TurnSelected(-mSnapRotate);
			if (ImGui.IsKeyPressed(ImGui.Key.RightBracket, true))
				TurnSelected(mSnapRotate);
			// F frames in the view the pointer is over (a Model View, or else the Scene view).
			if (ImGui.IsKeyPressed(ImGui.Key.F) && !modelling && !FrameKeyModelView())
				FocusSelected();
		}
	}
}
