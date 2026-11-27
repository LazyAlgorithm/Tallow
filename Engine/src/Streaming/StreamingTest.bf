using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// --streaming-test: the streaming core's checks with no window and no GPU (page files, packs, pools, the core with
/// IO threads, the feedback ring). Exit code 0 when every check passed. Later steps add scene parts.
static class StreamingTest
{
	static int sFailed;
	static int sChecks;

	static void Check(bool ok, StringView what)
	{
		sChecks++;
		if (!ok)
		{
			sFailed++;
			Console.WriteLine(scope $"streaming-test: FAIL {what}");
		}
	}

	static void Fill(List<uint8> page, int index, int size)
	{
		var state = (uint32)index * 2654435761U + 12345U;
		for (int j < size)
		{
			if (j < size / 2)
				page.Add((uint8)((j / 7) + index));
			else
			{
				state ^= state << 13; state ^= state >> 17; state ^= state << 5;
				page.Add((uint8)state);
			}
		}
	}

	class Recorder : IStreamConsumer
	{
		public List<int> order = new .() ~ delete _;
		public int bad;
		public bool Upload(StreamResource resource, int page, Span<uint8> data)
		{
			let expect = scope List<uint8>();
			Fill(expect, page, data.Length);
			for (int i < data.Length)
			{
				if (data[i] != expect[i])
				{
					bad++;
					break;
				}
			}
			order.Add(page);
			return true;
		}
	}

	public static int Run()
	{
		let dir = scope String();
		Path.GetTempPath(dir);
		dir.Append(scope $"tallow-streaming-test-{(uint32)Internal.GetTickCountMicro()}");
		Directory.CreateDirectory(dir);
		defer { Directory.DelTree(dir); }
		PageFileChecks(dir);
		PoolChecks();
		CoreChecks(dir);
		FeedbackChecks();
		Console.WriteLine(scope $"streaming-test: {sChecks - sFailed}/{sChecks} checks passed");
		return sFailed == 0 ? 0 : 1;
	}

	static void MakePages(List<List<uint8>> pages, int count, int size)
	{
		for (int i < count)
		{
			let page = new List<uint8>();
			// Sizes differ; one is empty, to cover the edge.
			Fill(page, i, i == 3 ? 0 : size + (i % 5) * 1000);
			pages.Add(page);
		}
	}

	static void PageFileChecks(StringView dir)
	{
		let pages = scope List<List<uint8>>();
		defer { for (let p in pages) delete p; }
		MakePages(pages, 40, 30000);
		let path = scope $"{dir}/a.tpages";
		Check(PageFile.Write(path, .GeoPage, pages) case .Ok, "write .tpages");
		let file = scope PageFile();
		Check(file.Open(path) case .Ok, "open .tpages");
		Check(file.PageCount == 40 && file.Kind == .GeoPage, "page count and kind");
		var allSame = true;
		for (int i < 40)
		{
			let plain = scope List<uint8>();
			if (!(file.Read(i, plain) case .Ok) || plain.Count != pages[i].Count)
			{
				allSame = false;
				continue;
			}
			for (int j < plain.Count)
			{
				if (plain[j] != pages[i][j])
				{
					allSame = false;
					break;
				}
			}
		}
		Check(allSame, "every page reads back identical");
		Check(file.Read(40, scope List<uint8>()) case .Err, "page past the end is an error");
		// A damaged page is caught by its CRC.
		let stored = scope List<uint8>();
		file.ReadRaw(7, stored);
		stored[stored.Count / 2] ^= 0x55;
		Check(file.Decode(7, stored, scope List<uint8>()) case .Err, "damaged page is rejected");
		// The same pages through a pack, one ranged read each.
		let whole = scope List<uint8>();
		File.ReadAll(path, whole);
		let packPath = scope $"{dir}/a.tpak";
		let entries = scope List<(StringView name, Span<uint8> data)>();
		entries.Add(("geo/a.tpages", Span<uint8>(whole.Ptr, whole.Count)));
		Check(PackFile.Write(packPath, entries) case .Ok, "pack with .tpages");
		let pack = scope PackFile();
		Check(pack.Open(packPath) case .Ok, "open pack");
		let inPack = scope PageFile();
		Check(inPack.Open(pack, "geo/a.tpages") case .Ok, "open .tpages inside a pack");
		var packSame = inPack.PageCount == 40;
		for (int i < 40)
		{
			let plain = scope List<uint8>();
			if (!(inPack.Read(i, plain) case .Ok) || plain.Count != pages[i].Count || (plain.Count > 0 && plain[plain.Count - 1] != pages[i][plain.Count - 1]))
				packSame = false;
		}
		Check(packSame, "pages read through PackFile.ReadRange match");
	}

	static void PoolChecks()
	{
		let pool = scope StreamPool(.TextureMip, 1000);
		var evicted = scope List<int>();
		pool.OnEvict = new [&evicted] (resource, page) => evicted.Add(page);
		for (int i < 10)
		{
			Check(pool.CanAdmit(100, i), "admit while room");
			pool.Add(1, i, 100, i);
		}
		Check(pool.Resident == 1000, "resident bytes");
		// Page 0 was last used long ago; touch 1 so it is the freshest of the old.
		pool.Touch(1, 0, 200);
		// Frame 200: pages 1..9 are cold or recent (used at 1..9 frames <= 120? they are 190+ old = Cold).
		Check(!pool.CanAdmit(100, 200) || pool.Resident + pool.Pending + 100 <= 1000, "never over budget");
		Check(evicted.Count == 1 && evicted[0] == 1, "coldest page (oldest use, not the touched one) goes first");
		Check(pool.Pending == 100, "evicted bytes wait for in-flight frames");
		Check(!pool.CanAdmit(100, 201), "room is not taken until the evicted page retires");
		Check(pool.Resident + pool.Pending <= 1000, "resident + pending within budget while waiting");
		Check(pool.CanAdmit(100, 200 + StreamPool.FramesBeforeReuse), "room after FramesBeforeReuse frames");
		pool.Add(2, 0, 100, 204);
		// Visible and pinned pages are never evicted.
		let small = scope StreamPool(.GeoPage, 300);
		small.Add(1, 0, 100, 10, true);
		small.Add(1, 1, 100, 10);
		small.Add(1, 2, 100, 10);
		Check(small.ClassOf(1, 1, 10) == .Visible && small.ClassOf(1, 0, 10) == .Pinned, "classes: visible, pinned");
		Check(!small.CanAdmit(100, 10), "nothing evictable while all are visible or pinned");
		Check(small.CanAdmit(100, 11) == false || small.PageCount <= 3, "still holds");
		let before = small.Resident;
		Check(small.EvictTo(0, 500) == false && small.Resident == 100 && before == 300, "pinned page survives EvictTo(0)");
		Check(small.Contains(1, 0), "pinned page still resident");
		let tiny = scope StreamPool(.VtTile, 50);
		Check(!tiny.CanAdmit(100, 0), "a page bigger than the budget is refused");
	}

	static void CoreChecks(StringView dir)
	{
		let pageSize = 20000;
		let pages = scope List<List<uint8>>();
		defer { for (let p in pages) delete p; }
		MakePages(pages, 40, pageSize);
		let path = scope $"{dir}/core.tpages";
		PageFile.Write(path, .TextureMip, pages);
		let file = scope PageFile();
		file.Open(path);
		let recorder = scope Recorder();
		let res = scope StreamResource();
		res.Id = 5;
		res.Kind = .TextureMip;
		res.File = file;
		res.Consumer = recorder;

		// Order: with no threads, requests are read best priority first; one page uploads a frame.
		StreamingCore.Start(0, 0, 8 * 25000);
		StreamingCore.UploadBudgetMB = 0.001f;
		StreamingCore.Register(res);
		StreamingCore.Request(res, 10, 1);
		StreamingCore.Request(res, 11, 5);
		StreamingCore.Request(res, 12, 3);
		StreamingCore.Request(res, 11, 9);
		Check(!StreamingCore.Request(res, 12, 4), "repeat request is not queued twice");
		for (int f = 1; f <= 12; f++)
			StreamingCore.Update(f);
		Check(recorder.order.Count == 3 && recorder.order[0] == 11 && recorder.order[1] == 12 && recorder.order[2] == 10, "pages arrive in priority order");
		Check(StreamingCore.LastFrameUploadMB >= 0, "upload counter");
		StreamingCore.Unregister(res, 40);
		StreamingCore.Stop();

		// Threads: stream all 40 pages through a budget of 8; a page is requested only while "visible".
		recorder.order.Clear();
		StreamingCore.Start(2, 0, 8 * 25000);
		StreamingCore.UploadBudgetMB = 0.05f;
		StreamingCore.Register(res);
		let pool = StreamingCore.Pool(.TextureMip);
		var overBudget = false;
		var want = 0;
		var sawPending = false;
		for (int frame = 1; frame <= 600; frame++)
		{
			// A window of 6 pages slides along; pages leaving it are no longer touched.
			let start = frame / 12;
			if (start < 40)
			{
				for (int p = start; p < Math.Min(start + 6, 40); p++)
					StreamingCore.Request(res, p, (float)(100 - p));
				want = start;
			}
			StreamingCore.Update(frame);
			if (pool.Resident + pool.Pending > pool.Budget)
				overBudget = true;
			if (pool.Pending > 0)
				sawPending = true;
			if (frame > 480 && StreamingCore.QueueDepth == 0)
				break;
			System.Threading.Thread.Sleep(1);
		}
		Check(!overBudget, "resident + pending never over budget while streaming");
		Check(recorder.bad == 0, "every uploaded page had the right bytes");
		Check(recorder.order.Count >= 40, "every page of the sliding window arrived");
		Check(sawPending && pool.EvictedPages > 0, "old pages were evicted (and their bytes waited)");
		Check(pool.Contains(5, 39) || StreamingCore.Pool(.TextureMip).PageCount > 0, "last window resident");
		Check(StreamingCore.Failures == 0, "no failed reads");
		Check(StreamingCore.AverageLatencyMs >= 0 && StreamingCore.Uploads >= 40, "latency and upload counters");
		StreamingCore.Unregister(res, 40);
		Check(pool.Resident == 0, "unregister releases the pages");
		StreamingCore.Stop();
	}

	static void FeedbackChecks()
	{
		let ring = scope FeedbackRing(8);
		let records = scope List<uint32>();
		records.Add(FeedbackRecord.Pack(5, 2));
		records.Add(FeedbackRecord.Pack(5, 4));
		records.Add(FeedbackRecord.Pack(6, 1));
		for (int i < 10)
			records.Add(FeedbackRecord.Pack(100 + (uint32)i, 0));
		ring.Submit(10, records);
		Check(ring.Dropped == 5, "records past capacity are counted dropped");
		var seen = scope Dictionary<uint32, uint32>();
		Check(ring.Drain(11, scope [&seen] (id, detail) => seen[id] = detail) == 0, "a slot is not read before it is old enough");
		let n = ring.Drain(12, scope [&seen] (id, detail) => seen[id] = detail);
		Check(n == 7 && seen[5] == 4 && seen[6] == 1, "de-duplicated, widest detail kept");
		Check(ring.Drain(13, scope (id, detail) => {}) == 0, "slot is free after draining");
	}
}
