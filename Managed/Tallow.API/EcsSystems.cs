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
        // Entities clients own run with their owners' controls, one at a time.
        Span<ulong> owned = stackalloc ulong[64];
        int ownedCount = Ecs.ClientOwned(session, owned);
        if (ownedCount > owned.Length)
        {
            owned = new ulong[ownedCount];
            ownedCount = Math.Min(ownedCount, Ecs.ClientOwned(session, owned));
        }
        ulong[]? skip = ownedCount == 0 ? null : owned[..ownedCount].ToArray();
        new EcsQuery<T>(session) { BareOnly = true }.ForEach((EcsEntity e, ref T data) =>
        {
            if (skip != null && Array.IndexOf(skip, e.Id) >= 0)
                return;
            Update(e, ref data, input, deltaTime);
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
