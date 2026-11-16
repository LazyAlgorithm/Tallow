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

/// Version 1 of the code: tools/test_csharp_reload.py swaps in v2/Scripts while it plays.
public class TickSystem : EcsSystem<Tick>
{
    public override void Update(EcsEntity entity, ref Tick tick, TickInput input, float deltaTime) => tick.N += 1;
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

    public override void Awake() => _awakes++;

    public override void Start()
    {
        Friend = Scene.Find("B")?.GetComponent<Partner>();
        Scene.CreateLocalEcsEntity().Set(new Tick());
    }

    public override void FixedUpdate(float deltaTime)
    {
        _ticks++;
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
