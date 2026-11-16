using System;
using System.Collections.Generic;
using Tallow;

namespace Reload;

[Serializable]
public class Settings
{
    public int Level = 1;
    public string Name = "start";
}

[Component]
public struct Tick
{
    public int N;
}

/// Version 2 of the code (tools/test_csharp_reload.py reloads it into the running game).
public class TickSystem : EcsSystem<Tick>
{
    public override void Update(EcsEntity entity, ref Tick tick, TickInput input, float deltaTime) => tick.N += 1000;
}

public class Counter : Script
{
    public float Speed = 2;
    public Settings Settings = new();
    public Partner? Friend;
    [NonSerialized] public int Transient = 1;
    public int AutoProp { get; set; }
    private int _ticks;
    private int _awakes;
    private string _label = "v1";
    private List<int> _history = new();
    // New in version 2: starts at its initializer.
    public int Added = 11;
    private int _v2Ticks, _updates;

    public override void Awake() => _awakes++;

    public override void Start()
    {
        Friend = Scene.Find("B")?.GetComponent<Partner>();
        Scene.CreateLocalEcsEntity().Set(new Tick());
    }

    // Not overridden in version 1: the reload must start calling it.
    public override void Update(TickInput input, float deltaTime) => _updates++;

    private static void Check(bool ok, string what) =>
        Log.Info((ok ? "RELOAD PASS " : "RELOAD FAIL ") + what);

    public override void FixedUpdate(float deltaTime)
    {
        _ticks++;
        if (++_v2Ticks == 1)
        {
            Check(_ticks > 50, $"a private counter keeps counting ({_ticks})");
            Check(_awakes == 1, $"Awake does not run again ({_awakes})");
            Check(Speed == 5, $"an Inspector field keeps its scene value ({Speed})");
            Check(_label == "changed" && AutoProp == 7, $"private and auto-property fields keep their values ({_label}, {AutoProp})");
            Check(Settings.Level == 3 && Settings.Name == "edited", $"a nested [Serializable] field keeps its values ({Settings.Level}, {Settings.Name})");
            Check(_history.Count == 1 && _history[0] == 4, $"a list keeps its items ({string.Join(",", _history)})");
            Check(Transient == 1, $"a [NonSerialized] field starts again at its initializer ({Transient})");
            Check(Added == 11, $"a field new in this version starts at its initializer ({Added})");
            Check(Friend != null && Friend.Version == "v2", $"a reference to another script points at its new instance ({Friend?.Version})");
        }
        if (_v2Ticks == 30)
        {
            Check(_updates > 0, $"a callback the new code overrides runs ({_updates})");
            int n = 0;
            Scene.Query<Tick>().ForEach((EcsEntity entity, ref Tick tick) => n = tick.N);
            Check(n > 20000, $"ECS systems run the new code on the same data ({n})");
            Log.Info("RELOAD DONE");
            Application.Quit();
        }
        if (_ticks == 10)
        {
            _label = "changed";
            Settings.Level = 3;
            Settings.Name = "edited";
            Transient = 50;
            AutoProp = 7;
            _history.Add(4);
        }
    }
}
