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
}
