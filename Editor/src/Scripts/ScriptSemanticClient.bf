using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// A source snapshot, kept for a complete semantic query and for reversible symbol renames.
class ScriptSourceSnapshot
{
	public String path = new .() ~ delete _;
	public String text = new .() ~ delete _;
	public String replacement = new .() ~ delete _;
}

/// Compiler-reported reference in an immutable semantic query snapshot.
struct ScriptSymbolReference
{
	public int file;
	public int start;
	public int length;
}

/// Asynchronous bridge to tools/beef_language_service.py.
/// Keeps source files untouched: unsaved buffers are passed as temporary overlays.
class ScriptSemantic
{
	public List<ScriptSourceSnapshot> sources = new .() ~ DeleteContainerAndItems!(_);
	public String status = new .() ~ delete _;
	public String result = new .() ~ delete _;
	public String path = new .() ~ delete _;
	public String operation = new .() ~ delete _;
	public String renameName = new .() ~ delete _;
	public int cursor;
	public bool running;

	String mProject = new .() ~ delete _;
	String mEngineRoot = new .() ~ delete _;
	String mWorkspace = new .() ~ delete _;
	Thread mThread;
	bool mFinished;

	public ~this()
	{
		mThread?.Join();
		delete mThread;
	}

	public static void CanonicalPath(StringView input, String output)
	{
		output.Clear();
		Path.GetFullPath(input, output);
		if (output.IsEmpty)
			output.Set(input);
	}

	public int Find(StringView filename)
	{
		let canonical = scope String();
		CanonicalPath(filename, canonical);
		for (int i < sources.Count)
			if (Path.Equals(sources[i].path, canonical))
				return i;
		return -1;
	}

	public void Add(StringView filename, StringView contents)
	{
		let canonical = scope String();
		CanonicalPath(filename, canonical);
		int existing = Find(canonical);
		if (existing >= 0)
		{
			sources[existing].text.Set(contents);
			return;
		}
		let source = new ScriptSourceSnapshot();
		source.path.Set(canonical);
		source.text.Set(contents);
		sources.Add(source);
	}

	bool AddFolderRecursive(StringView folder, int depth)
	{
		if (depth > 32 || !Directory.Exists(folder))
			return false;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let filename = scope String();
			entry.GetFileName(filename);
			if (!filename.EndsWith(".bf", .OrdinalIgnoreCase))
				continue;
			let contents = scope String();
			if (File.ReadAllText(entry, contents, true) case .Err)
				return false;
			Add(entry, contents);
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let filename = scope String();
			entry.GetFileName(filename);
			if (!filename.StartsWith('.') && filename != "build" && !AddFolderRecursive(entry, depth + 1))
				return false;
		}
		return true;
	}

	public bool AddFolder(StringView folder) => AddFolderRecursive(folder, 0);

	public bool Start(StringView requestedOperation, StringView filename, int requestedCursor, StringView requestedRename)
	{
		if (running || Project.Current == null)
			return false;
		if (mThread != null)
		{
			mThread.Join();
			DeleteAndNullify!(mThread);
		}
		CanonicalPath(filename, path);
		operation.Set(requestedOperation);
		renameName.Set(requestedRename);
		cursor = requestedCursor;
		mProject.Set(Project.Current.Path);
		mEngineRoot.Set(Project.Current.EngineRoot);
		mWorkspace.Set(scope $"{mProject}/build/.tallow-semantic-query");
		result.Clear();
		status.Set("Querying Beef compiler...");
		Interlocked.Store(ref mFinished, false);
		running = true;
		mThread = new Thread(new => Work);
		mThread.Start(false);
		return true;
	}

	void Work()
	{
		defer Interlocked.Store(ref mFinished, true);
		let requestDirectory = scope String(mWorkspace);
		if (Directory.CreateDirectory(requestDirectory) case .Err)
		{
			result.Set("error\tCould not create the Beef semantic request folder.\n");
			return;
		}
		let input = scope String();
		input.AppendF("operation\t{}\nfile\t{}\ncursor\t{}\nnew_name\t{}\n", operation, path, cursor, renameName);
		for (int i < sources.Count)
		{
			let source = sources[i];
			let snapshot = scope $"{requestDirectory}/overlay-{}.bf", i;
			if (File.WriteAllText(snapshot, source.text) case .Err)
			{
				result.Set("error\tCould not save an unsaved Beef script snapshot.\n");
				return;
			}
			input.AppendF("overlay\t{}\t{}\n", source.path, snapshot);
		}
		let requestPath = scope $"{requestDirectory}/request.tsv";
		if (File.WriteAllText(requestPath, input) case .Err)
		{
			result.Set("error\tCould not write the Beef language-service request.\n");
			return;
		}

		let python = scope String();
		if (!Toolchain.[Friend]FindOnPath(Terminal.Python, python))
		{
			result.Set("error\tPython is not available for the Beef language service.\n");
			return;
		}
		let service = scope $"{mEngineRoot}/tools/beef_language_service.py";
		if (!File.Exists(service))
		{
			result.Set("error\tTallow's Beef language service is not installed.\n");
			return;
		}
		let start = scope ProcessStartInfo();
		start.SetFileName(python);
		let args = scope String();
		Terminal.Quote(service, args);
		args.Append(" --project ");
		Terminal.Quote(mProject, args);
		args.Append(" --request ");
		Terminal.Quote(requestDirectory, args);
		start.SetArguments(args);
		start.UseShellExecute = false;
		start.CreateNoWindow = true;
		let process = scope SpawnedProcess();
		if (process.Start(start) case .Err)
		{
			result.Set("error\tUnable to start the Beef language service.\n");
			return;
		}
		process.WaitFor();
		let responsePath = scope $"{requestDirectory}/response.tsv";
		if (File.ReadAllText(responsePath, result, true) case .Err)
			result.Set("error\tBeef language service did not return a response.\n");
	}

	/// Collect once when the worker has finished; all editor changes occur on the main thread.
	public bool Collect()
	{
		if (!running || !Interlocked.Load(ref mFinished))
			return false;
		mThread.Join();
		DeleteAndNullify!(mThread);
		running = false;
		if (result.StartsWith("error\t"))
			status.Set("Beef analysis failed; see Console.");
		else
			status.Clear();
		return true;
	}
}
