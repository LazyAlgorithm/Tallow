using System.Numerics;

namespace Tallow;

/// <summary>Immediate-mode drawing for <see cref="Script.OnGUI"/>: pixels from the game view's top-left.</summary>
public static partial class GUI
{
    private static Vector4 Rgba(Color? color) => color is { } c ? new Vector4(c.R, c.G, c.B, c.A) : Vector4.One;

    /// <summary>Text with a soft shadow (white by default).</summary>
    public static void Label(float x, float y, string text, Color? color = null) =>
        CSharpGUI.Label(x, y, text ?? "", Rgba(color));

    /// <summary>A filled rounded rectangle.</summary>
    public static void Box(float x, float y, float width, float height, Color color) =>
        CSharpGUI.Box(x, y, width, height, Rgba(color));

    /// <summary>A progress or health bar; fraction is 0..1.</summary>
    public static void Bar(float x, float y, float width, float height, float fraction, Color color) =>
        CSharpGUI.Bar(x, y, width, height, fraction, Rgba(color));

    /// <summary>A checkbox: pass the current value, keep the returned one.</summary>
    public static bool Toggle(float x, float y, string label, bool value) => CSharpGUI.Toggle(x, y, label ?? "", value);

    /// <summary>A slider: pass the current value, keep the returned one.</summary>
    public static float Slider(float x, float y, float width, string label, float value, float min, float max) =>
        CSharpGUI.Slider(x, y, width, label ?? "", value, min, max);

    /// <summary>True while the mouse is over a GUI control, so gameplay can ignore the click.</summary>
    public static bool MouseOverControl => CSharpGUI.MouseOverControl();
}

/// <summary>A destructible voxel object: carving cuts it, and pieces cut free break away.</summary>
[NativeComponent("Tallow.VoxelObject")]
public readonly partial record struct VoxelObject(GameObject GameObject) : IComponent
{
    public bool IsValid => CSharpWorld.HasVoxelObject(GameObject.SceneId, GameObject.Id);

    /// <summary>Cuts a sphere out (shared in a network session). False without a VoxelObject.</summary>
    public bool Carve(Vector3 worldPoint, float radius) =>
        CSharpWorld.CarveVoxels(GameObject.SceneId, GameObject.Id, worldPoint, radius);

    /// <summary>Cuts a sphere out at a point in the object's own space; true when anything went.</summary>
    public bool CarveLocal(Vector3 objectPoint, float radius) =>
        CSharpComponentActions.VoxelCarveLocal(GameObject.SceneId, GameObject.Id, objectPoint, radius) switch
        {
            < 0 => throw ActionText.Missing(GameObject, "Voxel Object"),
            var carved => carved > 0,
        };

    /// <summary>Puts the shape back as its settings make it (undoing carving).</summary>
    public void ResetShape()
    {
        if (!CSharpComponentActions.VoxelControl(GameObject.SceneId, GameObject.Id, 0))
            throw ActionText.Missing(GameObject, "Voxel Object");
    }

    /// <summary>Fills the whole grid solid.</summary>
    public void Fill()
    {
        if (!CSharpComponentActions.VoxelControl(GameObject.SceneId, GameObject.Id, 1))
            throw ActionText.Missing(GameObject, "Voxel Object");
    }
}

/// <summary>Voxel terrain: dig and build with <see cref="ModifySphere"/>. <see cref="Find"/> gives the scene's.</summary>
[NativeComponent("Tallow.VoxelTerrain")]
public readonly partial record struct VoxelTerrain(GameObject GameObject) : IComponent
{
    public static VoxelTerrain? Find(Scene scene)
    {
        ulong id = CSharpWorld.FindVoxelTerrain(scene.SessionId);
        return id == 0 ? null : new VoxelTerrain(new GameObject(scene.SessionId, id));
    }

    /// <summary>Chunks made so far; with <see cref="PendingChunks"/> at 0 the ground near the camera is ready.</summary>
    public int ChunkCount => CSharpWorld.TerrainChunkCount(GameObject.SceneId, GameObject.Id);

    /// <summary>Chunks still being made (streamed in).</summary>
    public int PendingChunks => CSharpWorld.TerrainPendingChunks(GameObject.SceneId, GameObject.Id);

    /// <summary>Raises (amount &gt; 0) or digs (amount &lt; 0) the ground in a sphere.</summary>
    public bool ModifySphere(Vector3 worldCenter, float radius, float amount) =>
        CSharpWorld.ModifyTerrain(GameObject.SceneId, GameObject.Id, worldCenter, radius, amount);
}

/// <summary>The built-in networked character motor (WASD, jump, look). Read where it is looking.</summary>
[NativeComponent("Tallow.CharacterMotor")]
public readonly partial record struct CharacterMotor(GameObject GameObject) : IComponent
{
    public bool IsValid => CSharpWorld.HasCharacterMotor(GameObject.SceneId, GameObject.Id);
    /// <summary>Degrees around the up axis.</summary>
    public float Yaw => CSharpWorld.MotorYaw(GameObject.SceneId, GameObject.Id);
    /// <summary>Degrees up or down.</summary>
    public float Pitch => CSharpWorld.MotorPitch(GameObject.SceneId, GameObject.Id);
}

public readonly partial record struct Scene
{
    /// <summary>
    /// Adds everything in a scene file to this scene, under one new object that is returned (the file's top-level
    /// objects become its children); null when the file cannot be read. With <paramref name="applyEnvironment"/>
    /// the file's sky, fog and ambient light replace this scene's. Not networked: every machine loads it itself.
    /// </summary>
    public GameObject? LoadAdditive(string path, bool applyEnvironment = false)
    {
        ulong id = CSharpWorld.LoadAdditive(SessionId, path, applyEnvironment);
        return id != 0 ? new GameObject(SessionId, id) : null;
    }

    /// <summary>Removes what <see cref="LoadAdditive"/> added, at once.</summary>
    public bool Unload(GameObject group) => CSharpWorld.UnloadAdditive(SessionId, group.Id);

    /// <summary>The network session's tick; 0 offline.</summary>
    public long NetworkTick => CSharpWorld.NetworkTick(SessionId);

    /// <summary>Objects in the scene, transient ones included.</summary>
    public int ObjectCount => CSharpSceneObjects.ObjectCount(SessionId);

    /// <summary>How many objects have a built-in component of this type name ("Tallow.ReflectionProbe").</summary>
    public int CountComponents(string nativeTypeName) => CSharpNativeComponents.Count(SessionId, nativeTypeName);
}
