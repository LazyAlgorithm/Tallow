using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

enum ProjectTemplate
{
	Empty, Sample, Showcase
}

/// Creates new projects from built-in templates.
static class ProjectGenerator
{
	public static bool IsValidName(StringView name)
	{
		if (name.IsEmpty || name.Length > 48 || name[0].IsDigit)
			return false;
		for (let c in name.RawChars)
		{
			if (!c.IsLetterOrDigit && c != '_')
				return false;
		}
		return true;
	}

	/// Finds the engine folder (the one containing Engine/ and Editor/) from the running executable.
	public static bool FindEngineRoot(String outRoot)
	{
		let env = scope String();
		if (Environment.GetEnvironmentVariable("TALLOW_ROOT", env) case .Ok && !env.IsEmpty && Directory.Exists(scope $"{env}/Engine/src"))
		{
			// Forward slashes throughout, also on Windows: the path is written into build files where a backslash
			// would start an escape.
			env.Replace('\\', '/');
			if (env.EndsWith("/."))
				env.RemoveFromEnd(2);
			outRoot.Set(env);
			return true;
		}
		// Gfx.EngineAssetPath is <root>/Engine/assets, possibly with ../ segments.
		if (!Gfx.EngineAssetPath.IsEmpty)
		{
			let candidate = scope String();
			candidate.AppendF("{}/../..", Gfx.EngineAssetPath);
			let full = scope String();
			Normalize(candidate, full);
			if (Directory.Exists(scope $"{full}/Engine/src"))
			{
				outRoot.Set(full);
				while (outRoot.EndsWith('/') && outRoot.Length > 1)
					outRoot.RemoveFromEnd(1);
				return true;
			}
		}
		return false;
	}

	/// Collapses "." and ".." segments and repeated slashes in an absolute path.
	public static void Normalize(StringView path, String outPath)
	{
		List<StringView> parts = scope .();
		let forward = scope String(path)..Replace('\\', '/');
		for (let part in forward.Split('/'))
		{
			if (part.IsEmpty || part == ".")
				continue;
			if (part == "..")
			{
				if (parts.Count > 0)
					parts.PopBack();
				continue;
			}
			parts.Add(part);
		}
		for (let part in parts)
		{
			// A Windows path starts with its drive (C:), not with a slash.
			if (!(@part.Index == 0 && part.EndsWith(':')))
				outPath.Append('/');
			outPath.Append(part);
		}
		if (outPath.IsEmpty)
			outPath.Append('/');
	}

	static void Write(StringView path, StringView text)
	{
		if (File.WriteAllText(path, text) case .Err)
			Log.Error(scope $"Could not write {path}");
	}

	/// The project's folders: src (the assets) with its usual subfolders, and Libraries.
	static bool CreateFolders(StringView folder, String error)
	{
		for (let sub in StringView[?]("", "/src", "/src/Scripts", "/src/Scenes", "/src/Models", "/src/Textures", "/src/Prefabs", "/Libraries"))
		{
			if (Directory.CreateDirectory(scope $"{folder}{sub}") case .Err)
			{
				if (!Directory.Exists(scope $"{folder}{sub}"))
				{
					error.Set(scope $"Could not create {folder}{sub}");
					return false;
				}
			}
		}
		return true;
	}

	/// Copy saved assets recursively, including terrain sidecars; substitute only text assets.
	static bool CopyShowcase(StringView source, StringView destination, StringView name, String error)
	{
		if (Directory.CreateDirectory(destination) case .Err)
		{
			if (!Directory.Exists(destination))
			{
				error.Set(scope $"Could not create {destination}");
				return false;
			}
		}
		for (let entry in Directory.EnumerateFiles(source))
		{
			let file = scope String();
			entry.GetFileName(file);
			let from = scope $"{source}/{file}";
			let to = scope $"{destination}/{file}";
			if (file.EndsWith(".cs") || file.EndsWith(".bf") || file.EndsWith(".tscene") || file.EndsWith(".tprefab"))
			{
				let text = scope String();
				if (File.ReadAllText(from, text) case .Err)
				{
					error.Set(scope $"Could not read {from}");
					return false;
				}
				text.Replace("{NAMESPACE}", name);
				if (File.WriteAllText(to, text) case .Ok) continue;
			}
			else if (File.Copy(from, to, true) case .Ok) continue;
			error.Set(scope $"Could not copy {from} to {to}");
			return false;
		}
		for (let entry in Directory.EnumerateDirectories(source))
		{
			let dir = scope String();
			entry.GetFileName(dir);
			if (!CopyShowcase(scope $"{source}/{dir}" , scope $"{destination}/{dir}" , name, error)) return false;
		}
		return true;
	}

	/// Creates the folder structure and source files. sample adds a voxel world with a networked player.
	/// Copies a template folder into a project, subfolders too. A file ending in .txt is text with {NAMESPACE} for the
	/// project's name, and is written without the .txt ("Player.bf.txt" becomes "Player.bf").
	static void CopyTemplateFiles(StringView source, StringView destination, StringView name)
	{
		if (!Directory.Exists(source))
			return;
		Directory.CreateDirectory(destination).IgnoreError();
		for (let entry in Directory.EnumerateDirectories(source))
		{
			let sub = entry.GetFileName(.. scope .());
			CopyTemplateFiles(scope $"{source}/{sub}", scope $"{destination}/{sub}", name);
		}
		for (let entry in Directory.EnumerateFiles(source))
		{
			let fileName = entry.GetFileName(.. scope .());
			if (fileName.EndsWith(".txt"))
			{
				let text = scope String();
				if (File.ReadAllText(scope $"{source}/{fileName}" , text, true) case .Err)
					continue;
				text.Replace("{NAMESPACE}", name);
				fileName.RemoveFromEnd(4);
				Write(scope $"{destination}/{fileName}" , text);
			}
			else
				File.Copy(scope $"{source}/{fileName}" , scope $"{destination}/{fileName}").IgnoreError();
		}
	}

	public static bool Create(StringView folder, StringView name, StringView engineRoot, bool sample, String error)
	{
		return Create(folder, name, engineRoot, sample ? .Sample : .Empty, error);
	}

	public static bool Create(StringView folder, StringView name, StringView engineRoot, ProjectTemplate template, String error)
	{
		if (!IsValidName(name))
		{
			error.Set("Project names use letters, digits and underscores, and start with a letter.");
			return false;
		}
		if (Directory.Exists(folder) && File.Exists(scope $"{folder}/project.tallow"))
		{
			error.Set("A project already exists in that folder.");
			return false;
		}
		if (template == .Showcase && !File.Exists(scope $"{engineRoot}/Editor/templates/showcase/src/Scenes/Gallery.tscene"))
		{
			error.Set("The Tallow Gallery template is missing from this engine installation.");
			return false;
		}
		if (!CreateFolders(folder, error))
			return false;

		let project = scope Project();
		project.Name.Set(name);
		project.Path.Set(folder);
		project.EngineRoot.Set(engineRoot);
		if (template == .Showcase)
		{
			project.StartScene.Set("Scenes/Gallery.tscene");
			project.WindowWidth = 1600;
			project.WindowHeight = 900;
			project.EscapeQuits = false;
		}
		project.Save();

		// Packaged engines carry immutable identity. New projects are pinned
		// before the first build; source checkouts without a manifest stay legacy.
		if (EngineVersions.HasManifest(engineRoot))
		{
			let detail = scope String();
			if (!EngineVersions.PinNew(folder, engineRoot, detail))
			{
				error.Set(scope $"Could not pin the new project to this Tallow engine build. {detail}");
				return false;
			}
		}

		// BeefSpace/BeefProj are only for Beef gameplay; Project.Build writes them when a
		// legacy native build is asked for. Every template's gameplay is C#, so none starts with them.

		Write(scope $"{folder}/.gitignore" , "build/\nrecovery/\n.cache/\n.tallow-csharp/\n*.slnx\nPackages/Downloads/\nPackages/Exports/\nBeefSpace.toml\nBeefProj.toml\n");

		if (template == .Showcase)
		{
			if (!CopyShowcase(scope $"{engineRoot}/Editor/templates/showcase" , folder, name, error))
				return false;
			Write(scope $"{folder}/.template" , "showcase");
			return true;
		}

		if (template == .Empty)
		{
			// One C# script: the scene's first-person character (Scripts/FirstPersonCharacter.cs). The project runs
			// in the precompiled editor and player, so there is no Program.bf and nothing for BeefBuild to compile.
			for (let sub in StringView[?]("Scripts", "Prefabs", "Materials", "Textures", "Models", "Scenes"))
				Directory.CreateDirectory(scope $"{folder}/src/{sub}").IgnoreError();
			CopyTemplateFiles(scope $"{engineRoot}/Editor/templates/empty", scope $"{folder}/src", name);
			Write(scope $"{folder}/.template" , "empty");
			return true;
		}

		// The first scene (and Prefabs/Player.tprefab) is built by the editor the first time the project opens.
		// Shared sample content: the C# starter scripts, the animated character, its clips and the menu.
		let common = scope $"{engineRoot}/Editor/templates/common";
		for (let sub in StringView[?]("Scripts", "Prefabs", "Animations", "Models", "UI", "Materials", "Shaders", "Textures"))
		{
			Directory.CreateDirectory(scope $"{folder}/src/{sub}").IgnoreError();
			if (!Directory.Exists(scope $"{common}/{sub}"))
				continue;
			for (let entry in Directory.EnumerateFiles(scope $"{common}/{sub}"))
			{
				let fileName = scope String();
				entry.GetFileName(fileName);
				if (fileName.EndsWith(".txt"))
				{
					let text = scope String();
					if (File.ReadAllText(scope $"{common}/{sub}/{fileName}" , text, true) case .Err)
						continue;
					text.Replace("{NAMESPACE}", name);
					fileName.Replace(".txt", "");
					Write(scope $"{folder}/src/{sub}/{fileName}" , text);
				}
				else
					File.Copy(scope $"{common}/{sub}/{fileName}" , scope $"{folder}/src/{sub}/{fileName}").IgnoreError();
			}
		}
		Write(scope $"{folder}/.template" , template == .Sample ? "sample" : "empty");
		return true;
	}
}
