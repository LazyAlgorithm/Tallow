using System.Linq;
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
/// <summary>A nested Inspector value: its fields show under the field's name.</summary>
[Serializable]
public struct Stats
{
    /// Hit points.
    public int Health;
    public float Speed;
    public Limits? Limits;
    [NonSerialized] public int Ignored;
}

[Serializable]
public class Limits
{
    public float Max = 5;
    public string Tag = "";
}

/// <summary>A list item with fields of its own: the Inspector draws each item's fields.</summary>
[Serializable]
public class Wave
{
    public int Count = 3;
    public float Delay;
    public CheckKind Kind;
    public string Name = "";
}

[Serializable]
public struct Waypoint
{
    public System.Numerics.Vector3 At;
    public bool Wait;
}

public class ApiChecks : CheckBase
{
    private readonly List<string> mWorldStateChanges = new();

    public override void OnWorldStateChanged(int from, int to) => mWorldStateChanges.Add($"{from}>{to}");

    /// <summary>
    /// How fast it moves, in metres a second (see <see cref="Stats"/>) &amp; more.
    /// </summary>
    public float Speed = 1f;
    public string Label = "default";
    public List<int> Numbers = new();
    public System.Numerics.Vector3[] Points = [];
    public Color Tint = new(1, 1, 1);
    public double Precise;
    public string[] Words = [];
    public List<CheckKind> Kinds = new();
    public Stats Stats = new() { Health = 10 };
    public Stats NoOverrides;
    [Asset(AssetKind.Prefab)] public string EnemyPrefab = "";
    [Asset(AssetKind.AudioClip)] public List<string> Sounds = new();
    public List<Wave> Waves = new();
    public Waypoint[] Waypoints = [];

    private int _tick;
    private int _fixedTicks;
    private bool _started;
    private Helper? _helper;
    // Read by the native side (CSharpRuntime.RunFieldTest), which makes the editor's calls: an Inspector edit, and
    // the Scene view's gizmo pass for a selected and an unselected object.
    private int _validations;
    private float _speedWhenValidated;
    private int _gizmosSelected;
    private int _gizmosUnselected;

    public override void OnValidate()
    {
        _validations++;
        _speedWhenValidated = Speed;
    }

    public override void OnDrawGizmos(bool selected)
    {
        if (selected)
            _gizmosSelected++;
        else
            _gizmosUnselected++;
        Gizmos.Line(Transform.Position, Transform.Position + Vector3.UnitY, Color.Red);
        Gizmos.Sphere(Transform.Position, 0.5f, Color.White, onTop: selected);
        Gizmos.Box(Transform.Position, Vector3.One, Color.Black);
    }

    public override void Awake()
    {
        Check("fields are restored before Awake", Speed == 3f && Label == "from scene");
        // A game script cannot put itself between other scripts and the engine.
        Check("Engine.Bind is not open to game code",
            typeof(Engine).GetMethod("Bind", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static) == null);
        Check($"list, array, Color and double fields come from the scene ({string.Join(",", Numbers)}; {Points.Length}; {Tint}; {Precise}; {string.Join("|", Words)}; {string.Join(",", Kinds)})",
            Numbers.SequenceEqual([1, 2, 3]) && Points.Length == 2 && Points[1] == new System.Numerics.Vector3(4, 5, 6) &&
            Tint == new Color(0.5f, 0.25f, 1, 1) && Precise == 0.1 && Words.Length == 2 && Words[0] == "a;b" &&
            Words[1] == "c\\d" && Kinds.Count == 2 && Kinds[0] == CheckKind.Second);
        Check($"nested [Serializable] struct and class fields come from the scene ({Stats.Health}, {Stats.Speed}, "
            + $"{Stats.Limits?.Max}, {Stats.Limits?.Tag}, {NoOverrides.Limits?.Max})",
            Stats.Health == 42 && Stats.Speed == 1.5f && Stats.Limits is { Max: 9, Tag: "edge" } &&
            NoOverrides.Health == 0 && NoOverrides.Limits is null);
        Check($"lists of [Serializable] classes and structs come from the scene ({Waves.Count}; {Waypoints.Length})",
            Waves.Count == 2 && Waves[0] is { Count: 5, Kind: CheckKind.Second, Name: "x;y", Delay: 0 } &&
            Waves[1] is { Count: 3, Delay: 0.5f, Kind: CheckKind.First, Name: "" } && Waypoints.Length == 1 &&
            Waypoints[0].At == new System.Numerics.Vector3(1, 2, 3) && Waypoints[0].Wait);
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
        else if (_tick == 8)
            EveryNativeHandle(); // Its objects go at the end of the frame, so it has a frame of its own.
        else if (_tick == 9)
            ComponentActions();
        else if (_tick == 10)
            SystemsBegin();
        else if (_tick == 11)
            EventsBegin();
        else if (_tick == 20)
            SystemsCheck();
        else if (_tick == 40)
            Physics();
        else if (_tick == 41)
            EcsData();
        else if (_tick == 42)
            LocalState();
        else if (_tick == 43)
            PrefabsAndRpcs();
        else if (_tick == 44)
            Scene.Find("AsyncDoomed")?.Destroy();
        else if (_tick == 45)
            UpdateOrderSetup();
        else if (_tick == 50)
            UpdateOrderChecks();
        else if (_tick == 60)
            _victim = Scene.CreateGameObject("Victim").AddComponent<UpdateCounter>();
        else if (_tick == 63)
        {
            // Destroyed before its own Update this frame (it was made after this script): it gets no more.
            _victimUpdatesAtDestroy = _victim!.Updates;
            _victim.GameObject.Destroy();
        }
        else if (_tick == 65)
            Check("an object destroyed earlier in the frame gets no more Updates",
                _victim!.Updates == _victimUpdatesAtDestroy && _victimUpdatesAtDestroy > 0);
        else if (_tick == 66)
            ServiceChecks();
        else if (_tick == 70)
            Check($"Workshop.Browse without Steam finishes with no items ({_browse?.Status})",
                _browse is { IsCompletedSuccessfully: true } && _browse.Result.Length == 0);
        else if (_tick == 100)
        {
            // LetGo(0.05f) fades over 0.05 s of game time; this is well after.
            Limb[] limbs = IK.Limbs(_ikRig);
            Check($"Limb.LetGo fades one Limb IK's weight to 0 and leaves the other ({limbs.Length}: {string.Join(", ", limbs.Select(l => l.Weight))})",
                limbs.Length == 2 && limbs[0].Weight < 0.01f && limbs[1].Weight > 0.99f);
            _ikRig.Destroy();
        }
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
        else if (_tick == 280)
        {
            ComponentAccessSetup();
            ComponentActionsSetup();
        }
        else if (_tick == 300)
        {
            GroundAsTrigger();
            HooksAndSaves();
            AsyncChecks();
            GraphChecks();
            AnimatorChecks();
            UIChecks();
            NativeComponentChecks();
            EventChecks();
            SpawnLayerJointChecks();
            ReferenceFieldChecks();
            PackageChecks();
            ComponentAccessChecks();
            ComponentActionsChecks();
            Finish();
            Application.Quit();
        }
    }

    private UpdateCounter? _victim;
    private int _victimUpdatesAtDestroy;

    private GameObject _accessRoot, _accessChild, _accessGrandchild;
    private Helper? _removedHelper;

    /// GetComponents / InParent / InChildren, RemoveComponent (checked frames later, at 300) and Transform directions.
    private void ComponentAccessSetup()
    {
        _accessRoot = Scene.CreateGameObject("Access root");
        _accessChild = Scene.CreateGameObject("Access child");
        _accessGrandchild = Scene.CreateGameObject("Access grandchild");
        _accessChild.SetParent(_accessRoot);
        _accessGrandchild.SetParent(_accessChild);
        Helper first = _accessRoot.AddComponent<Helper>();
        Helper second = _accessRoot.AddComponent<Helper>();
        _accessGrandchild.AddComponent<Helper>();
        _accessRoot.AddComponent<Light>();
        _accessGrandchild.AddComponent<Light>();
        Check("GetComponents<T> finds both scripts of a type, in order",
            _accessRoot.GetComponents<Helper>() is [var a, var b] && ReferenceEquals(a, first) && ReferenceEquals(b, second));
        Check("GetComponents<T> of a built-in component finds the one", _accessRoot.GetComponents<Light>().Length == 1);
        Check("GetComponentInParent<T> finds the nearest one up the hierarchy",
            ReferenceEquals(_accessChild.GetComponentInParent<Helper>(), first)
            && _accessGrandchild.GetComponentInParent<Helper>() is { } own && own.GameObject == _accessGrandchild);
        Check("GetComponentsInChildren<T> finds this object's and every descendant's",
            _accessRoot.GetComponentsInChildren<Helper>().Length == 3 && _accessRoot.GetComponentsInChildren<Light>().Length == 2
            && _accessChild.GetComponentsInChildren<Helper>().Length == 1);
        // Removed at the end of the frame: still there now.
        _removedHelper = second;
        bool scriptQueued = _accessRoot.RemoveComponent(second);
        bool lightQueued = _accessGrandchild.RemoveComponent<Light>();
        Check("RemoveComponent of a script and a built-in component is accepted", scriptQueued && lightQueued);
        Check("RemoveComponent<T> with nothing to remove says so", !_accessChild.RemoveComponent<Light>());

        _accessChild.Transform.Rotation = Quaternion.CreateFromAxisAngle(Vector3.UnitY, MathF.PI / 2);
        Vector3 worldForward = _accessChild.Transform.TransformDirection(Vector3.UnitZ);
        Vector3 back = _accessChild.Transform.InverseTransformDirection(worldForward);
        Check($"TransformDirection rotates and InverseTransformDirection undoes it ({worldForward})",
            Vector3.Distance(worldForward, Vector3.UnitX) < 1e-4f && Vector3.Distance(back, Vector3.UnitZ) < 1e-4f);
        _accessRoot.Transform.Position = new Vector3(2, 0, 0);
        _accessRoot.Transform.Rotation = Quaternion.Identity;
        _accessRoot.Transform.RotateAround(Vector3.Zero, Vector3.UnitY, 90);
        Check($"RotateAround moves and turns the object about a point ({_accessRoot.Transform.Position})",
            Vector3.Distance(_accessRoot.Transform.Position, new Vector3(0, 0, -2)) < 1e-3f
            && Vector3.Distance(_accessRoot.Transform.Forward, Vector3.Transform(Vector3.UnitZ, Quaternion.CreateFromAxisAngle(Vector3.UnitY, MathF.PI / 2))) < 1e-3f);
    }

    private void ComponentAccessChecks()
    {
        Check("RemoveComponent took the script off by the next frame (its OnDestroy ran)",
            _accessRoot.GetComponents<Helper>().Length == 1 && _removedHelper is { DestroyRan: true });
        Check("RemoveComponent<Light> took the light off", !_accessGrandchild.GetComponent<Light>().IsValid
            && _accessRoot.GetComponent<Light>().IsValid);
        Check("removing a script that is gone is refused", _removedHelper is { } gone && !_accessRoot.RemoveComponent(gone));
    }

    private GameObject _pool, _floater, _swimmer;

    /// Water, voxel, line, skinned-renderer, compute and swimming actions (water floating checked at 300).
    private void ComponentActionsSetup()
    {
        _pool = Scene.CreateGameObject("Pool");
        _pool.Transform.Position = new Vector3(300, 0, 300);
        Water water = _pool.AddComponent<Water>();
        Vector3 over = new(300, -1, 300), away = new(900, -1, 900);
        float height = water.HeightAt(over);
        Check($"Water.HeightAt, DepthOf and Covers ({height}, {water.DepthOf(over)})",
            water.Covers(over) && !water.Covers(away) && MathF.Abs(water.DepthOf(over) - (height + 1)) < 1e-3f
            && water.DepthOf(away) == float.MinValue);
        _floater = Scene.CreateGameObject("Floater");
        _floater.Transform.Position = new Vector3(300, 0.2f, 300);
        _floater.AddComponent<SphereCollider>();
        _floater.AddComponent<Rigidbody>();

        GameObject block = Scene.CreateGameObject("Voxel block");
        block.Transform.Position = new Vector3(-300, 0, -300);
        VoxelObject voxels = block.AddComponent<VoxelObject>();
        voxels.Fill();
        bool carved = voxels.CarveLocal(Vector3.Zero, 0.6f);
        voxels.ResetShape();
        Check("VoxelObject.Fill, CarveLocal and ResetShape", carved);

        GameObject line = Scene.CreateGameObject("Line");
        LineRenderer lineRenderer = line.AddComponent<LineRenderer>();
        lineRenderer.SetPositions([Vector3.Zero, Vector3.One]);
        lineRenderer.ClearPositions();
        Check("LineRenderer.ClearPositions", lineRenderer.PositionCount == 0);

        GameObject body = Scene.CreateGameObject("Skinned");
        SkinnedMeshRenderer skinned = body.AddComponent<SkinnedMeshRenderer>();
        skinned.SetPartHidden("Head", true);
        skinned.SetPartColor("Body", new Color(1, 0, 0));
        Check("SkinnedMeshRenderer part calls work without a model (no parts, no bones)",
            skinned.PartCount == 0 && skinned.BoneAt(0) == null && skinned.GetPartMaterial("Body") == "");

        GameObject effect = Scene.CreateGameObject("Effect");
        ComputeEffect compute = effect.AddComponent<ComputeEffect>();
        bool set = true;
        try { compute.SetColor("tint", new Color(0, 1, 0)); } catch (InvalidOperationException) { set = false; }
        Check("ComputeEffect.SetColor reaches the effect", set);

        // Deep in the pool: Swim moves as a swimmer there (out of deep water it walks). Its character is made by the
        // next physics step, so it swims at 300.
        _swimmer = Scene.CreateGameObject("Swimmer");
        _swimmer.Transform.Position = new Vector3(303, -4, 303);
        _swimmer.AddComponent<CharacterController>();
    }

    private void ComponentActionsChecks()
    {
        Water water = _pool.GetComponent<Water>();
        Check("Water.IsFloating sees a Rigidbody in it", water.IsFloating(_floater.GetComponent<Rigidbody>())
            && !water.IsFloating(_pool));
        Check("offline: no session, nothing to leave, no clients",
            !Network.InSession(Scene) && !Network.IsConnected(Scene) && !Network.Leave(Scene) && Network.ClientIds(Scene).Length == 0
            && Network.PlayerObject(Scene, 0) == null);
        PlatformChecks();
        CharacterController character = _swimmer.GetComponent<CharacterController>();
        float before = _swimmer.Transform.Position.Y;
        for (int i = 0; i < 5; i++)
            character.Swim(new Vector3(0, 2, 0), 0.1f);
        Check($"CharacterController.Swim swims up through deep water ({before} -> {_swimmer.Transform.Position.Y})",
            _swimmer.Transform.Position.Y > before + 0.3f);
    }

    /// Engine services that are not components (headless: no pads, fingers or window).
    private void PlatformChecks()
    {
        Check("Gamepad: none connected headless, nothing held",
            !Gamepad.IsConnected() && !Gamepad.GetButton(GamepadButton.South) && Gamepad.GetAxis(GamepadAxis.LeftX) == 0 &&
            Gamepad.Name() == "" && Touch.Count == 0 && Touch.Fingers.Length == 0);
        Gamepad.Rumble(0.5f, 0.5f, 0.1f);
        DialogueVariables.Set("gold", 12);
        DialogueVariables.Add("gold", 3);
        DialogueVariables.Set("metGuard", true);
        Check($"DialogueVariables Set/Add/Get and Evaluate ({DialogueVariables.Get("gold")})",
            DialogueVariables.Get("gold") == 15 && DialogueVariables.Evaluate("gold >= 10 && metGuard") &&
            !DialogueVariables.Evaluate("gold > 100"));
        DialogueVariables.Clear();
        int line = Subtitles.Show("Guard", "Halt!", 5);
        int caption = Subtitles.Caption("[door creaks]");
        bool shown = Subtitles.IsShowing(line) && Subtitles.IsShowing(caption);
        Subtitles.Hide(line);
        Check("Subtitles Show, Caption, IsShowing and Hide", shown && !Subtitles.IsShowing(line) && Subtitles.IsShowing(caption));
        Subtitles.Clear();
        int before = Achievements.GetStat("csharpProbe", true);
        int after = Achievements.AddStat("csharpProbe", 2, true);
        Achievements.SetStat("csharpProbe", before, true);
        Check($"Achievements stats add and set locally ({before} -> {after})", after == before + 2 &&
            Achievements.GetStat("csharpProbe", true) == before);
        Achievements.Clear("csharpProbeAchievement");
        bool unlocked = Achievements.Unlock("csharpProbeAchievement") && Achievements.IsUnlocked("csharpProbeAchievement")
            && !Achievements.Unlock("csharpProbeAchievement");
        Achievements.Clear("csharpProbeAchievement");
        Check("Achievements Unlock once, IsUnlocked, Clear", unlocked && !Achievements.IsUnlocked("csharpProbeAchievement"));
        Decals.Spawn(Scene, new Vector3(0, 0.01f, 0), Vector3.UnitY, "Textures/decal.png", 1, 5);
        Decals.Clear(Scene);
        Vector3 wind = Wind.At(Scene, Vector3.Zero);
        float gusts = Wind.Gusts(Scene);
        Check($"Wind.At and Gusts read the scene's wind ({wind}, {gusts})", float.IsFinite(wind.X) && gusts >= 0 && gusts <= 1);
        QualityLevel level = Quality.Level;
        Quality.Set(QualityLevel.Low, save: false);
        bool low = Quality.Level == QualityLevel.Low;
        Quality.Set(level == QualityLevel.Custom ? QualityLevel.High : level, save: false);
        Check($"Quality.Set applies a preset (was {level}, recommended {Quality.Recommended})", low);
        Quality.Set(QualityLevel.High, save: false);
        bool vsync = Quality.VSync;
        Quality.VSync = !vsync;
        Quality.ShadowMapSize = 1024;
        Quality.RenderScale = 0.8f;
        bool changed = Quality.VSync == !vsync && Quality.ShadowMapSize == 1024 && MathF.Abs(Quality.RenderScale - 0.8f) < 1e-5f
            && Quality.Level == QualityLevel.Custom;
        Quality.ShadowMapSize = 99999;
        bool clamped = Quality.ShadowMapSize == 8192;
        Quality.Set(level == QualityLevel.Custom ? QualityLevel.High : level, save: false);
        Check("Quality's single settings (VSync, ShadowMapSize, RenderScale) apply, clamp and make the level Custom",
            changed && clamped && Quality.VSync == vsync);
        string? sceneText = Assets.ReadText("Scenes/Main.tscene");
        Check($"Assets.Exists/ReadText read the game's own files ({sceneText?.Length ?? -1} chars); missing ones are null",
            Assets.Exists("Scenes/Main.tscene") && sceneText is { Length: > 0 } && !Assets.Exists("No/Such.file") &&
            Assets.ReadBytes("No/Such.file") == null);
        SaveHandle saved = SaveSystem.Save("csharpProbe");
        bool savedOk = saved.Done && saved.Succeeded && saved.Error == "" && SaveSystem.Exists("csharpProbe") &&
            SaveSystem.Slots.Contains("csharpProbe");
        SaveHandle loaded = SaveSystem.Load("csharpProbe");
        bool loadedOk = loaded.Done && loaded.Succeeded && loaded.Found;
        SaveSystem.Delete("csharpProbe");
        SaveHandle missing = SaveSystem.Load("csharpProbe");
        Check($"SaveSystem Save, Exists, Slots, Load, Delete ({saved.Error}{loaded.Error})",
            savedOk && loadedOk && !SaveSystem.Exists("csharpProbe") && missing.Done && !missing.Found);
        Check("VoiceChat offline: not sending; Talk is settable; nobody is speaking",
            !VoiceChat.IsTransmitting && !VoiceChat.IsSpeaking(1) && !VoiceChat.IsMuted(1) && VoiceChat.GetPlayerVolume(1) == 1 &&
            ((VoiceChat.Talk = true) && VoiceChat.Talk) && !(VoiceChat.Talk = false));
        bool full = Screen.Fullscreen;
        Screen.Fullscreen = full;
        Check("Screen.Fullscreen reads and keeps its value", Screen.Fullscreen == full);
    }

    private void PackageChecks()
    {
        string result = "";
        try
        {
            result = InGame.Json.JsonText.RoundTrip();
        }
        catch (Exception exception)
        {
            result = exception.GetType().Name + ": " + exception.Message;
        }
        Check("a NuGet package from an assembly definition loads and runs (" + result + ")",
            result == "{\"Player\":\"Ada\",\"Points\":42}|Ada|42");
    }

    private void AsyncChecks()
    {
        AsyncProbe? probe = Scene.Find("Async")?.GetComponent<AsyncProbe>();
        Check("await NextFrame, Wait and Task.Delay all finish", probe is { Step: 4 });
        Check("await NextFrame carries on in the next frame", probe?.FramesForNextFrame == 1);
        // 0.5 s at the fixed 60 Hz step of this test: 30 frames.
        Check("await Wait(0.5) waits half a second of game time", probe?.FramesForWait is >= 29 and <= 31);
        Check("code after every await runs on the game thread", probe is { StayedOnGameThread: true });
        Check("destroying a script cancels what it awaits", AsyncDoomed.Cancelled && !AsyncDoomed.RanOn);
    }

    private void ReferenceFieldChecks()
    {
        RefProbe? probe = Scene.Find("RefProbe")?.GetComponent<RefProbe>();
        Check("a GameObject reference field is set from the scene", probe?.Target == Scene.Find("AnimRoot"));
        Check("a built-in component reference field (Light)", probe is { Lamp.IsValid: true } && probe.Lamp.Intensity == 2);
        Check("a Transform reference field", probe?.Spot?.GameObject == Scene.Find("Animated"));
        Check("a reference to a missing object stays null", probe is { Gone: null });
        Check("a script reference to a later object is set, and that script awake, by Awake",
            probe is { LateSetInMyAwake: true, LateWasAwakeInMyAwake: true } && probe.Late?.GameObject == Scene.Find("LateHelper"));
        GameObject? first = Scene.InstantiatePrefab("Prefabs/RefPair.tprefab");
        GameObject? second = Scene.InstantiatePrefab("Prefabs/RefPair.tprefab");
        PairProbe? a = first?.GetComponent<PairProbe>(), b = second?.GetComponent<PairProbe>();
        Check("each prefab copy's reference points at its own child",
            a != null && b != null && a.Partner == first!.Value.GetChild(0) && b.Partner == second!.Value.GetChild(0) && a.Partner != b.Partner);
        first?.Destroy();
        second?.Destroy();
        foreach ((Type type, string native) in NativeTypes())
            Check($"{type.Name} is marked [NativeComponent(\"{native}\")]",
                type.GetCustomAttributes(typeof(NativeComponentAttribute), false) is [NativeComponentAttribute { TypeName: var named }] && named == native);
    }

    // Tallow.API's table of built-in handles (internal), read by reflection for the check above.
    private static IEnumerable<(Type, string)> NativeTypes() =>
        (IEnumerable<(Type, string)>)typeof(NativeComponentAttribute).Assembly.GetType("Tallow.NativeComponentTypes")!
            .GetProperty("All")!.GetValue(null)!;

    // Scene text keeps 7 significant digits of a float (SceneSerializer.WriteValue), so a value can move in its last
    // place the first time it goes through the engine, and then stays.
    private static bool SameToSevenDigits(object? a, object? b)
    {
        static float[]? Parts(object? v) => v switch
        {
            float f => [f],
            Vector2 x => [x.X, x.Y],
            Vector3 x => [x.X, x.Y, x.Z],
            Vector4 x => [x.X, x.Y, x.Z, x.W],
            Color c => [c.R, c.G, c.B, c.A],
            _ => null,
        };
        float[]? x = Parts(a), y = Parts(b);
        if (x is null || y is null || x.Length != y.Length)
            return false;
        for (int i = 0; i < x.Length; i++)
            if (MathF.Abs(x[i] - y[i]) > 1e-6f * MathF.Max(1f, MathF.Abs(x[i])))
                return false;
        return true;
    }

    private static Dictionary<Type, string[]> GeneratedFields() =>
        (Dictionary<Type, string[]>)typeof(NativeComponentAttribute).Assembly.GetType("Tallow.NativeComponentTypes")!
            .GetField("GeneratedFields", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!
            .GetValue(null)!;

    private static readonly HashSet<string> HandWritten = ["Light", "MeshRenderer", "SphereCollider", "BoxCollider",
        "NavigationAgent", "NavigationSurface", "Rigidbody", "CharacterController", "UIDocument", "Animator",
        "VoxelObject", "VoxelTerrain", "CharacterMotor", "AudioSource", "SoftBody"];

    /// Every built-in component handle (the generated ones too) can be added, and each of its fields reads back what
    /// is written to it.
    private void EveryNativeHandle()
    {
        var problems = new List<string>();
        int handles = 0, fields = 0;
        foreach ((Type type, string native) in NativeTypes())
        {
            GameObject holder = Scene.CreateGameObject("Handle " + type.Name);
            object handle = typeof(GameObject).GetMethod(nameof(GameObject.AddComponent))!.MakeGenericMethod(type)
                .Invoke(holder, null)!;
            handles++;
            // A NavigationSurface is valid once it has baked data, which a new one does not.
            if (type.Name != "NavigationSurface" && type.GetProperty("IsValid")?.GetValue(handle) is not true)
            {
                problems.Add(type.Name + " was not added");
                holder.Destroy();
                continue;
            }
            // Hand-written handles also carry live state (a Rigidbody's velocity...); generated ones are all fields,
            // as are the fields generated into hand-written handles (NativeComponentTypes.GeneratedFields).
            bool generated = !HandWritten.Contains(type.Name);
            GeneratedFields().TryGetValue(type, out string[]? added);
            foreach (var property in type.GetProperties())
            {
                if (!(generated || added?.Contains(property.Name) == true) || !property.CanWrite ||
                    property.Name is "IsValid" or "GameObject")
                    continue;
                object? value = property.GetValue(handle);
                property.SetValue(handle, value);
                object? again = property.GetValue(handle);
                fields++;
                if (!Equals(value, again) && !SameToSevenDigits(value, again))
                    problems.Add($"{type.Name}.{property.Name}: {value} became {again}");
            }
            holder.Destroy();
        }
        Check($"every built-in component handle ({handles}) adds, and its {fields} fields read back what is written",
            problems.Count == 0 && handles >= 40);
        foreach (string problem in problems.Take(10))
            Log.Info("INGAME NOTE " + problem);
        GameObject eye = Scene.CreateGameObject("CameraProbe");
        Camera camera = eye.AddComponent<Camera>();
        camera.FieldOfView = 72.5f;
        camera.Orthographic = true;
        Check("a generated handle (Camera) writes the engine's component", camera.FieldOfView == 72.5f &&
            new NativeComponent(eye, "Tallow.Camera").GetFloat("fieldOfView") == 72.5f && camera.Orthographic);
        eye.Destroy();
    }

    private EcsEntity _spinBare, _paired, _chargeOnly, _triple;
    private Task<WorkshopItem[]>? _browse;
    private GameObject _ikRig;

    /// Steam, the Workshop and the anti-cheat in an offline run with no Steam App ID.
    private void ServiceChecks()
    {
        Check($"Steam.Start is false without an App ID ({Steam.Error})", !Steam.Start() && !Steam.IsReady && Steam.UserId == 0 &&
            Steam.FriendCount == 0 && Steam.Friends.Length == 0 && Steam.FriendPresence(1, "connect") == "");
        Check("Steam.TakeJoinRequest is false with none waiting", !Steam.TakeJoinRequest(out string connect) && connect == "");
        Check("the Workshop is unavailable without Steam", !Workshop.Available && !Workshop.IsInstalled(1) &&
            Workshop.Folder(1) == null && Workshop.Subscribed.Length == 0 && Workshop.MountInstalled() == 0);
        _browse = Workshop.Browse(WorkshopSort.Popular);

        CheatAction was = AntiCheat.GetAction(CheatKind.Debugger);
        AntiCheat.SetAction(CheatKind.Debugger, CheatAction.Kick);
        Check("AntiCheat.SetAction and GetAction", AntiCheat.GetAction(CheatKind.Debugger) == CheatAction.Kick &&
            AntiCheat.GetAction(CheatKind.InvalidInput) == CheatAction.Kick);
        AntiCheat.SetAction(CheatKind.Debugger, was);
        AntiCheat.Ban("steam:123");
        bool banned = AntiCheat.IsBanned("steam:123") && AntiCheat.BansToText().Contains("steam:123");
        AntiCheat.Unban("steam:123");
        Check("AntiCheat bans: Ban, IsBanned, BansToText, Unban", banned && !AntiCheat.IsBanned("steam:123"));
        Check("Network.Kick is false offline", !Network.Kick(Scene, 1));
        Check("AntiCheat.KickReason is empty when nobody removed us", AntiCheat.KickReason == "");

        var settings = (VoiceChat.Proximity, VoiceChat.MaxDistance, VoiceChat.Bitrate, VoiceChat.PushToTalkKey, VoiceChat.PushToTalkAction);
        VoiceChat.Proximity = true;
        VoiceChat.MaxDistance = 42;
        VoiceChat.Bitrate = 16000;
        VoiceChat.PushToTalkKey = KeyCode.G;
        VoiceChat.PushToTalkAction = "";
        Check("VoiceChat settings round-trip", VoiceChat.Proximity && VoiceChat.MaxDistance == 42 && VoiceChat.Bitrate == 16000 &&
            VoiceChat.PushToTalkKey == KeyCode.G && VoiceChat.PushToTalkAction == "");
        (VoiceChat.Proximity, VoiceChat.MaxDistance, VoiceChat.Bitrate, VoiceChat.PushToTalkKey, VoiceChat.PushToTalkAction) = settings;

        GameObject shifter = Scene.CreateGameObject("Shifter");
        uint before = shifter.WorldStates;
        shifter.WorldStates = 2;
        bool objectStates = shifter.WorldStates == 2;
        shifter.Destroy();
        bool queryInside;
        using (Scene.QueryInWorldStates(1))
            queryInside = Scene.QueryWorldStates == 1;
        Check($"world-state masks: GameObject.WorldStates ({before:X}) and Scene.QueryInWorldStates",
            before == uint.MaxValue && objectStates && queryInside && Scene.QueryWorldStates == uint.MaxValue);
        Check("Network settings read as off without a session", !Scene.IsReplaying && !Network.IsMigrating(Scene) &&
            Network.GetMaxRewindTicks(Scene) == 0 && !Network.HostMigration);

        Quaternion turn = IK.FromTo(Vector3.UnitZ, Vector3.UnitX);
        Check("IK.FromTo turns one direction onto another", Vector3.Distance(Vector3.Transform(Vector3.UnitZ, turn), Vector3.UnitX) < 1e-4f);
        _ikRig = Scene.CreateGameObject("IKRig");
        _ikRig.AddComponent<LimbIK>();
        IK.AddLimb(_ikRig);
        IK.Limbs(_ikRig)[0].LetGo(0.05f);
        Check("IK.Limb finds no limb by a tip it does not have", IK.Limb(_ikRig, "RightHand") == null);

        GuardedInt coins = 100;
        coins += 5;
        int shown = coins;
        GuardedFloat health = 100;
        health -= 12.5f;
        Check($"GuardedInt and GuardedFloat keep their values ({shown}, {health})", shown == 105 && coins.Intact &&
            health.Value == 87.5f && health.Intact && default(GuardedInt).Value == 0);
    }
    private GameObject _spinObject;
    private int _systemTick;

    /// An EcsSystem (SpinSystem) runs every fixed tick on bare entities with its data, not on GameObjects'.
    private void SystemsBegin()
    {
        _spinBare = Scene.CreateLocalEcsEntity();
        _spinBare.Set(new Spin { Speed = 2 });
        _spinObject = Scene.CreateGameObject("SpinObject");
        _spinObject.Entity.Set(new Spin { Speed = 2 });
        _paired = Scene.CreateLocalEcsEntity();
        _paired.Set(new Charge());
        _paired.Set(new Drain());
        _chargeOnly = Scene.CreateLocalEcsEntity();
        _chargeOnly.Set(new Charge());
        _triple = Scene.CreateLocalEcsEntity();
        _triple.Set(new Charge());
        _triple.Set(new Drain());
        _triple.Set(new Spark());
        _systemTick = _fixedTicks;
    }

    private void SystemsCheck()
    {
        Spin bare = _spinBare.Get<Spin>(), onObject = _spinObject.Entity.Get<Spin>();
        int ticks = _fixedTicks - _systemTick;
        Check($"an EcsSystem runs each fixed tick on bare entities ({bare.Ticks} of {ticks} ticks, angle {bare.Angle})",
            bare.Ticks > 0 && Math.Abs(bare.Ticks - ticks) <= 1 && bare.Angle == bare.Ticks * 2);
        Check("an EcsSystem leaves GameObjects' entities alone", onObject.Ticks == 0);
        Check("offline, a bare entity is this machine's", _spinBare.IsMine && _spinBare.OwnerClientId == 0 && !_spinBare.SetOwner(1));
        Charge paired = _paired.Get<Charge>(), alone = _chargeOnly.Get<Charge>();
        Drain drained = _paired.Get<Drain>();
        Check($"an EcsSystem<T1, T2> runs on entities with both data ({paired.Count}, {drained.Count}) and not one ({alone.Count})",
            paired.Count > 0 && Math.Abs(paired.Count - ticks) <= 1 && drained.Count == -paired.Count && alone.Count == 0);
        Spark spark = _triple.Get<Spark>();
        Charge tripleCharge = _triple.Get<Charge>();
        Check($"an EcsSystem<T1, T2, T3> runs on entities with all three ({spark.Count} of {ticks}; charge {tripleCharge.Count}) and not two ({_paired.Has<Spark>()})",
            spark.Count > 0 && Math.Abs(spark.Count - ticks) <= 1 && tripleCharge.Count == spark.Count * 11 && !_paired.Has<Spark>());
        _triple.DestroyLocal();
        _spinBare.DestroyLocal();
        _paired.DestroyLocal();
        _chargeOnly.DestroyLocal();
        _spinObject.Destroy();
    }

    /// What C# can do with built-in components beyond their fields (NativeComponentActions.cs).
    private void ComponentActions()
    {
        GameObject eye = Scene.CreateGameObject("ActionCamera");
        eye.Transform.Position = new Vector3(1, 2, 3);
        Camera camera = eye.AddComponent<Camera>();
        camera.FieldOfView = 60;
        var screen = new Vector2(1600, 900);
        Ray middle = camera.ScreenPointToRay(screen / 2, screen);
        Check("Camera.ScreenPointToRay through the middle of the screen goes where the camera looks",
            Vector3.Distance(middle.Origin, eye.Transform.Position) < 1e-4f &&
            Vector3.Distance(middle.Direction, eye.Transform.Forward) < 1e-4f);
        var target = new Vector2(1200, 250);
        Ray ray = camera.ScreenPointToRay(target, screen);
        Vector3 back = camera.WorldToScreenPoint(ray.GetPoint(7), screen);
        Check("WorldToScreenPoint undoes ScreenPointToRay (pixels and distance in front)",
            MathF.Abs(back.X - target.X) < 0.05f && MathF.Abs(back.Y - target.Y) < 0.05f && back.Z > 0);
        camera.Orthographic = true;
        camera.OrthographicSize = 5;
        Ray flat = camera.ScreenPointToRay(new Vector2(1600, 0), screen);
        Vector3 corner = camera.WorldToScreenPoint(flat.GetPoint(3), screen);
        Check("an orthographic camera's rays are parallel and still map back to the screen",
            Vector3.Distance(flat.Direction, eye.Transform.Forward) < 1e-4f &&
            MathF.Abs(corner.X - 1600) < 0.05f && MathF.Abs(corner.Y) < 0.05f);
        bool headless = false;
        try { camera.ScreenPointToRay(Vector2.Zero); } catch (InvalidOperationException) { headless = Screen.Width == 0; }
        Check("ScreenPointToRay without a screen asks for its size", headless || Screen.Width > 0);

        LineRenderer line = eye.AddComponent<LineRenderer>();
        line.SetPositions([new Vector3(0, 0, 0), new Vector3(1, 2, 3), new Vector3(-4, 5, 6)]);
        Vector3[] points = line.GetPositions();
        Check("LineRenderer.SetPositions and GetPositions", line.PositionCount == 3 && points.Length == 3 &&
            points[2] == new Vector3(-4, 5, 6));
        eye.AddComponent<TrailRenderer>().Clear();
        eye.AddComponent<ParticleSystem>().Play();
        Check("TrailRenderer.Clear and ParticleSystem.Play run", true);
        SequencePlayer sequence = eye.AddComponent<SequencePlayer>();
        Check("a Sequence Player with no sequence does not play", !sequence.Play() && !sequence.IsPlaying);
        DialogueRunner dialogue = eye.AddComponent<DialogueRunner>();
        Check("a Dialogue Runner with no conversation does not play",
            !dialogue.Play() && !dialogue.IsPlaying && dialogue.View == DialogueView.None && dialogue.Line == null &&
            dialogue.Choices.Count == 0);
        Check("Water.At finds no water where there is none", !Water.At(Scene, new Vector3(0, -50, 0)).IsValid);
        bool missing = false;
        try { new ParticleSystem(Scene.CreateGameObject("NoParticles")).Play(); }
        catch (InvalidOperationException error) { missing = error.Message.Contains("\"NoParticles\"") && error.Message.Contains("Particle System"); }
        Check("an action on a component the object lacks throws, naming it", missing);
        eye.Destroy();
        Scene.Find("NoParticles")?.Destroy();
    }

    // A sequence, a conversation and a tree that each send a "Ping" event, on an object with an EventProbe script.
    private void EventsBegin()
    {
        GameObject talker = Scene.CreateGameObject("Event probe");
        talker.AddComponent<EventProbe>();
        talker.AddComponent<SequencePlayer>().Sequence = "Sequences/Ping.tsequence";
        talker.AddComponent<DialogueRunner>().Dialogue = "Dialogue/Ping.tdialogue";
        talker.AddComponent<BehaviorTreeRunner>().Tree = "AI/Ping.tbt";
        talker.GetComponent<SequencePlayer>().Play();
        talker.GetComponent<DialogueRunner>().Play();
    }

    private void EventChecks()
    {
        string heard = string.Join(",", EventProbe.Heard.Distinct());
        Check($"OnSequenceEvent, OnDialogueEvent and OnTreeEvent reach a script on the same object ({heard})",
            EventProbe.Heard.Contains("sequence Ping 3") && EventProbe.Heard.Contains("dialogue Ping 2") &&
            EventProbe.Heard.Contains("tree Ping"));
        Scene.Find("Event probe")?.Destroy();
    }

    private void NativeComponentChecks()
    {
        GameObject lamp = Scene.CreateGameObject("Native component probe");
        Light light = lamp.AddComponent<Light>();
        light.Type = LightType.Point;
        light.Intensity = 7.5f;
        light.Color = new Color(1f, 0.5f, 0.25f, 1f);
        Check("AddComponent<Light> adds a native light, and its fields round-trip",
            light.IsValid && light.Type == LightType.Point && light.Intensity == 7.5f && light.Color == new Color(1f, 0.5f, 0.25f, 1f));
        Check("GetComponent<Light> finds it", lamp.GetComponent<Light>() == light && lamp.AddComponent<Light>() == light);
        MeshRenderer renderer = lamp.AddComponent<MeshRenderer>();
        renderer.Mesh = "builtin:sphere_smooth";
        renderer.Roughness = 0.3f;
        Check("MeshRenderer string and float fields", renderer.Mesh == "builtin:sphere_smooth" && MathF.Abs(renderer.Roughness - 0.3f) < 1e-6f);
        // Warm up (static caches, JIT), then a lookup and a by-name field read must not allocate.
        _ = lamp.GetComponent<MeshRenderer>().Roughness;
        _ = lamp.GetComponent<Animator>().IsValid;
        long before = GC.GetAllocatedBytesForCurrentThread();
        bool found = true;
        for (int i = 0; i < 100; i++)
            found &= lamp.GetComponent<MeshRenderer>().IsValid && !lamp.GetComponent<Animator>().IsValid
                && renderer.Roughness > 0;
        long allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        Check($"GetComponent<built-in> and a field read by name allocate nothing ({allocated} bytes for 100)", found && allocated == 0);
        lamp.Transform.Position = new Vector3(10, 20, 30);
        bool bounded = renderer.TryGetWorldBounds(out Vector3 low, out Vector3 high);
        Check($"MeshRenderer.TryGetWorldBounds is the sphere's box where it stands ({low} {high})",
            bounded && Vector3.Distance((low + high) / 2, new Vector3(10, 20, 30)) < 0.01f && high.X - low.X > 0.5f);
        renderer.Material = "Materials/Glow.tmat";
        renderer.SetMaterialColor("color", new Color(1, 0, 0, 1));
        renderer.SetMaterialFloat("roughness", 0.9f);
        Check("MeshRenderer.Material switches the material; SetMaterialColor and SetMaterialFloat run on its own copy",
            renderer.Material == "Materials/Glow.tmat" && renderer.BackFaceCulling && renderer.Texture == "");
        Check("MeshRenderer.IsVisible is false with nothing drawing (headless)", Screen.Width > 0 || !renderer.IsVisible);
        renderer.Material = "";
        // A 2 x 1 quad built in code, one metre above the lamp.
        renderer.SetMesh([new(-1, 1, 0), new(1, 1, 0), new(1, 2, 0), new(-1, 2, 0)], [0, 2, 1, 0, 3, 2]);
        bool built = renderer.TryGetWorldBounds(out Vector3 qLow, out Vector3 qHigh);
        bool badIndex = false;
        try { renderer.SetMesh([Vector3.Zero, Vector3.One, Vector3.UnitX], [0, 1, 3]); }
        catch (ArgumentOutOfRangeException) { badIndex = true; }
        bool cleared = renderer.ClearMesh() && !renderer.ClearMesh();
        renderer.TryGetWorldBounds(out Vector3 sLow, out Vector3 sHigh);
        Check($"MeshRenderer.SetMesh draws a built quad ({qLow} {qHigh}); bad indices throw; ClearMesh goes back",
            built && MathF.Abs(qHigh.X - qLow.X - 2) < 0.01f && MathF.Abs(qHigh.Y - qLow.Y - 1) < 0.01f &&
            MathF.Abs(qLow.Y - 21) < 0.01f && badIndex && cleared && sHigh.X - sLow.X < 1.01f);
        lamp.AddComponent<SphereCollider>().Radius = 0.25f;
        Rigidbody body = lamp.AddComponent<Rigidbody>();
        body.Mass = 55f;
        Check("Rigidbody and SphereCollider fields", body.Mass == 55f && lamp.GetComponent<SphereCollider>().Radius == 0.25f);
        Check("Rigidbody defaults match the Inspector's (damping 0.05, sleeping allowed, not debris)",
            body.LinearDamping == 0.05f && body.AngularDamping == 0.05f && body.AllowSleeping && !body.FreezeRotation && !body.Debris);
        body.LinearDamping = 0.5f;
        body.AngularDamping = 0.25f;
        body.FreezeRotation = true;
        body.AllowSleeping = false;
        body.Debris = true;
        Check("Rigidbody damping, freeze rotation, sleeping and debris fields",
            body.LinearDamping == 0.5f && body.AngularDamping == 0.25f && body.FreezeRotation && !body.AllowSleeping && body.Debris);
        body.LinearDamping = body.AngularDamping = 0.05f;
        body.FreezeRotation = body.Debris = false;
        body.AllowSleeping = true;
        bool refused = false;
        try { new NativeComponent(lamp, "Tallow.Light").Set("noSuchField", 1f); }
        catch (ArgumentException) { refused = true; }
        Check("setting a field that does not exist throws", refused);
        Check("a missing built-in component reads as absent", !lamp.GetComponent<NavigationAgent>().IsValid && lamp.GetComponent<NavigationAgent>() == default);
        lamp.Transient = true;
        Check("GameObject.Transient", lamp.Transient);
        Check("CommandLine reads switches", CommandLine.Has("--fixed-step") && CommandLine.Get("--no-such-switch") == null);
        AudioSource speaker = lamp.AddComponent<AudioSource>();
        speaker.Stop();
        speaker.Pause();
        speaker.Resume();
        GameObject silent = Scene.CreateGameObject("Silent");
        Check("AddComponent<AudioSource>, and a source with no clip is silent", speaker.IsValid && !speaker.IsPlaying
            && lamp.GetComponent<AudioSource>() == speaker && !silent.GetComponent<AudioSource>().IsValid);
        silent.Destroy();
        float music = Audio.GetGroupVolume(AudioGroup.Music), master = Audio.MasterVolume;
        Audio.SetGroupVolume(AudioGroup.Music, 0.25f);
        Audio.MasterVolume = 0.5f;
        Check("Audio group and master volumes round-trip",
            Audio.GetGroupVolume(AudioGroup.Music) == 0.25f && Audio.MasterVolume == 0.5f);
        Audio.SetGroupVolume(AudioGroup.Music, music);
        Audio.MasterVolume = master;
        lamp.Destroy();
    }

    private void SpawnLayerJointChecks()
    {
        Check("SpawnPoints.Count counts a team's points", SpawnPoints.Count(Scene, 1) == 1 && SpawnPoints.Count(Scene, 0) == 2);
        GameObject? red = SpawnPoints.Next(Scene, 1);
        Check("SpawnPoints.Next gives the team's own point", red?.Name == "SpawnRed");
        GameObject mover = Scene.CreateGameObject("Spawned");
        GameObject? used = SpawnPoints.Place(mover, 2);
        Check("SpawnPoints.Place moves an object to the point (" + mover.Transform.Position + ")",
            used?.Name == "SpawnBlue" && Vector3.Distance(mover.Transform.Position, new Vector3(125, 0, 120)) < 1e-3f);
        bool got = SpawnPoints.TryGet(Scene, 1, false, out Vector3 position, out Quaternion rotation);
        Check("SpawnPoints.TryGet gives the point's position and facing",
            got && Vector3.Distance(position, new Vector3(120, 0, 120)) < 1e-3f && MathF.Abs(MathF.Abs(rotation.Y) - 0.7071068f) < 1e-3f);
        float window = SpawnPoints.StartWindow;
        SpawnPoints.StartWindow = 0;
        SpawnPoints.BeginStart(Scene);
        bool open = SpawnPoints.IsStartPhase(Scene);
        SpawnPoints.EndStart(Scene);
        Check("SpawnPoints start phase opens and closes", open && !SpawnPoints.IsStartPhase(Scene));
        SpawnPoints.StartWindow = window;
        Check("GameObject.Team is 0 without teams", mover.Team == 0);
        mover.Destroy();

        var degrees = new Vector3(30f, -75f, 140f);
        Quaternion managed = Quaternion.Euler(degrees), native = RotationMath.EulerDegrees(degrees);
        Check("Quaternion.Euler in C# matches the engine's (" + managed + " / " + native + ")",
            MathF.Abs(Quaternion.Dot(managed, native)) > 0.999999f && Quaternion.Euler(degrees.X, degrees.Y, degrees.Z) == managed);
        Check("Layers.Named/Name/Mask", Layers.Named("Default") == 0 && Layers.Name(0) == "Default"
            && Layers.Mask("Default") == 1u && Layers.Mask("NoSuchLayer") == 0u);
        Check("a ray with an empty layer mask hits nothing", Scene.RaycastHit(new Vector3(3, 10, 0), -Vector3.UnitY, 20f, 0u) == null
            && Scene.RaycastHit(new Vector3(0, 10, 0), -Vector3.UnitY, 20f, Layers.Mask("Default")) != null);
        Check("WorldStates and Scene.WorldState", WorldStates.Named("Default") == 0 && WorldStates.Name(0) == "Default"
            && WorldStates.Name(99) == null && Scene.WorldState == 0 && !Scene.SetWorldState("NoSuchState") && Scene.SetWorldState("Default"));
        mWorldStateChanges.Clear();
        Scene.SetWorldState(1);
        Scene.SetWorldState(1); // No change: no call.
        Scene.SetWorldState(0);
        Check("OnWorldStateChanged hears each change with the states before and after ("
            + string.Join(",", mWorldStateChanges) + ")", string.Join(",", mWorldStateChanges) == "0>1,1>0");

        NavigationSurface surface = NavigationSurface.Find(Scene);
        Check("NavigationSurface.Find without a surface, and its queries say no",
            !surface.IsValid && !surface.SamplePosition(Vector3.Zero, 2f, out _) && !surface.RandomPoint(Vector3.Zero, 5f, new Random(1), out _));

        Rigidbody post = Scene.Find("HingePost")?.GetComponent<Rigidbody>() ?? default;
        Rigidbody door = Scene.Find("HingeDoor")?.GetComponent<Rigidbody>() ?? default;
        Hinge? hinge = Scene.CreateHinge(post, door, new Vector3(130, 5, 130), Vector3.UnitY, Vector3.UnitY, Vector3.UnitX);
        Check("Scene.CreateHinge joins two bodies", hinge is { IsValid: true });
        if (hinge is Hinge made)
        {
            made.SetMotorSpeed(3f, 100f);
            float angle = made.Angle;
            made.Destroy();
            Check("a hinge reads its angle and is gone after Destroy", float.IsFinite(angle) && !made.IsValid);
            made.SetMotorSpeed(1f, 1f); // a gone hinge does nothing
        }
        Check("a hinge is not made without bodies", Scene.CreateHinge(default, door, Vector3.Zero, Vector3.UnitY, Vector3.UnitY, Vector3.UnitX) == null);
        Suspension? spring = Scene.CreateSuspension(post, door, new Vector3(130, 5, 130), new Vector3(130.6f, 5, 130), Vector3.UnitY,
            Vector3.UnitY, Vector3.UnitX, 0.2f);
        Check("Scene.CreateSuspension, its spring and position", spring is { IsValid: true }
            && float.IsFinite(spring.Value.Position));
        spring?.SetSpring(5000f, 300f);
        spring?.Destroy();
    }

    private void UIChecks()
    {
        GameObject? menu = Scene.Find("Menu");
        MenuProbe? probe = menu?.GetComponent<MenuProbe>();
        UIDocument document = menu?.GetComponent<UIDocument>() ?? default;
        Check("a UI Document is found from C#", document.IsValid);
        Check("onload calls the C# code-behind once, with its element", probe is { Opened: 1, OpenedFrom: "screen" });
        Check("a handler can take the element's id", probe?.NamedId == "named");
        Check("UIElement.SetText changes the element's text", document.Find("status")?.Text == "Hello Ada");
        Check("UIElement.Visible hides an element", document.Find("hidden") is { Visible: false });
        Check("Find gives null for a missing id", document.Find("nope") == null);
    }

    private void AnimatorChecks()
    {
        GameObject? root = Scene.Find("AnimRoot");
        GameObject? animated = Scene.Find("Animated");
        Animator animator = root?.GetComponentInChildren<Animator>() ?? default;
        Check("GetComponentInChildren finds an Animator below the object", animator.IsValid && animator.GameObject == animated);
        Check("an object without an Animator has none", root?.GetAnimator() == null);
        Check("the Animator starts its default clip (" + animator.CurrentClip + ")", animator.CurrentClip == "Idle");
        Check("Animator.HasClip", animator.HasClip("Walk") && !animator.HasClip("Nope"));
        animator.Play("Walk", 0f);
        Check("Animator.Play switches the clip (" + animator.CurrentClip + ")", animator.CurrentClip == "Walk");
        animator.Speed = 1.5f;
        Check("Animator.Speed is set and read back", MathF.Abs(animator.Speed - 1.5f) < 1e-6f);
        Check("a missing Animator reads empty", new Animator(root ?? default).CurrentClip == "");
    }

    private void GraphChecks()
    {
        // GraphProbe.cs is GraphProbe.tgraph compiled by the editor's graph compiler (the test compiles it again).
        GraphProbe? graph = Scene.Find("Graph")?.GetComponent<GraphProbe>();
        Check("a visual script graph compiled to C# runs as a script", graph != null);
        if (graph == null)
            return;
        Vector3 expected = Vector3.Transform(Vector3.UnitZ, RotationMath.EulerDegrees(new Vector3(0, 90, 0)));
        Check("graph Rotate Vector turns a vector as the engine does", Vector3.Distance(graph.turned, expected) < 1e-4f);
        Check("graph Vector Length", MathF.Abs(graph.length - 5f) < 1e-5f);
        Check("graph text nodes build text (" + graph.label + ")", graph.label == "graph 7");
        Check("graph Find Object By Name gives the object", graph.self == graph.GameObject);
        Check("graph On Update runs every frame with its delta time", graph.frames > 200 && graph.elapsed > 3f);
        Check("graph nodes read from Tallow.API set and read the Transform", graph.position == new Vector3(1, 2, 3));
        Check("graph node read from Tallow.API calls Mathf.Lerp", MathF.Abs(graph.lerped - 2.5f) < 1e-5f);
        Check("a subgraph (Doubled.tgraph) compiles into the graph and returns its value", graph.doubled == 42f);
        // The graph's Heal event: For Each Health (GameObjects only) sets Value to Value + 1.
        EcsEntity healed = GameObject.Entity, bare = Scene.CreateLocalEcsEntity();
        healed.Set(new Health { Value = 5 });
        bare.Set(new Health { Value = 5 });
        graph.Custom_Heal();
        Check($"a graph's For Each and Set nodes change C# ECS data on GameObjects, not bare entities ({healed.Get<Health>().Value}, {bare.Get<Health>().Value}, {Scene.Query<Health>().Count})",
            healed.Get<Health>().Value == 6 && bare.Get<Health>().Value == 5);
        healed.Remove<Health>();
        bare.DestroyLocal();
        // A graph's custom event is a public method C# can call.
        int before = graph.bumped;
        graph.Custom_Bump();
        graph.Custom_Bump();
        Check("C# calls a graph's custom event", graph.bumped == before + 2);
    }

    private void HooksAndSaves()
    {
        HooksProbe? hooks = Scene.Find("Hooks")?.GetComponent<HooksProbe>();
        Check("the hooks probe is attached", hooks != null);
        if (hooks == null)
            return;
        Check("LocalEarlyUpdate runs every frame during Play", hooks.Frames > 200);
        Check($"a frame runs LocalEarlyUpdate, EarlyUpdate, LocalUpdate, Update, LateUpdate, LocalLateUpdate in order ({hooks.Order})",
            hooks.Order == "local-early early local update late local-late ");
        Check("each frame callback runs once a frame with the frame's delta time", hooks.SameCounts && hooks.FrameDelta);
        hooks.SendNetworkEvent("ping", 2.5f);
        Check("SendNetworkEvent without a session calls OnNetworkEvent here", hooks.LastEvent == "ping:2.5");
        // DebugDraw and Gizmos reach the engine's line batches (nothing to see headless; must not throw).
        DebugDraw.Line(Vector3.Zero, Vector3.UnitY, Color.Red);
        Gizmos.Sphere(Vector3.Zero, 1f, Color.Cyan, onTop: true);
        Gizmos.Box(Vector3.Zero, Vector3.One, new Color(0.5f, 0.5f, 0.5f, 0.3f));

        const string slot = "csharp-ingame-test";
        hooks.Coins = 7;
        hooks.SetSecret(1.25f);
        hooks.Unsaved = 3;
        SaveTask saved = SaveGame.Save(slot);
        Check("SaveGame.Save writes a slot", saved.Done && saved.Succeeded && SaveGame.Exists(slot));
        Check("OnSaving runs before the save reads [Saved] fields", hooks.Savings == 1);
        hooks.Coins = 0;
        hooks.SetSecret(0f);
        hooks.Unsaved = 9;
        SaveTask loaded = SaveGame.Load(slot);
        Check("SaveGame.Load finds the slot", loaded.Done && loaded.Found);
        Check("[Saved] fields come back from the save, private ones too",
            hooks.Coins == 7 && hooks.Secret == 1.25f);
        Check("fields without [Saved] are not in saves", hooks.Unsaved == 9);
        Check("OnLoaded runs after the fields are back", hooks.Loads == 1 && hooks.CoinsWhenLoaded == 7);
        SaveGame.Delete(slot);
        Check("SaveGame.Delete removes the slot", !SaveGame.Exists(slot));
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
        DocumentedApis(crate, body.Value, controller!.Value);
    }

    // The calls docs/physics-queries.md, character-controller.md, input.md, scenes.md and saving.md show in C#.
    private void DocumentedApis(GameObject crate, Rigidbody body, CharacterController controller)
    {
        PhysicsHit? capsule = Scene.CapsuleCastHit(new Vector3(-10, 10.5f, -10), new Vector3(-10, 11.5f, -10), 0.5f,
            -Vector3.UnitY, 50f);
        Check("CapsuleCastHit reaches the ground", capsule is { Distance: > 9.5f and < 10.5f } &&
            capsule.Value.HitObject?.Name == "Ground");
        PhysicsHit? box = Scene.BoxCastHit(new Vector3(-10, 10, -10), Vector3.One, Quaternion.CreateFromYawPitchRoll(0.7f, 0, 0),
            -Vector3.UnitY, 50f);
        Check("BoxCastHit reaches the ground", box is { Distance: > 9f and < 10f } && box.Value.HitObject?.Name == "Ground");
        Vector3 above = crate.Transform.Position + new Vector3(0, 5, 0);
        Check("Rigidbody.BodyId", body.BodyId != uint.MaxValue);
        Check("a sphere cast can leave out one body",
            Scene.SphereCastHit(above, 0.25f, -Vector3.UnitY, 20f)?.HitObject == crate &&
            Scene.SphereCastHit(above, 0.25f, -Vector3.UnitY, 20f, uint.MaxValue, body.BodyId)?.HitObject?.Name == "Ground");
        Check("CheckSphere and OverlapSphere find the crate",
            Scene.CheckSphere(crate.Transform.Position, 1f) && !Scene.CheckSphere(new Vector3(0, 30, 0), 1f) &&
            Scene.OverlapSphere(crate.Transform.Position, 0.75f).Contains(crate) &&
            Scene.CheckBox(crate.Transform.Position, Vector3.One, Quaternion.Identity) &&
            Scene.CheckCapsule(crate.Transform.Position, crate.Transform.Position + Vector3.UnitY, 0.3f));
        Check("a grounded character's AirTime, steepness and ground", controller.AirTime == 0 && !controller.IsOnSteepGround &&
            controller.GroundNormal.Y > 0.9f && controller.GroundVelocity == Vector3.Zero);
        float radius = controller.Radius;
        Check("CharacterController.SetBox and back to SetCapsule",
            controller.SetBox(new Vector3(0.8f, 1.8f, 0.8f)) && controller.SetCapsule(radius, 2f) && controller.Height == 2f);
        Check("input bindings: no capture in a headless run, names, text round trip",
            !InputActions.CaptureBinding("Jump", 0) && InputActions.BindingName("No Such Action", 0) is null &&
            InputActions.ToText() is { } text && Roundtrip(text));
        Check("InputActions.Describe names the standard Jump key", InputActions.Describe("Jump") == "Space" &&
            !InputActions.FromGamepad("Jump"));
        Check("GamePaths.PlayerData", GamePaths.PlayerData is { Length: > 1 } path && path.EndsWith('/'));
        GameObject? extra = Scene.LoadAdditive("Scenes/Extra.tscene");
        Check("LoadAdditive adds a scene's objects under one", extra is { } group && group.ChildCount == 2 &&
            Scene.Find("ExtraThing") is { } thing && thing.Parent == group);
        Check("Unload removes them", extra is { } added && Scene.Unload(added) && Scene.Find("ExtraThing") is null);
        Check("LoadAdditive of a missing file is null", Scene.LoadAdditive("Scenes/Nowhere.tscene") is null);
    }

    private static bool Roundtrip(string text)
    {
        InputActions.LoadText(text);
        return InputActions.ToText() == text;
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
        TypedQueries();
    }

    private void TypedQueries()
    {
        EcsEntity a = Scene.CreateLocalEcsEntity(), b = Scene.CreateLocalEcsEntity(), c = Scene.CreateLocalEcsEntity();
        Check("generic Set/Get", a.Set(new Motion { Velocity = Vector3.UnitX, Drag = 1 }) && a.Get<Motion>().Drag == 1);
        b.Set(new Motion { Velocity = Vector3.UnitY, Drag = 2 });
        b.Set(new Health { Value = 10, Hits = 0 });
        c.Set(new Health { Value = 5, Hits = 0 });
        Check("Has<T> and TryGet of missing data", a.Has<Motion>() && !a.Has<Health>() && !a.TryGet(out Health _));
        GameObject holder = Scene.Find("Runner")!.Value;
        EcsEntity onObject = holder.Entity;
        Check("a GameObject's entity takes C# data", onObject.Set(new Health { Value = 1, Hits = 0 }) &&
            onObject.GameObject == holder && a.GameObject is null);
        Check("Query<T>.Count counts bare entities and GameObjects",
            Scene.Query<Motion>().Count == 2 && Scene.Query<Health>().Count == 3 && Scene.Query<Motion, Health>().Count == 1);
        int visited = 0;
        Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) =>
        {
            h.Hits++;
            h.Value *= 2;
            visited++;
        });
        Check("ForEach visits every match and writes changes back",
            visited == 3 && b.Get<Health>().Value == 20 && c.Get<Health>().Hits == 1 && onObject.Get<Health>().Value == 2);
        Scene.Query<Motion, Health>().ForEach((EcsEntity e, ref Motion m, ref Health h) =>
        {
            m.Velocity *= h.Value;
            h.Hits += 10;
        });
        Check("a two-component query reads and writes both", b.Get<Motion>().Velocity == new Vector3(0, 20, 0) &&
            b.Get<Health>().Hits == 11 && a.Get<Motion>().Velocity == Vector3.UnitX);
        Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) =>
        {
            if (e == onObject)
                e.Set(new Health { Value = 99, Hits = h.Hits });
        });
        Check("Set during ForEach is kept when the row is left alone", onObject.Get<Health>().Value == 99);
        // Destroying and removing during ForEach: the gone are not written back (nor resurrected).
        Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) =>
        {
            h.Value = -1;
            if (e == c)
                c.DestroyLocal();
            if (e == b)
                b.Remove<Health>();
        });
        Check("ForEach skips writing to entities destroyed or changed during it",
            !c.IsAlive && !b.Has<Health>() && onObject.Get<Health>().Value == -1 && Scene.Query<Health>().Count == 1);
        Check("Remove<T> on a GameObject", onObject.Remove<Health>() && !onObject.Has<Health>() && !onObject.Remove<Health>());
        bool threw = false;
        try { a.Set(new NotData()); } catch (InvalidOperationException) { threw = true; }
        Check("a struct that is not [Component] data is refused with a message", threw);
        a.DestroyLocal();
        b.DestroyLocal();
        StructureDuringForEach();
        QueryFilters();
    }

    /// Query With/Without terms, and a tag (a [Component] struct with no fields).
    private void QueryFilters()
    {
        // Earlier checks leave Health on a few objects (none Frozen): count from them.
        int before = Scene.Query<Health>().Count;
        var made = new List<EcsEntity>();
        for (int i = 0; i < 6; i++)
        {
            EcsEntity entity = Scene.CreateLocalEcsEntity();
            entity.Set(new Health { Value = i });
            if (i % 2 == 0)
                entity.Set(new Frozen());
            if (i < 2)
                entity.Set(new Motion { Drag = 1 });
            made.Add(entity);
        }
        int all = Scene.Query<Health>().Count;
        int frozen = Scene.Query<Health>().With<Frozen>().Count;
        int thawed = Scene.Query<Health>().Without<Frozen>().Count;
        Check($"Query With/Without a tag ({all - before}, {frozen}, {thawed - before})",
            all - before == 6 && frozen == 3 && thawed - before == 3);
        float sum = 0;
        Scene.Query<Health>().Without<Frozen>().Without<Motion>().ForEach((EcsEntity e, ref Health h) =>
        {
            if (!made.Contains(e))
                return;
            sum += h.Value;
            h.Hits = 7;
        });
        Check($"ForEach with two Without terms visits and writes only those ({sum})",
            sum == 3 + 5 && made[3].Get<Health>().Hits == 7 && made[2].Get<Health>().Hits == 0);
        Check("With and Without together, and on a two-data query",
            Scene.Query<Health>().With<Frozen>().Without<Motion>().Count == 2 &&
            Scene.Query<Health, Motion>().With<Frozen>().Count == 1);
        bool threw = false;
        try { Scene.Query<Health>().With<Frozen>().With<Motion>().Without<Frozen>().Without<Motion>().With<Frozen>(); }
        catch (InvalidOperationException) { threw = true; }
        Check("a query takes at most four With/Without terms", threw);
        foreach (EcsEntity entity in made)
            entity.DestroyLocal();
    }

    /// ForEach works on the data in place; what scripts do inside it that changes structure must still work.
    private void StructureDuringForEach()
    {
        var made = new List<EcsEntity>();
        for (int i = 0; i < 40; i++)
        {
            EcsEntity entity = Scene.CreateLocalEcsEntity();
            entity.Set(new Health { Value = i, Hits = 0 });
            made.Add(entity);
        }
        GameObject victim = Scene.CreateGameObject("ForEachVictim");
        victim.Entity.Set(new Health { Value = 1000, Hits = 0 });
        int visited = 0, spawnedObjects = 0;
        bool readsOld = true, sawNew = false;
        var spawned = new List<EcsEntity>();
        Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) =>
        {
            visited++;
            sawNew |= spawned.Contains(e);
            h.Hits += 1;
            if (h.Value == 3)
            {
                // A new bare entity with data, and a new GameObject that is moved and given data.
                EcsEntity child = Scene.CreateLocalEcsEntity();
                child.Set(new Health { Value = 500, Hits = 0 });
                spawned.Add(child);
                GameObject made3 = Scene.CreateGameObject("MadeInForEach");
                made3.Transform.Position = new Vector3(1, 2, 3);
                made3.Entity.Set(new Health { Value = 501, Hits = 0 });
                spawnedObjects += made3.Transform.Position == new Vector3(1, 2, 3) ? 1 : 0;
            }
            if (h.Value == 5)
            {
                // New values for data an entity already has are written at once; adding data is queued.
                made[6].Set(new Health { Value = 6, Hits = 77 });
                readsOld &= made[6].Get<Health>().Hits == 77;
                made[7].Set(new Motion { Drag = 4 });
                readsOld &= !made[7].Has<Motion>();
            }
            if (h.Value == 7)
                made[8].DestroyLocal();
            if (h.Value == 9)
                victim.Destroy();
        });
        Check("ForEach in place visits each entity there at the start once, not ones made during it",
            visited == 41 && !sawNew);
        Check("a GameObject made inside ForEach works at once (Transform) and its data arrives after",
            spawnedObjects == 1 && Scene.Find("MadeInForEach")?.Entity.Get<Health>().Value == 501);
        Check("inside ForEach a new value is seen at once and new data arrives when it ends",
            readsOld && made[6].Get<Health>().Hits >= 77 && made[7].Get<Motion>().Drag == 4);
        Check("an entity destroyed inside ForEach is gone after it, and a new one has its data",
            !made[8].IsAlive && spawned.Count == 1 && spawned[0].Get<Health>().Value == 500);
        int hits = 0;
        Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) => hits += h.Hits > 0 ? 1 : 0);
        Check("writes through ForEach refs land in the data", hits >= 38);
        // An action that throws ends the ForEach cleanly: the queue is applied and the next ForEach works.
        bool caught = false;
        try
        {
            Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) =>
            {
                made[0].Set(new Health { Value = 0, Hits = 99 });
                throw new InvalidOperationException("from ForEach");
            });
        }
        catch (InvalidOperationException) { caught = true; }
        int after = 0;
        Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) => after++);
        Check("an exception in ForEach ends it: queued changes applied, later ForEach still works",
            caught && made[0].Get<Health>().Hits == 99 && after > 0);
        // Nested ForEach over the same data.
        int pairs = 0;
        Scene.Query<Health>().ForEach((EcsEntity e, ref Health h) =>
        {
            if (h.Value < 2)
                Scene.Query<Health>().ForEach((EcsEntity inner, ref Health other) => pairs++);
        });
        Check("ForEach can run inside ForEach", pairs == 2 * Scene.Query<Health>().Count);
        foreach (EcsEntity entity in made)
            entity.DestroyLocal();
        foreach (EcsEntity entity in spawned)
            entity.DestroyLocal();
        Scene.Find("MadeInForEach")?.Destroy();
    }

    private readonly List<UpdateStep> _steps = [];

    /// Each script's Update is checked just before it runs: an earlier one may have disabled it or its object.
    private void UpdateOrderSetup()
    {
        for (int i = 0; i < 6; i++)
        {
            GameObject step = Scene.CreateGameObject("UpdateStep" + i);
            UpdateStep script = step.AddComponent<UpdateStep>();
            script.Index = i;
            script.Steps = _steps;
            _steps.Add(script);
        }
    }

    private void UpdateOrderChecks()
    {
        // 0 disables 1 and deactivates 3's object on its first Update; 2 throws every time; 4 and 5 run after it.
        int runs = _steps[0].Updates;
        Check("a script disabled by an earlier one in the same frame does not run", _steps[1].Updates == 0);
        Check("a script whose object an earlier one deactivated does not run", _steps[3].Updates == 0);
        Check("a script throwing in Update does not stop the scripts after it",
            runs >= 3 && _steps[2].Updates == runs && _steps[4].Updates == runs && _steps[5].Updates == runs);
        Check("scripts in a row run in the scene's order", _steps[5].SawBefore == 3); // 0, 2 and 4 ran first
        foreach (UpdateStep step in _steps)
            step.GameObject.Destroy();
    }

    private void LocalState()
    {
        GameObject spun = Scene.CreateGameObject("RotateProbe");
        Quaternion start = Quaternion.Normalize(new Quaternion(0.1f, 0.7f, -0.2f, 0.6f));
        spun.Transform.LocalRotation = start;
        var degrees = new Vector3(30, -45, 10);
        spun.Transform.Rotate(degrees);
        Quaternion expected = Quaternion.Normalize(start * Quaternion.CreateFromYawPitchRoll(
            degrees.Y * (MathF.PI / 180), degrees.X * (MathF.PI / 180), degrees.Z * (MathF.PI / 180)));
        Quaternion got = spun.Transform.LocalRotation;
        Check("Transform.Rotate turns in local space by X/Y/Z degrees (Y, then X, then Z)",
            MathF.Abs(Quaternion.Dot(got, expected)) > 0.9999f);
        spun.Destroy();
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

/// await on the game thread: NextFrame, Wait (game time) and Task.Delay (real time, back on the game thread).
public class AsyncProbe : Script
{
    public int Step;
    public bool StayedOnGameThread = true;
    public int FramesForNextFrame = -1, FramesForWait = -1;
    private int _thread, _frames;

    public override void LocalUpdate(float deltaTime) => _frames++;

    public override void Start()
    {
        _thread = Environment.CurrentManagedThreadId;
        Run();
        Boom();
    }

    private void Note()
    {
        if (Environment.CurrentManagedThreadId != _thread || SynchronizationContext.Current == null)
            StayedOnGameThread = false;
    }

    private async void Run()
    {
        Step = 1;
        await NextFrame(); // From Start: after the next frame's LateUpdate.
        // From here (after this frame's LateUpdate) the next frame is one Update away.
        int before = _frames;
        await NextFrame();
        FramesForNextFrame = _frames - before;
        Note();
        Step = 2;
        before = _frames;
        await Wait(0.5f);
        FramesForWait = _frames - before;
        Note();
        Step = 3;
        await Task.Delay(15, Destroyed);
        Note();
        Step = 4;
    }

    private async void Boom()
    {
        await NextFrame();
        throw new InvalidOperationException("thrown on purpose by async code");
    }
}

/// Destroyed while it waits: the wait ends as cancelled and nothing after it runs.
public class AsyncDoomed : Script
{
    public static bool Cancelled, RanOn;

    public override void Start() => Forever();

    private async void Forever()
    {
        try
        {
            await Wait(1000f);
            RanOn = true;
        }
        catch (OperationCanceledException)
        {
            Cancelled = true;
            throw; // Ending by cancellation is normal: it is not reported.
        }
    }
}

/// The frame callbacks, OnNetworkEvent and the save hooks.
public class HooksProbe : Script
{
    [Saved] public int Coins;
    [Saved] private float secret;
    public int Unsaved;
    public int Frames, Savings, Loads, CoinsWhenLoaded = -1;
    public string LastEvent = "";

    public float Secret => secret;
    public void SetSecret(float value) => secret = value;

    public string Order = "";
    private int _early, _local, _update, _late, _localLate;

    // Checked as each frame starts (the checks read it partway through one): every callback ran once a frame.
    private bool _countsDiffered;
    public bool SameCounts => Frames > 10 && !_countsDiffered;
    public bool FrameDelta { get; private set; } = true;

    // One frame (the tenth) records the order the callbacks ran in.
    private void Note(string name, float deltaTime)
    {
        FrameDelta &= deltaTime == Time.DeltaTime;
        if (Frames == 10)
            Order += name + " ";
    }

    public override void LocalEarlyUpdate(float deltaTime)
    {
        _countsDiffered |= _early != Frames || _local != Frames || _update != Frames || _late != Frames || _localLate != Frames;
        Frames++;
        Note("local-early", deltaTime);
    }
    public override void EarlyUpdate(TickInput input, float deltaTime) { _early++; Note("early", deltaTime); }
    public override void LocalUpdate(float deltaTime) { _local++; Note("local", deltaTime); }
    public override void Update(TickInput input, float deltaTime) { _update++; Note("update", deltaTime); }
    public override void LateUpdate(TickInput input, float deltaTime) { _late++; Note("late", deltaTime); }
    public override void LocalLateUpdate(float deltaTime) { _localLate++; Note("local-late", deltaTime); }
    public override void OnNetworkEvent(string name, float value) =>
        LastEvent = name + ":" + value.ToString(System.Globalization.CultureInfo.InvariantCulture);
    public override void OnSaving() => Savings++;
    public override void OnLoaded()
    {
        Loads++;
        CoinsWhenLoaded = Coins;
    }
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

/// One of a row of scripts for ApiChecks.UpdateOrderChecks.
public class UpdateStep : Script
{
    public int Index, Updates, SawBefore;
    public List<UpdateStep>? Steps;

    public override void Update(TickInput input, float deltaTime)
    {
        Updates++;
        SawBefore = 0;
        for (int i = 0; i < Index; i++)
            SawBefore += Steps![i].Updates >= Updates ? 1 : 0;
        if (Index == 0 && Updates == 1)
        {
            Steps![1].Enabled = false;
            Steps[3].GameObject.SetActive(false);
        }
        if (Index == 2)
            throw new InvalidOperationException("thrown on purpose by UpdateStep");
    }
}

/// Counts its Updates (an object destroyed during a frame must get no more).
public class UpdateCounter : Script
{
    public int Updates;

    public override void Update(TickInput input, float deltaTime) => Updates++;
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
    public bool DestroyRan;
    public override void OnDestroy() => DestroyRan = true;
}

[Component]
public struct Motion
{
    public Vector3 Velocity;
    public float Drag;
}

[Component]
public struct Health
{
    public float Value;
    public int Hits;
}

[Component]
public struct Spin
{
    public float Speed, Angle;
    public int Ticks;
}

public class SpinSystem : EcsSystem<Spin>
{
    public override void Update(EcsEntity entity, ref Spin spin, TickInput input, float deltaTime)
    {
        spin.Ticks++;
        spin.Angle += spin.Speed;
    }
}

[Component]
public struct Charge
{
    public int Count;
}

[Component]
public struct Drain
{
    public int Count;
}

[Component]
public struct Spark
{
    public int Count;
}

/// Runs on bare entities with Charge, Drain and Spark (ChargeDrainSystem runs on them too: Charge gains 1 + 10 a tick).
public class ChargeDrainSparkSystem : EcsSystem<Charge, Drain, Spark>
{
    public override void Update(EcsEntity entity, ref Charge charge, ref Drain drain, ref Spark spark, TickInput input, float deltaTime)
    {
        spark.Count++;
        charge.Count += 10;
    }
}

/// Runs on bare entities with both Charge and Drain.
public class ChargeDrainSystem : EcsSystem<Charge, Drain>
{
    public override void Update(EcsEntity entity, ref Charge charge, ref Drain drain, TickInput input, float deltaTime)
    {
        charge.Count++;
        drain.Count--;
    }
}

public enum CheckKind { First, Second }

/// A tag: no fields, only there or not.
[Component]
public struct Frozen
{
}

public struct NotData
{
    public int X;
}

/// <summary>Code-behind for UI/probe.tui: its onload handlers are this script's methods.</summary>
public class MenuProbe : Script
{
    public string playerName = "Ada";
    public int Opened;
    public string OpenedFrom = "", NamedId = "";

    private void OnOpen(UIElement element)
    {
        Opened++;
        OpenedFrom = element.Id;
        UIDocument document = GetComponent<UIDocument>();
        document.Find("status")?.SetText("Hello " + playerName);
        if (document.Find("hidden") is { } hidden)
            hidden.Visible = false;
    }

    public void Named(string id) => NamedId = id;
}

/// Reference fields set in the scene file (as the Inspector saves them): objects, a built-in component, a Transform,
/// a C# script on an object that comes later in the scene, and a reference to an object that is not there.
public class RefProbe : Script
{
    public GameObject Target;
    public Light Lamp;
    public Transform? Spot;
    public LateHelper? Late;
    public GameObject? Gone;
    // Not saved nor synced, though marked: an object id means nothing in another run or on another machine.
    [Saved, Sync] public GameObject? NotKept;
    [Saved] public int KeptNumber = 7;
    public bool LateWasAwakeInMyAwake;
    public bool LateSetInMyAwake;

    public override void Awake()
    {
        LateSetInMyAwake = Late != null;
        LateWasAwakeInMyAwake = Late is { WasAwake: true };
    }
}

public class LateHelper : Script
{
    public bool WasAwake;
    public override void Awake() => WasAwake = true;
}

/// In Prefabs/RefPair.tprefab: points at its own child, whichever copy it is.
public class PairProbe : Script
{
    public GameObject Partner;
}

/// Hears the Sequence Player's, Dialogue Runner's and Behavior Tree Runner's events on its object.
public class EventProbe : Script
{
    public static readonly List<string> Heard = [];

    public override void OnSequenceEvent(string name, float value) => Heard.Add($"sequence {name} {value}");
    public override void OnDialogueEvent(string name, float value) => Heard.Add($"dialogue {name} {value}");
    public override void OnTreeEvent(string name) => Heard.Add($"tree {name}");
}
