using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace ProfilerTests;

/// A script whose Update the Profiler times by type.
[Component]
class Spinner : Component
{
	public int32 updates;

	public override void Update()
	{
		updates++;
	}
}

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static void Spin(int64 nanoseconds)
	{
		let until = Profiler.Now + nanoseconds;
		while (Profiler.Now < until)
		{
		}
	}

	/// The row of a marker under a parent row (-1: the top), or -1.
	static int32 RowOf(List<ProfilerRow> rows, int32 marker, int32 parent)
	{
		for (int i < rows.Count)
		{
			if (rows[i].marker == marker && rows[i].parent == parent)
				return (int32)i;
		}
		return -1;
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		Profiler.NameThread("Main Thread");
		ProfilerModules.Install();
		let capture = Profiler.Local;
		capture.limit = 300;
		let outer = Profiler.Marker("Outer", .Scripts);
		let inner = Profiler.Marker("Inner", .Physics);
		let other = Profiler.Marker("Other", .AI);
		let counter = Profiler.Counter("Things", .Scripts);
		let summed = Profiler.Counter("Summed", .Scripts, "bytes");

		// ---- off: nothing recorded ----
		Profiler.BeginFrame();
		Profiler.Begin(outer);
		Profiler.End();
		Profiler.EndFrame();
		ok &= Check(capture.frames.IsEmpty && Profiler.Marker("Outer") == outer, "nothing is recorded while the Profiler is off, and a name keeps its id");

		// ---- nesting, the hierarchy, counters ----
		Profiler.Enabled = true;
		Profiler.BeginFrame();
		Profiler.Begin(outer);
		Spin(200000);
		for (int i < 2)
		{
			Profiler.Begin(inner);
			Spin(300000);
			Profiler.End();
		}
		Profiler.Begin(other);
		Profiler.Begin(inner);
		Spin(100000);
		Profiler.End();
		Profiler.End();
		Profiler.End();
		Profiler.Set(counter, 5);
		Profiler.Set(counter, 7);
		Profiler.Add(summed, 2);
		Profiler.Add(summed, 3);
		Profiler.EndFrame(1234);
		ok &= Check(capture.frames.Count == 1, "a frame is recorded once it is on");
		let frame = capture.frames.Back;
		let rows = scope List<ProfilerRow>();
		frame.Hierarchy(0, rows);
		let frameRow = RowOf(rows, Profiler.Marker("Frame"), -1);
		let outerRow = RowOf(rows, outer, frameRow);
		let innerRow = RowOf(rows, inner, outerRow);
		let otherRow = RowOf(rows, other, outerRow);
		let deepRow = RowOf(rows, inner, otherRow);
		ok &= Check(frameRow >= 0 && outerRow >= 0 && innerRow >= 0 && otherRow >= 0 && deepRow >= 0, "the hierarchy nests Frame > Outer > Inner and Outer > Other > Inner");
		if (innerRow >= 0 && deepRow >= 0 && outerRow >= 0 && otherRow >= 0)
		{
			ok &= Check(rows[innerRow].calls == 2 && rows[deepRow].calls == 1 && rows[outerRow].calls == 1, "calls of a marker under one parent merge into one row (2 calls), apart from the same marker elsewhere");
			let o = rows[outerRow];
			ok &= Check(o.self == o.total - rows[innerRow].total - rows[otherRow].total && o.self >= 150000 && rows[innerRow].total >= 600000, scope $"self time is total less the rows under it (outer {o.total / 1000} us, self {o.self / 1000} us)");
			ok &= Check(rows[otherRow].self < rows[otherRow].total && rows[deepRow].total >= 100000, "a row's self time leaves out its children's");
		}
		ok &= Check(frame.Counter(counter) == 7 && frame.Counter(summed) == 5 && capture.UnitOf(summed) == "bytes", "Set keeps the last value, Add sums, and a counter keeps its unit");
		ok &= Check(frame.gpuTime == 1234 && frame.cpuTime >= frame.TimeOf(outer) && frame.interval > 0, "the frame keeps its GPU time, CPU time and interval");
		int64[16] categories = default;
		frame.CategoryTimes(capture, 0, categories);
		ok &= Check(categories[(int)ProfilerCategory.Physics] == rows[innerRow].total + rows[deepRow].total && categories[(int)ProfilerCategory.AI] == rows[otherRow].self, "each category gets its markers' self time");

		Profiler.BeginFrame();
		Profiler.EndFrame();
		ok &= Check(capture.frames.Back.Counter(counter, -1) == -1, "counters start again each frame");

		// ---- other threads: job workers labelled with the caller's marker, a sample cut at the frame's end ----
		let pathMarker = Profiler.Marker("Find Paths", .AI);
		Profiler.BeginFrame();
		Profiler.Begin(pathMarker);
		Jobs.For(64, scope (index) =>
			{
				Spin(50000);
			}
			);
		Profiler.End();
		Profiler.EndFrame();
		var workers = 0;
		var labelled = true;
		for (let sample in capture.frames.Back.samples)
		{
			if (sample.thread != 0)
			{
				workers++;
				labelled &= sample.marker == pathMarker && capture.ThreadName(sample.thread).StartsWith("Job ");
			}
		}
		ok &= Check(Jobs.ThreadCount == 1 || (workers > 0 && labelled), scope $"job workers' time shows under the caller's marker, on named threads ({workers} samples)");

		let long = Profiler.Marker("Long Work", .Assets);
		var started = false;
		var finish = false;
		let thread = scope Thread(new [&] () =>
			{
				Profiler.NameThread("Worker");
				Profiler.Begin(long);
				started = true;
				while (!finish)
					Thread.Sleep(1);
				Spin(200000);
				Profiler.End();
			});
		thread.Start(false);
		while (!started)
			Thread.Sleep(1);
		Profiler.BeginFrame();
		Spin(300000);
		Profiler.EndFrame();
		let first = capture.frames.Back;
		finish = true;
		thread.Join();
		Profiler.BeginFrame();
		Profiler.EndFrame();
		let second = capture.frames.Back;
		ok &= Check(first.TimeOf(long) > 0 && second.TimeOf(long) >= 200000, scope $"a sample open across a frame's end is cut there and goes on in the next ({first.TimeOf(long) / 1000} us, then {second.TimeOf(long) / 1000} us)");

		// ---- components timed by type ----
		let scene = scope Scene();
		Scene.Active = scene;
		for (int i < 3)
			scene.CreateGameObject("Spinner").AddComponent<Spinner>();
		scene.StartPlay();
		Profiler.BeginFrame();
		scene.Update();
		Profiler.EndFrame();
		let spinner = capture.Find("Spinner.Update()");
		frame.Hierarchy(0, rows);
		capture.frames.Back.Hierarchy(0, rows);
		var spinnerCalls = 0;
		for (let row in rows)
		{
			if (row.marker == spinner)
				spinnerCalls += row.calls;
		}
		ok &= Check(spinner >= 0 && spinnerCalls == 3 && capture.CategoryOf(spinner) == .Scripts, scope $"each component type's Update is a marker with a call per component ({spinnerCalls} calls), game code under Scripts");
		ok &= Check(capture.frames.Back.Counter(capture.Find("Components")) >= 3 && capture.frames.Back.Counter(capture.Find("Game Objects")) == 3, "the modules count the scene's objects and components");

		// ---- the history and the file ----
		capture.limit = 5;
		for (int i < 8)
		{
			Profiler.BeginFrame();
			Profiler.EndFrame();
		}
		ok &= Check(capture.frames.Count == 5 && capture.frames.Back.index == Time.FrameCount, "the history keeps the newest frames up to its limit");
		Profiler.BeginFrame();
		Profiler.Begin(outer);
		Profiler.Set(counter, 42);
		Profiler.End();
		Profiler.EndFrame(99);
		let path = "/tmp/tallow-profiler-test.tprofile";
		defer
		{
			System.IO.File.Delete(path);
		}
		ok &= Check(capture.Save(path), "a capture saves");
		let loaded = scope ProfilerCapture();
		ok &= Check(loaded.Load(path) && loaded.frames.Count == capture.frames.Count, "and loads with every frame");
		var same = loaded.NameOf(outer) == "Outer" && loaded.CategoryOf(inner) == .Physics && loaded.ThreadName(0) == "Main Thread";
		let a = capture.frames.Back, b = loaded.frames.Back;
		same &= a.samples.Count == b.samples.Count && a.gpuTime == b.gpuTime && b.Counter(counter) == 42 && a.cpuTime == b.cpuTime;
		for (int i < Math.Min(a.samples.Count, b.samples.Count))
			same &= a.samples[i].marker == b.samples[i].marker && a.samples[i].duration == b.samples[i].duration && a.samples[i].depth == b.samples[i].depth;
		ok &= Check(same, "names, threads, samples and counters come back the same");
		let report = scope String();
		capture.WriteReport(report);
		ok &= Check(report.Contains("## Frame times") && report.Contains("| Outer | Scripts |") && report.Contains("slowest frames") && report.Contains("- Things: ") && report.Contains("Main Thread"), "a text report has the frame times, the markers, the slowest frames and the counters");
		uint8[?] garbage = .(3, 1, 2);
		let broken = scope ProfilerCapture();
		ok &= Check(!broken.Read(garbage) && broken.frames.IsEmpty, "a broken record is refused");

		// ---- memory snapshots ----
		let before = scope ProfilerMemorySnapshot();
		before.Add("Texture", "a.png", 1000);
		before.Add("Texture", "gone.png", 500);
		let after = scope ProfilerMemorySnapshot();
		after.Add("Texture", "a.png", 1500);
		after.Add("Mesh", "new.glb", 2000);
		let changes = scope List<(String kind, String name, int64 change)>();
		after.Compare(before, changes);
		ok &= Check(changes.Count == 3 && changes[0].name == "new.glb" && changes[0].change == 2000 && changes[1].change == 500 && changes[2].name == "gone.png" && changes[2].change == -500, "comparing snapshots lists what grew, what is new and what went, largest first");
		let taken = ProfilerMemorySnapshot.Take("now");
		defer delete taken;
		ok &= Check(ProfilerModules.ProcessMemory() > 0 && taken.Total("Totals") > 0, scope $"a snapshot reads the process's memory ({ProfilerModules.ProcessMemory() / (1024 * 1024)} MB)");

		// ---- an editor watching over the network ----
		capture.limit = 300;
		let port = (uint16)(7800 + (Platform.BfpProcess_GetCurrentId() % 100));
		ok &= Check(ProfilerServer.Listen(port), "the profiler listens for an editor");
		Profiler.Enabled = false;
		let client = scope ProfilerClient();
		client.Connect("127.0.0.1", port);
		for (int i = 0; i < 200 && !(client.Connected && Profiler.Enabled); i++)
		{
			ProfilerServer.Update();
			client.Update(5);
		}
		ok &= Check(client.Connected && Profiler.Enabled && ProfilerServer.Watchers == 1, "an editor connects, and recording starts for it");
		let late = Profiler.Marker("Made After Connecting", .Networking);
		for (int i = 0; i < 200 && client.capture.frames.Count < 3; i++)
		{
			ProfilerServer.Update();
			Profiler.BeginFrame();
			Profiler.Begin(late);
			Profiler.End();
			Profiler.EndFrame();
			client.Update(5);
		}
		let remote = client.capture;
		ok &= Check(remote.frames.Count >= 3 && remote.NameOf(late) == "Made After Connecting" && remote.NameOf(outer) == "Outer" && remote.frames.Back.TimeOf(late) >= 0 && remote.ThreadName(0) == "Main Thread", scope $"it is sent the frames, with names made before and after it came ({remote.frames.Count} frames, {client.received} bytes)");
		client.SetRecording(false);
		for (int i = 0; i < 200 && Profiler.Enabled; i++)
		{
			ProfilerServer.Update();
			client.Update(5);
		}
		ok &= Check(!Profiler.Enabled, "and it can stop the recording");
		client.Disconnect();
		ProfilerServer.Stop();

		Console.WriteLine(ok ? "ALL PASS" : "SOME FAILED");
		return ok ? 0 : 1;
	}
}
