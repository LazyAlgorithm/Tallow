using Tallow;

namespace Reload;

/// Not in version 2: its script is dropped by the reload, ending as a destroyed one would.
public class Gone : Script
{
    public override void OnDestroy() => Log.Info("RELOAD PASS a script whose class is gone ends with OnDestroy (old code)");
}

/// A class only in version 1: a field holding one starts again at its initializer after the reload.
public class OnlyInVersion1
{
    public int Value = 1;
}
