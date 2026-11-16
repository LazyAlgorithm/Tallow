using System;
using System.Numerics;
using Tallow;

namespace NetGame;

/// Runs on a headless server and client (tools/test_csharp_network.py). The server changes its [Sync] fields;
/// the client checks it received them, and that fields without [Sync] stayed its own.
public class SyncProbe : Script
{
    [Sync] public int Count;
    [Sync] private float hidden = 1f;
    [Sync] public string Message = "start";
    [Sync] public Vector3 Spot;
    public int LocalOnly = 5;
    /// The server's record of one network tick: the phases in the order they ran, whether each ran once per tick,
    /// and whether they all had Update's (the tick's) delta time.
    [Sync] public string Phases = "";

    private int _early, _updates, _late, _localFrames;
    private string _order = "";
    private bool _tickDelta = true;
    private float _updateDelta;

    public override void EarlyUpdate(TickInput input, float deltaTime)
    {
        _early++;
        _tickDelta &= _updateDelta == 0 || deltaTime == _updateDelta;
        if (_early == 11) _order += "early ";
    }

    public override void Update(TickInput input, float deltaTime)
    {
        _updates++;
        _updateDelta = deltaTime;
        if (_updates == 11) _order += "update ";
    }

    public override void LateUpdate(TickInput input, float deltaTime)
    {
        _late++;
        _tickDelta &= deltaTime == _updateDelta;
        if (_late == 11) _order += "late";
    }

    public override void LocalUpdate(float deltaTime) => _localFrames++;

    private int _ticks;
    private bool _done;
    private int _pings;

    [Rpc(RpcTarget.Everyone)]
    private void Ping(int number, string text)
    {
        if (number > 0 && text == "ping")
            _pings++;
    }

    public override void FixedUpdate(float deltaTime)
    {
        _ticks++;
        if (Scene.IsServer)
        {
            if (_ticks == 30)
            {
                Phases = $"{_order}|{_early == _updates && _updates == _late && _updates > 0}|{_tickDelta}|{_localFrames > 0}";
                Count = 42;
                hidden = 2.5f;
                Message = "from server";
                Spot = new Vector3(1, 2, 3);
                LocalOnly = 99;
                Log.Info("NETTEST server set its fields");
            }
            // Keeps changing, so later snapshots carry later values.
            if (_ticks > 30 && _ticks % 10 == 0)
            {
                Count++;
                Rpc(nameof(Ping), Count, "ping");
            }
            return;
        }
        if (!Scene.IsClient || _done)
            return;
        if (Message == "from server" && Count >= 43 && _pings >= 2)
        {
            _done = true;
            Check("server RPC to everyone arrives", _pings >= 2);
            bool refused = false;
            try
            {
                Rpc(nameof(Ping), 1, "ping");
            }
            catch (InvalidOperationException)
            {
                refused = true;
            }
            Check("a client cannot call RPCs on an object it does not own", refused);
            Check("int [Sync] field", Count >= 43);
            Check("private [Sync] field", hidden == 2.5f);
            Check("string [Sync] field", Message == "from server");
            Check("Vector3 [Sync] field", Spot == new Vector3(1, 2, 3));
            Check("fields without [Sync] stay the client's own", LocalOnly == 5);
            Check($"a networked object runs EarlyUpdate, Update, LateUpdate in order once per tick, LocalUpdate per frame ({Phases})",
                Phases == "early update late|True|True|True");
            Finished();
        }
        else if (_ticks == 60 * 20)
        {
            _done = true;
            Log.Error($"NETTEST FAIL the server's values never arrived (Count {Count}, Message \"{Message}\")");
            Application.Quit();
        }
    }

    private static int sFinished;

    /// The probes (this, RpcProbe on the client's player and SpawnProbe) report before the client quits.
    public static void Finished()
    {
        if (++sFinished < 4)
            return;
        Log.Info("NETTEST DONE");
        Application.Quit();
    }

    public static void Check(string label, bool ok)
    {
        if (ok)
            Log.Info("NETTEST PASS " + label);
        else
            Log.Error("NETTEST FAIL " + label);
    }
}
