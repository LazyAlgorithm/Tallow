using System;
using System.Collections;

namespace Tallow;

/// Networking calls for C# scripts that need the native session (generated wrappers in Tallow.API).
[CSharpExpose]
static class CSharpNetwork
{
    /// A session setting by number: 0 InterpolationTicks, 1 PredictPhysics, 2 MaxRewindTicks, 3 HostMigration,
    /// 4 IsMigrating (read only). Bools are 0 or 1; -1 without a session (3 then gives the setting for the next one).
    [CSharpExpose]
    public static int32 Setting(uint64 session, int32 which)
    {
        let network = CSharpRuntime.PhysicsScene(session)?.Network;
        if (network == null)
            return which == 3 ? (NetworkSession.HostMigrationOverride ? 1 : 0) : -1;
        switch (which)
        {
        case 0: return network.InterpolationTicks;
        case 1: return network.PredictPhysics ? 1 : 0;
        case 2: return network.MaxRewindTicks;
        case 3: return network.HostMigration ? 1 : 0;
        case 4: return network.IsMigrating ? 1 : 0;
        default: return -1;
        }
    }

    [CSharpExpose]
    public static void SetSetting(uint64 session, int32 which, int32 value)
    {
        if (which == 3)
            NetworkSession.HostMigrationOverride = value != 0;
        let network = CSharpRuntime.PhysicsScene(session)?.Network;
        if (network == null)
            return;
        switch (which)
        {
        case 0: network.InterpolationTicks = Math.Clamp(value, 0, 60);
        case 1: network.PredictPhysics = value != 0;
        case 2: network.MaxRewindTicks = Math.Clamp(value, 0, 120);
        case 3: network.HostMigration = value != 0;
        default:
        }
    }

    static List<String> sHostChanges = new .() ~ DeleteContainerAndItems!(_);

    /// The next host change seen on this machine: the new host's Steam ID or address, empty when this machine
    /// became the host; -1 when there is none. The first call for a session starts watching it.
    [CSharpExpose]
    public static int32 TakeHostChange(uint64 session, Span<uint8> buffer)
    {
        let network = CSharpRuntime.PhysicsScene(session)?.Network;
        if (network != null && network.OnHostChanged == null)
        {
            network.OnHostChanged = new (address) => { if (sHostChanges.Count < 64) sHostChanges.Add(new String(address)); };
        }
        if (sHostChanges.IsEmpty)
            return -1;
        let first = sHostChanges[0];
        let length = (int32)first.Length;
        for (int i < Math.Min(first.Length, buffer.Length))
            buffer[i] = (uint8)first[i];
        if (length <= buffer.Length)
        {
            sHostChanges.RemoveAt(0);
            delete first;
        }
        return length;
    }

    /// Sends a script's [Rpc] call. 1: run it here now; 0: sent to the server; -1: not allowed or stale.
    /// target: 0 server, 1 everyone. arguments: the encoded argument text (Tallow.API RpcMethods).
    [CSharpExpose]
    public static int32 SendRpc(uint64 session, uint64 entity, int32 instance, int32 target, StringView method, StringView arguments)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return -1;
        for (let component in obj.Components)
        {
            if (let behaviour = component as CSharpBehaviour)
            {
                if (behaviour.IsLoaded && behaviour.ManagedInstance == instance)
                    return NetworkSync.SendScriptRpc(behaviour, target, method, arguments);
            }
        }
        return -1;
    }

    /// Component.SendNetworkEvent for a script: 1 when sent (or run here, with no session), -1 when the script is gone.
    [CSharpExpose]
    public static int32 SendEvent(uint64 session, uint64 entity, int32 instance, StringView name, float value)
    {
        let obj = CSharpRuntime.PhysicsObject(session, entity);
        if (obj == null)
            return -1;
        for (let component in obj.Components)
        {
            if (let behaviour = component as CSharpBehaviour)
            {
                if (behaviour.IsLoaded && behaviour.ManagedInstance == instance)
                {
                    NetworkSync.SendEvent(behaviour, name, value);
                    return 1;
                }
            }
        }
        return -1;
    }

	/// NetworkManager.RegisterPrefabFile: a name for a prefab file, for Spawn and the session's player prefab.
	[CSharpExpose]
	public static bool RegisterPrefabFile(StringView name, StringView path)
	{
		if (name.IsEmpty || path.IsEmpty || name.Length > 256 || path.Length > 4096)
			return false;
		NetworkManager.RegisterPrefabFile(name, path);
		return true;
	}

	/// Whether C# set Network.ChooseTeam (NetworkManager then asks it for each joining player's team).
	[CSharpExpose]
	public static void SetTeamChooser(bool on) => CSharpRuntime.HasTeamChooser = on;

	[CSharpExpose]
	public static bool IsPrefabRegistered(StringView name) => NetworkManager.IsRegistered(name);

	/// Server only: makes a registered prefab (or a .tprefab path) on every machine, owned by a client (0: the
	/// server). Returns the new object's id, 0 when not the server or it could not be made.
	[CSharpExpose]
	public static uint64 Spawn(uint64 session, StringView prefab, Vector3 position, Quaternion rotation, int32 ownerId)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null || scene.Network == null || !scene.Network.IsServer || prefab.IsEmpty || ownerId < 0 ||
			!position.x.IsFinite || !position.y.IsFinite || !position.z.IsFinite ||
			!rotation.x.IsFinite || !rotation.y.IsFinite || !rotation.z.IsFinite || !rotation.w.IsFinite ||
			rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z + rotation.w * rotation.w < 1.0e-12f)
			return 0;
		let created = scene.Network.Spawn(prefab, position, rotation.Normalized, ownerId);
		return (created != null && !created.IsDestroyed) ? (uint64)created.Id : 0;
	}

	/// Server only: removes a spawned networked object everywhere.
	[CSharpExpose]
	public static bool Despawn(uint64 session, uint64 entity)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (scene == null || scene.Network == null || !scene.Network.IsServer || obj == null ||
			!obj.GetComponent<NetworkIdentity>().IsValid)
			return false;
		scene.Network.Despawn(obj);
		return true;
	}

	/// Server, while the object's player's tick runs: puts every other networked object back where that player saw
	/// it (NetworkManager.BeginLagCompensation). False, doing nothing, where it does not apply.
	[CSharpExpose]
	public static bool BeginLagCompensation(uint64 session, uint64 entity)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (scene == null || scene.Network == null || obj == null)
			return false;
		let identity = obj.GetComponent<NetworkIdentity>();
		return identity.IsValid && scene.Network.BeginLagCompensation(identity);
	}

	/// Puts everything back where it really is. Safe when nothing was moved.
	[CSharpExpose]
	public static void EndLagCompensation(uint64 session) => CSharpRuntime.PhysicsScene(session)?.Network?.EndLagCompensation();

	/// The server tick lag compensation went back to, or -1 when it is not in effect.
	[CSharpExpose]
	public static double LagCompensationTick(uint64 session) => CSharpRuntime.PhysicsScene(session)?.Network?.LagCompensationTick ?? -1;

	/// What the session shares, for tests and debugging (UTF-8 into buffer; returns the full length). The first line
	/// is "offline" or "role=host|client connected=0|1 clients=N shared=N"; then a "NETPOS id x y z name" line per
	/// shared object, the session's own description, and a "VOXEL id indices name" line per voxel object.
	[CSharpExpose]
	public static int32 CopyReport(uint64 session, Span<uint8> buffer)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null)
			return 0;
		let text = scope String();
		let network = scene.Network;
		if (network == null || network.Mode == .Offline)
			text.Append("offline\n");
		else
		{
			text.AppendF("role={} connected={} clients={} shared={}\n", network.IsServer ? "host" : "client",
				network.IsConnected ? 1 : 0, network.ClientCount, network.Identities.Count);
			for (let identity in network.Identities)
			{
				let at = identity.GameObject.Transform.Position;
				text.AppendF("NETPOS {} {:0.000} {:0.000} {:0.000} {}\n", identity.NetId, at.x, at.y, at.z, identity.GameObject.Name);
			}
			network.Describe(text);
		}
		for (let voxels in scene.FindComponents<VoxelObject>(.. scope .()))
		{
			let mesh = voxels.GameObject.GetComponent<MeshRenderer>().RuntimeMesh;
			text.AppendF("VOXEL {} {} {}\n", voxels.GameObject.Id, mesh != null ? mesh.Indices.Count : 0, voxels.GameObject.Name);
		}
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// How the next scene's Network Session starts: mode 0 as the scene says, 1 server, 2 host, 3 client (to
	/// address); port 0 keeps the scene's. Takes effect when a scene with a Network Session loads.
	[CSharpExpose]
	public static void SetSession(int32 mode, StringView address, int32 port)
	{
		NetworkSession.ModeOverride = mode == 1 ? .Server : mode == 2 ? .Host : mode == 3 ? .Client : .Offline;
		NetworkSession.AddressOverride.Set(mode == 3 ? address : "");
		NetworkSession.PortOverride = Math.Max(port, 0);
	}

	/// Starts a session in the running scene at once: mode 1 server (no local player), 2 host, 3 client (to
	/// address); transport 0 Direct, 1 Steam. False when the scene has a session already, the mode is wrong or the
	/// transport could not start. The scene needs a Network Session only for sessions started at load; this makes
	/// them from a menu instead.
	[CSharpExpose]
	public static bool StartSession(uint64 session, int32 mode, StringView address, int32 port,
		int32 transport, StringView playerPrefab, bool hostMigration, bool autoReplicate)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null || scene.Network != null || mode < 1 || mode > 3 || port < 0 || port > 65535)
			return false;
		let network = new NetworkManager(scene);
		network.PlayerPrefab.Set(playerPrefab.IsEmpty ? "Player" : playerPrefab);
		network.Transport = transport == 1 ? .Steam : .Direct;
		network.HostMigration = hostMigration;
		network.AutoReplicate = autoReplicate;
		scene.Network = network;
		bool ok;
		if (mode == 3)
			ok = network.StartClient(address.IsEmpty ? "127.0.0.1" : address, (uint16)port);
		else
			ok = network.StartServer((uint16)port, mode == 2);
		if (!ok)
		{
			scene.Network = null;
			delete network;
			return false;
		}
		return true;
	}

	/// Ends this scene's session (the scene plays on offline). False when there was none.
	[CSharpExpose]
	public static bool StopSession(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene?.Network == null)
			return false;
		scene.Network.Stop();
		delete scene.Network;
		scene.Network = null;
		return true;
	}

	/// 1 connected (a server always is), 0 not yet or no longer, -1 no session.
	[CSharpExpose]
	public static int32 Connected(uint64 session)
	{
		let network = CSharpRuntime.PhysicsScene(session)?.Network;
		return network == null ? -1 : (network.IsServer || network.IsConnected) ? 1 : 0;
	}

	/// Server: the connected clients' ids into ids (as numbers; spans of int32 are not a binding type) (the host's own player, 0, is not one); how many there are
	/// (more than ids holds: call again with room). -1 on a client or without a session.
	[CSharpExpose]
	public static int32 ClientIds(uint64 session, Span<float> ids)
	{
		let network = CSharpRuntime.PhysicsScene(session)?.Network;
		if (network == null || !network.IsServer)
			return -1;
		let list = scope List<int32>();
		network.GetClientIds(list);
		for (int i < Math.Min(list.Count, ids.Length))
			ids[i] = list[i]; // exact: client ids are small
		return (int32)list.Count;
	}

	/// The object's shared network id (the identity server and clients use for it), 0 when it has no Network
	/// Identity or no session is running.
	[CSharpExpose]
	public static int32 NetId(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || obj.Scene.Network == null)
			return 0;
		let identity = obj.GetComponent<NetworkIdentity>();
		return identity.IsValid ? (int32)identity.NetId : 0;
	}

	/// The object spawned as a client's player (0: the host's own); 0 when it has none.
	[CSharpExpose]
	public static uint64 PlayerObject(uint64 session, int32 clientId)
	{
		let player = CSharpRuntime.PhysicsScene(session)?.Network?.PlayerObject(clientId);
		return player != null ? (uint64)player.Id : 0;
	}

	/// Server: 1 when a client is told about an object (it is in that client's area: NetworkIdentity relevance),
	/// 0 when not, -1 on a client, without a session or for an object without a Network Identity.
	[CSharpExpose]
	public static int32 RelevantTo(uint64 session, uint64 entity, int32 clientId)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		let network = scene?.Network;
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (network == null || !network.IsServer || obj == null)
			return -1;
		let identity = obj.GetComponent<NetworkIdentity>();
		if (!identity.IsValid)
			return -1;
		return network.IsRelevantTo(clientId, identity.NetId) ? 1 : 0;
	}
}
