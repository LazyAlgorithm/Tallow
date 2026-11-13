using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Draw public C# values without instantiating the managed game in Edit mode.
/// The trusted Roslyn build writes the field manifest; overrides live in the
/// native scene component and use the normal scene and prefab serializer.
extension EditorApp
{
	bool DrawManagedFields(CSharpBehaviour component)
	{
		let catalog = scope $"{Project.Current.Path}/.tallow-csharp/fields.tsv";
		let data = scope String();
		if (File.ReadAllText(catalog, data) case .Err)
		{
			ImGui.TextDisabled("Compile the C# project to inspect public fields.");
			return false;
		}
		bool changed = false;
		bool tableOpen = false;
		for (let line in data.Split('\n', .RemoveEmptyEntries))
		{
			let columns = scope List<StringView>();
			for (let part in line.Split('\t'))
				columns.Add(part);
			if (columns.Count < 4 || columns[0] != (StringView)component.scriptType)
				continue;
			let name = columns[1];
			let kind = columns[2];
			let current = scope String();
			if (!component.ReadEditorField(name, current))
				current.Set(columns[3]);
			if (!tableOpen)
			{
				if (!BeginPropertyTable("managedCSharpFields"))
					return changed;
				tableOpen = true;
			}
			ImGui.PushID(scope String(name).CStr());
			let label = scope String();
			NiceName(name, label);
			BeginProperty(label.CStr());
			bool edited = false;
			let newValue = scope String();
			switch (kind)
			{
			case "float":
				var value = SceneSerializer.ParseFloat(current);
				if (columns.Count >= 6 && !columns[4].IsEmpty && !columns[5].IsEmpty)
					edited = ImGui.SliderFloat("##value", ref value,
						SceneSerializer.ParseFloat(columns[4]), SceneSerializer.ParseFloat(columns[5]));
				else
					edited = ImGui.DragFloat("##value", ref value, 0.05f);
				if (edited)
					newValue.AppendF("{}", value);
			case "int":
				var value = SceneSerializer.ParseInt(current);
				edited = ImGui.DragInt("##value", ref value, 0.1f);
				if (edited)
					newValue.AppendF("{}", value);
			case "bool":
				var value = current == "true" || current == "1";
				edited = ImGui.Checkbox("##value", ref value);
				if (edited)
					newValue.Set(value ? "true" : "false");
			case "Vector2", "Vector3", "Vector4":
				let parts = scope List<StringView>();
				for (let item in StringView(current).Split(','))
					parts.Add(item);
				if (kind == "Vector2" && parts.Count == 2)
				{
					Vector2 value = .(SceneSerializer.ParseFloat(parts[0]), SceneSerializer.ParseFloat(parts[1]));
					edited = ImGui.DragFloat2("##value", &value.x, 0.05f);
					if (edited)
						newValue.AppendF("{},{}", value.x, value.y);
				}
				else if (kind == "Vector3" && parts.Count == 3)
				{
					Vector3 value = .(SceneSerializer.ParseFloat(parts[0]), SceneSerializer.ParseFloat(parts[1]), SceneSerializer.ParseFloat(parts[2]));
					edited = ImGui.DragFloat3("##value", ref value, 0.05f);
					if (edited)
						newValue.AppendF("{},{},{}", value.x, value.y, value.z);
				}
				else if (kind == "Vector4" && parts.Count == 4)
				{
					Vector4 value = .(SceneSerializer.ParseFloat(parts[0]), SceneSerializer.ParseFloat(parts[1]), SceneSerializer.ParseFloat(parts[2]), SceneSerializer.ParseFloat(parts[3]));
					edited = ImGui.DragFloat4("##value", &value.x, 0.05f);
					if (edited)
						newValue.AppendF("{},{},{},{}", value.x, value.y, value.z, value.w);
				}
			}
			if (edited)
			{
				component.WriteEditorField(name, newValue);
				changed = true;
			}
			ImGui.PopID();
		}
		if (tableOpen)
			ImGui.EndTable();
		return changed;
	}
}
