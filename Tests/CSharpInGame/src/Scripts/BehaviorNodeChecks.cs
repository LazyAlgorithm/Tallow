using Tallow;

namespace InGame;

/// <summary>A C# condition with its own key (AI/CSharpNodes.tbt names it ingame.ammo).</summary>
[BehaviorNode("Ammo At Least", Condition = true, Key = "ingame.ammo", Description = "Succeeds while the blackboard's ammo is at least Count.")]
public class AmmoAtLeast : BehaviorNode
{
    public int Count = 1;

    protected override BehaviorStatus OnTick(float deltaTime) =>
        Blackboard.GetNumber("ammo") >= Count ? BehaviorStatus.Success : BehaviorStatus.Failure;
}

/// <summary>Runs for Ticks ticks, writing how far it got to the blackboard.</summary>
public class CountTicks : BehaviorNode
{
    public float Ticks = 2;
    public string Entry = "count";
    private int _count;
    public static int Starts, Ends;

    protected override void OnStart()
    {
        _count = 0;
        Starts++;
    }

    protected override BehaviorStatus OnTick(float deltaTime)
    {
        _count++;
        Blackboard.SetNumber(Entry, _count);
        return _count >= Ticks ? BehaviorStatus.Success : BehaviorStatus.Running;
    }

    protected override void OnEnd(bool aborted)
    {
        if (!aborted)
            Ends++;
    }
}

[BehaviorNode("Mark Done", Category = "Tests")]
public class MarkDone : BehaviorNode
{
    protected override BehaviorStatus OnTick(float deltaTime)
    {
        Blackboard.SetFlag("done", true);
        Blackboard.SetObject("me", GameObject);
        return BehaviorStatus.Success;
    }
}
