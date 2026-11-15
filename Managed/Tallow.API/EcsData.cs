using System.Buffers;
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
}

internal static class EcsSchema<T> where T : unmanaged
{
    internal static ulong Id;

    internal static ulong Require() => Id != 0 ? Id : throw new InvalidOperationException(
        $"{typeof(T).Name} is not an ECS data component. Mark the struct [Component] (fields of bool, int, uint, " +
        "long, ulong, float, double, Vector2/3/4 or Quaternion), and build.");

    /// <summary>Registers the layout in the scene (once per scene; false outside an offline game).</summary>
    internal static bool Ensure(ulong session) =>
        Ecs.RegisterLocalData(session, Require(), Unsafe.SizeOf<T>(), 1) != 0;
}

public readonly partial record struct EcsEntity
{
    /// <summary>
    /// Gives this entity a C# <c>[Component]</c> struct's data (or replaces it). Works on bare entities
    /// (<see cref="Scene.CreateLocalEcsEntity"/>) and on GameObjects (<see cref="GameObject.Entity"/>), in an
    /// offline game. False when the entity has gone.
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
/// The entities that have every one of a query's data components. <c>ForEach</c> visits the ones that match when
/// it starts, copying their data out in pages and writing back after it the rows whose data the action changed
/// through its refs (a row left alone keeps whatever <see cref="EcsEntity.Set{T}"/> gave it meanwhile).
/// The action may create and destroy entities and add or remove data: one that has gone or lost a component by the
/// end is not written back, and new ones are visited next time.
/// </summary>
public readonly record struct EcsQuery<T1>(ulong SessionId) where T1 : unmanaged
{
    public int Count
    {
        get
        {
            Span<ulong> schemas = [EcsSchema<T1>.Require()];
            return Ecs.CountData(SessionId, schemas);
        }
    }

    public void ForEach(EcsAction<T1> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        ulong[] schemas = [EcsSchema<T1>.Require()];
        int size1 = Unsafe.SizeOf<T1>();
        using EcsRows rows = EcsRows.Read(SessionId, schemas, size1);
        for (int i = 0; i < rows.Count; i++)
        {
            ref byte row = ref rows.Row(i);
            T1 a = Unsafe.ReadUnaligned<T1>(ref row);
            action(new EcsEntity(SessionId, rows.Ids[i]), ref a);
            if (EcsRows.Store(ref row, a))
                rows.Changed(i);
        }
        rows.WriteBack();
    }
}

/// <inheritdoc cref="EcsQuery{T1}"/>
public readonly record struct EcsQuery<T1, T2>(ulong SessionId) where T1 : unmanaged where T2 : unmanaged
{
    public int Count
    {
        get
        {
            Span<ulong> schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require()];
            return Ecs.CountData(SessionId, schemas);
        }
    }

    public void ForEach(EcsAction<T1, T2> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        ulong[] schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require()];
        int size1 = Unsafe.SizeOf<T1>();
        using EcsRows rows = EcsRows.Read(SessionId, schemas, size1 + Unsafe.SizeOf<T2>());
        for (int i = 0; i < rows.Count; i++)
        {
            ref byte row = ref rows.Row(i);
            T1 a = Unsafe.ReadUnaligned<T1>(ref row);
            T2 b = Unsafe.ReadUnaligned<T2>(ref Unsafe.Add(ref row, size1));
            action(new EcsEntity(SessionId, rows.Ids[i]), ref a, ref b);
            if (EcsRows.Store(ref row, a) | EcsRows.Store(ref Unsafe.Add(ref row, size1), b))
                rows.Changed(i);
        }
        rows.WriteBack();
    }
}

/// <inheritdoc cref="EcsQuery{T1}"/>
public readonly record struct EcsQuery<T1, T2, T3>(ulong SessionId)
    where T1 : unmanaged where T2 : unmanaged where T3 : unmanaged
{
    public int Count
    {
        get
        {
            Span<ulong> schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require(), EcsSchema<T3>.Require()];
            return Ecs.CountData(SessionId, schemas);
        }
    }

    public void ForEach(EcsAction<T1, T2, T3> action)
    {
        ArgumentNullException.ThrowIfNull(action);
        ulong[] schemas = [EcsSchema<T1>.Require(), EcsSchema<T2>.Require(), EcsSchema<T3>.Require()];
        int size1 = Unsafe.SizeOf<T1>(), size2 = Unsafe.SizeOf<T2>();
        using EcsRows rows = EcsRows.Read(SessionId, schemas, size1 + size2 + Unsafe.SizeOf<T3>());
        for (int i = 0; i < rows.Count; i++)
        {
            ref byte row = ref rows.Row(i);
            T1 a = Unsafe.ReadUnaligned<T1>(ref row);
            T2 b = Unsafe.ReadUnaligned<T2>(ref Unsafe.Add(ref row, size1));
            T3 c = Unsafe.ReadUnaligned<T3>(ref Unsafe.Add(ref row, size1 + size2));
            action(new EcsEntity(SessionId, rows.Ids[i]), ref a, ref b, ref c);
            if (EcsRows.Store(ref row, a) | EcsRows.Store(ref Unsafe.Add(ref row, size1), b) |
                EcsRows.Store(ref Unsafe.Add(ref row, size1 + size2), c))
                rows.Changed(i);
        }
        rows.WriteBack();
    }
}

/// <summary>
/// The matches of a query copied out of the native ECS: ids, and per entity one row of its records one after
/// another. Pooled buffers; pages stay within the native limits (4096 entities, 4 MB).
/// </summary>
internal sealed class EcsRows : IDisposable
{
    private readonly ulong _session;
    private readonly ulong[] _schemas;
    private readonly int _rowSize;
    private byte[] _bytes;
    public ulong[] Ids { get; private set; }
    public int Count { get; private set; }

    private EcsRows(ulong session, ulong[] schemas, int rowSize, int capacity)
    {
        _session = session;
        _schemas = schemas;
        _rowSize = rowSize;
        Ids = ArrayPool<ulong>.Shared.Rent(Math.Max(capacity, 1));
        _bytes = ArrayPool<byte>.Shared.Rent(Math.Max(capacity * rowSize, 1));
    }

    private int PageRows => Math.Max(1, Math.Min(4096, 4 * 1024 * 1024 / _rowSize));

    public static EcsRows Read(ulong session, ulong[] schemas, int rowSize)
    {
        int total = Ecs.CountData(session, schemas);
        var rows = new EcsRows(session, schemas, rowSize, total);
        while (rows.Count < total)
        {
            int want = Math.Min(rows.PageRows, total - rows.Count);
            int got = Ecs.CopyDataPage(session, schemas, rows.Count, rows.Ids.AsSpan(rows.Count, want),
                rows._bytes.AsSpan(rows.Count * rowSize, want * rowSize));
            if (got <= 0)
                break;
            rows.Count += got;
        }
        return rows;
    }

    public ref byte Row(int index) => ref _bytes[index * _rowSize];

    // Rows changed so far are moved to the front, in order: row Changed(i) goes to _changed (always <= i).
    private int _changed;

    public void Changed(int index)
    {
        if (index != _changed)
        {
            Ids[_changed] = Ids[index];
            _bytes.AsSpan(index * _rowSize, _rowSize).CopyTo(_bytes.AsSpan(_changed * _rowSize, _rowSize));
        }
        _changed++;
    }

    /// <summary>Writes the value over the bytes at <paramref name="at"/>; true when they were different.</summary>
    public static bool Store<T>(ref byte at, T value) where T : unmanaged
    {
        ReadOnlySpan<byte> now = MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(ref value, 1));
        if (now.SequenceEqual(MemoryMarshal.CreateReadOnlySpan(ref at, now.Length)))
            return false;
        Unsafe.WriteUnaligned(ref at, value);
        return true;
    }

    /// <summary>Writes the changed rows back (call once, after the last row).</summary>
    public void WriteBack()
    {
        for (int at = 0; at < _changed; at += PageRows)
        {
            int count = Math.Min(PageRows, _changed - at);
            Ecs.WriteDataPage(_session, _schemas, Ids.AsSpan(at, count), _bytes.AsSpan(at * _rowSize, count * _rowSize));
        }
    }

    public void Dispose()
    {
        ArrayPool<ulong>.Shared.Return(Ids);
        ArrayPool<byte>.Shared.Return(_bytes);
        Ids = [];
        _bytes = [];
        Count = 0;
    }
}
