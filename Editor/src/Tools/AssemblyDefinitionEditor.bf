using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Inspector for an assembly definition (.tasmdef) clicked in the Project panel, laid out like
/// Unity's: the assembly's name and root namespace, the other assemblies it references, what it
/// contains and what depends on it. Edits stay pending until Apply, so a half-typed name never
/// reaches the compiler; the same rules Tallow.Build enforces are checked live.
extension EditorApp
{
	class AssemblyDefinitionFile
	{
		public String path = new .() ~ delete _;
		public String folder = new .() ~ delete _;
		public String name = new .() ~ delete _;
		public String rootNamespace = new .() ~ delete _;
		public List<String> references = new .() ~ DeleteContainerAndItems!(_);
		/// Keys this page does not edit, kept verbatim (raw JSON values) so saving never drops them.
		public List<(String key, String value)> other = new .() ~ { for (let item in _) { delete item.key; delete item.value; } delete _; };
		public bool valid;

		public void CopyFrom(AssemblyDefinitionFile source)
		{
			path.Set(source.path);
			folder.Set(source.folder);
			name.Set(source.name);
			rootNamespace.Set(source.rootNamespace);
			ClearAndDeleteItems!(references);
			for (let reference in source.references)
				references.Add(new .(reference));
			for (let item in other) { delete item.key; delete item.value; }
			other.Clear();
			for (let item in source.other)
				other.Add((new .(item.key), new .(item.value)));
			valid = source.valid;
		}

		public bool SameEdits(AssemblyDefinitionFile other)
		{
			if (name != other.name || rootNamespace != other.rootNamespace || references.Count != other.references.Count)
				return false;
			for (int i < references.Count)
				if (references[i] != other.references[i])
					return false;
			return true;
		}
	}

	AssemblyDefinitionFile mAsmdefSaved ~ delete _;
	AssemblyDefinitionFile mAsmdefEdit ~ delete _;
	DateTime mAsmdefDiskTime;
	List<AssemblyDefinitionFile> mAsmdefProject = new .() ~ DeleteContainerAndItems!(_);
	List<String> mAsmdefScripts = new .() ~ DeleteContainerAndItems!(_);
	System.Diagnostics.Stopwatch mAsmdefScanClock = new .(true) ~ delete _;
	/// The folder scanned for definitions: the project's src, or a scratch folder under --script-files-test.
	String mAsmdefSourceOverride = new .() ~ delete _;

	void AssemblySourceRoot(String output)
	{
		if (!mAsmdefSourceOverride.IsEmpty)
			output.Set(mAsmdefSourceOverride);
		else if (Project.Current != null)
			output.AppendF("{}/src", Project.Current.Path);
	}

	// --- A small JSON reader for the flat .tasmdef object --------------------------------

	static void SkipJsonSpace(StringView text, ref int at)
	{
		while (at < text.Length && (text[at] == ' ' || text[at] == '\t' || text[at] == '\r' || text[at] == '\n'))
			at++;
	}

	/// Reads a JSON string starting at its opening quote, decoding the common escapes.
	static bool ReadJsonString(StringView text, ref int at, String output)
	{
		if (at >= text.Length || text[at] != '"')
			return false;
		at++;
		while (at < text.Length)
		{
			let c = text[at++];
			if (c == '"')
				return true;
			if (c != '\\')
			{
				output.Append(c);
				continue;
			}
			if (at >= text.Length)
				return false;
			let escape = text[at++];
			switch (escape)
			{
			case 'n': output.Append('\n');
			case 't': output.Append('\t');
			case 'r': output.Append('\r');
			case 'b': output.Append('\b');
			case 'f': output.Append('\f');
			case 'u':
				if (at + 4 > text.Length)
					return false;
				if (!(uint32.Parse(text.Substring(at, 4), .HexNumber) case .Ok(let code)))
					return false;
				output.Append((char32)code);
				at += 4;
			default: output.Append(escape);
			}
		}
		return false;
	}

	/// Skips any JSON value, for keys kept verbatim.
	static bool SkipJsonValue(StringView text, ref int at)
	{
		SkipJsonSpace(text, ref at);
		if (at >= text.Length)
			return false;
		let c = text[at];
		if (c == '"')
			return ReadJsonString(text, ref at, scope String());
		if (c == '{' || c == '[')
		{
			let close = c == '{' ? '}' : ']';
			at++;
			SkipJsonSpace(text, ref at);
			if (at < text.Length && text[at] == close)
			{
				at++;
				return true;
			}
			while (at < text.Length)
			{
				if (c == '{')
				{
					SkipJsonSpace(text, ref at);
					if (!ReadJsonString(text, ref at, scope String()))
						return false;
					SkipJsonSpace(text, ref at);
					if (at >= text.Length || text[at++] != ':')
						return false;
				}
				if (!SkipJsonValue(text, ref at))
					return false;
				SkipJsonSpace(text, ref at);
				if (at >= text.Length)
					return false;
				if (text[at] == ',')
				{
					at++;
					continue;
				}
				if (text[at] == close)
				{
					at++;
					return true;
				}
				return false;
			}
			return false;
		}
		let start = at;
		while (at < text.Length && (text[at].IsLetterOrDigit || text[at] == '-' || text[at] == '+' || text[at] == '.'))
			at++;
		return at > start;
	}

	static bool ParseAssemblyDefinition(StringView text, AssemblyDefinitionFile output)
	{
		int at = 0;
		SkipJsonSpace(text, ref at);
		if (at >= text.Length || text[at++] != '{')
			return false;
		SkipJsonSpace(text, ref at);
		if (at < text.Length && text[at] == '}')
			return false; // No name.
		bool hasName = false;
		while (at < text.Length)
		{
			SkipJsonSpace(text, ref at);
			let key = scope String();
			if (!ReadJsonString(text, ref at, key))
				return false;
			SkipJsonSpace(text, ref at);
			if (at >= text.Length || text[at++] != ':')
				return false;
			SkipJsonSpace(text, ref at);
			if (key == "name" || key == "rootNamespace")
			{
				let value = scope String();
				if (!ReadJsonString(text, ref at, value))
					return false;
				(key == "name" ? output.name : output.rootNamespace).Set(value);
				hasName |= key == "name";
			}
			else if (key == "references")
			{
				if (at >= text.Length || text[at++] != '[')
					return false;
				SkipJsonSpace(text, ref at);
				if (at < text.Length && text[at] == ']')
					at++;
				else
				{
					while (true)
					{
						SkipJsonSpace(text, ref at);
						let reference = new String();
						if (!ReadJsonString(text, ref at, reference))
						{
							delete reference;
							return false;
						}
						output.references.Add(reference);
						SkipJsonSpace(text, ref at);
						if (at < text.Length && text[at] == ',')
						{
							at++;
							continue;
						}
						if (at < text.Length && text[at] == ']')
						{
							at++;
							break;
						}
						return false;
					}
				}
			}
			else
			{
				let start = at;
				if (!SkipJsonValue(text, ref at))
					return false;
				output.other.Add((new .(key), new .(text.Substring(start, at - start))));
			}
			SkipJsonSpace(text, ref at);
			if (at < text.Length && text[at] == ',')
			{
				at++;
				continue;
			}
			if (at < text.Length && text[at] == '}')
				return hasName;
			return false;
		}
		return false;
	}

	static void WriteJsonString(StringView value, String output)
	{
		output.Append('"');
		for (let c in value.RawChars)
		{
			switch (c)
			{
			case '"': output.Append("\\\"");
			case '\\': output.Append("\\\\");
			case '\n': output.Append("\\n");
			case '\t': output.Append("\\t");
			case '\r': output.Append("\\r");
			default:
				if ((uint8)c < 0x20)
					output.AppendF("\\u{0:X4}", (int32)c);
				else
					output.Append(c);
			}
		}
		output.Append('"');
	}

	static void WriteAssemblyDefinition(AssemblyDefinitionFile definition, String output)
	{
		output.Append("{\n  \"name\": ");
		WriteJsonString(definition.name, output);
		if (!definition.rootNamespace.IsEmpty)
		{
			output.Append(",\n  \"rootNamespace\": ");
			WriteJsonString(definition.rootNamespace, output);
		}
		output.Append(",\n  \"references\": [");
		for (int i < definition.references.Count)
		{
			output.Append(i == 0 ? "\n    " : ",\n    ");
			WriteJsonString(definition.references[i], output);
		}
		output.Append(definition.references.IsEmpty ? "]" : "\n  ]");
		for (let item in definition.other)
		{
			output.Append(",\n  ");
			WriteJsonString(item.key, output);
			output.AppendF(": {}", item.value);
		}
		output.Append("\n}\n");
	}

	static bool LoadAssemblyDefinition(StringView path, AssemblyDefinitionFile output)
	{
		output.path.Set(path);
		output.folder.Clear();
		Path.GetDirectoryPath(path, output.folder).IgnoreError();
		let text = scope String();
		if (File.ReadAllText(path, text, true) case .Err)
			return false;
		output.valid = ParseAssemblyDefinition(text, output);
		return output.valid;
	}

	// --- Project scan and the rules Tallow.Build applies ---------------------------------

	static bool ValidAssemblyName(StringView name)
	{
		if (name.IsEmpty || name == "Tallow.Game" || name == "Tallow.API")
			return false;
		if (!name[0].IsLetter && name[0] != '_')
			return false;
		for (let c in name.RawChars)
			if (!c.IsLetterOrDigit && c != '_' && c != '.')
				return false;
		return true;
	}

	static bool ValidNamespace(StringView text)
	{
		if (text.IsEmpty)
			return true; // Defaults to the assembly name.
		for (let part in text.Split('.'))
		{
			if (part.IsEmpty || (!part[0].IsLetter && part[0] != '_'))
				return false;
			for (let c in part.RawChars)
				if (!c.IsLetterOrDigit && c != '_')
					return false;
		}
		return true;
	}

	void FindAssemblyDefinitions(StringView folder, int depth)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let path = entry.GetFilePath(.. scope .());
			if (!path.EndsWith(".tasmdef"))
				continue;
			let definition = new AssemblyDefinitionFile();
			LoadAssemblyDefinition(path, definition);
			mAsmdefProject.Add(definition);
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (!name.StartsWith('.'))
				FindAssemblyDefinitions(entry.GetFilePath(.. scope .()), depth + 1);
		}
	}

	static bool InFolder(StringView path, StringView folder) =>
		path.Length > folder.Length && path.StartsWith(folder) && (path[folder.Length] == '/' || path[folder.Length] == '\\');

	/// The .cs files this assembly compiles: under its folder, except where a nested definition takes over.
	void FindAssemblyScripts(StringView folder, int depth, bool top)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return;
		if (!top)
		{
			for (let entry in Directory.EnumerateFiles(folder))
				if (entry.GetFileName(.. scope .()).EndsWith(".tasmdef"))
					return;
		}
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let path = entry.GetFilePath(.. scope .());
			if (path.EndsWith(".cs"))
				mAsmdefScripts.Add(new .(path));
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (!name.StartsWith('.'))
				FindAssemblyScripts(entry.GetFilePath(.. scope .()), depth + 1, false);
		}
	}

	void ScanAssemblyDefinitions()
	{
		ClearAndDeleteItems!(mAsmdefProject);
		ClearAndDeleteItems!(mAsmdefScripts);
		let source = scope String();
		AssemblySourceRoot(source);
		if (!source.IsEmpty)
			FindAssemblyDefinitions(source, 0);
		if (mAsmdefEdit != null)
		{
			FindAssemblyScripts(mAsmdefEdit.folder, 0, true);
			mAsmdefScripts.Sort(scope (a, b) => a.CompareTo(b));
		}
		mAsmdefScanClock.Restart();
	}

	AssemblyDefinitionFile ProjectAssembly(StringView name)
	{
		for (let definition in mAsmdefProject)
			if (definition.valid && definition.name == name && !Path.Equals(definition.path, mAsmdefEdit.path, .Lenient))
				return definition;
		return null;
	}

	/// Whether following references from `name` reaches the edited assembly again.
	bool ReachesEdited(StringView name, HashSet<String> seen)
	{
		if (name == mAsmdefEdit.name)
			return true;
		let definition = ProjectAssembly(name);
		if (definition == null)
			return false;
		if (seen.Contains(definition.name))
			return false;
		seen.Add(definition.name);
		for (let reference in definition.references)
			if (ReachesEdited(reference, seen))
				return true;
		return false;
	}

	/// The problems Tallow.Build would refuse this definition for.
	void AssemblyDefinitionProblems(List<String> problems)
	{
		let edit = mAsmdefEdit;
		if (!ValidAssemblyName(edit.name))
			problems.Add(new $"'{edit.name}' is not a valid assembly name: start with a letter, then letters, digits, '_' or '.'. Tallow.Game and Tallow.API are reserved.");
		else if (ProjectAssembly(edit.name) != null)
			problems.Add(new $"Another assembly definition is already named {edit.name}.");
		if (!ValidNamespace(edit.rootNamespace))
			problems.Add(new $"'{edit.rootNamespace}' is not a valid namespace.");
		for (let definition in mAsmdefProject)
		{
			if (!Path.Equals(definition.path, edit.path, .Lenient) && Path.Equals(definition.folder, edit.folder, .Lenient))
				problems.Add(new $"{Path.GetFileName(definition.path, .. scope .())} is in the same folder; each folder has at most one assembly definition.");
		}
		let unique = scope HashSet<String>();
		for (let reference in edit.references)
		{
			if (reference == edit.name)
				problems.Add(new $"{edit.name} cannot reference itself.");
			else if (ProjectAssembly(reference) == null)
				problems.Add(new $"There is no assembly named {reference} in this project.");
			else if (ReachesEdited(reference, scope .()))
				problems.Add(new $"Referencing {reference} makes a cycle: it already depends on {edit.name}.");
			if (!unique.Add(reference))
				problems.Add(new $"{reference} is listed twice.");
		}
	}

	void OpenAssemblyDefinition(StringView path)
	{
		if (mAsmdefEdit != null && mAsmdefSaved != null && !mAsmdefEdit.SameEdits(mAsmdefSaved))
			Log.Warning(scope $"Unapplied changes to {Path.GetFileName(mAsmdefSaved.path, .. scope .())} were discarded.");
		DeleteAndNullify!(mAsmdefSaved);
		DeleteAndNullify!(mAsmdefEdit);
		mAsmdefSaved = new .();
		LoadAssemblyDefinition(path, mAsmdefSaved);
		mAsmdefEdit = new .();
		mAsmdefEdit.CopyFrom(mAsmdefSaved);
		if (File.GetLastWriteTimeUtc(path) case .Ok(let time))
			mAsmdefDiskTime = time;
		ScanAssemblyDefinitions();
	}

	/// Writes the edits. A rename also updates every other definition that referenced the old name,
	/// as Unity's GUID references would keep them pointing at this assembly.
	bool ApplyAssemblyDefinition()
	{
		let oldName = scope String(mAsmdefSaved.name);
		let text = scope String();
		WriteAssemblyDefinition(mAsmdefEdit, text);
		if (File.WriteAllText(mAsmdefEdit.path, text) case .Err)
		{
			Log.Error(scope $"Could not write {mAsmdefEdit.path}.");
			return false;
		}
		if (mAsmdefSaved.valid && oldName != mAsmdefEdit.name)
		{
			for (let definition in mAsmdefProject)
			{
				if (!definition.valid || Path.Equals(definition.path, mAsmdefEdit.path, .Lenient))
					continue;
				bool changed = false;
				for (let reference in definition.references)
				{
					if (reference == oldName)
					{
						reference.Set(mAsmdefEdit.name);
						changed = true;
					}
				}
				if (!changed)
					continue;
				let other = scope String();
				WriteAssemblyDefinition(definition, other);
				if (File.WriteAllText(definition.path, other) case .Ok)
					Log.Info(scope $"{definition.name} now references {mAsmdefEdit.name} (was {oldName}).");
			}
		}
		mAsmdefSaved.CopyFrom(mAsmdefEdit);
		mAsmdefSaved.valid = true;
		if (File.GetLastWriteTimeUtc(mAsmdefEdit.path) case .Ok(let time))
			mAsmdefDiskTime = time;
		ScanAssemblyDefinitions();
		Log.Info(scope $"Saved {Path.GetFileName(mAsmdefEdit.path, .. scope .())}; the C# scripts recompile.");
		return true;
	}

	/// The namespace a new script in `folder` starts with: the owning assembly's root namespace,
	/// or its name, or the project name outside any assembly definition.
	public void ScriptNamespaceFor(StringView folder, String output)
	{
		output.Set(Project.Current != null ? Project.Current.Name : "Game");
		let source = scope String();
		AssemblySourceRoot(source);
		if (source.IsEmpty)
			return;
		let current = scope String(folder);
		for (int depth < 64)
		{
			if (Directory.Exists(current))
			{
				for (let entry in Directory.EnumerateFiles(current))
				{
					let path = entry.GetFilePath(.. scope .());
					if (!path.EndsWith(".tasmdef"))
						continue;
					let definition = scope AssemblyDefinitionFile();
					if (LoadAssemblyDefinition(path, definition) && ValidAssemblyName(definition.name))
					{
						output.Set(definition.rootNamespace.IsEmpty ? definition.name : definition.rootNamespace);
						return;
					}
				}
			}
			if (Path.Equals(current, source, .Lenient) || !InFolder(current, source))
				return;
			let parent = scope String();
			if (Path.GetDirectoryPath(current, parent) case .Err || parent.IsEmpty || parent == current)
				return;
			current.Set(parent);
		}
	}

	// --- The Inspector page ---------------------------------------------------------------

	void DrawAssemblyDefinitionInspector(StringView fullPath)
	{
		if (mAsmdefEdit == null || !Path.Equals(mAsmdefEdit.path, fullPath, .Lenient))
			OpenAssemblyDefinition(fullPath);
		let dirty = !mAsmdefEdit.SameEdits(mAsmdefSaved);
		// Another program (or the code editor) changed the file: follow it unless there are edits here.
		if (mAsmdefScanClock.ElapsedMilliseconds > 1000)
		{
			if (File.GetLastWriteTimeUtc(fullPath) case .Ok(let time) && time != mAsmdefDiskTime && !dirty)
			{
				let path = scope String(fullPath);
				DeleteAndNullify!(mAsmdefEdit);
				OpenAssemblyDefinition(path);
			}
			else
				ScanAssemblyDefinitions();
		}

		let fileName = scope String();
		Path.GetFileNameWithoutExtension(fullPath, fileName);
		ImGui.Text(scope $"{fileName}  (Assembly Definition)");
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		ImGui.TextDisabled(relative.CStr());
		if (!mAsmdefSaved.valid)
		{
			ImGui.TextColored(.(1.0f, 0.45f, 0.4f, 1), "This file is not a valid assembly definition. Fix it in the code editor, or Apply to rewrite it from the fields below.");
		}
		ImGui.Separator();

		ImGui.AlignTextToFramePadding();
		ImGui.Text("Name");
		ImGui.SameLine(130);
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##asmname", mAsmdefEdit.name);
		ImGui.AlignTextToFramePadding();
		ImGui.Text("Root Namespace");
		ImGui.SameLine(130);
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##asmnamespace", mAsmdefEdit.rootNamespace);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The namespace new scripts in this assembly start with. Empty uses the assembly name.");

		ImGui.Dummy(.(0, 4));
		if (ImGui.CollapsingHeader("Assembly Definition References", ImGui.TreeFlags.DefaultOpen))
		{
			int removeAt = -1;
			for (int i < mAsmdefEdit.references.Count)
			{
				let reference = mAsmdefEdit.references[i];
				ImGui.PushID((int32)i);
				if (ImGui.SmallButton("x"))
					removeAt = i;
				ImGui.SameLine();
				let target = ProjectAssembly(reference);
				if (target == null)
					ImGui.TextColored(.(1.0f, 0.45f, 0.4f, 1), scope $"{reference}  (missing)");
				else
				{
					ImGui.Text(reference);
					if (ImGui.IsItemHovered())
						ImGui.SetTooltip(target.path.CStr());
					if (ImGui.IsItemClicked(0))
					{
						mSelectedAsset.Set(target.path);
						mInspectAsset = true;
					}
				}
				ImGui.PopID();
			}
			if (removeAt >= 0)
			{
				delete mAsmdefEdit.references[removeAt];
				mAsmdefEdit.references.RemoveAt(removeAt);
			}
			if (mAsmdefEdit.references.IsEmpty)
				ImGui.TextDisabled("None. Scripts here can use Tallow.API and their own types.");
			ImGui.SetNextItemWidth(-1);
			if (ImGui.BeginCombo("##asmaddreference", "Add reference..."))
			{
				bool any = false;
				for (let definition in mAsmdefProject)
				{
					if (!definition.valid || Path.Equals(definition.path, mAsmdefEdit.path, .Lenient) ||
						mAsmdefEdit.references.Contains(definition.name))
						continue;
					any = true;
					let cycles = ReachesEdited(definition.name, scope .());
					ImGui.BeginDisabled(cycles);
					if (ImGui.Selectable(scope $"{definition.name}{cycles ? "  (depends on this one)" : ""}".CStr()))
						mAsmdefEdit.references.Add(new .(definition.name));
					ImGui.EndDisabled();
				}
				if (!any)
					ImGui.TextDisabled("No other assembly definitions to reference.");
				ImGui.EndCombo();
			}
		}

		let problems = scope List<String>();
		defer { ClearAndDeleteItems!(problems); }
		AssemblyDefinitionProblems(problems);
		if (!problems.IsEmpty)
		{
			ImGui.Dummy(.(0, 4));
			for (let problem in problems)
				ImGui.TextColored(.(1.0f, 0.45f, 0.4f, 1), problem.CStr());
		}

		ImGui.Dummy(.(0, 4));
		ImGui.BeginDisabled(!dirty && mAsmdefSaved.valid);
		ImGui.BeginDisabled(!problems.IsEmpty);
		if (ImGui.Button("Apply"))
			ApplyAssemblyDefinition();
		ImGui.EndDisabled();
		ImGui.SameLine();
		if (ImGui.Button("Revert"))
			mAsmdefEdit.CopyFrom(mAsmdefSaved);
		ImGui.EndDisabled();
		ImGui.SameLine();
		if (ImGui.Button("Open in Code Editor"))
			OpenScript(fullPath);

		ImGui.Dummy(.(0, 6));
		if (ImGui.CollapsingHeader(scope $"Scripts ({mAsmdefScripts.Count})###asmscripts".CStr()))
		{
			if (mAsmdefScripts.IsEmpty)
				ImGui.TextDisabled("No C# scripts in this folder yet.");
			for (let script in mAsmdefScripts)
			{
				let shown = scope String();
				if (InFolder(script, mAsmdefEdit.folder))
					shown.Append(script.Substring(mAsmdefEdit.folder.Length + 1));
				else
					shown.Append(script);
				if (ImGui.Selectable(shown.CStr()))
					OpenScript(script);
			}
		}
		if (ImGui.CollapsingHeader("Referenced By###asmreferencedby"))
		{
			bool any = false;
			for (let definition in mAsmdefProject)
			{
				if (!definition.valid || !definition.references.Contains(mAsmdefSaved.name) ||
					Path.Equals(definition.path, mAsmdefEdit.path, .Lenient))
					continue;
				any = true;
				if (ImGui.Selectable(definition.name.CStr()))
				{
					mSelectedAsset.Set(definition.path);
					mInspectAsset = true;
				}
			}
			ImGui.TextDisabled(any ? "and Tallow.Game, which references every assembly." : "Tallow.Game only (it references every assembly).");
		}
	}
}
