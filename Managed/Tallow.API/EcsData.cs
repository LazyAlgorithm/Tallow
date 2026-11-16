using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Tallow;

/// <summary>
/// Ties each C# <c>[Component]</c> struct to the schema id the build gave its layout. The build's generated code
/// registers every one when the game assembly loads; scripts never need to call this.
/// </summary>
public static class EcsSchemas
{
    public static void Register<T>(ulong schemaId) where T : unmanaged => EcsSchema<T>.Id = schemaId;

    /// <summary>Generated: ties T to its schema and tells the engine its [Sync] fields ("name:offset:size;" each),
    /// so that a server sends them to clients.</summary>
    public static void Register<T>(ulong schemaId, string name, string syncFields) where T : unmanaged
    {
        EcsSchema<T>.Id = schemaId;
        // Generated module initializers run on load, before any engine call is possible in a host with no engine.
        if (GeneratedNativeApi.IsBound)
            Ecs.DescribeData(schemaId, name, Unsafe.SizeOf<T>(), 1, syncFields);
    }
}

internal static class EcsSchema<T> where T : unmanaged
{
    internal static ulong Id;

    internal static ulong Require() => Id != 0 ? Id : throw new InvalidOperationException(
        $"{typeof(T).Name} is not an ECS data component. Mark the struct [Component] (fields of bool, int, uint, " +
        "long, ulong, float, double, Vector2/3/4 or Quaternion), and build.");

    /// <summary>Registers the layout in the scene (once per scene; false outside a playing game).</summary>
    internal static bool Ensure(ulong session) =>
        Ecs.RegisterLocalData(session, Require(), Unsafe.SizeOf<T>(), 1) != 0;
}

public readonly partial record struct EcsEntity
{
    /// <summary>
    /// Gives this entity a C# <c>[Component]</c> struct's data (or replaces it). Works on bare entities
    /// (<see cref="Scene.CreateLocalEcsEntity"/>) and on GameObjects (<see cref="GameObject.Entity"/>), in an
    /// playing scene. False when the entity has gone.
    /// </summary>
    public bool Set<T>(in T value) where T : unmanaged
    {
        if (Id == 0 || !EcsSchema<T>.Ensure(SessionId))
            return false;
        T copy = value;
        return Ecs.SetLocalData(SessionId, Id, EcsSchema<T>.Id,
            MemoryMarshal.AsBytes(MemoryMarshal.CreateSpan(ref copy, 1)));
    }

    /// <summary>Reads this entity's data of type T; false (and default) when it has none.</summary>
    public bool TryGet<T>(out T value) where T : unmanaged
    {
        value = default;
        return Id != 0 && Ecs.CopyLocalData(SessionId, Id, EcsSchema<T>.Require(),
            MemoryMarshal.AsBytes(MemoryMarshal.CreateSpan(ref value, 1)));
    }

    /// <summary>This entity's data of type T; throws when it has none.</summary>
    public T Get<T>() where T : unmanaged => TryGet(out T value) ? value :
        throw new InvalidOperationException($"The entity has no {typeof(T).Name}.");

    public bool Has<T>() where T : unmanaged => Id != 0 && Ecs.HasLocalData(SessionId, Id, EcsSchema<T>.Require());

    /// <summary>Takes this entity's data of type T away; false when it had none.</summary>
    public bool Remove<T>() where T : unmanaged =>
        Id != 0 && Ecs.RemoveLocalData(SessionId, Id, EcsSchema<T>.Require());

    /// <summary>The GameObject this entity belongs to, or null for a bare entity.</summary>
    public GameObject? GameObject
    {
        get
        {
            ulong objectId = Id == 0 ? 0 : Ecs.ObjectOfEntity(SessionId, Id);
            return objectId != 0 ? new GameObject(SessionId, objectId) : null;
        }
    }
}

public readonly partial record struct GameObject
{
    /// <summary>
    /// This object's ECS entity, to give it C# <c>[Component]</c> data (<see cref="EcsEntity.Set{T}"/>) that
    /// <see cref="Scene.Query{T1}"/> finds. The data goes when the object does, and is not saved with the scene.
    /// </summary>
    public EcsEntity Entity => new(SceneId, IsValid ? Ecs.EntityOfObject(SceneId, Id) : 0);
}

/// <summary>A query's With and Without terms (up to <see cref="Capacity"/>), kept without allocating.</summary>
public readonly record struct EcsFilter
{
    public const int Capacity = 4;
    private readonly ulong _a, _b, _c, _d;
    private readonly int _with, _without;

    private EcsFilter(ulong a, ulong b, ulong c, ulong d, int with, int without) =>
        (_a, _b, _c, _d, _with, _without) = (a, b, c, d, with, without);

    public int Count => _with + _without;

    internal EcsFilter Add(ulong schema, bool with)
    {
        if (Count == Capacity)
            throw new InvalidOperationException($"A query can have at most {Capacity} With and Without terms.");
        Span<ulong> ids = [_a, _b, _c, _d];
        // With terms first, then Without.
        if (with)
        {
            for (int i = Count; i > _with; i--)
                ids[i] = ids[i - 1];
            ids[_with] = schema;
        }
        else
            ids[Count] = schema;
        return new EcsFilter(ids[0], ids[1], ids[2], ids[3], _with + (with ? 1 : 0), _without + (with ? 0 : 1));
    }

    internal void Split(Span<ulong> buffer, out Span<ulong> with, out Span<ulong> without)
    {
        buffer[0] = _a;
        buffer[1] = _b;
        buffer[2] = _c;
        buffer[3] = _d;
        with = buffer[.._with];
        without = buffer.Slice(_with, _without);
    }
}

public delegate void EcsAction<T1>(EcsEntity entity, ref T1 a);
public delegate void EcsAction<T1, T2>(EcsEntity entity, ref T1 a, ref T2 b);
public delegate void EcsAction<T1, T2, T3>(EcsEntity entity, ref T1 a, ref T2 b, ref T3 c);

public readonly partial record struct Scene
{
    /// <summary>The entities (bare ones and GameObjects) with T1's data.</summary>
    public EcsQuery<T1> Query<T1>() where T1 : unmanaged => new(SessionId);

    /// <summary>The entities with both T1's and T2's data.</summary>
    public EcsQuery<T1, T2> Query<T1, T2>() where T1 : unmanaged where T2 : unmanaged => new(SessionId);

    /// <summary>The entities with T1's, T2's and T3's data.</summary>
    public EcsQuery<T1, T2, T3> Query<T1, T2, T3>()
        where T1 : unmanaged where T2 : unmanaged where T3 : unmanaged => new(SessionId);
}

/// <summary>
/// The entities that have every one of a query's data components. <c>ForEach</c> works on their data in place, table
/// by table, as native ECS systems do: the refs it gives the action are the entity's own data, so writing through
/// them is the whole cost of a change.
/// <para>While it runs, <see cref="EcsEntity.Set{T}"/> of data an entity already has writes at once (as the ref
/// does). Changes to which data entities have (<c>Set</c> of data an entity lacks, <see cref="EcsEntity.Remove{T}"/>,
/// creating and destroying bare entities) are queued and happen when it ends, in the order made, so
/// <see cref="EcsEntity.Has{T}"/> and <see cref="EcsEntity.Get{T}"/> do not see them until then. GameObjects made,
/// changed or destroyed in it work at once. Entities made during it are visited next time.</para>
/// </summary>
public readonly record struct EcsQuery<T1>(ulong SessionId) where T1 : unmanaged
{
    /// <summary>Only entities that also have F's data (not read or written).</summary>
    public EcsQuery<T1> With<F>() where F : unmanaged => this with { Filter = Filter.Add(EcsSchema<F>.Require(), true) };

    /// <summary>Only entities without F's data.</summary>
    public EcsQuery<T1> Without<F>() where F : unmanaged => this with { Filter = Filter.Add(EcsSchema<F>.Require(), false) };

    /// <summary>The <see cref="With{F}"/> and <see cref="Without{F}"/> terms so far.</summary>
    public EcsFilter Filter { get; init; }

    /// <summary>Only bare entities, not GameObjects' (what systems run on).</summary>
    internal bool BareOnly { get; init; }

    public int Count
    {
        get
        {
            Span<ulong> schemas = [EcsSchema<T1>.Require()];
            Span<ulong> filters = stackalloc ulong[EcsFilter.Capacity];
            Filter.Split(filters, out Span<ulong> with, out Span<ulong> without);
            return Ecs.CountData(SessionId, schemas, with, without);
        }
    }

    public unsafe void ForEach(EcsAction<T1> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        Span<ulong> schemas = [EcsSchema<T1>.Require()];
        Span<ulong> filters = stackalloc ulong[EcsFilter.Capacity];
        Filter.Split(filters, out Span<ulong> with, out Span<ulong> without);
        int handle = Ecs.BeginDataIteration(SessionId, schemas, with, without, BareOnly ? 1 : 0);
        if (handle <= 0)
            return;
        try
        {
            Span<ulong> columns = stackalloc ulong[3];
            int count;
            while ((count = Ecs.NextDataTable(SessionId, handle, columns)) > 0)
            {
                T1* a = (T1*)columns[0];
                ulong* ids = (ulong*)columns[1];
                uint* version = (uint*)columns[2];
                uint seen = *version;
                for (int i = 0; i < count; i++)
                {
                    if (*version != seen)
                    {
                        // The engine moved rows of this table (an object destroyed or changed in the action).
                        count = Ecs.RefreshDataTable(SessionId, handle, columns);
                        if (i >= count)
                            break;
                        a = (T1*)columns[0];
                        ids = (ulong*)columns[1];
                        version = (uint*)columns[2];
                        seen = *version;
                    }
                    action(new EcsEntity(SessionId, ids[i]), ref a[i]);
                }
            }
        }
        finally
        {
            Ecs.EndDataIteration(SessionId, handle);
        }
    }
}

/// <inheritdoc cref="EcsQuery{T1}"/>
public readonly record struct EcsQuery<T1, T2>(ulong SessionId) where T1 : unmanaged where T2 : unmanaged
{
    /// <summary>Only entities that also have F's data (not read or written).</summary>
    public EcsQuery<T1, T2> With<F>() where F : unmanaged => this with { Filter = Filter.Add(EcsSchema<F>.Require(), true) };

    /// <summary>Only entities without F's data.</summary>
    public EcsQuery<T1, T2> Without<F>() where F : unmanaged => this with { Filter = Filter.Add(EcsSchema<F>.Require(), false) };

    /// <summary>The <see cref="With{F}"/> and <see cref="Without{F}"/> terms so far.</summary>
    public EcsFilter Filter { get; init; }

    /// <summary>Only bare entities, not GameObjects' (what systems run on).</summary>
    internal bool BareOnly { get; init; }

    public int Count
    {
        get
        {
            Span<ulong> schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require()];
            Span<ulong> filters = stackalloc ulong[EcsFilter.Capacity];
            Filter.Split(filters, out Span<ulong> with, out Span<ulong> without);
            return Ecs.CountData(SessionId, schemas, with, without);
        }
    }

    public unsafe void ForEach(EcsAction<T1, T2> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        Span<ulong> schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require()];
        Span<ulong> filters = stackalloc ulong[EcsFilter.Capacity];
        Filter.Split(filters, out Span<ulong> with, out Span<ulong> without);
        int handle = Ecs.BeginDataIteration(SessionId, schemas, with, without, BareOnly ? 1 : 0);
        if (handle <= 0)
            return;
        try
        {
            Span<ulong> columns = stackalloc ulong[4];
            int count;
            while ((count = Ecs.NextDataTable(SessionId, handle, columns)) > 0)
            {
                T1* a = (T1*)columns[0];
                T2* b = (T2*)columns[1];
                ulong* ids = (ulong*)columns[2];
                uint* version = (uint*)columns[3];
                uint seen = *version;
                for (int i = 0; i < count; i++)
                {
                    if (*version != seen)
                    {
                        // The engine moved rows of this table (an object destroyed or changed in the action).
                        count = Ecs.RefreshDataTable(SessionId, handle, columns);
                        if (i >= count)
                            break;
                        a = (T1*)columns[0];
                        b = (T2*)columns[1];
                        ids = (ulong*)columns[2];
                        version = (uint*)columns[3];
                        seen = *version;
                    }
                    action(new EcsEntity(SessionId, ids[i]), ref a[i], ref b[i]);
                }
            }
        }
        finally
        {
            Ecs.EndDataIteration(SessionId, handle);
        }
    }
}

/// <inheritdoc cref="EcsQuery{T1}"/>
public readonly record struct EcsQuery<T1, T2, T3>(ulong SessionId)
    where T1 : unmanaged where T2 : unmanaged where T3 : unmanaged
{
    /// <summary>Only entities that also have F's data (not read or written).</summary>
    public EcsQuery<T1, T2, T3> With<F>() where F : unmanaged => this with { Filter = Filter.Add(EcsSchema<F>.Require(), true) };

    /// <summary>Only entities without F's data.</summary>
    public EcsQuery<T1, T2, T3> Without<F>() where F : unmanaged => this with { Filter = Filter.Add(EcsSchema<F>.Require(), false) };

    /// <summary>The <see cref="With{F}"/> and <see cref="Without{F}"/> terms so far.</summary>
    public EcsFilter Filter { get; init; }

    /// <summary>Only bare entities, not GameObjects' (what systems run on).</summary>
    internal bool BareOnly { get; init; }

    public int Count
    {
        get
        {
            Span<ulong> schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require(), EcsSchema<T3>.Require()];
            Span<ulong> filters = stackalloc ulong[EcsFilter.Capacity];
            Filter.Split(filters, out Span<ulong> with, out Span<ulong> without);
            return Ecs.CountData(SessionId, schemas, with, without);
        }
    }

    public unsafe void ForEach(EcsAction<T1, T2, T3> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        Span<ulong> schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require(), EcsSchema<T3>.Require()];
        Span<ulong> filters = stackalloc ulong[EcsFilter.Capacity];
        Filter.Split(filters, out Span<ulong> with, out Span<ulong> without);
        int handle = Ecs.BeginDataIteration(SessionId, schemas, with, without, BareOnly ? 1 : 0);
        if (handle <= 0)
            return;
        try
        {
            Span<ulong> columns = stackalloc ulong[5];
            int count;
            while ((count = Ecs.NextDataTable(SessionId, handle, columns)) > 0)
            {
                T1* a = (T1*)columns[0];
                T2* b = (T2*)columns[1];
                T3* c = (T3*)columns[2];
                ulong* ids = (ulong*)columns[3];
                uint* version = (uint*)columns[4];
                uint seen = *version;
                for (int i = 0; i < count; i++)
                {
                    if (*version != seen)
                    {
                        // The engine moved rows of this table (an object destroyed or changed in the action).
                        count = Ecs.RefreshDataTable(SessionId, handle, columns);
                        if (i >= count)
                            break;
                        a = (T1*)columns[0];
                        b = (T2*)columns[1];
                        c = (T3*)columns[2];
                        ids = (ulong*)columns[3];
                        version = (uint*)columns[4];
                        seen = *version;
                    }
                    action(new EcsEntity(SessionId, ids[i]), ref a[i], ref b[i], ref c[i]);
                }
            }
        }
        finally
        {
            Ecs.EndDataIteration(SessionId, handle);
        }
    }
}
