using System;
using System.Collections;
using System.IO;

namespace Tallow.Editor;

/// Engine identities and project pins (tallow-version.json, tallow-engine.lock.json).
/// The launcher and the project generator use this directly, so opening, creating or
/// upgrading a project does not need Python. tools/engine_versions.py remains for
/// the packaging scripts (install, resolve) and must read and write the same files.
static class EngineVersions
{
	public const String Manifest = "tallow-version.json";
	public const String Lock = "tallow-engine.lock.json";

	public struct Identity : IEquatable<Identity>
	{
		public String engine;
		public String version;
		public String build;
		public int32 projectFormat;

		public bool Equals(Identity other) =>
			engine == other.engine && version == other.version && build == other.build &&
			projectFormat == other.projectFormat;
	}

	/// Reads the string or integer value of a top-level key in a flat JSON object.
	static bool JsonValue(StringView json, StringView key, String output, out bool isString)
	{
		isString = false;
		let quoted = scope $"\"{key}\"";
		var at = json.IndexOf(quoted);
		if (at < 0)
			return false;
		at += quoted.Length;
		while (at < json.Length && (json[at] == ' ' || json[at] == '\t' || json[at] == '\r' || json[at] == '\n'))
			at++;
		if (at >= json.Length || json[at] != ':')
			return false;
		at++;
		while (at < json.Length && (json[at] == ' ' || json[at] == '\t' || json[at] == '\r' || json[at] == '\n'))
			at++;
		if (at >= json.Length)
			return false;
		if (json[at] == '"')
		{
			let end = json.IndexOf('"', at + 1);
			if (end < 0)
				return false;
			let text = json.Substring(at + 1, end - at - 1);
			// Identity values are plain version text; escapes would mean a damaged file.
			if (text.Contains('\\'))
				return false;
			output.Set(text);
			isString = true;
			return true;
		}
		var end = at;
		while (end < json.Length && (json[end].IsDigit || json[end] == '-'))
			end++;
		if (end == at)
			return false;
		output.Set(json.Substring(at, end - at));
		return true;
	}

	static bool ValidVersion(StringView text)
	{
		if (text.IsEmpty || !text[0].IsLetterOrDigit)
			return false;
		for (let c in text.RawChars)
			if (!c.IsLetterOrDigit && c != '.' && c != '+' && c != '-')
				return false;
		return true;
	}

	static bool ValidBuild(StringView text)
	{
		if (text.Length != 40)
			return false;
		for (let c in text.RawChars)
			if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
				return false;
		return true;
	}

	/// Reads and validates an identity file (the same rules as engine_versions.identity).
	/// The strings are appended to the caller's; pass scoped Strings.
	public static bool Read(StringView path, String engine, String version, String build, out int32 projectFormat)
	{
		projectFormat = 0;
		let json = scope String();
		if (File.ReadAllText(path, json) case .Err)
			return false;
		bool isString = false;
		let format = scope String();
		if (!JsonValue(json, "engine", engine, out isString) || !isString || engine != "Tallow")
			return false;
		if (!JsonValue(json, "version", version, out isString) || !isString || !ValidVersion(version))
			return false;
		if (!JsonValue(json, "build", build, out isString) || !isString || !ValidBuild(build))
			return false;
		if (!JsonValue(json, "project_format", format, out isString) || isString)
			return false;
		if (!(int32.Parse(format) case .Ok(let value)) || value < 1)
			return false;
		projectFormat = value;
		return true;
	}

	/// Writes an identity as engine_versions.write_json does (sorted keys, two-space indent), atomically.
	static bool Write(StringView path, StringView engine, StringView version, StringView build, int32 projectFormat)
	{
		let text = scope String();
		text.AppendF("{{\n  \"build\": \"{}\",\n  \"engine\": \"{}\",\n  \"project_format\": {},\n  \"version\": \"{}\"\n}}\n",
			build, engine, projectFormat, version);
		let temporary = scope $"{path}.tmp";
		if (File.WriteAllText(temporary, text) case .Err)
			return false;
		if (File.Move(temporary, path) case .Err)
		{
			File.Delete(temporary).IgnoreError();
			return false;
		}
		return true;
	}

	static bool Same(StringView a, StringView b)
	{
		let engineA = scope String(); let versionA = scope String(); let buildA = scope String();
		let engineB = scope String(); let versionB = scope String(); let buildB = scope String();
		int32 formatA = 0, formatB = 0;
		return Read(a, engineA, versionA, buildA, out formatA) && Read(b, engineB, versionB, buildB, out formatB) &&
			engineA == engineB && versionA == versionB && buildA == buildB && formatA == formatB;
	}

	/// The engine folder named by the project's settings file, or false.
	static bool RecordedEngine(StringView project, String output)
	{
		for (let name in StringView[?]("project.tallow", "project.tessera"))
		{
			let text = scope String();
			if (File.ReadAllText(scope $"{project}/{name}", text) case .Err)
				continue;
			for (var line in text.Split('\n'))
			{
				let equals = line.IndexOf('=');
				if (equals < 0)
					continue;
				var key = line.Substring(0, equals);
				key.Trim();
				if (key != "engine")
					continue;
				var value = line.Substring(equals + 1);
				value.Trim();
				if (Path.IsPathRooted(value))
					output.Set(value);
				else
					output.Set(scope $"{project}/{value}");
				return true;
			}
		}
		return false;
	}

	/// Whether an engine folder carries an identity at all (packaged engines do; source checkouts do not).
	public static bool HasManifest(StringView engineRoot) => File.Exists(scope $"{engineRoot}/{Manifest}");

	/// What opening a project with this engine means: "same", "upgrade" or "newer" (this engine cannot read it),
	/// with the two version names for the message. Mirrors engine_versions.check.
	public static bool Check(StringView project, StringView engineRoot, String verdict, String from, String to)
	{
		verdict.Set("same");
		let engine = scope String(); let version = scope String(); let build = scope String();
		int32 format = 0;
		if (!Read(scope $"{engineRoot}/{Manifest}", engine, version, build, out format))
			return false;
		if (!File.Exists(scope $"{project}/project.tallow"))
		{
			verdict.Set("upgrade");
			from.Set("Tessera");
			to.Set(version);
			return true;
		}
		let lock = scope $"{project}/{Lock}";
		if (!File.Exists(lock))
			return true;
		let pinnedEngine = scope String(); let pinnedVersion = scope String(); let pinnedBuild = scope String();
		int32 pinnedFormat = 0;
		if (!Read(lock, pinnedEngine, pinnedVersion, pinnedBuild, out pinnedFormat))
			return false;
		if (pinnedVersion == version && pinnedBuild == build && pinnedFormat == format)
			return true;
		if (pinnedFormat > format)
		{
			verdict.Set("newer");
			from.Set(pinnedVersion);
			to.Set(version);
			return true;
		}
		let recorded = scope String();
		if (RecordedEngine(project, recorded) && File.Exists(scope $"{recorded}/{Manifest}") &&
			Same(scope $"{recorded}/{Manifest}", lock))
			return true; // The engine it is pinned to is still installed.
		verdict.Set("upgrade");
		from.Set(pinnedVersion);
		to.Set(version);
		return true;
	}

	/// True when the project is not pinned, or is pinned to exactly this engine. Mirrors engine_versions.verify.
	public static bool Verify(StringView project, StringView engineRoot)
	{
		let lock = scope $"{project}/{Lock}";
		if (!File.Exists(lock))
			return true;
		return Same(lock, scope $"{engineRoot}/{Manifest}");
	}

	/// Pins a newly created project to this engine; an existing pin must already match.
	public static bool PinNew(StringView project, StringView engineRoot, String error)
	{
		let lock = scope $"{project}/{Lock}";
		if (File.Exists(lock))
		{
			if (Verify(project, engineRoot))
				return true;
			error.Set("A different engine build is already pinned; migration is explicit.");
			return false;
		}
		let engine = scope String(); let version = scope String(); let build = scope String();
		int32 format = 0;
		if (!Read(scope $"{engineRoot}/{Manifest}", engine, version, build, out format))
		{
			error.Set("This engine's tallow-version.json is missing or invalid.");
			return false;
		}
		if (!Write(lock, engine, version, build, format))
		{
			error.Set(scope $"Could not write {lock}.");
			return false;
		}
		return true;
	}

	static void KeepCopy(StringView project, StringView backup, StringView file)
	{
		if (!file.StartsWith(project))
			return;
		let target = scope $"{backup}{file.Substring(project.Length)}";
		let folder = scope String();
		Path.GetDirectoryPath(target, folder).IgnoreError();
		Directory.CreateDirectory(folder).IgnoreError();
		File.Copy(file, target, true).IgnoreError();
	}

	/// The engine's old namespace in code and saved component names: "Tessera" followed by ".X" (capital), ";" or
	/// "::", at a word start. Never a game's own TesseraIntro or the word in a sentence.
	static bool RenameLegacyNamespace(StringView text, String output)
	{
		bool changed = false;
		int i = 0;
		let word = "Tessera";
		while (i < text.Length)
		{
			let at = text.IndexOf(word, i);
			if (at < 0)
				break;
			output.Append(text.Substring(i, at - i));
			let after = at + word.Length;
			let wordStart = at == 0 || !(text[at - 1].IsLetterOrDigit || text[at - 1] == '_');
			let follows = (after + 1 < text.Length && text[after] == '.' && text[after + 1].IsUpper) ||
				(after < text.Length && text[after] == ';') ||
				(after + 1 < text.Length && text[after] == ':' && text[after + 1] == ':');
			if (wordStart && follows)
			{
				output.Append("Tallow");
				changed = true;
			}
			else
				output.Append(word);
			i = after;
		}
		output.Append(text.Substring(i));
		return changed;
	}

	static void RenameInFolder(StringView project, StringView backup, StringView folder, int depth)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateDirectories(folder))
			RenameInFolder(project, backup, entry.GetFilePath(.. scope .()), depth + 1);
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let path = entry.GetFilePath(.. scope .());
			let text = scope String();
			if (File.ReadAllText(path, text) case .Err)
				continue;
			if (text.Contains('\0') || !text.Contains("Tessera"))
				continue;
			let updated = scope String();
			if (!RenameLegacyNamespace(text, updated))
				continue;
			KeepCopy(project, backup, path);
			File.WriteAllText(path, updated).IgnoreError();
		}
	}

	/// Moves a project to this engine, keeping every file it changes in .tallow-upgrade-backup/<build>.
	/// Mirrors engine_versions.upgrade.
	public static bool Upgrade(StringView projectIn, StringView engineRoot, String error)
	{
		let project = scope String(projectIn);
		while (project.EndsWith('/') || project.EndsWith('\\'))
			project.RemoveFromEnd(1);
		let verdict = scope String(); let from = scope String(); let to = scope String();
		if (!Check(project, engineRoot, verdict, from, to))
		{
			error.Set("This engine's tallow-version.json, or the project's pin, is missing or invalid.");
			return false;
		}
		if (verdict == "newer")
		{
			error.Set("This project needs a newer Tallow engine.");
			return false;
		}
		let engine = scope String(); let version = scope String(); let build = scope String();
		int32 format = 0;
		Read(scope $"{engineRoot}/{Manifest}", engine, version, build, out format);
		let backup = scope $"{project}/.tallow-upgrade-backup/{build}";
		let legacy = scope $"{project}/project.tessera";
		let settings = scope $"{project}/project.tallow";
		if (File.Exists(legacy) && !File.Exists(settings))
		{
			KeepCopy(project, backup, legacy);
			if (File.Move(legacy, settings) case .Err)
			{
				error.Set("Could not rename project.tessera to project.tallow.");
				return false;
			}
			RenameInFolder(project, backup, scope $"{project}/src", 0);
		}
		else
			KeepCopy(project, backup, settings);

		let text = scope String();
		File.ReadAllText(settings, text).IgnoreError();
		let root = scope String(engineRoot);
		root.Replace('\\', '/');
		let entry = scope $"engine = {root}";
		let updated = scope String();
		bool found = false;
		for (let line in text.Split('\n', .RemoveEmptyEntries))
		{
			let equals = line.IndexOf('=');
			var key = equals >= 0 ? line.Substring(0, equals) : line;
			key.Trim();
			if (key == "engine")
			{
				updated.Append(entry);
				found = true;
			}
			else
				updated.Append(line);
			updated.Append('\n');
		}
		if (!found)
			updated.AppendF("{}\n", entry);
		if (File.WriteAllText(settings, updated) case .Err)
		{
			error.Set(scope $"Could not write {settings}.");
			return false;
		}
		let lock = scope $"{project}/{Lock}";
		if (File.Exists(lock))
			KeepCopy(project, backup, lock);
		if (!Write(lock, engine, version, build, format))
		{
			error.Set(scope $"Could not write {lock}.");
			return false;
		}
		return true;
	}
}
