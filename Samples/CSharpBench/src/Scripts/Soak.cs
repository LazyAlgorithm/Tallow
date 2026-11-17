using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Numerics;
using System.Text;
using Tallow;

namespace CSharpBench;

/// <summary>
/// B23, the stability soak (tools/run_csharp_soak.py): TALLOW_BENCH_MODE=soak loads Scenes/Soak.tscene and keeps
/// one gameplay loop going for TALLOW_SOAK_SECONDS (default 1800), the scene reloaded every TALLOW_SOAK_CYCLE
/// seconds (default 25). Each scene life has Mover cubes, a pile of physics balls, soft bodies (torn down and made
/// again, a different kind each time), Lifer objects made and destroyed every few frames and network crates spawned
/// and despawned. TALLOW_SOAK_ROLE: offline (default), host (the session restarts with every reload, so clients
/// are dropped) or client (joins TALLOW_SOAK_ADDRESS and joins again whenever it is dropped).
/// TALLOW_SOAK_PORT is the port (default 47810).
///
/// Once a second a JSON line goes to TALLOW_BENCH_OUT (written at once, so a crash keeps what came before): frame
/// time median/p95/p99/max of that second, the process's RSS, the managed heap, bytes allocated, GCs, open file
/// handles, threads, scene objects, the cycle and network state. Frames a scene load fell in are not frame samples;
/// their time is a load time. At the end a "soak_done" line has the totals.
/// </summary>
public static class SoakRun
{
    public static bool Started;
    public static readonly Stopwatch Clock = new();
    public static double Seconds = 1800;
    public static double CycleSeconds = 25;
    public static string Role = "offline";
    public static string Address = "127.0.0.1";
    public static int Port = 47810;
    public static string Output = "";
    public static int Cycle;
    public static int Reconnects;
    public static int JoinFailures;
    public static int Loads;
    public static long Frames;
    public static long ScriptErrors;
    public static readonly List<double> FrameTimes = new();
    public static readonly List<double> LoadTimes = new();
    public static long LastFrame;
    public static double NextSample = 1;
    public static long LastAllocated;
    public static int SamplesWritten;
    public static bool Finished;
    /// <summary>The time a scene load started (0: none pending), so its frame counts as load time.</summary>
    public static long LoadStarted;

    public static void Begin()
    {
        if (Started)
            return;
        Started = true;
        Clock.Start();
        if (double.TryParse(Environment.GetEnvironmentVariable("TALLOW_SOAK_SECONDS"), NumberStyles.Float, CultureInfo.InvariantCulture, out double seconds))
            Seconds = seconds;
        if (double.TryParse(Environment.GetEnvironmentVariable("TALLOW_SOAK_CYCLE"), NumberStyles.Float, CultureInfo.InvariantCulture, out double cycle))
            CycleSeconds = cycle;
        Role = Environment.GetEnvironmentVariable("TALLOW_SOAK_ROLE") is { Length: > 0 } role ? role : Role;
        Address = Environment.GetEnvironmentVariable("TALLOW_SOAK_ADDRESS") is { Length: > 0 } address ? address : Address;
        if (int.TryParse(Environment.GetEnvironmentVariable("TALLOW_SOAK_PORT"), out int port))
            Port = port;
        Output = Environment.GetEnvironmentVariable("TALLOW_BENCH_OUT") ?? "";
        LastAllocated = GC.GetTotalAllocatedBytes(false);
        Quality.VSync = false;
        Console.WriteLine($"CSharpBench soak: {Role}, {Seconds:F0} s, a reload every {CycleSeconds:F0} s");
    }

    /// <summary>Loads the soak scene again, starting (or joining) the session first as the role says.</summary>
    public static void Load()
    {
        if (Role == "host")
            Network.Host(Port);
        else if (Role == "client")
            Network.Join(Address, Port);
        LoadStarted = Stopwatch.GetTimestamp();
        Loads++;
        SceneManager.Load("Scenes/Soak.tscene");
    }

    public static void Write(string line)
    {
        Console.WriteLine(line);
        if (Output.Length == 0)
            return;
        try
        {
            File.AppendAllText(Output, line + "\n");
        }
        catch (IOException)
        {
        }
    }

    private static double Percentile(List<double> sorted, double p) =>
        sorted.Count == 0 ? 0 : sorted[Math.Min((int)Math.Ceiling(p * sorted.Count) - 1, sorted.Count - 1)];

    private static int OpenFiles()
    {
        try
        {
            return Directory.Exists("/proc/self/fd") ? Directory.GetFileSystemEntries("/proc/self/fd").Length : -1;
        }
        catch (Exception)
        {
            return -1;
        }
    }

    /// <summary>One frame: its time (unless a load fell in it), and the second's sample when one is due.</summary>
    public static void Frame(Scene scene, bool connected)
    {
        long now = Stopwatch.GetTimestamp();
        if (LoadStarted != 0)
        {
            LoadTimes.Add(Stopwatch.GetElapsedTime(LoadStarted, now).TotalMilliseconds);
            LoadStarted = 0;
        }
        else if (LastFrame != 0)
            FrameTimes.Add(Stopwatch.GetElapsedTime(LastFrame, now).TotalMilliseconds);
        LastFrame = now;
        Frames++;
        double t = Clock.Elapsed.TotalSeconds;
        if (t < NextSample)
            return;
        NextSample = Math.Floor(t) + 1;
        FrameTimes.Sort();
        long allocated = GC.GetTotalAllocatedBytes(false);
        using Process self = Process.GetCurrentProcess();
        var line = new StringBuilder();
        line.Append(CultureInfo.InvariantCulture, $"{{\"soak\":\"{Role}\",\"t\":{t:F1},\"cycle\":{Cycle},\"frames\":{FrameTimes.Count}");
        line.Append(CultureInfo.InvariantCulture, $",\"frame_median_ms\":{Percentile(FrameTimes, 0.5):F3},\"frame_p95_ms\":{Percentile(FrameTimes, 0.95):F3}");
        line.Append(CultureInfo.InvariantCulture, $",\"frame_p99_ms\":{Percentile(FrameTimes, 0.99):F3},\"frame_max_ms\":{(FrameTimes.Count > 0 ? FrameTimes[^1] : 0):F3}");
        line.Append(CultureInfo.InvariantCulture, $",\"rss_mb\":{Environment.WorkingSet / 1048576.0:F1},\"managed_mb\":{GC.GetTotalMemory(false) / 1048576.0:F2}");
        line.Append(CultureInfo.InvariantCulture, $",\"alloc_mb\":{(allocated - LastAllocated) / 1048576.0:F3},\"gc0\":{GC.CollectionCount(0)},\"gc1\":{GC.CollectionCount(1)},\"gc2\":{GC.CollectionCount(2)}");
        line.Append(CultureInfo.InvariantCulture, $",\"gc_pause_ms\":{GC.GetTotalPauseDuration().TotalMilliseconds:F1},\"files\":{OpenFiles()},\"threads\":{self.Threads.Count}");
        line.Append(CultureInfo.InvariantCulture, $",\"objects\":{scene.ObjectCount},\"connected\":{(connected ? 1 : 0)},\"reconnects\":{Reconnects},\"join_failures\":{JoinFailures}");
        line.Append(CultureInfo.InvariantCulture, $",\"loads\":{Loads},\"last_load_ms\":{(LoadTimes.Count > 0 ? LoadTimes[^1] : 0):F1},\"lifers\":{Lifer.Alive}}}");
        Write(line.ToString());
        SamplesWritten++;
        FrameTimes.Clear();
        LastAllocated = allocated;
        if (t >= Seconds && !Finished)
        {
            Finished = true;
            var sortedLoads = new List<double>(LoadTimes);
            sortedLoads.Sort();
            Write(string.Create(CultureInfo.InvariantCulture,
                $"{{\"soak_done\":\"{Role}\",\"seconds\":{t:F1},\"frames\":{Frames},\"cycles\":{Cycle},\"loads\":{Loads},\"load_median_ms\":{Percentile(sortedLoads, 0.5):F1},\"load_p95_ms\":{Percentile(sortedLoads, 0.95):F1},\"reconnects\":{Reconnects},\"join_failures\":{JoinFailures},\"lifer_awakes\":{Lifer.Awakes},\"lifer_destroys\":{Lifer.Destroys}}}"));
            Application.Quit();
        }
    }
}

/// <summary>A network crate the soak's server spawns and despawns.</summary>
public class SoakCrate : Script
{
}

/// <summary>One life of the soak scene (SoakRun has what lasts across reloads).</summary>
public class Soak : Script
{
    private const int Movers = 2000;
    private const int Balls = 300;
    private const int SoftBodies = 8;
    private const int LiferBatch = 100;
    private const int Crates = 40;

    private static readonly string[] SoftKinds = ["jelly", "cloth", "shell", "driven"];

    private readonly Stopwatch _age = Stopwatch.StartNew();
    private readonly List<GameObject> _soft = new();
    private readonly List<GameObject> _lifers = new();
    private readonly Queue<GameObject> _crates = new();
    private int _frame;
    private bool _softTornDown;
    private bool _reloading;
    private bool _wasConnected;
    private double _lostAt = -1;

    public override void Start()
    {
        SoakRun.Begin();
        SoakRun.Cycle++;
        Network.RegisterPrefab("soakcrate", "Prefabs/SoakCrate.tprefab");
        Transform.Position = new Vector3(0, 30, -60);
        Transform.LookAt(Vector3.Zero);
        float half = Workload.HalfSize(Movers);
        for (int i = 0; i < Movers; i++)
        {
            Workload.Start(i, half, out Vector3 position, out Vector3 velocity, out Vector3 spin);
            GameObject cube = Scene.CreateGameObject("Cube");
            cube.Transform.LocalPosition = position + new Vector3(0, 0, 80);
            cube.Transform.LocalScale = new Vector3(Workload.CubeScale);
            cube.AddComponent<MeshRenderer>();
            Mover mover = cube.AddComponent<Mover>();
            mover.Velocity = velocity;
            mover.Spin = spin;
            mover.HalfSize = half;
        }
        float box = Workload.PhysicsHalfSize(Balls);
        Workload.PhysicsBox(box, out Vector3 floorPosition, out Vector3 floorSize);
        AddWall(floorPosition, floorSize);
        for (int side = 0; side < 4; side++)
        {
            Workload.PhysicsWall(box, side, out Vector3 position, out Vector3 size);
            AddWall(position, size);
        }
        for (int i = 0; i < Balls; i++)
        {
            GameObject ball = Scene.CreateGameObject("Ball");
            ball.Transform.LocalPosition = Workload.PhysicsStart(i, box);
            ball.AddComponent<SphereCollider>();
            ball.AddComponent<Rigidbody>();
            ball.AddComponent<Ball>();
        }
        AddWall(new Vector3(-40, -0.5f, 0), new Vector3(20, 1, 20));
        MakeSoftBodies(SoftKinds[SoakRun.Cycle % SoftKinds.Length]);
    }

    private void AddWall(Vector3 position, Vector3 size)
    {
        GameObject wall = Scene.CreateGameObject("Wall");
        wall.Transform.LocalPosition = position;
        wall.Transform.LocalScale = size;
        wall.AddComponent<BoxCollider>();
    }

    private void MakeSoftBodies(string kind)
    {
        for (int i = 0; i < SoftBodies; i++)
        {
            GameObject made = Scene.CreateGameObject("Soft");
            made.Transform.LocalPosition = new Vector3(-46 + (i % 4) * 4, 2 + i / 4 * 3, -3 + (i / 4) * 4);
            MeshRenderer renderer = made.AddComponent<MeshRenderer>();
            renderer.Mesh = Workload.SoftMesh(kind);
            if (kind is "shell" or "driven")
            {
                if (kind == "shell")
                    made.AddComponent<BoxCollider>();
                else
                    made.AddComponent<SphereCollider>();
                made.AddComponent<Rigidbody>();
            }
            SoftBody soft = made.AddComponent<SoftBody>();
            soft.Kind = Workload.SoftKind(kind);
            made.AddComponent<Squish>();
            _soft.Add(made);
        }
    }

    public override void LocalUpdate(float deltaTime)
    {
        bool connected = SoakRun.Role == "offline" || Network.IsConnected(Scene);
        SoakRun.Frame(Scene, connected);
        if (SoakRun.Finished || _reloading)
            return;
        _frame++;
        double age = _age.Elapsed.TotalSeconds;

        // Objects with scripts made and destroyed every few frames.
        if (_frame % 6 == 0)
        {
            foreach (GameObject made in _lifers)
                made.Destroy();
            _lifers.Clear();
            for (int i = 0; i < LiferBatch; i++)
            {
                GameObject made = Scene.CreateGameObject("Lifer");
                made.Transform.LocalPosition = new Vector3(40 + i % 10, 1, i / 10);
                made.AddComponent<MeshRenderer>();
                made.AddComponent<Lifer>();
                _lifers.Add(made);
            }
        }

        // The server spawns network crates and despawns the oldest.
        if (Scene.IsServer && _frame % 30 == 0)
        {
            while (_crates.Count >= Crates)
                Scene.Despawn(_crates.Dequeue());
            for (int i = 0; i < 10; i++)
            {
                if (Scene.Spawn("soakcrate", new Vector3(20 + (_frame / 30 % 10), 1, i), Quaternion.Identity) is { } crate)
                    _crates.Enqueue(crate);
            }
        }

        // Halfway through the scene's life, its soft bodies are torn down and others made.
        if (!_softTornDown && age >= SoakRun.CycleSeconds * 0.6)
        {
            _softTornDown = true;
            foreach (GameObject soft in _soft)
                soft.Destroy();
            _soft.Clear();
            MakeSoftBodies(SoftKinds[(SoakRun.Cycle + 2) % SoftKinds.Length]);
        }

        if (SoakRun.Role == "client")
        {
            // Dropped (the host reloaded): join again.
            if (connected)
            {
                _wasConnected = true;
                _lostAt = -1;
            }
            else if (_lostAt < 0)
                _lostAt = age;
            else if (age - _lostAt > (_wasConnected ? 0.5 : 10))
            {
                if (_wasConnected)
                    SoakRun.Reconnects++;
                else
                    SoakRun.JoinFailures++;
                _reloading = true;
                SoakRun.Load();
            }
            return;
        }
        if (age >= SoakRun.CycleSeconds)
        {
            _reloading = true;
            SoakRun.Load();
        }
    }
}
