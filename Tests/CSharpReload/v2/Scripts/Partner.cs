using Tallow;

namespace Reload;

public class Partner : Script
{
    public string Version => "v2";
    public int Beats;
    private int _reloads, _beatsAtReload, _newBeats, _frames;

    // Runs once after the reload, in this code, with the fields already carried over.
    public override void OnReload()
    {
        _reloads++;
        _beatsAtReload = Beats;
        Beat();
    }

    private async void Beat()
    {
        while (true)
        {
            await Wait(0.05f);
            Beats++;
            _newBeats++;
        }
    }

    private static void Check(bool ok, string what) =>
        Log.Info((ok ? "RELOAD PASS " : "RELOAD FAIL ") + what);

    public override void FixedUpdate(float deltaTime)
    {
        if (++_frames != 25)
            return;
        Check(_reloads == 1 && _beatsAtReload > 0, $"OnReload runs once, after the fields moved ({_reloads}, {_beatsAtReload})");
        Check(_newBeats > 3, $"an await loop started in OnReload runs ({_newBeats})");
        Check(Beats - _beatsAtReload == _newBeats, $"the old code's await loop does not carry on ({Beats - _beatsAtReload} vs {_newBeats})");
    }
}
