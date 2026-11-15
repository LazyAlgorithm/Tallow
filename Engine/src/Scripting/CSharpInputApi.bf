using System;

namespace Tallow;

/// Mouse pointer capture for C# gameplay, backed by Input.LockCursor: the
/// engine releases it when play stops, and in the editor it only takes hold
/// while the Game view is being played in.
[CSharpExpose]
static class Cursor
{
	[CSharpExpose]
	public static bool IsLocked() => Input.LockCursor;

	[CSharpExpose]
	public static void SetLocked(bool locked)
	{
		Input.LockCursor = locked;
	}
}
