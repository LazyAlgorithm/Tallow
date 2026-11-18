using Tallow;

namespace Reload;

public class Partner : Script
{
    public string Version => "v1";
    public int Beats;

    public override void Start() => Beat();

    // A game-time await loop: the reload ends it (version 2 starts its own in OnReload).
    private async void Beat()
    {
        while (true)
        {
            await Wait(0.05f);
            Beats++;
        }
    }
}
