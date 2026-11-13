using System.Numerics;

namespace Tallow;

/// <summary>Marks a gameplay behaviour or an ECS data type for registration.</summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct)]
public sealed class ComponentAttribute : Attribute { }

/// <summary>Marks state the networking bridge must replicate.</summary>
[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public sealed class SyncAttribute : Attribute { }

/// <summary>Controls a numeric field's Inspector range.</summary>
[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public sealed class RangeAttribute(float minimum, float maximum) : Attribute
{
    public float Minimum { get; } = minimum;
    public float Maximum { get; } = maximum;
}

/// <summary>Buttons automatically collected and transmitted by the network input system.</summary>
public enum InputButton
{
    Jump, Sprint, Crouch, Fire, Use, Reload, Ability1, Ability2,
    Custom1, Custom2, Custom3, Custom4, Custom5, Custom6, Custom7, Custom8
}

/// <summary>
/// The local or server-replayed controls for one gameplay tick.
/// Look.X is yaw and Look.Y is pitch, both in degrees.
/// </summary>
public readonly record struct TickInput(
    Vector2 Move, Vector2 Look, uint Buttons, uint PreviousButtons = 0)
{
    public float Yaw => Look.X;
    public float Pitch => Look.Y;

    public bool Held(InputButton button) => (Buttons & (1u << (int)button)) != 0;
    public bool Pressed(InputButton button) =>
        (Buttons & (1u << (int)button)) != 0 && (PreviousButtons & (1u << (int)button)) == 0;
    public bool Released(InputButton button) =>
        (Buttons & (1u << (int)button)) == 0 && (PreviousButtons & (1u << (int)button)) != 0;

    public bool Jump => Held(InputButton.Jump);
    public bool Sprint => Held(InputButton.Sprint);
    public bool Crouch => Held(InputButton.Crouch);
    public bool Fire => Held(InputButton.Fire);
    public bool Use => Held(InputButton.Use);

    public Quaternion LookRotation =>
        Quaternion.CreateFromYawPitchRoll(Yaw * (MathF.PI / 180), Pitch * (MathF.PI / 180), 0);

    public Vector3 MoveDirection
    {
        get
        {
            Vector3 direction = Vector3.Transform(
                new Vector3(Move.X, 0, Move.Y),
                Quaternion.CreateFromAxisAngle(Vector3.UnitY, Yaw * (MathF.PI / 180)));
            return direction.LengthSquared() > 1 ? Vector3.Normalize(direction) : direction;
        }
    }
}

/// <summary>A validated reference to an engine-owned scene entity, not a native pointer.</summary>
public readonly record struct GameObject(ulong SceneId, ulong Id)
{
    public bool IsValid => Engine.Bridge.IsAlive(this);
    public Transform Transform => new(this);
    public void Destroy() => Engine.Bridge.Destroy(this);
}

/// <summary>Reads and writes the ECS transform through the engine bridge.</summary>
public sealed class Transform(GameObject gameObject)
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
    private Transform? _transform;
    public Transform Transform => _transform ??= new Transform(GameObject);
    public bool IsMine => Engine.Bridge.IsMine(GameObject);

    /// <summary>Called by Tallow's lifecycle dispatcher, not by gameplay scripts.</summary>
    public void Attach(GameObject gameObject)
    {
        GameObject = gameObject;
        _transform = new Transform(gameObject);
    }

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
