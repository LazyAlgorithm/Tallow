using System;

namespace Tallow;

/// Timed script sequences using one ordinary float field. Initialise the field to -1 (stopped), Start a wait,
/// then Advance it with Update's supplied deltaTime. Public float fields already participate in scene saving,
/// script reload and lockstep history, so a wait can be restored and replayed with the rest of the script.
static class ScriptTimer
{
	/// Starts or restarts a wait in seconds. A zero wait completes on the next Advance call.
	public static void Start(ref float remaining, float seconds)
	{
		remaining = seconds.IsFinite ? Math.Max(seconds, 0) : -1;
	}

	/// Cancels the wait without reporting completion.
	public static void Stop(ref float remaining)
	{
		remaining = -1;
	}

	/// Returns true once when the wait finishes. A stopped timer never completes until Start is called again.
	public static bool Advance(ref float remaining, float deltaTime)
	{
		if (!remaining.IsFinite || remaining < 0 || !deltaTime.IsFinite || deltaTime < 0)
			return false;
		remaining -= deltaTime;
		if (remaining > 0)
			return false;
		remaining = -1;
		return true;
	}
}
