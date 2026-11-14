using System;
using System.Collections;
using System.IO;

namespace Tallow.Editor;

/// Portable metadata scan. Order-independent snapshots detect additions, removals, renames and writes.
class ProjectFolderMonitor
{
	List<String> mSnapshot = new .() ~ DeleteContainerAndItems!(_);
	bool mInitialized;
	public bool ScriptsOnly;
	/// Extension used by script-only scans: Beef by default, C# in managed projects.
	public StringView ScriptExtension = ".bf";
	public bool Poll(StringView root)
	{
		List<String> current = scope .();
		defer
		{
			for (let item in current)
				delete item;
		}
		Scan(root, current, 0, ScriptsOnly, ScriptExtension);
		current.Sort(scope (a, b) => String.Compare(a, b, false));
		bool changed = current.Count != mSnapshot.Count;
		if (!changed)
		{
			for (int i < current.Count)
			{
				if (current[i] != mSnapshot[i])
				{
					changed = true;
					break;
				}
			}
		}
		ClearAndDeleteItems!(mSnapshot);
		for (let item in current)
			mSnapshot.Add(new String(item));
		let notify = mInitialized && changed;
		mInitialized = true;
		return notify;
	}

	static void Scan(StringView folder, List<String> files, int depth, bool scriptsOnly, StringView extension)
	{
		if (depth > 32) return; // Bound recursion if an asset folder contains a directory link cycle.
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name.StartsWith('.') || (scriptsOnly && !name.EndsWith(extension, .OrdinalIgnoreCase))) continue;
			// Fetch time first: Beef's POSIX size accessor reads the cached stat record.
			let modified = entry.GetLastWriteTimeUtc().Ticks;
			files.Add(new String(scope $"{folder}/{name}|{entry.GetFileSize()}|{modified}"));
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name.StartsWith('.')) continue;
			let path = scope $"{folder}/{name}";
			if (!scriptsOnly)
				files.Add(new String(path));
			Scan(path, files, depth + 1, scriptsOnly, extension);
		}
	}
}
