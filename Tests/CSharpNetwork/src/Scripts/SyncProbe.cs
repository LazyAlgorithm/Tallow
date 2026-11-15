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

    /// Both probes (this and RpcProbe on the client's player) report before the client quits.
    public static void Finished()
    {
        if (++sFinished < 2)
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
