using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Scene text, map rules and project files for C# games (a map editor that saves items as scene text, reads a
/// player's model from their folder, or checks a map against MapRules.txt).
[CSharpExpose]
static class CSharpSavedScenes
{
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// Makes the objects written as scene text, with fresh ids: the first object, 0 when the text is not one.
	[CSharpExpose]
	public static uint64 Instantiate(uint64 session, StringView text)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null || text.IsEmpty)
			return 0;
		let obj = SceneSerializer.Instantiate(scene, text);
		return obj != null ? (uint64)obj.Id : 0;
	}

	/// An object's whole hierarchy as scene text (what a map editor saves an item as), UTF-8 into buffer.
	[CSharpExpose]
	public static int32 SaveObjectTree(uint64 session, uint64 entity, Span<uint8> buffer)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null)
			return -1;
		let text = scope String();
		SceneSerializer.SaveObjectTree(obj, text);
		return Copy(text, buffer);
	}

	/// The objects under a group as scene text, named: a map's contents.
	[CSharpExpose]
	public static int32 SaveGroup(uint64 session, uint64 entity, StringView name, Span<uint8> buffer)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		let scene = CSharpRuntime.PhysicsScene(session);
		if (obj == null || scene == null)
			return -1;
		let text = scope String();
		SceneSerializer.SaveGroup(scene, obj, name, text);
		return Copy(text, buffer);
	}

	/// The problems MapRules.txt finds in scene text, one after another separated by 0x1F (empty: it is a map).
	[CSharpExpose]
	public static int32 MapProblems(StringView sceneText, Span<uint8> buffer)
	{
		let problems = scope List<String>();
		defer
		{
			for (let problem in problems)
				delete problem;
		}
		MapRules.Check(sceneText, problems);
		let text = scope String();
		for (int i < problems.Count)
		{
			if (i > 0)
				text.Append('\x1F');
			text.Append(problems[i]);
		}
		return Copy(text, buffer);
	}

	/// Parses a number a scene or interface file wrote (the engine's own rules).
	[CSharpExpose]
	public static float ParseFloat(StringView text) => SceneSerializer.ParseFloat(text);

	/// Parses a whole number a scene or interface file wrote.
	[CSharpExpose]
	public static int32 ParseInt(StringView text) => SceneSerializer.ParseInt(text);
}

/// Project files a C# game reads and writes (models brought into a map), through the engine's asset packs so it
/// works the same in a built game.
[CSharpExpose]
static class CSharpAssetFiles
{
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// The project's folder; the path memory files are added under.
	[CSharpExpose]
	public static int32 ProjectPath(Span<uint8> buffer) => Copy(Assets.ProjectPath, buffer);

	/// A project path made absolute (a model file under the project or a pack).
	[CSharpExpose]
	public static int32 ResolvePath(StringView path, Span<uint8> buffer)
	{
		let resolved = scope String();
		Assets.ResolvePath(path, resolved);
		return Copy(resolved, buffer);
	}

	/// A file's bytes (-1 when it cannot be read), its length returned even past buffer.
	[CSharpExpose]
	public static int32 ReadFile(StringView path, Span<uint8> buffer)
	{
		let data = scope List<uint8>();
		if (!Assets.ReadBytes(path, data))
			return -1;
		let count = Math.Min(data.Count, buffer.Length);
		for (int i < count)
			buffer[i] = data[i];
		return (int32)data.Count;
	}

	/// Keeps a file in memory under a project path, as a mounted map's own files are: a model brought into a map
	/// is then found when the map is saved.
	[CSharpExpose]
	public static void AddMemoryFile(StringView path, Span<uint8> data) =>
		AssetPack.AddMemoryFile(path, data);

	/// Forgets every memory file under a folder: false when there were none.
	[CSharpExpose]
	public static int32 RemoveMemoryFiles(StringView folder) => (int32)AssetPack.RemoveMemoryFiles(folder);

	/// Makes the asset cache read a file again (after its bytes change).
	[CSharpExpose]
	public static void ForgetAsset(StringView prefix) => Assets.Forget(prefix);

	/// The files in a folder (its sub-folders too), one after another separated by 0x1F: for a map editor's palette.
	[CSharpExpose]
	public static int32 FilesIn(StringView folder, Span<uint8> buffer)
	{
		let files = scope List<String>();
		defer
		{
			for (let file in files)
				delete file;
		}
		AssetPack.FilesIn(folder, files);
		let text = scope String();
		for (int i < files.Count)
		{
			if (i > 0)
				text.Append('\x1F');
			text.Append(files[i]);
		}
		return Copy(text, buffer);
	}
}

/// Named settings kept in the engine's checksummed save format, separate from a save game (a game's volume, control
/// and aircraft settings). Text lines are "key", a tab, a kind ("f" float, "b" bool, "i" whole number, "s" text),
/// a tab and the value.
[CSharpExpose]
static class CSharpSettings
{
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// Saves the settings under a slot name. False when the file could not be written.
	[CSharpExpose]
	public static bool Save(StringView slot, StringView text)
	{
		if (slot.IsEmpty)
			return false;
		let data = scope SaveNode(.Object);
		for (let line in text.Split('\n', .RemoveEmptyEntries))
		{
			let first = line.IndexOf('\t');
			if (first <= 0)
				continue;
			let key = line.Substring(0, first);
			let rest = line.Substring(first + 1);
			let second = rest.IndexOf('\t');
			if (second <= 0)
				continue;
			let kind = rest.Substring(0, second);
			let value = rest.Substring(second + 1);
			switch (kind)
			{
			case "f": data.Set(key, SaveNode.MakeFloat(float.Parse(value) case .Ok(let v) ? v : 0));
			case "b": data.Set(key, SaveNode.MakeBool(value == "1" || value == "true"));
			case "i": data.Set(key, SaveNode.MakeInt(int64.Parse(value) case .Ok(let v) ? v : 0));
			case "s": data.Set(key, SaveNode.MakeString(value));
			}
		}
		let task = scope SaveTask(.Save, slot);
		data.ToBytes(task.data);
		let storage = scope FileSaveStorage();
		storage.Write(task);
		return task.Succeeded;
	}

	/// Reads the settings saved under a slot as the same text Save takes; its length, -1 when there is no such save.
	[CSharpExpose]
	public static int32 Load(StringView slot, Span<uint8> buffer)
	{
		if (slot.IsEmpty)
			return -1;
		let task = scope SaveTask(.Load, slot);
		let storage = scope FileSaveStorage();
		storage.Read(task);
		if (!task.Succeeded || !task.Found)
			return -1;
		let data = SaveNode.FromBytes(task.data);
		if (data == null)
			return -1;
		defer delete data;
		let output = scope String();
		for (int i < data.keys.Count)
		{
			let value = data.items[i];
			switch (value.kind)
			{
			case .Float: output.AppendF("{}\tf\t{}\n", data.keys[i], value.number);
			case .Bool: output.AppendF("{}\tb\t{}\n", data.keys[i], value.integer != 0 ? "1" : "0");
			case .Int: output.AppendF("{}\ti\t{}\n", data.keys[i], value.integer);
			case .String: output.AppendF("{}\ts\t{}\n", data.keys[i], value.text);
			default: break;
			}
		}
		return Copy(output, buffer);
	}
}
