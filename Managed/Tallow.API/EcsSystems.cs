using System.Runtime.InteropServices;

namespace Tallow;

/// <summary>
/// Game code that advances one bare ECS entity's <typeparamref name="T"/> data by one tick, from that tick's controls.
/// Derive from it (the build finds the class; no attribute needed) and the engine runs it every fixed tick, before
/// scripts' Update:
/// <list type="bullet">
/// <item>offline, on every bare entity with the data, with this machine's controls;</item>
/// <item>on the server, on its own bare entities, and on each one a client owns
/// (<see cref="EcsEntity.SetOwner"/>) with that client's controls, as they arrive;</item>
/// <item>on a client, only on the entities it owns, at once, with its own controls (prediction). Where the server's
/// state for a tick differs from what it predicted, the client takes the server's and runs its controls since again.</item>
/// </list>
/// Update must depend only on the entity it is given (its data, the controls and the delta time): not on other
/// entities, wall-clock time or Input. Only <c>[Sync]</c> fields are put right by the server. GameObjects' entities are
/// not run.
/// </summary>
public abstract class EcsSystem<T> : EcsSystemBase where T : unmanaged
{
    public abstract void Update(EcsEntity entity, ref T data, TickInput input, float deltaTime);

    internal override ulong SchemaId => EcsSchema<T>.Require();

    internal override void Run(ulong session, ulong entity, TickInput input, float deltaTime)
    {
        if (entity != 0)
        {
            var one = new EcsEntity(session, entity);
            if (!one.TryGet(out T data))
                return;
            Update(one, ref data, input, deltaTime);
            one.Set(data);
            return;
        }
        ulong[]? skip = ClientOwned(session);
        new EcsQuery<T>(session) { BareOnly = true }.ForEach((EcsEntity e, ref T data) =>
        {
            if (skip != null && Array.IndexOf(skip, e.Id) >= 0)
                return;
            Update(e, ref data, input, deltaTime);
        });
    }
}

/// <summary>
/// As <see cref="EcsSystem{T}"/>, for bare entities with both <typeparamref name="T1"/> and <typeparamref name="T2"/>
/// data (entities with only one are left alone). Ownership and prediction go by <typeparamref name="T1"/>, so give it
/// the <c>[Sync]</c> fields.
/// </summary>
public abstract class EcsSystem<T1, T2> : EcsSystemBase where T1 : unmanaged where T2 : unmanaged
{
    public abstract void Update(EcsEntity entity, ref T1 a, ref T2 b, TickInput input, float deltaTime);

    internal override ulong SchemaId
    {
        get
        {
            EcsSchema<T2>.Require();
            return EcsSchema<T1>.Require();
        }
    }

    internal override void Run(ulong session, ulong entity, TickInput input, float deltaTime)
    {
        if (entity != 0)
        {
            var one = new EcsEntity(session, entity);
            if (!one.TryGet(out T1 a) || !one.TryGet(out T2 b))
                return;
            Update(one, ref a, ref b, input, deltaTime);
            one.Set(a);
            one.Set(b);
            return;
        }
        ulong[]? skip = ClientOwned(session);
        new EcsQuery<T1, T2>(session) { BareOnly = true }.ForEach((EcsEntity e, ref T1 a, ref T2 b) =>
        {
            if (skip != null && Array.IndexOf(skip, e.Id) >= 0)
                return;
            Update(e, ref a, ref b, input, deltaTime);
        });
    }
}

/// <summary>What the engine runs: an <see cref="EcsSystem{T}"/>.</summary>
public abstract class EcsSystemBase
{
    /// <summary>Systems run by Order, then by full name.</summary>
    public virtual int Order => 0;

    internal abstract ulong SchemaId { get; }
    internal abstract void Run(ulong session, ulong entity, TickInput input, float deltaTime);

    /// <summary>The entities clients own (they run with their owners' controls, one at a time), or null for none.</summary>
    private protected static ulong[]? ClientOwned(ulong session)
    {
        Span<ulong> owned = stackalloc ulong[64];
        int count = Ecs.ClientOwned(session, owned);
        if (count > owned.Length)
        {
            owned = new ulong[count];
            count = Math.Min(count, Ecs.ClientOwned(session, owned));
        }
        return count == 0 ? null : owned[..count].ToArray();
    }
}

/// <summary>The game's systems, registered by generated code when its assembly loads.</summary>
public static class EcsSystems
{
    private static readonly List<EcsSystemBase> sSystems = [];

    /// <summary>Generated: a system the build found.</summary>
    public static void Register(EcsSystemBase system, string name)
    {
        ArgumentNullException.ThrowIfNull(system);
        sSystems.Add(system);
        if (GeneratedNativeApi.IsBound)
            Ecs.DescribeSystem(sSystems.Count - 1, name, system.Order, system.SchemaId);
    }

    internal static void Run(int index, ulong session, ulong entity, TickInput input, float deltaTime)
    {
        if ((uint)index >= (uint)sSystems.Count)
            throw new InvalidOperationException($"No ECS system {index}.");
        sSystems[index].Run(session, entity, input, deltaTime);
    }

    /// <summary>The game assembly is unloading: its systems must not keep it alive.</summary>
    internal static void Clear() => sSystems.Clear();
}

public readonly partial record struct EcsEntity
{
    /// <summary>
    /// Server: gives this bare entity to a client (0: back to the server). Its <see cref="EcsSystem{T}"/>s then run on
    /// that client at once (prediction) and on the server with that client's controls. False when it cannot (not the
    /// server, not a bare entity this game made, or it has no <c>[Sync]</c> data yet).
    /// </summary>
    public bool SetOwner(int clientId) => Id != 0 && Ecs.SetOwner(SessionId, Id, clientId);

    /// <summary>The client whose controls run this entity; 0 for the server's (and offline).</summary>
    public int OwnerClientId => Id == 0 ? 0 : Ecs.OwnerOf(SessionId, Id);

    /// <summary>Whether this machine's controls run it: a client's own entities, the server's (and offline) the rest.</summary>
    public bool IsMine
    {
        get
        {
            int owner = OwnerClientId;
            int role = CSharpSceneObjects.NetworkRole(SessionId);
            return role == 2 ? owner != 0 && owner == new Scene(SessionId).LocalClientId : owner == 0;
        }
    }
}
