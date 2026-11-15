using Tallow;

namespace InGame;

/// Base class: its fields must be catalogued and restored for derived scripts.
public abstract class CheckBase : Script
{
    [ShowInInspector] private float baseSecret = 2f;
    public bool Flag = true;
    protected float BaseSecret => baseSecret;

    private int _failures;

    protected void Check(string label, bool condition)
    {
        if (condition)
            Log.Info("INGAME PASS " + label);
        else
        {
            _failures++;
            Log.Error("INGAME FAIL " + label);
        }
    }

    protected void Finish() => Log.Info(_failures == 0 ? "INGAME DONE" : $"INGAME FAILED {_failures}");
}

/// Runs inside the real engine (tools/test_csharp_ingame.py): exercises the
/// C# gameplay API against the native scene, physics and ECS.
public class ApiChecks : CheckBase
{
    public float Speed = 1f;
    public string Label = "default";

    private int _tick;
    private int _fixedTicks;
    private bool _started;
    private Helper? _helper;

    public override void Awake()
    {
        Check("fields are restored before Awake", Speed == 3f && Label == "from scene");
        // tools/test_csharp_export.py checks a built game runs on the .NET it ships with.
        Log.Info("INGAME RUNTIME " + System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory());
    }

    public override void Start() => _started = true;

    public override void FixedUpdate(float deltaTime) => _fixedTicks++;

    public override void Update(TickInput input, float deltaTime)
    {
        _tick++;
        if (_tick == 5)
            SceneAndFields();
        else if (_tick == 6)
            Hierarchy();
        else if (_tick == 7)
            Components();
        else if (_tick == 40)
            Physics();
        else if (_tick == 41)
            EcsData();
        else if (_tick == 42)
            LocalState();
        else if (_tick == 43)
            PrefabsAndRpcs();
        else if (_tick == 145)
            _staysBeforeRest = Probe("Ball").CollisionStays;
        else if (_tick == 150)
            ContactsWhileResting();
        else if (_tick == 165)
            ContactsAfterLeaving();
        else if (_tick == 200)
            ControllerHits();
        else if (_tick == 260)
            ContactsAfterLanding();
        else if (_tick == 300)
        {
            GroundAsTrigger();
            Finish();
            Application.Quit();
        }
    }

    private int _rpcValue;
    private string _rpcText = "";
    private int _rpcSender = -1;

    [Rpc(RpcTarget.Everyone)]
    private void Shout(int value, string text, Vector3 where)
    {
        _rpcValue = value + (int)where.X;
        _rpcText = text;
        _rpcSender = RpcSender;
    }

    private void PrefabsAndRpcs()
    {
        GameObject? spawned = Scene.InstantiatePrefab("Prefabs/Spawned.tprefab");
        SpawnedProbe? probe = spawned?.GetComponent<SpawnedProbe>();
        Check("a prefab made during play has its saved fields in Awake", probe?.PowerInAwake == 9 && probe.TitleInAwake == "from prefab");

        Rpc(nameof(Shout), 40, "here", new Vector3(2, 0, 0));
        Check("an RPC without a session runs at once", _rpcValue == 42 && _rpcText == "here" && _rpcSender == 0);
        bool notRpc = false, badCount = false, badType = false;
        try { Rpc(nameof(PrefabsAndRpcs)); } catch (ArgumentException) { notRpc = true; }
        try { Rpc(nameof(Shout), 1); } catch (ArgumentException) { badCount = true; }
        try { Rpc(nameof(Shout), "1", "x", Vector3.Zero); } catch (ArgumentException) { badType = true; }
        Thrower? thrower = Scene.Find("Thrower")?.GetComponent<Thrower>();
        Check("a script that throws in Update keeps being updated", thrower is { Updates: > 30 });
        RenamedProbe? renamed = Scene.Find("Renamed")?.GetComponent<RenamedProbe>();
        Check("a scene naming a script's [FormerlyNamed] name gets the renamed class, fields and all",
            renamed is { Awoke: true, Power: 4 });
        Check("Rpc refuses a method without [Rpc]", notRpc);
        Check("Rpc refuses the wrong number or kind of arguments", badCount && badType);
    }

    private int _staysBeforeRest;

    private ContactProbe Probe(string name) =>
        Scene.Find(name)!.Value.GetComponent<ContactProbe>()!;

    // The ball fell from y=3 through the trigger zone onto the ground, and has been asleep on it for a while.
    private void ContactsWhileResting()
    {
        ContactProbe ball = Probe("Ball");
        ContactProbe zone = Probe("Zone");
        Check("OnCollisionEnter once with the ground", ball.CollisionEnters == 1 && ball.LastCollision.GameObject.Name == "Ground");
        Check("collision normal points out of the ground", ball.LastCollision.Normal.Y > 0.9f);
        Check("collision point and closing speed", MathF.Abs(ball.LastCollision.Point.Y) < 0.1f && ball.LastCollision.RelativeSpeed > 3f);
        Check("the ball is asleep on the ground", Scene.Find("Ball")!.Value.GetRigidbody()?.IsSleeping == true);
        Check("no OnCollisionExit while resting (asleep)", ball.CollisionExits == 0);
        Check("OnTriggerEnter on the object entering", ball.TriggerEnters == 1 && ball.LastTrigger.Name == "Zone");
        Check("OnTriggerEnter on the trigger", zone.TriggerEnters == 1 && zone.LastTrigger.Name == "Ball");
        Check("a trigger is not a collision", zone.CollisionEnters == 0 && ball.CollisionEnters == 1);
        Check("a trigger ignores the static ground", zone.TriggerEnters == 1);
        Check("OnCollisionStay while settling, with the ground and a normal",
            ball.CollisionStays > 0 && ball.LastStay.GameObject.Name == "Ground" && ball.LastStay.Normal.Y > 0.9f);
        Check("no OnCollisionStay while asleep", ball.CollisionStays == _staysBeforeRest);
        Check("OnTriggerStay on both while falling through", ball.TriggerStays > 3 && zone.TriggerStays > 3);
        Scene.Find("Ball")!.Value.Transform.Position = new Vector3(15, 6, 15);
    }

    private void ContactsAfterLeaving()
    {
        ContactProbe ball = Probe("Ball");
        ContactProbe zone = Probe("Zone");
        Check("OnCollisionExit after moving away", ball.CollisionExits == 1 && ball.LastExit.GameObject.Name == "Ground");
        Check("OnTriggerExit on both", ball.TriggerExits == 1 && zone.TriggerExits == 1);
        Check("Stay only between Enter and Exit", !ball.StayOutsideEnterExit && !zone.StayOutsideEnterExit);
    }

    private void ControllerHits()
    {
        Walker walker = Scene.Find("Walker")!.Value.GetComponent<Walker>()!;
        Check("OnControllerHit for the ground walked on", walker.GroundHits > 10);
        Check("OnControllerHit for a wall walked into", walker.WallHits > 0);
        Check("its normal points back at the character and the point is on the wall",
            walker.LastWall.Normal.Z < -0.9f && MathF.Abs(walker.LastWall.Point.Z - 2.8f) < 0.1f && walker.LastWall.MoveSpeed > 2.9f);
        Check("the wall stopped the character", Scene.Find("Walker")!.Value.Transform.Position.Z < 2.4f);
    }

    private void ContactsAfterLanding()
    {
        Check("OnCollisionEnter again after landing elsewhere", Probe("Ball").CollisionEnters == 2);
        GameObject ground = Scene.Find("Ground")!.Value;
        ColliderHandle collider = ground.GetCollider()!.Value;
        Check("a collider is solid by default", !collider.IsTrigger);
        collider.IsTrigger = true;
        // Taking the ground away does not wake what sleeps on it.
        Rigidbody body = Scene.Find("Ball")!.Value.GetRigidbody()!.Value;
        body.Velocity = new Vector3(0, -0.1f, 0);
    }

    // Since tick 260 the ground has been a trigger.
    private void GroundAsTrigger()
    {
        GameObject ground = Scene.Find("Ground")!.Value;
        ContactProbe ball = Probe("Ball");
        Check("IsTrigger set from C# reads back", ground.GetCollider()!.Value.IsTrigger);
        Check("a solid made a trigger lets things through", Scene.Find("Ball")!.Value.Transform.Position.Y < -0.5f);
        Check("and reports them as triggers", ball.TriggerEnters == 2 && ball.LastTrigger.Name == "Ground");
    }

    private void SceneAndFields()
    {
        Check("Start ran before Update", _started);
        Check("base-class private [ShowInInspector] field restored", BaseSecret == 7f);
        Check("bool override restored", Flag == false);
        Check("FixedUpdate runs", _fixedTicks > 0);
        Check("Transform.Position reads the scene", Transform.Position == new Vector3(1, 2, 3));
        Transform.Position = new Vector3(float.NaN, 0, 0);
        Check("non-finite positions are ignored", Transform.Position == new Vector3(1, 2, 3));
        Check("offline scene acts as server", Scene.IsServer && !Scene.IsClient && !Scene.IsNetworked);
        Check("offline objects are mine", IsMine && GameObject.OwnerClientId == 0 && !GameObject.IsNetworked);
        Check("Time.Tick advances", Time.Tick > 0);
    }

    private void Hierarchy()
    {
        Check("GameObject.Name", GameObject.Name == "Runner");
        GameObject.SetName("Renamed");
        Check("renaming is visible to Scene.Find",
            Scene.Find("Renamed") == GameObject && Scene.Find("Runner") is null);
        GameObject.SetName("Runner");

        Check("ChildCount and GetChild", GameObject.ChildCount == 1 &&
            GameObject.GetChild(0)?.Name == "Child" && GameObject.GetChild(1) is null);
        GameObject child = GameObject.FindChild("Child")!.Value;
        Check("child Parent", child.Parent == GameObject && GameObject.Parent is null);
        Check("child world position follows its parent",
            Vector3.Distance(child.Transform.Position, new Vector3(1, 3, 3)) < 0.001f);

        Check("an object cannot be parented under its own child", !GameObject.SetParent(child));
        Check("unparenting keeps the world pose", child.SetParent(null) &&
            child.Parent is null && GameObject.ChildCount == 0 &&
            Vector3.Distance(child.Transform.Position, new Vector3(1, 3, 3)) < 0.001f);
        Check("re-parenting", child.SetParent(GameObject) && child.Parent == GameObject);

        Check("tags from the scene file", GameObject.HasTag("checks") &&
            Scene.FindWithTag("checks") == GameObject);
        Check("AddTag and FindAllWithTag", child.AddTag("checks") &&
            Scene.FindAllWithTag("checks").Length == 2);
        Check("RemoveTag", child.RemoveTag("checks") && !child.HasTag("checks") &&
            Scene.FindAllWithTag("checks").Length == 1);

        GameObject.SetLayer(3);
        Check("Layer", GameObject.Layer == 3);
        GameObject.SetLayer(0);

        GameObject made = Scene.CreateGameObject("Made");
        Check("CreateGameObject", made.IsValid && made.Name == "Made");
        made.SetActive(false);
        Check("SetActive", !made.ActiveSelf && !made.ActiveInHierarchy);
        made.Destroy();
    }

    private void Components()
    {
        Check("destroyed objects stop resolving", Scene.Find("Made") is null);
        _helper = AddComponent<Helper>();
        Check("AddComponent attaches and runs Awake", _helper.Awoke &&
            GetComponent<Helper>() == _helper);
        _helper.Enabled = false;
        Check("disabling a component calls OnDisable", !_helper.Enabled && _helper.Disables == 1);
        _helper.Enabled = true;
        Check("GetComponent<Transform>", TryGetComponent<Transform>(out _));
        Check("missing native handle", !TryGetComponent<Rigidbody>(out _));
    }

    private void Physics()
    {
        Check("added component received Update", _helper!.Updates > 0);
        GameObject crate = Scene.Find("Crate")!.Value;
        Rigidbody? body = crate.GetRigidbody();
        Check("Rigidbody handle", body is { IsValid: true, HasBody: true });
        Check("the crate fell onto the ground", crate.Transform.Position.Y < 4.9f);
        Check("NaN impulses are rejected", body!.Value.AddImpulse(new Vector3(float.NaN, 0, 0)) == false);
        Check("box collider handle", crate.GetCollider()?.Kind == ColliderKind.Box &&
            crate.GetCollider()?.BoxSize == new Vector3(1, 1, 1));

        PhysicsHit? hit = Scene.RaycastHit(new Vector3(-10, 10, -10), -Vector3.UnitY, 50f);
        Check("raycast hits the ground", hit is { Distance: > 9.5f and < 10.5f } &&
            hit.Value.HitObject?.Name == "Ground");
        Check("raycast misses the sky", Scene.RaycastHit(new Vector3(0, 10, 0), Vector3.UnitY, 50f) is null);

        GameObject player = Scene.Find("Player")!.Value;
        CharacterController? controller = player.GetCharacterController();
        Check("character controller is simulated and grounded",
            controller is { IsValid: true, HasCharacter: true, IsGrounded: true });
        Check("template character locked the cursor", Cursor.Locked);
        Check("character height", controller?.Height == 2f);
    }

    private void EcsData()
    {
        EcsEntity entity = Scene.CreateLocalEcsEntity();
        Check("local ECS entity", entity.IsAlive);
        Check("typed local data round trip",
            entity.SetLocalData(new Motion { Velocity = new Vector3(1, 2, 3), Drag = 0.5f }) &&
            entity.TryGetLocalData(out Motion read) &&
            read.Velocity == new Vector3(1, 2, 3) && read.Drag == 0.5f);
        Span<ulong> ids = stackalloc ulong[4];
        Span<Motion> values = stackalloc Motion[4];
        Check("local data query page", Scene.CopyLocalDataPage(0, ids, values) == 1 &&
            ids[0] == entity.Id && values[0].Drag == 0.5f);
        Check("DestroyLocal", entity.DestroyLocal() && !entity.IsAlive);
    }

    private void LocalState()
    {
        Check("no keys are held in a headless run", !Input.GetKey(KeyCode.W) &&
            Input.GetAxis("Horizontal") == 0f && !Input.GetMouseButton(MouseButton.Left));
        Check("Mathf and RotationMath bindings", Mathf.Clamp01(2f) == 1f &&
            Vector3.Distance(RotationMath.ToEulerDegrees(
                RotationMath.EulerDegrees(new Vector3(0, 90, 0))), new Vector3(0, 90, 0)) < 0.01f);
    }
}

/// Counts collision and trigger callbacks for ApiChecks.
public class ContactProbe : Script
{
    public int CollisionEnters, CollisionExits, TriggerEnters, TriggerExits;
    public int CollisionStays, TriggerStays;
    public bool StayOutsideEnterExit;
    public Collision LastCollision, LastExit, LastStay;
    public GameObject LastTrigger;

    public override void OnCollisionStay(Collision collision)
    {
        CollisionStays++;
        LastStay = collision;
        if (CollisionEnters == CollisionExits)
            StayOutsideEnterExit = true;
    }

    public override void OnTriggerStay(GameObject other)
    {
        TriggerStays++;
        if (TriggerEnters == TriggerExits)
            StayOutsideEnterExit = true;
    }

    public override void OnCollisionEnter(Collision collision)
    {
        CollisionEnters++;
        LastCollision = collision;
    }

    public override void OnCollisionExit(Collision collision)
    {
        CollisionExits++;
        LastExit = collision;
    }

    public override void OnTriggerEnter(GameObject other)
    {
        TriggerEnters++;
        LastTrigger = other;
    }

    public override void OnTriggerExit(GameObject other) => TriggerExits++;
}

/// Walks into the Wall (towards +Z) and records what its CharacterController hits.
public class Walker : Script
{
    public int GroundHits, WallHits, Steps;
    public ControllerHit LastWall;

    public override void FixedUpdate(float deltaTime)
    {
        if (++Steps <= 150)
            GetCharacterController()!.Value.SimpleMove(new Vector3(0, 0, 3), deltaTime);
    }

    public override void OnControllerHit(ControllerHit hit)
    {
        if (hit.GameObject.Name == "Ground" && hit.Normal.Y > 0.9f)
            GroundHits++;
        else if (hit.GameObject.Name == "Wall")
        {
            WallHits++;
            LastWall = hit;
        }
    }
}

/// Throws in every Update. The engine logs it once (tools/test_csharp_ingame.py checks the file and line)
/// and keeps calling it.
public class Thrower : Script
{
    public int Updates;

    public override void Update(TickInput input, float deltaTime)
    {
        Updates++;
        throw new InvalidOperationException("thrown on purpose by Thrower");
    }
}

/// The scene still names this class InGame.OldProbeName.
[FormerlyNamed("InGame.OldProbeName")]
public class RenamedProbe : Script
{
    public int Power = 1;
    public bool Awoke;

    public override void Awake() => Awoke = true;
}

public class SpawnedProbe : Script
{
    public int Power = 1;
    public string Title = "default";
    public int PowerInAwake;
    public string TitleInAwake = "";

    public override void Awake()
    {
        PowerInAwake = Power;
        TitleInAwake = Title;
    }
}

public class Helper : Script
{
    public bool Awoke;
    public int Disables;
    public int Updates;

    public override void Awake() => Awoke = true;
    public override void OnDisable() => Disables++;
    public override void Update(TickInput input, float deltaTime) => Updates++;
}

[Component]
public struct Motion
{
    public Vector3 Velocity;
    public float Drag;
}
