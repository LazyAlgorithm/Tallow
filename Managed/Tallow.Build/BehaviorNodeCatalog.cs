using System.Globalization;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;


/// <summary>
/// The game's C# behaviour tree nodes (BehaviorNode classes) for the editor, which offers them before the game runs:
/// .tallow-csharp/behavior-nodes.tsv, one row per class: key, category, title, 1 for a condition, description, class,
/// settings (each name 0x1F type 0x1F default, separated by 0x1E), as CSharpBehaviorNodes.Register takes them.
/// </summary>
internal static class BehaviorNodeCatalog
{
    public static void Write(CSharpCompilation compilation, IReadOnlyCollection<SyntaxTree> gameTrees, string path)
    {
        var rows = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (SyntaxTree tree in gameTrees)
        {
            SemanticModel model = compilation.GetSemanticModel(tree);
            foreach (ClassDeclarationSyntax node in tree.GetRoot().DescendantNodes().OfType<ClassDeclarationSyntax>())
            {
                if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol symbol || symbol.IsAbstract || symbol.IsGenericType ||
                    !IsBehaviorNode(symbol))
                    continue;
                string className = symbol.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat).Replace("global::", "");
                AttributeData? info = symbol.GetAttributes().FirstOrDefault(a => a.AttributeClass?.ToDisplayString() == "Tallow.BehaviorNodeAttribute");
                string Named(string name, string fallback) =>
                    info?.NamedArguments.FirstOrDefault(a => a.Key == name).Value.Value?.ToString() ?? fallback;
                string title = info?.ConstructorArguments.FirstOrDefault().Value?.ToString() ?? symbol.Name;
                bool condition = info?.NamedArguments.FirstOrDefault(a => a.Key == "Condition").Value.Value is true;
                var settings = new List<string>();
                // The class's own fields in declaration order, then each base class's: BehaviorNodes.Register orders
                // them the same way, as a node's values are kept by position.
                for (INamedTypeSymbol? type = symbol; type != null && type.ToDisplayString() != "Tallow.BehaviorNode"; type = type.BaseType)
                    foreach (IFieldSymbol field in type.GetMembers().OfType<IFieldSymbol>())
                    {
                        if (field.IsStatic || field.IsReadOnly || field.IsConst || field.DeclaredAccessibility != Accessibility.Public ||
                            SettingType(field.Type) is not string kind)
                            continue;
                        settings.Add(field.Name + "\x1f" + kind + "\x1f" + Default(compilation, field, kind));
                    }
                string key = Named("Key", className);
                rows[key] = string.Join('\t', key, Clean(Named("Category", "Game")), Clean(title), condition ? "1" : "0",
                    Clean(Named("Description", "")), className, string.Join('\x1e', settings));
            }
        }
        string text = string.Concat(rows.Values.Select(row => row + "\n"));
        if (File.Exists(path) && File.ReadAllText(path) == text)
            return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", text);
        File.Move(path + ".tmp", path, overwrite: true);
    }

    private static string Clean(string text) => text.Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');

    private static bool IsBehaviorNode(INamedTypeSymbol symbol)
    {
        for (INamedTypeSymbol? parent = symbol.BaseType; parent != null; parent = parent.BaseType)
            if (parent.ToDisplayString() == "Tallow.BehaviorNode")
                return true;
        return false;
    }

    private static string? SettingType(ITypeSymbol type) => type.SpecialType switch
    {
        SpecialType.System_Single or SpecialType.System_Double or SpecialType.System_Int32 => "Number",
        SpecialType.System_Boolean => "Bool",
        SpecialType.System_String => "Text",
        _ => type.ToDisplayString() == "System.Numerics.Vector3" ? "Vector" : null,
    };

    /// <summary>The field's initializer when it is a constant (or new Vector3 of constants); else the type's default.</summary>
    private static string Default(CSharpCompilation compilation, IFieldSymbol field, string kind)
    {
        foreach (SyntaxReference reference in field.DeclaringSyntaxReferences)
        {
            if (reference.GetSyntax() is not VariableDeclaratorSyntax { Initializer.Value: ExpressionSyntax value })
                continue;
            SemanticModel model = compilation.GetSemanticModel(value.SyntaxTree);
            if (kind == "Vector" && value is BaseObjectCreationExpressionSyntax { ArgumentList: { } arguments })
            {
                var parts = arguments.Arguments.Select(a => model.GetConstantValue(a.Expression)).ToList();
                if (parts.All(p => p.HasValue))
                {
                    var numbers = parts.Select(p => Convert.ToSingle(p.Value, CultureInfo.InvariantCulture)).ToList();
                    if (numbers.Count == 1)
                        numbers = [numbers[0], numbers[0], numbers[0]];
                    if (numbers.Count == 3)
                        return string.Join(' ', numbers.Select(n => n.ToString(CultureInfo.InvariantCulture)));
                }
            }
            Optional<object?> constant = model.GetConstantValue(value);
            if (constant.HasValue)
                return constant.Value switch
                {
                    bool flag => flag ? "true" : "false",
                    IFormattable number => number.ToString(null, CultureInfo.InvariantCulture),
                    null => "",
                    object other => Clean(other.ToString() ?? ""),
                };
        }
        return kind switch { "Number" => "0", "Bool" => "false", "Vector" => "0 0 0", _ => "" };
    }
}
