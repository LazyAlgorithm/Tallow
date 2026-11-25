using System;
using System.Collections;

namespace Tallow;

/// What the GPU asks for, as the cull and feedback passes write it: one uint32 per request, the resource (or page)
/// number in the low 24 bits and the wanted detail (a mip, a LOD level, a tile level) in the high 8.
static class FeedbackRecord
{
	public static uint32 Pack(uint32 id, uint32 detail) => (id & 0xFFFFFF) | ((detail & 0xFF) << 24);
	public static uint32 Id(uint32 record) => record & 0xFFFFFF;
	public static uint32 Detail(uint32 record) => record >> 24;
}

/// Ring of readback slots for the feedback buffer. The renderer copies the buffer into the slot of the frame it was
/// written in (Submit, called when the readback lands); Drain hands the records of a frame that is old enough that the
/// GPU is done with it, so the main thread never waits (the same scheme as GpuDriven's PollStats). Records are
/// de-duplicated (largest wanted detail per id) before they reach the handler. The buffer is clamped: records past
/// Capacity are counted in Dropped.
class FeedbackRing
{
	public const int Slots = 3;
	/// A slot is read back this many frames after the frame it was recorded in.
	public const int Latency = 2;

	struct Slot
	{
		public int frame;
		public bool full;
		public List<uint32> records;
	}

	Slot[Slots] mSlots;
	Dictionary<uint32, uint32> mWanted = new .() ~ delete _;

	public int Capacity;
	public int64 Dropped;
	public int64 Records;

	public this(int capacity = 65536)
	{
		Capacity = capacity;
		for (int i < Slots)
		{
			mSlots[i].records = new .();
			mSlots[i].frame = -1;
		}
	}

	public ~this()
	{
		for (int i < Slots)
			delete mSlots[i].records;
	}

	/// Stores the records read back for `frame`. A frame still waiting in the slot is overwritten (counted dropped).
	public void Submit(int frame, Span<uint32> records)
	{
		let slot = &mSlots[frame % Slots];
		if (slot.full)
			Dropped += slot.records.Count;
		slot.records.Clear();
		let count = Math.Min(records.Length, Capacity);
		Dropped += records.Length - count;
		slot.records.AddRange(records.Slice(0, count));
		slot.frame = frame;
		slot.full = true;
	}

	/// Calls `handler(id, detail)` once per distinct id for every slot at least Latency frames old, then frees the slot.
	/// Returns how many distinct requests were handed over.
	public int Drain(int currentFrame, delegate void(uint32 id, uint32 detail) handler)
	{
		mWanted.Clear();
		for (int i < Slots)
		{
			let slot = &mSlots[i];
			if (!slot.full || currentFrame - slot.frame < Latency)
				continue;
			for (let record in slot.records)
			{
				Records++;
				let id = FeedbackRecord.Id(record);
				let detail = FeedbackRecord.Detail(record);
				if (mWanted.TryGetValue(id, let have))
				{
					if (detail > have)
						mWanted[id] = detail;
				}
				else
					mWanted[id] = detail;
			}
			slot.records.Clear();
			slot.full = false;
		}
		for (let (id, detail) in mWanted)
			handler(id, detail);
		return mWanted.Count;
	}
}
