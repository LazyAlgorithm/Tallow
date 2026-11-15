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
	/// The compiler's field catalog, re-read only when the file changes. The
	/// Inspector draws every frame; the catalog changes once per compile.
	String mManagedFieldCatalog = new .() ~ delete _;
	String mManagedFieldCatalogPath = new .() ~ delete _;
	DateTime mManagedFieldCatalogTime;
	bool mManagedFieldCatalogLoaded;
	System.Diagnostics.Stopwatch mManagedFieldCatalogClock = new .(true) ~ delete _;

	bool LoadManagedFieldCatalog()
	{
		let catalog = scope $"{Project.Current.Path}/.tallow-csharp/fields.tsv";
		if (mManagedFieldCatalogLoaded && catalog == mManagedFieldCatalogPath &&
			mManagedFieldCatalogClock.ElapsedMilliseconds < 250)
			return true;
		mManagedFieldCatalogClock.Restart();
		DateTime modified;
		switch (File.GetLastWriteTimeUtc(catalog))
		{
		case .Ok(let value):
			modified = value;
		case .Err:
			mManagedFieldCatalogLoaded = false;
			return false;
		}
		if (mManagedFieldCatalogLoaded && catalog == mManagedFieldCatalogPath &&
			modified == mManagedFieldCatalogTime)
			return true;
		mManagedFieldCatalog.Clear();
		if (File.ReadAllText(catalog, mManagedFieldCatalog) case .Err)
		{
			mManagedFieldCatalogLoaded = false;
			return false;
		}
		mManagedFieldCatalogPath.Set(catalog);
		mManagedFieldCatalogTime = modified;
		mManagedFieldCatalogLoaded = true;
		return true;
	}

	bool DrawManagedFields(CSharpBehaviour component)
	{
		if (!LoadManagedFieldCatalog())
		{
			ImGui.TextDisabled("Compile the C# project to inspect public fields.");
			return false;
		}
		let data = mManagedFieldCatalog;
		bool changed = false;
		bool tableOpen = false;
		// During Play the widgets show the running script's values (edits still go to it, as before).
		let live = scope String();
		let playing = component.IsLoaded && CSharpRuntime.ReadFields(component.ManagedInstance, false, live);
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
			if (playing && FindLiveField(live, name, current))
			{
			}
			else if (!component.ReadEditorField(name, current))
			{
				current.Set(columns[3]);
				// Snapshot hidden serialized defaults into the native
				// scene/prefab fieldOverrides once. They are persisted without
				// drawing a visible Inspector widget, and later default
				// initializer changes do not silently overwrite saved values.
				// Never during Play: writing the default would also reset the running script's value.
				if (columns.Count >= 7 && columns[6] == "1" && !component.IsLoaded && kind != "object")
				{
					if (component.WriteEditorField(name, current))
						changed = true;
				}
			}
			if (columns.Count >= 7 && columns[6] == "1")
				continue;
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
				var value = current.Equals("true", .OrdinalIgnoreCase) || current == "1";
				edited = ImGui.Checkbox("##value", ref value);
				if (edited)
					newValue.Set(value ? "true" : "false");
			case "string":
				// InputText is deliberately single-line: fieldOverrides stores
				// one name/value per line and cannot represent embedded tabs or
				// newlines until the scene serializer gains an escaped format.
				newValue.Set(current);
				edited = ImGui.InputText("##value", newValue);
			case "enum":
				// The catalog lists exactly the enum constants in source order.
				if (columns.Count >= 8 && ImGui.BeginCombo("##value", current.CStr()))
				{
					for (let option in columns[7].Split('|', .RemoveEmptyEntries))
					{
						if (ImGui.Selectable(scope String(option).CStr(), current == option))
						{
							newValue.Set(option);
							edited = true;
						}
					}
					ImGui.EndCombo();
				}
			case "object":
				// Kept in the component's reference list, not in fieldOverrides (see CSharpBehaviour.SetReference).
				GameObject target = component.ReferenceTarget(name);
				if (playing && current.StartsWith('#'))
					target = mScene.FindById((uint32)SceneSerializer.ParseInt(current.Substring(1)));
				let descriptor = columns.Count >= 8 ? columns[7] : StringView("GameObject");
				if (DrawManagedReference(descriptor, target, var picked))
				{
					if (component.SetReference(name, picked))
						changed = true;
				}
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
				if (component.WriteEditorField(name, newValue))
					changed = true;
			}
			ImGui.PopID();
		}
		if (tableOpen)
			ImGui.EndTable();
		if (component.IsLoaded)
			DrawManagedDebugFields(component);
		return changed;
	}

	/// Whether an object fits a C# reference field: "GameObject"/"Transform" take any; "native:Tallow.Light" one
	/// with that built-in component; "script:Ns.Class" one with that C# script (or any C# script, when the class
	/// might be a base class the catalog cannot see through).
	static bool FitsManagedReference(GameObject go, StringView descriptor)
	{
		if (descriptor == "GameObject" || descriptor == "Transform")
			return true;
		if (descriptor.StartsWith("native:"))
		{
			let typeName = descriptor.Substring("native:".Length);
			if (let handle = HandleComponents.Find(typeName))
				return go.Scene != null && go.Scene.World.Has(go.Entity, handle.index);
			let info = ComponentRegistry.Find(typeName);
			if (info == null)
				return false;
			for (let component in go.Components)
				if (component.GetType() == info.type)
					return true;
			return false;
		}
		if (descriptor.StartsWith("script:"))
		{
			let className = descriptor.Substring("script:".Length);
			for (let component in go.Components)
			{
				if (let script = component as CSharpBehaviour)
				{
					if (script.scriptType == className)
						return true;
				}
			}
		}
		return false;
	}

	/// An object slot for a C# reference field: shows the object's name, takes an object dragged from the
	/// Hierarchy, and "..." lists the objects that fit. True when the choice changed (picked null clears it).
	bool DrawManagedReference(StringView descriptor, GameObject current, out GameObject picked)
	{
		picked = null;
		bool changed = false;
		ImGui.SetNextItemWidth(-28);
		let shown = scope String();
		if (current == null)
			shown.Append("None");
		else
		{
			shown.Append(current.Name);
			if (!FitsManagedReference(current, descriptor))
				shown.Append(" (missing component)");
		}
		ImGui.InputText("##v", shown, ImGui.InputFlags.ReadOnly);
		if (ImGui.BeginDragDropTarget())
		{
			let payload = ImGui.AcceptDragDropPayload("GAMEOBJECT");
			if (payload != null && payload.dataSize == sizeof(uint32))
			{
				let go = mScene.FindById(*(uint32*)payload.data);
				if (go != null)
				{
					picked = go;
					changed = true;
				}
			}
			ImGui.EndDragDropTarget();
		}
		ImGui.SameLine();
		if (ImGui.Button("..."))
			ImGui.OpenPopup("ManagedObjectPicker");
		if (ImGui.BeginPopup("ManagedObjectPicker"))
		{
			if (ImGui.Selectable("None", current == null))
			{
				picked = null;
				changed = true;
			}
			for (let go in mScene.Objects)
			{
				if (go.IsDestroyed || go.Transient || !FitsManagedReference(go, descriptor))
					continue;
				ImGui.PushID((int32)go.Id);
				if (ImGui.Selectable(go.Name.CStr(), current == go))
				{
					picked = go;
					changed = true;
				}
				ImGui.PopID();
			}
			ImGui.EndPopup();
		}
		return changed;
	}

	static bool FindLiveField(StringView live, StringView name, String output)
	{
		for (let line in live.Split('\n', .RemoveEmptyEntries))
		{
			let separator = line.IndexOf('\t');
			if (separator > 0 && line.Substring(0, separator) == name)
			{
				output.Set(line.Substring(separator + 1));
				return true;
			}
		}
		return false;
	}

	/// Every field of the running script, private ones and collections included, read-only and refreshed each
	/// frame: watching gameplay state without stopping the game at a breakpoint.
	void DrawManagedDebugFields(CSharpBehaviour component)
	{
		if (!ImGui.CollapsingHeader("Debug: all fields (live)###csharpdebugfields"))
			return;
		let all = scope String();
		if (!CSharpRuntime.ReadFields(component.ManagedInstance, true, all))
		{
			ImGui.TextDisabled("The script's fields could not be read.");
			return;
		}
		if (all.IsEmpty)
		{
			ImGui.TextDisabled("This script has no fields.");
			return;
		}
		if (!ImGui.BeginTable("csharpdebugfields", 3, ImGui.TableFlags.RowBg | ImGui.TableFlags.Resizable))
			return;
		ImGui.TableSetupColumn("Field");
		ImGui.TableSetupColumn("Type");
		ImGui.TableSetupColumn("Value");
		for (let line in all.Split('\n', .RemoveEmptyEntries))
		{
			var parts = line.Split('\t');
			let name = parts.GetNext() case .Ok(let a) ? a : "";
			let type = parts.GetNext() case .Ok(let b) ? b : "";
			let value = parts.GetNext() case .Ok(let c) ? c : "";
			ImGui.TableNextRow();
			ImGui.TableNextColumn();
			ImGui.Text(name);
			ImGui.TableNextColumn();
			ImGui.TextDisabled(scope String(type).CStr());
			ImGui.TableNextColumn();
			ImGui.Text(value);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip(scope String(value).CStr());
		}
		ImGui.EndTable();
	}
}
