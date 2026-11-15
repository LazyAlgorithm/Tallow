using System.Globalization;
using System.Numerics;
using Tallow;

namespace {NAMESPACE};

/// <summary>
/// The Tallow Gallery: a courtyard, a hall of reflections, a room of lights, a yard of things to knock over and a
/// soft body lab. Everything in it is an ordinary object in Scenes/Gallery.tscene, so it can be moved in the
/// editor; this script is what moves while playing. Objects it animates are found by name.
/// </summary>
public class Gallery : Script
{
    private readonly record struct Room(string Name, string About, Vector2 Min, Vector2 Max);

    // Rooms by their floor area (x, z).
    private static readonly Room[] Rooms =
    [
        new("Hall of Reflections", "Each probe box matches its room, so the walls line up in the floor and in every sphere.", new(-14, 1), new(14, 19)),
        new("Room of Lights", "Clustered point lights with shadows, a spot light, and emissive tubes through bloom.", new(14, 3), new(28, 17)),
        new("Physics Yard", "Walk into the stack, or press E to shove what you are looking at. The ball hangs on a rope.", new(16, -34), new(44, -4)),
        new("Pool Garden", "Built-in water, grass and bushes that sway in the wind, and a character skinned on the GPU.", new(-44, -34), new(-8, -4)),
        new("Voxel Quarry", "Fire balls to blast chunks out of anything here, or hold right click to cut through it, a van included.", new(16, -62), new(46, -34)),
        new("Terrain Field", "The ground is voxels. Hold right click to dig, Q to raise it. Caves and overhangs work, and collision follows.", new(-46, -62), new(-8, -34)),
        new("Soft Body Lab", "Left click to fire balls. Steel shells dent and stay dented, jelly wobbles, cloth folds, and robots path round it all.", new(-8, -60), new(16, -34)),
        new("Courtyard", "Sun, shadows, wind in the flag. The Hall of Reflections is ahead, the Soft Body Lab behind you.", new(-8, -34), new(16, 1)),
    ];

    // Test switch --view N: places worth a screenshot (position, yaw, pitch).
    private static readonly (Vector3 At, float Yaw, float Pitch)[] Places =
    [
        (new(4, 1.1f, -28), 0, 0), (new(0, 1.1f, 3), 0, 6), (new(-12, 1.1f, 3), 50, 6), (new(15, 1.6f, 6), 62, 6),
        (new(19, 1.1f, -28), 40, 4), (new(-14, 1.1f, -9), 240, 10), (new(-34, 1.1f, -11), 60, 4), (new(4, 1.1f, -38), 180, 8),
        (new(-5, 1.1f, -42), 150, 4), (new(3, 1.1f, -8), 200, -12), (new(30.6f, 1.6f, -40), 180, 0), (new(-14, 1.1f, -44), 270, 12),
        (new(-28, 1.1f, -22), 180, 10), (new(-14.5f, 1.6f, -58), -15, 20), (new(7, 1.1f, 10), 90, 8), (new(6, 1.1f, 13), 180, 10),
        (new(12.5f, 1.1f, 9), 80, 22), (new(17, 1.1f, 11), 260, 14), (new(1, 1.1f, 9), 180, 12), (new(21, 1.1f, -24), 90, 0),
    ];

    private const int MaxBalls = 24;

    private GameObject? _walker;
    private readonly GameObject?[] _orbiters = new GameObject?[3];
    private readonly Light[] _braziers = new Light[2];
    private readonly List<NavigationAgent> _robots = [];
    private readonly List<Rigidbody> _balls = [];
    private VoxelTerrain? _terrain;
    private bool _sculpted;
    private float _nextCut;
    private int _testCuts, _testShots, _netReport = -1;
    private Rigidbody _fired;
    private Vector3 _firedVelocity;
    private Visitor? _visitor;
    private UIDocument _hud;
    private int _room = -1;
    private float _walkAngle;
    private uint _seed;
    private readonly Dictionary<string, Vector3> _sharedAtStart = [];

    public override void Start()
    {
        _walker = Scene.Find("Walking figure");
        for (int i = 0; i < _orbiters.Length; i++)
            _orbiters[i] = Scene.Find($"Orbiting light {i}");
        for (int i = 0; i < _braziers.Length; i++)
            _braziers[i] = Scene.Find($"Brazier light {i}")?.GetComponent<Light>() ?? default;
        _terrain = VoxelTerrain.Find(Scene);
        for (int i = 0; i < 2; i++)
        {
            if (Scene.Find($"Patrol robot {i}")?.GetComponent<NavigationAgent>() is { IsValid: true } robot)
                _robots.Add(robot);
        }

        // Each machine has its own visitor: a capsule that walks and looks, seeing through the scene's camera.
        GameObject person = Scene.CreateGameObject("Visitor");
        person.Transform.Position = new Vector3(4, 1.1f, -28);
        CharacterController body = person.AddComponent<CharacterController>();
        body.Radius = 0.34f;
        body.StandingHeight = 1.8f;
        body.PushStrength = 180;
        _visitor = person.AddComponent<Visitor>();
        _visitor.View = Scene.Find("Camera");
        GameObject hud = Scene.CreateGameObject("Hud");
        _hud = hud.AddComponent<UIDocument>();
        _hud.Document = "UI/hud.tui";

        if (CommandLine.Get("--view") is not null)
            Stand(CommandLine.GetInt("--view"));
        _testShots = CommandLine.GetInt("--fire-test");
        _testCuts = CommandLine.GetInt("--cut-test");
        _netReport = CommandLine.GetInt("--net-report", -1);
        NoteShared();
        Scene.CreateGameObject("Script and system crowd").AddComponent<GalleryCrowd>();
        if (CommandLine.Has("--self-test"))
            Console.WriteLine($"SHOWCASE_READY rooms={Rooms.Length} probes={Scene.CountComponents("Tallow.ReflectionProbe")} objects={Scene.ObjectCount}");
    }

    /// <summary>Test switch --view N: stand somewhere worth a screenshot.</summary>
    private void Stand(int view)
    {
        if (_visitor is null)
            return;
        var place = Places[Math.Clamp(view, 0, Places.Length - 1)];
        _visitor.GetComponent<CharacterController>().Teleport(place.At);
        _visitor.Yaw = place.Yaw;
        _visitor.Pitch = place.Pitch;
    }

    public override void Update(TickInput input, float deltaTime)
    {
        if (_visitor is null)
            return;
        float t = Time.RealTime;
        // The lights go round their room, each at its own pace.
        for (int i = 0; i < _orbiters.Length; i++)
        {
            float angle = t * (0.5f + i * 0.17f) + i * 2.1f;
            if (_orbiters[i] is { } orbiter)
                orbiter.Transform.Position = new Vector3(21 + MathF.Cos(angle) * 4.2f, 2.4f + MathF.Sin(t + i) * 0.8f, 10 + MathF.Sin(angle) * 4.2f);
        }
        for (int i = 0; i < _braziers.Length; i++)
        {
            if (_braziers[i].IsValid)
                _braziers[i].Intensity = 9 + MathF.Sin(t * 11 + i) * 1.5f + MathF.Sin(t * 23 + i * 3) * 1.1f;
        }
        if (_walker is { } walker)
        {
            _walkAngle += Time.DeltaTime * 0.45f;
            walker.Transform.Position = new Vector3(-30 + MathF.Cos(_walkAngle) * 4.5f, 0, -8 + MathF.Sin(_walkAngle) * 2.5f);
            walker.Transform.Rotation = Quaternion.Euler(0, -_walkAngle * 180f / MathF.PI, 0);
        }
        if (Input.GetKeyDown(KeyCode.E))
            Shove();
        if ((Cursor.Locked && Input.GetMouseButtonDown(MouseButton.Left)) ||
            (_testShots > 0 && Time.FrameCount > 60 && Time.FrameCount % 12 == 0 && _testShots-- > 0))
            Fire();
        // A new ball has its body from the next frame: then it gets its speed.
        if (_fired.HasBody)
        {
            _fired.Velocity = _firedVelocity;
            _fired = default;
        }
        _nextCut -= Time.DeltaTime;
        if (_nextCut <= 0)
        {
            if (Cursor.Locked && Input.GetMouseButton(MouseButton.Right))
                Cut(-1);
            else if (Cursor.Locked && Input.GetKey(KeyCode.Q))
                Cut(1);
        }
        if (_testCuts > 0 && Time.FrameCount > 60 && Time.FrameCount % 4 == 0 && --_testCuts >= 0)
            Cut(-1);
        ShapeTheField();
        BlastVoxels();
        foreach (NavigationAgent robot in _robots)
        {
            // A robot not yet sent anywhere has neither arrived nor failed: it is sent off too.
            if (!robot.PathPending && (robot.HasArrived || robot.PathFailed || robot.PathCornerCount == 0))
                robot.SetDestination(new Vector3(-6 + Scatter() * 20, 0, -57 + Scatter() * 19), 2.2f, 0.4f);
        }
        ShowRoom();
        if (Time.FrameCount == _netReport)
            ReportShared();
    }

    private Transform? View => _visitor?.View?.Transform;

    /// <summary>Pushes whatever rigid body the visitor is looking at.</summary>
    private void Shove()
    {
        if (View is not { } view)
            return;
        // Starts past the visitor's own capsule, which the ray would otherwise hit first.
        if (Scene.RaycastHit(view.Position + view.Forward * 0.7f, view.Forward, 14) is { HitObject: { } hit })
            hit.GetComponent<Rigidbody>().AddImpulse(view.Forward * 60);
    }

    /// <summary>Where the eye points: a thin cut through a voxel object, or a dig (-1) or mound (1) in the ground.</summary>
    private void Cut(int direction)
    {
        _nextCut = 0.07f;
        if (View is not { } view ||
            Scene.RaycastHit(view.Position + view.Forward * 0.7f, view.Forward, 30) is not { HitObject: { } hit } contact)
            return;
        if (hit.GetComponent<VoxelObject>() is { IsValid: true } voxels)
        {
            if (direction < 0)
                voxels.Carve(contact.Point, 0.45f);
        }
        // Terrain rays land on its chunks, which are children of the terrain's object.
        else if (_terrain is { } terrain && hit.Parent == terrain.GameObject)
        {
            _nextCut = 0.12f;
            terrain.ModifySphere(contact.Point, 2.2f, direction * 2);
        }
    }

    /// <summary>Hills and a hollow, once the ground exists. The terrain tile itself stays flat and editable.</summary>
    private void ShapeTheField()
    {
        if (_sculpted || _terrain is not { } terrain || terrain.ChunkCount == 0 || terrain.PendingChunks > 0)
            return;
        _sculpted = true;
        // All of it stays clear of the tile's edges (x -40..-16, z -60..-36), which would slice it into cliffs.
        for (int i = 0; i < 7; i++)
            terrain.ModifySphere(new Vector3(-33 + i * 0.8f, 0, -45 + i * 0.5f), 6 - i * 0.4f, 3);
        terrain.ModifySphere(new Vector3(-22, 0.5f, -53), 5, -3);
        terrain.ModifySphere(new Vector3(-20, 0.5f, -41), 3.5f, 3);
    }

    /// <summary>A ball about to reach a voxel object blows a hole in it where it lands.</summary>
    private void BlastVoxels()
    {
        foreach (Rigidbody ball in _balls)
        {
            if (!ball.HasBody)
                continue;
            Vector3 velocity = ball.Velocity;
            float speed = velocity.Length();
            if (speed < 6)
                continue;
            float step = speed * Time.DeltaTime + 0.3f;
            if (Scene.RaycastHit(ball.GameObject.Transform.Position, velocity / speed, step) is { HitObject: { } hit } contact &&
                hit.GetComponent<VoxelObject>() is { IsValid: true } carved)
                carved.Carve(contact.Point, 0.9f);
        }
    }

    /// <summary>A heavy ball from the eye, fast enough to dent a shell. The oldest goes once there are too many.</summary>
    private void Fire()
    {
        if (View is not { } view)
            return;
        GameObject ball = Scene.CreateGameObject("Launched ball");
        ball.Transient = true;
        ball.Transform.Position = view.Position + view.Forward * 0.9f;
        ball.Transform.LocalScale = new Vector3(0.5f);
        MeshRenderer look = ball.AddComponent<MeshRenderer>();
        look.Mesh = "builtin:sphere_smooth";
        look.FlatShading = false;
        look.Color = new Color(0.95f, 0.75f, 0.2f);
        look.Metallic = 1;
        look.Roughness = 0.3f;
        ball.AddComponent<SphereCollider>();
        Rigidbody body = ball.AddComponent<Rigidbody>();
        body.Mass = 55;
        _fired = body;
        _firedVelocity = view.Forward * 30;
        _balls.Add(body);
        if (_balls.Count > MaxBalls)
        {
            _balls[0].GameObject.Destroy();
            _balls.RemoveAt(0);
        }
    }

    private void ShowRoom()
    {
        if (_visitor is null)
            return;
        Vector3 at = _visitor.Transform.Position;
        int room = Rooms.Length - 1;
        for (int i = 0; i < Rooms.Length; i++)
        {
            Room r = Rooms[i];
            if (at.X >= r.Min.X && at.X <= r.Max.X && at.Z >= r.Min.Y && at.Z <= r.Max.Y)
            {
                room = i;
                break;
            }
        }
        if (room == _room)
            return;
        _room = room;
        _hud.Find("room")?.SetText(Rooms[room].Name);
        _hud.Find("about")?.SetText(Rooms[room].About);
    }

    private float Scatter()
    {
        _seed = _seed * 1664525U + 1013904223U;
        return ((_seed >> 16) & 0xFFFF) / 65535f;
    }

    // Test switch --net-report N: at frame N, says what is shared and where each shared object is.

    private static IEnumerable<(string Id, Vector3 At)> SharedPositions(string report)
    {
        foreach (string line in report.Split('\n'))
        {
            string[] parts = line.Split(' ', 6);
            if (parts.Length >= 5 && parts[0] == "NETPOS")
                yield return (parts[1], new Vector3(ParseFloat(parts[2]), ParseFloat(parts[3]), ParseFloat(parts[4])));
        }
    }

    private static float ParseFloat(string text) => float.Parse(text, CultureInfo.InvariantCulture);

    private void NoteShared()
    {
        foreach (var (id, at) in SharedPositions(Network.Report(Scene)))
            _sharedAtStart[id] = at;
    }

    private void ReportShared()
    {
        string report = Network.Report(Scene);
        string first = report.Split('\n')[0];
        if (first == "offline")
        {
            Console.WriteLine("SHOWCASE_NET offline");
            foreach (NavigationAgent robot in _robots)
            {
                Vector3 at = robot.GameObject.Transform.Position;
                Console.WriteLine(string.Create(CultureInfo.InvariantCulture, $"ROBOT {at.X:0.000} {at.Z:0.000}"));
            }
            return;
        }
        int moved = SharedPositions(report).Count(p => _sharedAtStart.TryGetValue(p.Id, out Vector3 start) && Vector3.Distance(p.At, start) > 0.5f);
        Console.WriteLine($"SHOWCASE_NET {first} moved={moved}");
        Console.Write(report[(first.Length + 1)..]);
    }
}
