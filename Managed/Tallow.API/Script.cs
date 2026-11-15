using System.Numerics;

namespace Tallow;

/// <summary>
/// Marks an ECS data struct for registration. Script-derived gameplay classes
/// are discovered by inheritance; this attribute is optional on legacy
/// scripts for backwards compatibility.
/// </summary>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct)]
public sealed class ComponentAttribute : Attribute { }

/// <summary>
/// Build-generated trusted C# component registration contract shared by the
/// JIT editor and the future statically linked NativeAOT player. Scripts are
/// created through direct constructors, not reflection over game assemblies.
/// </summary>
public interface IGameplayComponentRegistry
{
    global::System.Collections.Generic.IReadOnlyList<string> ComponentNames { get; }
    Script? Create(string fullName);
    /// <summary>Former full names ([FormerlyNamed]) and the script each now names.</summary>
    global::System.Collections.Generic.IReadOnlyDictionary<string, string> FormerNames =>
        new global::System.Collections.Generic.Dictionary<string, string>();
}

/// <summary>
/// The full name (namespace and class) this script had before it was renamed or moved to another namespace.
/// Scenes, prefabs and built games that still name it the old way get this class, and the editor updates the
/// scenes it opens. Repeat it for each earlier name.
/// </summary>
[AttributeUsage(AttributeTargets.Class, AllowMultiple = true, Inherited = false)]
public sealed class FormerlyNamedAttribute(string fullName) : Attribute
{
    public string FullName { get; } = fullName;
}

/// <summary>
/// Kept in save games: SaveSystem writes the field's value when the game saves and puts it back when that save
/// is loaded (then <see cref="Script.OnLoaded"/> runs). Saved under the field's name, so a renamed field starts
/// from its default. Types: those the Inspector shows (numbers, bool, string, enums, vectors, references).
/// </summary>
[AttributeUsage(AttributeTargets.Field)]
public sealed class SavedAttribute : Attribute { }

/// <summary>Marks state the networking bridge must replicate.</summary>
[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
public sealed class SyncAttribute : Attribute { }

/// <summary>
/// Save a private gameplay field and show it in the Inspector. Public fields
/// are serialized and displayed by default. Values are applied before Awake.
/// </summary>
[AttributeUsage(AttributeTargets.Field)]
public sealed class ShowInInspectorAttribute : Attribute { }

/// <summary>
/// Keep a serialized C# field hidden in the Inspector, like Beef's
/// HideInInspector. Also explicitly serializes a private field.
/// </summary>
[AttributeUsage(AttributeTargets.Field)]
public sealed class HideInInspectorAttribute : Attribute { }

/// <summary>
/// Gives a persisted field a stable identity across C# member renames.
/// Optional: the default identity is derived from the declaring component
/// and field name. NativeAOT exporters will consume source-generated IDs,
/// not use reflection to locate serialized fields at runtime.
/// Keep this ID constant when renaming a field; use a new ID for a new field.
/// </summary>
[AttributeUsage(AttributeTargets.Field)]
public sealed class SerializedFieldIdAttribute(string id) : Attribute
{
    public string Id { get; } = id;
}

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

/// <summary>
/// Public component lookup marker shared by C# Script objects and native
/// session-checked component handles. Gameplay never sees Beef pointers.
/// </summary>
public interface IComponent { }

/// <summary>A validated reference to an engine-owned scene entity, not a native pointer.</summary>
public readonly record struct GameObject(ulong SceneId, ulong Id)
{
    public bool IsValid => Engine.Bridge.IsAlive(this);

    private static bool CheckedActiveState(int state)
    {
        if (state < 0)
            throw new ObjectDisposedException(nameof(GameObject),
                "The native scene GameObject is no longer alive.");
        return state != 0;
    }

    /// <summary>Whether this object is switched on, ignoring parent state.</summary>
    public bool ActiveSelf =>
        CheckedActiveState(CSharpSceneObjects.ActiveSelfState(SceneId, Id));

    /// <summary>Whether this object and every parent in its hierarchy are active.</summary>
    public bool ActiveInHierarchy =>
        CheckedActiveState(CSharpSceneObjects.ActiveHierarchyState(SceneId, Id));

    /// <summary>
    /// Activates/deactivates the native GameObject and its descendant
    /// hierarchy, invoking the usual component and networking callbacks.
    /// </summary>
    public void SetActive(bool active)
    {
        if (!CSharpSceneObjects.SetActive(SceneId, Id, active))
            throw new ObjectDisposedException(nameof(GameObject),
                "The native scene GameObject is no longer alive.");
    }

    public Transform Transform => new(this);
    /// <summary>The scene session containing this object; no native pointer is held.</summary>
    public Scene Scene => new(SceneId);

    private static ObjectDisposedException Stale() =>
        new(nameof(GameObject), "The native scene GameObject is no longer alive.");

    /// <summary>The object's name, as shown in the Hierarchy.</summary>
    public string Name
    {
        get
        {
            Span<byte> buffer = stackalloc byte[256];
            int length = CSharpSceneObjects.CopyName(SceneId, Id, buffer);
            if (length < 0)
                throw Stale();
            if (length > buffer.Length)
            {
                buffer = new byte[length];
                length = Math.Min(length, CSharpSceneObjects.CopyName(SceneId, Id, buffer));
                if (length < 0)
                    throw Stale();
            }
            return global::System.Text.Encoding.UTF8.GetString(buffer[..length]);
        }
    }

    /// <summary>
    /// Renames the object. (GameObject is a value handle, so this is a method:
    /// C# does not allow assigning a property through another property.)
    /// </summary>
    public void SetName(string name)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        if (!CSharpSceneObjects.SetName(SceneId, Id, name))
            throw IsValid ? new ArgumentException(
                "Names are at most 256 bytes of single-line text.", nameof(name)) : Stale();
    }

    /// <summary>The object this one is under in the hierarchy, or null at the top.</summary>
    public GameObject? Parent
    {
        get
        {
            ulong parent = CSharpSceneObjects.GetParent(SceneId, Id);
            return parent != 0 ? new GameObject(SceneId, parent) : null;
        }
    }

    /// <summary>
    /// Moves this object under another, or to the top of the scene with
    /// null. Returns false when that would make it its own descendant.
    /// </summary>
    public bool SetParent(GameObject? parent, bool keepWorldPose = true)
    {
        if (parent is { } target && target.SceneId != SceneId)
            return false;
        return CSharpSceneObjects.SetParent(SceneId, Id, parent?.Id ?? 0, keepWorldPose);
    }

    /// <summary>How many objects are directly under this one.</summary>
    public int ChildCount
    {
        get
        {
            int count = CSharpSceneObjects.GetChildCount(SceneId, Id);
            return count >= 0 ? count : throw Stale();
        }
    }

    /// <summary>The child at an index, in Hierarchy order; null when out of range.</summary>
    public GameObject? GetChild(int index)
    {
        ulong child = CSharpSceneObjects.GetChild(SceneId, Id, index);
        return child != 0 ? new GameObject(SceneId, child) : null;
    }

    /// <summary>The first direct child with that name, or null.</summary>
    public GameObject? FindChild(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        for (int i = 0; GetChild(i) is { } child; i++)
            if (child.Name == name)
                return child;
        return null;
    }

    public bool HasTag(string tag) => CSharpSceneObjects.HasTag(SceneId, Id, tag);
    public bool AddTag(string tag) => CSharpSceneObjects.AddTag(SceneId, Id, tag);
    public bool RemoveTag(string tag) => CSharpSceneObjects.RemoveTag(SceneId, Id, tag);

    /// <summary>The physics layer, 0 to 31 (named in Project Settings).</summary>
    public int Layer
    {
        get
        {
            int layer = CSharpSceneObjects.GetLayer(SceneId, Id);
            return layer >= 0 ? layer : throw Stale();
        }
    }

    /// <summary>Moves the object to another physics layer, 0 to 31.</summary>
    public void SetLayer(int layer)
    {
        if (!CSharpSceneObjects.SetLayer(SceneId, Id, layer))
            throw IsValid ? new ArgumentOutOfRangeException(nameof(layer)) : Stale();
    }

    /// <summary>Whether the object has a Network Identity (is replicated).</summary>
    public bool IsNetworked => CSharpSceneObjects.HasNetworkIdentity(SceneId, Id);

    /// <summary>
    /// The client that owns this networked object; 0 is the server (and
    /// every object without a Network Identity).
    /// </summary>
    public int OwnerClientId
    {
        get
        {
            int owner = CSharpSceneObjects.OwnerClientId(SceneId, Id);
            return owner >= 0 ? owner : throw Stale();
        }
    }
    /// <summary>
    /// Resolve a C# behaviour or a supported native/ECS-backed component
    /// through one API. Native value handles remain lightweight and validate
    /// the owning scene on use; no native object or Jolt pointer crosses.
    /// 
    /// When missing, C# script/Transform lookups return null, while native
    /// struct handles return default (IsValid == false). Prefer
    /// TryGetComponent if absence is possible.
    /// </summary>
    public T? GetComponent<T>() where T : IComponent =>
        TryGetComponent<T>(out var found) ? found : default;

    /// <summary>
    /// Resolve a component with a consistent missing-component result for
    /// both managed classes and native value handles. This avoids relying on
    /// null checks for value-type Rigidbody, SoftBody, Joint, etc.
    /// </summary>
    public bool TryGetComponent<T>(out T component) where T : IComponent
    {
        Type requested = typeof(T);
        if (typeof(Script).IsAssignableFrom(requested))
        {
            if (Engine.Bridge.GetManagedComponent(this, requested) is T script)
            {
                component = script;
                return true;
            }
        }
        else if (requested == typeof(Transform))
        {
            if (IsValid)
            {
                component = (T)(object)Transform;
                return true;
            }
        }
        else if (requested == typeof(Rigidbody))
        {
            if (GetRigidbody() is { } rigidbody)
            {
                component = (T)(object)rigidbody;
                return true;
            }
        }
        else if (requested == typeof(SoftBody))
        {
            if (GetSoftBody() is { } body)
            {
                component = (T)(object)body;
                return true;
            }
        }
        else if (requested == typeof(CharacterController))
        {
            if (GetCharacterController() is { } controller)
            {
                component = (T)(object)controller;
                return true;
            }
        }
        else if (requested == typeof(Joint))
        {
            if (GetJoint() is { } joint)
            {
                component = (T)(object)joint;
                return true;
            }
        }
        else if (requested == typeof(Animator))
        {
            if (GetAnimator() is { } animator)
            {
                component = (T)(object)animator;
                return true;
            }
        }
        else if (requested == typeof(ColliderHandle))
        {
            // One collider for GetComponent; indexed GetCollider(index) is
            // still available when multiple shapes share a GameObject.
            if (GetCollider() is { } collider)
            {
                component = (T)(object)collider;
                return true;
            }
        }
        else
        {
            throw new NotSupportedException(
                $"Component lookup has no native handle mapping for {requested.FullName}.");
        }
        component = default!;
        return false;
    }

    /// <summary>
    /// Attach a new trusted C# behaviour through Tallow's native scene and
    /// return precisely that new instance, even if siblings share its type.
    /// The Scene manages Awake/OnEnable/Start and eventual destruction.
    /// </summary>
    public T AddComponent<T>() where T : Script
    {
        Type type = typeof(T);
        if (type.IsAbstract || type.ContainsGenericParameters ||
            type.FullName is not string fullName)
            throw new ArgumentException("C# components must be concrete, non-generic Script types.");

        int instance = CSharpComponents.Add(SceneId, Id, fullName);
        if (instance <= 0)
            throw new InvalidOperationException(
                $"Tallow could not add {fullName} to the native scene object.");
        return Engine.Bridge.GetManagedInstance(this, instance) as T ??
            throw new InvalidOperationException(
                $"Tallow failed to resolve newly attached C# component {fullName}.");
    }

    public void Destroy() => Engine.Bridge.Destroy(this);

    /// <summary>Number of native class colliders attached to this object.</summary>
    public int ColliderCount => Physics.GetColliderCount(SceneId, Id);

    /// <summary>
    /// Read a collider by attachment order, including stacked colliders
    /// of the same type. Returns null for invalid indices.
    /// </summary>
    /// <summary>This object's Animator, or null.</summary>
    public Animator? GetAnimator()
    {
        var animator = new Animator(this);
        return animator.IsValid ? animator : null;
    }

    /// <summary>The component on this object or the nearest one below it (depth first), or null/default.</summary>
    public T? GetComponentInChildren<T>() where T : IComponent
    {
        if (TryGetComponent(out T found))
            return found;
        for (int i = 0; i < ChildCount; i++)
        {
            if (GetChild(i) is { } child && child.GetComponentInChildren<T>() is { } inChild &&
                !EqualityComparer<T>.Default.Equals(inChild, default!))
                return inChild;
        }
        return default;
    }

    public ColliderHandle? GetCollider(int index = 0) =>
        Physics.GetColliderKind(SceneId, Id, index) >= 0 ?
            new ColliderHandle(this, index) : null;

    /// <summary>Retrieve an existing ECS-backed native Joint handle.</summary>
    public Joint? GetJoint() =>
        Physics.HasJoint(SceneId, Id) ? new Joint(this) : null;

    /// <summary>Retrieve the ECS-backed native Jolt character controller.</summary>
    public CharacterController? GetCharacterController() =>
        Physics.HasCharacterController(SceneId, Id) ? new CharacterController(this) : null;

    /// <summary>Retrieve the existing native ECS-backed Rigidbody handle.</summary>
    public Rigidbody? GetRigidbody() =>
        Physics.HasRigidbody(SceneId, Id) ? new Rigidbody(this) : null;

    /// <summary>Retrieve the existing native Jolt soft-body component.</summary>
    public SoftBody? GetSoftBody() =>
        Physics.HasSoftBody(SceneId, Id) ? new SoftBody(this) : null;
}

/// <summary>
/// Point and distance from a single native Jolt cast. A richer hit record
/// (surface normal and hit GameObject) is planned once struct ABI generation
/// is available; those fields are intentionally not fabricated here.
/// </summary>
public readonly record struct PhysicsContact(Vector3 Point, float Distance);

/// <summary>
/// Full native collision contact. A null Normal means the native query did not
/// supply a surface normal (currently true for raycasts, not sphere casts).
/// HitObject is null for contacts without an associated live GameObject.
/// </summary>
public readonly record struct PhysicsHit(
    Vector3 Point, Vector3? Normal, float Distance,
    GameObject? HitObject, float PenetrationDepth, uint BodyId)
{
    internal static PhysicsHit? FromNative(ulong session, PhysicsQueryHit hit)
    {
        if ((hit.Flags & 1) == 0)
            return null;
        Vector3? normal = (hit.Flags & 2) != 0 ?
            new Vector3(hit.NormalX, hit.NormalY, hit.NormalZ) : null;
        GameObject? obj = (hit.Flags & 4) != 0 && hit.EntityId != 0 ?
            new GameObject(session, hit.EntityId) : null;
        return new PhysicsHit(new Vector3(hit.PointX, hit.PointY, hit.PointZ),
            normal, hit.Distance, obj, hit.PenetrationDepth, hit.BodyId);
    }
}

/// <summary>
/// Generation-aware Flecs entity reference. Unlike GameObject, bare ECS
/// entities do not require a scene GameObject or Transform.
/// </summary>
public readonly record struct EcsEntity(ulong SessionId, ulong Id)
{
    public bool IsAlive => Id != 0 && Ecs.IsAlive(SessionId, Id);

    /// <summary>
    /// Delete only an unlinked local Flecs entity. Scene-backed GameObjects
    /// and replicated entities are protected by the native engine. This
    /// returns false if the scene has ended or the entity was already deleted.
    /// </summary>
    public bool DestroyLocal() => Id != 0 && Ecs.DeleteLocalEntity(SessionId, Id);

    /// <summary>
    /// Experimental offline-only opaque Flecs component write. Schema IDs
    /// and exact binary layouts must match a preceding successful scene
    /// registration. For gameplay use prefer generated typed data adapters
    /// once those are available. Never supply managed object references.
    /// </summary>
    public bool SetLocalData(ulong schemaId, Span<byte> bytes) =>
        Id != 0 && Ecs.SetLocalData(SessionId, Id, schemaId, bytes);

    /// <summary>
    /// Read an existing local-only opaque data component into the caller's
    /// exact-sized buffer. Returns false for a missing component, stale
    /// entity, invalid layout or networked scene.
    /// </summary>
    public bool TryCopyLocalData(ulong schemaId, Span<byte> destination) =>
        Id != 0 && Ecs.CopyLocalData(SessionId, Id, schemaId, destination);

    public bool HasLocalData(ulong schemaId) =>
        Id != 0 && Ecs.HasLocalData(SessionId, Id, schemaId);
}

/// <summary>
/// A reference to the active scene session. Its ID is checked by Beef for
/// every operation, so stale handles cannot access a subsequently opened scene.
/// </summary>
public readonly record struct Scene(ulong SessionId)
{
    /// <summary>
    /// Wrap a Flecs entity ID; it is not the same as GameObject.Id.
    /// </summary>
    public EcsEntity GetEcsEntity(ulong flecsEntityId) => new(SessionId, flecsEntityId);

    /// <summary>
    /// Create a bare local-only Flecs entity through the native world.
    /// Networked scenes do not permit this until generated [Sync] data and
    /// server authority have a shared C#/Beef replication path.
    /// </summary>
    public EcsEntity CreateLocalEcsEntity()
    {
        ulong id = Ecs.CreateLocalEntity(SessionId);
        return id != 0 ? new(SessionId, id) :
            throw new InvalidOperationException(
                "Cannot create a local ECS entity outside an active offline scene.");
    }

    /// <summary>
    /// Bulk-create bare local-only ECS entities. Returned IDs are Flecs
    /// entities, not GameObject IDs; wrap them using GetEcsEntity when needed.
    /// The output buffer must be no larger than 65536 items.
    /// </summary>
    public int CreateLocalEcsEntities(Span<ulong> entityIds) =>
        Ecs.CreateLocalEntities(SessionId, entityIds);

    /// <summary>
    /// Experimental offline-only registration of opaque packed Flecs data.
    /// A stable schema ID and matching field layout are required; native
    /// code validates length, size, alignment, entity ownership and session.
    /// Network sessions reject this API. True means the registration was
    /// accepted (including a compatible previous registration).
    /// </summary>
    public bool RegisterLocalEcsData(ulong schemaId, int size, int alignment) =>
        Ecs.RegisterLocalData(SessionId, schemaId, size, alignment) != 0;

    /// <summary>Count offline-only Flecs entities with this registered schema.</summary>
    public int CountLocalEcsData(ulong schemaId) =>
        Ecs.CountLocalData(SessionId, schemaId);

    /// <summary>
    /// Copy a page of packed native ECS data in one call. Bytes hold whole,
    /// sequential records of the registered component's size. Query ordering
    /// can change following ECS structural modifications.
    /// </summary>
    public int CopyLocalEcsDataPage(ulong schemaId, int offset,
        Span<ulong> entityIds, Span<byte> bytes) =>
        Ecs.CopyLocalDataPage(SessionId, schemaId, offset, entityIds, bytes);

    /// <summary>Count enabled native Flecs Rigidbody data components.</summary>
    public int RigidbodyEntityCount => Ecs.CountRigidbodies(SessionId);

    /// <summary>
    /// Copy one page of native Rigidbody masses in a single generated ABI
    /// call. IDs are Flecs entities, not GameObjects. Copy capacity is the
    /// shorter span; keep ECS structural membership stable between pages.
    /// </summary>
    public int CopyRigidbodyMasses(int offset, Span<ulong> entityIds,
        Span<float> masses) =>
        Ecs.CopyRigidbodyMasses(SessionId, offset, entityIds, masses);

    /// <summary>
    /// Full native Jolt ray hit: point, distance and collider GameObject.
    /// Normal is null until the native RaycastHit supplies a surface normal.
    /// </summary>
    public PhysicsHit? RaycastHit(Vector3 origin, Vector3 direction,
        float maxDistance, uint layerMask = uint.MaxValue) =>
        PhysicsHit.FromNative(SessionId,
            Physics.RaycastDetails(SessionId, origin, direction, maxDistance, layerMask));

    /// <summary>
    /// Full swept-sphere Jolt hit including normal, body ID and penetration.
    /// </summary>
    public PhysicsHit? SphereCastHit(Vector3 origin, float radius,
        Vector3 direction, float maxDistance, uint layerMask = uint.MaxValue) =>
        PhysicsHit.FromNative(SessionId,
            Physics.SphereCastDetails(SessionId, origin, radius,
                direction, maxDistance, layerMask));

    /// <summary>Closest Jolt ray contact, or null when nothing was hit.</summary>
    public PhysicsContact? Raycast(Vector3 origin, Vector3 direction,
        float maxDistance, uint layerMask = uint.MaxValue)
    {
        Vector4 result = Physics.RaycastContact(SessionId, origin,
            direction, maxDistance, layerMask);
        return result.W < 0 ? null :
            new PhysicsContact(new Vector3(result.X, result.Y, result.Z), result.W);
    }

    /// <summary>Native Jolt swept sphere contact, including initial overlaps.</summary>
    public PhysicsContact? SphereCast(Vector3 origin, float radius,
        Vector3 direction, float maxDistance, uint layerMask = uint.MaxValue)
    {
        Vector4 result = Physics.SphereCastContact(SessionId, origin,
            radius, direction, maxDistance, layerMask);
        return result.W < 0 ? null :
            new PhysicsContact(new Vector3(result.X, result.Y, result.Z), result.W);
    }

    /// <summary>Distance to the nearest Jolt hit, or -1 if no hit.</summary>
    public float RaycastDistance(Vector3 origin, Vector3 direction,
        float maxDistance, uint layerMask = uint.MaxValue) =>
        Physics.RaycastDistance(SessionId, origin, direction, maxDistance, layerMask);

    public GameObject CreateGameObject(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        ulong id = Engine.Bridge.CreateSceneObject(SessionId, name);
        return id != 0 ? new GameObject(SessionId, id) :
            throw new InvalidOperationException(
                "The scene is no longer active or the native object could not be created.");
    }

    /// <summary>Find the first object with this name (linear scene search).</summary>
    public GameObject? Find(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        ulong id = Engine.Bridge.FindSceneObject(SessionId, name);
        return id == 0 ? null : new GameObject(SessionId, id);
    }

    /// <summary>
    /// Instantiate a prefab with the native network ownership rules. A
    /// replicated prefab can return null on clients until the server spawns it.
    /// </summary>
    public GameObject? InstantiatePrefab(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        ulong id = Engine.Bridge.InstantiatePrefab(SessionId, path);
        return id == 0 ? null : new GameObject(SessionId, id);
    }

    /// <summary>Instantiates a prefab at a world position and rotation.</summary>
    public GameObject? InstantiatePrefab(string path, Vector3 position, Quaternion rotation)
    {
        ArgumentNullException.ThrowIfNull(path);
        ulong id = CSharpSceneObjects.InstantiatePrefabAt(SessionId, path, position, rotation);
        return id == 0 ? null : new GameObject(SessionId, id);
    }

    /// <summary>The first active object with that tag, or null.</summary>
    public GameObject? FindWithTag(string tag)
    {
        ArgumentNullException.ThrowIfNull(tag);
        ulong id = CSharpSceneObjects.FindWithTag(SessionId, tag);
        return id == 0 ? null : new GameObject(SessionId, id);
    }

    /// <summary>Every object with that tag, active or not.</summary>
    public GameObject[] FindAllWithTag(string tag)
    {
        ArgumentNullException.ThrowIfNull(tag);
        Span<ulong> ids = stackalloc ulong[64];
        int count = CSharpSceneObjects.FindAllWithTag(SessionId, tag, ids);
        if (count > ids.Length)
        {
            ids = new ulong[count];
            count = Math.Min(count, CSharpSceneObjects.FindAllWithTag(SessionId, tag, ids));
        }
        var found = new GameObject[Math.Max(count, 0)];
        for (int i = 0; i < found.Length; i++)
            found[i] = new GameObject(SessionId, ids[i]);
        return found;
    }

    /// <summary>Whether a network session (hosting or joined) is running.</summary>
    public bool IsNetworked => CSharpSceneObjects.NetworkRole(SessionId) != 0;
    /// <summary>True on the server or host, and in a game with no network session.</summary>
    public bool IsServer => CSharpSceneObjects.NetworkRole(SessionId) != 2;
    /// <summary>True on a machine that joined someone else's session.</summary>
    public bool IsClient => CSharpSceneObjects.NetworkRole(SessionId) == 2;
    /// <summary>This machine's client id in the session; 0 on the server or offline.</summary>
    public int LocalClientId => CSharpSceneObjects.LocalClientId(SessionId);
}

/// <summary>Native prefab instantiation; networking authority remains in Beef.</summary>
public static class Prefab
{
    public static GameObject? Instantiate(Scene scene, string path) =>
        scene.InstantiatePrefab(path);

    public static GameObject? Instantiate(Scene scene, string path,
        Vector3 position, Quaternion rotation) =>
        scene.InstantiatePrefab(path, position, rotation);
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
public sealed class Transform(GameObject gameObject) : IComponent
{
    /// <summary>The object this transform belongs to.</summary>
    public GameObject GameObject => gameObject;

    /// <summary>The parent's transform, or null at the top of the scene.</summary>
    public Transform? Parent => gameObject.Parent?.Transform;

    public bool SetParent(Transform? parent, bool keepWorldPose = true) =>
        gameObject.SetParent(parent?.GameObject, keepWorldPose);

    public int ChildCount => gameObject.ChildCount;

    public Transform? GetChild(int index) => gameObject.GetChild(index)?.Transform;

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
    Script? GetManagedInstance(GameObject gameObject, int instanceId);
    void Destroy(GameObject gameObject);
    bool IsMine(GameObject gameObject);
    ulong CreateSceneObject(ulong sceneSession, string name);
    ulong FindSceneObject(ulong sceneSession, string name);
    ulong InstantiatePrefab(ulong sceneSession, string path);
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
        public Script? GetManagedInstance(GameObject gameObject, int instanceId) => throw Missing();
        public void Destroy(GameObject gameObject) => throw Missing();
        public bool IsMine(GameObject gameObject) => throw Missing();
        public ulong CreateSceneObject(ulong sceneSession, string name) => throw Missing();
        public ulong FindSceneObject(ulong sceneSession, string name) => throw Missing();
        public ulong InstantiatePrefab(ulong sceneSession, string path) => throw Missing();
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
public abstract class Script : IComponent
{
    public GameObject GameObject { get; private set; }

    // The CLR ID of the specific native-owned component. It is NOT a Flecs
    // entity ID or GameObject.Id and is intentionally not a user API.
    internal int NativeInstanceId { get; private set; }
    private Transform? _transform;
    public Transform Transform => _transform ??= new Transform(GameObject);
    public bool IsMine => Engine.Bridge.IsMine(GameObject);
    public Scene Scene => GameObject.Scene;

    /// <summary>
    /// Calls one of this script's <see cref="RpcAttribute"/> methods: here and on every client
    /// (<see cref="RpcTarget.Everyone"/>), or on the server (<see cref="RpcTarget.Server"/>). The server may call
    /// any; a client only on an object it owns, and an Everyone call then runs on it when the server sends it
    /// back. Without a session it runs here at once. Use <c>nameof(Method)</c>.
    /// </summary>
    protected void Rpc(string method, params object?[] arguments)
    {
        RpcMethods.Entry entry = RpcMethods.Find(GetType(), method) ??
            throw new ArgumentException($"{GetType().Name}.{method} is not an [Rpc] method.", nameof(method));
        string encoded = RpcMethods.Encode(entry, arguments ?? []);
        int result = CSharpNetwork.SendRpc(GameObject.SceneId, GameObject.Id, RequireNativeInstance(),
            (int)entry.Target, method, encoded);
        if (result < 0)
            throw new InvalidOperationException(
                $"{method}: only the server, or the client that owns this object, can call its RPCs.");
        if (result > 0)
            RpcMethods.Run(this, entry, RpcMethods.Decode(entry, encoded, GameObject.SceneId), 0);
    }

    /// <summary>Inside an [Rpc] method: the client id of the machine that called it (0 for the server or this
    /// machine without a session).</summary>
    protected static int RpcSender => RpcMethods.CurrentSender;

    private int RequireNativeInstance() =>
        NativeInstanceId > 0 ? NativeInstanceId :
            throw new InvalidOperationException(
                "This Script is not attached to a live native Tallow component.");

    private static bool CheckedState(int state)
    {
        if (state < 0)
            throw new ObjectDisposedException(nameof(Script),
                "The native C# component or its scene is no longer alive.");
        return state != 0;
    }

    /// <summary>
    /// Controls the native Component.Enabled flag. Switching it while playing
    /// invokes the usual OnEnable/OnDisable and networking notifications.
    /// </summary>
    public bool Enabled
    {
        get => CheckedState(CSharpComponents.EnabledState(
            GameObject.SceneId, GameObject.Id, RequireNativeInstance()));
        set
        {
            if (!CSharpComponents.SetEnabled(
                    GameObject.SceneId, GameObject.Id, RequireNativeInstance(), value))
                throw new ObjectDisposedException(nameof(Script),
                    "The native C# component or its scene is no longer alive.");
        }
    }

    /// <summary>Native-enabled component on an active hierarchy object.</summary>
    public bool IsActiveAndEnabled => CheckedState(CSharpComponents.ActiveState(
        GameObject.SceneId, GameObject.Id, RequireNativeInstance()));

    /// <summary>
    /// Find a managed script or a native/ECS component through the same API.
    /// </summary>
    public T? GetComponent<T>() where T : IComponent => GameObject.GetComponent<T>();

    /// <summary>Find a component, returning false when it is not attached.</summary>
    public bool TryGetComponent<T>(out T component) where T : IComponent =>
        GameObject.TryGetComponent(out component);

    /// <summary>Add and return another managed gameplay component.</summary>
    public T AddComponent<T>() where T : Script => GameObject.AddComponent<T>();

    public ColliderHandle? GetCollider(int index = 0) => GameObject.GetCollider(index);
    public T? GetComponentInChildren<T>() where T : IComponent => GameObject.GetComponentInChildren<T>();
    public Animator? GetAnimator() => GameObject.GetAnimator();
    public int ColliderCount => GameObject.ColliderCount;
    public Joint? GetJoint() => GameObject.GetJoint();
    public CharacterController? GetCharacterController() => GameObject.GetCharacterController();
    public Rigidbody? GetRigidbody() => GameObject.GetRigidbody();
    public SoftBody? GetSoftBody() => GameObject.GetSoftBody();

    /// <summary>Called by Tallow's lifecycle dispatcher, not by gameplay scripts.</summary>
    public void Attach(GameObject gameObject)
    {
        GameObject = gameObject;
        NativeInstanceId = 0;
        _transform = new Transform(gameObject);
    }

    internal void AttachNative(GameObject gameObject, int instanceId)
    {
        Attach(gameObject);
        NativeInstanceId = instanceId;
    }

    internal void InvalidateNative()
    {
        NativeInstanceId = 0;
        _destroyed?.Cancel();
    }

    private CancellationTokenSource? _destroyed;

    /// <summary>Cancelled when this script is destroyed (its object destroyed, the scene unloaded, Play
    /// stopped). <see cref="Wait"/> and <see cref="NextFrame"/> use it already; pass it to Task.Delay and other
    /// async work so it ends with the script.</summary>
    public CancellationToken Destroyed
    {
        get
        {
            if (_destroyed == null)
            {
                _destroyed = new CancellationTokenSource();
                if (NativeInstanceId == 0)
                    _destroyed.Cancel();
            }
            return _destroyed.Token;
        }
    }

    /// <summary><c>await NextFrame();</c> carries on next frame, after LateUpdate. Ends (cancelled) if the
    /// script is destroyed first.</summary>
    protected Task NextFrame() => GameThread.Delay(0f, Destroyed);

    /// <summary><c>await Wait(2f);</c> carries on after that many seconds of game time (slowed and paused with
    /// it), after LateUpdate. Ends (cancelled) if the script is destroyed first. Task.Delay waits real time.</summary>
    protected Task Wait(float seconds) => GameThread.Delay(seconds, Destroyed);

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
    /// <summary>This object's body began touching another's, after the physics step of a tick. Called once per
    /// pair of objects, on both. Runs on every machine that simulates the tick: check
    /// <see cref="Scene.IsServer"/> before changing authoritative state.</summary>
    public virtual void OnCollisionEnter(Collision collision) { }
    /// <summary>Every physics step after <see cref="OnCollisionEnter"/> while the two still touch and either is
    /// awake (not while both sleep).</summary>
    public virtual void OnCollisionStay(Collision collision) { }
    /// <summary>The two stopped touching. <c>collision.GameObject</c> is not valid when the other was destroyed.</summary>
    public virtual void OnCollisionExit(Collision collision) { }
    /// <summary>Something entered this object's trigger collider, or this object entered another's trigger.</summary>
    public virtual void OnTriggerEnter(GameObject other) { }
    /// <summary>This object's CharacterController ran into something while moving (the ground it walks on too),
    /// once per thing per move. Not called during network prediction replays.</summary>
    public virtual void OnControllerHit(ControllerHit hit) { }
    /// <summary>Every physics step while <paramref name="other"/> is inside the trigger and awake.</summary>
    public virtual void OnTriggerStay(GameObject other) { }
    /// <summary>It left the trigger. <paramref name="other"/> is not valid when it was destroyed.</summary>
    public virtual void OnTriggerExit(GameObject other) { }
    /// <summary>Once a frame, after the scene's frame work (streaming, effects): on this machine only.</summary>
    public virtual void OnFrame() { }
    /// <summary>A field was changed in the Inspector during Play (or by the scene loader).</summary>
    public virtual void OnValidate() { }
    /// <summary>Draw helpers in the editor's Scene view with <see cref="Gizmos"/>, every frame during Play.
    /// <paramref name="selected"/> is true when this object is selected.</summary>
    public virtual void OnDrawGizmos(bool selected) { }
    /// <summary>The game is about to be saved: bring <see cref="SavedAttribute"/> fields up to date.</summary>
    public virtual void OnSaving() { }
    /// <summary>A save was just loaded and the <see cref="SavedAttribute"/> fields were put back: rebuild
    /// anything made from them.</summary>
    public virtual void OnLoaded() { }
    /// <summary>Called on every machine when <see cref="SendNetworkEvent"/> is used on this script.</summary>
    public virtual void OnNetworkEvent(string name, float value) { }

    /// <summary>
    /// Tells this script on every machine that something happened (a sound, an effect): calls
    /// <see cref="OnNetworkEvent"/> there. Allowed from the server, or from the client that owns the object;
    /// without a session it simply calls it here. The name is at most 64 characters. For calls with
    /// arguments, use an <see cref="RpcAttribute"/> method.
    /// </summary>
    public void SendNetworkEvent(string name, float value = 0f)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (CSharpNetwork.SendEvent(GameObject.SceneId, GameObject.Id, RequireNativeInstance(), name, value) < 0)
            throw new InvalidOperationException($"SendNetworkEvent({name}): this script is not running.");
    }
}
