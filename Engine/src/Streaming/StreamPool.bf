using System;
using System.Collections;

namespace Tallow;

/// How much a resident page is worth keeping, best first. Eviction takes Cold, then Recent; never Visible or Pinned.
public enum StreamClass : uint8
{
	Cold,
	Recent,
	Visible,
	Pinned
}

/// The pages of one kind that are resident, against a byte budget. Pages are keyed by (resource id, page index);
/// resource ids stay below 2^40. Single-threaded: the main thread owns it.
///
/// Evicting a page takes it out of the resident set at once (OnEvict fires, the owner stops using it) but its bytes stay
/// counted in Pending for FramesBeforeReuse frames, the same rule as the geometry pool's free list, so a frame still in
/// flight on the GPU can finish with it. Resident + Pending never exceeds the budget.
class StreamPool
{
	public const int FramesBeforeReuse = 4;
	/// A page used within this many frames counts as Visible; within RecentFrames, as Recent.
	public const int VisibleFrames = 1;
	public const int RecentFrames = 120;

	struct Entry
	{
		public int64 bytes;
		public int lastUsed;
		public bool pinned;
	}

	Dictionary<uint64, Entry> mPages = new .() ~ delete _;
	List<(int64 bytes, int freeFrame)> mPending = new .() ~ delete _;

	public StreamKind Kind;
	public int64 Budget;
	public int64 Resident { get; private set; }
	public int64 Pending { get; private set; }
	public int PageCount => mPages.Count;
	public int64 EvictedPages;
	/// Called when a page leaves the resident set (resource id, page).
	public delegate void(uint64 resource, int page) OnEvict ~ delete _;

	public this(StreamKind kind, int64 budget)
	{
		Kind = kind;
		Budget = budget;
	}

	public static uint64 Key(uint64 resource, int page) => (resource << 24) | (uint64)(page & 0xFFFFFF);

	public bool Contains(uint64 resource, int page) => mPages.ContainsKey(Key(resource, page));

	/// Marks a page used this frame.
	public void Touch(uint64 resource, int page, int frame)
	{
		if (mPages.TryGetValue(Key(resource, page), var entry))
		{
			entry.lastUsed = frame;
			mPages[Key(resource, page)] = entry;
		}
	}

	public StreamClass ClassOf(uint64 resource, int page, int frame)
	{
		if (!mPages.TryGetValue(Key(resource, page), let entry))
			return .Cold;
		return Classify(entry, frame);
	}

	static StreamClass Classify(Entry entry, int frame)
	{
		if (entry.pinned)
			return .Pinned;
		let age = frame - entry.lastUsed;
		if (age <= VisibleFrames)
			return .Visible;
		return age <= RecentFrames ? .Recent : .Cold;
	}

	/// Makes room for `bytes` more and says whether it can be taken now: false when everything evictable is gone
	/// (the page has to wait for pages in use to go cold) or when room is only coming as evicted pages retire.
	public bool CanAdmit(int64 bytes, int frame)
	{
		Retire(frame);
		if (bytes > Budget)
			return false;
		if (!EvictTo(Budget - bytes, frame))
			return false;
		return Resident + Pending + bytes <= Budget;
	}

	/// Adds a page that CanAdmit accepted. Pinned pages are never evicted (a geometry root page, say).
	public void Add(uint64 resource, int page, int64 bytes, int frame, bool pinned = false)
	{
		let key = Key(resource, page);
		if (mPages.TryGetValue(key, let old))
		{
			Resident -= old.bytes;
			mPages.Remove(key);
		}
		mPages[key] = .() { bytes = bytes, lastUsed = frame, pinned = pinned };
		Resident += bytes;
	}

	/// Drops a page now (the resource is gone). Its bytes wait out the in-flight frames like an eviction.
	public void Remove(uint64 resource, int page, int frame)
	{
		let key = Key(resource, page);
		if (mPages.TryGetValue(key, let entry))
		{
			mPages.Remove(key);
			Resident -= entry.bytes;
			mPending.Add((entry.bytes, frame + FramesBeforeReuse));
			Pending += entry.bytes;
		}
	}

	/// Evicts coldest-first until Resident is at most `bytes`. False if pages that may not be evicted keep it above.
	public bool EvictTo(int64 bytes, int frame)
	{
		Retire(frame);
		while (Resident > bytes)
		{
			uint64 bestKey = 0;
			int bestAge = -1;
			StreamClass bestClass = .Pinned;
			for (let (key, entry) in mPages)
			{
				let cls = Classify(entry, frame);
				if (cls >= .Visible)
					continue;
				let age = frame - entry.lastUsed;
				if (bestAge < 0 || cls < bestClass || (cls == bestClass && age > bestAge))
				{
					bestKey = key;
					bestAge = age;
					bestClass = cls;
				}
			}
			if (bestAge < 0)
				return false;
			let entry = mPages[bestKey];
			mPages.Remove(bestKey);
			Resident -= entry.bytes;
			mPending.Add((entry.bytes, frame + FramesBeforeReuse));
			Pending += entry.bytes;
			EvictedPages++;
			if (OnEvict != null)
				OnEvict(bestKey >> 24, (int)(bestKey & 0xFFFFFF));
		}
		return true;
	}

	/// Frees the bytes of evicted pages whose in-flight frames are over.
	public void Retire(int frame)
	{
		for (var i = mPending.Count - 1; i >= 0; i--)
		{
			if (mPending[i].freeFrame <= frame)
			{
				Pending -= mPending[i].bytes;
				mPending.RemoveAtFast(i);
			}
		}
	}
}
