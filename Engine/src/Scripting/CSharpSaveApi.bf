using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// SaveSystem for C# scripts (generated wrappers in Tallow.API; SaveGame there).
[CSharpExpose]
static class CSharpSaves
{
	/// Saves the playing scene into a slot; returns the task's id.
	[CSharpExpose]
	public static int32 Save(StringView slot) => SaveSystem.Save(slot).id;

	/// Loads a slot into the game; returns the task's id.
	[CSharpExpose]
	public static int32 Load(StringView slot) => SaveSystem.Load(slot).id;

	/// A task's state: 0 still running, 1 done, 2 done but the slot had no save (loading), -1 failed.
	[CSharpExpose]
	public static int32 Status(int32 task)
	{
		let handle = SaveHandle(task);
		if (!handle.Done)
			return 0;
		if (!handle.Succeeded)
			return -1;
		return handle.Found ? 1 : 2;
	}

	[CSharpExpose]
	public static bool Exists(StringView slot) => SaveSystem.Exists(slot);

	[CSharpExpose]
	public static void Delete(StringView slot) => SaveSystem.Delete(slot);

	/// The slots that hold saves, separated by 0x1F; the whole length (call again with more room if it is more).
	[CSharpExpose]
	public static int32 ListSlots(Span<uint8> buffer)
	{
		let slots = scope List<String>();
		SaveSystem.ListSlots(slots);
		let text = scope String();
		for (let slot in slots)
		{
			if (!text.IsEmpty)
				text.Append('\x1F');
			text.Append(slot);
			delete slot;
		}
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	static Monitor sLock = new .() ~ delete _;
	/// Saves and loads handed to the C# storage and not finished yet, by number.
	static Dictionary<int32, SaveTask> sPending = new .() ~ delete _;
	static int32 sNextTask = 1;
	/// Where ListSlot puts slots while the C# storage lists them.
	static List<String> sListing;

	/// Hands a task to the C# storage (op 0 write, 1 read).
	public static void Hand(SaveTask task, int32 op)
	{
		int32 id;
		using (sLock.Enter())
		{
			id = sNextTask++;
			sPending[id] = task;
		}
		Span<uint8> data = op == 0 ? task.data : default;
		if (CSharpRuntime.SaveStorageCall(op, id, task.slot, data) < 0)
			FinishTask(id, 0, default, "The game's save storage threw an exception (see the Console).");
	}

	public static void List(List<String> slots)
	{
		sListing = slots;
		CSharpRuntime.SaveStorageCall(4, 0, "", default);
		sListing = null;
	}

	/// The C# storage's answer while listing: one slot that holds a save.
	[CSharpExpose]
	public static void ListSlot(StringView slot)
	{
		if (sListing != null && !slot.IsEmpty)
			sListing.Add(new String(slot));
	}

	/// The C# storage finished a write or read (outcome 1 done, 2 read but the slot was empty, 0 failed with error),
	/// from any thread. Loading: data is the save. False when the task is not waiting (finished already, or the
	/// storage was changed since).
	[CSharpExpose]
	public static bool FinishTask(int32 task, int32 outcome, Span<uint8> data, StringView error)
	{
		SaveTask waiting;
		using (sLock.Enter())
		{
			if (!sPending.TryGetValue(task, out waiting))
				return false;
			sPending.Remove(task);
		}
		if (outcome == 0)
		{
			waiting.Fail(error.IsEmpty ? "The save storage failed." : error);
			return true;
		}
		if (waiting.kind == .Load && outcome == 1)
		{
			waiting.data.Clear();
			waiting.data.AddRange(data);
		}
		waiting.Finish(true, outcome == 1);
		return true;
	}

	/// Saves go to the game's C# SaveStorage (on), or back to files (off; anything still on its way fails).
	[CSharpExpose]
	public static void UseStorage(bool on)
	{
		let current = SaveSystem.[Friend]sStorage;
		if (on)
		{
			if (!(current is CSharpSaveStorage))
				SaveSystem.Storage = new CSharpSaveStorage();
			return;
		}
		if (current is CSharpSaveStorage)
			SaveSystem.Storage = null;
		List<SaveTask> orphans = scope .();
		using (sLock.Enter())
		{
			for (let task in sPending.Values)
				orphans.Add(task);
			sPending.Clear();
		}
		for (let task in orphans)
			task.Fail("The game's save storage was replaced before it finished.");
	}
}

/// Hands saves to the game's C# SaveStorage (SaveGame.Storage).
class CSharpSaveStorage : SaveStorage
{
	public override void Write(SaveTask task) => CSharpSaves.Hand(task, 0);
	public override void Read(SaveTask task) => CSharpSaves.Hand(task, 1);
	public override bool Exists(StringView slot) => CSharpRuntime.SaveStorageCall(2, 0, slot, default) > 0;
	public override void Delete(StringView slot) => CSharpRuntime.SaveStorageCall(3, 0, slot, default);
	public override void List(List<String> slots) => CSharpSaves.List(slots);
}
