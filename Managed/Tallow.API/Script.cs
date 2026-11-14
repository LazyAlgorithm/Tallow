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
    /// <summary>Find an attached C# gameplay behaviour on this object.</summary>
    public T? GetComponent<T>() where T : Script =>
        Engine.Bridge.GetManagedComponent(this, typeof(T)) as T;
    public void Destroy() => Engine.Bridge.Destroy(this);
}

/// <summary>
/// The native Transform channels. These are passed by value through the trusted
/// host; gameplay scripts should use Transform properties instead.
/// </summary>
public enum TransformChannel
{
    LocalPosition = 1,
    Rotation = 2,
    LocalRotation = 3,
    LocalScale = 4,
    WorldScale = 5,
    EulerAngles = 6,
    LocalEulerAngles = 7,
    Forward = 8,
    Right = 9,
    Up = 10,
    LookAt = 11,
    TransformPoint = 12,
    InverseTransformPoint = 13
}

/// <summary>
/// The same world/local position, rotation, scale and directional properties as
/// Beef's Transform. All hierarchy math is performed by the native engine.
/// </summary>
public sealed class Transform(GameObject gameObject)
{
    private Vector4 Read(TransformChannel channel) =>
        Engine.Bridge.GetTransform(gameObject, channel);

    private void Write(TransformChannel channel, Vector4 value) =>
        Engine.Bridge.SetTransform(gameObject, channel, value);

    private Vector3 ReadVector(TransformChannel channel)
    {
        Vector4 value = Read(channel);
        return new Vector3(value.X, value.Y, value.Z);
    }

    private void WriteVector(TransformChannel channel, Vector3 value) =>
        Write(channel, new Vector4(value, 0));

    private Quaternion ReadQuaternion(TransformChannel channel)
    {
        Vector4 value = Read(channel);
        return new Quaternion(value.X, value.Y, value.Z, value.W);
    }

    private void WriteQuaternion(TransformChannel channel, Quaternion value) =>
        Write(channel, new Vector4(value.X, value.Y, value.Z, value.W));

    public Vector3 Position
    {
        get => Engine.Bridge.GetPosition(gameObject);
        set => Engine.Bridge.SetPosition(gameObject, value);
    }

    public Vector3 LocalPosition
    {
        get => ReadVector(TransformChannel.LocalPosition);
        set => WriteVector(TransformChannel.LocalPosition, value);
    }

    public Quaternion Rotation
    {
        get => ReadQuaternion(TransformChannel.Rotation);
        set => WriteQuaternion(TransformChannel.Rotation, value);
    }

    public Quaternion LocalRotation
    {
        get => ReadQuaternion(TransformChannel.LocalRotation);
        set => WriteQuaternion(TransformChannel.LocalRotation, value);
    }

    public Vector3 LocalScale
    {
        get => ReadVector(TransformChannel.LocalScale);
        set => WriteVector(TransformChannel.LocalScale, value);
    }

    public Vector3 WorldScale => ReadVector(TransformChannel.WorldScale);

    public Vector3 EulerAngles
    {
        get => ReadVector(TransformChannel.EulerAngles);
        set => WriteVector(TransformChannel.EulerAngles, value);
    }

    public Vector3 LocalEulerAngles
    {
        get => ReadVector(TransformChannel.LocalEulerAngles);
        set => WriteVector(TransformChannel.LocalEulerAngles, value);
    }

    public Vector3 Forward => ReadVector(TransformChannel.Forward);
    public Vector3 Right => ReadVector(TransformChannel.Right);
    public Vector3 Up => ReadVector(TransformChannel.Up);

    public void SetPositionAndRotation(Vector3 position, Quaternion rotation)
    {
        Position = position;
        Rotation = rotation;
    }

    public void Translate(Vector3 delta) => Position += delta;

    /// <summary>Rotate in local space, with X/Y/Z angles in degrees.</summary>
    public void Rotate(Vector3 eulerDegrees) =>
        LocalRotation = Quaternion.Normalize(LocalRotation *
            Quaternion.CreateFromYawPitchRoll(
                eulerDegrees.Y * (MathF.PI / 180),
                eulerDegrees.X * (MathF.PI / 180),
                eulerDegrees.Z * (MathF.PI / 180)));

    /// <summary>Face a world-space point using Tallow's native LookAt.</summary>
    public void LookAt(Vector3 target) => WriteVector(TransformChannel.LookAt, target);

    /// <summary>Convert a point in local space to world space (including parents and scale).</summary>
    public Vector3 TransformPoint(Vector3 localPoint) =>
        Engine.Bridge.TransformPoint(gameObject, localPoint, inverse: false);

    /// <summary>Convert a world-space point back into this object's local space.</summary>
    public Vector3 InverseTransformPoint(Vector3 worldPoint) =>
        Engine.Bridge.TransformPoint(gameObject, worldPoint, inverse: true);
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
    Vector4 GetTransform(GameObject gameObject, TransformChannel channel);
    void SetTransform(GameObject gameObject, TransformChannel channel, Vector4 value);
    Vector3 TransformPoint(GameObject gameObject, Vector3 point, bool inverse);
    Script? GetManagedComponent(GameObject gameObject, Type scriptType);
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
        public Vector4 GetTransform(GameObject gameObject, TransformChannel channel) => throw Missing();
        public void SetTransform(GameObject gameObject, TransformChannel channel, Vector4 value) => throw Missing();
        public Vector3 TransformPoint(GameObject gameObject, Vector3 point, bool inverse) => throw Missing();
        public Script? GetManagedComponent(GameObject gameObject, Type scriptType) => throw Missing();
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

    /// <summary>Find another attached C# behaviour, as in native Beef scripts.</summary>
    public T? GetComponent<T>() where T : Script => GameObject.GetComponent<T>();

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
