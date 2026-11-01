using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// What SaveSystem.Save and Load return: a number standing for that save or load, to ask about later. It stays
/// good however long it is kept.
struct SaveHandle
{
	/// Which save or load this is.
	public readonly int32 id;
	/// A handle on a save or load by its id.
	public this(int32 id)
	{
		this.id = id;
	}

	/// Whether the save or load has finished, well or not.
	public bool Done => SaveSystem.[Friend]OutcomeOf(id).done;
	/// Whether it finished and worked.
	public bool Succeeded => SaveSystem.[Friend]OutcomeOf(id).succeeded;
	/// Loading: whether the slot held a save.
	public bool Found => SaveSystem.[Friend]OutcomeOf(id).found;
	/// Why it did not work (empty if it did).
	public void Error(String text) => text.Append(SaveSystem.[Friend]OutcomeOf(id).error ?? "");
}

/// One save or load on its way: SaveSystem.Save and Load return it, and a SaveStorage finishes it, at once or later
/// (an upload to a server, say), from any thread. SaveSystem notices on the next frame and fires its events.
class SaveTask
{
	/// Whether a task saves or loads.
	public enum Kind { Save, Load }

	/// Whether this task saves or loads.
	public readonly Kind kind;
	/// The save slot it is for.
	public readonly String slot = new .() ~ delete _;
	/// Saving: the bytes to keep. Loading: the storage puts the bytes it found here.
	public readonly List<uint8> data = new .() ~ delete _;
	/// Why it failed, when it did: for the player or the log.
	public readonly String error = new .() ~ delete _;
	Monitor mLock = new .() ~ delete _;
	bool mDone, mSucceeded, mFound;
	// SaveSystem's own bookkeeping.
	bool mApplied, mReported;
	int32 mId;

	/// A task for a slot.
	public this(Kind kind, StringView slot)
	{
		this.kind = kind;
		this.slot.Set(slot);
	}

	/// Whether the task has finished, well or not.
	public bool Done
	{
		get
		{
			using (mLock.Enter()) return mDone;
		}
	}

	/// Whether it finished and worked.
	public bool Succeeded
	{
		get
		{
			using (mLock.Enter()) return mSucceeded;
		}
	}

	/// Loading: whether the storage had a save in that slot.
	public bool Found
	{
		get
		{
			using (mLock.Enter()) return mFound;
		}
	}

	/// Storage: the save is written, or the bytes are in data (found: false when the slot is empty).
	public void Finish(bool succeeded, bool found = true)
	{
		using (mLock.Enter())
		{
			mSucceeded = succeeded;
			mFound = succeeded && found;
			mDone = true;
		}
	}

	/// Storage: something went wrong.
	public void Fail(StringView why)
	{
		using (mLock.Enter())
		{
			error.Set(why);
			mDone = true;
		}
	}
}

/// Where saves go: a folder on this machine, a server, a cloud service, memory. SaveSystem makes the bytes and
/// hands them over; a storage only keeps and returns them. Derive from this to send saves somewhere of your own,
/// and set SaveSystem.Storage once (in GameSetup.Register, say):
///
///   class ServerStorage : SaveStorage
///   {
///       public override void Write(SaveTask task) { /* upload task.data, then task.Finish(true) */ }
///       public override void Read(SaveTask task) { /* download into task.data, then task.Finish(true) */ }
///   }
///
/// Write and Read may finish at once or later, on any thread: call task.Finish (or Fail) when done.
abstract class SaveStorage
{
	/// Writes a save task's data to its slot, then calls Finish on it (now or later, from any thread).
	public abstract void Write(SaveTask task);
	/// Reads a slot's data into a load task, then calls Finish on it.
	public abstract void Read(SaveTask task);
	/// Whether a slot holds a save. A storage that cannot tell without asking a server answers false.
	public virtual bool Exists(StringView slot) => false;
	/// Deletes a slot's save, if there is one.
	public virtual void Delete(StringView slot) { }
	/// The slots that hold saves, where the storage can list them.
	public virtual void List(List<String> slots) { }
}

/// Saves as files in the player's own folder for the game (on Windows in AppData, on Linux in ~/.local/share, in
/// a browser in its storage): one file per slot, written whole to a temporary file first so that a crash while
/// saving never leaves half a save.
class FileSaveStorage : SaveStorage
{
	/// The folder the save files are in.
	public readonly String folder = new .() ~ delete _;

	/// GamePaths.Saves when folder is empty.
	public this(StringView folder = default)
	{
		if (!folder.IsEmpty)
			this.folder.Set(folder);
		else
			GamePaths.Saves(this.folder);
		while (this.folder.EndsWith('/') || this.folder.EndsWith('\\'))
			this.folder.RemoveFromEnd(1);
	}

	/// A slot's name as a file name every system accepts, and back. Letters (any language), digits, spaces and
	/// most punctuation stay as they are; the few characters file names cannot hold are written as %XX.
	public static void FileNameOf(StringView slot, String fileName)
	{
		for (int i < slot.Length)
		{
			let c = slot[i];
			let edge = (i == 0 && (c == '.' || c == ' ')) || (i == slot.Length - 1 && (c == '.' || c == ' '));
			if ((uint8)c < 0x20 || c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|' || c == '%' || edge)
				fileName.AppendF("%{0:X2}", (int)(uint8)c);
			else
				fileName.Append(c);
		}
		if (slot.IsEmpty)
			fileName.Append("%00");
	}

	/// The slot a save file's name belongs to.
	public static void SlotOf(StringView fileName, String slot)
	{
		for (int i = 0; i < fileName.Length; i++)
		{
			if (fileName[i] == '%' && i + 2 < fileName.Length && (uint8.Parse(fileName.Substring(i + 1, 2), .HexNumber) case .Ok(let code)))
			{
				if (code != 0)
					slot.Append((char8)code);
				i += 2;
			}
			else
				slot.Append(fileName[i]);
		}
	}

	void PathOf(StringView slot, String path)
	{
		path.Append(folder);
		path.Append('/');
		FileNameOf(slot, path);
		path.Append(".tsave");
	}

	public override void Write(SaveTask task)
	{
		Directory.CreateDirectory(folder).IgnoreError();
		let path = PathOf(task.slot, .. scope .());
		let temporary = scope $"{path}.new";
		if (File.WriteAll(temporary, task.data) case .Err)
		{
			task.Fail(scope $"Could not write {temporary}.");
			return;
		}
		if (File.Exists(path))
			File.Delete(path).IgnoreError();
		if (File.Move(temporary, path) case .Err)
		{
			task.Fail(scope $"Could not replace {path}.");
			return;
		}
		// In a browser, files reach its storage a few seconds later on their own; a save goes now.
		WebPlatform.Persist();
		task.Finish(true);
	}

	public override void Read(SaveTask task)
	{
		let path = PathOf(task.slot, .. scope .());
		if (!File.Exists(path))
		{
			task.Finish(true, false);
			return;
		}
		if (File.ReadAll(path, task.data) case .Err)
		{
			task.Fail(scope $"Could not read {path}.");
			return;
		}
		task.Finish(true);
	}

	public override bool Exists(StringView slot) => File.Exists(PathOf(slot, .. scope .()));

	public override void Delete(StringView slot)
	{
		File.Delete(PathOf(slot, .. scope .())).IgnoreError();
		WebPlatform.Persist();
	}

	public override void List(List<String> slots)
	{
		if (!Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (name.EndsWith(".tsave"))
			{
				name.RemoveFromEnd(6);
				slots.Add(SlotOf(name, .. new String()));
			}
		}
	}
}

/// Saves kept in memory while the game runs: quick saves, tests, or a staging step before a slower storage.
class MemorySaveStorage : SaveStorage
{
	Dictionary<String, List<uint8>> mSlots = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	public override void Write(SaveTask task)
	{
		if (mSlots.TryGetValueAlt(task.slot, let existing))
		{
			existing.Clear();
			existing.AddRange(task.data);
		}
		else
			mSlots[new String(task.slot)] = new List<uint8>()..AddRange(task.data);
		task.Finish(true);
	}

	public override void Read(SaveTask task)
	{
		if (!mSlots.TryGetValueAlt(task.slot, let existing))
		{
			task.Finish(true, false);
			return;
		}
		task.data.AddRange(existing);
		task.Finish(true);
	}

	public override bool Exists(StringView slot) => mSlots.ContainsKeyAlt(slot);

	public override void Delete(StringView slot)
	{
		if (mSlots.GetAndRemoveAlt(slot) case .Ok(let entry))
		{
			delete entry.key;
			delete entry.value;
		}
	}

	public override void List(List<String> slots)
	{
		for (let key in mSlots.Keys)
			slots.Add(new String(key));
	}
}
