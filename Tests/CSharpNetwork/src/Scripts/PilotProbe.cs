using Tallow;

namespace NetGame;

/// <summary>A bare entity an EcsSystem advances: Ticks is shared; LocalRuns counts runs on this machine.</summary>
[Component]
public struct Pilot
{
    [Sync] public int Kind;
    [Sync] public int Ticks;
    public int LocalRuns;
}

public class PilotSystem : EcsSystem<Pilot>
{
    public override void Update(EcsEntity entity, ref Pilot pilot, TickInput input, float deltaTime)
    {
        pilot.Ticks++;
        pilot.LocalRuns++;
    }
}

/// The server makes two pilots, gives one (Kind 1) to the client and keeps the other (Kind 2). The client must run
/// only its own (prediction), and see the server's advance through replication.
public class PilotProbe : Script
{
    private bool _made, _given, _done;
    private int _ticks;
    private EcsEntity _mine;

    public override void FixedUpdate(float deltaTime)
    {
        if (!Scene.IsNetworked)
            return;
        _ticks++;
        if (Scene.IsServer)
        {
            if (!_made)
            {
                _made = true;
                _mine = Scene.CreateLocalEcsEntity();
                _mine.Set(new Pilot { Kind = 1 });
                Scene.CreateLocalEcsEntity().Set(new Pilot { Kind = 2 });
            }
            if (!_given && Scene.Find("Player") is { } player && player.OwnerClientId != 0)
            {
                _given = true;
                Log.Info($"NETTEST server gave a pilot to client {player.OwnerClientId} ({_mine.SetOwner(player.OwnerClientId)})");
            }
            return;
        }
        if (_done)
            return;
        Pilot own = default, server = default;
        EcsEntity ownEntity = default;
        Scene.Query<Pilot>().ForEach((EcsEntity entity, ref Pilot pilot) =>
        {
            if (pilot.Kind == 1) { own = pilot; ownEntity = entity; }
            if (pilot.Kind == 2) server = pilot;
        });
        if (own.LocalRuns >= 30 && server.Ticks >= 30)
        {
            _done = true;
            SyncProbe.Check("EcsEntity.SetOwner gives a bare entity to the client (OwnerClientId, IsMine)",
                ownEntity.OwnerClientId == Scene.LocalClientId && ownEntity.IsMine);
            SyncProbe.Check($"the client runs its own entity's EcsSystem at once (prediction: {own.LocalRuns} runs, {own.Ticks} ticks)",
                own.Ticks >= own.LocalRuns / 2);
            SyncProbe.Check($"the client does not run the server's entity, which advances through replication ({server.LocalRuns}, {server.Ticks})",
                server.LocalRuns == 0 && server.Ticks >= 30);
            SyncProbe.Finished();
        }
        else if (_ticks == 60 * 20)
        {
            _done = true;
            Log.Error($"NETTEST FAIL pilots: own runs {own.LocalRuns} ticks {own.Ticks}, server's runs {server.LocalRuns} ticks {server.Ticks}, owner {ownEntity.OwnerClientId}");
            Application.Quit();
        }
    }
}
