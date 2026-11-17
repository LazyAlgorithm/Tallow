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

    public static bool IsConnected(int pad = 0) => CSharpPlatform.GamepadConnected(pad);
    public static GamepadKind Kind(int pad = 0) => (GamepadKind)CSharpPlatform.GamepadKindOf(pad);
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
    public static Vector2 LeftStick(int pad = 0) => new(GetAxis(GamepadAxis.LeftX, pad), GetAxis(GamepadAxis.LeftY, pad));
    public static Vector2 RightStick(int pad = 0) => new(GetAxis(GamepadAxis.RightX, pad), GetAxis(GamepadAxis.RightY, pad));
    /// <summary>Shakes the pad: low- and high-frequency motor strength 0 to 1, for some seconds.</summary>
    public static void Rumble(float low, float high, float seconds, int pad = 0) => CSharpPlatform.GamepadRumble(low, high, seconds, pad);
}

/// <summary>A finger on a touch screen.</summary>
public readonly record struct Finger(int Id, Vector2 Position, Vector2 Start, Vector2 Delta, float StartTime, bool Down);

/// <summary>Fingers on a touch screen (phones, tablets, touch laptops).</summary>
public static class Touch
{
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
    public static bool Antialias { get => Flag("antialias"); set => Change("antialias", value ? "1" : "0"); }
    public static bool Shadows { get => Flag("shadows"); set => Change("shadows", value ? "1" : "0"); }
    /// <summary>How many point and spot lights may cast shadows at once.</summary>
    public static int ShadowedLights { get => (int)Number("shadowedLights"); set => Change("shadowedLights", Text(value)); }
    /// <summary>The sun's shadow map size in pixels (256-8192).</summary>
    public static int ShadowMapSize { get => (int)Number("shadowMapSize"); set => Change("shadowMapSize", Text(value)); }
    /// <summary>Multiplies how far shadows reach (0.05-4).</summary>
    public static float ShadowDistance { get => Number("shadowDistance"); set => Change("shadowDistance", Text(value)); }
    public static bool AmbientOcclusion { get => Flag("ambientOcclusion"); set => Change("ambientOcclusion", value ? "1" : "0"); }
    public static bool DepthOfField { get => Flag("depthOfField"); set => Change("depthOfField", value ? "1" : "0"); }
    public static bool MotionBlur { get => Flag("motionBlur"); set => Change("motionBlur", value ? "1" : "0"); }
    /// <summary>Multiplies the distances at which models switch to simpler LODs (0.05-4).</summary>
    public static float LodBias { get => Number("lodBias"); set => Change("lodBias", Text(value)); }
    /// <summary>Multiplies how far grass and foliage are drawn (0.05-4).</summary>
    public static float FoliageDistance { get => Number("foliageDistance"); set => Change("foliageDistance", Text(value)); }
    public static bool GpuSkinning { get => Flag("gpuSkinning"); set => Change("gpuSkinning", value ? "1" : "0"); }
    /// <summary>Mip levels dropped from textures: 0 full detail ... 3 the lowest.</summary>
    public static int TextureDetail { get => (int)Number("textureDetail"); set => Change("textureDetail", Text(value)); }
    public static bool Anisotropic { get => Flag("anisotropic"); set => Change("anisotropic", value ? "1" : "0"); }
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
    public static void Hide(int id) => CSharpPlatform.SubtitleHide(id);
    public static bool IsShowing(int id) => CSharpPlatform.SubtitleShowing(id);
    public static void Clear() => CSharpPlatform.SubtitlesClear();
}

/// <summary>The numbers dialogue conditions read and Set nodes write ("gold", "metGuard"; true is 1).</summary>
public static class DialogueVariables
{
    public static float Get(string name) => CSharpPlatform.DialogueVariable(name ?? "");
    public static void Set(string name, float value)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        CSharpPlatform.SetDialogueVariable(name, value);
    }
    public static void Set(string name, bool value) => Set(name, value ? 1 : 0);
    public static void Add(string name, float amount) => Set(name, Get(name) + amount);
    /// <summary>Whether a dialogue condition holds now ("gold &gt;= 10 &amp;&amp; metGuard").</summary>
    public static bool Evaluate(string condition) => CSharpPlatform.DialogueCondition(condition ?? "");
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

    /// <summary>Removes every spawned decal in the scene.</summary>
    public static void Clear(Scene scene) => CSharpPlatform.DecalsClear(scene.SessionId);
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
    public static SaveHandle Save(string slot = "default") => new(CSharpPlatform.SaveStart(slot ?? "", false));
    public static SaveHandle Load(string slot = "default") => new(CSharpPlatform.SaveStart(slot ?? "", true));
    public static bool Exists(string slot = "default") => CSharpPlatform.SaveExists(slot ?? "");
    public static void Delete(string slot = "default") => CSharpPlatform.SaveDelete(slot ?? "");
    /// <summary>The slots that hold a save.</summary>
    public static string[] Slots =>
        (ActionText.Read(CSharpPlatform.SaveSlots) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Voice chat in a network session (push-to-talk or open mic, set up on the scene's Voice Chat settings).</summary>
public static class VoiceChat
{
    public static bool HasMicrophone => (CSharpPlatform.VoiceState() & 1) != 0;
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
    public static bool IsSpeaking(int clientId) => CSharpPlatform.VoiceSpeaking(clientId);
    public static void Mute(int clientId, bool muted = true) => CSharpPlatform.VoiceMute(clientId, muted);
    public static bool IsMuted(int clientId) => CSharpPlatform.VoiceMuted(clientId);
    /// <summary>How loud one player is heard here, 0 to 2 (1 as they are).</summary>
    public static void SetPlayerVolume(int clientId, float volume) => CSharpPlatform.VoiceSetVolume(clientId, volume);
    public static float GetPlayerVolume(int clientId) => CSharpPlatform.VoiceVolume(clientId);
}

/// <summary>
/// The game's own files by asset path ("Data/levels.json"): in the project while making it, packed inside a built
/// game. Read-only; use <see cref="SaveSystem"/> or a <c>[Saved]</c> field for what the player changes.
/// </summary>
public static class Assets
{
    public static bool Exists(string path) => CSharpPlatform.AssetExists(path ?? "");

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
