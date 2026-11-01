using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Inspector for a data asset (.tdata) clicked in the Project panel: its fields, written to the file as they change.
extension EditorApp
{
	DataAsset mEditedData ~ delete _;
	String mEditedDataPath = new .() ~ delete _;

	void DrawDataAssetInspector(StringView fullPath)
	{
		if (mEditedDataPath != fullPath || mEditedData == null)
		{
			DeleteAndNullify!(mEditedData);
			mEditedDataPath.Set(fullPath);
			let text = scope String();
			if (File.ReadAllText(fullPath, text) case .Ok)
			{
				let typeName = scope String();
				for (var line in text.Split('\n'))
				{
					line.Trim();
					if (line.StartsWith("dataasset "))
					{
						typeName.Set(line.Substring(10));
						typeName.Trim();
						break;
					}
				}
				mEditedData = DataAsset.Create(DataAsset.TypeNamed(typeName));
				if (mEditedData != null)
				{
					let relative = scope String();
					Assets.MakeRelative(fullPath, relative);
					mEditedData.[Friend]AssetPath.Set(relative);
					mEditedData.ReadText(text);
				}
				else
				{
					ImGui.TextWrapped(scope $"This data asset is of a class the scripts do not have now: '{typeName}'. Check the class name, or that its scripts compiled.");
					return;
				}
			}
			else
				return;
		}
		let name = scope String();
		Path.GetFileNameWithoutExtension(fullPath, name);
		ImGui.Text(scope $"{name}  ({mEditedData.GetType().GetName(.. scope .())})");
		let relative = scope String(mEditedData.AssetPath);
		ImGui.TextDisabled(relative.CStr());
		ImGui.Spacing();

		let fields = scope List<FieldRef>();
		ComponentRegistry.GetFields(mEditedData, typeof(DataAsset), fields);
		var changed = false;
		if (fields.Count > 0 && BeginPropertyTable("datafields"))
		{
			for (let field in fields)
			{
				if (!field.hidden && field.kind != .ObjectReference)
					changed |= DrawField(field);
			}
			ImGui.EndTable();
		}
		if (changed)
		{
			let text = scope String();
			mEditedData.WriteText(text);
			if (File.WriteAllText(fullPath, text) case .Err)
				Log.Error(scope $"Could not write {fullPath}.");
			// Play mode and scripts read the file again.
			DataAsset.ClearCache();
		}
		ImGui.Spacing();
		ImGui.TextDisabled("Read it from any script with DataAsset.Get<...>().");
		let io = scope SaveIO();
		mEditedData.SaveFields(io);
		if (io.Root.Count > 0)
		{
			ImGui.TextWrapped("Fields marked [Saved] start with these values; each player's own changes are kept in their folder when the game calls Save().");
			if (ImGui.Button("Forget my saved copy"))
			{
				let slot = scope String(relative);
				if (slot.EndsWith(".tdata"))
					slot.RemoveFromEnd(6);
				DataAsset.Storage.Delete(slot);
				Log.Info(scope $"Removed this machine's saved copy of {relative}.");
			}
		}
	}
}
