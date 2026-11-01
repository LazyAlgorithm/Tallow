using System;
using System.Collections;
using System.IO;

namespace Tallow.Editor;

/// Window > Profiler (docs/profiler.md): a timeline of recorded frames with a chart for each module (CPU by category,
/// GPU by pass, rendering, memory, physics, animation, audio, networking, AI, UI, particles, assets, scripts, jobs), and
/// the picked frame's hierarchy, per-thread timeline, GPU passes, counters and memory snapshots. It records this editor
/// (edit and play mode), a running build or server attached over the network, or a saved .tprofile capture.
extension EditorApp
{
	bool mShowProfiler;
	/// Where frames come from: 0 this editor, 1 an attached build, 2 a loaded file.
	int32 mProfilerSource;
	bool mProfilerRecording;
	/// Record only while the scene is playing.
	bool mProfilerPlayOnly;
	/// The picked frame's number, or -1 to follow the newest.
	int64 mProfilerFrame = -1;
	int32 mProfilerTab;
	int32 mProfilerThread;
	/// Which module charts are shown (bit per module).
	int32 mProfilerModules = 0x7;
	ProfilerClient mProfilerClient ~ delete _;
	ProfilerCapture mProfilerFile ~ delete _;
	String mProfilerAddress = new .("127.0.0.1") ~ delete _;
	String mProfilerPort = new .("7741") ~ delete _;
	String mProfilerSavePath = new .() ~ delete _;
	String mProfilerFilter = new .() ~ delete _;
	String mProfilerStatus = new .() ~ delete _;
	/// Hierarchy rows the user opened, by path.
	HashSet<int64> mProfilerOpen = new .() ~ delete _;
	List<ProfilerRow> mProfilerRows = new .() ~ delete _;
	float mProfilerZoom = 1;
	float mProfilerScroll;
	float mProfilerDragX;
	List<ProfilerMemorySnapshot> mProfilerSnapshots = new .() ~ DeleteContainerAndItems!(_);
	int32 mProfilerSnapshotA = -1, mProfilerSnapshotB = -1;
	/// --profiler-report <file>: written with the --profiler-test check.
	String mProfilerReportPath = new .() ~ delete _;
	/// --profiler-test: frames left before the check.
	int32 mProfilerTestFrames = -1;

	static StringView[?] sProfilerModuleNames = .("CPU Usage", "GPU", "Rendering", "Memory", "Physics", "Animation", "Audio", "Networking", "AI", "UI", "Particles", "Assets", "Scripts", "Jobs");
	/// The counter category each module after CPU and GPU shows.
	static ProfilerCategory[?] sProfilerModuleCategories = .(.Other, .Rendering, .Rendering, .Memory, .Physics, .Animation, .Audio, .Networking, .AI, .UI, .Particles, .Assets, .Scripts, .Jobs);
	static StringView[?] sProfilerTabs = .("Hierarchy", "Timeline", "GPU Passes", "Counters", "Memory");

	/// A colour for each category, picked to tell apart on dark and light themes.
	public static Color ProfilerColor(ProfilerCategory category)
	{
		switch (category)
		{
		case .Scripts: return .(0.32f, 0.56f, 0.95f, 1);
		case .Rendering: return .(0.36f, 0.76f, 0.40f, 1);
		case .Physics: return .(0.95f, 0.60f, 0.25f, 1);
		case .Animation: return .(0.70f, 0.46f, 0.92f, 1);
		case .Audio: return .(0.25f, 0.76f, 0.76f, 1);
		case .Networking: return .(0.92f, 0.80f, 0.28f, 1);
		case .AI: return .(0.92f, 0.45f, 0.62f, 1);
		case .UI: return .(0.55f, 0.82f, 0.98f, 1);
		case .Particles: return .(0.96f, 0.74f, 0.56f, 1);
		case .Assets: return .(0.70f, 0.55f, 0.38f, 1);
		case .Jobs: return .(0.52f, 0.60f, 0.82f, 1);
		case .Memory: return .(0.78f, 0.78f, 0.80f, 1);
		case .Editor: return .(0.62f, 0.62f, 0.76f, 1);
		case .Waiting: return .(0.42f, 0.42f, 0.46f, 1);
		default: return .(0.58f, 0.60f, 0.64f, 1);
		}
	}

	/// A steady colour for a name (GPU passes, counters' lines).
	static Color ProfilerHashColor(StringView name)
	{
		var hash = (uint32)2166136261;
		for (let c in name.RawChars)
			hash = (hash ^ (uint32)c) * 16777619;
		return Color.FromHSV((hash % 360) / 360.0f, 0.55f, 0.92f);
	}

	ProfilerCapture ProfilerShown
	{
		get
		{
			switch (mProfilerSource)
			{
			case 1: return mProfilerClient?.capture ?? Profiler.Local;
			case 2: return mProfilerFile ?? Profiler.Local;
			default: return Profiler.Local;
			}
		}
	}

	static void ProfilerTime(String text, int64 nanoseconds)
	{
		let ms = nanoseconds / 1.0e6;
		if (ms >= 100)
			text.AppendF("{:0} ms", ms);
		else if (ms >= 1)
			text.AppendF("{:0.00} ms", ms);
		else
			text.AppendF("{:0.0} us", nanoseconds / 1.0e3);
	}

	static void ProfilerValue(String text, double value, StringView unit)
	{
		if (unit.StartsWith("bytes"))
		{
			let rest = unit.Substring(5);
			if (Math.Abs(value) >= 1024.0 * 1024 * 1024)
				text.AppendF("{:0.00} GB", value / (1024.0 * 1024 * 1024));
			else if (Math.Abs(value) >= 1024.0 * 1024)
				text.AppendF("{:0.0} MB", value / (1024.0 * 1024));
			else if (Math.Abs(value) >= 1024)
				text.AppendF("{:0.0} KB", value / 1024.0);
			else
				text.AppendF("{:0} B", value);
			text.Append(rest);
			return;
		}
		if (value == Math.Round(value) && Math.Abs(value) < 1e12)
			text.AppendF("{}", (int64)value);
		else
			text.AppendF("{:0.000}", value);
		if (!unit.IsEmpty)
			text.AppendF(" {}", unit);
	}

	/// Starts or stops recording this editor (as the Record button does; also for --profiler-test).
	void ProfilerRecord(bool on)
	{
		mProfilerRecording = on;
		if (mProfilerSource == 1)
			mProfilerClient?.SetRecording(on);
	}

	/// Test switches: --profiler opens the window recording; --profiler-tab <n> picks a tab (0 Hierarchy, 1 Timeline,
	/// 2 GPU Passes, 3 Counters, 4 Memory, which takes a snapshot); --profiler-attach <host:port> attaches to a build;
	/// --profiler-test records 30 frames and logs PROFILER-TEST PASS or FAIL.
	void ApplyProfilerSwitches()
	{
		let text = scope String();
		if (HasArg("--profiler") || HasArg("--profiler-test"))
		{
			mShowProfiler = true;
			ProfilerRecord(true);
		}
		if (GetArg("--profiler-tab", text))
		{
			mShowProfiler = true;
			mProfilerTab = (int32)Math.Clamp(SceneSerializer.ParseInt(text), 0, sProfilerTabs.Count - 1);
			if (mProfilerTab == 4)
				mProfilerSnapshots.Add(ProfilerMemorySnapshot.Take("At start"));
		}
		if (GetArg("--profiler-attach", text..Clear()))
		{
			mShowProfiler = true;
			mProfilerSource = 1;
			let colon = text.LastIndexOf(':');
			mProfilerAddress.Set(colon > 0 ? text.Substring(0, colon) : text);
			mProfilerPort.Set(colon > 0 ? text.Substring(colon + 1) : "7741");
			mProfilerClient = new .();
			mProfilerClient.Connect(mProfilerAddress, int32.Parse(mProfilerPort) case .Ok(let port) ? (uint16)port : ProfilerServer.DefaultPort);
			mProfilerRecording = true;
		}
		if (HasArg("--profiler-test"))
			mProfilerTestFrames = 30;
		GetArg("--profiler-report", mProfilerReportPath);
	}

	void RunProfilerTest()
	{
		let capture = Profiler.Local;
		let frame = capture.frames.IsEmpty ? null : capture.frames.Back;
		var ok = frame != null && capture.frames.Count >= 20;
		let problems = scope String();
		if (!ok)
			problems.AppendF(" only {} frames recorded;", capture.frames.Count);
		if (frame != null)
		{
			for (let name in StringView[?]("Frame", "Editor.DrawUI", "Render", "Present (waiting for the GPU)"))
			{
				let id = capture.Find(name);
				if (id < 0 || frame.TimeOf(id) <= 0)
				{
					ok = false;
					problems.AppendF(" no {};", name);
				}
			}
			for (let name in StringView[?]("Process Memory", "Draw Calls"))
			{
				if (frame.Counter(capture.Find(name), -1) < 0)
				{
					ok = false;
					problems.AppendF(" no counter {};", name);
				}
			}
			frame.Hierarchy(0, mProfilerRows);
			ok &= !mProfilerRows.IsEmpty;
		}
		var gpu = false;
		for (let other in capture.frames)
			gpu |= other.gpuTime > 0 && !other.passes.IsEmpty;
		if (!mProfilerReportPath.IsEmpty)
			capture.SaveReport(mProfilerReportPath);
		Log.Info(scope $"PROFILER-TEST {ok ? "PASS" : "FAIL"}: {capture.frames.Count} frames, {frame?.samples.Count ?? 0} samples in the last, GPU passes timed: {gpu}.{problems}");
	}

	/// Each editor frame, before anything is drawn: keeps the editor's recording in step with the buttons and takes
	/// what an attached build sent.
	void UpdateProfiler()
	{
		if (mProfilerSource == 0)
			Profiler.Enabled = mProfilerRecording && (!mProfilerPlayOnly || mScene.IsPlaying);
		else if (Profiler.Enabled && !ProfilerServer.Listening)
			Profiler.Enabled = false;
		if (mProfilerClient != null)
			mProfilerClient.Update();
		if (mProfilerTestFrames > 0 && --mProfilerTestFrames == 0)
			RunProfilerTest();
	}

	ProfilerFrame ProfilerPicked(ProfilerCapture capture)
	{
		if (capture.frames.IsEmpty)
			return null;
		if (mProfilerFrame >= 0)
		{
			if (let frame = capture.FrameAt(mProfilerFrame))
				return frame;
		}
		return capture.frames.Back;
	}

	void DrawProfilerWindow()
	{
		if (!mShowProfiler)
			return;
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + 60, viewport.workPos.y + 60), 4);
		ImGui.SetNextWindowSize(.(1100, 760), 4);
		if (ImGui.Begin("Profiler", &mShowProfiler))
		{
			let capture = ProfilerShown;
			DrawProfilerToolbar(capture);
			ImGui.Separator();
			let available = ImGui.GetContentRegionAvail();
			let chartsHeight = Math.Max(available.y * 0.42f, 150);
			if (ImGui.BeginChild("##profiler_charts", .(0, chartsHeight), 1))
				DrawProfilerCharts(capture);
			ImGui.EndChild();
			let frame = ProfilerPicked(capture);
			for (int i < sProfilerTabs.Count)
			{
				if (i > 0)
					ImGui.SameLine();
				if (ImGui.Selectable(scope String(sProfilerTabs[i]).CStr(), mProfilerTab == i, 0, .(ImGui.CalcTextSize(scope String(sProfilerTabs[i]).CStr()).x + 12, 0)))
					mProfilerTab = (int32)i;
			}
			ImGui.SameLine();
			let summary = scope String();
			if (frame != null)
			{
				summary.AppendF("   Frame {}  |  CPU ", frame.index);
				ProfilerTime(summary, frame.cpuTime);
				summary.Append("  |  GPU ");
				if (frame.gpuTime > 0)
					ProfilerTime(summary, frame.gpuTime);
				else
					summary.Append("-");
				summary.Append("  |  every ");
				ProfilerTime(summary, frame.interval);
			}
			else
				summary.Append("   No frames yet: press Record.");
			ImGui.TextDisabled(summary.CStr());
			ImGui.Separator();
			if (ImGui.BeginChild("##profiler_detail", .(0, 0), 0))
			{
				if (frame != null || mProfilerTab == 4)
				{
					switch (mProfilerTab)
					{
					case 0: DrawProfilerHierarchy(capture, frame);
					case 1: DrawProfilerTimeline(capture, frame);
					case 2: DrawProfilerPasses(capture, frame);
					case 3: DrawProfilerCounters(capture, frame);
					default: DrawProfilerMemory();
					}
				}
			}
			ImGui.EndChild();
		}
		ImGui.End();
	}

	void DrawProfilerToolbar(ProfilerCapture capture)
	{
		let recording = mProfilerSource == 2 ? false : (mProfilerSource == 1 ? Profiler.Enabled || mProfilerRecording : mProfilerRecording);
		if (recording)
			ImGui.PushStyleColor(ImGui.Col.Button, .(0.75f, 0.2f, 0.2f, 1));
		if (ImGui.Button(recording ? "Stop" : "Record") && mProfilerSource != 2)
			ProfilerRecord(!mProfilerRecording);
		if (recording)
			ImGui.PopStyleColor();
		ImGui.SameLine();
		if (ImGui.Button("Clear"))
		{
			capture.Clear();
			mProfilerFrame = -1;
		}
		ImGui.SameLine();
		StringView[3] sources = .("This Editor", "Attached Build", "Loaded File");
		ImGui.SetNextItemWidth(130);
		if (ImGui.BeginCombo("##profiler_source", scope String(sources[mProfilerSource]).CStr()))
		{
			for (int32 i < 3)
			{
				if (ImGui.Selectable(scope String(sources[i]).CStr(), mProfilerSource == i))
				{
					mProfilerSource = i;
					mProfilerFrame = -1;
				}
			}
			ImGui.EndCombo();
		}
		ImGui.SameLine();
		if (mProfilerSource == 0)
		{
			ImGui.Checkbox("Play Mode Only", ref mProfilerPlayOnly);
			ImGui.SameLine();
		}
		else if (mProfilerSource == 1)
		{
			ImGui.SetNextItemWidth(120);
			ImGui.InputText("##profiler_address", mProfilerAddress);
			ImGui.SameLine();
			ImGui.SetNextItemWidth(55);
			ImGui.InputText("##profiler_port", mProfilerPort);
			ImGui.SameLine();
			let connected = mProfilerClient != null && (mProfilerClient.Connected || mProfilerClient.Connecting);
			if (ImGui.Button(connected ? "Detach" : "Attach"))
			{
				if (connected)
					mProfilerClient.Disconnect();
				else
				{
					if (mProfilerClient == null)
						mProfilerClient = new .();
					let port = int32.Parse(mProfilerPort) case .Ok(let number) ? (uint16)Math.Clamp(number, 1, 65535) : ProfilerServer.DefaultPort;
					mProfilerClient.Connect(mProfilerAddress, port);
					mProfilerRecording = true;
				}
			}
			ImGui.SameLine();
			let state = scope String();
			if (mProfilerClient == null || (!mProfilerClient.Connected && !mProfilerClient.Connecting))
				state.Append("Not attached (start the game with --profile-listen)");
			else if (mProfilerClient.Connecting)
				state.AppendF("Attaching to {}...", mProfilerClient.address);
			else
				state.AppendF("Attached to {} ({:0.0} MB received)", mProfilerClient.address, mProfilerClient.received / (1024.0 * 1024.0));
			ImGui.TextDisabled(state.CStr());
			ImGui.SameLine();
		}
		ImGui.Checkbox("Each Component", ref Profiler.ComponentSamples);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Times every component's Update, LateUpdate and FixedUpdate by type (turn off for less overhead).");
		ImGui.SameLine();
		if (ImGui.Button("<"))
			ProfilerStep(capture, -1);
		ImGui.SameLine();
		if (ImGui.Button(">"))
			ProfilerStep(capture, 1);
		ImGui.SameLine();
		if (ImGui.Button(mProfilerFrame < 0 ? "Newest (following)" : "Newest"))
			mProfilerFrame = -1;
		ImGui.SameLine();
		if (ImGui.Button("Save"))
			ProfilerSave(capture);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Saves the frames as a .tprofile capture in Profiles/, to load here again.");
		ImGui.SameLine();
		if (ImGui.Button("Export Report"))
			ProfilerSave(capture, true);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Writes a text report (.md) in Profiles/ to read or to give someone debugging: frame times, the slowest frames' call trees, the costliest markers, GPU passes and counters. Also copies it to the clipboard.");
		ImGui.SameLine();
		if (ImGui.BeginCombo("##profiler_load", "Load"))
		{
			let folder = scope String();
			ProfilerFolder(folder);
			var any = false;
			if (Directory.Exists(folder))
			{
				for (let entry in Directory.EnumerateFiles(folder))
				{
					let name = entry.GetFileName(.. scope .());
					if (!name.EndsWith(".tprofile"))
						continue;
					any = true;
					if (ImGui.Selectable(name.CStr()))
						ProfilerLoad(entry.GetFilePath(.. scope .()));
				}
			}
			if (!any)
				ImGui.TextDisabled("No captures in Profiles/ yet (Save makes one).");
			ImGui.EndCombo();
		}
		if (!mProfilerStatus.IsEmpty)
		{
			ImGui.SameLine();
			ImGui.TextDisabled(mProfilerStatus.CStr());
		}
	}

	void ProfilerFolder(String folder)
	{
		folder.Append(Assets.ProjectPath.IsEmpty ? "." : Assets.ProjectPath);
		folder.Append("/Profiles");
	}

	void ProfilerSave(ProfilerCapture capture, bool report = false)
	{
		let folder = scope String();
		ProfilerFolder(folder);
		Directory.CreateDirectory(folder).IgnoreError();
		let now = DateTime.Now;
		mProfilerSavePath.Clear();
		mProfilerSavePath.AppendF("{}/{}-{:D4}{:D2}{:D2}-{:D2}{:D2}{:D2}{}", folder, report ? "report" : "capture", now.Year, now.Month, now.Day, now.Hour, now.Minute, now.Second, report ? ".md" : ".tprofile");
		mProfilerStatus.Clear();
		if (report)
		{
			let text = scope String();
			capture.WriteReport(text);
			if (File.WriteAllText(mProfilerSavePath, text) case .Ok)
			{
				ImGui.SetClipboardText(text.CStr());
				mProfilerStatus.AppendF("Report written to {} and copied", mProfilerSavePath);
			}
			else
				mProfilerStatus.AppendF("Could not write {}", mProfilerSavePath);
			return;
		}
		if (capture.Save(mProfilerSavePath))
			mProfilerStatus.AppendF("Saved {} frames to Profiles/{}", capture.frames.Count, mProfilerSavePath.Substring(folder.Length + 1));
		else
			mProfilerStatus.AppendF("Could not save {}", mProfilerSavePath);
	}

	void ProfilerLoad(StringView path)
	{
		if (mProfilerFile == null)
			mProfilerFile = new .();
		mProfilerStatus.Clear();
		if (mProfilerFile.Load(path))
		{
			mProfilerSource = 2;
			mProfilerFrame = -1;
			mProfilerStatus.AppendF("Loaded {} frames", mProfilerFile.frames.Count);
		}
		else
			mProfilerStatus.AppendF("Could not read {}", path);
	}

	void ProfilerStep(ProfilerCapture capture, int direction)
	{
		if (capture.frames.IsEmpty)
			return;
		var at = capture.frames.Count - 1;
		if (mProfilerFrame >= 0)
		{
			for (int i < capture.frames.Count)
			{
				if (capture.frames[i].index == mProfilerFrame)
					at = i;
			}
		}
		at = Math.Clamp(at + direction, 0, capture.frames.Count - 1);
		mProfilerFrame = capture.frames[at].index;
	}

	/// The module charts, one above another, each with its legend on the left. Clicking one picks a frame.
	void DrawProfilerCharts(ProfilerCapture capture)
	{
		// The modules to show, as a row of toggles.
		for (int i < sProfilerModuleNames.Count)
		{
			if (i > 0)
				ImGui.SameLine();
			var on = (mProfilerModules & (1 << i)) != 0;
			if (ImGui.Checkbox(scope String(sProfilerModuleNames[i])..AppendF("##module{}", i).CStr(), ref on))
				mProfilerModules = on ? (mProfilerModules | (int32)(1 << i)) : (mProfilerModules & ~(int32)(1 << i));
		}
		for (int i < sProfilerModuleNames.Count)
		{
			if ((mProfilerModules & (1 << i)) == 0)
				continue;
			DrawProfilerChart(capture, (int32)i, i == 0 ? 150 : 80);
		}
	}

	void DrawProfilerChart(ProfilerCapture capture, int32 module, float height)
	{
		let legendWidth = 230.0f;
		let start = ImGui.GetCursorScreenPos();
		let width = Math.Max(ImGui.GetContentRegionAvail().x - legendWidth - 4, 50);
		let graphMin = ImGui.Vec2(start.x + legendWidth, start.y);
		let graphMax = ImGui.Vec2(graphMin.x + width, start.y + height);
		ImGui.DrawRectFilled(graphMin, graphMax, EditorTheme.Canvas);
		ImGui.DrawText(.(start.x, start.y), EditorTheme.Accent, scope String(sProfilerModuleNames[module]).CStr());
		let frames = capture.frames;
		let count = frames.Count;
		let picked = ProfilerPicked(capture);
		let barWidth = count > 0 ? width / Math.Max(count, 60) : width;
		float X(int index) => graphMin.x + width - (count - index) * barWidth;
		let legend = scope String();
		let lineHeight = ImGui.GetTextLineHeight();
		var legendY = start.y + lineHeight + 2;
		if (module == 0 || module == 1)
		{
			// Stacked bars: the main thread's time by category, or the GPU's by pass.
			// Scaled to the tallest stack (a frame's categories can add up to more than its own time when a sample
			// was cut at the frame's end), never under 30 or 60 frames a second.
			var top = (module == 0 ? 33.4e6 : 16.7e6);
			int64[16] times = default;
			for (let frame in frames)
			{
				double stack = 0;
				if (module == 0)
				{
					frame.CategoryTimes(capture, 0, times);
					for (let time in times)
						stack += time;
				}
				else
				{
					for (let pass in frame.passes)
						stack += pass.time;
				}
				top = Math.Max(top, Math.Max(stack, module == 0 ? (double)frame.cpuTime : (double)frame.gpuTime));
			}
			ImGui.PushClipRect(graphMin, graphMax);
			for (int i < count)
			{
				let frame = frames[i];
				var y = graphMax.y;
				if (module == 0)
				{
					frame.CategoryTimes(capture, 0, times);
					for (int c < 16)
					{
						if (times[c] <= 0)
							continue;
						let h = (float)(times[c] / top) * height;
						ImGui.DrawRectFilled(.(X(i), y - h), .(X(i) + Math.Max(barWidth - 1, 1), y), ProfilerColor((ProfilerCategory)c));
						y -= h;
					}
				}
				else
				{
					for (let pass in frame.passes)
					{
						let h = (float)(pass.time / top) * height;
						ImGui.DrawRectFilled(.(X(i), y - h), .(X(i) + Math.Max(barWidth - 1, 1), y), ProfilerHashColor(capture.NameOf(pass.pass)));
						y -= h;
					}
					if (frame.passes.IsEmpty && frame.gpuTime > 0)
					{
						let h = (float)(frame.gpuTime / top) * height;
						ImGui.DrawRectFilled(.(X(i), graphMax.y - h), .(X(i) + Math.Max(barWidth - 1, 1), graphMax.y), ProfilerColor(.Rendering));
					}
				}
			}
			// 60 and 30 frames a second.
			for (let mark in double[?](16.67e6, 33.33e6))
			{
				if (mark > top)
					continue;
				let y = graphMax.y - (float)(mark / top) * height;
				ImGui.DrawLine(.(graphMin.x, y), .(graphMax.x, y), .(1, 1, 1, 0.25f));
				// Above the line, or below it when that would leave the chart.
				let labelY = (y - lineHeight < graphMin.y) ? y + 1 : y - lineHeight;
				ImGui.DrawText(.(graphMin.x + 2, labelY), .(1, 1, 1, 0.5f), mark < 20e6 ? "16.7 ms (60 fps)" : "33.3 ms (30 fps)");
			}
			ImGui.PopClipRect();
			// The legend: the picked frame's figures.
			if (picked != null && module == 0)
			{
				picked.CategoryTimes(capture, 0, times);
				for (int c < 16)
				{
					if (times[c] <= 0 || legendY > start.y + height - lineHeight)
						continue;
					legend.Clear();
					legend.AppendF("{}  ", (ProfilerCategory)c);
					ProfilerTime(legend, times[c]);
					ImGui.DrawRectFilled(.(start.x, legendY + 3), .(start.x + 8, legendY + 11), ProfilerColor((ProfilerCategory)c));
					ImGui.DrawText(.(start.x + 12, legendY), EditorTheme.Text, legend.CStr());
					legendY += lineHeight;
				}
			}
			else if (picked != null)
			{
				legend.Clear();
				legend.Append("Frame ");
				if (picked.gpuTime > 0)
					ProfilerTime(legend, picked.gpuTime);
				else
					legend.Append("not timed (no GPU here)");
				ImGui.DrawText(.(start.x, legendY), EditorTheme.Text, legend.CStr());
				legendY += lineHeight;
				for (let pass in picked.passes)
				{
					if (legendY > start.y + height - lineHeight)
						break;
					legend.Clear();
					legend.AppendF("{}  ", capture.NameOf(pass.pass));
					ProfilerTime(legend, pass.time);
					ImGui.DrawRectFilled(.(start.x, legendY + 3), .(start.x + 8, legendY + 11), ProfilerHashColor(capture.NameOf(pass.pass)));
					ImGui.DrawText(.(start.x + 12, legendY), EditorTheme.Text, legend.CStr());
					legendY += lineHeight;
				}
			}
		}
		else
		{
			// Lines: each counter of the module's category, scaled to its own highest value.
			let category = sProfilerModuleCategories[module];
			var shown = 0;
			for (int id < capture.names.Count)
			{
				if (capture.KindOf((int32)id) != .Counter || capture.CategoryOf((int32)id) != category || capture.names[id].text == null)
					continue;
				var high = 0.0;
				var any = false;
				for (let frame in frames)
				{
					let value = frame.Counter((int32)id, double.NaN);
					if (!value.IsNaN)
					{
						high = Math.Max(high, Math.Abs(value));
						any = true;
					}
				}
				if (!any)
					continue;
				let color = ProfilerHashColor(capture.NameOf((int32)id));
				var previous = ImGui.Vec2(0, 0);
				var have = false;
				for (int i < count)
				{
					let value = frames[i].Counter((int32)id, double.NaN);
					if (value.IsNaN)
					{
						have = false;
						continue;
					}
					let point = ImGui.Vec2(X(i) + barWidth * 0.5f, graphMax.y - 2 - (float)(high > 0 ? value / high : 0) * (height - 4));
					if (have)
						ImGui.DrawLine(previous, point, color, 1.5f);
					previous = point;
					have = true;
				}
				if (legendY <= start.y + height - lineHeight)
				{
					legend.Clear();
					legend.AppendF("{}  ", capture.NameOf((int32)id));
					if (picked != null)
						ProfilerValue(legend, picked.Counter((int32)id), capture.UnitOf((int32)id));
					ImGui.DrawRectFilled(.(start.x, legendY + 3), .(start.x + 8, legendY + 11), color);
					ImGui.DrawText(.(start.x + 12, legendY), EditorTheme.Text, legend.CStr());
					legendY += lineHeight;
				}
				shown++;
			}
			if (shown == 0)
				ImGui.DrawText(.(graphMin.x + 8, graphMin.y + 8), EditorTheme.TextDim, "Nothing recorded for this module yet.");
		}
		// The picked frame, and picking one.
		if (picked != null)
		{
			for (int i < count)
			{
				if (frames[i] == picked)
				{
					ImGui.DrawRect(.(X(i) - 1, graphMin.y), .(X(i) + barWidth + 1, graphMax.y), .(1, 1, 1, 0.9f));
					break;
				}
			}
		}
		ImGui.SetCursorScreenPos(graphMin);
		ImGui.InvisibleButton(scope String()..AppendF("##chart{}", module).CStr(), .(width, height));
		if ((ImGui.IsItemHovered() && ImGui.IsMouseDown(0)) && count > 0)
		{
			let mouse = ImGui.GetMousePos();
			let index = Math.Clamp(count - 1 - (int)((graphMax.x - mouse.x) / barWidth), 0, count - 1);
			mProfilerFrame = frames[index].index;
		}
		else if (ImGui.IsItemHovered() && count > 0)
		{
			let mouse = ImGui.GetMousePos();
			let index = count - 1 - (int)((graphMax.x - mouse.x) / barWidth);
			if (index >= 0 && index < count)
			{
				let tip = scope String();
				tip.AppendF("Frame {}: CPU ", frames[index].index);
				ProfilerTime(tip, frames[index].cpuTime);
				if (frames[index].gpuTime > 0)
				{
					tip.Append(", GPU ");
					ProfilerTime(tip, frames[index].gpuTime);
				}
				ImGui.SetTooltip(tip.CStr());
			}
		}
		ImGui.SetCursorScreenPos(.(start.x, graphMax.y + 4));
		ImGui.Dummy(.(1, 1));
	}

	/// The picked frame's merged calls on one thread: name, total and self time (and their share of the frame),
	/// calls. Rows open and close; a filter shows every row whose name matches, flat.
	void DrawProfilerHierarchy(ProfilerCapture capture, ProfilerFrame frame)
	{
		DrawProfilerThreadPicker(capture, frame);
		ImGui.SameLine();
		ImGui.SetNextItemWidth(220);
		ImGui.InputText("##profiler_filter", mProfilerFilter, 0, "Search markers");
		frame.Hierarchy(mProfilerThread, mProfilerRows);
		let rows = mProfilerRows;
		var frameTime = (double)Math.Max(frame.cpuTime, 1);
		if (mProfilerThread != 0)
		{
			int64 busy = 0;
			for (let row in rows)
			{
				if (row.parent < 0)
					busy += row.total;
			}
			frameTime = Math.Max(frameTime, busy);
		}
		// Each row's children, biggest first.
		let children = scope List<List<int32>>();
		defer
		{
			ClearAndDeleteItems!(children);
		}
		for (int i <= rows.Count)
			children.Add(new .());
		for (int i < rows.Count)
			children[rows[i].parent < 0 ? rows.Count : rows[i].parent].Add((int32)i);
		for (let list in children)
			list.Sort(scope (a, b) => rows[b].total <=> rows[a].total);
		if (ImGui.BeginTable("##profiler_hierarchy", 6, ImGui.TableFlags.Resizable | ImGui.TableFlags.RowBg | ImGui.TableFlags.BordersInnerV | ImGui.TableFlags.ScrollY))
		{
			ImGui.TableSetupColumn("Marker", ImGui.ColumnFlags.WidthStretch);
			ImGui.TableSetupColumn("Total %", ImGui.ColumnFlags.WidthFixed, 64);
			ImGui.TableSetupColumn("Self %", ImGui.ColumnFlags.WidthFixed, 64);
			ImGui.TableSetupColumn("Calls", ImGui.ColumnFlags.WidthFixed, 56);
			ImGui.TableSetupColumn("Total", ImGui.ColumnFlags.WidthFixed, 80);
			ImGui.TableSetupColumn("Self", ImGui.ColumnFlags.WidthFixed, 80);
			ImGui.TableHeadersRow();
			let text = scope String();
			void Row(int32 index, int64 path, bool flat)
			{
				let row = rows[index];
				let rowPath = path * 1000003 + row.marker + 1;
				let hasChildren = !children[index].IsEmpty;
				let open = flat || mProfilerOpen.Contains(rowPath);
				ImGui.TableNextRow();
				ImGui.TableNextColumn();
				text.Clear();
				if (!flat)
					text.Append(' ', row.depth * 3);
				text.Append(hasChildren && !flat ? (open ? "v " : "> ") : "  ");
				text.Append(capture.NameOf(row.marker));
				text.AppendF("##row{}", rowPath);
				ImGui.PushStyleColor(ImGui.Col.Text, ProfilerColor(capture.CategoryOf(row.marker)));
				if (ImGui.Selectable(text.CStr(), false, ImGui.SelectableFlags.SpanAllColumns) && hasChildren && !flat)
				{
					if (open)
						mProfilerOpen.Remove(rowPath);
					else
						mProfilerOpen.Add(rowPath);
				}
				ImGui.PopStyleColor();
				ImGui.TableNextColumn();
				ImGui.Text(scope String()..AppendF("{:0.0}%", row.total * 100.0 / frameTime));
				ImGui.TableNextColumn();
				ImGui.Text(scope String()..AppendF("{:0.0}%", row.self * 100.0 / frameTime));
				ImGui.TableNextColumn();
				ImGui.Text(scope String()..AppendF("{}", row.calls));
				ImGui.TableNextColumn();
				text.Clear();
				ProfilerTime(text, row.total);
				ImGui.Text(text);
				ImGui.TableNextColumn();
				text.Clear();
				ProfilerTime(text, row.self);
				ImGui.Text(text);
				if (open && !flat)
				{
					for (let child in children[index])
						Row(child, rowPath, false);
				}
			}
			if (!mProfilerFilter.IsEmpty)
			{
				let matches = scope List<int32>();
				for (int i < rows.Count)
				{
					if (capture.NameOf(rows[i].marker).Contains(mProfilerFilter, true))
						matches.Add((int32)i);
				}
				matches.Sort(scope (a, b) => rows[b].total <=> rows[a].total);
				for (let index in matches)
					Row(index, 0, true);
			}
			else
			{
				// The top rows start open, so a frame shows its main parts at once.
				for (let top in children[rows.Count])
				{
					mProfilerOpen.Add(rows[top].marker + 1);
					Row(top, 0, false);
				}
			}
			ImGui.EndTable();
		}
	}

	void DrawProfilerThreadPicker(ProfilerCapture capture, ProfilerFrame frame)
	{
		ImGui.SetNextItemWidth(160);
		if (ImGui.BeginCombo("##profiler_thread", scope String(capture.ThreadName(mProfilerThread)).CStr()))
		{
			for (int32 i < (int32)capture.threads.Count)
			{
				var used = false;
				for (let sample in frame.samples)
				{
					if (sample.thread == i)
					{
						used = true;
						break;
					}
				}
				let label = scope String(capture.ThreadName(i));
				if (!used)
					label.Append(" (idle)");
				if (ImGui.Selectable(label.CStr(), mProfilerThread == i))
					mProfilerThread = i;
			}
			ImGui.EndCombo();
		}
	}

	/// Every thread's samples across the frame, a lane each, nested downwards (a flame chart per thread). The wheel
	/// zooms about the mouse and dragging moves along.
	void DrawProfilerTimeline(ProfilerCapture capture, ProfilerFrame frame)
	{
		ImGui.TextDisabled("Wheel: zoom.  Drag: move.  Double-click: whole frame.");
		let origin = ImGui.GetCursorScreenPos();
		let size = ImGui.GetContentRegionAvail();
		let width = Math.Max(size.x, 100);
		// The time shown: the frame, and anything on other threads that ran past it.
		var first = 0L, last = Math.Max(frame.cpuTime, 1);
		for (let sample in frame.samples)
		{
			first = Math.Min(first, sample.start);
			last = Math.Max(last, sample.start + sample.duration);
		}
		let span = (double)(last - first);
		let scale = width * mProfilerZoom / span;
		float X(int64 time) => origin.x + (float)((time - first) * scale) - mProfilerScroll;
		// The lanes: threads with samples, main first.
		let lanes = scope List<int32>();
		int32 deepest = 0;
		let depthOf = scope Dictionary<int32, int32>();
		for (let sample in frame.samples)
		{
			if (!lanes.Contains(sample.thread))
				lanes.Add(sample.thread);
			depthOf.TryGetValue(sample.thread, var depth);
			depthOf[sample.thread] = Math.Max(depth, sample.depth + 1);
			deepest = Math.Max(deepest, sample.depth + 1);
		}
		lanes.Sort();
		let rowHeight = ImGui.GetTextLineHeight() + 4;
		var y = origin.y + rowHeight;
		ImGui.PushClipRect(origin, .(origin.x + width, origin.y + size.y));
		// A ruler in milliseconds.
		var step = 1.0e5;
		while (step * scale < 70)
			step *= step < 1e6 ? 5 : 2;
		var tick = Math.Floor(first / step) * step;
		while (X((int64)tick) < origin.x + width)
		{
			let x = X((int64)tick);
			ImGui.DrawLine(.(x, origin.y), .(x, origin.y + size.y), .(1, 1, 1, 0.08f));
			let label = scope String();
			ProfilerTime(label, (int64)tick);
			ImGui.DrawText(.(x + 2, origin.y), EditorTheme.TextDim, label.CStr());
			tick += step;
		}
		var hovered = false;
		let mouse = ImGui.GetMousePos();
		for (let lane in lanes)
		{
			ImGui.DrawText(.(origin.x + 2, y), EditorTheme.Accent, scope String(capture.ThreadName(lane)).CStr());
			y += rowHeight;
			for (let sample in frame.samples)
			{
				if (sample.thread != lane)
					continue;
				let x0 = X(sample.start), x1 = Math.Max(X(sample.start + sample.duration), x0 + 1);
				if (x1 < origin.x || x0 > origin.x + width)
					continue;
				let top = y + sample.depth * rowHeight;
				let color = ProfilerColor(capture.CategoryOf(sample.marker));
				ImGui.DrawRectFilled(.(x0, top), .(x1, top + rowHeight - 1), color);
				if (x1 - x0 > 30)
				{
					let label = scope String(capture.NameOf(sample.marker));
					ImGui.PushClipRect(.(Math.Max(x0, origin.x), top), .(x1, top + rowHeight));
					ImGui.DrawText(.(Math.Max(x0, origin.x) + 3, top + 1), .(0.05f, 0.05f, 0.07f, 1), label.CStr());
					ImGui.PopClipRect();
				}
				if (!hovered && mouse.x >= x0 && mouse.x <= x1 && mouse.y >= top && mouse.y < top + rowHeight && ImGui.IsWindowHovered())
				{
					hovered = true;
					let tip = scope String();
					tip.AppendF("{}  ({}, {})\n", capture.NameOf(sample.marker), capture.CategoryOf(sample.marker), capture.ThreadName(sample.thread));
					ProfilerTime(tip, sample.duration);
					tip.Append(", starting at ");
					ProfilerTime(tip, sample.start);
					ImGui.SetTooltip(tip.CStr());
				}
			}
			depthOf.TryGetValue(lane, let laneDepth);
			y += laneDepth * rowHeight + 6;
		}
		ImGui.PopClipRect();
		ImGui.InvisibleButton("##profiler_timeline", .(width, Math.Max(y - origin.y, size.y - 4)));
		if (ImGui.IsItemHovered())
		{
			let wheel = Input.MouseWheel;
			if (wheel != 0)
			{
				// Zoom about the time under the mouse.
				let at = (mouse.x - origin.x + mProfilerScroll) / mProfilerZoom;
				mProfilerZoom = Math.Clamp(mProfilerZoom * (wheel > 0 ? 1.25f : 0.8f), 1, 20000);
				mProfilerScroll = at * mProfilerZoom - (mouse.x - origin.x);
			}
			if (ImGui.IsMouseDoubleClicked(0))
			{
				mProfilerZoom = 1;
				mProfilerScroll = 0;
			}
		}
		if (ImGui.IsItemActive() && ImGui.IsMouseDragging(0))
			mProfilerScroll -= mouse.x - mProfilerDragX;
		mProfilerDragX = mouse.x;
		mProfilerScroll = Math.Clamp(mProfilerScroll, 0, Math.Max(width * mProfilerZoom - width, 0));
	}

	void DrawProfilerPasses(ProfilerCapture capture, ProfilerFrame frame)
	{
		if (frame.passes.IsEmpty)
		{
			ImGui.TextWrapped("No GPU pass times in this frame. They come from the graphics driver's timers while recording, a frame or two behind the CPU (a dedicated server or a test without a window has none).");
			return;
		}
		int64 total = 0;
		for (let pass in frame.passes)
			total += pass.time;
		let sorted = scope List<(int32 pass, int64 time)>(frame.passes.GetEnumerator());
		sorted.Sort(scope (a, b) => b.time <=> a.time);
		if (ImGui.BeginTable("##profiler_passes", 3, ImGui.TableFlags.RowBg | ImGui.TableFlags.BordersInnerV | ImGui.TableFlags.ScrollY))
		{
			ImGui.TableSetupColumn("Pass (bgfx view)", ImGui.ColumnFlags.WidthStretch);
			ImGui.TableSetupColumn("GPU Time", ImGui.ColumnFlags.WidthFixed, 90);
			ImGui.TableSetupColumn("Share", ImGui.ColumnFlags.WidthFixed, 200);
			ImGui.TableHeadersRow();
			let text = scope String();
			for (let pass in sorted)
			{
				ImGui.TableNextRow();
				ImGui.TableNextColumn();
				ImGui.TextColored(ProfilerHashColor(capture.NameOf(pass.pass)), scope String(capture.NameOf(pass.pass)).CStr());
				ImGui.TableNextColumn();
				text.Clear();
				ProfilerTime(text, pass.time);
				ImGui.Text(text);
				ImGui.TableNextColumn();
				ImGui.ProgressBar((float)(pass.time / (double)Math.Max(total, 1)), .(-1, 0));
			}
			ImGui.TableNextRow();
			ImGui.TableNextColumn();
			ImGui.TextDisabled("All passes");
			ImGui.TableNextColumn();
			text.Clear();
			ProfilerTime(text, total);
			ImGui.Text(text);
			ImGui.EndTable();
		}
	}

	/// Every counter in the picked frame by module, with its lowest, average and highest over the frames kept.
	void DrawProfilerCounters(ProfilerCapture capture, ProfilerFrame frame)
	{
		if (ImGui.BeginTable("##profiler_counters", 5, ImGui.TableFlags.RowBg | ImGui.TableFlags.BordersInnerV | ImGui.TableFlags.ScrollY | ImGui.TableFlags.Resizable))
		{
			ImGui.TableSetupColumn("Counter", ImGui.ColumnFlags.WidthStretch);
			ImGui.TableSetupColumn("This Frame", ImGui.ColumnFlags.WidthFixed, 110);
			ImGui.TableSetupColumn("Lowest", ImGui.ColumnFlags.WidthFixed, 100);
			ImGui.TableSetupColumn("Average", ImGui.ColumnFlags.WidthFixed, 100);
			ImGui.TableSetupColumn("Highest", ImGui.ColumnFlags.WidthFixed, 100);
			ImGui.TableHeadersRow();
			let text = scope String();
			for (int c < (int)ProfilerCategory.Waiting + 1)
			{
				var header = false;
				for (int id < capture.names.Count)
				{
					if (capture.KindOf((int32)id) != .Counter || (int)capture.CategoryOf((int32)id) != c || capture.names[id].text == null)
						continue;
					var low = double.MaxValue, high = -double.MaxValue, sum = 0.0;
					var seen = 0;
					for (let other in capture.frames)
					{
						let value = other.Counter((int32)id, double.NaN);
						if (value.IsNaN)
							continue;
						low = Math.Min(low, value);
						high = Math.Max(high, value);
						sum += value;
						seen++;
					}
					if (seen == 0)
						continue;
					if (!header)
					{
						header = true;
						ImGui.TableNextRow();
						ImGui.TableNextColumn();
						ImGui.TextColored(ProfilerColor((ProfilerCategory)c), scope String()..AppendF("{}", (ProfilerCategory)c).CStr());
					}
					let unit = capture.UnitOf((int32)id);
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.Text(scope String()..AppendF("    {}", capture.NameOf((int32)id)));
					for (let value in double[?](frame.Counter((int32)id, double.NaN), low, sum / seen, high))
					{
						ImGui.TableNextColumn();
						text.Clear();
						if (value.IsNaN)
							text.Append("-");
						else
							ProfilerValue(text, value, unit);
						ImGui.Text(text);
					}
				}
			}
			ImGui.EndTable();
		}
	}

	/// Snapshots of what memory holds (each texture and mesh, and the totals), and the difference between two.
	void DrawProfilerMemory()
	{
		if (ImGui.Button("Take Snapshot"))
		{
			let label = scope String();
			let now = DateTime.Now;
			label.AppendF("{:D2}:{:D2}:{:D2}{}", now.Hour, now.Minute, now.Second, mScene.IsPlaying ? " (playing)" : "");
			mProfilerSnapshots.Add(ProfilerMemorySnapshot.Take(label));
			mProfilerSnapshotB = (int32)mProfilerSnapshots.Count - 1;
		}
		ImGui.SameLine();
		ImGui.TextDisabled(mProfilerSource == 0 ? "of this editor" : "(snapshots are of this editor; an attached build sends its memory counters)");
		if (mProfilerSnapshots.IsEmpty)
		{
			ImGui.TextWrapped("Take a snapshot, do something (load a scene, play), take another, and pick both to see what grew.");
			return;
		}
		void Picker(StringView label, ref int32 index, bool allowNone)
		{
			ImGui.SetNextItemWidth(200);
			let preview = index >= 0 && index < mProfilerSnapshots.Count ? mProfilerSnapshots[index].label : (allowNone ? "(none: just one)" : "");
			if (ImGui.BeginCombo(scope String(label).CStr(), scope String(preview).CStr()))
			{
				if (allowNone && ImGui.Selectable("(none: just one)", index < 0))
					index = -1;
				for (int32 i < (int32)mProfilerSnapshots.Count)
				{
					if (ImGui.Selectable(scope String()..AppendF("{}##snap{}", mProfilerSnapshots[i].label, i).CStr(), index == i))
						index = i;
				}
				ImGui.EndCombo();
			}
		}
		Picker("Snapshot", ref mProfilerSnapshotB, false);
		ImGui.SameLine();
		Picker("Compared with", ref mProfilerSnapshotA, true);
		if (mProfilerSnapshotB < 0 || mProfilerSnapshotB >= mProfilerSnapshots.Count)
			mProfilerSnapshotB = (int32)mProfilerSnapshots.Count - 1;
		let shown = mProfilerSnapshots[mProfilerSnapshotB];
		let text = scope String();
		text.Append("Textures ");
		ProfilerValue(text, shown.Total("Texture"), "bytes");
		text.Append("   Meshes ");
		ProfilerValue(text, shown.Total("Mesh"), "bytes");
		for (let entry in shown.entries)
		{
			if (entry.kind == "Totals")
			{
				text.AppendF("   {} ", entry.name);
				ProfilerValue(text, entry.bytes, "bytes");
			}
		}
		ImGui.TextDisabled(text.CStr());
		let comparing = mProfilerSnapshotA >= 0 && mProfilerSnapshotA < mProfilerSnapshots.Count && mProfilerSnapshotA != mProfilerSnapshotB;
		if (ImGui.BeginTable("##profiler_memory", 3, ImGui.TableFlags.RowBg | ImGui.TableFlags.BordersInnerV | ImGui.TableFlags.ScrollY | ImGui.TableFlags.Resizable))
		{
			ImGui.TableSetupColumn("Kind", ImGui.ColumnFlags.WidthFixed, 80);
			ImGui.TableSetupColumn("Name", ImGui.ColumnFlags.WidthStretch);
			ImGui.TableSetupColumn(comparing ? "Change" : "Size", ImGui.ColumnFlags.WidthFixed, 110);
			ImGui.TableHeadersRow();
			if (comparing)
			{
				let changes = scope List<(String kind, String name, int64 change)>();
				shown.Compare(mProfilerSnapshots[mProfilerSnapshotA], changes);
				for (let change in changes)
				{
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.Text(change.kind);
					ImGui.TableNextColumn();
					ImGui.Text(change.name);
					ImGui.TableNextColumn();
					text.Clear();
					if (change.change > 0)
						text.Append('+');
					ProfilerValue(text, change.change, "bytes");
					ImGui.TextColored(change.change > 0 ? EditorTheme.Warning : EditorTheme.Good, text.CStr());
				}
				if (changes.IsEmpty)
				{
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.TableNextColumn();
					ImGui.TextDisabled("No difference.");
				}
			}
			else
			{
				for (let entry in shown.entries)
				{
					ImGui.TableNextRow();
					ImGui.TableNextColumn();
					ImGui.Text(entry.kind);
					ImGui.TableNextColumn();
					ImGui.Text(entry.name);
					ImGui.TableNextColumn();
					text.Clear();
					ProfilerValue(text, entry.bytes, "bytes");
					ImGui.Text(text);
				}
			}
			ImGui.EndTable();
		}
	}
}
