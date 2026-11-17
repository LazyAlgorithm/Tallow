using System.Numerics;

namespace Tallow;

/// <summary>A gamepad button (the same numbers as the engine's GamepadButton).</summary>
public enum GamepadButton
{
    South, East, West, North,
    Back, Guide, Start,
    LeftStick, RightStick,
    LeftShoulder, RightShoulder,
    DpadUp, DpadDown, DpadLeft, DpadRight,
    LeftTrigger, RightTrigger,
    Count
}

/// <summary>A gamepad stick axis or trigger.</summary>
public enum GamepadAxis
{
    LeftX, LeftY, RightX, RightY, LeftTrigger, RightTrigger,
    Count
}

/// <summary>Which kind of pad it is, for button names and prompts.</summary>
public enum GamepadKind
{
    Generic, Xbox, PlayStation, Nintendo
}

/// <summary>
/// Gamepads, read directly (pad 0 is the first). Gameplay that is played over the network reads controls from the
/// tick's <see cref="TickInput"/> instead; this is for menus and local effects such as <see cref="Rumble"/>.
/// </summary>
public static class Gamepad
{
    /// <summary>How many pads the engine follows.</summary>
    public const int MaxPads = 4;

    /// <summary>Whether a pad is plugged in at that number.</summary>
    public static bool IsConnected(int pad = 0) => CSharpPlatform.GamepadConnected(pad);
    /// <summary>What kind of pad it is (for showing the right button pictures).</summary>
    public static GamepadKind Kind(int pad = 0) => (GamepadKind)CSharpPlatform.GamepadKindOf(pad);
    /// <summary>The pad's name as the system reports it, or empty.</summary>
    public static string Name(int pad = 0) =>
        ActionText.Read(buffer => CSharpPlatform.GamepadNameOf(pad, buffer)) ?? "";
    /// <summary>Held down now.</summary>
    public static bool GetButton(GamepadButton button, int pad = 0) => CSharpPlatform.GamepadButtonState((int)button, pad, 0);
    /// <summary>Pressed this frame.</summary>
    public static bool GetButtonDown(GamepadButton button, int pad = 0) => CSharpPlatform.GamepadButtonState((int)button, pad, 1);
    /// <summary>Released this frame.</summary>
    public static bool GetButtonUp(GamepadButton button, int pad = 0) => CSharpPlatform.GamepadButtonState((int)button, pad, 2);
    /// <summary>A stick axis (-1 to 1) or a trigger (0 to 1).</summary>
    public static float GetAxis(GamepadAxis axis, int pad = 0) => CSharpPlatform.GamepadAxisValue((int)axis, pad);
    /// <summary>The left stick, each axis -1 to 1.</summary>
    public static Vector2 LeftStick(int pad = 0) => new(GetAxis(GamepadAxis.LeftX, pad), GetAxis(GamepadAxis.LeftY, pad));
    /// <summary>The right stick, each axis -1 to 1.</summary>
    public static Vector2 RightStick(int pad = 0) => new(GetAxis(GamepadAxis.RightX, pad), GetAxis(GamepadAxis.RightY, pad));
    /// <summary>Shakes the pad: low- and high-frequency motor strength 0 to 1, for some seconds.</summary>
    public static void Rumble(float low, float high, float seconds, int pad = 0) => CSharpPlatform.GamepadRumble(low, high, seconds, pad);
}

/// <summary>A finger on a touch screen.</summary>
public readonly record struct Finger(int Id, Vector2 Position, Vector2 Start, Vector2 Delta, float StartTime, bool Down);

/// <summary>Fingers on a touch screen (phones, tablets, touch laptops).</summary>
public static class Touch
{
    /// <summary>How many fingers are on the screen now.</summary>
    public static int Count => CSharpPlatform.TouchCount();

    /// <summary>The fingers down now (and those lifted this frame, with Down false).</summary>
    public static Finger[] Fingers
    {
        get
        {
            int count = Count;
            var fingers = new List<Finger>(count);
            Span<float> v = stackalloc float[9];
            for (int i = 0; i < count; i++)
                if (CSharpPlatform.TouchFinger(i, v))
                    fingers.Add(new Finger((int)v[0], new Vector2(v[1], v[2]), new Vector2(v[3], v[4]),
                        new Vector2(v[5], v[6]), v[7], v[8] != 0));
            return fingers.ToArray();
        }
    }
}

/// <summary>Graphics quality presets.</summary>
public enum QualityLevel
{
    Low, Medium, High, Ultra,
    /// <summary>Settings changed one by one from a preset.</summary>
    Custom
}

/// <summary>The graphics quality preset (shadows, reflections, effects...), as the game's settings menu sets it.</summary>
public static class Quality
{
    /// <summary>The preset in use, or Custom once a setting was changed by itself.</summary>
    public static QualityLevel Level => (QualityLevel)CSharpPlatform.QualityCurrent();

    /// <summary>The preset the engine suggests for this machine (phone, integrated graphics, browser).</summary>
    public static QualityLevel Recommended => (QualityLevel)CSharpPlatform.QualityRecommended();

    /// <summary>Applies a preset at once; save keeps it for the next start.</summary>
    public static void Set(QualityLevel level, bool save = true)
    {
        if (!CSharpPlatform.QualitySet((int)level, save))
            throw new ArgumentOutOfRangeException(nameof(level), "Choose Low, Medium, High or Ultra.");
    }

    // One setting at a time, as a settings menu changes them: each applies at once and makes the level Custom (unless
    // the values then match a preset). Call Save() to keep them for the next start.

    /// <summary>Wait for the screen's refresh before showing a frame (no tearing; caps the frame rate to the screen's).</summary>
    public static bool VSync { get => Flag("vsync"); set => Change("vsync", value ? "1" : "0"); }
    /// <summary>The 3D image's resolution as a fraction of the window's (0.25-1).</summary>
    public static float RenderScale { get => Number("renderScale"); set => Change("renderScale", Text(value)); }
    /// <summary>Smooths jagged edges (multisampling).</summary>
    public static bool Antialias { get => Flag("antialias"); set => Change("antialias", value ? "1" : "0"); }
    /// <summary>Whether anything casts shadows.</summary>
    public static bool Shadows { get => Flag("shadows"); set => Change("shadows", value ? "1" : "0"); }
    /// <summary>How many point and spot lights may cast shadows at once.</summary>
    public static int ShadowedLights { get => (int)Number("shadowedLights"); set => Change("shadowedLights", Text(value)); }
    /// <summary>The sun's shadow map size in pixels (256-8192).</summary>
    public static int ShadowMapSize { get => (int)Number("shadowMapSize"); set => Change("shadowMapSize", Text(value)); }
    /// <summary>Multiplies how far shadows reach (0.05-4).</summary>
    public static float ShadowDistance { get => Number("shadowDistance"); set => Change("shadowDistance", Text(value)); }
    /// <summary>Darkens creases and corners (screen-space ambient occlusion).</summary>
    public static bool AmbientOcclusion { get => Flag("ambientOcclusion"); set => Change("ambientOcclusion", value ? "1" : "0"); }
    /// <summary>Blurs what is out of the camera's focus.</summary>
    public static bool DepthOfField { get => Flag("depthOfField"); set => Change("depthOfField", value ? "1" : "0"); }
    /// <summary>Blurs what moves fast across the screen.</summary>
    public static bool MotionBlur { get => Flag("motionBlur"); set => Change("motionBlur", value ? "1" : "0"); }
    /// <summary>Multiplies the distances at which models switch to simpler LODs (0.05-4).</summary>
    public static float LodBias { get => Number("lodBias"); set => Change("lodBias", Text(value)); }
    /// <summary>Multiplies how far grass and foliage are drawn (0.05-4).</summary>
    public static float FoliageDistance { get => Number("foliageDistance"); set => Change("foliageDistance", Text(value)); }
    /// <summary>Bends skinned models on the GPU instead of the CPU.</summary>
    public static bool GpuSkinning { get => Flag("gpuSkinning"); set => Change("gpuSkinning", value ? "1" : "0"); }
    /// <summary>Mip levels dropped from textures: 0 full detail ... 3 the lowest.</summary>
    public static int TextureDetail { get => (int)Number("textureDetail"); set => Change("textureDetail", Text(value)); }
    /// <summary>Keeps textures sharp at grazing angles (anisotropic filtering).</summary>
    public static bool Anisotropic { get => Flag("anisotropic"); set => Change("anisotropic", value ? "1" : "0"); }
    /// <summary>Whether reflection probes are used (off: the sky only).</summary>
    public static bool ReflectionProbes { get => Flag("reflectionProbes"); set => Change("reflectionProbes", value ? "1" : "0"); }
    /// <summary>Reflection probe resolution in pixels (32-512).</summary>
    public static int ReflectionSize { get => (int)Number("reflectionSize"); set => Change("reflectionSize", Text(value)); }

    /// <summary>Keeps the current settings for the next start.</summary>
    public static void Save()
    {
        // Rewriting a value as it is saves everything.
        CSharpPlatform.QualitySetValue("vsync", VSync ? "1" : "0", true);
    }

    private static string Value(string name) =>
        ActionText.Read(buffer => CSharpPlatform.QualityValueText(name, buffer)) ?? "";

    private static bool Flag(string name) => Value(name) == "1";

    private static float Number(string name) =>
        float.TryParse(Value(name), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out float value) ? value : 0f;

    private static string Text(float value) => value.ToString("0.#########", System.Globalization.CultureInfo.InvariantCulture);

    private static void Change(string name, string value)
    {
        if (!CSharpPlatform.QualitySetValue(name, value, false))
            throw new InvalidOperationException($"{name} is not a quality setting.");
    }
}

/// <summary>
/// Achievements and stats: on Steam when the game runs there, otherwise kept locally. Ids are those in the
/// project's achievement definitions.
/// </summary>
public static class Achievements
{
    /// <summary>
    /// Unlocks one; false when it already was (or Steam refused it). An id missing from the project's list still
    /// unlocks locally, with a warning.
    /// </summary>
    public static bool Unlock(string id) => CSharpPlatform.AchievementUnlock(id ?? "");
    /// <summary>Whether the achievement is unlocked.</summary>
    public static bool IsUnlocked(string id) => CSharpPlatform.AchievementUnlocked(id ?? "");
    /// <summary>Shows progress towards one ("3 of 10").</summary>
    public static void SetProgress(string id, int current, int max) => CSharpPlatform.AchievementProgress(id ?? "", current, max);
    /// <summary>Locks one again (for testing).</summary>
    public static void Clear(string id)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        CSharpPlatform.AchievementClear(id);
    }
    /// <summary>Locks every achievement again (for testing).</summary>
    public static void ClearAll() => CSharpPlatform.AchievementClear("");
    /// <summary>A stat (kills, distance...); localOnly keeps it off Steam.</summary>
    public static int GetStat(string name, bool localOnly = false) => CSharpPlatform.StatGet(name ?? "", localOnly);
    /// <summary>Sets a stat; localOnly keeps it off Steam.</summary>
    public static void SetStat(string name, int value, bool localOnly = false) => CSharpPlatform.StatSet(name ?? "", value, localOnly);
    /// <summary>Adds to a stat; its new value.</summary>
    public static int AddStat(string name, int amount = 1, bool localOnly = false) => CSharpPlatform.StatAdd(name ?? "", amount, localOnly);
}

/// <summary>Subtitles and sound captions drawn over the game (Dialogue Runners and Audio Sources can add them too).</summary>
public static class Subtitles
{
    /// <summary>Shows a line; seconds 0 works it out from its length. Its id, for <see cref="Hide"/>.</summary>
    public static int Show(string speaker, string text, float seconds = 0) =>
        Show(speaker, text, seconds, new Color(1, 0.85f, 0.45f));

    /// <summary>Shows a line with the speaker's name in a colour of its own.</summary>
    public static int Show(string speaker, string text, float seconds, Color speakerColor) =>
        CSharpPlatform.SubtitleShow(speaker ?? "", text ?? "", seconds, new Vector4(speakerColor.R, speakerColor.G, speakerColor.B, speakerColor.A));

    /// <summary>A sound caption, such as "[door creaks]".</summary>
    public static int Caption(string text, float seconds = 2) => CSharpPlatform.SubtitleCaption(text ?? "", seconds);
    /// <summary>Hides a line or caption by the id Show or Caption gave.</summary>
    public static void Hide(int id) => CSharpPlatform.SubtitleHide(id);
    /// <summary>Whether that line or caption is still on screen.</summary>
    public static bool IsShowing(int id) => CSharpPlatform.SubtitleShowing(id);
    /// <summary>Hides every line and caption.</summary>
    public static void Clear() => CSharpPlatform.SubtitlesClear();
}

/// <summary>The numbers dialogue conditions read and Set nodes write ("gold", "metGuard"; true is 1).</summary>
public static class DialogueVariables
{
    /// <summary>A variable's value (0 when it was never set).</summary>
    public static float Get(string name) => CSharpPlatform.DialogueVariable(name ?? "");
    /// <summary>Sets a variable.</summary>
    public static void Set(string name, float value)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        CSharpPlatform.SetDialogueVariable(name, value);
    }
    /// <summary>Sets a variable to 1 (true) or 0 (false).</summary>
    public static void Set(string name, bool value) => Set(name, value ? 1 : 0);
    /// <summary>Adds to a variable (subtracts with a negative amount).</summary>
    public static void Add(string name, float amount) => Set(name, Get(name) + amount);
    /// <summary>Whether a dialogue condition holds now ("gold &gt;= 10 &amp;&amp; metGuard").</summary>
    public static bool Evaluate(string condition) => CSharpPlatform.DialogueCondition(condition ?? "");
    /// <summary>Forgets every variable.</summary>
    public static void Clear() => CSharpPlatform.DialogueVariablesClear();
}

/// <summary>
/// Many short-lived marks pressed onto surfaces (bullet holes, footprints, scorch marks). For a lasting mark that
/// moves with an object, add a <see cref="Decal"/> component instead.
/// </summary>
public static class Decals
{
    /// <summary>
    /// A decal at a point on a surface facing along its normal (a ray hit's point and normal): texture path, size in
    /// metres, lifetime in seconds (0: until newer ones push it out), tint and spin in degrees.
    /// </summary>
    public static void Spawn(Scene scene, Vector3 position, Vector3 normal, string texture, float size,
        float lifetime = 0, Color? color = null, float spin = 0)
    {
        ArgumentException.ThrowIfNullOrEmpty(texture);
        Color c = color ?? new Color(1, 1, 1);
        CSharpPlatform.DecalSpawn(scene.SessionId, position, normal, texture, size, lifetime, new Vector4(c.R, c.G, c.B, c.A), spin);
    }

    /// <summary>A decal box of your own: any size and turn, pressed along its Z axis; surfaces turned more than
    /// angleLimit degrees away from it are left alone.</summary>
    public static void Spawn(Scene scene, Vector3 position, Quaternion rotation, Vector3 size, string texture,
        float lifetime = 0, Color? color = null, float angleLimit = 70)
    {
        ArgumentException.ThrowIfNullOrEmpty(texture);
        Color c = color ?? new Color(1, 1, 1);
        CSharpPlatform.DecalSpawnBox(scene.SessionId, position, new Vector4(rotation.X, rotation.Y, rotation.Z, rotation.W), size,
            texture, lifetime, new Vector4(c.R, c.G, c.B, c.A), angleLimit);
    }

    /// <summary>Removes every spawned decal in the scene.</summary>
    public static void Clear(Scene scene) => CSharpPlatform.DecalsClear(scene.SessionId);

    /// <summary>How many spawned decals a scene keeps; the oldest makes way for new ones (256 by default).</summary>
    public static int MaxSpawned
    {
        get => CSharpPlatform.DecalsMax();
        set => CSharpPlatform.SetDecalsMax(value);
    }
}

/// <summary>The wind (Wind Zones and the scene's own), for things that drift: smoke, flags, sails, leaves.</summary>
public static class Wind
{
    /// <summary>The wind's velocity at a point, metres a second.</summary>
    public static Vector3 At(Scene scene, Vector3 position) => CSharpPlatform.WindAt(scene.SessionId, position);
    /// <summary>How gusty it is now, 0 to 1.</summary>
    public static float Gusts(Scene scene) => CSharpPlatform.WindGusts(scene.SessionId);
}

/// <summary>A save or load on its way (it may finish later, for a save kept on a server).</summary>
public readonly record struct SaveHandle(int Id)
{
    private int Progress => CSharpPlatform.SaveProgress(Id);
    /// <summary>Whether it has finished, well or not.</summary>
    public bool Done => (Progress & 1) != 0;
    /// <summary>Whether it finished and worked.</summary>
    public bool Succeeded => (Progress & 2) != 0;
    /// <summary>Loading: whether the slot held a save.</summary>
    public bool Found => (Progress & 4) != 0;
    /// <summary>Why it did not work (empty if it did).</summary>
    public string Error
    {
        get
        {
            int id = Id;
            return ActionText.Read(buffer => CSharpPlatform.SaveError(id, buffer)) ?? "";
        }
    }
}

/// <summary>
/// Save games. Saving keeps every <see cref="SavedAttribute">[Saved]</see> field and the objects the scene's save
/// settings name; loading puts them back (then <see cref="Script.OnLoaded"/> runs). Slots are names ("default",
/// "slot2", "autosave").
/// </summary>
public static class SaveSystem
{
    /// <summary>Starts saving to a slot; watch the handle for when it is done.</summary>
    public static SaveHandle Save(string slot = "default") => new(CSharpPlatform.SaveStart(slot ?? "", false));
    /// <summary>Starts loading a slot; watch the handle for when it is done (Found says whether there was a save).</summary>
    public static SaveHandle Load(string slot = "default") => new(CSharpPlatform.SaveStart(slot ?? "", true));
    /// <summary>Whether the slot holds a save.</summary>
    public static bool Exists(string slot = "default") => CSharpPlatform.SaveExists(slot ?? "");
    /// <summary>Deletes the slot's save.</summary>
    public static void Delete(string slot = "default") => CSharpPlatform.SaveDelete(slot ?? "");
    /// <summary>The slots that hold a save.</summary>
    public static string[] Slots =>
        (ActionText.Read(CSharpPlatform.SaveSlots) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Voice chat in a network session (push-to-talk or open mic, set up on the scene's Voice Chat settings).</summary>
public static class VoiceChat
{
    /// <summary>Whether this machine has a microphone voice chat can use.</summary>
    public static bool HasMicrophone => (CSharpPlatform.VoiceState() & 1) != 0;
    /// <summary>Whether the microphone is open (recording) now.</summary>
    public static bool MicrophoneOpen => (CSharpPlatform.VoiceState() & 2) != 0;
    /// <summary>Whether this machine is sending its voice now.</summary>
    public static bool IsTransmitting => (CSharpPlatform.VoiceState() & 4) != 0;
    /// <summary>How loud the microphone is, 0 to 1 (for a level meter).</summary>
    public static float MicrophoneLevel => CSharpPlatform.VoiceMicrophoneLevel();
    /// <summary>Talks as if the push-to-talk key were held (an open-mic toggle, a talk button on a touch screen).</summary>
    public static bool Talk
    {
        get => CSharpPlatform.VoiceTalk();
        set => CSharpPlatform.VoiceSetTalk(value);
    }
    /// <summary>Whether that player's voice is being heard now.</summary>
    public static bool IsSpeaking(int clientId) => CSharpPlatform.VoiceSpeaking(clientId);
    /// <summary>Stops (or with false, starts again) hearing that player on this machine.</summary>
    public static void Mute(int clientId, bool muted = true) => CSharpPlatform.VoiceMute(clientId, muted);
    /// <summary>Whether that player is muted on this machine.</summary>
    public static bool IsMuted(int clientId) => CSharpPlatform.VoiceMuted(clientId);
    /// <summary>How loud one player is heard here, 0 to 4 (1 as they are).</summary>
    public static void SetPlayerVolume(int clientId, float volume) => CSharpPlatform.VoiceSetVolume(clientId, volume);
    /// <summary>How loud that player is heard here, 0 to 4.</summary>
    public static float GetPlayerVolume(int clientId) => CSharpPlatform.VoiceVolume(clientId);

    /// <summary>The master switch. Off, the microphone is never opened and nothing is sent or played.</summary>
    public static bool Enabled
    {
        get => CSharpPlatform.VoiceSetting(0) != 0;
        set => CSharpPlatform.SetVoiceSetting(0, value ? 1 : 0);
    }
    /// <summary>On: heard only while the push-to-talk key (or <see cref="Talk"/>) is held. Off: heard whenever louder than <see cref="Activation"/>.</summary>
    public static bool PushToTalk
    {
        get => CSharpPlatform.VoiceSetting(1) != 0;
        set => CSharpPlatform.SetVoiceSetting(1, value ? 1 : 0);
    }
    /// <summary>The key held to talk when PushToTalk is on.</summary>
    public static KeyCode PushToTalkKey
    {
        get => (KeyCode)CSharpPlatform.VoiceSetting(2);
        set => CSharpPlatform.SetVoiceSetting(2, (int)value);
    }
    /// <summary>An input action held to talk as well ("Talk" unless changed: V and d-pad down). Empty for none.</summary>
    public static string PushToTalkAction
    {
        get => ActionText.Read(CSharpPlatform.VoicePushToTalkAction) ?? "";
        set => CSharpPlatform.SetVoicePushToTalkAction(value ?? "");
    }
    /// <summary>How loud the microphone must be before an open microphone sends, 0 to 1 (compare with MicrophoneLevel).</summary>
    public static float Activation
    {
        get => CSharpPlatform.VoiceSetting(3);
        set => CSharpPlatform.SetVoiceSetting(3, value);
    }
    /// <summary>Seconds an open microphone keeps sending after you fall quiet.</summary>
    public static float ReleaseTime
    {
        get => CSharpPlatform.VoiceSetting(4);
        set => CSharpPlatform.SetVoiceSetting(4, value);
    }
    /// <summary>Gain on your microphone before it is sent.</summary>
    public static float MicrophoneVolume
    {
        get => CSharpPlatform.VoiceSetting(5);
        set => CSharpPlatform.SetVoiceSetting(5, value);
    }
    /// <summary>Loudness of other players' voices (the Voice mixer group applies as well).</summary>
    public static float Volume
    {
        get => CSharpPlatform.VoiceSetting(6);
        set => CSharpPlatform.SetVoiceSetting(6, value);
    }
    /// <summary>Evens out quiet and loud microphones (on by default).</summary>
    public static bool AutoLevel
    {
        get => CSharpPlatform.VoiceSetting(7) != 0;
        set => CSharpPlatform.SetVoiceSetting(7, value ? 1 : 0);
    }
    /// <summary>Stops your microphone being sent without turning voice chat off.</summary>
    public static bool Muted
    {
        get => CSharpPlatform.VoiceSetting(8) != 0;
        set => CSharpPlatform.SetVoiceSetting(8, value ? 1 : 0);
    }
    /// <summary>Stops other players' voices being played.</summary>
    public static bool Deafened
    {
        get => CSharpPlatform.VoiceSetting(9) != 0;
        set => CSharpPlatform.SetVoiceSetting(9, value ? 1 : 0);
    }
    /// <summary>On: a voice comes from the speaker's character and fades with distance. Off: everyone hears everyone, like a radio. Decided by the server.</summary>
    public static bool Proximity
    {
        get => CSharpPlatform.VoiceSetting(10) != 0;
        set => CSharpPlatform.SetVoiceSetting(10, value ? 1 : 0);
    }
    /// <summary>With Proximity on: full volume within this distance.</summary>
    public static float MinDistance
    {
        get => CSharpPlatform.VoiceSetting(11);
        set => CSharpPlatform.SetVoiceSetting(11, value);
    }
    /// <summary>With Proximity on: silent beyond this distance.</summary>
    public static float MaxDistance
    {
        get => CSharpPlatform.VoiceSetting(12);
        set => CSharpPlatform.SetVoiceSetting(12, value);
    }
    /// <summary>Players hear only their own team. Decided by the server.</summary>
    public static bool TeamOnly
    {
        get => CSharpPlatform.VoiceSetting(13) != 0;
        set => CSharpPlatform.SetVoiceSetting(13, value ? 1 : 0);
    }
    /// <summary>Plays your own voice back to you, for a microphone test; works without a session.</summary>
    public static bool Loopback
    {
        get => CSharpPlatform.VoiceSetting(14) != 0;
        set => CSharpPlatform.SetVoiceSetting(14, value ? 1 : 0);
    }
    /// <summary>Bits per second of speech (24000 by default; 12000 to 64000 are sensible).</summary>
    public static int Bitrate
    {
        get => (int)CSharpPlatform.VoiceSetting(15);
        set => CSharpPlatform.SetVoiceSetting(15, (float)value);
    }

    private static Action<int, bool>? sOnSpeakingChanged;

    /// <summary>Raised once a frame (after LateUpdate) for each player who started or stopped being heard on this
    /// machine: the client id, and whether they are speaking now.</summary>
    public static event Action<int, bool> OnSpeakingChanged
    {
        add
        {
            if (sOnSpeakingChanged == null)
                while (CSharpPlatform.VoiceTakeSpeakingChange() >= 0) { }
            // Hooked again each time: a game that stopped dropped the hook (GameThread.Stop).
            GameThread.EachFrame -= RaiseSpeaking;
            GameThread.EachFrame += RaiseSpeaking;
            sOnSpeakingChanged += value;
        }
        remove
        {
            sOnSpeakingChanged -= value;
            if (sOnSpeakingChanged == null)
                GameThread.EachFrame -= RaiseSpeaking;
        }
    }

    internal static void ClearHandlers()
    {
        GameThread.EachFrame -= RaiseSpeaking;
        sOnSpeakingChanged = null;
    }

    private static void RaiseSpeaking()
    {
        for (long change; (change = CSharpPlatform.VoiceTakeSpeakingChange()) >= 0;)
            sOnSpeakingChanged?.Invoke((int)(uint)change, (change >> 32) != 0);
    }
}

/// <summary>
/// The game's own files by asset path ("Data/levels.json"): in the project while making it, packed inside a built
/// game. Read-only; use <see cref="SaveSystem"/> or a <c>[Saved]</c> field for what the player changes.
/// </summary>
public static class Assets
{
    /// <summary>Whether the game has a file at that asset path.</summary>
    public static bool Exists(string path) => CSharpPlatform.AssetExists(path ?? "");

    /// <summary>Makes a folder's files loadable by their path inside it, ahead of the game's own: a Mods folder
    /// beside the game, or a downloaded level pack. A file there with the same path as one of the game's replaces
    /// it.</summary>
    public static void AddSearchPath(string folder) => CSharpPlatform.AssetsAddSearchPath(folder ?? "");

    /// <summary>The file's bytes, or null when there is no such file.</summary>
    public static byte[]? ReadBytes(string path)
    {
        int length = CSharpPlatform.AssetRead(path ?? "", Span<byte>.Empty);
        if (length < 0)
            return null;
        var data = new byte[length];
        length = CSharpPlatform.AssetRead(path!, data);
        return length < 0 ? null : data[..Math.Min(length, data.Length)];
    }

    /// <summary>The file as UTF-8 text, or null when there is no such file.</summary>
    public static string? ReadText(string path) =>
        ReadBytes(path) is { } data ? System.Text.Encoding.UTF8.GetString(data) : null;
}
