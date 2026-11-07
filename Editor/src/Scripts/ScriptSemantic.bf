using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// An immutable source snapshot sent to Beef's resolver. Rename compares these again before editing buffers.
class ScriptSourceSnapshot
{
	public String path = new .() ~ delete _;
	public String text = new .() ~ delete _;
	public String replacement = new .() ~ delete _;
}

/// A compiler-resolved symbol occurrence. Offsets and lengths are UTF-8 bytes, as in Beef source files.
struct ScriptSymbolReference
{
	public int file;
	public int start;
	public int length;
}

/// Runs the Beef IDE resolver outside the editor. The UI owns snapshots until the worker finishes, and rejects
/// results when any open source changed. No resolver operation writes the project's source files.
class ScriptSemantic
{
	[CLink] static extern char8* tn_code_canonical_path(char8* path);

	/// Uses the same absolute, symlink-resolved source names as the compiler worker.
	public static void CanonicalPath(StringView file, String output)
	{
		output.Set(StringView(tn_code_canonical_path(scope String(file).CStr())));
		output.Replace('\\', '/');
	}

	Thread mWorker;
	bool mFinished;
	String mFolder = new .() ~ delete _;
	String mCommand = new .() ~ delete _;
	public bool running;
	public String operation = new .() ~ delete _;
	public String path = new .() ~ delete _;
	public String renameName = new .() ~ delete _;
	public String result = new .() ~ delete _;
	public String status = new .() ~ delete _;
	public int cursor;
	public List<ScriptSourceSnapshot> sources = new .() ~ DeleteContainerAndItems!(_);

	public ~this()
	{
		if (mWorker != null)
		{
			mWorker.Join();
			delete mWorker;
		}
		if (!mFolder.IsEmpty)
			Directory.DelTree(mFolder).IgnoreError();
	}

	public int Find(StringView file)
	{
		let canonical = scope String();
		CanonicalPath(file, canonical);
		for (int i < sources.Count)
		{
			if (Path.Equals(sources[i].path, canonical))
				return i;
		}
		return -1;
	}

	public void Add(StringView file, StringView text)
	{
		let index = Find(file);
		if (index >= 0)
		{
			sources[index].text.Set(text);
			return;
		}
		let source = new ScriptSourceSnapshot();
		CanonicalPath(file, source.path);
		source.text.Set(text);
		sources.Add(source);
	}

	public bool AddFolder(StringView folder, int depth = 0)
	{
		if (depth > 32)
			return false;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.EndsWith(".bf", .OrdinalIgnoreCase))
				continue;
			let file = scope $"{folder}/{name}";
			let source = scope String();
			if (File.ReadAllText(file, source, true) case .Err)
				return false;
			Add(file, source);
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.StartsWith('.') && name != "build" && !AddFolder(scope $"{folder}/{name}" , depth + 1))
				return false;
		}
		return true;
	}

	public bool Start(StringView request, StringView file, int byteOffset, StringView newName = "")
	{
		if (running || Project.Current == null)
			return false;
		operation.Set(request);
		CanonicalPath(file, path);
		if (path.Contains('\t') || path.Contains('\n') || newName.Contains('\t') || newName.Contains('\n'))
			return false;
		cursor = byteOffset;
		renameName.Set(newName);
		result.Clear();
		status.Set("Beef: resolving...");
		if (!mFolder.IsEmpty)
			Directory.DelTree(mFolder).IgnoreError();
		mFolder.Set(scope $"{Project.Current.Path}/.tallow-language/{SDL.SDL_GetTicksNS()}");
		if (Directory.CreateDirectory(mFolder) case .Err)
			return false;
		let manifest = scope $"operation\t{request}\nfile\t{path}\ncursor\t{byteOffset}\nnew_name\t{newName}\n";
		for (int i < sources.Count)
		{
			let source = sources[i];
			if (source.path.Contains('\t') || source.path.Contains('\n'))
				return false;
			let snapshot = scope $"{mFolder}/{i}.bf";
			if (File.WriteAllText(snapshot, source.text) case .Err)
				return false;
			manifest.AppendF("overlay\t{}\t{}\n", source.path, snapshot);
		}
		if (File.WriteAllText(scope $"{mFolder}/request.tsv" , manifest) case .Err)
			return false;
		mCommand.Clear();
		mCommand.AppendF("{} ", Terminal.Python);
		Terminal.Quote(scope $"{Project.Current.EngineRoot}/tools/beef_language_service.py" , mCommand);
		mCommand.Append(" --project ");
		Terminal.Quote(Project.Current.Path, mCommand);
		mCommand.Append(" --request ");
		Terminal.Quote(mFolder, mCommand);
		mCommand.Append(" > ");
		Terminal.Quote(scope $"{mFolder}/worker.log" , mCommand);
		mCommand.Append(" 2>&1");
		running = true;
		mFinished = false;
		mWorker = new Thread(new () =>
			{
				let exitCode = Terminal.Run(mCommand);
				if (File.ReadAllText(scope $"{mFolder}/response.tsv" , result, true) case .Err)
					result.Set(scope $"error\tBeef language service failed ({exitCode}); see {mFolder}/worker.log\n");
				Interlocked.Store(ref mFinished, true);
			});
		mWorker.Start(false);
		return true;
	}

	public bool Collect()
	{
		if (!running || !Interlocked.Load(ref mFinished))
			return false;
		mWorker.Join();
		DeleteAndNullify!(mWorker);
		running = false;
		status.Set("Beef: ready");
		return true;
	}
}
