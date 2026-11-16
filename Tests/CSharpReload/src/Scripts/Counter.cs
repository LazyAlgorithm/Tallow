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

public enum Mode { Walk, Run, Swim }

/// Game classes held in collections: copied to the new code's classes field by field.
public class Item
{
    public int Count;
    public Item? Next;
    public Mode Mode;
}

public struct Cell
{
    public int X;
    public Settings? Owner;
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
    private int _score;
    private string _kind = "x";
    private Action? _callback;
    private Action? _named;
    private int _pings;
    private (string, object?) _pair;

    private void Ping() => _pings += 1;
    private int PickTeam(int clientId) => clientId % 2;

    private static object MakeRemoved() => new OnlyInVersion1();

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
            _kind = "y";
            _callback = () => _ticks += 0;
            _named = Ping;
            Network.ChooseTeam = PickTeam;
            _pair = ("p", loop);
        }
    }
}
