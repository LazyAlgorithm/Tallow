using Tallow;

namespace NetReload;

/// Version 2: on the client that followed the host, the server's [Sync] value must come from this code too.
public class Probe : Script
{
    [Sync] public int ServerVersion;
    private bool _reloaded;
    private int _after;

    public override void OnReload() => _reloaded = true;

    private static void Check(bool ok, string what) =>
        Log.Info((ok ? "NETRELOAD PASS " : "NETRELOAD FAIL ") + what);

    public override void FixedUpdate(float deltaTime)
    {
        if (Scene.IsServer)
        {
            ServerVersion = 2;
            return;
        }
        if (!_reloaded || ++_after != 60)
            return;
        Check(ServerVersion == 2, $"the client runs version 2 and the server's [Sync] value comes from version 2 ({ServerVersion})");
        Log.Info("NETRELOAD DONE");
        Application.Quit();
    }
}
