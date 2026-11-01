using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// What a marker or counter belongs to: it colours the marker's time in the Profiler window and picks the module a
/// counter is shown in.
public enum ProfilerCategory : uint8
{
	Other,
	Scripts,
	Rendering,
	Physics,
	Animation,
	Audio,
	Networking,
	AI,
	UI,
	Particles,
	Assets,
	Jobs,
	Memory,
	Editor,
	/// Time spent waiting (for the GPU, vsync, other threads).
	Waiting,
}

/// One timed stretch on one thread: from a marker's Begin to its End.
[CRepr]
public struct ProfilerSample
{
	public int32 marker;
	/// The thread it ran on (an index into the capture's thread names).
	public int16 thread;
	/// How many samples were open around it on its thread.
	public int16 depth;
	/// Nanoseconds from the frame's start (work on another thread can begin before it).
	public int64 start;
	public int64 duration;
}

/// A merged line of a frame's hierarchy: every call of one marker under the same parent line.
public struct ProfilerRow
{
	public int32 marker;
	/// The row it is under, or -1.
	public int32 parent;
	public int32 depth;
	public int32 calls;
	/// Nanoseconds, all calls together.
	public int64 total;
	/// The part of total not spent in rows under it.
	public int64 self;
}

/// One recorded frame.
public class ProfilerFrame
{
	/// The frame number (Time.FrameCount when it was recorded).
	public int64 index;
	/// When it started (nanoseconds, on the recording machine's clock).
	public int64 startTime;
	/// The main thread's time from the frame's start to its end.
	public int64 cpuTime;
	/// The time since the frame before started (what the player sees: 16.7 ms at 60 fps).
	public int64 interval;
	/// The GPU's time for its latest finished frame (it runs a frame or two behind the CPU), or 0.
	public int64 gpuTime;
	public List<ProfilerSample> samples = new .() ~ delete _;
	/// Counter values set this frame.
	public List<(int32 counter, double value)> counters = new .() ~ delete _;
	/// GPU time per render pass (bgfx view): the pass's name marker and nanoseconds.
	public List<(int32 pass, int64 time)> passes = new .() ~ delete _;
	// CategoryTimes' last answer (charts ask for every frame each redraw), for this thread and sample count.
	int64[16] mCategories;
	int32 mCategoriesThread = -1;
	int mCategoriesSamples = -1;

	public void Clear()
	{
		index = startTime = cpuTime = interval = gpuTime = 0;
		mCategoriesSamples = -1;
		samples.Clear();
		counters.Clear();
		passes.Clear();
	}

	public void CopyFrom(ProfilerFrame other)
	{
		index = other.index;
		startTime = other.startTime;
		cpuTime = other.cpuTime;
		interval = other.interval;
		gpuTime = other.gpuTime;
		mCategoriesSamples = -1;
		samples.Clear();
		samples.AddRange(other.samples);
		counters.Clear();
		counters.AddRange(other.counters);
		passes.Clear();
		passes.AddRange(other.passes);
	}

	/// A counter's value this frame, or `missing` when it was not set.
	public double Counter(int32 counter, double missing = 0)
	{
		for (let entry in counters)
		{
			if (entry.counter == counter)
				return entry.value;
		}
		return missing;
	}

	/// Total time of a marker's samples this frame (on every thread, or one).
	public int64 TimeOf(int32 marker, int32 thread = -1)
	{
		int64 total = 0;
		for (let sample in samples)
		{
			if (sample.marker == marker && (thread < 0 || sample.thread == thread))
				total += sample.duration;
		}
		return total;
	}

	/// Time per category on one thread, counting only each thread's outermost samples by their own category's share:
	/// a sample's self time goes to its category. `times` gets one entry per ProfilerCategory.
	public void CategoryTimes(ProfilerCapture capture, int32 thread, Span<int64> times)
	{
		if (mCategoriesThread != thread || mCategoriesSamples != samples.Count)
		{
			mCategories = default;
			let rows = scope List<ProfilerRow>();
			Hierarchy(thread, rows);
			for (let row in rows)
			{
				let category = (int)capture.CategoryOf(row.marker);
				if (category < 16)
					mCategories[category] += row.self;
			}
			mCategoriesThread = thread;
			mCategoriesSamples = samples.Count;
		}
		for (int i < times.Length)
			times[i] = i < 16 ? mCategories[i] : 0;
	}

	/// The frame's hierarchy on one thread: samples merged by their path from the top, so calls of one marker under
	/// one parent are one row. Rows come parent first, children in the order first seen.
	public void Hierarchy(int32 thread, List<ProfilerRow> rows)
	{
		rows.Clear();
		// The row open at each depth while walking the samples (they are kept in the order they began).
		int32[64] open = default;
		for (int d < 64)
			open[d] = -1;
		// Keyed by parent row and marker together.
		let children = scope Dictionary<int64, int32>();
		for (let sample in samples)
		{
			if (sample.thread != thread)
				continue;
			let depth = Math.Clamp((int32)sample.depth, 0, 63);
			// A parent cut off at the frame's start is missing: hang the sample on the deepest row there is.
			var parent = (int32) - 1;
			for (int32 d = depth - 1; d >= 0; d--)
			{
				if (open[d] >= 0 && open[d] < rows.Count && rows[open[d]].depth == d)
				{
					parent = open[d];
					break;
				}
			}
			int32 row;
			let key = ((int64)parent << 32) | (int64)(uint32)sample.marker;
			if (!children.TryGetValue(key, out row))
			{
				row = (int32)rows.Count;
				ProfilerRow added = default;
				added.marker = sample.marker;
				added.parent = parent;
				added.depth = parent < 0 ? 0 : rows[parent].depth + 1;
				rows.Add(added);
				children[key] = row;
			}
			rows[row].calls++;
			rows[row].total += sample.duration;
			open[Math.Min(rows[row].depth, 63)] = row;
			for (int32 d = rows[row].depth + 1; d < 64; d++)
				open[d] = -1;
		}
		for (int i < rows.Count)
			rows[i].self = rows[i].total;
		for (let row in rows)
		{
			if (row.parent >= 0)
				rows[row.parent].self -= row.total;
		}
		for (int i < rows.Count)
			rows[i].self = Math.Max(rows[i].self, 0);
	}
}

/// Frames with the names they use: the local recording (Profiler.Local), one received from a running build
/// (ProfilerClient), or one loaded from a .tprofile file.
public class ProfilerCapture
{
	public enum Kind : uint8
	{
		Marker,
		Counter,
		Pass,
	}

	public struct Name
	{
		public String text;
		public ProfilerCategory category;
		public Kind kind;
		/// A counter's unit ("bytes", "ms", ""), shown beside its values.
		public String unit;
	}

	public List<Name> names = new .() ~
		{
			for (let name in _)
			{
				delete name.text;
				delete name.unit;
			}
			delete _;
		};
	public List<String> threads = new .() ~ DeleteContainerAndItems!(_);
	/// The frames kept, oldest first, at most `limit` (older ones are dropped and reused).
	public List<ProfilerFrame> frames = new .() ~ DeleteContainerAndItems!(_);
	public int32 limit = 300;
	List<ProfilerFrame> mSpare = new .() ~ DeleteContainerAndItems!(_);
	/// Bumped whenever a frame is added, so views know to redraw.
	public int32 Revision;

	public StringView NameOf(int32 id) => id >= 0 && id < names.Count && names[id].text != null ? names[id].text : "?";
	public ProfilerCategory CategoryOf(int32 id) => id >= 0 && id < names.Count ? names[id].category : .Other;
	public StringView UnitOf(int32 id) => id >= 0 && id < names.Count && names[id].unit != null ? names[id].unit : "";
	public Kind KindOf(int32 id) => id >= 0 && id < names.Count ? names[id].kind : .Marker;
	public StringView ThreadName(int32 index) => index >= 0 && index < threads.Count ? threads[index] : "?";

	public void SetName(int32 id, StringView text, ProfilerCategory category, Kind kind, StringView unit)
	{
		if (id < 0 || id > 1000000)
			return;
		while (names.Count <= id)
			names.Add(default);
		var name = ref names[id];
		if (name.text == null)
			name.text = new .();
		if (name.unit == null)
			name.unit = new .();
		name.text.Set(text);
		name.unit.Set(unit);
		name.category = category;
		name.kind = kind;
	}

	public void SetThread(int32 index, StringView text)
	{
		if (index < 0 || index > 4096)
			return;
		while (threads.Count <= index)
			threads.Add(new .());
		threads[index].Set(text);
	}

	/// The id of a name, or -1.
	public int32 Find(StringView text)
	{
		for (int i < names.Count)
		{
			if (names[i].text != null && names[i].text == text)
				return (int32)i;
		}
		return -1;
	}

	/// A frame to fill and then Add (the oldest one is reused when the capture is full).
	public ProfilerFrame NewFrame()
	{
		ProfilerFrame frame;
		if (!mSpare.IsEmpty)
			frame = mSpare.PopBack();
		else
			frame = new .();
		frame.Clear();
		return frame;
	}

	public void Add(ProfilerFrame frame)
	{
		frames.Add(frame);
		while (limit > 0 && frames.Count > limit)
		{
			mSpare.Add(frames[0]);
			frames.RemoveAt(0);
		}
		Revision++;
	}

	public void Clear()
	{
		for (let frame in frames)
			mSpare.Add(frame);
		frames.Clear();
		Revision++;
	}

	/// The frame with this frame number, or null.
	public ProfilerFrame FrameAt(int64 index)
	{
		for (int i = frames.Count - 1; i >= 0; i--)
		{
			if (frames[i].index == index)
				return frames[i];
		}
		return null;
	}

	// ---- the file and wire format: a run of records, each a type byte then its fields (little-endian) ----

	public const uint8 RecordName = 1;
	public const uint8 RecordThread = 2;
	public const uint8 RecordFrame = 3;
	public static StringView Magic = "TPROFILE1\n";

	static void PutU8(List<uint8> bytes, uint8 value) => bytes.Add(value);
	static void PutI16(List<uint8> bytes, int16 value)
	{
		bytes.Add((uint8)value);
		bytes.Add((uint8)(value >> 8));
	}

	static void PutI32(List<uint8> bytes, int32 value)
	{
		for (int i < 4)
			bytes.Add((uint8)(value >> (i * 8)));
	}

	static void PutI64(List<uint8> bytes, int64 value)
	{
		for (int i < 8)
			bytes.Add((uint8)(value >> (i * 8)));
	}

	static void PutF64(List<uint8> bytes, double value)
	{
		var value;
		PutI64(bytes, *(int64*)&value);
	}

	static void PutText(List<uint8> bytes, StringView text)
	{
		let length = (int16)Math.Min(text.Length, 30000);
		PutI16(bytes, length);
		for (int i < length)
			bytes.Add((uint8)text[i]);
	}

	public static void WriteName(List<uint8> bytes, int32 id, StringView text, ProfilerCategory category, Kind kind, StringView unit)
	{
		PutU8(bytes, RecordName);
		PutI32(bytes, id);
		PutU8(bytes, (uint8)category);
		PutU8(bytes, (uint8)kind);
		PutText(bytes, text);
		PutText(bytes, unit);
	}

	public static void WriteThread(List<uint8> bytes, int32 index, StringView text)
	{
		PutU8(bytes, RecordThread);
		PutI32(bytes, index);
		PutText(bytes, text);
	}

	public static void WriteFrame(List<uint8> bytes, ProfilerFrame frame)
	{
		PutU8(bytes, RecordFrame);
		PutI64(bytes, frame.index);
		PutI64(bytes, frame.startTime);
		PutI64(bytes, frame.cpuTime);
		PutI64(bytes, frame.interval);
		PutI64(bytes, frame.gpuTime);
		PutI32(bytes, (int32)frame.samples.Count);
		for (let sample in frame.samples)
		{
			PutI32(bytes, sample.marker);
			PutI16(bytes, sample.thread);
			PutI16(bytes, sample.depth);
			PutI64(bytes, sample.start);
			PutI64(bytes, sample.duration);
		}
		PutI32(bytes, (int32)frame.counters.Count);
		for (let counter in frame.counters)
		{
			PutI32(bytes, counter.counter);
			PutF64(bytes, counter.value);
		}
		PutI32(bytes, (int32)frame.passes.Count);
		for (let pass in frame.passes)
		{
			PutI32(bytes, pass.pass);
			PutI64(bytes, pass.time);
		}
	}

	/// The whole capture: the magic line, every name and thread, then the frames.
	public void Write(List<uint8> bytes)
	{
		for (let c in Magic.RawChars)
			bytes.Add((uint8)c);
		for (int i < names.Count)
		{
			if (names[i].text != null)
				WriteName(bytes, (int32)i, names[i].text, names[i].category, names[i].kind, names[i].unit);
		}
		for (int i < threads.Count)
			WriteThread(bytes, (int32)i, threads[i]);
		for (let frame in frames)
			WriteFrame(bytes, frame);
	}

	struct Reader
	{
		public Span<uint8> bytes;
		public int at;
		public bool failed;

		public bool Has(int count) mut
		{
			if (at + count > bytes.Length)
				failed = true;
			return !failed;
		}
		public uint8 U8() mut => Has(1) ? bytes[at++] : 0;
		public int16 I16() mut
		{
			if (!Has(2))
				return 0;
			let value = (int16)((uint16)bytes[at] | ((uint16)bytes[at + 1] << 8));
			at += 2;
			return value;
		}
		public int32 I32() mut
		{
			if (!Has(4))
				return 0;
			uint32 value = 0;
			for (int i < 4)
				value |= (uint32)bytes[at + i] << (i * 8);
			at += 4;
			return (int32)value;
		}
		public int64 I64() mut
		{
			if (!Has(8))
				return 0;
			uint64 value = 0;
			for (int i < 8)
				value |= (uint64)bytes[at + i] << (i * 8);
			at += 8;
			return (int64)value;
		}
		public double F64() mut
		{
			var bits = I64();
			return *(double*)&bits;
		}
		public void Text(String into) mut
		{
			let length = I16();
			if (length < 0 || !Has(length))
				return;
			for (int i < length)
				into.Append((char8)bytes[at + i]);
			at += length;
		}
	}

	/// Reads records (a file's, after its magic line, or a packet's) into this capture. False when they are broken.
	public bool Read(Span<uint8> bytes)
	{
		Reader reader = .() { bytes = bytes };
		// A file starts with its magic line.
		if (bytes.Length >= Magic.Length)
		{
			var magic = true;
			for (int i < Magic.Length)
				magic &= bytes[i] == (uint8)Magic[i];
			if (magic)
				reader.at = Magic.Length;
		}
		let text = scope String();
		let unit = scope String();
		while (reader.at < bytes.Length && !reader.failed)
		{
			let type = reader.U8();
			switch (type)
			{
			case RecordName:
				let id = reader.I32();
				let category = (ProfilerCategory)Math.Min(reader.U8(), (uint8)ProfilerCategory.Waiting);
				let kind = (Kind)Math.Min(reader.U8(), (uint8)Kind.Pass);
				text.Clear();
				unit.Clear();
				reader.Text(text);
				reader.Text(unit);
				if (!reader.failed)
					SetName(id, text, category, kind, unit);
			case RecordThread:
				let index = reader.I32();
				text.Clear();
				reader.Text(text);
				if (!reader.failed)
					SetThread(index, text);
			case RecordFrame:
				let frame = NewFrame();
				frame.index = reader.I64();
				frame.startTime = reader.I64();
				frame.cpuTime = reader.I64();
				frame.interval = reader.I64();
				frame.gpuTime = reader.I64();
				let samples = reader.I32();
				if (samples < 0 || !reader.Has((int)samples * 24))
				{
					mSpare.Add(frame);
					return false;
				}
				for (int i < samples)
				{
					ProfilerSample sample = default;
					sample.marker = reader.I32();
					sample.thread = reader.I16();
					sample.depth = reader.I16();
					sample.start = reader.I64();
					sample.duration = reader.I64();
					frame.samples.Add(sample);
				}
				let counters = reader.I32();
				if (counters < 0 || !reader.Has((int)counters * 12))
				{
					mSpare.Add(frame);
					return false;
				}
				for (int i < counters)
				{
					let id = reader.I32();
					frame.counters.Add((id, reader.F64()));
				}
				let passes = reader.I32();
				if (passes < 0 || !reader.Has((int)passes * 12))
				{
					mSpare.Add(frame);
					return false;
				}
				for (int i < passes)
				{
					let id = reader.I32();
					frame.passes.Add((id, reader.I64()));
				}
				if (reader.failed)
				{
					mSpare.Add(frame);
					return false;
				}
				Add(frame);
			default:
				return false;
			}
		}
		return !reader.failed;
	}

	/// Saves the capture as a .tprofile file.
	public bool Save(StringView path)
	{
		let bytes = scope List<uint8>();
		Write(bytes);
		return System.IO.File.WriteAll(path, bytes) case .Ok;
	}

	/// Loads a .tprofile file (replacing what the capture held). The limit grows to fit every frame in it.
	public bool Load(StringView path)
	{
		let bytes = scope List<uint8>();
		if (System.IO.File.ReadAll(path, bytes) case .Err)
			return false;
		Clear();
		let saved = limit;
		limit = 0;
		let ok = Read(bytes);
		limit = Math.Max(saved, (int32)frames.Count);
		return ok;
	}
}

/// A named marker kept in a static field: it registers its name the first time it is used, so it can be declared
/// anywhere without caring when static fields are set up.
///
///     static ProfilerMarker sPathfinding = .("My Pathfinding", .AI);
///     sPathfinding.Begin(); ... Profiler.End();       // or: using (sPathfinding.Sample()) { ... }
public struct ProfilerMarker
{
	StringView mName;
	ProfilerCategory mCategory;
	int32 mId;

	public this(StringView name, ProfilerCategory category = .Scripts)
	{
		mName = name;
		mCategory = category;
		mId = -1;
	}

	public int32 Id
	{
		get mut
		{
			if (mId < 0)
				mId = Profiler.Marker(mName, mCategory);
			return mId;
		}
	}

	public void Begin() mut
	{
		if (Profiler.Enabled)
			Profiler.Begin(Id);
	}

	public Profiler.SampleScope Sample() mut => Profiler.Enabled ? Profiler.Sample(Id) : default;
}

/// A named counter kept in a static field (registered the first time it is used).
///
///     static ProfilerCounter sEnemies = .("Enemies", .Scripts);
///     sEnemies.Set(count);
public struct ProfilerCounter
{
	StringView mName;
	StringView mUnit;
	ProfilerCategory mCategory;
	int32 mId;

	public this(StringView name, ProfilerCategory category = .Scripts, StringView unit = "")
	{
		mName = name;
		mUnit = unit;
		mCategory = category;
		mId = -1;
	}

	public int32 Id
	{
		get mut
		{
			if (mId < 0)
				mId = Profiler.Counter(mName, mCategory, mUnit);
			return mId;
		}
	}

	public void Set(double value) mut
	{
		if (Profiler.Enabled)
			Profiler.Set(Id, value);
	}

	public void Add(double amount) mut
	{
		if (Profiler.Enabled)
			Profiler.Add(Id, amount);
	}
}

/// The engine's profiler (docs/profiler.md): markers timed on every thread, counters, and a history of frames that
/// the editor's Window > Profiler shows. Recording costs next to nothing until Enabled is set (the window,
/// `--profile`, or a connected editor sets it). Markers and counters are best kept in ProfilerMarker and
/// ProfilerCounter static fields; Marker and Counter look names up under a lock.
public static class Profiler
{
	class ThreadBuffer
	{
		public int16 index;
		public List<ProfilerSample> samples = new .() ~ delete _;
		/// Each open sample's place in samples, outermost first.
		public int32[64] open;
		public int32 depth;
		/// Taken by the thread while it writes, and by the main thread when it takes the frame's samples.
		public int32 busy;

		public void Lock()
		{
			while (Interlocked.CompareExchange(ref busy, 0, 1) != 0)
				Thread.SpinWait(8);
		}

		public void Unlock() => Interlocked.Store(ref busy, 0);
	}

	/// Times work while it is true; frames are added to Local's history at each EndFrame.
	public static bool Enabled
	{
		get => sEnabled;
		set
		{
			if (sEnabled == value)
				return;
			sEnabled = value;
			// Nothing begun while it was off is half-open; anything open now is dropped.
			for (let buffer in sThreads)
			{
				buffer.Lock();
				buffer.samples.Clear();
				buffer.depth = 0;
				buffer.Unlock();
			}
			sFrameOpen = false;
		}
	}

	static bool sEnabled;
	/// Also times every component's Update, LateUpdate and FixedUpdate one by one (by type). On by default; off makes
	/// recording cheaper in scenes with thousands of components.
	public static bool ComponentSamples = true;
	/// The local recording.
	public static ProfilerCapture Local = new .() ~ delete _;

	static Monitor sLock = new .() ~ delete _;
	static Dictionary<String, int32> sIds = new .() ~ DeleteDictionaryAndKeys!(_);
	/// The names Local has that no listener has been sent yet (ProfilerServer reads and clears it); -1 - index for a
	/// thread's name.
	static List<int32> sNewNames = new .() ~ delete _;
	static List<ThreadBuffer> sThreads = new .() ~ DeleteContainerAndItems!(_);
	[ThreadStatic]
	static ThreadBuffer tBuffer;
	static List<double> sCounterValues = new .() ~ delete _;
	static List<int32> sCountersSet = new .() ~ delete _;
	static bool sFrameOpen;
	static int64 sFrameStart, sLastFrameStart;
	static ProfilerFrame sCurrent;
	static int32 sFrameMarker = -1;
	/// Called at each EndFrame, before the frame is stored, to set the modules' counters (ProfilerModules).
	public static List<function void()> Collectors = new .() ~ delete _;
	/// Called with each finished frame (the remote listener sends it on).
	public static Event<delegate void(ProfilerFrame)> OnFrame ~ _.Dispose();

	/// The clock samples use (nanoseconds).
	public static int64 Now => (int64)SDL.SDL_GetTicksNS();

	/// The id of a marker (made the first time its name is seen). Keep it in a static field: looking a name up takes a
	/// lock.
	public static int32 Marker(StringView name, ProfilerCategory category = .Other) => Register(name, category, .Marker, "");

	/// The id of a counter: a number set each frame, shown in its category's module. `unit` is shown beside values
	/// ("bytes" values are shown in KB/MB).
	public static int32 Counter(StringView name, ProfilerCategory category, StringView unit = "") => Register(name, category, .Counter, unit);

	/// The id of a GPU pass's name.
	public static int32 Pass(StringView name) => Register(name, .Rendering, .Pass, "");

	static int32 Register(StringView name, ProfilerCategory category, ProfilerCapture.Kind kind, StringView unit)
	{
		using (sLock.Enter())
		{
			let key = scope String(name);
			if (kind != .Marker)
				key.Insert(0, kind == .Counter ? "#counter " : "#pass ");
			if (sIds.TryGetValue(key, let found))
				return found;
			let id = (int32)Local.names.Count;
			Local.SetName(id, name, category, kind, unit);
			sIds[new String(key)] = id;
			sNewNames.Add(id);
			return id;
		}
	}

	/// The names registered since the last call (for ProfilerServer).
	public static void TakeNewNames(List<int32> into)
	{
		using (sLock.Enter())
		{
			into.AddRange(sNewNames);
			sNewNames.Clear();
		}
	}

	static ThreadBuffer Buffer()
	{
		var buffer = tBuffer;
		if (buffer != null)
			return buffer;
		using (sLock.Enter())
		{
			buffer = new ThreadBuffer();
			buffer.index = (int16)sThreads.Count;
			sThreads.Add(buffer);
			// The first thread to record is taken to be the main thread until it is named.
			let name = buffer.index == 0 ? "Main Thread" : scope:: $"Thread {buffer.index}";
			Local.SetThread(buffer.index, name);
			sNewNames.Add(-1 - buffer.index);
		}
		tBuffer = buffer;
		return buffer;
	}

	/// Names the calling thread in captures ("Main Thread", "Job 3", "Asset Loader").
	public static void NameThread(StringView name)
	{
		let buffer = Buffer();
		using (sLock.Enter())
		{
			Local.SetThread(buffer.index, name);
			sNewNames.Add(-1 - buffer.index);
		}
	}

	/// The index of the calling thread in captures.
	public static int32 ThreadIndex => Buffer().index;

	/// Starts timing a marker on this thread. Every Begin needs an End on the same thread.
	public static void Begin(int32 marker)
	{
		if (!sEnabled)
			return;
		let buffer = Buffer();
		buffer.Lock();
		if (buffer.depth < 64)
		{
			ProfilerSample sample = default;
			sample.marker = marker;
			sample.thread = buffer.index;
			sample.depth = (int16)buffer.depth;
			sample.start = Now;
			sample.duration = -1;
			buffer.open[buffer.depth] = (int32)buffer.samples.Count;
			buffer.samples.Add(sample);
		}
		buffer.depth++;
		buffer.Unlock();
	}

	/// Ends the latest Begin on this thread.
	public static void End()
	{
		if (!sEnabled)
			return;
		let buffer = Buffer();
		buffer.Lock();
		if (buffer.depth > 0)
		{
			buffer.depth--;
			if (buffer.depth < 64)
			{
				let at = buffer.open[buffer.depth];
				if (at >= 0 && at < buffer.samples.Count)
				{
					var sample = ref buffer.samples[at];
					sample.duration = Now - sample.start;
				}
			}
		}
		buffer.Unlock();
	}

	/// The marker innermost open on this thread, or -1 (Jobs labels its workers' time with it).
	public static int32 Current
	{
		get
		{
			if (!sEnabled)
				return -1;
			let buffer = Buffer();
			buffer.Lock();
			var marker = (int32) - 1;
			if (buffer.depth > 0 && buffer.depth <= 64)
			{
				let at = buffer.open[buffer.depth - 1];
				if (at >= 0 && at < buffer.samples.Count)
					marker = buffer.samples[at].marker;
			}
			buffer.Unlock();
			return marker;
		}
	}

	/// Times a marker until the end of a `using` block (or the scope, with `defer`).
	public struct SampleScope : IDisposable
	{
		bool mBegun;

		public this(int32 marker)
		{
			mBegun = sEnabled;
			if (mBegun)
				Begin(marker);
		}

		public void Dispose()
		{
			if (mBegun && sEnabled)
				End();
		}
	}

	public static SampleScope Sample(int32 marker) => .(marker);

	/// Sets a counter's value for this frame.
	public static void Set(int32 counter, double value)
	{
		if (!sEnabled || counter < 0)
			return;
		using (sLock.Enter())
		{
			while (sCounterValues.Count <= counter)
				sCounterValues.Add(double.NaN);
			if (sCounterValues[counter].IsNaN)
				sCountersSet.Add(counter);
			sCounterValues[counter] = value;
		}
	}

	/// Adds to a counter's value for this frame (from any thread).
	public static void Add(int32 counter, double amount)
	{
		if (!sEnabled || counter < 0)
			return;
		using (sLock.Enter())
		{
			while (sCounterValues.Count <= counter)
				sCounterValues.Add(double.NaN);
			if (sCounterValues[counter].IsNaN)
			{
				sCountersSet.Add(counter);
				sCounterValues[counter] = 0;
			}
			sCounterValues[counter] += amount;
		}
	}

	/// Starts a frame (Application.Frame calls it first thing; tests and tools can call it themselves).
	public static void BeginFrame()
	{
		if (!sEnabled)
			return;
		if (sFrameMarker < 0)
			sFrameMarker = Marker("Frame", .Other);
		Buffer();
		sFrameStart = Now;
		sFrameOpen = true;
		Begin(sFrameMarker);
	}

	/// Ends the frame: collects the modules' counters and every thread's samples into a frame added to Local, and
	/// hands it to OnFrame. Samples still open on other threads are cut at this point and go on into the next frame.
	public static void EndFrame(int64 gpuTime = 0)
	{
		if (!sEnabled || !sFrameOpen)
			return;
		sFrameOpen = false;
		End();
		for (let collect in Collectors)
			collect();
		let now = Now;
		let frame = Local.NewFrame();
		frame.index = Time.FrameCount;
		frame.startTime = sFrameStart;
		frame.cpuTime = now - sFrameStart;
		frame.interval = sLastFrameStart > 0 ? sFrameStart - sLastFrameStart : frame.cpuTime;
		frame.gpuTime = gpuTime;
		sLastFrameStart = sFrameStart;
		using (sLock.Enter())
		{
			for (let buffer in sThreads)
			{
				buffer.Lock();
				// Open samples are cut here: their part so far goes in this frame, and they start again at once.
				let keep = scope List<ProfilerSample>();
				for (int d < Math.Min(buffer.depth, 64))
				{
					let at = buffer.open[d];
					if (at >= 0 && at < buffer.samples.Count)
					{
						var sample = ref buffer.samples[at];
						sample.duration = now - sample.start;
						var again = sample;
						again.start = now;
						again.duration = -1;
						keep.Add(again);
					}
				}
				for (var sample in buffer.samples)
				{
					if (sample.duration < 0)
						continue;
					sample.start -= sFrameStart;
					frame.samples.Add(sample);
				}
				buffer.samples.Clear();
				for (int i < keep.Count)
				{
					buffer.open[i] = (int32)buffer.samples.Count;
					buffer.samples.Add(keep[i]);
				}
				buffer.Unlock();
			}
			for (let counter in sCountersSet)
			{
				frame.counters.Add((counter, sCounterValues[counter]));
				sCounterValues[counter] = double.NaN;
			}
			sCountersSet.Clear();
			if (sCurrent != null)
			{
				frame.passes.AddRange(sCurrent.passes);
				sCurrent.passes.Clear();
			}
		}
		// Samples on a thread are kept in the order they began; the main thread's frame sample comes first.
		// (a parent and its first child can start on the same nanosecond: the parent, less deep, first).
		frame.samples.Sort(scope (a, b) => a.thread != b.thread ? a.thread <=> b.thread : (a.start != b.start ? a.start <=> b.start : a.depth <=> b.depth));
		OnFrame.Invoke(frame);
		Local.Add(frame);
	}

	/// Records a GPU pass time for the frame being recorded (ProfilerModules reads bgfx's per-view times).
	public static void AddPass(int32 pass, int64 time)
	{
		if (!sEnabled)
			return;
		if (sCurrent == null)
			sCurrent = new .();
		sCurrent.passes.Add((pass, time));
	}

	public static void Shutdown()
	{
		DeleteAndNullify!(sCurrent);
	}
}
