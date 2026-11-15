using System;

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
}
