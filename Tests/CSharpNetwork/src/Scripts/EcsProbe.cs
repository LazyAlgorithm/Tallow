using System.Numerics;
using Tallow;

namespace NetGame;

/// <summary>Bare ECS data the server shares: [Sync] fields go to clients, the rest stays on the server.</summary>
[Component]
public struct Beacon
{
    [Sync] public int Score;
    [Sync] public Vector3 Position;
    [Sync] public bool Lit;
    public float ServerOnly;
}

/// <summary>Bare ECS data with a place: the server sends it only to clients whose player is near.</summary>
[Component]
public struct Marker
{
    [SyncPosition] public Vector3 At;
    [Sync] public int Number;
}

/// The server makes three bare entities with C# [Component] data, changes one and deletes another; the client checks
/// each step arrives (and that the field without [Sync] does not).
public class EcsProbe : Script
{
    private int _ticks, _step;
    private bool _made;
    private EcsEntity _changed, _deleted;

    public override void FixedUpdate(float deltaTime)
    {
        _ticks++;
        if (!Scene.IsNetworked)
            return; // A client plays offline until it connects (IsServer is true then).
        if (Scene.IsServer)
        {
            if (!_made)
            {
                _made = true;
                for (int i = 0; i < 3; i++)
                {
                    EcsEntity entity = Scene.CreateLocalEcsEntity();
                    entity.Set(new Beacon { Score = 10 + i, Position = new Vector3(i, 2, 3), ServerOnly = 9 });
                    if (i == 0) _changed = entity;
                    if (i == 2) _deleted = entity;
                }
                // One marker beside the client's player (it starts near the origin), one far beyond the 100 m radius.
                Scene.CreateLocalEcsEntity().Set(new Marker { At = new Vector3(5, 0, 5), Number = 1 });
                Scene.CreateLocalEcsEntity().Set(new Marker { At = new Vector3(5000, 0, 5), Number = 2 });
            }
            // Once the client has them (a player object of its own is there), change one and delete another.
            if (_step == 0 && Scene.Find("Player") is { } player && player.OwnerClientId != 0)
            {
                _step = 1;
                _ticks = 0;
            }
            if (_step == 1 && _ticks == 90)
            {
                _step = 2;
                Scene.Query<Beacon>().ForEach((EcsEntity entity, ref Beacon beacon) =>
                {
                    if (entity == _changed)
                    {
                        beacon.Score = 99;
                        beacon.Lit = true;
                    }
                });
                Log.Info($"NETTEST server changed a beacon and deleted one ({_deleted.DestroyLocal()})");
            }
            return;
        }
        if (_step == 0 && Scene.Query<Beacon>().Count == 3)
        {
            _step = 1;
            int scores = 0;
            bool positions = true, serverOnly = false;
            Scene.Query<Beacon>().ForEach((EcsEntity entity, ref Beacon beacon) =>
            {
                scores += beacon.Score;
                positions &= beacon.Position == new Vector3(beacon.Score - 10, 2, 3);
                serverOnly |= beacon.ServerOnly != 0;
            });
            SyncProbe.Check("bare C# ECS entities the server made arrive with their [Sync] data", scores == 33 && positions);
            SyncProbe.Check("a C# ECS field without [Sync] is not sent", !serverOnly);
        }
        else if (_step == 1 && Scene.Query<Beacon>().Count == 2)
        {
            _step = 2;
            bool lit = false;
            Scene.Query<Beacon>().ForEach((EcsEntity entity, ref Beacon beacon) => lit |= beacon.Lit && beacon.Score == 99);
            SyncProbe.Check("a change the server's ForEach makes reaches the client", lit);
            SyncProbe.Check("a bare entity the server deletes goes on the client", true);
            int near = 0, far = 0;
            Scene.Query<Marker>().ForEach((EcsEntity entity, ref Marker marker) =>
            {
                if (marker.Number == 1 && marker.At == new Vector3(5, 0, 5)) near++;
                if (marker.Number == 2) far++;
            });
            SyncProbe.Check($"[SyncPosition] C# data reaches a client near it and not one far away ({near} near, {far} far)",
                near == 1 && far == 0);
            SyncProbe.Finished();
        }
        else if (_ticks == 60 * 20 && _step < 2)
        {
            var seen = new System.Text.StringBuilder();
            Scene.Query<Beacon>().ForEach((EcsEntity entity, ref Beacon beacon) => seen.Append($" {entity.Id}:{beacon.Score}{(beacon.Lit ? "*" : "")}"));
            Log.Error($"NETTEST FAIL C# ECS data did not replicate (step {_step}, beacons{seen})");
            _step = 2;
            Application.Quit();
        }
    }
}
