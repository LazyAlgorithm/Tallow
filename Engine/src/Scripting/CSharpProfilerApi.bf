using System;

namespace Tallow;

/// The profiler for C# scripts (ProfilerMarker, ProfilerCounter and Profiler in Tallow.API).
[CSharpExpose]
static class CSharpProfiler
{
	/// The id of a marker (category: ProfilerCategory).
	[CSharpExpose]
	public static int32 Marker(StringView name, int32 category) => Profiler.Marker(name, Category(category));

	/// The id of a counter.
	[CSharpExpose]
	public static int32 Counter(StringView name, int32 category, StringView unit) => Profiler.Counter(name, Category(category), unit);

	[CSharpExpose]
	public static void Begin(int32 marker) => Profiler.Begin(marker);

	[CSharpExpose]
	public static void End() => Profiler.End();

	[CSharpExpose]
	public static void SetCounter(int32 counter, double value)
	{
		if (Profiler.Enabled)
			Profiler.Set(counter, value);
	}

	[CSharpExpose]
	public static void AddCounter(int32 counter, double amount)
	{
		if (Profiler.Enabled)
			Profiler.Add(counter, amount);
	}

	[CSharpExpose]
	public static bool Enabled() => Profiler.Enabled;

	[CSharpExpose]
	public static void NameThread(StringView name) => Profiler.NameThread(name);

	static ProfilerCategory Category(int32 value) =>
		value >= 0 && value <= (int32)ProfilerCategory.Waiting ? (ProfilerCategory)value : .Other;
}
