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
