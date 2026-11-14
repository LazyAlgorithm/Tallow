using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// An immutable source snapshot sent to the selected language compiler. Rename rechecks sources.
class ScriptSourceSnapshot
{
	public String path = new .() ~ delete _;
	public String text = new .() ~ delete _;
	public String replacement = new .() ~ delete _;
}

/// A compiler-resolved symbol occurrence. Offsets and lengths are UTF-8 bytes.
struct ScriptSymbolReference
{
	public int file;
	public int start;
	public int length;
}

/// Runs the compiler language service outside the editor. Source snapshots
/// are checked before applying results. User source is never modified by the worker.
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
	// Always rebuild Roslyn once after launching the editor: a previously built
	// DLL may be stale after the user pulls changes to the C# integration branch.
	bool mCSharpWorkerBuilt;
	bool mCSharpServerStarted;
	String mCSharpQueue = new .() ~ delete _;
	String mCSharpServiceCommand = new .() ~ delete _;
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
		if (!mCSharpQueue.IsEmpty)
			File.WriteAllText(scope $"{mCSharpQueue}/stop", "stop").IgnoreError();
	}

	public int Find(StringView file)
	{
		let canonical = scope String();
		CanonicalPath(file, canonical);
		for (int i < sources.Count)
		{
			if (Path.Equals(sources[i].path, canonical, .Lenient))
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

	public bool AddFolder(StringView folder, StringView suffix = ".bf", int depth = 0)
	{
		if (depth > 32)
			return false;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.EndsWith(suffix, .OrdinalIgnoreCase))
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
			if (!name.StartsWith('.') && name != "build" && !AddFolder(scope $"{folder}/{name}" , suffix, depth + 1))
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
		let isCSharp = path.EndsWith(".cs", .OrdinalIgnoreCase);
		status.Set(isCSharp ? "C#: resolving..." : "Resolving...");
		if (!mFolder.IsEmpty)
			Directory.DelTree(mFolder).IgnoreError();
		if (isCSharp)
		{
			if (mCSharpQueue.IsEmpty)
				mCSharpQueue.Set(scope $"{Project.Current.Path}/.tallow-language/roslyn-{SDL.SDL_GetTicksNS()}");
			if (Directory.CreateDirectory(mCSharpQueue) case .Err)
				return false;
			mFolder.Set(scope $"{mCSharpQueue}/request-{SDL.SDL_GetTicksNS()}");
		}
		else
			mFolder.Set(scope $"{Project.Current.Path}/.tallow-language/{SDL.SDL_GetTicksNS()}");
		if (Directory.CreateDirectory(mFolder) case .Err)
			return false;
		let manifest = scope $"operation\t{request}\nfile\t{path}\ncursor\t{byteOffset}\nnew_name\t{newName}\n";
		for (int i < sources.Count)
		{
			let source = sources[i];
			if (source.path.Contains('\t') || source.path.Contains('\n'))
				return false;
			let snapshot = scope $"{mFolder}/{i}{(isCSharp ? ".cs" : ".bf")}";
			if (File.WriteAllText(snapshot, source.text) case .Err)
				return false;
			manifest.AppendF("overlay\t{}\t{}\n", source.path, snapshot);
		}
		if (File.WriteAllText(scope $"{mFolder}/request.tsv" , manifest) case .Err)
			return false;
		mCommand.Clear();
		if (isCSharp)
		{
			// Build Roslyn once, then leave the compiler running as an editor
			// process. Each semantic query uses a lightweight queue request.
			let service = scope $"{Project.Current.EngineRoot}/Managed/Tallow.LanguageService/Tallow.LanguageService.csproj";
			let dll = scope $"{Project.Current.EngineRoot}/Managed/Tallow.LanguageService/bin/Debug/net11.0/Tallow.LanguageService.dll";
			if (!mCSharpWorkerBuilt)
			{
				mCommand.Append("dotnet build ");
				Terminal.Quote(service, mCommand);
				mCommand.Append(" --configuration Debug --nologo --verbosity quiet > ");
				Terminal.Quote(scope $"{mFolder}/worker.log", mCommand);
				mCommand.Append(" 2>&1");
			}
			mCSharpServiceCommand.Clear();
			mCSharpServiceCommand.Append("dotnet ");
			Terminal.Quote(dll, mCSharpServiceCommand);
			mCSharpServiceCommand.Append(" --serve ");
			Terminal.Quote(mCSharpQueue, mCSharpServiceCommand);
			mCSharpServiceCommand.Append(" --project ");
			Terminal.Quote(Project.Current.Path, mCSharpServiceCommand);
			mCSharpServiceCommand.Append(" --engine-root ");
			Terminal.Quote(Project.Current.EngineRoot, mCSharpServiceCommand);
			mCSharpServiceCommand.Append(" > ");
			Terminal.Quote(scope $"{mCSharpQueue}/server.log", mCSharpServiceCommand);
			mCSharpServiceCommand.Append(" 2>&1");
		}
		else
		{
			// Legacy compiler worker for generated graph sources; migrate separately.
			mCommand.AppendF("{} ", Terminal.Python);
			Terminal.Quote(scope $"{Project.Current.EngineRoot}/tools/beef_language_service.py", mCommand);
			mCommand.Append(" --project ");
			Terminal.Quote(Project.Current.Path, mCommand);
		}
		if (!isCSharp)
		{
			mCommand.Append(" --request ");
			Terminal.Quote(mFolder, mCommand);
			mCommand.Append(" > ");
			Terminal.Quote(scope $"{mFolder}/worker.log", mCommand);
			mCommand.Append(" 2>&1");
		}
		running = true;
		mFinished = false;
		mWorker = new Thread(new () =>
			{
				if (isCSharp)
				{
					if (!mCSharpWorkerBuilt)
					{
						if (Terminal.Run(mCommand) == 0)
							mCSharpWorkerBuilt = true;
					}
					if (mCSharpWorkerBuilt)
					{
						if (!mCSharpServerStarted)
						{
							File.Delete(scope $"{mCSharpQueue}/ready").IgnoreError();
							File.Delete(scope $"{mCSharpQueue}/stop").IgnoreError();
							Terminal.RunDetached(mCSharpServiceCommand);
							mCSharpServerStarted = true;
						}
						// The request is already written. Normally the warm worker
						// responds in milliseconds, without starting a new runtime.
						for (int tries = 0; tries < 500 &&
							!File.Exists(scope $"{mFolder}/response.tsv"); tries++)
							Thread.Sleep(20);
						if (!File.Exists(scope $"{mFolder}/response.tsv"))
							mCSharpServerStarted = false;
					}
				}
				else
					Terminal.Run(mCommand);
				if (File.ReadAllText(scope $"{mFolder}/response.tsv" , result, true) case .Err)
				{
					// The .NET process may fail before it can write response.tsv
					// (missing SDK, failed restore or missing runtime). Show the
					// useful error in the editor instead of a raw wait status.
					let workerLog = scope String();
					let detail = scope String();
					let logPath = isCSharp && mCSharpWorkerBuilt ? scope $"{mCSharpQueue}/server.log" : scope $"{mFolder}/worker.log";
					if (File.ReadAllText(logPath, workerLog, true) case .Ok)
					{
						for (let line in workerLog.Split('\n'))
						{
							if (line.Contains("error ") || line.Contains("NETSDK") ||
								line.Contains("not found") || line.Contains("could not") ||
								line.Contains("SDK"))
								detail.Set(line);
						}
						if (detail.IsEmpty)
						{
							for (let line in workerLog.Split('\n'))
							{
								if (!line.IsEmpty)
								{
									detail.Set(line);
									break;
								}
							}
						}
						if (detail.Length > 450)
							detail.Remove(450, detail.Length - 450);
					}
					result.Set(detail.IsEmpty ?
						"error\tC# language service could not start. Check .NET 11 SDK and worker.log.\n" :
						scope $"error\tC# language service: {detail}\n");
				}
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
		status.Set("Language service ready");
		return true;
	}
}
