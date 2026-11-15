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
    public override void OnFrame()
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
