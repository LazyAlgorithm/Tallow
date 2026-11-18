using System.Globalization;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

/// <summary>
/// The visual scripting nodes C# code offers, for the graph editor in a C# project:
/// .tallow-csharp/graph-nodes.tsv. Each public member of Tallow.API's gameplay types and of the game's own public
/// types whose parameters and result a pin can carry becomes a node, with the C# the graph compiler puts in for it.
///
/// Rows (tab separated), each "node" row followed by its pins:
///   node  key  category  title  Value|Action  code  game(0|1)
///   in    label  pin  typeName  fallback  default
///   out   label  pin  typeName  code
///   enum  typeName  member  member...   (the values an Enum pin of that type offers)
/// In code, {0}, {1}... are the data inputs in order and $N is the node's id. A fallback is the C# used when nothing
/// is connected to an object pin; a default is the value a value pin starts with, as the graph file writes it.
/// </summary>
internal static class GraphNodeCatalog
{
    /// <summary>Tallow.API static classes that are plumbing, not gameplay.</summary>
    private static readonly HashSet<string> HiddenTypes = new(StringComparer.Ordinal)
    {
        "Engine", "GeneratedNativeApi", "GraphRuntime", "TallowMathExtensions", "GameThread", "Ecs", "Physics",
        "CSharpSceneObjects", "CSharpComponents", "CSharpDraw", "CSharpNetwork", "CSharpSaves", "CSharpAudio",
        "CSharpInputActions", "CSharpGameplay", "CSharpBindingFixture", "Prefab"
    };

    /// <summary>Tallow.API types whose instances a pin carries, with what an unconnected pin means.</summary>
    private static readonly Dictionary<string, string> Handles = new(StringComparer.Ordinal)
    {
        ["GameObject"] = "GameObject",
        ["Transform"] = "Transform",
        ["Rigidbody"] = "GameObject.GetComponent<Rigidbody>()",
        ["CharacterController"] = "GameObject.GetComponent<CharacterController>()",
        ["SoftBody"] = "GameObject.GetComponent<SoftBody>()",
        ["Joint"] = "GameObject.GetComponent<Joint>()",
        ["Animator"] = "GameObject.GetComponentInChildren<Animator>()",
        ["Light"] = "GameObject.GetComponent<Light>()",
        ["MeshRenderer"] = "GameObject.GetComponent<MeshRenderer>()",
        ["NavigationAgent"] = "GameObject.GetComponent<NavigationAgent>()",
        ["VoxelObject"] = "GameObject.GetComponent<VoxelObject>()",
        ["UIDocument"] = "GameObject.GetComponent<UIDocument>()",
    };

    /// <summary>Script methods the engine calls; a node for one would make no sense.</summary>
    private static readonly HashSet<string> Lifecycle = new(StringComparer.Ordinal)
    {
        "Awake", "OnEnable", "Start", "FixedUpdate", "EarlyUpdate", "Update", "LateUpdate", "LocalEarlyUpdate", "LocalUpdate", "LocalLateUpdate", "OnDisable", "OnDestroy",
        "OnGUI", "OnCollisionEnter", "OnCollisionStay", "OnCollisionExit", "OnTriggerEnter", "OnTriggerStay",
        "OnTriggerExit", "OnControllerHit", "OnValidate", "OnReload", "OnDrawGizmos", "OnSaving", "OnLoaded",
        "OnNetworkEvent", "Attach", "Equals", "GetHashCode", "ToString", "Deconstruct", "PrintMembers", "GetType",
        "NextFrame", "Wait"
    };

    private static readonly string[] PurePrefixes =
    [
        "Get", "Is", "Has", "Can", "Find", "To", "Contains", "Count", "Distance", "Dot", "Cross", "Lerp", "Clamp", "Min",
        "Max", "Abs", "Sqrt", "Sin", "Cos", "Tan", "Atan", "Pow", "Sign", "Angle", "Normalize", "Euler", "Slerp", "Look",
        "Evaluate", "Sample", "Weight", "Length", "Check", "Overlap", "World", "Local", "Inverse", "Smooth", "Wrap",
        "Floor", "Perlin", "Fbm", "Average", "Transform", "Inverse", "Held", "Pressed", "Released", "Value", "Vector",
        "Delta", "Range", "Exists", "Key", "Mouse"
    ];

    private readonly record struct Pin(string Kind, string TypeName, bool Unwrap);

    private sealed class Node(string key, string category, string title, bool value, string code, bool game)
    {
        public readonly List<string> Rows = [];
        public string Head => string.Join('\t', "node", key, category, title, value ? "Value" : "Action", code, game ? "1" : "0");
        public string Key => key;
    }

    public static void Write(CSharpCompilation compilation, IReadOnlyCollection<SyntaxTree> gameTrees, string path)
    {
        var nodes = new SortedDictionary<string, Node>(StringComparer.Ordinal);
        var gameTypes = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
        foreach (SyntaxTree tree in gameTrees)
        {
            SemanticModel model = compilation.GetSemanticModel(tree);
            foreach (var declaration in tree.GetRoot().DescendantNodes()
                .OfType<Microsoft.CodeAnalysis.CSharp.Syntax.BaseTypeDeclarationSyntax>())
            {
                if (model.GetDeclaredSymbol(declaration) is INamedTypeSymbol type && Visible(type))
                    gameTypes.Add(type);
            }
        }
        INamedTypeSymbol? script = compilation.GetTypeByMetadataName("Tallow.Script");
        INamespaceSymbol? tallow = compilation.GlobalNamespace.GetNamespaceMembers().FirstOrDefault(n => n.Name == "Tallow");
        var context = new Context(script, gameTypes);
        if (tallow != null)
        {
            foreach (INamedTypeSymbol type in tallow.GetTypeMembers().OrderBy(t => t.Name, StringComparer.Ordinal))
            {
                if (type.DeclaredAccessibility != Accessibility.Public || HiddenTypes.Contains(type.Name) ||
                    type.IsGenericType || type.TypeKind is not (TypeKind.Class or TypeKind.Struct))
                    continue;
                if (type.IsStatic)
                    AddMembers(context, nodes, type, Owner.Static, false);
                else if (Handles.ContainsKey(type.Name))
                    AddMembers(context, nodes, type, Owner.Target, false);
                else if (type.Name == "Scene")
                    AddMembers(context, nodes, type, Owner.Scene, false);
                else if (SymbolEqualityComparer.Default.Equals(type, script))
                    AddMembers(context, nodes, type, Owner.This, false);
            }
        }
        foreach (INamedTypeSymbol type in gameTypes.OrderBy(t => t.ToDisplayString(), StringComparer.Ordinal))
        {
            if (type.TypeKind == TypeKind.Enum)
                continue;
            if (type.IsStatic || type.IsAbstract && type.IsSealed)
                AddMembers(context, nodes, type, Owner.Static, true);
            else if (context.IsScript(type))
                AddMembers(context, nodes, type, Owner.Target, true);
            else if (type.TypeKind == TypeKind.Class)
                AddMembers(context, nodes, type, Owner.StaticOnly, true);
        }
        var text = new StringBuilder();
        foreach ((string name, INamedTypeSymbol enumType) in context.Enums)
        {
            var members = enumType.GetMembers().OfType<IFieldSymbol>().Where(f => f.IsConst).Select(f => f.Name);
            text.Append(Row(["enum", name, .. members])).Append('\n');
        }
        foreach (Node node in nodes.Values)
        {
            text.Append(node.Head).Append('\n');
            foreach (string row in node.Rows)
                text.Append(row).Append('\n');
        }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string value = text.ToString();
        if (!File.Exists(path) || File.ReadAllText(path) != value)
        {
            string temporary = path + ".tmp";
            File.WriteAllText(temporary, value);
            File.Move(temporary, path, overwrite: true);
        }
        Console.WriteLine($"Visual scripting: {nodes.Count} nodes from C# code.");
    }

    private enum Owner { Static, StaticOnly, Target, Scene, This }

    private sealed class Context(INamedTypeSymbol? script, HashSet<INamedTypeSymbol> gameTypes)
    {
        /// <summary>The enums pins use, by the name the code writes.</summary>
        public readonly SortedDictionary<string, INamedTypeSymbol> Enums = new(StringComparer.Ordinal);

        public bool IsScript(ITypeSymbol type)
        {
            for (ITypeSymbol? at = type; at != null; at = at.BaseType)
            {
                if (SymbolEqualityComparer.Default.Equals(at, script))
                    return true;
            }
            return false;
        }

        public bool IsGame(ITypeSymbol type) => type is INamedTypeSymbol named && gameTypes.Contains(named);
    }

    private static bool Visible(INamedTypeSymbol type)
    {
        for (INamedTypeSymbol? at = type; at != null; at = at.ContainingType)
        {
            if (at.DeclaredAccessibility != Accessibility.Public)
                return false;
        }
        return !type.IsGenericType && type.ContainingType == null && type.TypeKind is TypeKind.Class or TypeKind.Struct or TypeKind.Enum;
    }

    /// <summary>The pin a C# type travels on, if any.</summary>
    private static Pin? PinFor(Context context, ITypeSymbol type)
    {
        bool unwrap = false;
        if (type is INamedTypeSymbol { OriginalDefinition.SpecialType: SpecialType.System_Nullable_T } nullable)
        {
            type = nullable.TypeArguments[0];
            unwrap = true;
        }
        switch (type.SpecialType)
        {
            case SpecialType.System_Single: return new Pin("Float", "float", unwrap);
            case SpecialType.System_Int32: return new Pin("Int", "int", unwrap);
            case SpecialType.System_Boolean: return new Pin("Bool", "bool", unwrap);
            case SpecialType.System_String: return new Pin("String", "string", false);
        }
        string ns = type.ContainingNamespace?.ToDisplayString() ?? "";
        if (ns == "System.Numerics" && type.Name is "Vector2" or "Vector3" or "Quaternion")
            return new Pin(type.Name, type.Name, unwrap);
        if (ns == "Tallow" && type.Name == "Color")
            return new Pin("Color", "Color", unwrap);
        if (ns == "Tallow" && Handles.ContainsKey(type.Name))
            return new Pin("Object", type.Name, unwrap);
        if (context.IsGame(type) && context.IsScript(type) && !type.IsAbstract)
            return new Pin("Object", type.ToDisplayString(), false);
        if (type is INamedTypeSymbol { TypeKind: TypeKind.Enum } enumType && enumType.DeclaredAccessibility == Accessibility.Public &&
            enumType.ContainingType == null && (ns == "Tallow" || context.IsGame(type)))
        {
            string name = ns == "Tallow" ? enumType.Name : enumType.ToDisplayString();
            context.Enums[name] = enumType;
            return new Pin("Enum", name, unwrap);
        }
        return null;
    }

    private static string Fallback(Pin pin) =>
        pin.Kind != "Object" ? "" : Handles.TryGetValue(pin.TypeName, out string? handle) ? handle : $"GetComponent<{pin.TypeName}>()";

    private static bool IsStruct(Pin pin) => pin.Kind != "Object" || pin.TypeName is not ("Transform") && Handles.ContainsKey(pin.TypeName);

    private static string Spaced(string name)
    {
        var text = new StringBuilder();
        for (int i = 0; i < name.Length; i++)
        {
            char c = name[i];
            if (i > 0 && char.IsUpper(c) && (char.IsLower(name[i - 1]) || i + 1 < name.Length && char.IsLower(name[i + 1]) && char.IsUpper(name[i - 1])))
                text.Append(' ');
            text.Append(c == '_' ? ' ' : c);
        }
        return text.ToString();
    }

    private static bool LooksPure(string name) => PurePrefixes.Any(name.StartsWith);

    private static string Row(params string[] parts) => string.Join('\t', parts.Select(p => p.Replace('\t', ' ').Replace('\n', ' ')));

    /// <summary>A parameter's default as the graph file writes a value, or "".</summary>
    private static string DefaultText(IParameterSymbol parameter)
    {
        if (!parameter.HasExplicitDefaultValue || parameter.ExplicitDefaultValue == null)
            return "";
        return parameter.ExplicitDefaultValue switch
        {
            float f => f.ToString(CultureInfo.InvariantCulture),
            int i => i.ToString(CultureInfo.InvariantCulture),
            bool b => b ? "true" : "false",
            string s => s,
            _ => ""
        };
    }

    private static void AddMembers(Context context, SortedDictionary<string, Node> nodes, INamedTypeSymbol type, Owner owner, bool game)
    {
        string typeName = game ? type.ToDisplayString() : type.Name;
        string label = Spaced(type.Name);
        string category = (game ? "My Scripts|" : "Engine|") + label;
        string qualified = game ? "global::" + type.ToDisplayString() : "Tallow." + type.Name;
        Pin? target = owner == Owner.Target ? PinFor(context, type) : null;
        if (owner == Owner.Target && target == null)
            return;
        bool targetIsClass = target is { } t && !IsStruct(t);
        foreach (ISymbol member in type.GetMembers().OrderBy(m => m.Name, StringComparer.Ordinal))
        {
            if (member.DeclaredAccessibility != Accessibility.Public || member.IsImplicitlyDeclared || Lifecycle.Contains(member.Name) ||
                member.Name.StartsWith("__", StringComparison.Ordinal) || member.GetAttributes().Any(a => a.AttributeClass?.Name == "ObsoleteAttribute"))
                continue;
            bool isStatic = member.IsStatic;
            if (owner == Owner.StaticOnly && !isStatic)
                continue;
            // What the member is called on, and the code for that.
            string on;
            if (isStatic)
                on = qualified;
            else if (owner == Owner.Scene)
                on = "Scene";
            else if (owner == Owner.This)
                on = "this";
            else if (owner == Owner.Target)
                on = targetIsClass ? "{0}?" : "{0}";
            else
                continue;
            bool hasTarget = !isStatic && owner == Owner.Target;
            switch (member)
            {
                case IPropertySymbol { IsIndexer: false, Parameters.Length: 0 } property:
                    AddValue(context, nodes, typeName, category, label, game, member.Name, property.Type, on, hasTarget, target,
                        property.GetMethod?.DeclaredAccessibility == Accessibility.Public,
                        property.SetMethod is { DeclaredAccessibility: Accessibility.Public, IsInitOnly: false });
                    break;
                case IFieldSymbol { IsConst: false, IsImplicitlyDeclared: false } field:
                    AddValue(context, nodes, typeName, category, label, game, member.Name, field.Type, on, hasTarget, target, true, !field.IsReadOnly);
                    break;
                case IMethodSymbol { MethodKind: MethodKind.Ordinary, IsGenericMethod: false } method:
                    AddMethod(context, nodes, typeName, category, label, game, method, on, hasTarget, target, type.Name is "Mathf" or "Noise" or "RotationMath");
                    break;
            }
        }
    }

    private static void TargetPin(Node node, string label, Pin target) =>
        node.Rows.Add(Row("in", label, target.Kind, target.TypeName, Fallback(target), ""));

    private static void AddValue(Context context, SortedDictionary<string, Node> nodes, string typeName, string category, string label,
        bool game, string name, ITypeSymbol memberType, string on, bool hasTarget, Pin? target, bool canGet, bool canSet)
    {
        if (PinFor(context, memberType) is not { } pin)
            return;
        bool nullableOwner = on.EndsWith('?');
        string read = $"{on}.{name}";
        if (pin.Unwrap || nullableOwner)
            read = $"({read} ?? default)";
        string key = $"api:{typeName}.{name}";
        if (canGet && !nodes.ContainsKey(key))
        {
            var get = new Node(key, category, $"{label}: {Spaced(name)}", true, read, game);
            if (hasTarget)
                TargetPin(get, label, target!.Value);
            get.Rows.Add(Row("out", "", pin.Kind, pin.TypeName, ""));
            nodes[key] = get;
        }
        // A struct handle's setters write through to the engine, so setting one on a copy is fine.
        if (!canSet || pin.Unwrap)
            return;
        string owner = on.TrimEnd('?');
        string write = hasTarget
            ? $"{{ var t$N = {owner}; if (GraphRuntime.IsValid(t$N)) t$N.{name} = {{1}}; }}"
            : $"{owner}.{name} = {{0}};";
        var set = new Node(key + "=", category, $"{label}: Set {Spaced(name)}", false, write, game);
        if (hasTarget)
            TargetPin(set, label, target!.Value);
        set.Rows.Add(Row("in", "Value", pin.Kind, pin.TypeName, Fallback(pin), ""));
        nodes[set.Key] = set;
    }

    private static void AddMethod(Context context, SortedDictionary<string, Node> nodes, string typeName, string category, string label,
        bool game, IMethodSymbol method, string on, bool hasTarget, Pin? target, bool mathType)
    {
        Pin? result = null;
        bool returns = !method.ReturnsVoid;
        if (returns && (result = PinFor(context, method.ReturnType)) == null)
            return;
        var arguments = new List<string>();
        var inputs = new List<string>();
        int input = hasTarget ? 1 : 0;
        foreach (IParameterSymbol parameter in method.Parameters)
        {
            if (parameter.RefKind != RefKind.None)
                return;
            // The script calling it, and the scene it is in, go in by themselves.
            if (parameter.Type.ToDisplayString() is "Tallow.Script" && arguments.Count == 0)
            {
                arguments.Add("this");
                continue;
            }
            if (parameter.Type.ToDisplayString() is "Tallow.Scene")
            {
                arguments.Add("Scene");
                continue;
            }
            if (PinFor(context, parameter.Type) is not { } pin || pin.Unwrap)
            {
                if (parameter.HasExplicitDefaultValue)
                    break;
                return;
            }
            arguments.Add($"{{{input++}}}");
            inputs.Add(Row("in", Spaced(parameter.Name), pin.Kind, pin.TypeName, Fallback(pin), DefaultText(parameter)));
        }
        bool pure = returns && (mathType || LooksPure(method.Name));
        string call = $"{on}.{method.Name}({string.Join(", ", arguments)})";
        if (returns && (result!.Value.Unwrap || on.EndsWith('?')))
            call = $"({call} ?? default)";
        string key = $"api:{typeName}.{method.Name}/{inputs.Count}";
        if (nodes.ContainsKey(key))
            return;
        var node = new Node(key, category, $"{label}: {Spaced(method.Name)}", pure, pure ? call : returns ? $"r$N = {call};" : call + ";", game);
        if (hasTarget)
            TargetPin(node, label, target!.Value);
        node.Rows.AddRange(inputs);
        if (returns)
            node.Rows.Add(Row("out", pure ? "" : "Result", result!.Value.Kind, result.Value.TypeName, pure ? "" : "r$N"));
        nodes[key] = node;
    }
}
