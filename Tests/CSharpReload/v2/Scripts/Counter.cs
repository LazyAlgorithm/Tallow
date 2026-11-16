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

// Reordered and extended in version 2: values are carried by name.
public enum Mode { Swim, Walk, Run, Fly }

public class Item
{
    public int Count;
    public Item? Next;
    public Mode Mode;
    // New in version 2: the new constructor runs, so it keeps its initializer.
    public int Extra = 9;
}

public struct Cell
{
    public int X;
    public Settings? Owner;
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
    private Dictionary<string, int> _scores = new(StringComparer.OrdinalIgnoreCase);
    private HashSet<string> _seen = new();
    private Queue<int> _queue = new();
    private Stack<int> _stack = new();
    private readonly List<int> _readonlyList = new();
    private Dictionary<string, Item> _items = new();
    private Item?[] _array = new Item?[2];
    private Cell _cell;
    private Mode _mode = Mode.Walk;
    private List<Partner?> _partners = new();
    private object? _removed;
    private float _score;
    private int _kind = 5;
    private Action? _callback;
    private (string, object?) _pair;
    // New in version 2: starts at its initializer.
    public int Added = 11;
    private int _v2Ticks, _updates;

    private static object? MakeRemoved() => null;

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
            Check(_scores.TryGetValue("ALPHA", out int alpha) && alpha == 3, $"a dictionary keeps its items and comparer ({alpha})");
            Check(_seen.Count == 2 && _seen.Contains("b"), $"a set keeps its items ({_seen.Count})");
            Check(_queue.Count == 2 && _queue.Peek() == 1 && _stack.Count == 2 && _stack.Peek() == 2,
                "a queue and a stack keep their order");
            Check(_readonlyList.Count == 1 && _readonlyList[0] == 8, $"a readonly list keeps its items ({_readonlyList.Count})");
            Item? loop = _items.GetValueOrDefault("loop");
            Check(loop != null && loop.Count == 5 && loop.Next == loop && ReferenceEquals(_array[0], loop) &&
                _array[1]?.Count == 6, "game classes in a dictionary and an array keep values, cycles and sharing");
            Check(loop != null && loop.Mode == Mode.Swim && _mode == Mode.Run, $"enums keep their names after a reorder ({loop?.Mode}, {_mode})");
            Check(loop != null && loop.Extra == 9, $"a field new in a game class starts at its initializer ({loop?.Extra})");
            Check(_cell.X == 4 && ReferenceEquals(_cell.Owner, Settings), "a struct keeps its values and shared references");
            Check(_partners.Count == 1 && ReferenceEquals(_partners[0], Friend) && Friend != null, "a list of scripts points at the new instances");
            Check(_score == 42f, $"an int field that became a float keeps its number ({_score})");
            Check(_kind == 5 && _removed == null, $"a field whose type changed or was removed starts again ({_kind}, {_removed})");
            Check(_callback == null && ReferenceEquals(_pair.Item2, loop), "a delegate of the old code is dropped; a tuple keeps its object");
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
            _scores["Alpha"] = 3;
            _seen.Add("a");
            _seen.Add("b");
            _queue.Enqueue(1);
            _queue.Enqueue(2);
            _stack.Push(1);
            _stack.Push(2);
            _readonlyList.Add(8);
            var loop = new Item { Count = 5, Mode = Mode.Swim };
            loop.Next = loop;
            _items["loop"] = loop;
            _array[0] = loop;
            _array[1] = new Item { Count = 6 };
            _cell = new Cell { X = 4, Owner = Settings };
            _mode = Mode.Run;
            _partners.Add(Friend);
            _removed = MakeRemoved();
            _score = 42;
            _kind = 6;
            _callback = () => _ticks += 0;
            _pair = ("p", loop);
        }
    }
}
