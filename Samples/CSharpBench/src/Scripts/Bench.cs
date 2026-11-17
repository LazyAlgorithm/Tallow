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
///                       pile (B13: from empty, Workload.PileBatch Ball spheres dropped every Workload.PileWindow
///                       frames until a window's p95 frame time passes 16.67 ms or TALLOW_BENCH_COUNT are in;
///                       TALLOW_BENCH_SLEEP=0 keeps them from sleeping)
///                       softbody (B15: TALLOW_BENCH_COUNT soft bodies of TALLOW_BENCH_SOFT jelly / cloth / shell /
///                       driven on a floor, each with a Squish script reading its velocity)
///                       render (B16, run in a window with --profile-report: TALLOW_BENCH_COUNT static cubes with no
///                       script, TALLOW_BENCH_MOVING of them moved by Mover scripts, and with TALLOW_BENCH_CHUNKS=1 a
///                       chunk of Workload.ChunkSize cubes destroyed and another made every Workload.ChunkFrames)
///                       graph (B21: cubes running the Bobber visual script, Graphs/Bobber.tgraph)
///                       soak (B23: the stability soak, Soak.cs and tools/run_csharp_soak.py)
///                       netsync / nethash (B18: multiplayer sync, NetSync.cs and tools/run_net_bench.py)
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
    // The first whole frame (soft bodies, characters... are made in it).
    private double _firstFrameMs;

    public override void Start()
    {
        _mode = Environment.GetEnvironmentVariable("TALLOW_BENCH_MODE") is { Length: > 0 } mode ? mode : _mode;
        if (int.TryParse(Environment.GetEnvironmentVariable("TALLOW_BENCH_COUNT"), out int count))
            _count = count;
        if (int.TryParse(Environment.GetEnvironmentVariable("TALLOW_BENCH_FRAMES"), out int frames))
            _frames = frames;
        _output = Environment.GetEnvironmentVariable("TALLOW_BENCH_OUT") ?? "";
        if (_mode is "netsync" or "nethash")
        {
            // B18: the networked workload runs in its own scene (NetSync.cs).
            SceneManager.Load("Scenes/NetSync.tscene");
            _mode = "soak";
            return;
        }
        if (_mode == "soak")
        {
            // B23: the soak runs in its own scene (Soak.cs), reloaded over and over.
            SoakRun.Begin();
            SoakRun.Load();
            return;
        }
        _halfSize = Workload.HalfSize(_count);
        // As EcsBench: frames as fast as they go, not at the screen's refresh.
        Quality.VSync = false;
        Transform.Position = new Vector3(0, _halfSize * 0.6f, -_halfSize * 3.2f);
        Transform.LookAt(Vector3.Zero);

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
        else if (_mode == "pile")
            StartPile();
        else if (_mode == "softbody")
            SpawnSoftBodies();
        else if (_mode == "render")
            SpawnRender();
        else if (_mode == "graph")
            SpawnGraphs();
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

    /// <summary>B21: cubes each running the Bobber visual script (Graphs/Bobber.tgraph, 10 nodes), compiled to C#;
    /// EcsBench compiles the same graph to Beef. One more object runs GraphOrder, which logs its events' order.</summary>
    private void SpawnGraphs()
    {
        for (int i = 0; i < _count; i++)
        {
            Workload.Start(i, _halfSize, out Vector3 position, out _, out _);
            GameObject cube = Scene.CreateGameObject("Cube");
            cube.Transform.LocalPosition = position;
            cube.Transform.LocalScale = new Vector3(Workload.CubeScale);
            cube.AddComponent<MeshRenderer>();
            cube.AddComponent<Graphs.Bobber>();
        }
        Scene.CreateGameObject("Order").AddComponent<Graphs.GraphOrder>();
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
            body.AllowSleeping = Environment.GetEnvironmentVariable("TALLOW_BENCH_SLEEP") != "0";
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

    private float _pileHalf;
    private bool _pileSleep = true;
    private readonly List<double> _pileWindow = new();
    private int _pileWindows, _pileReached;
    private double _pileStopP95;
    private string _pileStop = "";
    private GameObject? _pileEnd;

    private void StartPile()
    {
        _pileSleep = Environment.GetEnvironmentVariable("TALLOW_BENCH_SLEEP") != "0";
        _pileHalf = Workload.PhysicsHalfSize(_count);
        Workload.PhysicsBox(_pileHalf, out Vector3 floorPosition, out Vector3 floorSize);
        AddWall(floorPosition, floorSize);
        for (int side = 0; side < 4; side++)
        {
            Workload.PhysicsWall(_pileHalf, side, out Vector3 position, out Vector3 size);
            AddWall(position, size);
        }
        _frames = int.MaxValue; // the pile ends the run itself
    }

    /// <summary>Called each measured frame: a batch of balls at the start of each window; at its end, stop if the
    /// window's p95 frame time was over 16.67 ms or every ball is in.</summary>
    private void StepPile(double frameMs)
    {
        if (_pileStop.Length > 0)
            return;
        if (_pileWindow.Count == 0)
        {
            for (int i = 0; i < Workload.PileBatch && _bodies.Count < _count; i++)
            {
                GameObject ball = Scene.CreateGameObject("Ball");
                ball.Transform.LocalPosition = Workload.PileStart(_bodies.Count, _pileHalf);
                ball.AddComponent<SphereCollider>();
                Rigidbody body = ball.AddComponent<Rigidbody>();
                body.AllowSleeping = _pileSleep;
                ball.AddComponent<Ball>();
                _bodies.Add(body);
            }
            // The end marker goes after the new balls, so their Updates are inside the timed span.
            _pileEnd?.Destroy();
            _pileEnd = Scene.CreateGameObject("Bench End");
            _pileEnd.Value.AddComponent<BenchEnd>().Owner = this;
        }
        _pileWindow.Add(frameMs);
        if (_pileWindow.Count < Workload.PileWindow)
            return;
        double p95 = Percentile(_pileWindow, 0.95);
        _pileWindow.Clear();
        _pileWindows++;
        if (p95 > 16.67 || _bodies.Count >= _count)
        {
            _pileReached = _bodies.Count;
            _pileStopP95 = p95;
            _pileStop = p95 > 16.67 ? "p95" : "count";
            Finish();
        }
    }

    private readonly List<SoftBody> _soft = new();
    private string _softKind = "jelly";

    private void SpawnSoftBodies()
    {
        _softKind = Environment.GetEnvironmentVariable("TALLOW_BENCH_SOFT") is { Length: > 0 } kind ? kind : "jelly";
        float half = Workload.SoftHalfSize(_count);
        AddWall(new Vector3(0, -0.5f, 0), new Vector3(half * 2 + 4, 1, half * 2 + 4));
        for (int i = 0; i < _count; i++)
        {
            GameObject made = Scene.CreateGameObject("Soft");
            made.Transform.LocalPosition = Workload.SoftStart(i, _count);
            MeshRenderer renderer = made.AddComponent<MeshRenderer>();
            renderer.Mesh = Workload.SoftMesh(_softKind);
            if (_softKind is "shell" or "driven")
            {
                if (_softKind == "shell")
                    made.AddComponent<BoxCollider>();
                else
                    made.AddComponent<SphereCollider>();
                made.AddComponent<Rigidbody>();
            }
            SoftBody soft = made.AddComponent<SoftBody>();
            soft.Kind = Workload.SoftKind(_softKind);
            made.AddComponent<Squish>();
            _soft.Add(soft);
        }
    }

    private int _moving;
    private bool _chunks;
    private readonly Queue<List<GameObject>> _chunkQueue = new();
    private int _chunkIndex, _chunksMade;

    private void SpawnRender()
    {
        _ = int.TryParse(Environment.GetEnvironmentVariable("TALLOW_BENCH_MOVING"), out _moving);
        _chunks = Environment.GetEnvironmentVariable("TALLOW_BENCH_CHUNKS") == "1";
        _ = int.TryParse(Environment.GetEnvironmentVariable("TALLOW_BENCH_EFFECTS"), out _effects);
        for (int i = 0; i < _count; i++)
        {
            GameObject cube = Scene.CreateGameObject("Static");
            cube.Transform.LocalPosition = Workload.StaticAt(i, _count);
            cube.Transform.LocalScale = new Vector3(Workload.CubeScale);
            MeshRenderer renderer = cube.AddComponent<MeshRenderer>();
            if (_effects > 0 && i % 10 == 0)
                renderer.Material = "Materials/glow.tmat";
        }
        for (int i = 0; i < _moving; i++)
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
        if (_chunks)
            for (int c = 0; c < Workload.ChunksLive; c++)
                MakeChunk();
        // TALLOW_BENCH_EFFECTS=N: N quads running the ripple compute graph, and every 10th static cube on the glow
        // shader's material (shader and compute graph regression: the profile report counts their dispatches).
        for (int i = 0; i < _effects; i++)
        {
            GameObject screen = Scene.CreateGameObject("Ripple");
            screen.Transform.LocalPosition = Workload.EffectAt(i, _halfSize);
            screen.Transform.LocalScale = new Vector3(4);
            screen.AddComponent<MeshRenderer>().Mesh = "builtin:quad";
            ComputeEffect effect = screen.AddComponent<ComputeEffect>();
            effect.Shader = "Shaders/ripple.tcompute";
            effect.Width = effect.Height = 256;
        }
    }

    private int _effects;

    private void MakeChunk()
    {
        var chunk = new List<GameObject>(Workload.ChunkSize);
        for (int i = 0; i < Workload.ChunkSize; i++)
        {
            GameObject cube = Scene.CreateGameObject("Chunk");
            cube.Transform.LocalPosition = Workload.ChunkAt(_chunkIndex, i, _halfSize);
            cube.Transform.LocalScale = new Vector3(Workload.CubeScale);
            cube.AddComponent<MeshRenderer>();
            chunk.Add(cube);
        }
        _chunkIndex++;
        _chunksMade++;
        _chunkQueue.Enqueue(chunk);
    }

    private void StepChunks()
    {
        if (!_chunks || _frame % Workload.ChunkFrames != 0)
            return;
        foreach (GameObject cube in _chunkQueue.Dequeue())
            cube.Destroy();
        MakeChunk();
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
        if (_mode == "soak")
            return;
        long now = Stopwatch.GetTimestamp();
        if (_lastFrame != 0 && _frame == 1)
            _firstFrameMs = Stopwatch.GetElapsedTime(_lastFrame, now).TotalMilliseconds;
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
        else if (_mode == "pile" && _frame > WarmupFrames && _frameTimes.Count > 0)
            StepPile(_frameTimes[^1]);
        else if (_mode == "render")
            StepChunks();
    }

    public override void LocalLateUpdate(float deltaTime)
    {
        if (_mode == "soak")
            return;
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
        if (_mode == "render")
            line.Append($"\"static\": {_count}, \"moving\": {_moving}, \"chunks_made\": {_chunksMade}, \"effects\": {_effects}, ");
        if (_mode == "softbody")
        {
            int bodies = 0, vertices = 0, sleeping = 0;
            foreach (SoftBody soft in _soft)
            {
                if (soft.HasBody) bodies++;
                vertices += soft.SimulatedVertexCount;
                if (soft.IsSleeping) sleeping++;
            }
            line.Append($"\"soft\": \"{_softKind}\", \"bodies\": {bodies}, \"vertices\": {vertices}, \"sleeping\": {sleeping}, \"low\": {Squish.Low}, ");
        }
        if (_mode == "pile")
            line.Append(Inv($"\"sleep\": {(_pileSleep ? 1 : 0)}, \"reached\": {_pileReached}, \"stop\": \"{_pileStop}\", \"stop_p95_ms\": {_pileStopP95:F3}, \"windows\": {_pileWindows}, "));
        if (_mode == "physics" || _mode == "pile")
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
        line.Append(Inv($"\"first_frame_ms\": {_firstFrameMs:F3}, "));
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

/// <summary>The softbody mode's script: reads its body's velocity each tick, and notes one that fell through the
/// floor (its object below -1 m).</summary>
public class Squish : Script
{
    public static int Low;
    private SoftBody _soft;
    private float _speed;

    public override void Start() => _soft = GetComponent<SoftBody>();

    public override void Update(TickInput input, float deltaTime)
    {
        _speed = _soft.Velocity.Length();
        if (Transform.Position.Y < -1 && _speed >= 0) { Low++; _speed = -1; }
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

    /// <summary>The render mode: static cubes on a flat square grid 1.5 m apart, under the moving ones.</summary>
    public static Vector3 StaticAt(int index, int count)
    {
        int side = (int)MathF.Ceiling(MathF.Sqrt(count));
        return new Vector3(-side * 0.75f + (index % side) * 1.5f, -2, -side * 0.75f + (index / side) * 1.5f);
    }

    /// <summary>The render mode's compute-effect quads: a row in front of the camera.</summary>
    public static Vector3 EffectAt(int index, float halfSize) => new Vector3(-halfSize * 0.5f + index * 5, halfSize * 0.3f, -halfSize);

    /// <summary>The render mode's streamed chunks: ChunkSize cubes in a 10 m block, blocks round a ring.</summary>
    public const int ChunkSize = 1000, ChunkFrames = 30, ChunksLive = 4;

    public static Vector3 ChunkAt(int chunk, int index, float halfSize)
    {
        float angle = chunk * 0.7f;
        Vector3 center = new Vector3(MathF.Cos(angle) * halfSize * 1.5f, 0, MathF.Sin(angle) * halfSize * 1.5f);
        return center + new Vector3(index % 10, index / 100, index / 10 % 10);
    }

    /// <summary>The softbody mode: bodies 3 m apart in a square, 3 m up (cloth drops flat).</summary>
    public static float SoftHalfSize(int count) => MathF.Ceiling(MathF.Sqrt(count)) * 1.5f;

    public static Vector3 SoftStart(int index, int count)
    {
        int side = (int)MathF.Ceiling(MathF.Sqrt(count));
        return new Vector3(-side * 1.5f + 1.5f + (index % side) * 3, 3, -side * 1.5f + 1.5f + (index / side) * 3);
    }

    public static string SoftMesh(string kind) => kind switch
    {
        "cloth" => "builtin:plane",
        "shell" => "builtin:cube",
        _ => "builtin:sphere",
    };

    public static SoftBodyKind SoftKind(string kind) => kind switch
    {
        "cloth" => SoftBodyKind.Cloth,
        "shell" => SoftBodyKind.Shell,
        "driven" => SoftBodyKind.DrivenJelly,
        _ => SoftBodyKind.Jelly,
    };

    /// <summary>The pile mode: balls dropped per batch, frames per batch.</summary>
    public const int PileBatch = 250;
    public const int PileWindow = 60;

    /// <summary>Pile ball i: a batch is one layer near the top of the walls, dropped onto what is already there.</summary>
    public static Vector3 PileStart(int index, float half)
    {
        int side = Math.Max(1, (int)((half * 2 - 1) / 1.1f));
        int slot = index % PileBatch;
        int x = slot % side, z = slot / side % side, y = slot / (side * side);
        float jitter = (index / PileBatch % 2) * 0.3f;
        return new Vector3(-half + 0.55f + x * 1.1f + jitter, 30 + y * 1.1f, -half + 0.55f + z * 1.1f + jitter);
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
