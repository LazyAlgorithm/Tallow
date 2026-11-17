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
	/// field-docs.tsv: "Class\tField" -> the field's /// summary, the Inspector label's tooltip.
	Dictionary<String, String> mManagedFieldDocs = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
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
		// A doc-comment edit changes only field-docs.tsv (unchanged catalogs are not rewritten).
		if (File.GetLastWriteTimeUtc(scope $"{Project.Current.Path}/.tallow-csharp/field-docs.tsv") case .Ok(let docsTime) &&
			docsTime > modified)
			modified = docsTime;
		if (mManagedFieldCatalogLoaded && catalog == mManagedFieldCatalogPath &&
			modified == mManagedFieldCatalogTime)
			return true;
		mManagedFieldCatalog.Clear();
		if (File.ReadAllText(catalog, mManagedFieldCatalog) case .Err)
		{
			mManagedFieldCatalogLoaded = false;
			return false;
		}
		for (let pair in mManagedFieldDocs)
		{
			delete pair.key;
			delete pair.value;
		}
		mManagedFieldDocs.Clear();
		let docs = scope String();
		if (File.ReadAllText(scope $"{Project.Current.Path}/.tallow-csharp/field-docs.tsv", docs) case .Ok)
		{
			for (var line in docs.Split('\n', .RemoveEmptyEntries))
			{
				line.TrimEnd();
				let second = line.IndexOf('\t');
				let third = second < 0 ? -1 : line.IndexOf('\t', second + 1);
				if (third > 0 && mManagedFieldDocs.TryAdd(new String(line.Substring(0, third)), let key, let value))
					*value = new String(line.Substring(third + 1));
			}
		}
		mManagedFieldCatalogPath.Set(catalog);
		mManagedFieldCatalogTime = modified;
		mManagedFieldCatalogLoaded = true;
		return true;
	}

	/// One C# value's widget (fields.tsv kind; options: an enum's names): true and newValue set when it was edited.
	bool DrawManagedValue(StringView kind, StringView current, StringView options, StringView rangeMin,
		StringView rangeMax, String newValue)
	{
		bool edited = false;
		switch (kind)
		{
		case "float":
			var value = SceneSerializer.ParseFloat(current);
			if (!rangeMin.IsEmpty && !rangeMax.IsEmpty)
				edited = ImGui.SliderFloat("##value", ref value, SceneSerializer.ParseFloat(rangeMin), SceneSerializer.ParseFloat(rangeMax));
			else
				edited = ImGui.DragFloat("##value", ref value, 0.05f);
			if (edited)
				newValue.AppendF("{}", value);
		case "double":
			// Edited at float precision; the text keeps what was typed when untouched.
			double parsed = 0;
			if (double.Parse(current) case .Ok(let d))
				parsed = d;
			var value = (float)parsed;
			edited = ImGui.DragFloat("##value", ref value, 0.05f);
			if (edited)
				newValue.AppendF("{}", value);
		case "int", "uint", "long":
			var value = SceneSerializer.ParseInt(current);
			if (!rangeMin.IsEmpty && !rangeMax.IsEmpty)
				// [Range]: dragging stays inside it.
				edited = ImGui.DragInt("##value", ref value, 0.1f, (int32)SceneSerializer.ParseFloat(rangeMin),
					(int32)SceneSerializer.ParseFloat(rangeMax));
			else
				edited = ImGui.DragInt("##value", ref value, 0.1f);
			if (kind == "uint" && value < 0)
				value = 0;
			if (edited)
				newValue.AppendF("{}", value);
		case "bool":
			var value = StringView.Compare(current, "true", true) == 0 || current == "1";
			edited = ImGui.Checkbox("##value", ref value);
			if (edited)
				newValue.Set(value ? "true" : "false");
		case "string":
			// InputText is deliberately single-line: fieldOverrides stores
			// one name/value per line and cannot represent embedded tabs or
			// newlines until the scene serializer gains an escaped format.
			newValue.Set(current);
			// [Asset(kind)]: a path picked from the project (drop target and browse list).
			if (options.StartsWith("asset:"))
				edited = DrawAssetPicker(newValue, options.Substring("asset:".Length));
			else
				edited = ImGui.InputText("##value", newValue);
		case "enum":
			// The catalog lists exactly the enum constants in source order.
			if (!options.IsEmpty && ImGui.BeginCombo("##value", scope String(current).CStr()))
			{
				for (let option in options.Split('|', .RemoveEmptyEntries))
				{
					if (ImGui.Selectable(scope String(option).CStr(), current == option))
					{
						newValue.Set(option);
						edited = true;
					}
				}
				ImGui.EndCombo();
			}
		case "Vector2", "Vector3", "Vector4", "Color":
			float[4] parts = .(0, 0, 0, 1);
			int count = 0;
			for (let item in current.Split(','))
			{
				if (count < 4)
					parts[count] = SceneSerializer.ParseFloat(item);
				count++;
			}
			switch (kind)
			{
			case "Vector2": edited = count == 2 && ImGui.DragFloat2("##value", &parts[0], 0.05f);
			case "Vector3": edited = count == 3 && ImGui.DragFloat3("##value", ref *(Vector3*)&parts[0], 0.05f);
			case "Vector4": edited = count == 4 && ImGui.DragFloat4("##value", &parts[0], 0.05f);
			default: edited = (count == 3 || count == 4) && ImGui.ColorEdit4("##value", ref *(Color*)&parts[0]);
			}
			if (edited)
			{
				let dimensions = kind == "Vector2" ? 2 : kind == "Vector3" ? 3 : 4;
				for (int i < dimensions)
					newValue.AppendF(i == 0 ? "{}" : ",{}", parts[i]);
			}
		}
		return edited;
	}

	/// A C# list or array field ("count;item;item...", ';' and '\\' escaped with '\\'): its items, each with
	/// DrawManagedValue, with + and - buttons.
	bool DrawManagedList(StringView kind, StringView current, StringView options, String newValue)
	{
		let items = scope List<String>();
		defer { ClearAndDeleteItems!(items); }
		let item = scope String();
		bool first = true;
		for (int i < current.Length)
		{
			let c = current[i];
			if (c == '\\' && i + 1 < current.Length)
				item.Append(current[++i]);
			else if (c == ';')
			{
				if (!first)
					items.Add(new String(item));
				first = false;
				item.Clear();
			}
			else
				item.Append(c);
		}
		if (!first)
			items.Add(new String(item));
		bool edited = false;
		int remove = -1;
		ImGui.TextDisabled(scope $"{items.Count} items");
		for (int i < items.Count)
		{
			ImGui.PushID((int32)i);
			if (ImGui.SmallButton("-"))
				remove = i;
			ImGui.SameLine();
			let changed = scope String();
			if (kind == "record" ? DrawManagedRecord(options, items[i], changed) :
				DrawManagedValue(kind, items[i], options, default, default, changed))
			{
				items[i].Set(changed);
				edited = true;
			}
			ImGui.PopID();
		}
		if (remove >= 0)
		{
			delete items[remove];
			items.RemoveAt(remove);
			edited = true;
		}
		if (ImGui.SmallButton("+"))
		{
			// A copy of the last item, or the kind's zero.
			let added = new String();
			if (!items.IsEmpty)
				added.Set(items.Back);
			else if (kind == "record")
				RecordDefaults(options, added);
			else
				added.Set(kind == "bool" ? "false" : kind == "string" ? "" : kind == "Vector2" ? "0,0" :
					kind == "Vector3" ? "0,0,0" : kind == "Vector4" ? "0,0,0,0" : kind == "Color" ? "1,1,1,1" :
					kind == "enum" ? (options.Split('|').GetNext() case .Ok(let name) ? name : "") : "0");
			items.Add(added);
			edited = true;
		}
		if (edited)
		{
			newValue.AppendF("{}", items.Count);
			for (let text in items)
			{
				newValue.Append(';');
				AppendEscaped(newValue, text);
			}
		}
		return edited;
	}

	/// Splits "a;b\\;c" on unescaped ';' (the list and record item format).
	static void SplitEscaped(StringView text, List<String> parts)
	{
		var part = new String();
		for (int i < text.Length)
		{
			let c = text[i];
			if (c == '\\' && i + 1 < text.Length)
				part.Append(text[++i]);
			else if (c == ';')
			{
				parts.Add(part);
				part = new String();
			}
			else
				part.Append(c);
		}
		parts.Add(part);
	}

	static void AppendEscaped(String output, StringView text)
	{
		for (let c in text.RawChars)
		{
			if (c == ';' || c == '\\')
				output.Append('\\');
			output.Append(c);
		}
	}

	/// A new list:record item: each schema field's default ("Name~kind~default~options" entries joined by '|').
	static void RecordDefaults(StringView schema, String output)
	{
		for (let entry in schema.Split('|', .RemoveEmptyEntries))
		{
			var parts = entry.Split('~');
			let name = parts.GetNext() case .Ok(let n) ? n : "";
			parts.GetNext();
			let value = parts.GetNext() case .Ok(let v) ? v : "";
			if (!output.IsEmpty)
				output.Append(';');
			AppendEscaped(output, scope $"{name}={value}");
		}
	}

	/// One list:record item ("Name=value" parts joined by ';'): a labelled widget per schema field. Fields the
	/// item text lacks show their default; the whole item is written back when one changes.
	bool DrawManagedRecord(StringView schema, StringView current, String newValue)
	{
		let parts = scope List<String>();
		defer { ClearAndDeleteItems!(parts); }
		SplitEscaped(current, parts);
		let names = scope List<StringView>();
		let values = scope List<String>();
		defer { ClearAndDeleteItems!(values); }
		bool edited = false;
		ImGui.BeginGroup();
		for (let entry in schema.Split('|', .RemoveEmptyEntries))
		{
			var columns = entry.Split('~');
			let name = columns.GetNext() case .Ok(let n) ? n : "";
			let kind = columns.GetNext() case .Ok(let k) ? k : "";
			let fallback = columns.GetNext() case .Ok(let d) ? d : "";
			let options = columns.GetNext() case .Ok(let o) ? o : "";
			let value = new String(fallback);
			for (let part in parts)
				if (part.StartsWith(name) && part.Length > name.Length && part[name.Length] == '=')
					value.Set(part.Substring(name.Length + 1));
			names.Add(name);
			values.Add(value);
			ImGui.PushID(scope String(name).CStr());
			let label = scope String();
			NiceName(name, label);
			ImGui.TextDisabled(label.CStr());
			ImGui.SameLine(90);
			ImGui.SetNextItemWidth(-1);
			// Enum names are '/'-separated in the schema (its '|' separates fields).
			let enumNames = scope String(options);
			enumNames.Replace('/', '|');
			let changed = scope String();
			if (DrawManagedValue(kind, value, enumNames, default, default, changed))
			{
				value.Set(changed);
				edited = true;
			}
			ImGui.PopID();
		}
		ImGui.EndGroup();
		if (edited)
		{
			for (int i < names.Count)
			{
				if (i > 0)
					newValue.Append(';');
				AppendEscaped(newValue, scope $"{names[i]}={values[i]}");
			}
		}
		return edited;
	}

	/// The catalog row (columns) of one of a script's fields; false when it has none by that name.
	bool FindManagedField(CSharpBehaviour component, StringView name, List<StringView> columns)
	{
		if (!LoadManagedFieldCatalog())
			return false;
		for (var line in mManagedFieldCatalog.Split('\n', .RemoveEmptyEntries))
		{
			line.TrimEnd();
			columns.Clear();
			for (let part in line.Split('\t'))
				columns.Add(part);
			if (columns.Count >= 4 && columns[0] == (StringView)component.scriptType && columns[1] == name)
				return true;
		}
		return false;
	}

	bool HasManagedField(CSharpBehaviour component, StringView name) => FindManagedField(component, name, scope .());

	/// A field's value as the Inspector shows it: the running script's during Play, else the scene's, else the
	/// default. False when the script has no such field.
	bool ReadManagedField(CSharpBehaviour component, StringView name, String output)
	{
		let columns = scope List<StringView>();
		if (!FindManagedField(component, name, columns))
			return false;
		output.Clear();
		let live = scope String();
		if (component.IsLoaded && CSharpRuntime.ReadFields(component.ManagedInstance, false, live) && FindLiveField(live, name, output))
			return true;
		if (columns[2] == "object")
		{
			// A reference: the name of the object it points at.
			if (let target = component.ReferenceTarget(name))
				output.Set(target.Name);
			return true;
		}
		if (!component.ReadEditorField(name, output))
			output.Set(columns[3]);
		return true;
	}

	/// only: just that field (and a [Serializable] field's own fields under it), for a C# Inspector's Field().
	bool DrawManagedFields(CSharpBehaviour component, StringView only = default)
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
		// The nested group ("Stats", "Stats.Limits") the last row was in: a heading row starts each new one.
		let group = scope String();
		for (var line in data.Split('\n', .RemoveEmptyEntries))
		{
			// fields.tsv has Windows line ends on Windows: the last column (hidden flag, enum names, reference
			// type) must not keep the '\r'.
			line.TrimEnd();
			let columns = scope List<StringView>();
			for (let part in line.Split('\t'))
				columns.Add(part);
			if (columns.Count < 4 || columns[0] != (StringView)component.scriptType)
				continue;
			let name = columns[1];
			if (!only.IsEmpty && name != only && !(name.StartsWith(only) && name.Length > only.Length && name[only.Length] == '.'))
				continue;
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
				if (!BeginPropertyTable(only.IsEmpty ? "managedCSharpFields" : scope $"managedCSharpField_{only}".CStr()))
					return changed;
				tableOpen = true;
			}
			// A [Serializable] struct or class field's own fields are "Outer.Inner": under a heading, indented.
			let dot = name.LastIndexOf('.');
			let rowGroup = dot > 0 ? name.Substring(0, dot) : StringView();
			int depth = 0;
			if (rowGroup != group)
			{
				// Headings for each part of the new group the previous row was not already inside.
				int shared = 0;
				let previousParts = scope List<StringView>(group.Split('.'));
				let parts = scope List<StringView>();
				if (!rowGroup.IsEmpty)
					for (let part in rowGroup.Split('.'))
						parts.Add(part);
				while (shared < parts.Count && shared < previousParts.Count && !group.IsEmpty && parts[shared] == previousParts[shared])
					shared++;
				for (int i = shared; i < parts.Count; i++)
				{
					let heading = scope String();
					heading.Append(' ', i * 3);
					NiceName(parts[i], heading);
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.AlignTextToFramePadding();
					ImGui.TextDisabled(heading.CStr());
					ImGui.TableNextColumn();
				}
				group.Set(rowGroup);
			}
			if (!rowGroup.IsEmpty)
				for (let c in rowGroup.RawChars)
					if (c == '.')
						depth++;
			if (!rowGroup.IsEmpty)
				depth++;
			ImGui.PushID(scope String(name).CStr());
			let label = scope String();
			label.Append(' ', depth * 3);
			NiceName(dot > 0 ? name.Substring(dot + 1) : name, label);
			BeginProperty(label.CStr());
			if (mManagedFieldDocs.TryGetAlt(scope $"{component.scriptType}\t{name}", ?, let documentation)  &&
				ImGui.IsItemHovered()) // The label: BeginProperty's last item.
				ImGui.SetTooltip(documentation.CStr());
			bool edited = false;
			let newValue = scope String();
			let options = columns.Count >= 8 ? columns[7] : StringView();
			let rangeMin = columns.Count >= 6 ? columns[4] : StringView();
			let rangeMax = columns.Count >= 6 ? columns[5] : StringView();
			switch (kind)
			{
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
			default:
				if (kind.StartsWith("list:"))
					edited = DrawManagedList(kind.Substring(5), current, options, newValue);
				else
					edited = DrawManagedValue(kind, current, options, rangeMin, rangeMax, newValue);
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
		if (component.IsLoaded && only.IsEmpty)
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
