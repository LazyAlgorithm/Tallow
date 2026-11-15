using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Keeps scenes pointing at their C# scripts when a class is renamed. A C# Script component names its class
/// (scriptType) and the asset ID of the file it is in (scriptAsset, from the file's .tmeta). When the name is no
/// longer compiled, the new one is the class's [FormerlyNamed] match, else the only script left in that file.
/// Reads only the catalogs Tallow.Build writes; never loads the game's assemblies.
static class CSharpScriptIdentity
{
	class Catalog
	{
		public HashSet<String> current = new .() ~ DeleteContainerAndItems!(_);
		public Dictionary<String, String> former = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		/// Absolute source file → the scripts declared in it.
		public Dictionary<String, List<String>> byFile = new .() ~ { for (let entry in _) { delete entry.key; DeleteContainerAndItems!(entry.value); } delete _; };
		public Dictionary<String, String> fileOf = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	}

	static bool Load(StringView projectPath, Catalog catalog)
	{
		let text = scope String();
		if (File.ReadAllText(scope $"{projectPath}/.tallow-csharp/components.tsv", text) case .Err)
			return false;
		for (var line in text.Split('\n', .RemoveEmptyEntries))
		{
			line.Trim();
			if (!line.IsEmpty && !catalog.current.ContainsAlt(line))
				catalog.current.Add(new String(line));
		}
		text.Clear();
		if (File.ReadAllText(scope $"{projectPath}/.tallow-csharp/former-names.tsv", text) case .Ok)
		{
			for (var line in text.Split('\n', .RemoveEmptyEntries))
			{
				line.Trim();
				let tab = line.IndexOf('\t');
				if (tab > 0 && !catalog.former.ContainsKeyAlt(line.Substring(0, tab)))
					catalog.former[new String(line.Substring(0, tab))] = new String(line.Substring(tab + 1));
			}
		}
		text.Clear();
		if (File.ReadAllText(scope $"{projectPath}/.tallow-csharp/component-sources.tsv", text) case .Ok)
		{
			for (var line in text.Split('\n', .RemoveEmptyEntries))
			{
				line.Trim();
				let tab = line.IndexOf('\t');
				if (tab <= 0)
					continue;
				let file = line.Substring(0, tab);
				let name = line.Substring(tab + 1);
				List<String> names;
				if (!catalog.byFile.TryGetValueAlt(file, out names))
				{
					names = new .();
					catalog.byFile[new String(file)] = names;
				}
				names.Add(new String(name));
				if (!catalog.fileOf.ContainsKeyAlt(name))
					catalog.fileOf[new String(name)] = new String(file);
			}
		}
		return true;
	}

	/// The .tmeta ID of the file declaring a compiled script, or false.
	static bool AssetIdOf(Catalog catalog, StringView scriptType, String outId)
	{
		if (!catalog.fileOf.TryGetValueAlt(scriptType, let file))
			return false;
		let relative = scope String();
		return AssetDatabase.ToRelative(file, relative) && AssetDatabase.GetId(relative, outId);
	}

	/// Records the file's asset ID on a component whose script was just chosen (Add Component, a dropped file).
	public static void Stamp(CSharpBehaviour component)
	{
		if (component == null || Project.Current == null)
			return;
		let catalog = scope Catalog();
		if (!Load(Project.Current.Path, catalog))
			return;
		let id = scope String();
		if (AssetIdOf(catalog, component.scriptType, id))
			component.scriptAsset.Set(id);
	}

	/// Renames scripts the scene names by an old name; fills in missing asset IDs. Returns how many were renamed
	/// (the scene then needs saving). Without a compiled catalog it changes nothing.
	public static int Repair(Scene scene, StringView projectPath)
	{
		let catalog = scope Catalog();
		if (scene == null || !Load(projectPath, catalog))
			return 0;
		int renamed = 0;
		let id = scope String();
		let path = scope String();
		for (let component in scene.Components)
		{
			let behaviour = component as CSharpBehaviour;
			if (behaviour == null || behaviour.scriptType.IsEmpty)
				continue;
			let name = (StringView)behaviour.scriptType;
			if (catalog.current.ContainsAlt(name))
			{
				id.Clear();
				if (AssetIdOf(catalog, name, id) && (StringView)behaviour.scriptAsset != id)
					behaviour.scriptAsset.Set(id);
				continue;
			}
			StringView found = default;
			String reason = scope .();
			if (catalog.former.TryGetValueAlt(name, let current) && catalog.current.ContainsAlt(current))
			{
				found = current;
				reason.Set("[FormerlyNamed]");
			}
			else if (!behaviour.scriptAsset.IsEmpty)
			{
				path.Clear();
				if (AssetDatabase.GetPath(behaviour.scriptAsset, path))
				{
					let full = scope $"{Assets.ProjectPath}/{path}";
					if (catalog.byFile.TryGetValueAlt(full, let names) && names.Count == 1)
					{
						found = names[0];
						reason.Set(scope $"the only script in {path}");
					}
				}
			}
			if (found.IsEmpty)
				continue;
			Log.Info(scope $"'{behaviour.GameObject.Name}': script {name} is now {found} ({reason}).");
			behaviour.scriptType.Set(found);
			id.Clear();
			if (AssetIdOf(catalog, found, id))
				behaviour.scriptAsset.Set(id);
			renamed++;
		}
		return renamed;
	}
}
