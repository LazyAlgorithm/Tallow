using System.Numerics;
using Tallow;

namespace NetGame;

/// On each client's player (spawned for it, so it owns it): calls the server, which answers everyone.
public class RpcProbe : Script
{
    public enum Mood { Calm, Loud }

    private int _ticks;
    private bool _done;
    private int _answer;
    private bool _echoed;

    [Rpc(RpcTarget.Server)]
    private void Ask(int value, string text, Vector3 where, Mood mood, GameObject self)
    {
        if (!Scene.IsServer)
        {
            Log.Error("NETTEST FAIL a Server RPC ran on a client");
            return;
        }
        // Only the owner may call, so the sender is this object's owner.
        bool good = text == "a\u001fb\\c" && where == new Vector3(4, 5, 6) && mood == Mood.Loud &&
            self == GameObject && RpcSender == GameObject.OwnerClientId && RpcSender > 0;
        Rpc(nameof(Answer), good ? value * 2 : -1);
    }

    [Rpc(RpcTarget.Everyone)]
    private void Answer(int value) => _answer = value;

    [Rpc] // Everyone by default
    private void Echo(bool flag)
    {
        if (flag)
            _echoed = true;
    }


    public override void FixedUpdate(float deltaTime)
    {
        _ticks++;
        if (!Scene.IsClient || !IsMine || _done)
            return;
        if (_ticks == 10)
        {
            Rpc(nameof(Ask), 21, "a\u001fb\\c", new Vector3(4, 5, 6), Mood.Loud, GameObject);
            Rpc(nameof(Echo), true);
            SyncProbe.Check("an owner's Everyone RPC waits for the server", !_echoed);
        }
        if (_answer != 0 && _echoed)
        {
            _done = true;
            SyncProbe.Check("client RPC to the server, answered to everyone (all argument kinds)", _answer == 42);
            SyncProbe.Check("owner's Everyone RPC comes back from the server", _echoed);
            SyncProbe.Finished();
        }
        else if (_ticks == 60 * 20)
        {
            _done = true;
            Log.Error($"NETTEST FAIL RPCs never came back (answer {_answer}, echoed {_echoed})");
            SyncProbe.Finished();
        }
    }
}
