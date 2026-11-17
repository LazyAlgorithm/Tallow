using System;
using System.Collections;

namespace Tallow;

/// The anti-cheat for C# (Managed/Tallow.API/AntiCheat.cs). Kinds and actions are CheatKind and CheatAction as
/// numbers. Violations are read by index, newest last; ViolationTotal counts every one since the program started,
/// so C# can tell which are new (its OnViolation event) even after the list has dropped old ones.
[CSharpExpose]
static class CSharpAntiCheat
{
	static int64 sTotal;
	static bool sCounting;

	static void Count()
	{
		if (sCounting)
			return;
		sCounting = true;
		AntiCheat.OnViolation.Add(new (clientId, kind, detail) => { sTotal++; });
	}

	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	static NetworkManager Session(uint64 session) => CSharpRuntime.PhysicsScene(session)?.Network;

	[CSharpExpose]
	public static bool GetEnabled() => AntiCheat.Enabled;

	[CSharpExpose]
	public static void SetEnabled(bool enabled) => AntiCheat.Enabled = enabled;

	[CSharpExpose]
	public static void SetAction(int32 kind, int32 action)
	{
		if (kind >= 0 && kind < (int32)CheatKind.Count)
			AntiCheat.SetAction((CheatKind)kind, (CheatAction)Math.Clamp(action, 0, 2));
	}

	[CSharpExpose]
	public static int32 GetAction(int32 kind) => kind >= 0 && kind < (int32)CheatKind.Count ? (int32)AntiCheat.GetAction((CheatKind)kind) : 0;

	/// Server: something the game caught itself, handled by its kind's action.
	[CSharpExpose]
	public static void Report(uint64 session, int32 clientId, int32 kind, StringView detail)
	{
		if (kind >= 0 && kind < (int32)CheatKind.Count)
			AntiCheat.Report(clientId, (CheatKind)kind, detail, Session(session));
	}

	[CSharpExpose]
	public static void ReportShot(uint64 session, int32 clientId) => AntiCheat.ReportShot(clientId, Session(session));

	[CSharpExpose]
	public static void ReportHit(uint64 session, int32 clientId, bool headshot) => AntiCheat.ReportHit(clientId, headshot, Session(session));

	/// One of the aim numbers for a player: 0 shots, 1 hits, 2 head shots, 3 hits straight after an instant turn.
	[CSharpExpose]
	public static int32 AimStat(uint64 session, int32 clientId, int32 which)
	{
		AntiCheat.AimStats(clientId, let shots, let hits, let headshots, let snapHits, Session(session));
		switch (which)
		{
		case 0: return shots;
		case 1: return hits;
		case 2: return headshots;
		default: return snapHits;
		}
	}

	/// A player's machine: something found here (a guarded value changed), told to the server.
	[CSharpExpose]
	public static void ReportLocal(int32 kind, StringView detail)
	{
		if (kind >= 0 && kind < (int32)CheatKind.Count)
			AntiCheat.ReportLocal((CheatKind)kind, detail);
	}

	/// Every violation found since the program started (counting starts with the first call).
	[CSharpExpose]
	public static int64 ViolationTotal()
	{
		Count();
		return sTotal;
	}

	[CSharpExpose]
	public static int32 ViolationCount() => (int32)AntiCheat.Violations.Count;

	/// A kept violation (0 the oldest): its client in the result's low 32 bits, its kind in the next 16.
	[CSharpExpose]
	public static int64 ViolationAt(int32 index)
	{
		if (index < 0 || index >= AntiCheat.Violations.Count)
			return -1;
		let violation = AntiCheat.Violations[index];
		return (int64)(uint32)violation.clientId | ((int64)(int32)violation.kind << 32);
	}

	[CSharpExpose]
	public static float ViolationTime(int32 index) => index >= 0 && index < AntiCheat.Violations.Count ? AntiCheat.Violations[index].time : 0;

	[CSharpExpose]
	public static int32 ViolationDetail(int32 index, Span<uint8> buffer) =>
		index >= 0 && index < AntiCheat.Violations.Count ? Copy(AntiCheat.Violations[index].detail, buffer) : -1;

	/// On a player's machine: why the server removed it, or empty.
	[CSharpExpose]
	public static int32 KickReason(Span<uint8> buffer) => Copy(AntiCheat.KickReason, buffer);

	[CSharpExpose]
	public static void Ban(StringView key) => AntiCheat.Ban(key);

	[CSharpExpose]
	public static void Unban(StringView key) => AntiCheat.Unban(key);

	[CSharpExpose]
	public static bool IsBanned(StringView key) => AntiCheat.IsBanned(key);

	[CSharpExpose]
	public static int32 BansToText(Span<uint8> buffer)
	{
		let text = scope String();
		AntiCheat.BansToText(text);
		return Copy(text, buffer);
	}

	[CSharpExpose]
	public static void BansFromText(StringView text) => AntiCheat.BansFromText(text);

	/// Server: removes a player from the session. False on a client, without a session, or for an unknown id.
	[CSharpExpose]
	public static bool Kick(uint64 session, int32 clientId)
	{
		let network = Session(session);
		return network != null && network.IsServer && network.Kick(clientId);
	}
}
