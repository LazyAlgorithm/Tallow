using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Inspector for an FBX, OBJ, DAE, STL, PLY, 3DS or .blend file clicked in the Project panel: its import settings
/// (docs/model-import.md). Apply writes them beside the file and converts it again.
extension EditorApp
{
	ModelImportSettings mImportSettings ~ delete _;
	String mImportSettingsPath = new .() ~ delete _;
	List<String> mImportClips = new .() ~ DeleteContainerAndItems!(_);
	HashSet<String> mImportClipsKept = new .() ~ DeleteContainerAndItems!(_);
	bool mImportEdited;

	void LoadImportSettings(StringView fullPath)
	{
		DeleteAndNullify!(mImportSettings);
		mImportSettings = new .();
		mImportSettings.Read(fullPath);
		mImportSettingsPath.Set(fullPath);
		mImportEdited = false;
		ClearAndDeleteItems!(mImportClips);
		ClearAndDeleteItems!(mImportClipsKept);
		ModelImport.ClipNames(Assets.MakeRelative(fullPath, .. scope .()), mImportClips);
		for (let clip in mImportClips)
		{
			if (mImportSettings.clips.IsEmpty || ClipListed(mImportSettings.clips, clip))
				mImportClipsKept.Add(new String(clip));
		}
	}

	static bool ClipListed(StringView list, StringView name)
	{
		let bar = name.LastIndexOf('|');
		let shortName = bar >= 0 ? name.Substring(bar + 1) : name;
		for (let entry in list.Split(','))
		{
			if (entry == name || entry == shortName)
				return true;
		}
		return false;
	}

	void DrawModelImportInspector(StringView fullPath)
	{
		let relative = Assets.MakeRelative(fullPath, .. scope .());
		if (mImportSettings == null || mImportSettingsPath != fullPath)
			LoadImportSettings(fullPath);
		// The clip list is read from the converted copy, which may only now be ready.
		if (mImportClips.IsEmpty && ModelImport.UpToDate(relative) && !mImportEdited)
			LoadImportSettings(fullPath);

		let name = Path.GetFileName(fullPath, .. scope .());
		ImGui.Text(scope $"{name}  (Model)");
		ImGui.TextDisabled(relative.CStr());
		ImGui.Separator();

		let error = ModelImport.Error(relative);
		if (error != null)
			ImGui.TextColored(.(1, 0.45f, 0.4f, 1), scope $"Could not import: {error.Value}");
		else if (!ModelImport.UpToDate(relative))
			ImGui.TextDisabled("Converting...");
		else
			ImGui.TextDisabled("Converted to glTF (used by every Mesh Renderer, Skinned Mesh Renderer and build).");
		ImGui.Dummy(.(0, 4));

		let settings = mImportSettings;
		if (ImGui.DragFloat("Scale", ref settings.scale, 0.01f, 0.0001f, 1000))
			mImportEdited = true;
		if (ImGui.Checkbox("Z axis is up (stand it upright)", ref settings.zUp))
			mImportEdited = true;
		if (ImGui.Checkbox("Materials", ref settings.materials))
			mImportEdited = true;
		if (ImGui.Checkbox("Animations", ref settings.animations))
			mImportEdited = true;
		if (settings.animations && !mImportClips.IsEmpty)
		{
			ImGui.Indent();
			for (let clip in mImportClips)
			{
				var kept = mImportClipsKept.Contains(clip);
				if (ImGui.Checkbox(scope $"{clip}##clip" .CStr(), ref kept))
				{
					if (kept)
						mImportClipsKept.Add(new String(clip));
					else if (mImportClipsKept.GetAndRemoveAlt(clip) case .Ok(let gone))
						delete gone;
					mImportEdited = true;
				}
			}
			ImGui.Unindent();
		}
		ImGui.Dummy(.(0, 4));
		if (!mImportEdited)
			ImGui.BeginDisabled();
		if (ImGui.Button("Apply"))
		{
			settings.clips.Clear();
			// Every clip kept is written as none named (so clips added to the file later come in too).
			if (mImportClipsKept.Count < mImportClips.Count)
			{
				for (let clip in mImportClips)
				{
					if (!mImportClipsKept.Contains(clip))
						continue;
					if (!settings.clips.IsEmpty)
						settings.clips.Append(',');
					settings.clips.Append(clip);
				}
			}
			settings.Write(fullPath);
			mImportEdited = false;
			ModelImport.Request(relative);
		}
		ImGui.SameLine();
		if (ImGui.Button("Revert"))
			LoadImportSettings(fullPath);
		if (!mImportEdited)
			ImGui.EndDisabled();
		ImGui.SameLine();
		if (ImGui.Button("Reimport"))
		{
			// The converter runs again even if the file has not changed.
			let raw = Assets.ConvertedModelCache(relative, .. scope .());
			raw.RemoveFromEnd(4);
			File.Delete(scope $"{raw}.source.glb").IgnoreError();
			ModelImport.Request(relative);
		}
	}
}
