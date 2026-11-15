using System;

namespace Tallow;

/// Networking calls for C# scripts that need the native session (generated wrappers in Tallow.API).
[CSharpExpose]
static class CSharpNetwork
{
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
}
