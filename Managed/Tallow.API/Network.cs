using System.Numerics;

namespace Tallow;

/// <summary>
/// Sessions and network prefabs. <see cref="Host"/>, <see cref="Join"/> and <see cref="Serve"/> say how the next
/// scene with a Network Session starts (load it after); <see cref="Leave"/> ends one. A prefab file whose root has a Network Identity is shared: <c>Scene.Spawn</c> (or
/// <see cref="Prefab.Instantiate(Scene, string)"/>) on the server makes it on every machine. Register a short name
/// for a prefab file once at startup, with the same names on the server and clients.
/// </summary>
public static class Network
{
    /// <summary>
    /// Hosts a game (a server that also plays) from the next scene with a Network Session, on its port or this one:
    /// <c>Network.Host(); SceneManager.Load("Scenes/Arena.tscene");</c>
    /// </summary>
    public static void Host(int port = 0) => CSharpNetwork.SetSession(2, "", port);

    /// <summary>Runs a dedicated server (no local player) from the next scene with a Network Session.</summary>
    public static void Serve(int port = 0) => CSharpNetwork.SetSession(1, "", port);

    /// <summary>Joins the game at an address from the next scene with a Network Session.</summary>
    public static void Join(string address, int port = 0)
    {
        ArgumentException.ThrowIfNullOrEmpty(address);
        CSharpNetwork.SetSession(3, address, port);
    }

    /// <summary>
    /// Ends the scene's session (it plays on offline) and lets later scenes start as they say again. False when it
    /// had none.
    /// </summary>
    public static bool Leave(Scene scene)
    {
        CSharpNetwork.SetSession(0, "", 0);
        return CSharpNetwork.StopSession(scene.SessionId);
    }

    /// <summary>Whether the scene has a session that is connected (a server always is).</summary>
    public static bool IsConnected(Scene scene) => CSharpNetwork.Connected(scene.SessionId) > 0;

    /// <summary>Whether the scene has a network session at all.</summary>
    public static bool InSession(Scene scene) => CSharpNetwork.Connected(scene.SessionId) >= 0;

    /// <summary>Server: the connected clients' ids (the host's own player, 0, is not one). Empty on a client.</summary>
    public static int[] ClientIds(Scene scene)
    {
        Span<float> some = stackalloc float[32];
        int count = CSharpNetwork.ClientIds(scene.SessionId, some);
        if (count <= 0)
            return [];
        Span<float> all = count <= some.Length ? some : new float[count];
        if (count > some.Length)
            count = Math.Min(count, CSharpNetwork.ClientIds(scene.SessionId, all));
        var ids = new int[count];
        for (int i = 0; i < count; i++)
            ids[i] = (int)all[i];
        return ids;
    }

    /// <summary>
    /// Server: whether a client is told about an object (it is in that client's area; set by the object's
    /// <c>NetworkIdentity.Relevance</c> and the session's relevance radius). False on a client.
    /// </summary>
    public static bool IsRelevantTo(GameObject gameObject, int clientId) =>
        CSharpNetwork.RelevantTo(gameObject.SceneId, gameObject.Id, clientId) > 0;

    /// <summary>The object spawned as a client's player (0: the host's own), or null.</summary>
    public static GameObject? PlayerObject(Scene scene, int clientId)
    {
        ulong id = CSharpNetwork.PlayerObject(scene.SessionId, clientId);
        return id == 0 ? null : new GameObject(scene.SessionId, id);
    }

    /// <summary>Names a prefab file for Spawn and for a Network Session's player prefab.</summary>
    public static void RegisterPrefab(string name, string prefabPath)
    {
        ArgumentException.ThrowIfNullOrEmpty(name);
        ArgumentException.ThrowIfNullOrEmpty(prefabPath);
        if (!CSharpNetwork.RegisterPrefabFile(name, prefabPath))
            throw new ArgumentException("A network prefab name or path is too long.");
    }

    /// <summary>How far in the past, in ticks, a client shows objects it does not control (0: two snapshots'
    /// worth, the default). Less is more up to date and less forgiving of a poor connection.</summary>
    public static int GetInterpolationTicks(Scene scene) => Math.Max(CSharpNetwork.Setting(scene.SessionId, 0), 0);
    /// <summary>Sets <see cref="GetInterpolationTicks"/> for the running session.</summary>
    public static void SetInterpolationTicks(Scene scene, int ticks) => CSharpNetwork.SetSetting(scene.SessionId, 0, ticks);

    /// <summary>Whether clients predict the server's physics bodies (on by default). Set on the server it decides
    /// for every client; set off on a client, that client shows them in the past.</summary>
    public static bool GetPredictPhysics(Scene scene) => CSharpNetwork.Setting(scene.SessionId, 1) == 1;
    /// <summary>Sets <see cref="GetPredictPhysics"/> for the running session.</summary>
    public static void SetPredictPhysics(Scene scene, bool on) => CSharpNetwork.SetSetting(scene.SessionId, 1, on ? 1 : 0);

    /// <summary>How far back, in ticks, lag compensation may look (24, 0.4 seconds, by default).</summary>
    public static int GetMaxRewindTicks(Scene scene) => Math.Max(CSharpNetwork.Setting(scene.SessionId, 2), 0);
    /// <summary>Sets <see cref="GetMaxRewindTicks"/> for the running session.</summary>
    public static void SetMaxRewindTicks(Scene scene, int ticks) => CSharpNetwork.SetSetting(scene.SessionId, 2, ticks);

    /// <summary>Keeps sessions going when their host leaves: another player takes over. Set it on every machine
    /// before the session starts (or tick Host Migration on the Network Session). Off by default.</summary>
    public static bool HostMigration
    {
        get => CSharpNetwork.Setting(0, 3) == 1;
        set => CSharpNetwork.SetSetting(0, 3, value ? 1 : 0);
    }

    /// <summary>True from losing the host until play resumes under the new one.</summary>
    public static bool IsMigrating(Scene scene) => CSharpNetwork.Setting(scene.SessionId, 4) == 1;

    private static Action<string>? sOnHostChanged;
    private static Action? sOnBecameHost;
    private static ulong sHostScene;

    /// <summary>Raised on every remaining machine after a host migration, with the new host's Steam ID or address
    /// (empty on the new host itself). Raised once a frame, after LateUpdate, for the scene the handler was added
    /// in.</summary>
    public static void OnHostChanged(Scene scene, Action<string> handler)
    {
        WatchHost(scene);
        sOnHostChanged += handler;
    }

    /// <summary>Raised on the machine that took over as host. Recreate server-only state there: timers, AI that only
    /// ran on the server.</summary>
    public static void OnBecameHost(Scene scene, Action handler)
    {
        WatchHost(scene);
        sOnBecameHost += handler;
    }

    private static void WatchHost(Scene scene)
    {
        // Hooked again each time: a game that stopped dropped the hook (GameThread.Stop).
        GameThread.EachFrame -= RaiseHostChanges;
        GameThread.EachFrame += RaiseHostChanges;
        sHostScene = scene.SessionId;
    }

    private static void RaiseHostChanges()
    {
        for (string? address; (address = ActionText.Read(buffer => CSharpNetwork.TakeHostChange(sHostScene, buffer))) != null;)
        {
            if (address.Length == 0)
                sOnBecameHost?.Invoke();
            sOnHostChanged?.Invoke(address);
        }
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

    /// <summary>A game is unloading: drop its handlers, so nothing keeps its assembly alive.</summary>
    internal static void ClearTeamChooser()
    {
        sChooseTeam = null;
        GameThread.EachFrame -= RaiseHostChanges;
        sOnHostChanged = null;
        sOnBecameHost = null;
        AntiCheat.ClearHandlers();
        VoiceChat.ClearHandlers();
        DayNight.ClearHandlers();
    }

    /// <summary>Server: removes a player from the session (a banned player, a cheater). False on a client, without
    /// a session, or for an id that is not connected.</summary>
    public static bool Kick(Scene scene, int clientId) => CSharpAntiCheat.Kick(scene.SessionId, clientId);

    /// <summary>Whether a networked prefab is registered under that name.</summary>
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

    /// <summary>Spawns a registered networked prefab on every machine, unrotated (server only); null when it could
    /// not.</summary>
    public GameObject? Spawn(string prefab, Vector3 position, int ownerClientId = 0) =>
        Spawn(prefab, position, Quaternion.Identity, ownerClientId);

    /// <summary>Server only: removes a networked object on every machine. False on a client.</summary>
    public bool Despawn(GameObject gameObject) => CSharpNetwork.Despawn(SessionId, gameObject.Id);
}
