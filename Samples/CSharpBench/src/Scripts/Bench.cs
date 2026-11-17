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
///                       getcomponent (TALLOW_BENCH_COUNT GetComponent calls a frame: native and script, hit and miss),
///                       physics (TALLOW_BENCH_COUNT Jolt spheres falling into a walled box, each with a Ball script
///                       reading its velocity and damping it), lifecycle (every other frame TALLOW_BENCH_COUNT objects
///                       with a Lifer script are made, the frame after they are destroyed; counts Awake/OnDestroy),
///                       alloc (TALLOW_BENCH_COUNT objects with an Allocator script running one pattern a frame,
///                       TALLOW_BENCH_ALLOC: math (Vector3/Quaternion value math), event (a C# event with a class
///                       argument and a capturing lambda), getcomponent (three GetComponent calls), string (the
///                       object's Name from the engine and a formatted string); managed bytes and GCs per frame)
///                       raycast / spherecast (TALLOW_BENCH_COUNT Jolt queries a frame over a field of 400 boxes;
///                       hits and a checksum of their distances must equal Beef's), character (TALLOW_BENCH_COUNT
///                       CharacterControllers, each walked by a Walker script every tick)
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
        else if (_mode == "physics")
            SpawnPhysics();
        else if (_mode == "lifecycle")
            _lifecycleMemoryStart = GC.GetTotalMemory(true);
        else if (_mode == "alloc")
            SpawnAllocators();
        else if (_mode == "raycast" || _mode == "spherecast")
            SpawnQueryField();
        else if (_mode == "character")
            SpawnWalkers();
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

    private readonly List<Rigidbody> _bodies = new();
    private readonly List<GameObject> _lifers = new();
    private readonly List<double> _createTimes = new();
    private readonly List<double> _destroyTimes = new();
    private long _lifecycleMemoryStart;

    private void SpawnPhysics()
    {
        float half = Workload.PhysicsHalfSize(_count);
        Workload.PhysicsBox(half, out Vector3 floorPosition, out Vector3 floorSize);
        AddWall(floorPosition, floorSize);
        for (int side = 0; side < 4; side++)
        {
            Workload.PhysicsWall(half, side, out Vector3 position, out Vector3 size);
            AddWall(position, size);
        }
        for (int i = 0; i < _count; i++)
        {
            GameObject ball = Scene.CreateGameObject("Ball");
            ball.Transform.LocalPosition = Workload.PhysicsStart(i, half);
            ball.AddComponent<SphereCollider>();
            Rigidbody body = ball.AddComponent<Rigidbody>();
            ball.AddComponent<Ball>();
            _bodies.Add(body);
        }
    }

    private void SpawnAllocators()
    {
        Allocator.Pattern = Environment.GetEnvironmentVariable("TALLOW_BENCH_ALLOC") switch
        {
            "event" => 1, "getcomponent" => 2, "string" => 3, _ => 0,
        };
        _allocPattern = Environment.GetEnvironmentVariable("TALLOW_BENCH_ALLOC") is { Length: > 0 } name ? name : "math";
        for (int i = 0; i < _count; i++)
        {
            GameObject made = Scene.CreateGameObject($"Allocator {i}");
            made.AddComponent<MeshRenderer>();
            made.AddComponent<Allocator>();
        }
    }

    private string _allocPattern = "";
    private long _hits;
    private readonly List<GameObject> _walkers = new();

    private void SpawnQueryField()
    {
        AddWall(new Vector3(0, -0.5f, 0), new Vector3(102, 1, 102));
        for (int i = 0; i < Workload.QueryObstacles; i++)
        {
            Workload.QueryObstacle(i, out Vector3 position, out Vector3 size);
            AddWall(position, size);
        }
    }

    /// <summary>Every query of the frame; the last frame's hits and distances (to the millimetre) are reported.</summary>
    private void StepQueries()
    {
        Scene scene = Scene;
        bool sphere = _mode == "spherecast";
        long hits = 0, checksum = 0;
        for (int i = 0; i < _count; i++)
        {
            Workload.QueryRay(i, out Vector3 origin, out Vector3 direction);
            PhysicsContact? contact = sphere
                ? scene.SphereCast(origin, Workload.QueryRadius, direction, Workload.QueryMaxDistance)
                : scene.Raycast(origin, direction, Workload.QueryMaxDistance);
            if (contact is { } hit)
            {
                hits++;
                checksum += (long)(hit.Distance * 1000);
            }
        }
        _hits = hits;
        _checksum = checksum;
    }

    private void SpawnWalkers()
    {
        float half = Workload.WalkerHalfSize(_count);
        AddWall(new Vector3(0, -0.5f, 0), new Vector3(half * 2, 1, half * 2));
        for (int i = 0; i < _count; i++)
        {
            GameObject walker = Scene.CreateGameObject("Walker");
            walker.Transform.LocalPosition = Workload.WalkerStart(i, _count);
            walker.AddComponent<CharacterController>();
            walker.AddComponent<Walker>().Index = i;
            _walkers.Add(walker);
        }
    }

    private void AddWall(Vector3 position, Vector3 size)
    {
        GameObject wall = Scene.CreateGameObject("Wall");
        wall.Transform.LocalPosition = position;
        wall.AddComponent<BoxCollider>().Size = size;
    }

    private void StepLifecycle()
    {
        var watch = Stopwatch.StartNew();
        if (_lifers.Count == 0)
        {
            for (int i = 0; i < _count; i++)
            {
                GameObject made = Scene.CreateGameObject("Lifer");
                made.AddComponent<Lifer>();
                _lifers.Add(made);
            }
            if (_frame > WarmupFrames)
                _createTimes.Add(watch.Elapsed.TotalMilliseconds);
        }
        else
        {
            foreach (GameObject made in _lifers)
                made.Destroy();
            _lifers.Clear();
            if (_frame > WarmupFrames)
                _destroyTimes.Add(watch.Elapsed.TotalMilliseconds);
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
        else if (_mode == "lifecycle")
            StepLifecycle();
        else if (_mode == "raycast" || _mode == "spherecast")
            StepQueries();
    }

    public override void LocalLateUpdate(float deltaTime)
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
        if (_mode == "physics")
        {
            int sleeping = 0;
            foreach (Rigidbody body in _bodies)
                if (body.IsSleeping) sleeping++;
            line.Append($"\"bodies\": {_bodies.Count}, \"sleeping\": {sleeping}, ");
        }
        if (_mode == "lifecycle")
        {
            // Destroyed objects' OnDestroy runs at frame end: what is still alive is the last batch made (or none).
            line.Append(Inv($"\"create_avg_ms\": {Average(_createTimes):F3}, \"destroy_avg_ms\": {Average(_destroyTimes):F3}, "));
            line.Append($"\"cycles\": {_destroyTimes.Count}, \"awakes\": {Lifer.Awakes}, \"destroys\": {Lifer.Destroys}, ");
            line.Append($"\"alive\": {Lifer.Alive}, \"expected_alive\": {_lifers.Count}, ");
            _lifers.Clear();
            line.Append($"\"managed_growth_bytes\": {GC.GetTotalMemory(true) - _lifecycleMemoryStart}, ");
        }
        if (_mode == "raycast" || _mode == "spherecast")
            line.Append($"\"hits\": {_hits}, ");
        if (_mode == "character")
        {
            _checksum = Walker.Checksum;
            line.Append($"\"walkers\": {_walkers.Count}, \"checked\": {Walker.Checked}, \"grounded\": {Walker.Grounded}, ");
        }
        if (_mode == "alloc")
            line.Append($"\"pattern\": \"{_allocPattern}\", \"allocator_checksum\": {Allocator.Checksum}, ");
        line.Append($"\"memory_peak\": {Process.GetCurrentProcess().PeakWorkingSet64}, ");
        line.Append($"\"memory_end\": {Environment.WorkingSet}, ");
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

/// <summary>The physics mode's control path: read the body's velocity and damp it while it moves.</summary>
public class Ball : Script
{
    private Rigidbody _body;

    public override void Start() => _body = GetComponent<Rigidbody>();

    public override void Update(TickInput input, float deltaTime)
    {
        Vector3 velocity = _body.Velocity;
        if (velocity.LengthSquared() > Workload.DampAbove * Workload.DampAbove)
            _body.AddForce(velocity * -Workload.Damping);
    }
}

/// <summary>The character mode's walker: one SimpleMove a tick.</summary>
public class Walker : Script
{
    public int Index;
    private CharacterController _controller;
    private int _tick;

    public override void Start() => _controller = GetComponent<CharacterController>();

    /// <summary>Where every walker stood after exactly WalkerCheckTick ticks, to the centimetre (frames hold a
    /// varying number of ticks).</summary>
    public static long Checksum;
    public static int Grounded, Checked;

    public override void Update(TickInput input, float deltaTime)
    {
        _controller.SimpleMove(Workload.WalkerVelocity(Index, _tick++), deltaTime);
        if (_tick == Workload.WalkerCheckTick)
        {
            Vector3 p = Transform.Position;
            Checksum += (long)(p.X * 100) + (long)(p.Y * 100) * 7 + (long)(p.Z * 100) * 13;
            Checked++;
            if (_controller.IsGrounded) Grounded++;
        }
    }
}

/// <summary>The alloc mode's object: one allocation pattern each Update (Allocator.Pattern).</summary>
public class Allocator : Script
{
    public static int Pattern;
    public static long Checksum;

    public sealed class Hit : EventArgs
    {
        public float Damage;
        public Hit(float damage) => Damage = damage;
    }

    public event EventHandler<Hit>? Hurt;
    private Vector3 _value = Vector3.One;
    private Quaternion _turn = Quaternion.Identity;
    private int _frame;

    public override void Update(TickInput input, float deltaTime)
    {
        _frame++;
        switch (Pattern)
        {
            case 0:
                _turn = Quaternion.Normalize(_turn * Quaternion.Euler(new Vector3(1, 2, 3) * deltaTime));
                _value = Vector3.Transform(_value, _turn) * 0.999f + Vector3.UnitY * deltaTime;
                if (_value.Y > 1e6f) Checksum++;
                break;
            case 1:
                RaiseEvent();
                break;
            case 2:
                if (GetComponent<MeshRenderer>().IsValid) Checksum++;
                if (GetComponent<Allocator>() != null) Checksum++;
                if (GetComponent<Rigidbody>().IsValid) Checksum++;
                break;
            case 3:
                string name = GameObject.Name;
                string label = $"{name} {_frame}";
                Checksum += label.Length;
                break;
        }
    }

    // A method of its own: a lambda's captured local makes C# allocate its closure where the local's scope starts,
    // and a switch is one scope, so in Update every pattern would pay for it.
    private void RaiseEvent()
    {
        int frame = _frame;
        Hurt += (sender, hit) => Checksum += (long)hit.Damage + frame;
        Hurt?.Invoke(this, new Hit(1));
        Hurt = null;
    }
}

/// <summary>The lifecycle mode's object: counts Awake and OnDestroy calls.</summary>
public class Lifer : Script
{
    public static int Awakes, Destroys, Alive;

    public override void Awake()
    {
        Awakes++;
        Alive++;
    }

    public override void OnDestroy()
    {
        Destroys++;
        Alive--;
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

    public const float DampAbove = 0.5f;
    public const float Damping = 0.2f;

    /// <summary>Half the inside width of the physics mode's box: about 0.8 m² of floor per ball, ten layers deep.</summary>
    public static float PhysicsHalfSize(int count) => MathF.Max(3, MathF.Sqrt(count / 10f) * 0.6f);

    public static void PhysicsBox(float half, out Vector3 position, out Vector3 size)
    {
        position = new Vector3(0, -0.5f, 0);
        size = new Vector3(half * 2 + 2, 1, half * 2 + 2);
    }

    /// <summary>Wall 0-3: +X, -X, +Z, -Z, tall enough to hold every layer.</summary>
    public static void PhysicsWall(float half, int side, out Vector3 position, out Vector3 size)
    {
        float height = 40;
        float offset = half + 0.5f;
        position = side switch
        {
            0 => new Vector3(offset, height / 2, 0),
            1 => new Vector3(-offset, height / 2, 0),
            2 => new Vector3(0, height / 2, offset),
            _ => new Vector3(0, height / 2, -offset),
        };
        size = side < 2 ? new Vector3(1, height, half * 2 + 2) : new Vector3(half * 2 + 2, height, 1);
    }

    /// <summary>Balls (radius 0.5) in a grid 1.1 m apart, layer above layer, with a small offset per layer.</summary>
    public static Vector3 PhysicsStart(int index, float half)
    {
        int side = Math.Max(1, (int)((half * 2 - 1) / 1.1f));
        int x = index % side, z = index / side % side, y = index / (side * side);
        float jitter = (y % 2) * 0.3f;
        return new Vector3(-half + 0.55f + x * 1.1f + jitter, 1 + y * 1.1f, -half + 0.55f + z * 1.1f + jitter);
    }

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

    /// <summary>The query modes' field (B14): a 102 m floor with 400 boxes of five heights on a 5 m grid.</summary>
    public const int QueryObstacles = 400;
    public const float QueryMaxDistance = 40;
    public const float QueryRadius = 0.3f;

    public static void QueryObstacle(int index, out Vector3 position, out Vector3 size)
    {
        float height = 1f + index % 5;
        position = new Vector3(-47.5f + (index % 20) * 5, height / 2, -47.5f + (index / 20) * 5);
        size = new Vector3(2, height, 2);
    }

    /// <summary>Query i: from 12 m up somewhere over the field, down at a slant (not normalised: both languages pass
    /// the same vector to the same physics call).</summary>
    public static void QueryRay(int index, out Vector3 origin, out Vector3 direction)
    {
        uint seed = (uint)index * 2654435761U + 777;
        float Next()
        {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            return (seed & 0xFFFFFF) / (float)0xFFFFFF * 2 - 1;
        }
        origin = new Vector3(Next() * 48, 12, Next() * 48);
        direction = new Vector3(Next() * 0.5f, -1, Next() * 0.5f);
    }

    /// <summary>The character mode: walkers 2 m apart on a floor with room round them.</summary>
    public static float WalkerHalfSize(int count) => MathF.Ceiling(MathF.Sqrt(count)) + 4;

    public static Vector3 WalkerStart(int index, int count)
    {
        int side = (int)MathF.Ceiling(MathF.Sqrt(count));
        return new Vector3(-side + 1 + (index % side) * 2, 1.2f, -side + 1 + (index / side) * 2);
    }

    /// <summary>The tick at which each walker's position goes into the checksum.</summary>
    public const int WalkerCheckTick = 300;

    /// <summary>Walking in a slowly turning direction, each walker its own phase.</summary>
    public static Vector3 WalkerVelocity(int index, int tick)
    {
        float angle = index * 0.7f + tick * 0.05f;
        return new Vector3(MathF.Cos(angle) * 2, 0, MathF.Sin(angle) * 2);
    }
}
