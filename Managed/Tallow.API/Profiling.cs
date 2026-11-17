namespace Tallow;

/// <summary>Where the Profiler window files a marker's time or a counter (its CPU Usage colours and modules).</summary>
public enum ProfilerCategory : byte
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
    /// <summary>Time spent waiting (for the GPU, vsync, other threads).</summary>
    Waiting,
}

/// <summary>
/// A named stretch of time in Window &gt; Profiler, kept in a static field:
/// <code>
/// static readonly ProfilerMarker Pathfinding = new("Enemy Pathfinding", ProfilerCategory.AI);
///
/// using (Pathfinding.Auto())   // timed until the block's end
///     FindPaths();
/// </code>
/// It registers its name the first time it is used, and costs next to nothing while the profiler is not recording.
/// Begin and End must pair up on the same thread; markers nest.
/// </summary>
public sealed class ProfilerMarker
{
    private int id = -1;

    /// <summary>A marker of this name, filed under a category (Scripts unless given).</summary>
    public ProfilerMarker(string name, ProfilerCategory category = ProfilerCategory.Scripts)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        Name = name;
        Category = category;
    }

    /// <summary>Its name in the Profiler.</summary>
    public string Name { get; }
    /// <summary>Its category.</summary>
    public ProfilerCategory Category { get; }

    private int Id
    {
        get
        {
            int known = Volatile.Read(ref id);
            if (known < 0)
            {
                known = CSharpProfiler.Marker(Name, (int)Category);
                Volatile.Write(ref id, known);
            }
            return known;
        }
    }

    /// <summary>Starts timing on this thread.</summary>
    public void Begin() => CSharpProfiler.Begin(Id);

    /// <summary>Ends this thread's latest Begin.</summary>
    public void End() => CSharpProfiler.End();

    /// <summary>Begins now and ends when the returned scope is disposed (a <c>using</c> block).</summary>
    public Scope Auto()
    {
        CSharpProfiler.Begin(Id);
        return new Scope(true);
    }

    /// <summary>Ends the marker's Begin when disposed.</summary>
    public readonly struct Scope : IDisposable
    {
        private readonly bool open;

        internal Scope(bool open) => this.open = open;

        /// <summary>Ends the sample.</summary>
        public void Dispose()
        {
            if (open)
                CSharpProfiler.End();
        }
    }
}

/// <summary>
/// A number shown each frame in the Profiler's module for its category (enemies alive, paths found, bytes sent),
/// kept in a static field:
/// <code>
/// static readonly ProfilerCounter Enemies = new("Enemies Alive");
/// Enemies.Set(enemies.Count);   // Set keeps the last value in a frame; Add sums
/// </code>
/// A unit starting with "bytes" is shown as KB, MB and GB.
/// </summary>
public sealed class ProfilerCounter
{
    private int id = -1;

    /// <summary>A counter of this name (Scripts unless given), its values shown with <paramref name="unit"/>.</summary>
    public ProfilerCounter(string name, ProfilerCategory category = ProfilerCategory.Scripts, string unit = "")
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        Name = name;
        Category = category;
        Unit = unit ?? "";
    }

    /// <summary>Its name in the Profiler.</summary>
    public string Name { get; }
    /// <summary>Its category (the module it shows in).</summary>
    public ProfilerCategory Category { get; }
    /// <summary>The unit shown beside its values.</summary>
    public string Unit { get; }

    private int Id
    {
        get
        {
            int known = Volatile.Read(ref id);
            if (known < 0)
            {
                known = CSharpProfiler.Counter(Name, (int)Category, Unit);
                Volatile.Write(ref id, known);
            }
            return known;
        }
    }

    /// <summary>This frame's value (the last Set in a frame wins).</summary>
    public void Set(double value)
    {
        if (CSharpProfiler.Enabled())
            CSharpProfiler.SetCounter(Id, value);
    }

    /// <summary>Adds to this frame's value.</summary>
    public void Add(double amount)
    {
        if (CSharpProfiler.Enabled())
            CSharpProfiler.AddCounter(Id, amount);
    }
}

/// <summary>The engine's profiler (Window &gt; Profiler, <c>--profile</c>, a connected editor).</summary>
public static class Profiler
{
    /// <summary>Whether it is recording now. Markers and counters cost next to nothing while it is not.</summary>
    public static bool Enabled => CSharpProfiler.Enabled();

    /// <summary>Names the calling thread in captures ("Loader", "Path Worker").</summary>
    public static void NameThread(string name) => CSharpProfiler.NameThread(name ?? "");
}
