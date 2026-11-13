using System.Numerics;

namespace Tallow;

/// <summary>Marks a gameplay behaviour or an ECS data type for registration.</summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct)]
public sealed class ComponentAttribute : Attribute;

/// <summary>Marks state the networking bridge must replicate.</summary>
[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public sealed class SyncAttribute : Attribute;

/// <summary>Controls a numeric field's Inspector range.</summary>
[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public sealed class RangeAttribute(float minimum, float maximum) : Attribute
{
    public float Minimum { get; } = minimum;
    public float Maximum { get; } = maximum;
}

/// <summary>Per-tick player input. The native input bridge will populate this.</summary>
public readonly record struct TickInput(Vector2 Move, Vector2 Look, uint Buttons);

/// <summary>A validated reference to an engine-owned scene entity, not a native pointer.</summary>
public readonly record struct GameObject(ulong SceneId, ulong Id)
{
    public bool IsValid => Engine.Bridge.IsAlive(this);
    public Transform Transform => new(this);
    public void Destroy() => Engine.Bridge.Destroy(this);
}

/// <summary>Reads and writes the ECS transform through the engine bridge.</summary>
public readonly struct Transform(GameObject gameObject)
{
    public Vector3 Position
    {
        get => Engine.Bridge.GetPosition(gameObject);
        set => Engine.Bridge.SetPosition(gameObject, value);
    }
}

/// <summary>
/// The trusted engine-to-managed boundary. A real implementation must marshal
/// calls into Tallow's existing scene/ECS/physics/network systems. Do not treat
/// this interface as complete gameplay parity.
/// </summary>
public interface IEngineBridge
{
    bool IsAlive(GameObject gameObject);
    Vector3 GetPosition(GameObject gameObject);
    void SetPosition(GameObject gameObject, Vector3 position);
    void Destroy(GameObject gameObject);
    bool IsMine(GameObject gameObject);
}

public static class Engine
{
    private sealed class UnboundBridge : IEngineBridge
    {
        private static InvalidOperationException Missing() =>
            new("Tallow's native C# engine bridge has not been initialized.");

        public bool IsAlive(GameObject gameObject) => throw Missing();
        public Vector3 GetPosition(GameObject gameObject) => throw Missing();
        public void SetPosition(GameObject gameObject, Vector3 position) => throw Missing();
        public void Destroy(GameObject gameObject) => throw Missing();
        public bool IsMine(GameObject gameObject) => throw Missing();
    }

    public static IEngineBridge Bridge { get; private set; } = new UnboundBridge();

    /// <summary>For the trusted native host and integration tests only.</summary>
    public static void Bind(IEngineBridge bridge) =>
        Bridge = bridge ?? throw new ArgumentNullException(nameof(bridge));
}

/// <summary>
/// Familiar Unity-like gameplay callbacks. Tallow owns the component lifetime;
/// managed allocations are reclaimed by .NET GC.
/// </summary>
public abstract class Script
{
    public GameObject GameObject { get; private set; }
    public Transform Transform => GameObject.Transform;
    public bool IsMine => Engine.Bridge.IsMine(GameObject);

    /// <summary>Called by Tallow's lifecycle dispatcher, not by gameplay scripts.</summary>
    public void Attach(GameObject gameObject) => GameObject = gameObject;

    public virtual void Awake() { }
    public virtual void OnEnable() { }
    public virtual void Start() { }
    public virtual void FixedUpdate(float deltaTime) { }
    public virtual void Update(TickInput input, float deltaTime) { }
    public virtual void OnLocalUpdate() { }
    public virtual void LateUpdate(float deltaTime) { }
    public virtual void OnDisable() { }
    public virtual void OnDestroy() { }
    public virtual void OnGUI() { }
}
