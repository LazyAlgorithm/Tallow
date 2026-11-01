using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Remembers recently opened projects in the user's config folder.
static class RecentProjects
{
	public static List<String> Paths = new .() ~ DeleteContainerAndItems!(_);

	static void GetFile(String outPath)
	{
		let pref = SDL.SDL_GetPrefPath("Tallow", "Editor");
		if (pref != null)
			outPath.Append(pref);
		outPath.Append("recent_projects.txt");
	}

	public static void GetConfigFolder(String outPath)
	{
		let pref = SDL.SDL_GetPrefPath("Tallow", "Editor");
		if (pref != null)
			outPath.Append(pref);
	}

	public static void Load()
	{
		ClearAndDeleteItems!(Paths);
		let text = scope String();
		if (File.ReadAllText(GetFile(.. scope .()), text) case .Err)
			return;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (!line.IsEmpty && File.Exists(scope $"{line}/project.tallow"))
				Paths.Add(new String(line));
		}
	}

	public static void Add(StringView path)
	{
		for (int i = Paths.Count - 1; i >= 0; i--)
		{
			if (Paths[i] == path)
			{
				delete Paths[i];
				Paths.RemoveAt(i);
			}
		}
		Paths.Insert(0, new String(path));
		Save();
	}

	public static void Remove(StringView path)
	{
		for (int i = Paths.Count - 1; i >= 0; i--)
		{
			if (Paths[i] == path)
			{
				delete Paths[i];
				Paths.RemoveAt(i);
			}
		}
		Save();
	}

	static void Save()
	{
		let text = scope String();
		for (let path in Paths)
			text.AppendF("{}\n", path);
		File.WriteAllText(GetFile(.. scope .()), text).IgnoreError();
	}
}
