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
	/// A C# data asset being edited: its class and its file's text (read again when another file is clicked).
	String mEditedManagedClass = new .() ~ delete _;
	String mEditedManagedText = new .() ~ delete _;

	/// The C# data asset classes the compiler found (.tallow-csharp/data-assets.tsv); savedOnly: those with [Saved] fields.
	void ManagedDataAssetClasses(List<String> names, bool savedOnly = false)
	{
		if (Project.Current == null)
			return;
		let text = scope String();
		if (File.ReadAllText(scope $"{Project.Current.Path}/.tallow-csharp/data-assets.tsv", text) case .Err)
			return;
		for (var line in text.Split('\n', .RemoveEmptyEntries))
		{
			line.Trim();
			let tab = line.IndexOf('\t');
			let className = tab < 0 ? line : line.Substring(0, tab);
			if (!className.IsEmpty && (!savedOnly || (tab > 0 && line.Substring(tab + 1) == "saved")))
				names.Add(new String(className));
		}
	}

	bool IsManagedDataAssetClass(StringView name, bool savedOnly = false)
	{
		let names = scope List<String>();
		ManagedDataAssetClasses(names, savedOnly);
		defer { ClearAndDeleteItems!(names); }
		for (let entry in names)
			if (entry == name)
				return true;
		return false;
	}

	/// A C# data asset file's value for a field ("field Name\tvalue" lines), or false when it has none.
	static bool ManagedDataValue(StringView text, StringView name, String value)
	{
		for (var line in text.Split('\n'))
		{
			line.TrimEnd();
			if (!line.StartsWith("field "))
				continue;
			let tab = line.IndexOf('\t');
			if (tab > 6 && line.Substring(6, tab - 6) == name)
			{
				value.Set(line.Substring(tab + 1));
				return true;
			}
		}
		return false;
	}

	/// The text of a C# data asset file of this class: each catalog field (not object references), with its value
	/// from old (an earlier file's text) or its default, and edited's value for the field named editedName.
	void ManagedDataText(StringView className, StringView old, StringView editedName, StringView edited, String text)
	{
		text.AppendF("dataasset {}\n", className);
		if (!LoadManagedFieldCatalog())
			return;
		for (var line in mManagedFieldCatalog.Split('\n', .RemoveEmptyEntries))
		{
			line.TrimEnd();
			let columns = scope List<StringView>();
			for (let part in line.Split('\t'))
				columns.Add(part);
			if (columns.Count < 4 || columns[0] != className || columns[2] == "object")
				continue;
			let value = scope String();
			if (!editedName.IsEmpty && columns[1] == editedName)
				value.Set(edited);
			else if (!ManagedDataValue(old, columns[1], value))
				value.Set(columns[3]);
			text.AppendF("field {}\t{}\n", columns[1], value);
		}
	}

	/// The Inspector for a .tdata file of a C# class: the compiler's field rows, written to the file as they change.
	void DrawManagedDataAsset(StringView fullPath)
	{
		let name = scope String();
		Path.GetFileNameWithoutExtension(fullPath, name);
		let shortClass = scope String(mEditedManagedClass);
		let lastDot = shortClass.LastIndexOf('.');
		if (lastDot >= 0)
			shortClass.Remove(0, lastDot + 1);
		ImGui.Text(scope $"{name}  ({shortClass})");
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		ImGui.TextDisabled(relative.CStr());
		ImGui.Spacing();
		if (!LoadManagedFieldCatalog())
		{
			ImGui.TextDisabled("Compile the C# project to edit this data asset.");
			return;
		}
		bool tableOpen = false;
		let editedName = scope String();
		let editedValue = scope String();
		for (var line in mManagedFieldCatalog.Split('\n', .RemoveEmptyEntries))
		{
			line.TrimEnd();
			let columns = scope List<StringView>();
			for (let part in line.Split('\t'))
				columns.Add(part);
			if (columns.Count < 4 || columns[0] != (StringView)mEditedManagedClass || columns[2] == "object" ||
				(columns.Count >= 7 && columns[6] == "1"))
				continue;
			if (!tableOpen)
			{
				if (!BeginPropertyTable("managedDataFields"))
					return;
				tableOpen = true;
			}
			let field = columns[1];
			let kind = columns[2];
			let current = scope String();
			if (!ManagedDataValue(mEditedManagedText, field, current))
				current.Set(columns[3]);
			ImGui.PushID(scope String(field).CStr());
			let label = scope String();
			NiceName(field, label);
			BeginProperty(label.CStr());
			if (mManagedFieldDocs.TryGetAlt(scope $"{mEditedManagedClass}\t{field}", ?, let documentation) && ImGui.IsItemHovered())
				ImGui.SetTooltip(documentation.CStr());
			let newValue = scope String();
			let options = columns.Count >= 8 ? columns[7] : StringView();
			let rangeMin = columns.Count >= 6 ? columns[4] : StringView();
			let rangeMax = columns.Count >= 6 ? columns[5] : StringView();
			bool edited = kind.StartsWith("list:") ? DrawManagedList(kind.Substring(5), current, options, newValue) :
				DrawManagedValue(kind, current, options, rangeMin, rangeMax, newValue);
			if (edited && editedName.IsEmpty)
			{
				editedName.Set(field);
				editedValue.Set(newValue);
			}
			ImGui.PopID();
		}
		if (tableOpen)
			ImGui.EndTable();
		if (!editedName.IsEmpty)
		{
			let text = scope String();
			ManagedDataText(mEditedManagedClass, mEditedManagedText, editedName, editedValue, text);
			if (File.WriteAllText(fullPath, text) case .Err)
				Log.Error(scope $"Could not write {fullPath}.");
			else
				mEditedManagedText.Set(text);
		}
		ImGui.Spacing();
		ImGui.TextDisabled(scope $"Read it from any script with DataAsset.Get<{shortClass}>().");
		if (IsManagedDataAssetClass(mEditedManagedClass, true))
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


	void DrawDataAssetInspector(StringView fullPath)
	{
		if (mEditedDataPath == fullPath && mEditedData == null && !mEditedManagedClass.IsEmpty)
		{
			DrawManagedDataAsset(fullPath);
			return;
		}
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
				mEditedManagedClass.Clear();
				if (mEditedData == null && IsManagedDataAssetClass(typeName))
				{
					mEditedManagedClass.Set(typeName);
					mEditedManagedText.Set(text);
				}
				else if (mEditedData != null)
				{
					let relative = scope String();
					Assets.MakeRelative(fullPath, relative);
					mEditedData.[Friend]AssetPath.Set(relative);
					mEditedData.ReadText(text);
				}
				else if (!mEditedManagedClass.IsEmpty)
				{
					DrawManagedDataAsset(fullPath);
					return;
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
				if (!field.hidden && !field.HoldsReferences)
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
