using System.Numerics;

namespace Tallow;

/// <summary>
/// Network prefabs. A prefab file whose root has a Network Identity is shared: <c>Scene.Spawn</c> (or
/// <see cref="Prefab.Instantiate(Scene, string)"/>) on the server makes it on every machine. Register a short name
/// for a prefab file once at startup, with the same names on the server and clients.
/// </summary>
public static class Network
{
    /// <summary>Names a prefab file for Spawn and for a Network Session's player prefab.</summary>
    public static void RegisterPrefab(string name, string prefabPath)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        ArgumentException.ThrowIfNullOrEmpty(prefabPath);
        if (!CSharpNetwork.RegisterPrefabFile(name, prefabPath))
            throw new ArgumentException("A network prefab name or path is too long.");
    }

    private static Func<int, int>? sChooseTeam;

    /// <summary>
    /// Server only: picks a joining player's team from their client id (0 or more), instead of the Network Session's
    /// team count sharing players out evenly. Null (the default) leaves that to the session. Set it once at startup,
    /// for example in a game manager's Awake.
    /// </summary>
    public static Func<int, int>? ChooseTeam
    {
        get => sChooseTeam;
        set
        {
            sChooseTeam = value;
            CSharpNetwork.SetTeamChooser(value != null);
        }
    }

    internal static int InvokeTeamChooser(int clientId)
    {
        if (sChooseTeam == null)
            return -1;
        int team = sChooseTeam(clientId);
        if (team < 0)
            throw new InvalidOperationException($"Network.ChooseTeam gave team {team} for client {clientId}; teams are 0 or more.");
        return team;
    }

    internal static void ClearTeamChooser() => sChooseTeam = null;

    public static bool IsRegistered(string name) => !string.IsNullOrEmpty(name) && CSharpNetwork.IsPrefabRegistered(name);

    /// <summary>
    /// What a scene's session shares, for tests and debugging. The first line is "offline" or
    /// "role=host|client connected=0|1 clients=N shared=N"; then "NETPOS id x y z name" per shared object, the
    /// session's own description, and "VOXEL id indices name" per voxel object.
    /// </summary>
    public static string Report(Scene scene)
    {
        byte[] buffer = new byte[16384];
        int length = CSharpNetwork.CopyReport(scene.SessionId, buffer);
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, CSharpNetwork.CopyReport(scene.SessionId, buffer));
        }
        return System.Text.Encoding.UTF8.GetString(buffer, 0, Math.Max(length, 0));
    }
}

public readonly partial record struct Scene
{
    /// <summary>
    /// Server only: makes a network prefab (a registered name or a .tprefab path) on every machine, owned by a
    /// client (0, the default, is the server). Null on a client or when it could not be made.
    /// </summary>
    public GameObject? Spawn(string prefab, Vector3 position, Quaternion rotation, int ownerClientId = 0)
    {
        ArgumentException.ThrowIfNullOrEmpty(prefab);
        ulong id = CSharpNetwork.Spawn(SessionId, prefab, position, rotation, ownerClientId);
        return id == 0 ? null : new GameObject(SessionId, id);
    }

    public GameObject? Spawn(string prefab, Vector3 position, int ownerClientId = 0) =>
        Spawn(prefab, position, Quaternion.Identity, ownerClientId);

    /// <summary>Server only: removes a networked object on every machine. False on a client.</summary>
    public bool Despawn(GameObject gameObject) => CSharpNetwork.Despawn(SessionId, gameObject.Id);
}
