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
public readonly record struct VoxelObject(GameObject GameObject) : IComponent
{
    public bool IsValid => CSharpWorld.HasVoxelObject(GameObject.SceneId, GameObject.Id);

    /// <summary>Cuts a sphere out (shared in a network session). False without a VoxelObject.</summary>
    public bool Carve(Vector3 worldPoint, float radius) =>
        CSharpWorld.CarveVoxels(GameObject.SceneId, GameObject.Id, worldPoint, radius);
}

/// <summary>Voxel terrain: dig and build with <see cref="ModifySphere"/>. <see cref="Find"/> gives the scene's.</summary>
public readonly record struct VoxelTerrain(GameObject GameObject) : IComponent
{
    public static VoxelTerrain? Find(Scene scene)
    {
        ulong id = CSharpWorld.FindVoxelTerrain(scene.SessionId);
        return id == 0 ? null : new VoxelTerrain(new GameObject(scene.SessionId, id));
    }

    /// <summary>Raises (amount &gt; 0) or digs (amount &lt; 0) the ground in a sphere.</summary>
    public bool ModifySphere(Vector3 worldCenter, float radius, float amount) =>
        CSharpWorld.ModifyTerrain(GameObject.SceneId, GameObject.Id, worldCenter, radius, amount);
}

/// <summary>The built-in networked character motor (WASD, jump, look). Read where it is looking.</summary>
public readonly record struct CharacterMotor(GameObject GameObject) : IComponent
{
    public bool IsValid => CSharpWorld.HasCharacterMotor(GameObject.SceneId, GameObject.Id);
    /// <summary>Degrees around the up axis.</summary>
    public float Yaw => CSharpWorld.MotorYaw(GameObject.SceneId, GameObject.Id);
    /// <summary>Degrees up or down.</summary>
    public float Pitch => CSharpWorld.MotorPitch(GameObject.SceneId, GameObject.Id);
}

public readonly partial record struct Scene
{
    /// <summary>The network session's tick; 0 offline.</summary>
    public long NetworkTick => CSharpWorld.NetworkTick(SessionId);
}
