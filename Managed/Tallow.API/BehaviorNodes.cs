using System.Globalization;
using System.Numerics;
using System.Reflection;

namespace Tallow;

/// <summary>What a behaviour tree node says after a tick.</summary>
public enum BehaviorStatus
{
    /// <summary>Still going: tick it again next time.</summary>
    Running = 1,
    /// <summary>Done, and it worked.</summary>
    Success = 2,
    /// <summary>Done, and it did not.</summary>
    Failure = 3,
}

/// <summary>
/// Names a <see cref="BehaviorNode"/> class for the behaviour tree editor's menu. Without it the class still works,
/// listed under "Game" by its class name.
/// </summary>
[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class BehaviorNodeAttribute(string title) : Attribute
{
    /// <summary>Its name in the editor's menu.</summary>
    public string Title { get; } = title;
    /// <summary>Where the menu lists it ("Game" by default).</summary>
    public string Category { get; init; } = "Game";
    /// <summary>What it does, shown in the editor.</summary>
    public string Description { get; init; } = "";
    /// <summary>True for a question answered at once (drawn as a condition) rather than an action.</summary>
    public bool Condition { get; init; }
    /// <summary>The key tree files save it under (the class's full name by default). Set it to keep trees working
    /// after renaming the class.</summary>
    public string? Key { get; init; }
}

/// <summary>
/// A behaviour tree node written in C#: an action or a condition. Its public fields (numbers, bool, string, Vector3)
/// are the node's settings, filled from the tree before <see cref="OnStart"/>. One instance per node in a running
/// tree, so fields can remember things between ticks. Runs where the tree runs (the server, in a session).
/// </summary>
/// <example><code>
/// [BehaviorNode("Has Ammo At Least", Condition = true, Description = "Succeeds while the guard has this much ammunition.")]
/// public class HasAmmoAtLeast : BehaviorNode
/// {
///     public int Count = 1;
///     protected override BehaviorStatus OnTick(float deltaTime) =>
///         GameObject.GetComponent&lt;GuardActions&gt;().Ammo >= Count ? BehaviorStatus.Success : BehaviorStatus.Failure;
/// }
/// </code></example>
public abstract class BehaviorNode
{
    /// <summary>The object whose Behavior Tree Runner runs this node.</summary>
    public GameObject GameObject { get; internal set; }

    /// <summary>The scene it is in.</summary>
    public Scene Scene => new(GameObject.SceneId);

    /// <summary>The object's transform.</summary>
    public Transform Transform => GameObject.Transform;

    /// <summary>The tree's blackboard: what all its nodes share.</summary>
    public Blackboard Blackboard => new(GameObject);

    /// <summary>Called when the node starts a run (after its settings are filled).</summary>
    protected virtual void OnStart() { }

    /// <summary>One tick: Running to be ticked again, or Success or Failure to finish.</summary>
    protected abstract BehaviorStatus OnTick(float deltaTime);

    /// <summary>Called when a run ends; aborted when something above stopped it part-way.</summary>
    protected virtual void OnEnd(bool aborted) { }

    internal void Start() => OnStart();
    internal BehaviorStatus Tick(float deltaTime) => OnTick(deltaTime);
    internal void End(bool aborted) => OnEnd(aborted);
}

/// <summary>A Behavior Tree Runner's blackboard (docs/behavior-trees.md), from scripts and C# nodes.</summary>
public readonly record struct Blackboard(GameObject Owner)
{
    /// <summary>Whether there is an entry for a key.</summary>
    public bool Has(string key) => CSharpBehaviorNodes.BlackboardHas(Owner.SceneId, Owner.Id, key ?? "");
    /// <summary>Forgets an entry.</summary>
    public void Clear(string key) => Must(CSharpBehaviorNodes.BlackboardClear(Owner.SceneId, Owner.Id, key ?? ""));
    /// <summary>A number (fallback when there is none).</summary>
    public float GetNumber(string key, float fallback = 0) =>
        CSharpBehaviorNodes.BlackboardNumber(Owner.SceneId, Owner.Id, key ?? "", fallback);
    /// <summary>Remembers a number.</summary>
    public void SetNumber(string key, float value) => Must(CSharpBehaviorNodes.BlackboardSetNumber(Owner.SceneId, Owner.Id, key ?? "", value));
    /// <summary>A flag (false when there is none).</summary>
    public bool GetFlag(string key) => GetNumber(key) != 0 && Has(key);
    /// <summary>Remembers a flag.</summary>
    public void SetFlag(string key, bool value) => Must(CSharpBehaviorNodes.BlackboardSetFlag(Owner.SceneId, Owner.Id, key ?? "", value));
    /// <summary>A position: a stored vector, or where a stored object is now. False when there is neither.</summary>
    public bool TryGetPosition(string key, out Vector3 position)
    {
        Span<float> found = stackalloc float[3];
        bool ok = CSharpBehaviorNodes.BlackboardPosition(Owner.SceneId, Owner.Id, key ?? "", found);
        position = ok ? new Vector3(found[0], found[1], found[2]) : default;
        return ok;
    }
    /// <summary>Remembers a position.</summary>
    public void SetVector(string key, Vector3 value) => Must(CSharpBehaviorNodes.BlackboardSetVector(Owner.SceneId, Owner.Id, key ?? "", value));
    /// <summary>A stored object, or null when there is none or it has gone.</summary>
    public GameObject? GetObject(string key) =>
        CSharpBehaviorNodes.BlackboardObject(Owner.SceneId, Owner.Id, key ?? "") is var id and not 0 ? new GameObject(Owner.SceneId, id) : null;
    /// <summary>Remembers an object (a target seen).</summary>
    public void SetObject(string key, GameObject? value) =>
        Must(CSharpBehaviorNodes.BlackboardSetObject(Owner.SceneId, Owner.Id, key ?? "", value?.Id ?? 0));

    private void Must(bool found)
    {
        if (!found)
            throw ActionText.Missing(Owner, "Behavior Tree Runner");
    }
}

public readonly partial record struct BehaviorTreeRunner
{
    /// <summary>The tree's blackboard.</summary>
    public Blackboard Blackboard => new(GameObject);
}

/// <summary>The game's C# behaviour tree nodes. The build registers each BehaviorNode class; the runtime offers them
/// to the engine when the game loads.</summary>
public static class BehaviorNodes
{
    private sealed record Kind(Type Type, Func<BehaviorNode> Create, FieldInfo[] Settings);

    private static readonly Dictionary<string, Kind> sKinds = new(StringComparer.Ordinal);
    private static readonly Dictionary<int, (BehaviorNode Node, string Values)> sLive = [];

    /// <summary>Called by the generated registry for each BehaviorNode class.</summary>
    public static void Register(Func<BehaviorNode> create, Type type)
    {
        // The class's own fields in declaration order, then each base class's (as the build's catalog lists them):
        // a node's values are kept by position.
        var settings = new List<FieldInfo>();
        for (Type? at = type; at != null && at != typeof(BehaviorNode); at = at.BaseType)
            settings.AddRange(at.GetFields(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
                .Where(field => !field.IsInitOnly && SettingType(field.FieldType) != null).OrderBy(DeclarationOrder));
        sKinds[type.FullName ?? type.Name] = new Kind(type, create, [.. settings]);
    }

    /// <summary>A field's place in its class's declaration. NativeAOT keeps no metadata tokens, but it lists a class's
    /// fields in declaration order already, so there the order they come in is kept.</summary>
    private static int DeclarationOrder(FieldInfo field) =>
        System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported ? field.MetadataToken : 0;

    private static string? SettingType(Type type) =>
        type == typeof(float) || type == typeof(int) || type == typeof(double) ? "Number" :
        type == typeof(bool) ? "Bool" : type == typeof(string) ? "Text" : type == typeof(Vector3) ? "Vector" : null;

    private static string Format(object? value) => value switch
    {
        null => "",
        bool flag => flag ? "true" : "false",
        float number => number.ToString(CultureInfo.InvariantCulture),
        double number => number.ToString(CultureInfo.InvariantCulture),
        int number => number.ToString(CultureInfo.InvariantCulture),
        Vector3 v => string.Create(CultureInfo.InvariantCulture, $"{v.X} {v.Y} {v.Z}"),
        _ => value.ToString() ?? "",
    };

    /// <summary>Gives the engine every registered kind (at load and reload).</summary>
    internal static void Publish()
    {
        foreach ((string className, Kind kind) in sKinds)
        {
            var info = kind.Type.GetCustomAttribute<BehaviorNodeAttribute>();
            BehaviorNode sample = kind.Create();
            var settings = string.Join('\x1e', kind.Settings.Select(field =>
                field.Name + "\x1f" + SettingType(field.FieldType) + "\x1f" + Format(field.GetValue(sample))));
            CSharpBehaviorNodes.Register(info?.Key ?? className, info?.Category ?? "Game", info?.Title ?? kind.Type.Name,
                info?.Condition == true ? 1 : 0, info?.Description ?? "", className, settings);
        }
    }

    /// <summary>The game's code is going: forgets its kinds and every running node.</summary>
    internal static void Clear()
    {
        sKinds.Clear();
        sLive.Clear();
    }

    /// <summary>A reload: the kinds come again from the new code, and running nodes are made again from it (with
    /// their settings, then OnStart) the next time they are ticked.</summary>
    internal static void Forget()
    {
        sKinds.Clear();
        foreach (int handle in sLive.Keys.ToArray())
            sLive[handle] = (null!, sLive[handle].Values);
    }

    private static void Fill(Kind kind, BehaviorNode node, string values)
    {
        string[] parts = values.Length == 0 ? [] : values.Split('\x1f');
        for (int i = 0; i < kind.Settings.Length && i < parts.Length; i++)
        {
            FieldInfo field = kind.Settings[i];
            string text = parts[i];
            object? value = field.FieldType == typeof(float) ? (float.TryParse(text, CultureInfo.InvariantCulture, out float f) ? f : 0f) :
                field.FieldType == typeof(double) ? (double.TryParse(text, CultureInfo.InvariantCulture, out double d) ? d : 0d) :
                field.FieldType == typeof(int) ? (float.TryParse(text, CultureInfo.InvariantCulture, out float n) ? (int)MathF.Round(n) : 0) :
                field.FieldType == typeof(bool) ? text is "true" or "1" :
                field.FieldType == typeof(string) ? text : ParseVector(text);
            field.SetValue(node, value);
        }
    }

    private static Vector3 ParseVector(string text)
    {
        string[] p = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        float At(int i) => i < p.Length && float.TryParse(p[i], CultureInfo.InvariantCulture, out float v) ? v : 0;
        return new Vector3(At(0), At(1), At(2));
    }

    /// <summary>One phase from the engine: 0 start, 1 tick, 2 end, 3 aborted, 4 gone. 1 running, 2 success, 3 failure.</summary>
    internal static int Call(int handle, int phase, string className, ulong session, ulong entity, string values, float deltaTime)
    {
        if (phase == 4)
        {
            sLive.Remove(handle);
            return 0;
        }
        if (!sKinds.TryGetValue(className, out Kind? kind))
            return 3;
        sLive.TryGetValue(handle, out var live);
        if (phase == 0)
            live.Values = values;
        bool made = live.Node == null || live.Node.GetType() != kind.Type;
        BehaviorNode node = made ? kind.Create() : live.Node!;
        live.Node = node;
        sLive[handle] = live;
        if (phase == 0 || made)
        {
            // A start; or a node made again part-way through a run (after a reload), which starts over.
            node.GameObject = new GameObject(session, entity);
            Fill(kind, node, live.Values ?? "");
            if (phase > 1)
                return 0;
            node.Start();
        }
        switch (phase)
        {
        case 0:
            return 1;
        case 1:
            return (int)node.Tick(deltaTime);
        default:
            node.End(phase == 3);
            return 0;
        }
    }
}
