using System.Numerics;
using System.Text;

namespace Tallow;

/// <summary>A line from a point in a direction (a camera's ray through a screen point).</summary>
public readonly record struct Ray(Vector3 Origin, Vector3 Direction)
{
    /// <summary>The point distance along the ray.</summary>
    public Vector3 GetPoint(float distance) => Origin + Direction * distance;
}

/// <summary>The size the game draws at.</summary>
public static class Screen
{
    /// <summary>Width in pixels (0 in a headless run).</summary>
    public static float Width => Size.X;
    /// <summary>Height in pixels (0 in a headless run).</summary>
    public static float Height => Size.Y;

    /// <summary>Whether the window fills the screen (borderless, at the desktop's resolution); set it to switch.</summary>
    public static bool Fullscreen
    {
        get => CSharpPlatform.WindowFullscreen();
        set => CSharpPlatform.SetWindowFullscreen(value);
    }

    /// <summary>Width and height in pixels.</summary>
    public static Vector2 Size
    {
        get
        {
            Span<float> size = stackalloc float[2];
            CSharpComponentActions.ScreenSize(size);
            return new Vector2(size[0], size[1]);
        }
    }
}

internal static class ActionText
{
    /// <summary>Reads text a native call copies into a buffer (it returns the full length; -1 for none).</summary>
    public static string? Read(Func<Span<byte>, int> copy)
    {
        Span<byte> buffer = stackalloc byte[256];
        int length = copy(buffer);
        if (length < 0)
            return null;
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, copy(buffer));
        }
        return Encoding.UTF8.GetString(buffer[..length]);
    }

    public static InvalidOperationException Missing(GameObject gameObject, string component) =>
        new($"{gameObject} has no {component}.");
}

public readonly partial record struct ParticleSystem
{
    /// <summary>Starts emitting (again, from the start).</summary>
    public void Play()
    {
        if (!CSharpComponentActions.ParticlePlay(GameObject.SceneId, GameObject.Id))
            throw ActionText.Missing(GameObject, "Particle System");
    }
}

public readonly partial record struct SequencePlayer
{
    private bool Control(int action, float time = 0)
    {
        if (!IsValid)
            throw ActionText.Missing(GameObject, "Sequence Player");
        return CSharpComponentActions.SequenceControl(GameObject.SceneId, GameObject.Id, action, time);
    }

    /// <summary>Plays the sequence from the start; false when it could not start (no sequence asset).</summary>
    public bool Play() => Control(0);
    /// <summary>Holds it where it is.</summary>
    public void Pause() => Control(1);
    /// <summary>Goes on after a Pause.</summary>
    public void Resume() => Control(2);
    /// <summary>Ends it where it is: its sounds and subtitles go and the camera goes back (Skip applies the end instead).</summary>
    public void Stop() => Control(3);
    /// <summary>Jumps to the end, applying what the sequence leaves behind.</summary>
    public void Skip() => Control(4);
    /// <summary>Moves to a time in seconds.</summary>
    public void Seek(float time) => Control(5, time);

    /// <summary>Whether it is playing (or paused partway).</summary>
    public bool IsPlaying => CSharpComponentActions.SequenceTime(GameObject.SceneId, GameObject.Id) >= 0;

    /// <summary>The time in seconds since it started, 0 when it is not playing.</summary>
    public float Time => Math.Max(CSharpComponentActions.SequenceTime(GameObject.SceneId, GameObject.Id), 0);
}

/// <summary>What a Dialogue Runner is showing.</summary>
public enum DialogueView { None, Line, Choices }

public readonly partial record struct DialogueRunner
{
    /// <summary>Starts the conversation (at a node when given); false when it could not start.</summary>
    public bool Play(string? node = null)
    {
        if (!IsValid)
            throw ActionText.Missing(GameObject, "Dialogue Runner");
        return CSharpComponentActions.DialoguePlay(GameObject.SceneId, GameObject.Id, node ?? "");
    }

    private void Control(int action, int index = 0)
    {
        if (!CSharpComponentActions.DialogueControl(GameObject.SceneId, GameObject.Id, action, index))
            throw ActionText.Missing(GameObject, "Dialogue Runner");
    }

    /// <summary>Goes on from the line shown.</summary>
    public void Advance() => Control(0);
    /// <summary>Picks one of the <see cref="Choices"/>.</summary>
    public void Choose(int index) => Control(1, index);
    /// <summary>Ends the conversation.</summary>
    public void Stop() => Control(2);

    private int State => CSharpComponentActions.DialogueState(GameObject.SceneId, GameObject.Id);

    /// <summary>Whether a conversation is going on.</summary>
    public bool IsPlaying => State > 0;

    /// <summary>Whether a line or choices are shown.</summary>
    public DialogueView View => (State & 15) switch { 1 => DialogueView.Line, 2 => DialogueView.Choices, _ => DialogueView.None };

    /// <summary>The line shown, or null.</summary>
    public string? Line => Text(0, 0);

    /// <summary>The name of the line's speaker ("" for a narrator), or null with no line.</summary>
    public string? SpeakerName => Text(1, 0);

    /// <summary>The line's speaker id, or null with no line.</summary>
    public string? SpeakerId => Text(3, 0);

    /// <summary>The answers to choose from (empty unless <see cref="View"/> is Choices).</summary>
    public IReadOnlyList<string> Choices
    {
        get
        {
            int state = State;
            int count = (state & 15) == 2 ? state >> 4 : 0;
            var choices = new string[count];
            for (int i = 0; i < count; i++)
                choices[i] = Text(2, i) ?? "";
            return choices;
        }
    }

    private string? Text(int which, int index)
    {
        ulong scene = GameObject.SceneId, id = GameObject.Id;
        return ActionText.Read(buffer => CSharpComponentActions.DialogueText(scene, id, which, index, buffer));
    }
}

public readonly partial record struct LineRenderer
{
    /// <summary>The line's points (when it draws its own points rather than its children).</summary>
    public Vector3[] GetPositions()
    {
        int count = CSharpComponentActions.LineGetPositions(GameObject.SceneId, GameObject.Id, Span<float>.Empty);
        if (count < 0)
            throw ActionText.Missing(GameObject, "Line Renderer");
        var values = new float[count * 3];
        CSharpComponentActions.LineGetPositions(GameObject.SceneId, GameObject.Id, values);
        var points = new Vector3[count];
        for (int i = 0; i < count; i++)
            points[i] = new Vector3(values[i * 3], values[i * 3 + 1], values[i * 3 + 2]);
        return points;
    }

    /// <summary>Replaces the line's points.</summary>
    public void SetPositions(ReadOnlySpan<Vector3> points)
    {
        var values = new float[points.Length * 3];
        for (int i = 0; i < points.Length; i++)
        {
            values[i * 3] = points[i].X;
            values[i * 3 + 1] = points[i].Y;
            values[i * 3 + 2] = points[i].Z;
        }
        if (!CSharpComponentActions.LineSetPositions(GameObject.SceneId, GameObject.Id, values))
            throw ActionText.Missing(GameObject, "Line Renderer");
    }

    /// <summary>Removes every point.</summary>
    public void ClearPositions() => SetPositions(ReadOnlySpan<Vector3>.Empty);

    /// <summary>How many points the line has. Setting it grows the list (new points at the origin) or shrinks it.</summary>
    public int PositionCount
    {
        get => Math.Max(CSharpComponentActions.LineGetPositions(GameObject.SceneId, GameObject.Id, Span<float>.Empty), 0);
        set
        {
            ArgumentOutOfRangeException.ThrowIfNegative(value);
            Vector3[] points = GetPositions();
            Array.Resize(ref points, value);
            SetPositions(points);
        }
    }

    /// <summary>One point, or zero for one that is not there.</summary>
    public Vector3 GetPosition(int index)
    {
        Vector3[] points = GetPositions();
        return index >= 0 && index < points.Length ? points[index] : Vector3.Zero;
    }

    /// <summary>Moves one point (one past the end adds it).</summary>
    public void SetPosition(int index, Vector3 position)
    {
        Vector3[] points = GetPositions();
        if (index == points.Length)
            Array.Resize(ref points, index + 1);
        else if ((uint)index >= (uint)points.Length)
            throw new ArgumentOutOfRangeException(nameof(index));
        points[index] = position;
        SetPositions(points);
    }

    /// <summary>Adds a point at the end of the line.</summary>
    public void AddPosition(Vector3 position) => SetPosition(PositionCount, position);

    /// <summary>The whole line's length in metres (in the world with Use World Space, otherwise in this object's
    /// space), counting the closing side of a loop.</summary>
    public float Length
    {
        get
        {
            Vector3[] points = GetPositions();
            float total = 0;
            for (int i = 1; i < points.Length; i++)
                total += Vector3.Distance(points[i], points[i - 1]);
            if (Loop && points.Length > 2)
                total += Vector3.Distance(points[0], points[^1]);
            return total;
        }
    }
}

public readonly partial record struct TrailRenderer
{
    /// <summary>Forgets the trail drawn so far (after a teleport).</summary>
    public void Clear()
    {
        if (!CSharpComponentActions.TrailClear(GameObject.SceneId, GameObject.Id))
            throw ActionText.Missing(GameObject, "Trail Renderer");
    }
}

public readonly partial record struct ViewmodelPose
{
    /// <summary>Kicks the arms and weapon back as a shot does (1 is one shot's worth); it settles by itself.</summary>
    public void Kick(float amount = 1)
    {
        if (!CSharpComponentActions.ViewmodelKick(GameObject.SceneId, GameObject.Id, amount))
            throw ActionText.Missing(GameObject, "Viewmodel Pose");
    }

    /// <summary>How far into aiming it is, from 0 at the hip to 1 down the sights (eased): for zooming the camera
    /// or blurring the world with the aim.</summary>
    public float AimBlend
    {
        get
        {
            float blend = CSharpComponentActions.ViewmodelAimBlend(GameObject.SceneId, GameObject.Id);
            return blend >= 0 ? blend : throw ActionText.Missing(GameObject, "Viewmodel Pose");
        }
    }
}

public readonly partial record struct SceneLoader
{
    /// <summary>Starts loading its scene in the background.</summary>
    public void Begin()
    {
        if (!CSharpComponentActions.SceneLoaderControl(GameObject.SceneId, GameObject.Id, 0))
            throw ActionText.Missing(GameObject, "Scene Loader");
    }

    /// <summary>Switches to the loaded scene.</summary>
    public void Activate()
    {
        if (!CSharpComponentActions.SceneLoaderControl(GameObject.SceneId, GameObject.Id, 1))
            throw ActionText.Missing(GameObject, "Scene Loader");
    }
}

public readonly partial record struct BehaviorTreeRunner
{
    /// <summary>Sends an event the tree's Wait For Event nodes can take.</summary>
    public void SendEvent(string name)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        if (!CSharpComponentActions.BehaviorTreeEvent(GameObject.SceneId, GameObject.Id, name))
            throw ActionText.Missing(GameObject, "Behavior Tree Runner");
    }

    /// <summary>Loads the tree again from its file.</summary>
    public void Reload()
    {
        if (!CSharpComponentActions.BehaviorTreeEvent(GameObject.SceneId, GameObject.Id, ""))
            throw ActionText.Missing(GameObject, "Behavior Tree Runner");
    }
}

/// <summary>The water's surface at a point.</summary>
public readonly record struct WaterSurface(float Height, Vector3 Normal, Vector3 Velocity);

public readonly partial record struct Water
{
    /// <summary>The surface over a point; false when the point is outside this water.</summary>
    public bool TryGetSurface(Vector3 point, out WaterSurface surface)
    {
        Span<float> values = stackalloc float[7];
        if (CSharpComponentActions.WaterSurface(GameObject.SceneId, GameObject.Id, point, values))
        {
            surface = new WaterSurface(values[0], new Vector3(values[1], values[2], values[3]),
                new Vector3(values[4], values[5], values[6]));
            return true;
        }
        surface = default;
        return false;
    }

    /// <summary>Whether a point's X and Z are over this water (endless water is everywhere).</summary>
    public bool Covers(Vector3 point) => TryGetSurface(point, out _);

    /// <summary>The surface's height over a point (the still level where the point is not over this water).</summary>
    public float HeightAt(Vector3 point)
    {
        float height = CSharpComponentActions.WaterHeight(GameObject.SceneId, GameObject.Id, point);
        return float.IsNaN(height) ? throw ActionText.Missing(GameObject, "Water") : height;
    }

    /// <summary>How far below the surface a point is (negative above it); float.MinValue when not over this water.</summary>
    public float DepthOf(Vector3 point) => TryGetSurface(point, out WaterSurface surface) ? surface.Height - point.Y : float.MinValue;

    /// <summary>Whether an object's Rigidbody (or soft body) was in this water at the last physics step.</summary>
    public bool IsFloating(GameObject body) =>
        CSharpComponentActions.WaterFloating(GameObject.SceneId, GameObject.Id, body.Id) > 0;

    /// <summary>Whether a Rigidbody was in this water at the last physics step.</summary>
    public bool IsFloating(Rigidbody body) => IsFloating(body.GameObject);

    /// <summary>The water whose area holds a point (not valid when none).</summary>
    public static Water At(Scene scene, Vector3 point)
    {
        ulong id = CSharpComponentActions.WaterAt(scene.SessionId, point);
        return id == 0 ? default : new Water(new GameObject(scene.SessionId, id));
    }
}

public readonly partial record struct Camera
{
    /// <summary>The ray from this camera through a screen point (pixels from the top left).</summary>
    public Ray ScreenPointToRay(Vector2 point) => ScreenPointToRay(point, Screen.Size);

    /// <summary>As <see cref="ScreenPointToRay(Vector2)"/> for a screen of the given size (for render targets).</summary>
    public Ray ScreenPointToRay(Vector2 point, Vector2 screenSize)
    {
        Span<float> values = stackalloc float[6];
        if (!CSharpComponentActions.CameraScreenRay(GameObject.SceneId, GameObject.Id, point.X, point.Y,
                screenSize.X, screenSize.Y, values))
            throw IsValid ? new InvalidOperationException("There is no screen (headless): pass its size.")
                          : ActionText.Missing(GameObject, "Camera");
        return new Ray(new Vector3(values[0], values[1], values[2]), new Vector3(values[3], values[4], values[5]));
    }

    /// <summary>Where a world point shows: X, Y in pixels from the top left, Z its distance in front (negative:
    /// behind the camera).</summary>
    public Vector3 WorldToScreenPoint(Vector3 point) => WorldToScreenPoint(point, Screen.Size);

    /// <summary>As <see cref="WorldToScreenPoint(Vector3)"/> for a screen of the given size.</summary>
    public Vector3 WorldToScreenPoint(Vector3 point, Vector2 screenSize)
    {
        Span<float> values = stackalloc float[3];
        if (!CSharpComponentActions.CameraWorldToScreen(GameObject.SceneId, GameObject.Id, point,
                screenSize.X, screenSize.Y, values))
            throw IsValid ? new InvalidOperationException("There is no screen (headless): pass its size.")
                          : ActionText.Missing(GameObject, "Camera");
        return new Vector3(values[0], values[1], values[2]);
    }
}

public readonly partial record struct SkinnedMeshRenderer
{
    /// <summary>Plays a clip on some bones over the base animation (bones: a bone name; it and those below it).</summary>
    public void PlayLayer(string clip, string bones, float fadeSeconds = 0.15f)
    {
        ArgumentException.ThrowIfNullOrEmpty(clip);
        if (!CSharpComponentActions.SkinnedLayer(GameObject.SceneId, GameObject.Id, clip, bones ?? "", fadeSeconds))
            throw ActionText.Missing(GameObject, "Skinned Mesh Renderer");
    }

    /// <summary>Fades the layer out.</summary>
    public void StopLayer(float fadeSeconds = 0.15f)
    {
        if (!CSharpComponentActions.SkinnedLayer(GameObject.SceneId, GameObject.Id, "", "", fadeSeconds))
            throw ActionText.Missing(GameObject, "Skinned Mesh Renderer");
    }

    /// <summary>How many parts (meshes with their own materials) the model has.</summary>
    public int PartCount => Math.Max(CSharpComponentActions.SkinnedPartCount(GameObject.SceneId, GameObject.Id), 0);

    /// <summary>A part's name, 0 to PartCount - 1.</summary>
    public string PartName(int index)
    {
        SkinnedMeshRenderer self = this;
        return ActionText.Read(buffer => CSharpComponentActions.SkinnedPartText(self.GameObject.SceneId, self.GameObject.Id, 0, index, "", buffer))
            ?? throw new ArgumentOutOfRangeException(nameof(index));
    }

    /// <summary>The material a part uses (its own, or the model's).</summary>
    public string GetPartMaterial(string part)
    {
        SkinnedMeshRenderer self = this;
        return ActionText.Read(buffer => CSharpComponentActions.SkinnedPartText(self.GameObject.SceneId, self.GameObject.Id, 1, 0, part ?? "", buffer)) ?? "";
    }

    /// <summary>Gives a part (by index) its own material, a .tmat path; empty for the model's.</summary>
    public void SetPartMaterial(int index, string materialPath)
    {
        if (!CSharpComponentActions.SkinnedPartMaterial(GameObject.SceneId, GameObject.Id, index, materialPath ?? ""))
            throw new ArgumentOutOfRangeException(nameof(index), $"{GameObject} has no Skinned Mesh Renderer part {index}.");
    }

    /// <summary>Tints a part.</summary>
    public void SetPartColor(string part, Color color) => Part(part, 0, new Vector4(color.R, color.G, color.B, color.A));

    /// <summary>Hides or shows a part.</summary>
    public void SetPartHidden(string part, bool hidden) => Part(part, 1, new Vector4(hidden ? 1 : 0, 0, 0, 0));

    /// <summary>Draws a part only into shadows (a first-person body's head).</summary>
    public void SetPartShadowOnly(string part, bool shadowOnly) => Part(part, 2, new Vector4(shadowOnly ? 1 : 0, 0, 0, 0));

    private void Part(string part, int what, Vector4 value)
    {
        ArgumentException.ThrowIfNullOrEmpty(part);
        if (!CSharpComponentActions.SkinnedPart(GameObject.SceneId, GameObject.Id, part, what, value))
            throw ActionText.Missing(GameObject, "Skinned Mesh Renderer");
    }

    /// <summary>The object of a bone (when the renderer exposes its bones as objects), or null.</summary>
    public GameObject? BoneAt(int joint)
    {
        ulong id = CSharpComponentActions.SkinnedBone(GameObject.SceneId, GameObject.Id, joint);
        return id == 0 ? null : new GameObject(GameObject.SceneId, id);
    }
}

public readonly partial record struct ComputeEffect
{
    /// <summary>Sets a vector input of the effect's compute graph by name.</summary>
    public void SetVector(string name, Vector4 value)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        if (!CSharpComponentActions.ComputeSetVector(GameObject.SceneId, GameObject.Id, name, value))
            throw ActionText.Missing(GameObject, "Compute Effect");
    }

    /// <summary>Sets a colour input of the effect's compute graph by name.</summary>
    public void SetColor(string name, Color value) => SetVector(name, new Vector4(value.R, value.G, value.B, value.A));

    /// <summary>Sets a number input of the effect's compute graph by name.</summary>
    public void SetFloat(string name, float value) => SetVector(name, new Vector4(value, 0, 0, 0));

    /// <summary>Runs the effect once now, for one with <see cref="EveryFrame"/> off. False when it could not run (no
    /// shader, or no graphics in a headless run).</summary>
    public bool Step() => CSharpComponentActions.ComputeStep(GameObject.SceneId, GameObject.Id);
}

public readonly partial record struct Foliage
{
    /// <summary>What the brush does: plants Density to the square metre in a circle (amount 0 to 1 of that). How many
    /// were planted.</summary>
    public int Paint(Vector3 center, float radius, float amount = 1) => Edit(0, center, radius, amount);

    /// <summary>Removes the plants in a circle (measured flat, whatever their height); how many went.</summary>
    public int Erase(Vector3 center, float radius) => Edit(1, center, radius, 0);

    /// <summary>One plant at a place in the world: turn in degrees about its up (below 0 at random), scale 0 between
    /// Min Scale and Max Scale.</summary>
    public void Add(Vector3 position, float turnDegrees = -1, float scale = 0) => Edit(2, position, turnDegrees, scale);

    /// <summary>Removes every plant.</summary>
    public void Clear() => Edit(3, default, 0, 0);

    private int Edit(int action, Vector3 point, float a, float b)
    {
        int result = CSharpComponentActions.FoliageEdit(GameObject.SceneId, GameObject.Id, action, point, a, b);
        return result >= 0 ? result : throw ActionText.Missing(GameObject, "Foliage");
    }
}
