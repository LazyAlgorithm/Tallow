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
    public void Pause() => Control(1);
    public void Resume() => Control(2);
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
    public void Stop() => Control(2);

    private int State => CSharpComponentActions.DialogueState(GameObject.SceneId, GameObject.Id);

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

    public int PositionCount => Math.Max(
        CSharpComponentActions.LineGetPositions(GameObject.SceneId, GameObject.Id, Span<float>.Empty), 0);
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
