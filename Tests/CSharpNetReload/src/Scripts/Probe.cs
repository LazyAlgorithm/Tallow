using Tallow;

namespace NetReload;

/// Version 1 (tools/test_csharp_network_reload.py hot reloads v2/Scripts on the server and one client): the server
/// says which version of the code it runs in a [Sync] field.
public class Probe : Script
{
    [Sync] public int ServerVersion;

    public override void FixedUpdate(float deltaTime)
    {
        if (Scene.IsServer)
            ServerVersion = 1;
    }
}
