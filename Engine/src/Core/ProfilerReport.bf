using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// A plain-text report of a capture (docs/profiler.md), to read or to give someone (or an AI assistant) debugging a
/// slow game: frame-time spread, the slowest frames with their call trees, the markers that cost most on average,
/// every thread, GPU passes and every counter. Written from Window > Profiler > Export Report, or with
/// `--profile-report <file>` on any build when it quits.
extension ProfilerCapture
{
	static void ReportTime(String text, double nanoseconds)
	{
		text.AppendF("{:0.000} ms", nanoseconds / 1.0e6);
	}

	static double Percentile(List<int64> sorted, double fraction)
	{
		if (sorted.IsEmpty)
			return 0;
		return sorted[Math.Clamp((int)(fraction * (sorted.Count - 1) + 0.5), 0, sorted.Count - 1)];
	}

	/// The report, `slowest` frames shown in full.
	public void WriteReport(String text, int slowest = 5)
	{
		text.Append("# Tallow Profiler report\n\n");
		if (frames.IsEmpty)
		{
			text.Append("No frames were recorded.\n");
			return;
		}
		text.AppendF("Frames {} to {} ({} recorded). Times are on the recording machine; GPU times lag the CPU by a frame or two.\n", frames.Front.index, frames.Back.index, frames.Count);
		text.Append("Self time = time in a marker less the markers inside it. 'Present (waiting for the GPU)' and 'Sleep' are idle waits, not work.\n\n");

		// ---- spread of frame times ----
		text.Append("## Frame times\n\n| | average | median | 95% | 99% | worst | best |\n|---|---|---|---|---|---|---|\n");
		void Spread(StringView label, delegate int64(ProfilerFrame) pick)
		{
			let values = scope List<int64>();
			double sum = 0;
			for (let frame in frames)
			{
				let value = pick(frame);
				if (value > 0)
				{
					values.Add(value);
					sum += value;
				}
			}
			if (values.IsEmpty)
			{
				text.AppendF("| {} | not recorded | | | | | |\n", label);
				return;
			}
			values.Sort();
			text.AppendF("| {} | ", label);
			ReportTime(text, sum / values.Count);
			for (let at in double[?](0.5, 0.95, 0.99, 1.0))
			{
				text.Append(" | ");
				ReportTime(text, Percentile(values, at));
			}
			text.Append(" | ");
			ReportTime(text, values[0]);
			text.Append(" |\n");
		}
		Spread("Frame interval (what players see)", scope (frame) => frame.interval);
		Spread("CPU main thread", scope (frame) => frame.cpuTime);
		Spread("GPU", scope (frame) => frame.gpuTime);
		var spikes = 0;
		let intervals = scope List<int64>();
		for (let frame in frames)
			intervals.Add(frame.interval);
		intervals.Sort();
		let median = Percentile(intervals, 0.5);
		for (let frame in frames)
		{
			if (median > 0 && frame.interval > median * 2)
				spikes++;
		}
		text.AppendF("\nSpikes (frames taking over twice the median interval): {}.\n\n", spikes);

		// ---- time by category ----
		text.Append("## Main thread by category (average self time per frame)\n\n");
		int64[16] times = default;
		double[16] sums = default;
		for (let frame in frames)
		{
			frame.CategoryTimes(this, 0, times);
			for (int c < 16)
				sums[c] += times[c];
		}
		let order = scope List<int>();
		for (int c < 16)
		{
			if (sums[c] > 0)
				order.Add(c);
		}
		order.Sort(scope (a, b) => sums[b] <=> sums[a]);
		for (let c in order)
		{
			text.AppendF("- {}: ", (ProfilerCategory)c);
			ReportTime(text, sums[c] / frames.Count);
			text.Append('\n');
		}
		text.Append('\n');

		// ---- markers over all frames ----
		let rows = scope List<ProfilerRow>();
		for (int32 thread < (int32)threads.Count)
		{
			// Per marker: total, self, calls, worst total in one frame, frames it ran in.
			let byMarker = scope Dictionary<int32, (double total, double self, int64 calls, int64 worst, int32 frames)>();
			for (let frame in frames)
			{
				frame.Hierarchy(thread, rows);
				let seen = scope HashSet<int32>();
				let frameTotals = scope Dictionary<int32, int64>();
				for (let row in rows)
				{
					byMarker.TryGetValue(row.marker, var entry);
					entry.self += row.self;
					entry.calls += row.calls;
					frameTotals.TryGetValue(row.marker, var frameTotal);
					// Count a marker's time once where it nests inside itself.
					var nested = false;
					var parent = row.parent;
					while (parent >= 0)
					{
						if (rows[parent].marker == row.marker)
						{
							nested = true;
							break;
						}
						parent = rows[parent].parent;
					}
					if (!nested)
					{
						entry.total += row.total;
						frameTotals[row.marker] = frameTotal + row.total;
					}
					if (seen.Add(row.marker))
						entry.frames++;
					byMarker[row.marker] = entry;
				}
				for (let (marker, total) in frameTotals)
				{
					var entry = byMarker[marker];
					entry.worst = Math.Max(entry.worst, total);
					byMarker[marker] = entry;
				}
			}
			if (byMarker.IsEmpty)
				continue;
			let markers = scope List<int32>();
			for (let marker in byMarker.Keys)
				markers.Add(marker);
			markers.Sort(scope (a, b) => byMarker[b].self <=> byMarker[a].self);
			text.AppendF("## Thread '{}': markers by average self time per frame\n\n", ThreadName(thread));
			text.Append("| marker | category | self/frame | total/frame | calls/frame | worst frame total | in frames |\n|---|---|---|---|---|---|---|\n");
			for (int i < Math.Min(markers.Count, thread == 0 ? 40 : 15))
			{
				let marker = markers[i];
				let entry = byMarker[marker];
				text.AppendF("| {} | {} | ", NameOf(marker), CategoryOf(marker));
				ReportTime(text, entry.self / frames.Count);
				text.Append(" | ");
				ReportTime(text, entry.total / frames.Count);
				text.AppendF(" | {:0.##} | ", entry.calls / (double)frames.Count);
				ReportTime(text, entry.worst);
				text.AppendF(" | {}/{} |\n", entry.frames, frames.Count);
			}
			text.Append('\n');
		}

		// ---- the slowest frames in full ----
		let bySlowness = scope List<ProfilerFrame>(frames.GetEnumerator());
		bySlowness.Sort(scope (a, b) => Math.Max(b.interval, b.cpuTime) <=> Math.Max(a.interval, a.cpuTime));
		text.AppendF("## The {} slowest frames (main thread call tree, rows over 0.05 ms)\n\n", Math.Min(slowest, bySlowness.Count));
		for (int i < Math.Min(slowest, bySlowness.Count))
		{
			let frame = bySlowness[i];
			text.AppendF("### Frame {}: interval ", frame.index);
			ReportTime(text, frame.interval);
			text.Append(", CPU ");
			ReportTime(text, frame.cpuTime);
			text.Append(", GPU ");
			if (frame.gpuTime > 0)
				ReportTime(text, frame.gpuTime);
			else
				text.Append("-");
			text.Append("\n\n```\n");
			frame.Hierarchy(0, rows);
			let children = scope List<List<int32>>();
			defer
			{
				ClearAndDeleteItems!(children);
			}
			for (int r <= rows.Count)
				children.Add(new .());
			for (int r < rows.Count)
				children[rows[r].parent < 0 ? rows.Count : rows[r].parent].Add((int32)r);
			for (let list in children)
				list.Sort(scope (a, b) => rows[b].total <=> rows[a].total);
			void Tree(int32 index)
			{
				let row = rows[index];
				if (row.total < 50000)
					return;
				text.Append(' ', row.depth * 2);
				text.AppendF("{}  total ", NameOf(row.marker));
				ReportTime(text, row.total);
				text.Append(", self ");
				ReportTime(text, row.self);
				if (row.calls > 1)
					text.AppendF(", {} calls", row.calls);
				text.Append('\n');
				for (let child in children[index])
					Tree(child);
			}
			for (let top in children[rows.Count])
				Tree(top);
			// Other threads busy in this frame.
			let busy = scope Dictionary<int32, int64>();
			for (let sample in frame.samples)
			{
				if (sample.thread != 0 && sample.depth == 0)
				{
					busy.TryGetValue(sample.thread, var time);
					busy[sample.thread] = time + sample.duration;
				}
			}
			for (let (thread, time) in busy)
			{
				text.AppendF("[{} busy ", ThreadName(thread));
				ReportTime(text, time);
				text.Append("]\n");
			}
			if (!frame.passes.IsEmpty)
			{
				text.Append("GPU passes:");
				for (let pass in frame.passes)
				{
					text.AppendF(" {} ", NameOf(pass.pass));
					ReportTime(text, pass.time);
					text.Append(';');
				}
				text.Append('\n');
			}
			text.Append("```\n\n");
		}

		// ---- GPU passes ----
		let passTimes = scope Dictionary<int32, (double sum, int64 worst, int32 count)>();
		for (let frame in frames)
		{
			for (let pass in frame.passes)
			{
				passTimes.TryGetValue(pass.pass, var entry);
				entry.sum += pass.time;
				entry.worst = Math.Max(entry.worst, pass.time);
				entry.count++;
				passTimes[pass.pass] = entry;
			}
		}
		if (!passTimes.IsEmpty)
		{
			text.Append("## GPU passes (bgfx views)\n\n| pass | average | worst |\n|---|---|---|\n");
			let passes = scope List<int32>();
			for (let pass in passTimes.Keys)
				passes.Add(pass);
			passes.Sort(scope (a, b) => passTimes[b].sum <=> passTimes[a].sum);
			for (let pass in passes)
			{
				let entry = passTimes[pass];
				text.AppendF("| {} | ", NameOf(pass));
				ReportTime(text, entry.sum / frames.Count);
				text.Append(" | ");
				ReportTime(text, entry.worst);
				text.Append(" |\n");
			}
			text.Append('\n');
		}

		// ---- counters ----
		text.Append("## Counters (first, lowest, average, highest, last)\n\n");
		for (int c < 16)
		{
			var header = false;
			for (int32 id < (int32)names.Count)
			{
				if (KindOf(id) != .Counter || (int)CategoryOf(id) != c || names[id].text == null)
					continue;
				var low = double.MaxValue, high = -double.MaxValue, sum = 0.0, first = double.NaN, last = 0.0;
				var seen = 0;
				for (let frame in frames)
				{
					let value = frame.Counter(id, double.NaN);
					if (value.IsNaN)
						continue;
					if (first.IsNaN)
						first = value;
					last = value;
					low = Math.Min(low, value);
					high = Math.Max(high, value);
					sum += value;
					seen++;
				}
				if (seen == 0)
					continue;
				if (!header)
				{
					text.AppendF("{}:\n", (ProfilerCategory)c);
					header = true;
				}
				let unit = UnitOf(id);
				text.AppendF("- {}{}{}: {:0.###}, {:0.###}, {:0.###}, {:0.###}, {:0.###}\n", NameOf(id), unit.IsEmpty ? "" : " in ", unit, first, low, sum / seen, high, last);
			}
		}
		text.Append("\nCounters in bytes are plain byte counts. Memory that grows from first to last without coming down can be a leak.\n");
	}

	public bool SaveReport(StringView path, int slowest = 5)
	{
		let text = scope String();
		WriteReport(text, slowest);
		return File.WriteAllText(path, text) case .Ok;
	}
}
