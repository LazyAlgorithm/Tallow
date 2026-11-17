using System;
using System.Collections;

namespace Tallow;

/// Data assets of C# classes (DataAsset in Tallow.API): their .tdata files, which class each is, and the player's
/// copies of their [Saved] fields (kept through DataAsset.Storage, as the Beef ones are).
[CSharpExpose]
static class CSharpDataAssets
{
	/// The file at a project path (from the asset pack in a built game): its whole length, -1 when there is none.
	[CSharpExpose]
	public static int32 ReadFile(StringView path, Span<uint8> buffer)
	{
		if (!path.EndsWith(".tdata"))
			return -1;
		let full = scope String();
		Assets.ResolvePath(path, full);
		let text = scope String();
		if (AssetPack.ReadAllText(full, text) case .Err)
			return -1;
		return Copy(text, buffer);
	}

	/// The .tdata files of a class (its full name), sorted and separated by '\n'; the whole length.
	[CSharpExpose]
	public static int32 FilesOf(StringView typeName, Span<uint8> buffer)
	{
		let paths = scope List<String>();
		DataAsset.FilesOfName(typeName, paths);
		let text = scope String();
		for (let path in paths)
		{
			if (!text.IsEmpty)
				text.Append('\n');
			text.Append(path);
			delete path;
		}
		return Copy(text, buffer);
	}

	/// Keeps the player's copy: "name\tvalue" lines of the [Saved] fields. False when the storage failed.
	[CSharpExpose]
	public static bool WriteCopy(StringView path, StringView fields)
	{
		let root = scope SaveNode(.Object);
		for (var line in fields.Split('\n', .RemoveEmptyEntries))
		{
			let tab = line.IndexOf('\t');
			if (tab > 0)
				root.Set(line.Substring(0, tab), SaveNode.MakeString(line.Substring(tab + 1)));
		}
		let task = scope SaveTask(.Save, SlotOf(path, .. scope .()));
		root.ToBytes(task.data);
		DataAsset.Storage.Write(task);
		if (task.Done && !task.Succeeded)
		{
			Log.Error(scope $"Could not keep {path}: {task.error}");
			return false;
		}
		return true;
	}

	/// The player's copy as "name\tvalue" lines: its whole length, -1 when there is none (or it is damaged, or the
	/// storage has not answered yet).
	[CSharpExpose]
	public static int32 ReadCopy(StringView path, Span<uint8> buffer)
	{
		let task = scope SaveTask(.Load, SlotOf(path, .. scope .()));
		DataAsset.Storage.Read(task);
		if (!task.Done || !task.Succeeded || !task.Found)
			return -1;
		let node = SaveNode.FromBytes(task.data);
		if (node == null)
		{
			Log.Error(scope $"The player's copy of {path} is damaged; the asset's values are used.");
			return -1;
		}
		defer delete node;
		let text = scope String();
		if (node.kind == .Object)
		{
			for (int i < node.keys.Count)
			{
				let item = node.items[i];
				// A line break would make a line of its own: a changed copy.
				if (item.kind != .String || item.text.Contains('\n') || node.keys[i].Contains('\t'))
					continue;
				text.AppendF("{}\t{}\n", node.keys[i], item.text);
			}
		}
		return Copy(text, buffer);
	}

	/// Forgets the player's copy.
	[CSharpExpose]
	public static void DeleteCopy(StringView path) => DataAsset.Storage.Delete(SlotOf(path, .. scope .()));

	/// The project's .tdata files are looked for again (one was made or renamed).
	[CSharpExpose]
	public static void Rescan() => DataAsset.ForgetIndex();

	static void SlotOf(StringView path, String slot)
	{
		slot.Append(path);
		if (slot.EndsWith(".tdata"))
			slot.RemoveFromEnd(6);
	}

	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}
}
