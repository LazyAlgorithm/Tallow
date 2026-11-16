using System.Collections.Generic;
using System.Numerics;
using Tallow;

namespace NetGame;

/// The server spawns two crates for the client's player (Scene.Spawn with an owner), then despawns one; the client
/// checks they arrived, that it owns them, and that the despawned one went away.
public class SpawnProbe : Script
{
    private int _ticks;
    private bool _spawned, _despawned, _done;
    private GameObject? _gone;

    public override void Awake()
    {
        // Before the client joins: its player's team comes from here (the server only asks on the server).
        if (Scene.IsServer)
            Network.ChooseTeam = clientId => 7;
    }

    public override void Start() => Network.RegisterPrefab("crate", "Prefabs/Crate.tprefab");

    public override void FixedUpdate(float deltaTime)
    {
        _ticks++;
        if (Scene.IsServer)
        {
            if (!_spawned && Scene.Find("Player") is { } player && player.OwnerClientId != 0)
            {
                _spawned = true;
                int owner = player.OwnerClientId;
                Scene.Spawn("crate", new Vector3(5, 0, 0), Quaternion.Identity, owner);
                _gone = Scene.Spawn("crate", new Vector3(0, 50, 0), owner);
                Log.Info($"NETTEST server spawned crates for client {owner} ({_gone != null})");
                _ticks = 0;
            }
            if (_spawned && !_despawned && _ticks == 60 && _gone is { } gone)
            {
                _despawned = true;
                Log.Info($"NETTEST server despawned a crate ({Scene.Despawn(gone)})");
            }
            return;
        }
        if (_done)
            return;
        CrateProbe? kept = null;
        foreach (CrateProbe crate in CrateProbe.Live)
        {
            // A despawned object reads as gone at once; its OnDestroy follows at the end of the frame.
            if (crate.GameObject.IsValid && crate.Transform.Position.X > 4)
                kept = crate;
        }
        if (kept != null && CrateProbe.SeenHigh && CrateProbe.HighDestroyed)
        {
            _done = true;
            SyncProbe.Check("Network.RegisterPrefab names a prefab on the client too", Network.IsRegistered("crate"));
            SyncProbe.Check("a crate the server spawned arrives at its position", true);
            SyncProbe.Check("Scene.Spawn gives the object to the client it names", kept.IsMine && kept.GameObject.OwnerClientId == Scene.LocalClientId);
            SyncProbe.Check("Scene.Despawn removes it on the client", true);
            SyncProbe.Check("Scene.Spawn on a client gives null", Scene.Spawn("crate", Vector3.Zero) == null);
            int team = Scene.Find("Player") is { } mine ? mine.Team : -1;
            SyncProbe.Check($"Network.ChooseTeam on the server picks the joining player's team ({team})", team == 7);
            SyncProbe.Finished();
        }
        else if (_ticks == 60 * 20)
        {
            _done = true;
            Log.Error($"NETTEST FAIL spawned crates never arrived (live {CrateProbe.Live.Count}, high seen {CrateProbe.SeenHigh}, high destroyed {CrateProbe.HighDestroyed})");
            Application.Quit();
        }
    }
}

public class CrateProbe : Script
{
    public static readonly List<CrateProbe> Live = [];
    public static bool SeenHigh, HighDestroyed;
    private bool _high;

    public override void Start()
    {
        Live.Add(this);
        _high = Transform.Position.Y > 40;
        SeenHigh |= _high;
    }

    public override void OnDestroy()
    {
        Live.Remove(this);
        HighDestroyed |= _high;
    }
}
