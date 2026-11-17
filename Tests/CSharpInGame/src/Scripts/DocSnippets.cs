using System.IO.Compression;
using System.Numerics;
using Tallow;

namespace InGame;

/// <summary>
/// The C# code shown in docs/*.md, so that it keeps compiling. Not attached to anything: each method is one
/// doc's snippet (the doc's text is the same code, give or take the surrounding method).
/// </summary>
public class DocSnippets : Script
{
    private int lives = 3;
    public bool Aiming;

    // docs/animator.md, "From scripts"
    private void Animator(Vector3 velocity, CharacterController controller)
    {
        var animator = GetComponent<Animator>();
        animator.SetFloat("speed", velocity.Length());
        animator.SetBool("grounded", controller.IsGrounded);
        animator.SetInteger("lives", lives);
        animator.SetTrigger("jump");

        if (animator.CurrentState == "Jump" && animator.NormalizedTime > 0.5f) { /* past the top of the jump */ }
        animator.Play("Idle");            // jump straight to a state
        animator.CrossFade("Run", 0.3f);  // or fade to it
    }

    // docs/animator.md, layers
    private void AnimatorLayers(Animator animator)
    {
        animator.SetLayerWeight(1, Aiming ? 1f : 0f);   // layer 1: the second in the controller's list
    }

    // docs/audio.md
    private void AudioSnippets(Vector3 position, bool headphones, float strengthSlider, float headSizeSlider, float trebleSlider)
    {
        var source = GetComponent<AudioSource>();
        source.Play();                              // the Audio Clip
        source.Play("Sounds/alarm.ogg");            // a different one
        source.PlayOneShot("Sounds/step.wav");      // on top of whatever is playing; any number can overlap
        source.Pause(); source.Resume(); source.Stop();
        if (source.IsPlaying) { }
        source.Time = source.Length / 2;

        Audio.PlayOneShot("Sounds/explosion.wav", position);     // at a place in the world
        Audio.PlayOneShot2D("Sounds/click.wav");                 // no position: interface sounds

        Audio.Hrtf = true;       // headphone 3D; can be switched while sounds play
        Audio.Hrtf = false;      // ordinary left-right panning (the default)

        // In an options menu:
        Audio.Hrtf = headphones;
        Audio.HrtfStrength = strengthSlider;      // 0..1
        Audio.HrtfHeadSize = headSizeSlider;      // 0.5..1.5
        Audio.HrtfTreble = trebleSlider;          // -12..12

        Audio.MasterVolume = 0.8f;
        Audio.SetGroupVolume(AudioGroup.Music, 0.5f);
        Audio.SetGroupVolume(AudioGroup.Effects, 1.0f);
    }

    // docs/physics-queries.md
    private void PhysicsQueries()
    {
        if (Scene.SphereCastHit(Transform.Position, 0.5f, -Vector3.UnitY, 5f) is PhysicsHit hit)
            Log.Info($"Hit {hit.HitObject?.Name} after {hit.Distance} meters");

        // Ignore the player's own rigidbody when probing the ground.
        var body = GetComponent<Rigidbody>();
        if (body.HasBody)
            Scene.SphereCastHit(Transform.Position, 0.25f, -Vector3.UnitY, 2f, uint.MaxValue, body.BodyId);

        // Endpoints are hemisphere centers, not the outer tips of the capsule.
        Scene.CapsuleCastHit(new Vector3(0, 0.5f, 0), new Vector3(0, 1.5f, 0), 0.5f, Vector3.UnitZ, 10f);

        // Size means full width/height/depth; rotation determines box orientation.
        Scene.BoxCastHit(Transform.Position, new Vector3(1, 2, 1), Quaternion.Euler(0, 45, 0), Vector3.UnitZ, 10f);
    }

    private float speed = 5f;
    private Vector3 velocity;

    // docs/character-controller.md
    public override void Update(TickInput input, float deltaTime)
    {
        var controller = GetComponent<CharacterController>();

        // Walking: you give the horizontal velocity; falling, gravity and jumping are handled.
        controller.SimpleMove(input.MoveDirection * speed, deltaTime, input.Pressed(InputButton.Jump) ? 6.5f : 0f);

        // Full control: exactly this velocity, no gravity added (flying, swimming, ladders).
        controller.Move(velocity, deltaTime);
    }

    // docs/character-controller.md, shapes
    private void CharacterShape(CharacterController controller)
    {
        if (!controller.SetBox(new Vector3(1.2f, 0.8f, 1.2f), 0.1f))
            Log.Info("Not enough room to become that here.");
        controller.SetCapsule(0.35f, 1.8f);
    }

    private float yaw, pitch, sensitivity = 0.1f;

    private void Jump() { }

    // docs/input.md
    public override void LocalUpdate(float deltaTime)
    {
        if (InputActions.Pressed("Jump"))
            Jump();
        Vector2 move = InputActions.Vector("Move");   // x right, y forward; no longer than 1
        Vector2 look = InputActions.Delta("Look");    // how far to turn this frame
        yaw += look.X * sensitivity;
        pitch -= look.Y * sensitivity;
    }

    // docs/input.md, rebinding
    private void Rebinding()
    {
        if (InputActions.CaptureBinding("Jump", 0))           // true on the frame a key or button goes down
            Log.Info($"Jump is now {InputActions.BindingName("Jump", 0)}");

        string text = InputActions.ToText();                    // save this with the player's settings...
        InputActions.LoadText(text);                            // ...and load it when the game starts
    }

    // docs/scenes.md
    private void Scenes()
    {
        GameObject? level = Scene.LoadAdditive("Scenes/Harbour.tscene", applyEnvironment: true);
        // ... play ...
        if (level is GameObject loaded)
            Scene.Unload(loaded);

        SceneManager.Load("Scenes/Credits.tscene");
    }

    // docs/saving.md
    private void PlayerDataPath()
    {
        string path = $"{GamePaths.PlayerData}notes.txt";
        System.IO.File.WriteAllText(path, "hello");
    }
}

// docs/saving.md
public class SavedPlayer : Script
{
    [Saved] public int Coins;
    [Saved] public Vector3 Checkpoint;
    [Saved] public float Health;
    public float Speed;                  // not saved

    public void SaveAndLoad()
    {
        SaveGame.Save();                          // the "default" slot
        SaveGame.Save("Castle");                  // or any name a player types
        SaveTask load = SaveGame.Load("Castle");
        if (load.Done && !load.Found)
            Log.Info("No save called Castle yet.");
    }
}

// docs/steam.md
public class SteamSnippets : Script
{
    private string folder = "", previewPng = "";

    private void SignIn()
    {
        if (Steam.Start())                              // connects with the project's App ID; false if Steam is not there
            Log.Info($"Signed in as {Steam.UserName} ({Steam.UserId})");
        Achievements.Unlock("FIRST_WIN");
    }

    private void Presence()
    {
        // Host, every couple of seconds:
        Steam.SetPresence("connect", Steam.UserId.ToString());
        Steam.SetPresence("status", "Deathmatch on Foundry");

        // Friend, on the Join screen:
        foreach (ulong friend in Steam.Friends)
        {
            string host = Steam.FriendPresence(friend, "connect");
            if (host != "") { /* list this friend; to join, start a client with the address set to host */ }
        }

        // Either, every frame:
        if (Steam.TakeJoinRequest(out string join)) { /* join it */ }
    }

    private async Task WorkshopUse()
    {
        int count = Workshop.MountInstalled();
        Log.Info($"{count} Workshop item(s) loaded.");

        WorkshopItem? item = null;
        foreach (WorkshopItem found in await Workshop.Browse(WorkshopSort.Popular))
        {
            Log.Info($"{found.Title} ({found.Id})");
            item = found;
        }
        if (item == null)
            return;
        Workshop.Subscribe(item.Id);        // Steam downloads it in the background
        if (Workshop.IsInstalled(item.Id)) Workshop.MountInstalled();

        WorkshopPublishResult result = await Workshop.Publish(folder, "My arena", "A small arena for four players.", previewPng,
            "level,arena", WorkshopVisibility.Public);
        Log.Info(result.Succeeded ? $"Published as {result.Id}" : result.Message);
    }
}

// docs/http.md
public class HttpSnippets : Script
{
    static readonly HttpClient Client = new() { DefaultRequestHeaders = { { "User-Agent", "MyGame" } } };
    public float Progress;

    private async Task Fetch(string url, string path, string zipPath, string folder)
    {
        string releases = await Client.GetStringAsync("https://api.github.com/repos/owner/repo/releases");

        // A file, with progress:
        using (HttpResponseMessage response = await Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
        {
            response.EnsureSuccessStatusCode();
            long total = response.Content.Headers.ContentLength ?? -1;
            await using Stream input = await response.Content.ReadAsStreamAsync();
            await using FileStream output = File.Create(path + ".part");
            var buffer = new byte[81920];
            long done = 0;
            for (int read; (read = await input.ReadAsync(buffer)) > 0; done += read)
            {
                await output.WriteAsync(buffer.AsMemory(0, read));
                Progress = total > 0 ? (float)done / total : -1;
            }
        }
        File.Move(path + ".part", path, overwrite: true);

        ZipFile.ExtractToDirectory(zipPath, folder, overwriteFiles: true);
    }
}

// docs/anti-cheat.md
public class AntiCheatSnippets : Script
{
    public class Buyer { public int Money; }

    private void Snippets(int clientId, bool headshot, int price, Buyer player)
    {
        AntiCheat.SetAction(CheatKind.Debugger, CheatAction.Kick);        // a competitive game might
        AntiCheat.SetAction(CheatKind.SuspiciousAim, CheatAction.Ignore);

        AntiCheat.ReportShot(Scene, clientId);                 // every pull of the trigger
        AntiCheat.ReportHit(Scene, clientId, headshot);        // when it hit another player
        var (shots, hits, headshots, snapHits) = AntiCheat.AimStats(Scene, clientId);

        if (price > player.Money)
            AntiCheat.Report(Scene, clientId, CheatKind.MemoryTampering, "bought something with no money");

        GuardedInt coins = 100;
        coins += 5;
        int shown = coins;
        GuardedFloat health = 100;

        AntiCheat.OnViolation += violation =>
        {
            // Show it, save it, or ban: violation.ClientId is the session's number for the player.
        };
        foreach (CheatViolation violation in AntiCheat.Violations) { /* the last 256, newest last */ }

        if (AntiCheat.IsBanned("steam:76561198000000000"))
            Network.Kick(Scene, clientId);
    }
}

// docs/spawn-points.md
public class SpawnPointSnippets : Script
{
    private void Snippets(GameObject player, int team)
    {
        GameObject? point = SpawnPoints.Next(Scene);           // the one used longest ago
        GameObject? random = SpawnPoints.Random(Scene, team);  // a random one for a team
        SpawnPoints.Place(player, team);                       // move an object there, facing the point's way

        SpawnPoints.StartWindow = 0;          // never closes by itself
        SpawnPoints.BeginStart(Scene);        // new round: start points can be used again, once each
        SpawnPoints.EndStart(Scene);          // from here on, ordinary points only

        int myTeam = GameObject.Team;         // 1, 2, ... or 0 when there are no teams
        Network.ChooseTeam = clientId => clientId % 2 + 1;

        if (Scene.IsServer)
            SpawnPoints.Place(GameObject, GameObject.Team, random: true);

        if (SpawnPoints.TryGet(Scene, team, false, out Vector3 position, out Quaternion rotation))
            Scene.Spawn("Guard", position, rotation);
    }
}

// docs/layers-and-tags.md
public class LayerTagSnippets : Script
{
    private void Snippets(Vector3 eye, Vector3 forward, Vector3 origin, Vector3 direction, Vector3 point, GameObject shooter)
    {
        uint mask = Layers.Mask("Default", "Enemies");
        if (Scene.RaycastHit(eye, forward, 100, mask) is PhysicsHit hit) { }
        PhysicsHit? shapeHit = Scene.SphereCastHit(origin, 0.3f, direction, 20, mask);
        GameObject[] near = Scene.OverlapSphere(point, 2, mask);

        GameObject? player = Scene.FindWithTag("Player");      // the first active one
        GameObject[] cover = Scene.FindAllWithTag("Cover");    // all of them, active or not
        GameObject.AddTag("Searched"); GameObject.RemoveTag("Searched"); GameObject.HasTag("Enemy");

        Scene.SetWorldState("Echo");
        shooter.WorldStates = 1u << WorldStates.Named("Echo");
        using (Scene.QueryInWorldStates(shooter.WorldStates))
        {
            if (Scene.SphereCastHit(eye, 0.05f, forward, 200) is PhysicsHit seen) { }
        }
    }

    public override void OnWorldStateChanged(int from, int to) { }
}

// docs/voice-chat.md
public class VoiceChatSnippets : Script
{
    private void Snippets(bool pushToTalkBox, KeyCode chosenKey, float sensitivitySlider, int clientId)
    {
        VoiceChat.PushToTalk = pushToTalkBox;
        VoiceChat.PushToTalkKey = chosenKey;
        VoiceChat.Activation = sensitivitySlider;

        VoiceChat.AutoLevel = true;
        VoiceChat.SetPlayerVolume(clientId, 2);
        VoiceChat.Volume = 0.8f;
        VoiceChat.MicrophoneVolume = 1.5f;
        VoiceChat.Muted = true;
        VoiceChat.Deafened = true;
        VoiceChat.Mute(clientId, true);
        Audio.SetGroupVolume(AudioGroup.Voice, 0.5f);
        if (VoiceChat.IsSpeaking(clientId)) { }
        if (VoiceChat.IsTransmitting) { }
        VoiceChat.OnSpeakingChanged += (id, speaking) => { };

        VoiceChat.Enabled = true;
        VoiceChat.Loopback = true;
        float level = VoiceChat.MicrophoneLevel;
        bool hasOne = VoiceChat.HasMicrophone;
        int owner = GameObject.OwnerClientId;
    }
}

// docs/ik.md
public class IKSnippets : Script
{
    public GameObject LeftHand, RightHand;      // drag the hand bones in

    Limb leftArm => IK.Limb(GameObject, LeftHand) ?? throw new InvalidOperationException("no Limb IK for the left hand");

    private void Snippets(Animator animator, float pull, GameObject upper, GameObject middle, GameObject tip, GameObject[] bones,
        Vector3 targetPoint, bool usePole, Vector3 polePoint, Vector3 localForward, float weight, float maxDegrees,
        Vector3 directionA, Vector3 directionB, GameObject nextGrip)
    {
        leftArm.LetGo(0.15f);
        animator.SetTrigger("Throw");
        leftArm.Grab(0.2f);
        leftArm.FadeWeight(0.5f, 0.3f);
        leftArm.SetTarget(nextGrip, 0.2f);
        bool holding = leftArm.IsHolding && leftArm.Reach < 1;

        var hand = LeftHand.GetComponent<HandPose>();
        hand.SetShape(HandShape.Grip);
        hand.SetShape(HandShape.Open, 0.3f);
        hand.Trigger = pull;
        hand.Curl(1, 0.5f);
        GameObject.GetComponent<LookAtIK>().LookAt(targetPoint);

        IK.TwoBone(upper, middle, tip, targetPoint, usePole, polePoint);
        IK.Chain(bones, tip, targetPoint);
        IK.LookAt(bones, localForward, targetPoint, weight, maxDegrees);
        Quaternion turn = IK.FromTo(directionA, directionB);
        IK.Solve(Scene);
    }
}

// docs/networking.md
[Component]
public struct FlightData
{
    [Sync] public Vector3 Velocity;
    [Sync] public float Fuel;
    public int LocalEffect; // not sent
}

public class FlightController : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        if (GameObject.Entity.TryGet(out FlightData flight))
            Transform.Position += flight.Velocity * deltaTime;
    }
}

public class Hover : Script
{
    public float Speed = 5;
    [Sync] public int Score;

    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Position += input.MoveDirection * Speed * deltaTime;
        if (input.Pressed(InputButton.Jump))
            Transform.Position += new Vector3(0, 1, 0);
        if (Scene.IsServer && input.Pressed(InputButton.Use))
            Score++;
        if (!Scene.IsReplaying && input.Pressed(InputButton.Custom1)) { }
    }
}

public class DocHealth : Script
{
    [Sync] public int Value = 100;
    [Sync] public string Title = "Rookie";

    public void Hurt(int amount) => Value -= amount;
}

public class Shooter : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        if (Scene.IsServer && input.Pressed(InputButton.Fire))
        {
            PhysicsHit? hit;
            using (LagCompensated())
                hit = Scene.RaycastHit(Transform.Position, Vector3.Transform(Vector3.Forward, input.LookRotation), 100);
            hit?.HitObject?.GetComponent<DocHealth>()?.Hurt(25);
        }
    }

    public override void Awake()
    {
        Network.HostMigration = true;
        Network.OnBecameHost(Scene, () => { });
        Network.OnHostChanged(Scene, address => { });
        Network.SetInterpolationTicks(Scene, 4);
        Network.SetPredictPhysics(Scene, true);
        bool migrating = Network.IsMigrating(Scene) && Network.GetMaxRewindTicks(Scene) > 0;
    }
}

// docs/lines-and-trails.md
public class LineSnippets : Script
{
    private void Snippets(Vector3 start, Vector3 end, Vector3 tip, GameObject camera, GameObject ball, float ballRadius, float power,
        LineRenderer aim)
    {
        var line = GetComponent<LineRenderer>();
        line.SetPositions([start, end]);
        line.PositionCount = 3;
        line.SetPosition(2, tip);
        float length = line.Length;

        Vector3 direction = camera.Transform.Forward;
        direction.Y = 0;
        direction = Vector3.Normalize(direction);
        Vector3 from = ball.Transform.Position + direction * (ballRadius + 0.05f);
        aim.SetPositions([from, from + direction * Mathf.Lerp(0.5f, 3, power)]);
        aim.StartColor = new Color(1, 1, 1);
        aim.EndColor = Color.Lerp(new Color(1, 1, 1, 0), new Color(1, 0.2f, 0.1f, 0), power);
        aim.StartWidth = aim.EndWidth = 0.08f;
        aim.DashLength = 0.08f;
        aim.GapLength = 0.12f;
    }
}

// docs/behavior-trees.md
public class GuardActions : Script
{
    public int Ammo = 3;

    public bool HasAmmo() => Ammo > 0;      // use as a condition
    public void Shoot() { Ammo--; }          // use as an action

    private void Snippets()
    {
        var brain = GetComponent<BehaviorTreeRunner>();
        brain.SendEvent("Hit");
        AINoise.Make(Scene, Transform.Position, 30, GameObject);
        AINoise.Forget();
    }

    public override void OnTreeEvent(string name)
    {
        if (name == "Alarm") { }
    }

    private void BlackboardSnippets(GameObject player, Vector3 position)
    {
        Blackboard board = GetComponent<BehaviorTreeRunner>().Blackboard;
        board.SetFlag("alert", true);
        board.SetObject("target", player);
        board.SetVector("noise", position);
        _ = board.GetNumber("ammo") + (board.GetFlag("alert") ? 1 : 0);
        _ = board.GetObject("target");
        _ = board.TryGetPosition("noise", out Vector3 _);
    }
}

[BehaviorNode("Has Ammo At Least", Condition = true, Description = "Succeeds while the guard has this much ammunition.")]
public class HasAmmoAtLeast : BehaviorNode
{
    public int Count = 1;

    protected override BehaviorStatus OnTick(float deltaTime) =>
        GameObject.GetComponent<GuardActions>().Ammo >= Count ? BehaviorStatus.Success : BehaviorStatus.Failure;
}

public class AimFor : BehaviorNode
{
    public float Seconds = 0.5f;
    private float _left;

    protected override void OnStart() => _left = Seconds;

    protected override BehaviorStatus OnTick(float deltaTime)
    {
        _left -= deltaTime;
        return _left > 0 ? BehaviorStatus.Running : BehaviorStatus.Success;
    }

    protected override void OnEnd(bool aborted) { }
}

[BehaviorNode("Aim", Key = "guard.aim")]
public class RenamedAim : BehaviorNode
{
    protected override BehaviorStatus OnTick(float deltaTime) => BehaviorStatus.Success;
}

// docs/maps.md
public class MapSnippets : Script
{
    private void Snippets(GameObject level, string mapId, MapFileInfo chosen, MapFileInfo map, string id, string hash)
    {
        var (written, problems) = MapFiles.Export(Scene, "Maps/Harbour.tmap", "Harbour", "A player", "A hill by the sea.",
            group: level, keepId: mapId);
        foreach (MapFileInfo found in MapFiles.Find(MapFiles.Folder))
        {
            if (found.Ok)
                Log.Info(found.Name);
            else
                Log.Warning($"{found.File}: {found.Problems[0]}");
        }
        if (MapFiles.Mount(chosen))
            Scene.LoadAdditive(chosen.ScenePath, true);
        if (chosen.CountComponents("Tallow.SpawnPoint") == 0)
            chosen = chosen.WithProblem("It has no spawn points.");

        MapSharing.Offer(map);
        if (!MapSharing.Have(id, hash))
            MapSharing.Request(Scene, id, hash);
        if (MapSharing.State == MapDownloadState.Done) { }
        MapSharing.Reset();
    }
}

// docs/systems.md
public class Spinner : Script
{
    public Vector3 Speed = new(0, 45, 0);

    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Rotate(Speed * deltaTime);
    }
}

[Component]
public struct SpeedData
{
    [Sync] public float Speed;
}

[Component]
public struct DocCharge { public float Amount; }

[Component]
public struct DocFrozen { public int Unused; }

public class Accelerate : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        EcsEntity entity = GameObject.Entity;
        if (entity.TryGet(out SpeedData data))
        {
            data.Speed += deltaTime;
            entity.Set(data);
        }
        Scene.Query<SpeedData, DocCharge>().ForEach((EcsEntity e, ref SpeedData speed, ref DocCharge charge) =>
        {
            speed.Speed += charge.Amount * 0.1f;
        });
        int count = Scene.Query<SpeedData>().Without<DocFrozen>().Count;
    }
}

// docs/joints.md, docs/dialogue.md, docs/viewmodel.md, docs/post-processing.md
public class DocPlayer : Script { public bool ControlsEnabled = true; }

public class DocGate : Script { public void Open() { } }

public class Talker : Script
{
    public DocPlayer? Player;
    public DocGate? Gate;

    public override void Start()
    {
        Player!.ControlsEnabled = false;
        GetComponent<DialogueRunner>().Play();
    }

    public override void OnDialogueEvent(string name, float value)
    {
        if (name == "OpenGate")
            Gate?.Open();
    }

    public override void OnDialogueEnded() => Player!.ControlsEnabled = true;

    private void Snippets(GameObject weight, GameObject post, Rigidbody forearm, Rigidbody upperArm, Vector3 elbowPosition,
        Rigidbody car, Rigidbody wheel, GameObject PlayerCamera, GameObject weapon, ViewmodelPose pose, bool fired)
    {
        Joint.Connect(weight.GetComponent<Rigidbody>(), post.GetComponent<Rigidbody>(), post.Transform.Position, Vector3.Down);
        Joint.Connect(forearm, upperArm, elbowPosition, -upperArm.GameObject.Transform.Up, 70);
        Hinge? hinge = Scene.CreateHinge(car, wheel, wheel.GameObject.Transform.Position, Vector3.UnitZ, Vector3.UnitZ, Vector3.UnitX);
        hinge?.SetMotorSpeed(3, 100);
        bool debris = wheel.Debris;
        GetComponent<CompoundCollider>().AddCylinder(Vector3.Zero, 0.4f, 0.1f, Quaternion.Identity);
        wheel.RebuildBody();

        int id = Subtitles.Show("Radio", "Bravo team, move in.", 3);
        Subtitles.Caption("[distant explosion]", 2);
        Subtitles.Hide(id);

        var camera = PlayerCamera.GetComponent<Camera>();
        camera.ViewmodelLayer = Layers.Named("Viewmodel");
        camera.ViewmodelFieldOfView = 60;
        weapon.SetLayer(camera.ViewmodelLayer);
        pose.Aiming = InputActions.Held("Aim");
        if (fired) pose.Kick(1);

        SceneEnvironment env = Scene.Environment;
        env.AutoFocus = true;
        env.DepthOfField = pose.AimBlend * 0.8f;
        env.ColorFilter = new Color(1, 0.6f, 0.6f);
        env.Saturation = 0.5f;
        ScreenEffects.Brightness = 1.2f;
    }
}

// docs/sequencer.md
public class Cutscene : Script
{
    public DocPlayer? Player;
    public DocGate? Gate;

    public void Begin()
    {
        Player!.ControlsEnabled = false;
        GetComponent<SequencePlayer>().Play();
    }

    public override void OnSequenceEvent(string name, float value)
    {
        if (name == "GateOpened")
            Gate?.Open();
    }

    public override void OnSequenceFinished() => Player!.ControlsEnabled = true;
}

// docs/water.md, voxel-objects.md, quality.md, lighting.md, lod.md, jobs.md
public class DocWorldSnippets : Script
{
    private void Snippets(Vector3 point, Vector3 origin, Vector3 direction, GameObject boat, GameObject go, GameObject rock,
        bool pressedLow, bool toggle, bool highDetail, int[] targets)
    {
        Water water = Water.At(Scene, point);
        if (water.IsValid && water.Covers(point))
            Log.Info($"{water.DepthOf(point)} m under");
        if (water.IsValid && water.TryGetSurface(point, out WaterSurface surface))
            boat.Transform.Position = new Vector3(point.X, surface.Height, point.Z);

        if (Scene.RaycastHit(origin, direction, 100) is PhysicsHit hit && hit.HitObject?.TryGetComponent(out VoxelObject voxels) == true)
            voxels.Carve(hit.Point, 0.4f);

        if (pressedLow) Quality.Set(QualityLevel.Low);
        Quality.MotionBlur = toggle;
        Quality.Save();
        if (!File.Exists($"{GamePaths.PlayerData}graphics.cfg"))
            Quality.Set(Quality.Recommended);

        var lamp = go.AddComponent<Light>();
        lamp.Type = LightType.Point;
        lamp.Range = 8;
        lamp.Intensity = 4;
        lamp.CastShadows = true;
        Quality.ShadowedLights = 4;

        var group = rock.AddComponent<LODGroup>();
        group.Source = LODGroupSource.Generated;
        Quality.LodBias = highDetail ? 1.5f : 1;

        float[] scores = new float[targets.Length];
        Parallel.For(0, targets.Length, i => scores[i] = targets[i] * 2f);
    }
}

// docs/navigation.md, decals.md, foliage.md, skinned-materials.md, standalone-player.md, materials.md, fields.md
public class DocMoreSnippets : Script
{
    public List<Vector3> Waypoints = [];
    public List<string> Names = [];
    public List<GameObject> Targets = [];
    public float[] Weights = new float[3];

    private void Snippets(Vector3 destination, Vector3 point, Vector3 center, Vector3 eyes, Vector3 target, System.Random random,
        Vector3 hitPoint, Vector3 hitNormal, Vector3 position, Quaternion rotation, bool playerHasChosen, bool savedChoice,
        SoftBody soft, Vector3 aimDirection, float shotStrength)
    {
        var navigation = GetComponent<NavigationAgent>();
        navigation.SetDestination(destination, 3, 0.2f);
        if (!navigation.PathPending && (navigation.PathFailed || navigation.HasArrived))
            navigation.StopMovement();
        NavigationSurface surface = NavigationSurface.Find(Scene);
        if (surface.SamplePosition(point, 2, out Vector3 onFloor)) { }
        if (surface.RandomPoint(center, 10, random, out Vector3 goal)) navigation.SetDestination(goal, 3, 0.2f);
        if (!surface.Raycast(eyes, target, out Vector3 blocked)) { }
        surface.Rebuild(center - Vector3.One, center + Vector3.One);

        Decals.Spawn(Scene, hitPoint, hitNormal, "Textures/bullet_hole.png", 0.12f, 20, spin: Random.Shared.NextSingle() * 360);
        Decals.Spawn(Scene, position, rotation, new Vector3(2, 1, 0.5f), "Textures/skid.png", 0, new Color(1, 1, 1, 0.8f));
        Decals.Clear(Scene);
        Decals.MaxSpawned = 512;

        var grass = GetComponent<Foliage>();
        grass.Paint(point, 6);
        grass.Erase(point, 3);
        grass.Add(point);
        grass.Clear();

        var skinned = GetComponent<SkinnedMeshRenderer>();
        for (int i = 0; i < skinned.PartCount; i++)
            Log.Info(skinned.PartName(i));
        skinned.SetPartMaterial(1, "Materials/armour_damaged.tmat");
        skinned.SetPartHidden("Hat_Tricorn", true);
        skinned.SetPartColor("Coat", new Color(0.56f, 0.14f, 0.16f));
        skinned.SetPartShadowOnly("Head", true);

        string? text = Assets.ReadText("Data/levels.txt");
        byte[]? bytes = Assets.ReadBytes("Data/table.bin");
        if (Assets.Exists("Data/extra.txt")) { }
        if (playerHasChosen)
            Screen.Fullscreen = savedChoice;

        soft.AddImpulse(aimDirection * shotStrength);

        var renderer = GetComponent<MeshRenderer>();
        renderer.Material = "Materials/brass.tmat";
        renderer.SetMaterialColor("color", new Color(1, 0, 0, 1));
        renderer.SetMaterialFloat("roughness", 0.2f);
        renderer.Emissive = new Color(1, 1, 1);
        renderer.EmissiveFromColor = true;
        renderer.EmissiveIntensity = 2;

        var effect = GetComponent<ComputeEffect>();
        effect.SetFloat("speed", 3);
        effect.SetColor("ink", new Color(1, 0.3f, 0.1f, 1));
        effect.EveryFrame = false;
        effect.Step();
    }

    public void OnFullscreen(UIElement source)
    {
        Screen.Fullscreen = source.Value > 0.5f;
    }
}

// docs/soft-bodies.md
public class DocSoftSnippets : Script
{
    private void Snippets(GameObject car, GameObject rail, SoftBody jelly, Vector3[] saved, GameObject helicopter, GameObject crate,
        GameObject truck, GameObject other2, GameObject counterweight, GameObject cargo, Vector3 beamLeft, Vector3 beamRight,
        GameObject trailer, GameObject player)
    {
        var shell = car.GetComponent<SoftBody>();
        float deepest = shell.DeepestDent;
        Vector3[] dents = shell.GetDents();
        shell.SetDents(dents);
        shell.Repair();

        var curtain = rail.AddComponent<SoftBody>();
        curtain.Pins = "0-10";
        curtain.WindDrag = 2;
        curtain.Rebuild();
        foreach (Vector3 p in curtain.Positions) { }
        curtain.SetPositions(saved);
        uint[] touched = jelly.TouchingBodies();

        Rope? sling = Rope.Attach(helicopter, crate, new Vector3(0, -0.5f, 0), new Vector3(0, 0.4f, 0), 6);
        Rope? tow = Rope.Attach(truck, other2, new Vector3(0, 0.4f, -2.2f), new Vector3(0, 0.4f, 2.1f));
        if (sling is { IsTaut: true, Pull: > 5000 } held)
            held.Release();
        if (Rope.Attach(counterweight, cargo) is Rope hoist)
        {
            hoist.WrapsAround = true;
            hoist.LayAlong([counterweight.Transform.Position, beamLeft, beamRight, cargo.Transform.Position]);
        }
        Rope? other = sling?.Snap();
        tow?.AttachEnd(trailer, new Vector3(0, 0.5f, 2));
        tow?.AttachStart(player);
        tow?.GameObject.Destroy();
    }
}

// docs/baked-lighting.md
public class DocBakeSnippets : Script
{
    private void Snippets(MeshRenderer renderer, Light light)
    {
        renderer.BakedLighting = true;
        light.BakedOnly = true;
    }
}

// docs/physics-queries.md
public class DocQuerySnippets : Script
{
    private static Vector3 Spread(Vector3 aim, int i) => Vector3.Normalize(aim + new Vector3(i * 0.01f, 0, 0));

    private void Snippets(Vector3 muzzle, Vector3 aim)
    {
        foreach (PhysicsHit hit in Scene.RaycastAll(muzzle, aim, 200))
        {
            Decals.Spawn(Scene, hit.Point, hit.Normal ?? -aim, $"Textures/hole_{hit.Surface}.png", 0.1f, 30);
            if (hit.Surface == "Metal") break;
        }
        RayQuery[] pellets = new RayQuery[12];
        for (int i = 0; i < pellets.Length; i++)
            pellets[i] = new RayQuery(muzzle, Spread(aim, i), 60);
        var hits = new PhysicsHit?[pellets.Length];
        Scene.RaycastBatch(pellets, hits);
        PhysicsHit[] contacts = Scene.OverlapSphereContacts(muzzle, 1);
        GameObject.RefreshColliders();
    }
}
