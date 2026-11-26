using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// One game build running on a thread of its own, so the editor stays usable. Tallow.Build writes its progress to the
/// log as "##progress <0-1> <step>" lines, which the editor reads for its progress bar.
class BuildJob
{
	public enum State { Running, Succeeded, Failed, Cancelled }

	public BuildTarget Target;
	public String Output = new .() ~ delete _;
	public String LogPath = new .() ~ delete _;
	public String PidPath = new .() ~ delete _;
	public String ProjectPath = new .() ~ delete _;
	/// Written by the main thread (Poll), read by the UI on it too.
	public float Progress;
	public String Step = new .() ~ delete _;
	public float Seconds;

	// Shared with the build's thread.
	public State Status = .Running;
	public bool CancelRequested;
	public bool Reported;
	public int32 ProcessId;
	public Thread Thread;
	public Stopwatch Clock = new .() ~ delete _;

	public bool Running => Volatile.Read(ref Status) == .Running;

	public ~this()
	{
		if (Thread != null)
		{
			Thread.Join();
			delete Thread;
		}
	}
}

/// The builds in progress and just finished. All calls are from the editor's main thread.
static class BuildJobs
{
	public static List<BuildJob> Jobs = new .() ~ DeleteContainerAndItems!(_);
	/// How many may run at once (one per system; they take turns only where they share the project's build folders).
	public const int MaxRunning = 3;
	static float sPollTimer;

	public static bool AnyRunning
	{
		get
		{
			for (let job in Jobs)
				if (job.Running)
					return true;
			return false;
		}
	}

	public static BuildJob Find(BuildTarget target)
	{
		for (let job in Jobs)
			if (job.Target == target)
				return job;
		return null;
	}

	public static int RunningCount
	{
		get
		{
			int n = 0;
			for (let job in Jobs)
				if (job.Running)
					n++;
			return n;
		}
	}

	/// Starts a build; false (and a message) when that system is already being built.
	public static bool Start(Project project, StringView output, BuildTarget target, bool iosSimulator, String error)
	{
		if (let old = Find(target))
		{
			if (old.Running)
			{
				error.Set("That system is already being built.");
				return false;
			}
			Jobs.Remove(old);
			delete old;
		}
		if (RunningCount >= MaxRunning)
		{
			error.Set("Too many builds are running; wait for one to finish.");
			return false;
		}
		let job = new BuildJob();
		job.Target = target;
		job.Output.Set(output);
		job.ProjectPath.Set(project.Path);
		let name = target.ToString(.. scope .())..ToLower();
		Directory.CreateDirectory(scope $"{project.Path}/build").IgnoreError();
		job.LogPath.AppendF("{}/build/build-{}.log", project.Path, name);
		job.PidPath.AppendF("{}/build/build-{}.pid", project.Path, name);
		File.Delete(job.LogPath).IgnoreError();
		File.Delete(job.PidPath).IgnoreError();
		let command = scope String();
		project.BuildPlayerCommand(output, target, iosSimulator, job.LogPath, command);
		job.Step.Set("Starting");
		job.Clock.Start();
		Jobs.Add(job);
		let line = new String();
#if BF_PLATFORM_WINDOWS
		line.Set(command);
#else
		// The shell writes its own number, then becomes the build, so that Cancel can find it (and what it started).
		line.AppendF("echo $$ > ");
		Terminal.Quote(job.PidPath, line);
		line.Append("; exec ");
		line.Append(command);
#endif
		job.Thread = new Thread(new () =>
			{
				bool ok = false;
#if BF_PLATFORM_WINDOWS
				let process = scope SpawnedProcess();
				let start = scope ProcessStartInfo();
				start.SetFileName("cmd.exe");
				start.SetArguments(scope $"/d /s /c \"{line}\"");
				start.UseShellExecute = false;
				start.CreateNoWindow = true;
				if (process.Start(start) case .Ok)
				{
					Volatile.Write(ref job.ProcessId, (int32)process.ProcessId);
					process.WaitFor();
					ok = process.ExitCode == 0;
				}
#else
				ok = Terminal.Run(line) == 0;
#endif
				delete line;
				Volatile.Write(ref job.Status, Volatile.Read(ref job.CancelRequested) ? .Cancelled : ok ? .Succeeded : .Failed);
			});
		job.Thread.Start(false);
		return true;
	}

	/// Stops a build: what it started (compilers, texture tools) is stopped too, and its half-made folders removed.
	public static void Cancel(BuildJob job)
	{
		if (!job.Running)
			return;
		Volatile.Write(ref job.CancelRequested, true);
		job.Step.Set("Cancelling");
#if BF_PLATFORM_WINDOWS
		if (job.ProcessId > 0)
			Terminal.RunDetached(scope $"taskkill /T /F /PID {job.ProcessId}");
#else
		let text = scope String();
		if (File.ReadAllText(job.PidPath, text) case .Ok)
		{
			text.Trim();
			int32 pid = 0;
			if (int32.Parse(text) case .Ok(let value))
				pid = value;
			if (pid <= 0)
				return;
			// Children first, so that none is left running when its parent is gone.
			let command = scope String();
			command.AppendF("kill_tree() {{ for c in $(pgrep -P $1); do kill_tree $c; done; kill -TERM $1 2>/dev/null; }}; kill_tree {}", pid);
			Terminal.RunDetached(command);
		}
#endif
	}

	public static void CancelAll()
	{
		for (let job in Jobs)
			Cancel(job);
	}

	/// Reads each running build's log for its progress, a few times a second. Returns a build that has just ended
	/// (once each), or null.
	public static BuildJob Poll(float dt)
	{
		sPollTimer -= dt;
		let due = sPollTimer <= 0;
		if (due)
			sPollTimer = 0.25f;
		BuildJob finished = null;
		for (let job in Jobs)
		{
			let status = Volatile.Read(ref job.Status);
			if (status == .Running)
			{
				job.Seconds = (float)job.Clock.Elapsed.TotalSeconds;
				if (due && !job.CancelRequested)
					ReadProgress(job);
			}
			else if (!job.Reported)
			{
				job.Reported = true;
				job.Clock.Stop();
				job.Seconds = (float)job.Clock.Elapsed.TotalSeconds;
				if (status == .Succeeded)
				{
					job.Progress = 1;
					job.Step.Set("Done");
				}
				if (status == .Cancelled)
					RemoveLeftovers(job);
				File.Delete(job.PidPath).IgnoreError();
				finished = job;
			}
		}
		return finished;
	}

	static void ReadProgress(BuildJob job)
	{
		let text = scope String();
		if (!(File.ReadAllText(job.LogPath, text) case .Ok))
			return;
		var at = -1;
		for (var i = text.Length - 11; i >= 0; i--)
			if (text[i] == '#' && StringView(text, i, 11) == "##progress ")
			{
				at = i;
				break;
			}
		if (at < 0)
			return;
		var rest = StringView(text, at + 11);
		let end = rest.IndexOf('\n');
		if (end >= 0)
			rest = rest.Substring(0, end);
		rest.Trim();
		let space = rest.IndexOf(' ');
		let number = space < 0 ? rest : rest.Substring(0, space);
		if (float.Parse(number) case .Ok(let value))
			job.Progress = Math.Clamp(value, 0, 1);
		if (space >= 0)
			job.Step.Set(rest.Substring(space + 1));
	}

	/// The log without its progress lines.
	public static void ReadLog(BuildJob job, String outText)
	{
		let text = scope String();
		File.ReadAllText(job.LogPath, text).IgnoreError();
		for (let line in text.Split('\n'))
			if (!line.StartsWith("##progress "))
				outText.Append(line, "\n");
	}

	/// A cancelled export leaves its working folder (<name>-<8 hex digits>, <name>-android-...) beside the output.
	static void RemoveLeftovers(BuildJob job)
	{
		let output = scope String(job.Output);
		while (output.EndsWith('/') || output.EndsWith('\\'))
			output.RemoveFromEnd(1);
		let parent = scope String();
		Path.GetDirectoryPath(output, parent);
		let name = scope String();
		Path.GetFileName(output, name);
		if (parent.IsEmpty || name.IsEmpty)
			return;
		let doomed = scope List<String>();
		defer { for (let d in doomed) delete d; }
		for (let entry in Directory.EnumerateDirectories(parent))
		{
			let folder = entry.GetFileName(.. scope .());
			if (!folder.StartsWith(name) || folder.Length <= name.Length + 1 || folder[name.Length] != '-')
				continue;
			let suffix = StringView(folder, name.Length + 1);
			bool hex = suffix.Length == 8;
			for (let c in suffix.RawChars)
				if (!c.IsDigit && !(c >= 'a' && c <= 'f'))
					hex = false;
			if (hex || suffix.StartsWith("android-"))
				doomed.Add(entry.GetFilePath(.. new .()));
		}
		for (let path in doomed)
			Directory.DelTree(path).IgnoreError();
	}
}
