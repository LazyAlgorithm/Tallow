using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Text;
using Tallow;

namespace CSharpBench;

/// <summary>
/// The C# side of the Beef-versus-C# benchmark: the same cubes and rules as Samples/EcsBench (Workload), run by C#
/// scripts or a C# ECS query. tools/run_csharp_bench.py runs both and prints them side by side. Set by environment
/// variables, as EcsBench is:
///   TALLOW_BENCH_MODE   gameobject (a Mover script per cube), ecs (a Scene.Query over bare entities, not drawn),
///                       getcomponent (TALLOW_BENCH_COUNT GetComponent calls a frame: native and script, hit and miss)
///   TALLOW_BENCH_COUNT  how many cubes (default 10000)
///   TALLOW_BENCH_FRAMES frames measured after a 120 frame warm-up (default 600)
///   TALLOW_BENCH_OUT    file a JSON line of results is added to
/// Frame time is from one Update to the next. Script time is from this script's Update to BenchEnd's, which is
/// added after every Mover and so runs after them.
/// </summary>
public class Bench : Script
{
    private const int WarmupFrames = 120;

    private string _mode = "gameobject";
    private int _count = 10000;
    private int _frames = 600;
    private string _output = "";
    private float _halfSize;

    private readonly List<double> _frameTimes = new();
    private readonly List<double> _updateTimes = new();
    private readonly List<double> _scriptTimes = new();
    private long _lastFrame;
    private long _updateStart;
    private int _frame;
    private double _spawnMs;
    private long _memoryBefore, _memoryAfter;
    private long _allocatedStart;
    private int _gen0Start, _gen1Start, _gen2Start;
    private TimeSpan _pauseStart;
    private TimeSpan _cpuStart;
    private long _checksum;

    public override void Start()
    {
        _mode = Environment.GetEnvironmentVariable("TALLOW_BENCH_MODE") is { Length: > 0 } mode ? mode : _mode;
        if (int.TryParse(Environment.GetEnvironmentVariable("TALLOW_BENCH_COUNT"), out int count))
            _count = count;
        if (int.TryParse(Environment.GetEnvironmentVariable("TALLOW_BENCH_FRAMES"), out int frames))
            _frames = frames;
        _output = Environment.GetEnvironmentVariable("TALLOW_BENCH_OUT") ?? "";
        _halfSize = Workload.HalfSize(_count);
        Transform.Position = new Vector3(0, _halfSize * 0.6f, -_halfSize * 3.2f);

        _memoryBefore = Environment.WorkingSet;
        var watch = Stopwatch.StartNew();
        if (_mode == "gameobject")
            SpawnGameObjects();
        else if (_mode == "ecs")
            SpawnEntities();
        else if (_mode == "getcomponent")
            GameObject.AddComponent<MeshRenderer>();
        else
            throw new ArgumentException($"Unknown TALLOW_BENCH_MODE {_mode}");
        _spawnMs = watch.Elapsed.TotalMilliseconds;
        GameObject.AddComponent<BenchEnd>().Owner = this;
        Console.WriteLine($"CSharpBench: {_mode}, {_count} cubes, spawned in {_spawnMs:F1} ms");
    }

    private void SpawnGameObjects()
    {
        for (int i = 0; i < _count; i++)
        {
            Workload.Start(i, _halfSize, out Vector3 position, out Vector3 velocity, out Vector3 spin);
            GameObject cube = Scene.CreateGameObject("Cube");
            cube.Transform.LocalPosition = position;
            cube.Transform.LocalScale = new Vector3(Workload.CubeScale);
            cube.AddComponent<MeshRenderer>();
            Mover mover = cube.AddComponent<Mover>();
            mover.Velocity = velocity;
            mover.Spin = spin;
            mover.HalfSize = _halfSize;
        }
    }

    private void SpawnEntities()
    {
        for (int i = 0; i < _count; i++)
        {
            Workload.Start(i, _halfSize, out Vector3 position, out Vector3 velocity, out Vector3 spin);
            EcsEntity entity = Scene.CreateLocalEcsEntity();
            entity.Set(new Pose { Position = position, Rotation = Quaternion.Identity });
            entity.Set(new Motion { Velocity = velocity, Spin = spin });
        }
    }

    public override void Update(TickInput input, float deltaTime)
    {
        long now = Stopwatch.GetTimestamp();
        if (_lastFrame != 0 && _frame > WarmupFrames)
            _frameTimes.Add(Stopwatch.GetElapsedTime(_lastFrame, now).TotalMilliseconds);
        _lastFrame = now;
        _frame++;
        if (_frame == WarmupFrames)
        {
            _memoryAfter = Environment.WorkingSet;
            _allocatedStart = GC.GetTotalAllocatedBytes(false);
            _gen0Start = GC.CollectionCount(0);
            _gen1Start = GC.CollectionCount(1);
            _gen2Start = GC.CollectionCount(2);
            _pauseStart = GC.GetTotalPauseDuration();
            _cpuStart = Process.GetCurrentProcess().TotalProcessorTime;
        }
        _updateStart = Stopwatch.GetTimestamp();
        if (_mode == "ecs")
        {
            float halfSize = _halfSize;
            Scene.Query<Pose, Motion>().ForEach((EcsEntity entity, ref Pose pose, ref Motion motion) =>
            {
                Workload.Step(ref pose.Position, ref motion.Velocity, halfSize, deltaTime);
                pose.Rotation = Quaternion.Normalize(pose.Rotation * Quaternion.Euler(motion.Spin * deltaTime));
            });
        }
        else if (_mode == "getcomponent")
        {
            long found = 0;
            for (int i = 0; i < _count; i++)
            {
                // Half hits (a native component and this script), half misses.
                if ((i & 3) == 0 && GetComponent<MeshRenderer>().IsValid) found++;
                else if ((i & 3) == 1 && GetComponent<Bench>() != null) found++;
                else if ((i & 3) == 2 && GetComponent<Rigidbody>().IsValid) found++;
                else if ((i & 3) == 3 && GetComponent<Mover>() != null) found++;
            }
            _checksum += found;
        }
    }

    public override void LateUpdate(float deltaTime)
    {
        if (_frame > WarmupFrames)
            _updateTimes.Add(Stopwatch.GetElapsedTime(_updateStart).TotalMilliseconds);
        if (_frameTimes.Count >= _frames)
            Finish();
    }

    internal void EndScriptUpdates()
    {
        if (_frame > WarmupFrames)
            _scriptTimes.Add(Stopwatch.GetElapsedTime(_updateStart).TotalMilliseconds);
    }

    private void Finish()
    {
        int measured = _frameTimes.Count;
        double cpu = (Process.GetCurrentProcess().TotalProcessorTime - _cpuStart).TotalMilliseconds;
        var line = new StringBuilder();
        line.Append($"{{\"lang\": \"csharp\", \"mode\": \"{_mode}\", \"count\": {_count}, \"frames\": {measured}, ");
        line.Append(Inv($"\"frame_avg_ms\": {Average(_frameTimes):F3}, \"frame_p50_ms\": {Percentile(_frameTimes, 0.5):F3}, "));
        line.Append(Inv($"\"frame_p95_ms\": {Percentile(_frameTimes, 0.95):F3}, \"frame_p99_ms\": {Percentile(_frameTimes, 0.99):F3}, "));
        line.Append(Inv($"\"update_avg_ms\": {Average(_updateTimes):F3}, \"update_p99_ms\": {Percentile(_updateTimes, 0.99):F3}, "));
        line.Append(Inv($"\"script_only_avg_ms\": {Average(_scriptTimes):F3}, \"script_only_p99_ms\": {Percentile(_scriptTimes, 0.99):F3}, "));
        line.Append(Inv($"\"cpu_ms_per_frame\": {cpu / Math.Max(measured, 1):F3}, "));
        line.Append(Inv($"\"gc_bytes_per_frame\": {(GC.GetTotalAllocatedBytes(false) - _allocatedStart) / Math.Max(measured, 1)}, "));
        line.Append($"\"gc_gen0\": {GC.CollectionCount(0) - _gen0Start}, \"gc_gen1\": {GC.CollectionCount(1) - _gen1Start}, ");
        line.Append($"\"gc_gen2\": {GC.CollectionCount(2) - _gen2Start}, ");
        line.Append(Inv($"\"gc_pause_ms\": {(GC.GetTotalPauseDuration() - _pauseStart).TotalMilliseconds:F3}, "));
        line.Append(Inv($"\"spawn_ms\": {_spawnMs:F1}, \"memory_before\": {_memoryBefore}, \"memory_after\": {_memoryAfter}, "));
        line.Append($"\"checksum\": {_checksum}}}");
        string text = line.ToString();
        Console.WriteLine(text);
        if (_output.Length > 0)
            File.AppendAllText(_output, text + "\n");
        _frameTimes.Clear();
        Application.Quit();
    }

    private static string Inv(FormattableString text) => FormattableString.Invariant(text);

    private static double Average(List<double> values)
    {
        if (values.Count == 0)
            return 0;
        double total = 0;
        foreach (double value in values)
            total += value;
        return total / values.Count;
    }

    private static double Percentile(List<double> values, double fraction)
    {
        if (values.Count == 0)
            return 0;
        var sorted = new List<double>(values);
        sorted.Sort();
        return sorted[Math.Min((int)(fraction * sorted.Count), sorted.Count - 1)];
    }
}

/// <summary>Added after every Mover, so its Update marks the end of the scripts' updates.</summary>
public class BenchEnd : Script
{
    internal Bench? Owner;

    public override void Update(TickInput input, float deltaTime) => Owner?.EndScriptUpdates();
}

/// <summary>The GameObject version: one script per cube, as EcsBench's Mover.</summary>
public class Mover : Script
{
    public Vector3 Velocity;
    public Vector3 Spin;
    public float HalfSize = 10;

    public override void Update(TickInput input, float deltaTime)
    {
        var transform = Transform;
        Vector3 position = transform.LocalPosition;
        Workload.Step(ref position, ref Velocity, HalfSize, deltaTime);
        transform.LocalPosition = position;
        transform.Rotate(Spin * deltaTime);
    }
}

[Component]
public struct Pose
{
    public Vector3 Position;
    public Quaternion Rotation;
}

[Component]
public struct Motion
{
    public Vector3 Velocity;
    public Vector3 Spin;
}

/// <summary>Samples/EcsBench's Workload, line for line: cubes bouncing round a box and spinning.</summary>
public static class Workload
{
    public const float CubeScale = 0.5f;

    public static float HalfSize(int count) => MathF.Max(4, MathF.Pow(count, 1 / 3.0f) * 1.5f);

    public static void Step(ref Vector3 position, ref Vector3 velocity, float halfSize, float deltaTime)
    {
        position += velocity * deltaTime;
        if (position.X > halfSize || position.X < -halfSize)
        {
            velocity.X = -velocity.X;
            position.X = Math.Clamp(position.X, -halfSize, halfSize);
        }
        if (position.Y > halfSize || position.Y < -halfSize)
        {
            velocity.Y = -velocity.Y;
            position.Y = Math.Clamp(position.Y, -halfSize, halfSize);
        }
        if (position.Z > halfSize || position.Z < -halfSize)
        {
            velocity.Z = -velocity.Z;
            position.Z = Math.Clamp(position.Z, -halfSize, halfSize);
        }
    }

    public static void Start(int index, float halfSize, out Vector3 position, out Vector3 velocity, out Vector3 spin)
    {
        uint seed = (uint)index * 2654435761U + 12345;
        float Next()
        {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            return (seed & 0xFFFFFF) / (float)0xFFFFFF * 2 - 1;
        }
        position = new Vector3(Next() * halfSize, Next() * halfSize, Next() * halfSize);
        velocity = new Vector3(Next() * 4, Next() * 4, Next() * 4);
        spin = new Vector3(Next() * 90, Next() * 90, Next() * 90);
    }
}
