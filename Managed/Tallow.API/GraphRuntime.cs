using System.Globalization;
using System.Numerics;

namespace Tallow;

/// <summary>A hit from the graph Raycast and Sphere Trace nodes (Point, Normal and Distance are zero, and
/// GameObject is not valid, when nothing was hit).</summary>
public readonly record struct GraphHit(GameObject GameObject, Vector3 Point, Vector3 Normal, float Distance);

/// <summary>Helpers the code compiled from visual scripting graphs calls (the C# side of the engine's
/// GraphRuntime). Game code can use them too.</summary>
public static class GraphRuntime
{
    /// <summary>A rotation from Euler angles in degrees.</summary>
    public static Quaternion Euler(float x, float y, float z) => RotationMath.EulerDegrees(new Vector3(x, y, z));

    /// <summary>Whether an object still exists.</summary>
    public static bool IsValid(GameObject value) => value.IsValid;

    /// <summary>A graph's Get node for C# ECS data: the object's data of type T, or default when it has none.</summary>
    public static T Data<T>(GameObject value) where T : unmanaged =>
        value.IsValid && value.Entity.TryGet(out T data) ? data : default;

    /// <summary>Whether a reference points at something that still exists.</summary>
    public static bool IsValid(object? value) => value switch
    {
        null => false,
        GameObject gameObject => gameObject.IsValid,
        Rigidbody body => body.IsValid,
        CharacterController controller => controller.IsValid,
        SoftBody softBody => softBody.IsValid,
        Joint joint => joint.IsValid,
        Animator animator => animator.IsValid,
        UIDocument document => document.IsValid,
        VoxelObject voxels => voxels.IsValid,
        CharacterMotor motor => motor.IsValid,
        Light light => light.IsValid,
        MeshRenderer renderer => renderer.IsValid,
        NavigationAgent agent => agent.IsValid,
        ColliderHandle collider => collider.IsValid,
        Script script => script.GameObject.IsValid,
        Transform transform => transform.GameObject.IsValid,
        _ => true
    };

    /// <summary>Destroys an object (nothing for one that is gone).</summary>
    public static void Destroy(GameObject target)
    {
        if (target.IsValid)
            target.Destroy();
    }

    /// <summary>The graph Raycast node: the first thing a ray hits within maxDistance.</summary>
    public static bool Raycast(Scene scene, Vector3 origin, Vector3 direction, float maxDistance, out GraphHit hit)
    {
        PhysicsHit? found = scene.RaycastHit(origin, direction, maxDistance);
        hit = Hit(found);
        return found.HasValue;
    }

    /// <summary>The graph Sphere Trace node: the first thing a moving sphere hits within maxDistance.</summary>
    public static bool SphereCast(Scene scene, Vector3 origin, float radius, Vector3 direction, float maxDistance, out GraphHit hit)
    {
        PhysicsHit? found = scene.SphereCastHit(origin, radius, direction, maxDistance);
        hit = Hit(found);
        return found.HasValue;
    }

    static GraphHit Hit(PhysicsHit? hit) => hit is { } h
        ? new GraphHit(h.HitObject ?? default, h.Point, h.Normal ?? Vector3.Zero, h.Distance)
        : default;

    /// <summary>Character capsule height (crouching): see CharacterController.SetHeight.</summary>
    public static void SetCharacterHeight(GameObject target, float height, float standingHeight) =>
        target.GetCharacterController()?.SetHeight(height, standingHeight);

    /// <summary>The character's capsule height now (0 without a CharacterController).</summary>
    public static float CharacterHeight(GameObject target) => target.GetCharacterController()?.Height ?? 0f;

    /// <summary>How far a crouching character's capsule has been lowered (0 standing).</summary>
    public static float CrouchLift(GameObject target) => target.GetCharacterController()?.CrouchLift ?? 0f;

    /// <summary>The graph random nodes' numbers (not the same on every machine: see NetRandom).</summary>
    public static class Random
    {
        /// <summary>From 0 up to (not including) 1.</summary>
        public static double NextDouble() => System.Random.Shared.NextDouble();
        /// <summary>From -1 up to 1.</summary>
        public static double NextDoubleSigned() => System.Random.Shared.NextDouble() * 2 - 1;
        /// <summary>From min up to (not including) max.</summary>
        public static int Next(int min, int max) => max <= min ? min : System.Random.Shared.Next(min, max);
    }

    /// <summary>The graph To String nodes: the value as text, the same on every machine (no locale).</summary>
    public static string Text(float value) => value.ToString(CultureInfo.InvariantCulture);
    /// <summary>A whole number as text.</summary>
    public static string Text(int value) => value.ToString(CultureInfo.InvariantCulture);
    /// <summary>"true" or "false".</summary>
    public static string Text(bool value) => value ? "true" : "false";
    /// <summary>The text, or empty for null.</summary>
    public static string Text(string? value) => value ?? "";
    /// <summary>"X=1 Y=2".</summary>
    public static string Text(Vector2 value) => string.Create(CultureInfo.InvariantCulture, $"X={value.X:0.###} Y={value.Y:0.###}");
    /// <summary>"X=1 Y=2 Z=3".</summary>
    public static string Text(Vector3 value) =>
        string.Create(CultureInfo.InvariantCulture, $"X={value.X:0.###} Y={value.Y:0.###} Z={value.Z:0.###}");
    /// <summary>"R=1 G=0.5 B=0 A=1".</summary>
    public static string Text(Color value) =>
        string.Create(CultureInfo.InvariantCulture, $"R={value.R:0.###} G={value.G:0.###} B={value.B:0.###} A={value.A:0.###}");
    /// <summary>The rotation as angles in degrees, "X=0 Y=90 Z=0".</summary>
    public static string Text(Quaternion value)
    {
        Vector3 euler = RotationMath.ToEulerDegrees(value);
        return string.Create(CultureInfo.InvariantCulture, $"X={euler.X:0.#} Y={euler.Y:0.#} Z={euler.Z:0.#}");
    }
    /// <summary>The object's name, or "None".</summary>
    public static string Text(GameObject value) => value.IsValid ? value.Name : "None";
    /// <summary>An object's or script's name, "None" for nothing, otherwise ToString.</summary>
    public static string Text(object? value) => value switch
    {
        null => "None",
        GameObject gameObject => Text(gameObject),
        Script script => script.GameObject.IsValid ? script.GameObject.Name : "None",
        _ => value.ToString() ?? ""
    };
}
