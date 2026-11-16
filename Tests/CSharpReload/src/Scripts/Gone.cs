using Tallow;

namespace Reload;

/// Not in version 2: its script is dropped by the reload, ending as a destroyed one would.
public class Gone : Script
{
    public override void OnDestroy() => Log.Info("RELOAD PASS a script whose class is gone ends with OnDestroy (old code)");
}
