using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Tallow.ManagedBuild;

/// <summary>
/// Generates and builds trusted gameplay assemblies from project C# and
/// assembly definitions. No Python, plug-in discovery or mod loading.
/// </summary>
internal static class Program
{
    private sealed record Definition(string Name, string Folder, List<string> References, string RootNamespace,
        List<PackageRef> Packages);

    /// <summary>A NuGet package an assembly definition uses, at one exact version.</summary>
    private sealed record PackageRef(string Id, string Version);

    private static readonly Regex PackageId = new(@"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$", RegexOptions.CultureInvariant);
    private static readonly Regex PackageVersion = new(@"^\d+(\.\d+){1,3}(-[0-9A-Za-z.-]+)?$", RegexOptions.CultureInvariant);

    private static readonly Regex AssemblyName = new(
        @"^[A-Za-z_][A-Za-z0-9_.]*$", RegexOptions.CultureInvariant);

    // Identifiers can survive renames when explicitly supplied. Limit their
    // alphabet so the generated source/scene manifest needs no escaping.
    private static readonly Regex SerializedIdName = new(
        @"^[A-Za-z0-9_.-]{1,64}$", RegexOptions.CultureInvariant);

    // A struct or class of the game's own marked [Serializable]: the Inspector shows its fields under it.
    private static bool IsNestedInspectorType(ITypeSymbol type) =>
        type is INamedTypeSymbol { TypeKind: TypeKind.Struct or TypeKind.Class } named &&
        named.Locations.Any(location => location.IsInSource) &&
        named.GetAttributes().Any(a => a.AttributeClass?.ToDisplayString() == "System.SerializableAttribute") &&
        !InheritsScript(named);

    private static bool InheritsScript(INamedTypeSymbol type)
    {
        for (INamedTypeSymbol? owner = type; owner != null; owner = owner.BaseType)
            if (owner.ToDisplayString() == "Tallow.Script")
                return true;
        return false;
    }

    /// <summary>A list item type's fields for the Inspector (fields.tsv column 8 of a "list:record" row):
    /// "Name~kind~default~options" joined by '|', options being an enum's names joined by '/'. Only fields of
    /// value kinds; null when there are none.</summary>
    private static string? RecordSchema(ITypeSymbol type)
    {
        var entries = new List<string>();
        foreach (IFieldSymbol inner in type.GetMembers().OfType<IFieldSymbol>())
        {
            var attributes = inner.GetAttributes().Select(a => a.AttributeClass?.ToDisplayString())
                .ToHashSet(StringComparer.Ordinal);
            bool shown = attributes.Contains("Tallow.ShowInInspectorAttribute") ||
                attributes.Contains("Tallow.HideInInspectorAttribute");
            if ((inner.DeclaredAccessibility != Accessibility.Public && !shown) || inner.IsStatic || inner.IsConst ||
                inner.IsReadOnly || inner.IsImplicitlyDeclared || attributes.Contains("System.NonSerializedAttribute") ||
                attributes.Contains("Tallow.HideInInspectorAttribute"))
                continue;
            string? kind = InspectorScalarKind(inner.Type);
            if (kind is null)
                continue;
            string value = kind switch
            {
                "bool" => "false", "string" => "", "Vector2" => "0,0", "Vector3" => "0,0,0",
                "Vector4" => "0,0,0,0", "Color" => "1,1,1,1", _ => "0"
            };
            string options = "";
            if (inner.Type is INamedTypeSymbol { TypeKind: TypeKind.Enum } enumType)
            {
                var names = enumType.GetMembers().OfType<IFieldSymbol>()
                    .Where(member => member.HasConstantValue && !member.IsImplicitlyDeclared).ToList();
                options = string.Join("/", names.Select(member => member.Name));
                value = names.FirstOrDefault()?.Name ?? "0";
            }
            // A constant initializer (`public int Count = 3;`) is the new item's value.
            if (inner.DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax() is VariableDeclaratorSyntax
                { Initializer.Value: { } initializer })
            {
                object? constant = (initializer as LiteralExpressionSyntax)?.Token.Value;
                if (initializer is PrefixUnaryExpressionSyntax { RawKind: (int)SyntaxKind.UnaryMinusExpression,
                        Operand: LiteralExpressionSyntax negated })
                    constant = negated.Token.Value switch
                    {
                        int x => -x, float x => -x, double x => -x, long x => -x, _ => null
                    };
                else if (initializer is MemberAccessExpressionSyntax member && kind == "enum")
                    constant = member.Name.Identifier.Text;
                if (constant is bool flag)
                    value = flag ? "true" : "false";
                else if (constant is string text && kind is "string" or "enum")
                    value = text;
                else if (constant is IFormattable number && kind is not ("bool" or "string" or "enum"))
                    value = number.ToString(null, CultureInfo.InvariantCulture);
            }
            if (value.IndexOfAny(['|', '~', '\t', '\n', '\r']) >= 0)
                value = "";
            entries.Add(string.Join("~", inner.Name, kind, value, options));
        }
        return entries.Count == 0 ? null : string.Join("|", entries);
    }

    /// <summary>A field's /// comment as one line of plain text: the &lt;summary&gt; when there is one, tags
    /// dropped (a &lt;see cref="X"/&gt; keeps its name), whitespace collapsed; "" when it has none.</summary>
    private static string FieldDocumentation(IFieldSymbol field)
    {
        if (field.DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax() is not VariableDeclaratorSyntax declarator ||
            declarator.Parent?.Parent is not FieldDeclarationSyntax declaration)
            return "";
        var text = new StringBuilder();
        foreach (SyntaxTrivia trivia in declaration.GetLeadingTrivia())
            foreach (string line in trivia.ToFullString().Split('\n'))
            {
                string trimmed = line.Trim();
                if (trimmed.StartsWith("///", StringComparison.Ordinal))
                    text.Append(trimmed[3..]).Append(' ');
            }
        string xml = text.ToString();
        Match summary = Regex.Match(xml, "<summary>(.*?)</summary>", RegexOptions.Singleline);
        if (summary.Success)
            xml = summary.Groups[1].Value;
        xml = Regex.Replace(xml, "<(?:see|seealso|paramref|typeparamref)\\s+\\w+=\"(?:[A-Z]:)?([^\"]*)\"\\s*/>", "$1");
        xml = Regex.Replace(xml, "<[^>]*>", "");
        xml = System.Net.WebUtility.HtmlDecode(xml);
        xml = Regex.Replace(xml, "\\s+", " ").Trim();
        return xml.Length > 400 ? xml[..400] + "..." : xml;
    }

    // What the Inspector edits a value of this type as (fields.tsv kinds), or null when it cannot.
    private static string? InspectorScalarKind(ITypeSymbol type) =>
        type.TypeKind == TypeKind.Enum ? "enum" : type.SpecialType switch
        {
            SpecialType.System_Single => "float",
            SpecialType.System_Double => "double",
            SpecialType.System_Int32 => "int",
            SpecialType.System_UInt32 => "uint",
            SpecialType.System_Int64 => "long",
            SpecialType.System_Boolean => "bool",
            SpecialType.System_String => "string",
            _ => type.ToDisplayString() switch
            {
                "System.Numerics.Vector2" => "Vector2",
                "System.Numerics.Vector3" => "Vector3",
                "System.Numerics.Vector4" => "Vector4",
                "Tallow.Color" => "Color",
                _ => null
            }
        };

    /// <summary>
    /// For an Inspector reference field: "GameObject", "Transform", "native:Tallow.Light" (a built-in component handle,
    /// named by its [NativeComponent] attribute) or "script:Namespace.Class" (a C# script); null for anything else.
    /// </summary>
    private static string? ReferenceDescriptor(ITypeSymbol type)
    {
        if (type is INamedTypeSymbol { OriginalDefinition.SpecialType: SpecialType.System_Nullable_T } nullable)
            type = nullable.TypeArguments[0];
        string name = type.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat).Replace("global::", "");
        if (name is "Tallow.GameObject" or "Tallow.Transform")
            return name["Tallow.".Length..];
        AttributeData? native = type.GetAttributes().FirstOrDefault(a =>
            a.AttributeClass?.ToDisplayString() == "Tallow.NativeComponentAttribute");
        if (native is { ConstructorArguments.Length: 1 } && native.ConstructorArguments[0].Value is string nativeName)
            return "native:" + nativeName;
        for (ITypeSymbol? baseType = type.BaseType; baseType != null; baseType = baseType.BaseType)
        {
            if (baseType.ToDisplayString() == "Tallow.Script")
                return type is INamedTypeSymbol { IsAbstract: false, IsGenericType: false } ? "script:" + name : null;
        }
        return null;
    }

    private static string StableFieldId(string componentName, string identity)
    {
        byte[] value = SHA256.HashData(Encoding.UTF8.GetBytes(
            "TALLOW_FIELD_V1:" + componentName + ":" + identity));
        // 128 bits avoids accidental collisions without exposing field names
        // in a later compiled release registration table.
        return Convert.ToHexString(value.AsSpan(0, 16));
    }

    private static string RequiredOption(string[] args, string option)
    {
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == option && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                return args[i + 1];
        throw new ArgumentException($"Missing {option}.");
    }

    private static bool Flag(string[] args, string flag) => args.Contains(flag);

    private const string ImplicitUsings =
        "global using System; global using System.Collections.Generic; global using System.IO; " +
        "global using System.Linq; global using System.Net.Http; global using System.Threading; " +
        "global using System.Threading.Tasks; ";

    /// The names in a script class's [FormerlyNamed("...")] attributes.
    private static IEnumerable<string> FormerNamesOf(INamedTypeSymbol symbol) =>
        symbol.GetAttributes()
            .Where(a => a.AttributeClass?.ToDisplayString() == "Tallow.FormerlyNamedAttribute" &&
                a.ConstructorArguments.Length == 1 && a.ConstructorArguments[0].Value is string)
            .Select(a => ((string)a.ConstructorArguments[0].Value!).Trim())
            .Where(name => name.Length > 0);

    private static string? OptionalOption(string[] args, string option)
    {
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i] == option && !args[i + 1].StartsWith("--", StringComparison.Ordinal))
                return args[i + 1];
        return null;
    }

    private static Dictionary<string, Definition> ReadDefinitions(string source)
    {
        var definitions = new Dictionary<string, Definition>(StringComparer.Ordinal);
        var folders = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string path in Directory.EnumerateFiles(source, "*.tasmdef", SearchOption.AllDirectories).Order())
        {
            using JsonDocument json = JsonDocument.Parse(File.ReadAllText(path));
            JsonElement root = json.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("name", out JsonElement nameValue) ||
                nameValue.ValueKind != JsonValueKind.String)
                throw new InvalidOperationException($"Invalid assembly definition: {path}");

            string name = nameValue.GetString()!;
            string folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
            if (!AssemblyName.IsMatch(name) || name is "Tallow.Game" or "Tallow.API" or "Tallow.Editor" or EditorAssembly ||
                definitions.ContainsKey(name) || !folders.Add(folder))
                throw new InvalidOperationException($"Invalid or duplicate assembly definition: {path}");

            var references = new List<string>();
            if (root.TryGetProperty("references", out JsonElement refs))
            {
                if (refs.ValueKind != JsonValueKind.Array)
                    throw new InvalidOperationException($"Invalid references in: {path}");
                foreach (JsonElement reference in refs.EnumerateArray())
                {
                    if (reference.ValueKind != JsonValueKind.String)
                        throw new InvalidOperationException($"Invalid assembly reference in: {path}");
                    references.Add(reference.GetString()!);
                }
            }
            // Optional, as in Unity: the namespace the editor gives new scripts in this assembly.
            string rootNamespace = name;
            if (root.TryGetProperty("rootNamespace", out JsonElement namespaceValue))
            {
                if (namespaceValue.ValueKind != JsonValueKind.String)
                    throw new InvalidOperationException($"Invalid rootNamespace in: {path}");
                string text = namespaceValue.GetString()!;
                if (text.Length > 0)
                {
                    if (!text.Split('.').All(part => AssemblyName.IsMatch(part)))
                        throw new InvalidOperationException($"Invalid rootNamespace '{text}' in: {path}");
                    rootNamespace = text;
                }
            }
            // NuGet packages: [{ "id": "Newtonsoft.Json", "version": "13.0.4" }], exact versions only, so every
            // build of the game gets the same code.
            var packages = new List<PackageRef>();
            if (root.TryGetProperty("packages", out JsonElement packageList))
            {
                if (packageList.ValueKind != JsonValueKind.Array)
                    throw new InvalidOperationException($"Invalid packages in: {path}");
                foreach (JsonElement package in packageList.EnumerateArray())
                {
                    if (package.ValueKind != JsonValueKind.Object ||
                        !package.TryGetProperty("id", out JsonElement id) || id.ValueKind != JsonValueKind.String ||
                        !package.TryGetProperty("version", out JsonElement version) || version.ValueKind != JsonValueKind.String)
                        throw new InvalidOperationException($"A package in {path} needs an \"id\" and a \"version\".");
                    string idText = id.GetString()!, versionText = version.GetString()!;
                    if (!PackageId.IsMatch(idText))
                        throw new InvalidOperationException($"Invalid package id '{idText}' in: {path}");
                    if (!PackageVersion.IsMatch(versionText))
                        throw new InvalidOperationException(
                            $"Package {idText} in {path} needs one exact version (like 13.0.4), not '{versionText}'.");
                    if (packages.Any(existing => string.Equals(existing.Id, idText, StringComparison.OrdinalIgnoreCase)))
                        throw new InvalidOperationException($"Package {idText} is listed twice in: {path}");
                    packages.Add(new PackageRef(idText, versionText));
                }
            }
            definitions.Add(name, new Definition(name, folder, references, rootNamespace, packages));
        }

        foreach (Definition definition in definitions.Values)
            foreach (string reference in definition.References)
                if (!definitions.ContainsKey(reference) || reference == definition.Name)
                    throw new InvalidOperationException(
                        $"{definition.Name} has an invalid dependency on {reference}.");

        var visiting = new HashSet<string>();
        var visited = new HashSet<string>();
        void Visit(string name)
        {
            if (visiting.Contains(name))
                throw new InvalidOperationException($"Circular assembly references involving {name}.");
            if (visited.Contains(name))
                return;
            visiting.Add(name);
            foreach (string reference in definitions[name].References)
                Visit(reference);
            visiting.Remove(name);
            visited.Add(name);
        }

        foreach (string name in definitions.Keys)
            Visit(name);
        return definitions;
    }

    /// <summary>The assembly of a game's editor scripts: every .cs file in a folder named Editor (at any depth under
    /// src/, as in Unity). It references the game's assemblies and Tallow.Editor; nothing references it, so a game
    /// build never has it.</summary>
    internal const string EditorAssembly = "Tallow.Game.Editor";

    internal static bool IsEditorFile(string source, string file) =>
        Path.GetRelativePath(source, Path.GetFullPath(file))
            .Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .SkipLast(1)
            .Any(folder => folder == "Editor");

    private static bool IsInFolder(string file, string folder)
    {
        string relative = Path.GetRelativePath(folder, file);
        return relative != ".." && !Path.IsPathRooted(relative) &&
            !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal);
    }

    private static XDocument CreateProject(
        string name, string rootNamespace, IEnumerable<string> files, IEnumerable<string> references,
        string api, string output, string binRoot, IReadOnlyList<PackageRef> packages)
    {
        var properties = new XElement("PropertyGroup",
            new XElement("TargetFramework", "net11.0"),
            new XElement("LangVersion", "15.0"),
            new XElement("AssemblyName", name),
            new XElement("RootNamespace", rootNamespace),
            new XElement("Nullable", "enable"),
            new XElement("ImplicitUsings", "enable"),
            new XElement("EnableDefaultCompileItems", "false"),
            new XElement("AllowUnsafeBlocks", "false"),
            new XElement("Deterministic", "true"),
            new XElement("AppendTargetFrameworkToOutputPath", "false"),
            new XElement("AppendRuntimeIdentifierToOutputPath", "false"),
            new XElement("OutputPath", output + Path.DirectorySeparatorChar),
            // A NuGet package's assemblies go beside the game's, where the runtime looks for them.
            new XElement("CopyLocalLockFileAssemblies", "true"));
        properties.AddFirst(new XElement("TallowBinRoot",
            new XAttribute("Condition", "'$(TallowBinRoot)' == ''"),
            binRoot + Path.DirectorySeparatorChar));
        var includes = new XElement("ItemGroup",
            // Using is an MSBuild item, not a PropertyGroup property.
            new XElement("Using", new XAttribute("Include", "System.Numerics")),
            // Typed ECS data extensions are generated in each trusted
            // assembly and should be discoverable like built-in APIs.
            new XElement("Using", new XAttribute("Include", "Tallow.Generated")),
            files.Select(file => new XElement("Compile", new XAttribute("Include", file))));
        var refs = new XElement("ItemGroup",
            new XElement("ProjectReference", new XAttribute("Include", api)));
        foreach (string reference in references)
            refs.Add(new XElement("ProjectReference", new XAttribute("Include", reference)));
        foreach (PackageRef package in packages)
            refs.Add(new XElement("PackageReference", new XAttribute("Include", package.Id),
                new XAttribute("Version", "[" + package.Version + "]")));
        return new XDocument(new XElement("Project", new XAttribute("Sdk", "Microsoft.NET.Sdk"),
            properties, includes, refs));
    }


    /// <summary>
    /// Generate direct C# factories in each trusted gameplay assembly, before
    /// building that assembly. This preserves access to internal component
    /// classes and provides an AOT-linkable root without reflection or IL DLL
    /// discovery. The current editor keeps its collectible JIT loader.
    /// </summary>
    /// <summary>Accessible from generated code in the type's own assembly (no private or protected nesting).</summary>
    private static bool Nameable(ITypeSymbol type)
    {
        switch (type)
        {
            case IArrayTypeSymbol array:
                return Nameable(array.ElementType);
            case INamedTypeSymbol named:
                for (INamedTypeSymbol? scope = named; scope != null; scope = scope.ContainingType)
                    // A file-local type is nameable only inside its own file, never by generated code.
                    if (scope.DeclaredAccessibility is not (Accessibility.Public or Accessibility.Internal) ||
                        scope.IsFileLocal)
                        return false;
                return named.TypeArguments.All(Nameable);
            default:
                return false;
        }
    }

    /// <summary>For NativeAOT, the generic instantiations the runtime's Inspector code makes for a script's fields
    /// (and those of the [Serializable] classes and structs they hold): List&lt;T&gt; and T[] of list items, and
    /// TryGetComponent&lt;T&gt; for component references. Reference types share code, so only value types and
    /// component lookups need naming, but naming all is harmless.</summary>
    private static void AddAotRoots(INamedTypeSymbol type, SortedSet<string> roots, HashSet<ITypeSymbol> seen)
    {
        if (!seen.Add(type) || seen.Count > 512)
            return;
        for (INamedTypeSymbol? at = type; at != null && at.ToDisplayString() != "Tallow.Script" &&
             at.SpecialType != SpecialType.System_Object && at.SpecialType != SpecialType.System_ValueType; at = at.BaseType)
        {
            foreach (IFieldSymbol field in at.GetMembers().OfType<IFieldSymbol>())
            {
                if (field.IsStatic || field.IsConst)
                    continue;
                AddAotRootsFor(field.Type, roots, seen);
            }
        }
    }

    private static void AddAotRootsFor(ITypeSymbol fieldType, SortedSet<string> roots, HashSet<ITypeSymbol> seen)
    {
        ITypeSymbol type = fieldType.WithNullableAnnotation(NullableAnnotation.NotAnnotated);
        if (type is INamedTypeSymbol { OriginalDefinition.SpecialType: SpecialType.System_Nullable_T } nullable)
            type = nullable.TypeArguments[0];
        ITypeSymbol? element = type switch
        {
            IArrayTypeSymbol { Rank: 1 } array => array.ElementType,
            INamedTypeSymbol named when named.OriginalDefinition.ToDisplayString() == "System.Collections.Generic.List<T>" => named.TypeArguments[0],
            _ => null
        };
        if (element != null)
        {
            if (Nameable(element) && element.TypeKind != TypeKind.TypeParameter)
            {
                string name = element.WithNullableAnnotation(NullableAnnotation.NotAnnotated).ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat);
                roots.Add($"_ = new global::System.Collections.Generic.List<{name}>();");
                roots.Add($"_ = new {name}[0];");
            }
            AddAotRootsFor(element, roots, seen);
            return;
        }
        if (type is not INamedTypeSymbol target || !Nameable(target) || target.IsGenericType)
            return;
        bool component = target.AllInterfaces.Any(i => i.ToDisplayString() == "Tallow.IComponent");
        string full = target.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat);
        if (component && !target.IsAbstract)
            roots.Add($"default(global::Tallow.GameObject).TryGetComponent<{full}>(out _);");
        // Classes and structs of the game's own that the Inspector edits field by field.
        else if (!component && target.Locations.Any(location => location.IsInSource) &&
                 target.TypeKind is TypeKind.Class or TypeKind.Struct)
            AddAotRoots(target, roots, seen);
    }

    private static void WriteComponentFactories(
        string engine, string generated, Dictionary<string, List<string>> filesByAssembly)
    {
        var parse = new CSharpParseOptions(LanguageVersion.CSharp15);
        var treesByPath = filesByAssembly.Values.SelectMany(files => files)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToDictionary(path => path,
                path => CSharpSyntaxTree.ParseText(File.ReadAllText(path), parse, path),
                StringComparer.OrdinalIgnoreCase);
        string apiDirectory = Path.Combine(engine, "Managed", "Tallow.API");
        var apiTrees = Directory.EnumerateFiles(apiDirectory, "*.cs", SearchOption.AllDirectories)
            .Where(path => !Path.GetRelativePath(apiDirectory, path)
                .Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                .Any(segment => segment is "bin" or "obj"))
            .Select(path => CSharpSyntaxTree.ParseText(File.ReadAllText(path), parse, path));
        string trusted = (string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES") ?? "";
        var refs = trusted.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(path => MetadataReference.CreateFromFile(path));
        // The SDK's implicit usings (both Tallow.API and game projects enable them), so that attributes declared
        // with plain "Attribute" bind and their arguments can be read.
        var compilation = CSharpCompilation.Create("Tallow.StaticComponentFactories",
            treesByPath.Values.Cast<SyntaxTree>().Concat(apiTrees).Append(
                CSharpSyntaxTree.ParseText(ImplicitUsings + "global using System.Numerics;", parse)),
            refs, new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary,
                allowUnsafe: true));

        var allTypes = new Dictionary<string, SortedDictionary<string, string>>(
            StringComparer.Ordinal);
        var formerNames = new SortedDictionary<string, string>(StringComparer.Ordinal);
        // Each assembly gets its own typed local-data adapters. No gameplay
        // assembly scanning or reflection is needed after C# compilation.
        var allEcsTypes = new Dictionary<string,
            SortedDictionary<string, (string CSharpType, string SchemaId, string Describe)>>(
                StringComparer.Ordinal);
        // EcsSystem<T> classes by assembly: display name -> fully qualified type.
        var allSystems = new Dictionary<string, SortedDictionary<string, string>>(StringComparer.Ordinal);
        // BehaviorNode classes by assembly (fully qualified types): registered when the assembly loads.
        var allBehaviorNodes = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        // DataAsset classes by assembly (fully qualified type -> the name .tdata files use): their constructors are
        // generated, so loading an asset never scans assemblies or reflects over constructors.
        var allDataAssets = new Dictionary<string, SortedDictionary<string, string>>(StringComparer.Ordinal);
        // [GameStart] methods by assembly (fully qualified): run once each time the game's code loads.
        var allGameStarts = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        // NativeAOT: generic code the runtime makes for Inspector fields by reflection (List<T> of a field's items,
        // GetComponent<T> for an object reference), named in code so the AOT compiler builds it (AotRoots).
        var allAotRoots = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        foreach (var (assembly, sourceFiles) in filesByAssembly)
        {
            var aotRoots = new SortedSet<string>(StringComparer.Ordinal);
            allAotRoots[assembly] = aotRoots;
            var types = new SortedDictionary<string, string>(StringComparer.Ordinal);
            var ecsTypes = new SortedDictionary<string, (string CSharpType, string SchemaId, string Describe)>(
                StringComparer.Ordinal);
            var systems = new SortedDictionary<string, string>(StringComparer.Ordinal);
            allSystems[assembly] = systems;
            var behaviorNodes = new SortedSet<string>(StringComparer.Ordinal);
            allBehaviorNodes[assembly] = behaviorNodes;
            var dataAssets = new SortedDictionary<string, string>(StringComparer.Ordinal);
            allDataAssets[assembly] = dataAssets;
            var gameStarts = new SortedSet<string>(StringComparer.Ordinal);
            allGameStarts[assembly] = gameStarts;
            foreach (string sourceFile in sourceFiles)
            {
                SyntaxTree tree = treesByPath[sourceFile];
                SemanticModel model = compilation.GetSemanticModel(tree);
                foreach (ClassDeclarationSyntax node in tree.GetRoot().DescendantNodes()
                    .OfType<ClassDeclarationSyntax>())
                {
                    if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol symbol)
                        continue;
                    foreach (IMethodSymbol method in symbol.GetMembers().OfType<IMethodSymbol>())
                    {
                        if (!method.GetAttributes().Any(a => a.AttributeClass?.ToDisplayString() == "Tallow.GameStartAttribute"))
                            continue;
                        bool reachable = true;
                        for (ISymbol? at = method; at is not null and not INamespaceSymbol; at = at.ContainingSymbol)
                            reachable &= at.DeclaredAccessibility is Accessibility.Public or Accessibility.Internal;
                        if (!method.IsStatic || method.Parameters.Length != 0 || method.IsGenericMethod ||
                            !method.ReturnsVoid || !reachable || symbol.IsGenericType)
                        {
                            var at = method.Locations.FirstOrDefault()?.GetLineSpan();
                            throw new InvalidOperationException(
                                $"{at?.Path}({(at?.StartLinePosition.Line ?? 0) + 1}): [GameStart] {method.Name} must be a " +
                                "static void method with no parameters, public or internal, in a public or internal class.");
                        }
                        gameStarts.Add(symbol.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat) + "." + method.Name);
                    }
                    // Deriving from Script identifies a gameplay behaviour;
                    // [Component] is reserved for explicit ECS data structs.
                    bool isScript = false, isSystem = false, isBehaviorNode = false, isDataAsset = false;
                    for (INamedTypeSymbol? parent = symbol.BaseType; parent != null;
                         parent = parent.BaseType)
                    {
                        if (parent.ToDisplayString() == "Tallow.Script")
                        {
                            isScript = true;
                            break;
                        }
                        if (parent.ToDisplayString() == "Tallow.DataAsset")
                        {
                            isDataAsset = true;
                            break;
                        }
                        if (parent.ToDisplayString() == "Tallow.BehaviorNode")
                        {
                            isBehaviorNode = true;
                            break;
                        }
                        if (parent.OriginalDefinition.ToDisplayString() is "Tallow.EcsSystem<T>" or "Tallow.EcsSystem<T1, T2>"
                            or "Tallow.EcsSystem<T1, T2, T3>")
                        {
                            isSystem = true;
                            break;
                        }
                    }
                    // An ECS system: made and registered when the assembly loads (EcsSystems.Register).
                    if (isSystem && !symbol.IsAbstract && !symbol.IsGenericType &&
                        symbol.DeclaredAccessibility is Accessibility.Public or Accessibility.Internal &&
                        symbol.InstanceConstructors.Any(ctor => ctor.Parameters.Length == 0 &&
                            ctor.DeclaredAccessibility is Accessibility.Public or Accessibility.Internal))
                        systems[symbol.ToDisplayString(SymbolDisplayFormat.CSharpErrorMessageFormat)] =
                            symbol.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat);
                    // A C# behaviour tree node kind (BehaviorNodes.Register).
                    if (isBehaviorNode && !symbol.IsAbstract && !symbol.IsGenericType &&
                        symbol.DeclaredAccessibility is Accessibility.Public or Accessibility.Internal &&
                        symbol.InstanceConstructors.Any(ctor => ctor.Parameters.Length == 0 &&
                            ctor.DeclaredAccessibility is Accessibility.Public or Accessibility.Internal))
                        behaviorNodes.Add(symbol.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat));
                    // A DataAsset class: registered with a generated constructor, so a .tdata file naming it loads
                    // without Assembly.GetTypes or Activator (NativeAOT has neither).
                    if (isDataAsset)
                    {
                        if (!symbol.IsAbstract && !symbol.IsGenericType && Nameable(symbol) &&
                            symbol.InstanceConstructors.Any(ctor => ctor.Parameters.Length == 0 &&
                                ctor.DeclaredAccessibility is Accessibility.Public or Accessibility.Internal))
                            dataAssets[symbol.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat)] =
                                symbol.ToDisplayString(SymbolDisplayFormat.CSharpErrorMessageFormat);
                        continue;
                    }
                    if (!isScript)
                        continue; // ECS struct/data will use a separate layout-safe registration path.
                    if (symbol.IsAbstract || symbol.IsGenericType)
                        continue;

                    // A registry in the SAME assembly can create internal
                    // classes, but not private nested classes.
                    for (INamedTypeSymbol? scope = symbol; scope != null;
                         scope = scope.ContainingType)
                        if (scope.DeclaredAccessibility is not
                            (Accessibility.Public or Accessibility.Internal))
                            throw new InvalidOperationException(
                                $"Script component {symbol} is inaccessible to generated " +
                                "registration. Make the component class internal or public.");

                    if (!symbol.InstanceConstructors.Any(ctor =>
                            ctor.Parameters.Length == 0 &&
                            ctor.DeclaredAccessibility is
                                (Accessibility.Public or Accessibility.Internal)))
                        throw new InvalidOperationException(
                            $"Script component {symbol} needs a parameterless " +
                            "constructor accessible to generated registration.");

                    string name = symbol.ToDisplayString(
                        SymbolDisplayFormat.CSharpErrorMessageFormat);
                    types[name] = symbol.ToDisplayString(
                        SymbolDisplayFormat.FullyQualifiedFormat);
                    AddAotRoots(symbol, aotRoots, new HashSet<ITypeSymbol>(SymbolEqualityComparer.Default));
                    foreach (string former in FormerNamesOf(symbol))
                    {
                        if (formerNames.TryGetValue(former, out string? other) && other != name)
                            throw new InvalidOperationException(
                                $"[FormerlyNamed(\"{former}\")] is on both {other} and {name}.");
                        formerNames[former] = name;
                    }
                }

                foreach (StructDeclarationSyntax node in tree.GetRoot().DescendantNodes()
                    .OfType<StructDeclarationSyntax>())
                {
                    if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol symbol ||
                        !symbol.GetAttributes().Any(a =>
                            a.AttributeClass?.ToDisplayString() == "Tallow.ComponentAttribute") ||
                        !symbol.IsUnmanagedType || symbol.IsRefLikeType ||
                        symbol.IsGenericType)
                        continue;

                    bool accessible = true;
                    for (INamedTypeSymbol? scope = symbol; scope != null;
                         scope = scope.ContainingType)
                        if (scope.DeclaredAccessibility is not
                            (Accessibility.Public or Accessibility.Internal))
                            accessible = false;
                    if (!accessible)
                        continue;

                    IFieldSymbol[] fields = symbol.GetMembers().OfType<IFieldSymbol>()
                        .Where(field => !field.IsStatic && !field.IsConst &&
                            !field.IsImplicitlyDeclared).ToArray();
                    // No fields: a tag (one byte in Flecs), for With/Without filters.
                    bool supported = fields.Length <= 128;
                    foreach (IFieldSymbol field in fields)
                    {
                        string kind = field.Type.ToDisplayString();
                        if (field.IsFixedSizeBuffer || field.IsReadOnly ||
                            !(field.Type.SpecialType is
                                SpecialType.System_Boolean or SpecialType.System_Int32 or
                                SpecialType.System_UInt32 or SpecialType.System_Int64 or
                                SpecialType.System_UInt64 or SpecialType.System_Single or
                                SpecialType.System_Double ||
                              kind is "System.Numerics.Vector2" or
                                "System.Numerics.Vector3" or
                                "System.Numerics.Vector4" or
                                "System.Numerics.Quaternion"))
                            supported = false;
                    }
                    if (!supported)
                        continue;

                    // Hash the *declaration*, not just its byte count. An
                    // incompatible same-size field change gets a new Flecs
                    // ID even during an editor hot reload. Keep assembly and
                    // field attributes in the signature for distinct layouts.
                    string name = symbol.ToDisplayString(
                        SymbolDisplayFormat.CSharpErrorMessageFormat);
                    string signature = assembly + "|" + name + "|" +
                        string.Join("|", symbol.GetAttributes().Select(a => a.ToString())) +
                        "|" + string.Join("|", fields.Select(field =>
                            field.Name + ":" +
                            field.Type.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat) +
                            ":" + string.Join(",", field.GetAttributes().Select(a =>
                                a.ToString()))));
                    string schemaId = Convert.ToHexString(SHA256.HashData(
                        Encoding.UTF8.GetBytes("TALLOW_LOCAL_ECS_V1|" + signature))
                        .AsSpan(0, 8));
                    // [Sync] fields go to the network: their offsets are measured when the assembly loads.
                    string csType = symbol.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat);
                    var describe = new StringBuilder("\"\"");
                    foreach (IFieldSymbol field in fields)
                    {
                        // [SyncPosition] (a Vector3: where the entity is, for relevance) is shared as [Sync] is.
                        bool position = field.Type.ToDisplayString() == "System.Numerics.Vector3" &&
                            field.GetAttributes().Any(a => a.AttributeClass?.ToDisplayString() == "Tallow.SyncPositionAttribute");
                        if ((!position && !field.GetAttributes().Any(a => a.AttributeClass?.ToDisplayString() == "Tallow.SyncAttribute")) ||
                            field.DeclaredAccessibility is not (Accessibility.Public or Accessibility.Internal))
                            continue;
                        int size = field.Type.SpecialType switch
                        {
                            SpecialType.System_Boolean => 1,
                            SpecialType.System_Int64 or SpecialType.System_UInt64 or SpecialType.System_Double => 8,
                            SpecialType.System_Int32 or SpecialType.System_UInt32 or SpecialType.System_Single => 4,
                            _ => field.Type.ToDisplayString() switch
                            {
                                "System.Numerics.Vector2" => 8,
                                "System.Numerics.Vector3" => 12,
                                _ => 16,
                            },
                        };
                        string fieldType = field.Type.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat);
                        describe.Append(" + \"").Append(field.Name).Append(":\" + (int)global::System.Runtime.CompilerServices.Unsafe.ByteOffset(ref b, ref global::System.Runtime.CompilerServices.Unsafe.As<")
                            .Append(fieldType).Append(", byte>(ref s.").Append(field.Name).Append(")) + \":").Append(size)
                            .Append(position ? ":p" : "").Append(";\"");
                    }
                    ecsTypes[name] = (csType, schemaId, describe.ToString());
                }
            }
            allTypes.Add(assembly, types);
            allEcsTypes.Add(assembly, ecsTypes);
        }

        // Source is generated under .tallow-csharp, NEVER in the user's src.
        // Avoid changing timestamps on no-op builds.
        foreach ((string assembly, SortedDictionary<string, string> types) in allTypes)
        {
            string className = FactoryName(assembly);
            var source = new StringBuilder();
            source.AppendLine("// Generated by Tallow.Build. Do not edit.")
                .AppendLine("#nullable enable")
                .AppendLine("namespace Tallow.Generated;")
                .Append("public static class ").Append(className).AppendLine()
                .AppendLine("{")
                .AppendLine("    public static global::Tallow.Script? Create(string fullName) => fullName switch")
                .AppendLine("    {");
            foreach ((string typeName, string csharpName) in types)
                source.Append("        ").Append(JsonSerializer.Serialize(typeName))
                    .Append(" => new ").Append(csharpName).AppendLine("(),");
            source.AppendLine("        _ => null")
                .AppendLine("    };")
                .AppendLine("}");
            string output = Path.Combine(generated, assembly,
                "Tallow.ComponentFactory.g.cs");
            WriteIfDifferent(output, source.ToString());
            filesByAssembly[assembly].Add(output);
        }

        // Data asset classes: a generated constructor each, registered when the assembly loads (Tallow.DataAsset has
        // no reflective fallback under NativeAOT).
        foreach ((string assembly, SortedDictionary<string, string> dataAssets) in allDataAssets)
        {
            if (dataAssets.Count == 0)
                continue;
            var source = new StringBuilder();
            source.AppendLine("// Generated by Tallow.Build. Do not edit.")
                .AppendLine("#nullable enable")
                .AppendLine("#pragma warning disable CA2255 // A game assembly: its data asset classes must be known before a file names one.")
                .AppendLine("namespace Tallow.Generated;")
                .Append("public static class DataAssets_").Append(FactoryName(assembly)).AppendLine()
                .AppendLine("{")
                .AppendLine("    [global::System.Runtime.CompilerServices.ModuleInitializer]")
                .AppendLine("    internal static void Register()")
                .AppendLine("    {");
            foreach ((string qualified, string fileName) in dataAssets)
                source.Append("        global::Tallow.DataAssetRegistry.Register(")
                    .Append(JsonSerializer.Serialize(fileName)).Append(", static () => new ")
                    .Append(qualified).AppendLine("());");
            source.AppendLine("    }")
                .AppendLine("}");
            string output = Path.Combine(generated, assembly, "Tallow.DataAssets.g.cs");
            WriteIfDifferent(output, source.ToString());
            filesByAssembly[assembly].Add(output);
        }


        // Generate strongly typed local data adapters before compilation.
        // The managed value is copied into a pinned Span<byte> only for one
        // synchronous generated ABI call. Native Flecs stores opaque bytes;
        // no C# references/pointers escape, no Jolt state is modified, and
        // the scene/session/network guards still live in Beef.
        foreach ((string assembly, var ecsTypes) in allEcsTypes)
        {
            var generatedEcs = new StringBuilder();
            generatedEcs.AppendLine("// Generated by Tallow.Build. Packed ECS data ([Sync] fields replicate from a server).")
                .AppendLine("#nullable enable")
                .AppendLine("namespace Tallow.Generated;")
                .Append("public static class EcsLocalData_")
                .Append(FactoryName(assembly)).AppendLine()
                .AppendLine("{");
            // Ties each struct to its schema id for the generic API (EcsEntity.Set<T>, Scene.Query<T>...).
            generatedEcs.AppendLine("#pragma warning disable CA2255 // A game assembly: its schemas must be known before any script runs.")
                .AppendLine("    [global::System.Runtime.CompilerServices.ModuleInitializer]")
                .AppendLine("    internal static void RegisterSchemas()")
                .AppendLine("    {");
            foreach ((string typeName, var schema) in ecsTypes)
                generatedEcs.AppendLine("        {")
                    .Append("            ").Append(schema.CSharpType).AppendLine(" s = default;")
                    .Append("            ref byte b = ref global::System.Runtime.CompilerServices.Unsafe.As<")
                    .Append(schema.CSharpType).AppendLine(", byte>(ref s);")
                    .Append("            global::Tallow.EcsSchemas.Register<").Append(schema.CSharpType)
                    .Append(">(0x").Append(schema.SchemaId).Append("UL, \"").Append(typeName).Append("\", ")
                    .Append(schema.Describe).AppendLine(");")
                    .AppendLine("        }");
            if (allSystems.TryGetValue(assembly, out var systemsOf))
                foreach ((string systemName, string systemType) in systemsOf)
                    generatedEcs.Append("        global::Tallow.EcsSystems.Register(new ").Append(systemType)
                        .Append("(), \"").Append(systemName).AppendLine("\");");
            if (allGameStarts.TryGetValue(assembly, out var startsOf))
                foreach (string start in startsOf)
                    generatedEcs.Append("        global::Tallow.GameStarts.Register(").Append(start).Append(", \"")
                        .Append(start.Replace("global::", "")).AppendLine("\");");
            if (allBehaviorNodes.TryGetValue(assembly, out var nodesOf))
                foreach (string nodeType in nodesOf)
                    generatedEcs.Append("        global::Tallow.BehaviorNodes.Register(() => new ").Append(nodeType)
                        .Append("(), typeof(").Append(nodeType).AppendLine("));");
            generatedEcs.AppendLine("    }")
                .AppendLine("#pragma warning restore CA2255");
            foreach ((string typeName, var schema) in ecsTypes)
            {
                string type = schema.CSharpType;
                string id = "0x" + schema.SchemaId + "UL";
                generatedEcs.Append("    /// <summary>Write local-only ")
                    .Append(typeName).AppendLine(" to a native Flecs entity.</summary>")
                    .Append("    public static bool SetLocalData(this global::Tallow.EcsEntity entity, in ")
                    .Append(type).AppendLine(" value)")
                    .AppendLine("    {")
                    .AppendLine("        if (!new global::Tallow.Scene(entity.SessionId).RegisterLocalEcsData(")
                    .Append("            ").Append(id).Append(", global::System.Runtime.CompilerServices.Unsafe.SizeOf<")
                    .Append(type).AppendLine(">(), 1))")
                    .AppendLine("            return false;")
                    .AppendLine("        var copy = value;")
                    .Append("        return entity.SetLocalData(").Append(id)
                    .AppendLine(", global::System.Runtime.InteropServices.MemoryMarshal.AsBytes(")
                    .AppendLine("            global::System.Runtime.InteropServices.MemoryMarshal.CreateSpan(ref copy, 1)));")
                    .AppendLine("    }")
                    .Append("    /// <summary>Read local-only ").Append(typeName)
                    .AppendLine(" from a native Flecs entity.</summary>")
                    .Append("    public static bool TryGetLocalData(this global::Tallow.EcsEntity entity, out ")
                    .Append(type).AppendLine(" result)")
                    .AppendLine("    {")
                    .AppendLine("        result = default;")
                    .Append("        return entity.TryCopyLocalData(").Append(id)
                    .AppendLine(", global::System.Runtime.InteropServices.MemoryMarshal.AsBytes(")
                    .AppendLine("            global::System.Runtime.InteropServices.MemoryMarshal.CreateSpan(ref result, 1)));")
                    .AppendLine("    }")
                    .Append("    /// <summary>Copy a page of native ").Append(typeName)
                    .AppendLine(" data without per-entity calls.</summary>")
                    .Append("    public static int CopyLocalDataPage(this global::Tallow.Scene scene, int offset, ")
                    .Append("global::System.Span<ulong> entityIds, global::System.Span<")
                    .Append(type).AppendLine("> values)")
                    .AppendLine("    {")
                    .AppendLine("        int capacity = global::System.Math.Min(entityIds.Length, values.Length);")
                    .AppendLine("        if (capacity <= 0) return 0;")
                    .Append("        return scene.CopyLocalEcsDataPage(").Append(id)
                    .AppendLine(", offset, entityIds[..capacity],")
                    .AppendLine("            global::System.Runtime.InteropServices.MemoryMarshal.AsBytes(values[..capacity]));")
                    .AppendLine("    }");
            }
            generatedEcs.AppendLine("}");
            string ecsPath = Path.Combine(generated, assembly, "Tallow.EcsLocalData.g.cs");
            WriteIfDifferent(ecsPath, generatedEcs.ToString());
            filesByAssembly[assembly].Add(ecsPath);
        }

        foreach ((string assembly, SortedSet<string> roots) in allAotRoots)
        {
            var text = new StringBuilder();
            text.AppendLine("// Generated by Tallow.Build. Never called: names the generic code Inspector fields need at run time")
                .AppendLine("// (lists of their items, GetComponent for object references), so that a NativeAOT export compiles it.")
                .AppendLine("#nullable enable")
                .AppendLine("namespace Tallow.Generated;")
                .Append("internal static class AotRoots_").Append(FactoryName(assembly)).AppendLine()
                .AppendLine("{")
                .AppendLine("    internal static void Instantiations()")
                .AppendLine("    {");
            foreach (string line in roots)
                text.Append("        ").AppendLine(line);
            text.AppendLine("    }").AppendLine("}");
            string rootsPath = Path.Combine(generated, assembly, "Tallow.AotRoots.g.cs");
            Directory.CreateDirectory(Path.GetDirectoryName(rootsPath)!);
            WriteIfDifferent(rootsPath, text.ToString());
            filesByAssembly[assembly].Add(rootsPath);
        }

        // Game root references all assembly factories explicitly. A future
        // NativeAOT player references THIS method to root constructors; the
        // current JIT editor still uses reflection/ALC for hot reload.
        var root = new StringBuilder();
        root.AppendLine("// Generated by Tallow.Build. AOT root; no assembly scanning.")
            .AppendLine("#nullable enable")
            .AppendLine("namespace Tallow.Generated;")
            .AppendLine("public sealed class TallowGeneratedGameRegistry : global::Tallow.IGameplayComponentRegistry")
            .AppendLine("{")
            .AppendLine("    public global::System.Collections.Generic.IReadOnlyList<string> ComponentNames { get; } = new string[]")
            .AppendLine("    {");
        foreach (string name in allTypes.Values.SelectMany(types => types.Keys)
            .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
            root.Append("        ").Append(JsonSerializer.Serialize(name)).AppendLine(",");
        foreach (string former in formerNames.Keys)
            if (allTypes.Values.Any(types => types.ContainsKey(former)))
                throw new InvalidOperationException(
                    $"[FormerlyNamed(\"{former}\")] names a script that still exists.");
        root.AppendLine("    };")
            .AppendLine("    public global::System.Collections.Generic.IReadOnlyDictionary<string, string> FormerNames { get; } =")
            .AppendLine("        new global::System.Collections.Generic.Dictionary<string, string>")
            .AppendLine("    {");
        foreach ((string former, string current) in formerNames)
            root.Append("        [").Append(JsonSerializer.Serialize(former)).Append("] = ")
                .Append(JsonSerializer.Serialize(current)).AppendLine(",");
        root.AppendLine("    };")
            .AppendLine("    public global::Tallow.Script? Create(string fullName)")
            .AppendLine("    {")
            .AppendLine("        global::Tallow.Script? component;");
        foreach (string assembly in allTypes.Keys.Order(StringComparer.Ordinal))
            root.Append("        component = ").Append(FactoryName(assembly))
                .AppendLine(".Create(fullName);")
                .AppendLine("        if (component is not null) return component;");
        root.AppendLine("        return null;")
            .AppendLine("    }")
            .AppendLine("}");
        string rootPath = Path.Combine(generated, "Tallow.Game",
            "Tallow.GameRegistry.g.cs");
        WriteIfDifferent(rootPath, root.ToString());
        filesByAssembly["Tallow.Game"].Add(rootPath);
        WriteFieldTables(compilation, filesByAssembly, treesByPath, generated);
    }

    /// <summary>
    /// The runtime's field tables (Tallow.ManagedFields): one entry per instance field of every class and struct the
    /// game declares, so the Inspector, saves, [Sync] and nested Inspector records are read and written without
    /// reflecting over game types (which NativeAOT cannot see through). Private fields are reached with
    /// [UnsafeAccessor] members in the same generated class; struct fields are changed through the boxed instance
    /// (Unsafe.Unbox). The same file registers the default-value constructors, List&lt;T&gt; factories and
    /// TryGetComponent lookups those paths need. A type this skips (a field type the generated code cannot name, a
    /// private nested type) keeps the runtime's reflection fallback.
    /// </summary>
    private static void WriteFieldTables(CSharpCompilation compilation,
        Dictionary<string, List<string>> filesByAssembly, Dictionary<string, SyntaxTree> treesByPath, string generated)
    {
        SymbolDisplayFormat qualified = SymbolDisplayFormat.FullyQualifiedFormat;
        foreach (var (assembly, sourceFiles) in filesByAssembly)
        {
            var emitted = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
            var tables = new List<INamedTypeSymbol>();
            // Script classes get a callback mask too, whether or not they have fields (a class with no field table
            // still needs the engine to know which of Update/OnGUI/... it has).
            var scripts = new List<INamedTypeSymbol>();
            var scriptSeen = new HashSet<INamedTypeSymbol>(SymbolEqualityComparer.Default);
            foreach (string sourceFile in sourceFiles)
            {
                // The list also holds generated files added earlier; only the game's own sources are trees here.
                if (!treesByPath.TryGetValue(sourceFile, out SyntaxTree? tree))
                    continue;
                SemanticModel model = compilation.GetSemanticModel(tree);
                foreach (TypeDeclarationSyntax node in tree.GetRoot().DescendantNodes().OfType<TypeDeclarationSyntax>())
                {
                    if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol symbol)
                        continue;
                    if (symbol.TypeKind is not (TypeKind.Class or TypeKind.Struct) || symbol.IsStatic ||
                        symbol.IsGenericType || symbol.IsRefLikeType || !Nameable(symbol) || !emitted.Add(symbol))
                        continue;
                    if (DerivesFrom(symbol, "Tallow.Script") && scriptSeen.Add(symbol))
                        scripts.Add(symbol);
                    IFieldSymbol[] fields = FieldsOf(symbol);
                    if (fields.Length == 0 ||
                        fields.Any(field => !Nameable(field.Type) || field.Type.IsRefLikeType))
                        continue; // read by reflection, as before
                    tables.Add(symbol);
                }
            }
            if (tables.Count == 0 && scripts.Count == 0)
                continue;
            tables.Sort((a, b) => string.CompareOrdinal(a.ToDisplayString(qualified), b.ToDisplayString(qualified)));
            scripts.Sort((a, b) => string.CompareOrdinal(a.ToDisplayString(qualified), b.ToDisplayString(qualified)));

            var source = new StringBuilder();
            source.AppendLine("// Generated by Tallow.Build. Do not edit.")
                .AppendLine("#nullable enable")
                .AppendLine("#pragma warning disable CA2255 // A game assembly: the runtime reads its fields without reflection.")
                .AppendLine("namespace Tallow.Generated;")
                .Append("public static class FieldTables_").Append(FactoryName(assembly)).AppendLine()
                .AppendLine("{");
            // One [UnsafeAccessor] per field: the getter and setter lambdas below reach private fields through it.
            int accessor = 0;
            var entries = new StringBuilder();
            var creates = new SortedDictionary<string, string>(StringComparer.Ordinal);
            var lists = new SortedDictionary<string, string>(StringComparer.Ordinal);
            var components = new SortedDictionary<string, string>(StringComparer.Ordinal);
            foreach (INamedTypeSymbol type in tables)
            {
                string target = type.ToDisplayString(qualified);
                bool isStruct = type.TypeKind == TypeKind.Struct;
                entries.Append("        global::Tallow.ManagedFields.RegisterFields(typeof(").Append(target)
                    .AppendLine("), new global::Tallow.ManagedField[] {");
                foreach (IFieldSymbol field in FieldsOf(type))
                {
                    string fieldType = field.Type.WithNullableAnnotation(NullableAnnotation.NotAnnotated)
                        .ToDisplayString(qualified);
                    string name = "Accessor_" + accessor++;
                    source.Append("    [global::System.Runtime.CompilerServices.UnsafeAccessor(global::System.Runtime.CompilerServices.UnsafeAccessorKind.Field, Name = \"")
                        .Append(field.Name).AppendLine("\")]");
                    source.Append("    private static extern ref ").Append(fieldType).Append(' ').Append(name)
                        .Append(isStruct ? " (ref " : " (").Append(target).AppendLine(" target);");
                    string read = isStruct
                        ? $"{name}(ref global::System.Runtime.CompilerServices.Unsafe.Unbox<{target}>(o))"
                        : $"{name}(({target})o)";
                    string? write = field.IsReadOnly
                        ? null
                        : (isStruct
                            ? $"{name}(ref global::System.Runtime.CompilerServices.Unsafe.Unbox<{target}>(o)) = ({fieldType})v!"
                            : $"{name}(({target})o) = ({fieldType})v!");
                    entries.Append("            new(").Append(JsonSerializer.Serialize(field.Name)).Append(", typeof(")
                        .Append(fieldType).Append("), static o => ").Append(read).Append(", ")
                        .Append(write is null ? "null" : $"static (o, v) => {write}")
                        .Append(", isPublic: ").Append(field.DeclaredAccessibility == Accessibility.Public ? "true" : "false")
                        .Append(", showInInspector: ").Append(HasAttribute(field, "Tallow.ShowInInspectorAttribute") ? "true" : "false")
                        .Append(", hideInInspector: ").Append(HasAttribute(field, "Tallow.HideInInspectorAttribute") ? "true" : "false")
                        .Append(", saved: ").Append(HasAttribute(field, "Tallow.SavedAttribute") ? "true" : "false")
                        .Append(", sync: ").Append(HasAttribute(field, "Tallow.SyncAttribute") ? "true" : "false")
                        .Append(", notSerialized: ").Append(HasAttribute(field, "System.NonSerializedAttribute") ? "true" : "false")
                        .AppendLine(", compilerGenerated: false),");
                    CollectFactories(field.Type, lists, components);
                }
                entries.AppendLine("        });");
                if (type.TypeKind == TypeKind.Struct ||
                    (!type.IsAbstract && type.InstanceConstructors.Any(ctor => ctor.Parameters.Length == 0 &&
                        ctor.DeclaredAccessibility is Accessibility.Public or Accessibility.Internal)))
                    creates[target] = target;
            }
            // UI handlers: a .tui event calls a script method by name, with no argument, the UIElement or its id.
            var uiEntries = new StringBuilder();
            int uiAccessor = 0;
            foreach (INamedTypeSymbol script in scripts)
            {
                string target = script.ToDisplayString(qualified);
                var handlers = new SortedDictionary<string, (string? None, string? Element, string? Text)>(StringComparer.Ordinal);
                foreach (IMethodSymbol method in script.GetMembers().OfType<IMethodSymbol>())
                {
                    if (method.MethodKind != MethodKind.Ordinary || method.IsStatic || method.IsGenericMethod ||
                        method.IsAbstract)
                        continue;
                    string? shape = method.Parameters.Length switch
                    {
                        0 => "none",
                        1 when method.Parameters[0].RefKind == RefKind.None &&
                            method.Parameters[0].Type.ToDisplayString() == "Tallow.UIElement" => "element",
                        1 when method.Parameters[0].RefKind == RefKind.None &&
                            method.Parameters[0].Type.SpecialType == SpecialType.System_String => "text",
                        _ => null,
                    };
                    if (shape is null)
                        continue;
                    string uiMethod = "Ui_" + uiAccessor++;
                    string returnType = method.ReturnsVoid ? "void" : method.ReturnType
                        .WithNullableAnnotation(NullableAnnotation.NotAnnotated).ToDisplayString(qualified);
                    source.Append("    [global::System.Runtime.CompilerServices.UnsafeAccessor(global::System.Runtime.CompilerServices.UnsafeAccessorKind.Method, Name = \"")
                        .Append(method.Name).AppendLine("\")]");
                    source.Append("    private static extern ").Append(returnType).Append(' ').Append(uiMethod)
                        .Append('(').Append(target).Append(" target");
                    if (shape == "element")
                        source.Append(", global::Tallow.UIElement element)");
                    else if (shape == "text")
                        source.Append(", string text)");
                    else
                        source.Append(')');
                    source.AppendLine(";");
                    string call = shape switch
                    {
                        "element" => $"{uiMethod}(({target})o, e)",
                        "text" => $"{uiMethod}(({target})o, s)",
                        _ => $"{uiMethod}(({target})o)",
                    };
                    handlers.TryGetValue(method.Name, out var existing);
                    handlers[method.Name] = shape switch
                    {
                        "element" => (existing.None, $"static (o, e) => {{ {call}; }}", existing.Text),
                        "text" => (existing.None, existing.Element, $"static (o, s) => {{ {call}; }}"),
                        _ => (method.ReturnsVoid
                            ? $"static o => {{ {call}; return null; }}"
                            : $"static o => {call}", existing.Element, existing.Text),
                    };
                }
                if (handlers.Count == 0)
                {
                    uiEntries.Append("        global::Tallow.ManagedUi.Register(typeof(").Append(target)
                        .AppendLine("), new global::System.Collections.Generic.Dictionary<string, global::Tallow.ManagedUiHandler>());");
                    continue;
                }
                uiEntries.Append("        global::Tallow.ManagedUi.Register(typeof(").Append(target)
                    .AppendLine("), new global::System.Collections.Generic.Dictionary<string, global::Tallow.ManagedUiHandler>");
                uiEntries.AppendLine("        {");
                foreach ((string name, var handler) in handlers)
                {
                    uiEntries.Append("            [").Append(JsonSerializer.Serialize(name))
                        .AppendLine("] = new global::Tallow.ManagedUiHandler");
                    uiEntries.AppendLine("            {");
                    if (handler.None is not null)
                        uiEntries.Append("                NoArgument = ").Append(handler.None).AppendLine(",");
                    if (handler.Element is not null)
                        uiEntries.Append("                WithElement = ").Append(handler.Element).AppendLine(",");
                    if (handler.Text is not null)
                        uiEntries.Append("                WithString = ").Append(handler.Text).AppendLine(",");
                    uiEntries.AppendLine("            },");
                }
                uiEntries.AppendLine("        });");
            }
            // [Rpc] methods: called by name from the network without reflecting over the class.
            var rpcEntries = new StringBuilder();
            int rpcAccessor = 0;
            foreach (INamedTypeSymbol script in scripts)
                WriteRpcTable(script, source, rpcEntries, ref rpcAccessor);

            source.AppendLine("    [global::System.Runtime.CompilerServices.ModuleInitializer]")
                .AppendLine("    internal static void Register()")
                .AppendLine("    {");
            source.Append(entries);
            foreach (string target in creates.Values)
                source.Append("        global::Tallow.ManagedFields.RegisterCreate(typeof(").Append(target)
                    .Append("), static () => (object)new ").Append(target).AppendLine("());");
            foreach ((string element, string elementType) in lists)
                source.Append("        global::Tallow.ManagedFields.RegisterList(typeof(").Append(elementType)
                    .Append("), static () => new global::System.Collections.Generic.List<").Append(elementType)
                    .AppendLine(">());");
            foreach ((string component, string componentType) in components)
                source.Append("        global::Tallow.ManagedFields.RegisterComponent(typeof(").Append(componentType)
                    .Append("), static g => g.TryGetComponent<").Append(componentType).AppendLine(">(out var c) ? c : null);");
            source.Append(uiEntries);
            source.Append(rpcEntries);
            foreach (INamedTypeSymbol script in scripts)
            {
                var overridden = new List<string>();
                foreach ((string callback, string[] parameters) in sCallbacks)
                    if (Overrides(script, callback, parameters))
                        overridden.Add(callback);
                source.Append("        global::Tallow.ManagedCallbacks.Register(typeof(")
                    .Append(script.ToDisplayString(qualified)).Append("), new string[] { ")
                    .Append(string.Join(", ", overridden.Select(name => JsonSerializer.Serialize(name)))).AppendLine(" });");
            }
            source.AppendLine("    }")
                .AppendLine("}");
            string output = Path.Combine(generated, assembly, "Tallow.FieldTables.g.cs");
            WriteIfDifferent(output, source.ToString());
            filesByAssembly[assembly].Add(output);
        }
    }

    /// <summary>
    /// The [Rpc] methods one script class declares (Tallow.ManagedRpcs): a direct call through an [UnsafeAccessor]
    /// and where it runs, so a NativeAOT game answers a network RPC without reflecting over the class. A method the
    /// runtime would refuse (generic, returning a value, a parameter type an RPC cannot carry) is registered with
    /// that same error instead of a call.
    /// </summary>
    private static void WriteRpcTable(INamedTypeSymbol script, StringBuilder source, StringBuilder entries,
        ref int accessor)
    {
        SymbolDisplayFormat qualified = SymbolDisplayFormat.FullyQualifiedFormat;
        string target = script.ToDisplayString(qualified);
        foreach (IMethodSymbol method in script.GetMembers().OfType<IMethodSymbol>())
        {
            if (method.MethodKind != MethodKind.Ordinary || method.IsStatic || method.IsAbstract)
                continue;
            // [Rpc] is inherited: an override without its own attribute still counts, as the reflected lookup does.
            AttributeData? attribute = null;
            for (IMethodSymbol? at = method; at is not null && attribute is null; at = at.OverriddenMethod)
                attribute = at.GetAttributes().FirstOrDefault(a =>
                    a.AttributeClass?.ToDisplayString() == "Tallow.RpcAttribute");
            if (attribute is null)
                continue;
            int rpcTarget = attribute.ConstructorArguments is [{ Value: int value }] ? value : 1; // RpcTarget.Everyone
            string[] parameterTypes = method.Parameters.Select(parameter => parameter.Type
                .WithNullableAnnotation(NullableAnnotation.NotAnnotated).ToDisplayString(qualified)).ToArray();
            string? error = method.IsGenericMethod || !method.ReturnsVoid
                ? $"{script.Name}.{method.Name}: an [Rpc] method returns void and is not generic."
                : method.Parameters.FirstOrDefault(parameter => parameter.RefKind != RefKind.None ||
                    !RpcParameter(parameter.Type)) is { } bad
                    ? $"{script.Name}.{method.Name}: [Rpc] parameters cannot be {bad.Type.Name}. Use int, float, bool, " +
                        "string, enums, vectors or GameObject."
                    : null;
            string? call = null;
            if (error is null)
            {
                string rpcMethod = "Rpc_" + accessor++;
                source.Append("    [global::System.Runtime.CompilerServices.UnsafeAccessor(global::System.Runtime.CompilerServices.UnsafeAccessorKind.Method, Name = \"")
                    .Append(method.Name).AppendLine("\")]");
                source.Append("    private static extern void ").Append(rpcMethod).Append('(').Append(target)
                    .Append(" target");
                for (int i = 0; i < parameterTypes.Length; i++)
                    source.Append(", ").Append(parameterTypes[i]).Append(" p").Append(i);
                source.AppendLine(");");
                string arguments = string.Join(", ", parameterTypes.Select((type, i) => $"({type})a[{i}]!"));
                call = arguments.Length == 0
                    ? $"{rpcMethod}(({target})o)"
                    : $"{rpcMethod}(({target})o, {arguments})";
            }
            entries.Append("        global::Tallow.ManagedRpcs.Register(typeof(").Append(target).Append("), ")
                .Append(JsonSerializer.Serialize(method.Name)).Append(", new global::Tallow.ManagedRpc(global::Tallow.RpcTarget.")
                .Append(rpcTarget == 0 ? "Server" : "Everyone")
                .Append(", new global::System.Type[] { ")
                .Append(string.Join(", ", parameterTypes.Select(type => "typeof(" + type + ")")))
                .Append(" }, ").Append(call is null ? "null" : $"static (o, a) => {call}").Append(", ")
                .Append(error is null ? "null" : JsonSerializer.Serialize(error)).AppendLine("));");
        }
    }

    /// <summary>The parameter types an [Rpc] can carry (the rule Tallow.RpcMethods applies at run time).</summary>
    private static bool RpcParameter(ITypeSymbol type) =>
        type.SpecialType is SpecialType.System_Int32 or SpecialType.System_Single or SpecialType.System_Boolean
            or SpecialType.System_String
        || type.TypeKind == TypeKind.Enum
        || type.ToDisplayString() is "System.Numerics.Vector2" or "System.Numerics.Vector3"
            or "System.Numerics.Vector4" or "Tallow.GameObject";

    /// <summary>The callbacks the runtime knows (names and parameter types), as the generated masks see them.</summary>
    private static readonly (string Name, string[] Parameters)[] sCallbacks =
    [
        ("EarlyUpdate", ["Tallow.TickInput", "float"]),
        ("Update", ["Tallow.TickInput", "float"]),
        ("LateUpdate", ["Tallow.TickInput", "float"]),
        ("FixedUpdate", ["float"]),
        ("LocalEarlyUpdate", ["float"]),
        ("LocalUpdate", ["float"]),
        ("LocalLateUpdate", ["float"]),
        ("OnGUI", []),
        ("OnWorldStateChanged", ["int", "int"]),
        ("OnSequenceEvent", ["string", "float"]),
        ("OnDialogueEvent", ["string", "float"]),
        ("OnTreeEvent", ["string"]),
        ("OnDialogueEnded", []),
        ("OnSequenceFinished", []),
        ("OnClientJoined", ["int"]),
        ("OnClientLeft", ["int"]),
        ("CapturePredictionState", ["ref Tallow.PredictionState"]),
        ("PreparePredictionState", ["ref Tallow.PredictionState"]),
        ("RestorePredictionState", ["ref Tallow.PredictionState"]),
    ];

    private static bool DerivesFrom(INamedTypeSymbol type, string name)
    {
        for (INamedTypeSymbol? parent = type.BaseType; parent != null; parent = parent.BaseType)
            if (parent.ToDisplayString() == name)
                return true;
        return false;
    }

    /// <summary>Whether the class or a base class below Script declares the callback (the rule Script.GetMethod with
    /// Public | Instance applies at run time).</summary>
    private static bool Overrides(INamedTypeSymbol type, string name, string[] parameters)
    {
        for (INamedTypeSymbol? at = type; at != null && at.ToDisplayString() != "Tallow.Script"; at = at.BaseType)
            foreach (IMethodSymbol method in at.GetMembers(name).OfType<IMethodSymbol>())
                if (!method.IsStatic && method.DeclaredAccessibility == Accessibility.Public && Matches(method, parameters))
                    return true;
        return false;
    }

    private static bool Matches(IMethodSymbol method, string[] parameters)
    {
        if (method.Parameters.Length != parameters.Length)
            return false;
        for (int i = 0; i < parameters.Length; i++)
        {
            IParameterSymbol parameter = method.Parameters[i];
            string expected = parameters[i];
            bool byRef = expected.StartsWith("ref ", StringComparison.Ordinal);
            if (byRef)
                expected = expected[4..];
            if (byRef != (parameter.RefKind == RefKind.Ref))
                return false;
            string actual = parameter.Type.SpecialType switch
            {
                SpecialType.System_Single => "float",
                SpecialType.System_Int32 => "int",
                SpecialType.System_String => "string",
                _ => parameter.Type.ToDisplayString(),
            };
            if (actual != expected)
                return false;
        }
        return true;
    }

    /// <summary>The instance fields a type declares itself, in declaration order (compiler-made backing fields are
    /// not source members and never appear).</summary>
    private static IFieldSymbol[] FieldsOf(INamedTypeSymbol type) =>
        type.GetMembers().OfType<IFieldSymbol>()
            .Where(field => !field.IsStatic && !field.IsConst && !field.IsImplicitlyDeclared).ToArray();

    private static bool HasAttribute(IFieldSymbol field, string name) =>
        field.GetAttributes().Any(a => a.AttributeClass?.ToDisplayString() == name);

    /// <summary>The List&lt;T&gt; factories and TryGetComponent lookups a field type needs (and its elements', for a
    /// list of records).</summary>
    private static void CollectFactories(ITypeSymbol fieldType,
        SortedDictionary<string, string> lists, SortedDictionary<string, string> components)
    {
        ITypeSymbol type = fieldType.WithNullableAnnotation(NullableAnnotation.NotAnnotated);
        if (type is INamedTypeSymbol { OriginalDefinition.SpecialType: SpecialType.System_Nullable_T } nullable)
            type = nullable.TypeArguments[0];
        ITypeSymbol? element = type switch
        {
            IArrayTypeSymbol { Rank: 1 } array => array.ElementType,
            INamedTypeSymbol named when named.OriginalDefinition.ToDisplayString() == "System.Collections.Generic.List<T>" => named.TypeArguments[0],
            _ => null
        };
        if (element != null)
        {
            if (Nameable(element) && element.TypeKind != TypeKind.TypeParameter)
            {
                string name = element.WithNullableAnnotation(NullableAnnotation.NotAnnotated)
                    .ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat);
                lists[name] = name;
            }
            CollectFactories(element, lists, components);
            return;
        }
        if (type is INamedTypeSymbol target && Nameable(target) && !target.IsGenericType &&
            target.AllInterfaces.Any(i => i.ToDisplayString() == "Tallow.IComponent"))
            components[target.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat)] =
                target.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat);
    }

    /// <summary>The generated factory class name for an assembly (stable across builds).</summary>
    private static string FactoryName(string assembly) =>
        "ComponentFactory_" + Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(assembly)).AsSpan(0, 8));

    /// <summary>Writes a generated file only when its text changed (a no-op build keeps timestamps).</summary>
    private static void WriteIfDifferent(string path, string value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (!File.Exists(path) || File.ReadAllText(path) != value)
            File.WriteAllText(path, value);
    }

    /// <summary>
    /// A solution at the project root listing every generated assembly, so
    /// VS Code, Rider and Visual Studio open the game's C# directly (with
    /// Tallow.API references and the trusted analyzers). Rewritten only when
    /// the assembly list changes.
    /// </summary>
    /// <summary>The code ID of the game last generated (see <see cref="CodeId"/>).</summary>
    private static string? sCodeId;

    /// <summary>
    /// What the game's code is, independent of where it was built: SHA-256 over each game assembly's name, its
    /// references and packages, and its sources (paths relative to src, line endings ignored, so a Windows and a Linux
    /// checkout agree), first 16 hex digits. Written beside Tallow.Game.dll as Tallow.Game.codeid; a network session
    /// uses it to hot reload every machine onto the same code (only machines that built the same sources follow).
    /// Generated files are left out: they follow from the sources.
    /// </summary>
    private static string CodeId(string source, Dictionary<string, List<string>> filesByAssembly,
        Dictionary<string, Definition> definitions)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        void Add(string text) => hash.AppendData(Encoding.UTF8.GetBytes(text + "\n"));
        foreach ((string name, List<string> files) in filesByAssembly.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            Add("assembly " + name);
            if (definitions.TryGetValue(name, out Definition? definition))
            {
                foreach (string reference in definition.References.Order(StringComparer.Ordinal))
                    Add("reference " + reference);
                foreach (PackageRef package in definition.Packages.OrderBy(p => p.Id, StringComparer.Ordinal))
                    Add($"package {package.Id} {package.Version}");
            }
            var sources = files.Where(file => IsInFolder(file, source))
                .Select(file => (Relative: Path.GetRelativePath(source, file).Replace('\\', '/'), File: file))
                .OrderBy(pair => pair.Relative, StringComparer.Ordinal);
            foreach ((string relative, string file) in sources)
            {
                Add("file " + relative);
                byte[] bytes = File.ReadAllBytes(file);
                hash.AppendData(bytes.Where(b => b != (byte)'\r').ToArray());
                Add("");
            }
        }
        return Convert.ToHexString(hash.GetHashAndReset())[..16].ToLowerInvariant();
    }

    private static void WriteSolution(string project, IEnumerable<string> csprojs)
    {
        string root = Path.GetFullPath(project).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string path = Path.Combine(root, Path.GetFileName(root) + ".slnx");
        var text = new StringBuilder("<Solution>\n");
        foreach (string csproj in csprojs.Order(StringComparer.Ordinal))
            text.Append("  <Project Path=\"")
                .Append(Path.GetRelativePath(root, csproj).Replace('\\', '/'))
                .Append("\" />\n");
        text.Append("</Solution>\n");
        string value = text.ToString();
        if (!File.Exists(path) || File.ReadAllText(path) != value)
            File.WriteAllText(path, value);
    }

    private static string Generate(string project, string engine) => Generate(project, engine, out _);

    /// <summary>editorProject: the editor scripts' project, or null when the game has none.</summary>
    private static string Generate(string project, string engine, out string? editorProject)
    {
        string source = Path.Combine(project, "src");
        string api = Path.Combine(engine, "Managed", "Tallow.API", "Tallow.API.csproj");
        if (!Directory.Exists(source) || !File.Exists(api))
            throw new DirectoryNotFoundException("Game src or Tallow.API is missing.");
        var definitions = ReadDefinitions(source);
        string generated = Path.Combine(project, ".tallow-csharp", "generated");
        string output = Path.Combine(project, ".tallow-csharp", "bin");

        var paths = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["Tallow.Game"] = Path.Combine(generated, "Tallow.Game", "Tallow.Game.csproj")
        };
        foreach (string name in definitions.Keys)
            paths.Add(name, Path.Combine(generated, name, name + ".csproj"));

        var filesByAssembly = paths.Keys.ToDictionary(name => name, _ => new List<string>());
        var editorFiles = new List<string>();
        foreach (string file in Directory.EnumerateFiles(source, "*.cs", SearchOption.AllDirectories))
        {
            if (IsEditorFile(source, file))
            {
                editorFiles.Add(Path.GetFullPath(file));
                continue;
            }
            string owner = "Tallow.Game";
            int depth = -1;
            foreach (Definition definition in definitions.Values)
            {
                if (definition.Folder.Length > depth && IsInFolder(file, definition.Folder))
                {
                    owner = definition.Name;
                    depth = definition.Folder.Length;
                }
            }
            filesByAssembly[owner].Add(Path.GetFullPath(file));
        }

        WriteComponentFactories(engine, generated, filesByAssembly);
        sCodeId = CodeId(source, filesByAssembly, definitions);

        foreach ((string name, string path) in paths)
        {
            string[] references = name == "Tallow.Game"
                ? definitions.Keys.ToArray()
                : definitions[name].References.ToArray();
            string[] refPaths = references.Select(reference => paths[reference]).ToArray();
            // $(TallowBinRoot) lets a game build (Tallow.Build export) put every assembly elsewhere, each in its own
            // folder as the runtime loads them, without touching the editor's build.
            string outputFolder = "$(TallowBinRoot)" + name;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string rootNamespace = name == "Tallow.Game" ? name : definitions[name].RootNamespace;
            IReadOnlyList<PackageRef> packages = name == "Tallow.Game" ? [] : definitions[name].Packages;
            var csproj = CreateProject(name, rootNamespace, filesByAssembly[name].Order(), refPaths, api,
                outputFolder, output, packages);
            // MSBuild treats project file timestamps as inputs. Saving an
            // identical .csproj on every no-op build invalidates otherwise
            // reusable compilation state, including referenced asmdefs.
            using var xml = new MemoryStream();
            csproj.Save(xml);
            byte[] bytes = xml.ToArray();
            if (!File.Exists(path) || !File.ReadAllBytes(path).AsSpan().SequenceEqual(bytes))
                File.WriteAllBytes(path, bytes);
        }
        editorProject = null;
        string editorBin = Path.Combine(output, EditorAssembly);
        if (editorFiles.Count > 0)
        {
            string editorApi = Path.Combine(engine, "Managed", "Tallow.Editor", "Tallow.Editor.csproj");
            if (!File.Exists(editorApi))
                throw new FileNotFoundException("The engine's Managed/Tallow.Editor is missing.", editorApi);
            editorProject = Path.Combine(generated, EditorAssembly, EditorAssembly + ".csproj");
            Directory.CreateDirectory(Path.GetDirectoryName(editorProject)!);
            string[] gameProjects = paths.Values.Append(editorApi).ToArray();
            var csproj = CreateProject(EditorAssembly, "Tallow.Game", editorFiles.Order(), gameProjects, api,
                "$(TallowBinRoot)" + EditorAssembly, output, []);
            using var xml = new MemoryStream();
            csproj.Save(xml);
            byte[] bytes = xml.ToArray();
            if (!File.Exists(editorProject) || !File.ReadAllBytes(editorProject).AsSpan().SequenceEqual(bytes))
                File.WriteAllBytes(editorProject, bytes);
        }
        // Editor scripts all removed: the editor must not keep loading the last ones built.
        else if (Directory.Exists(editorBin))
            Directory.Delete(editorBin, true);
        WriteSolution(project, editorProject == null ? paths.Values : paths.Values.Append(editorProject));
        Console.WriteLine($"Generated {paths.Count + (editorProject == null ? 0 : 1)} C# assemblies; game: {paths["Tallow.Game"]}");
        return paths["Tallow.Game"];
    }

    /// <summary>
    /// Publish the managed component catalog only after all trusted assemblies
    /// compiled successfully. Roslyn checks inheritance and attributes, rather
    /// than guessing classes from file names or executing the user's game.
    /// </summary>
    /// <summary>The game's sources and Tallow.API's in one Roslyn compilation, for the catalogs.</summary>
    private static CSharpCompilation CatalogCompilation(string project, string engine, out SyntaxTree[] trees)
    {
        string source = Path.Combine(project, "src");
        string api = Path.Combine(engine, "Managed", "Tallow.API");
        var parse = new CSharpParseOptions(LanguageVersion.CSharp15);
        // The editor scripts are not part of the game: no components, graph nodes or fields of theirs.
        var sources = Directory.EnumerateFiles(source, "*.cs", SearchOption.AllDirectories)
            .Where(path => !IsEditorFile(source, path))
            .Order(StringComparer.Ordinal).ToArray();
        trees = sources.Select(path => CSharpSyntaxTree.ParseText(
            File.ReadAllText(path), parse, path: Path.GetFullPath(path))).ToArray();
        var apiTrees = Directory.EnumerateFiles(api, "*.cs", SearchOption.AllDirectories)
            .Select(path => CSharpSyntaxTree.ParseText(
                File.ReadAllText(path), parse, path: Path.GetFullPath(path)));
        string trusted = (string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES") ?? "";
        var references = trusted.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(path => MetadataReference.CreateFromFile(path));
        var globalNumerics = CSharpSyntaxTree.ParseText(
            "global using System.Numerics;", parse, path: "Tallow.GlobalNumerics.g.cs");
        return CSharpCompilation.Create("Tallow.ComponentCatalog",
            trees.Concat(apiTrees).Append(globalNumerics), references,
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary));
    }

    /// <summary>
    /// The code editor's determinism warnings (TAL-NET: unseeded random numbers, clocks, local input, work on other
    /// threads, culture-dependent number parsing, per-process hash codes) in predicted tick code, listed when a game
    /// is built for release. Warnings, as in the editor: they do not stop the build.
    /// </summary>
    private static void ReportDeterminism(string project, string engine)
    {
        CSharpCompilation compilation = CatalogCompilation(project, engine, out SyntaxTree[] trees);
        // The game projects' implicit usings (ImplicitUsings), so that DateTime and the like bind as they do there.
        compilation = compilation.AddSyntaxTrees(CSharpSyntaxTree.ParseText(
            "global using global::System; global using global::System.Collections.Generic; global using global::System.IO; " +
            "global using global::System.Linq; global using global::System.Threading; global using global::System.Threading.Tasks; " +
            "global using global::Tallow.Generated;",
            new CSharpParseOptions(LanguageVersion.CSharp15), path: "Tallow.ImplicitUsings.g.cs"));
        var texts = trees.ToDictionary(tree => tree.FilePath, tree => tree.GetText().ToString(), StringComparer.Ordinal);
        var warnings = Tallow.LanguageService.GameplayDiagnostics.Analyze(compilation, texts)
            .Where(warning => warning.Category == "determinism").ToList();
        foreach (var warning in warnings)
            Console.WriteLine($"{warning.Path}({warning.Line + 1}): warning {warning.Message}");
        if (warnings.Count > 0)
            Console.WriteLine($"{warnings.Count} determinism warning(s) in networked tick code: these can make clients and " +
                "the server disagree (the code editor marks them in purple).");
    }

    private static string GraphNodesPath(string project) => Path.Combine(project, ".tallow-csharp", "graph-nodes.tsv");

    private static void WriteComponentCatalog(string project, string engine)
    {
        var compilation = CatalogCompilation(project, engine, out SyntaxTree[] trees);
        var components = new SortedSet<string>(StringComparer.Ordinal);
        var sourceRows = new SortedSet<string>(StringComparer.Ordinal);
        // Old script names and what they are now ([FormerlyNamed]); the editor updates scenes with them.
        var formerRows = new SortedSet<string>(StringComparer.Ordinal);
        var fieldRows = new SortedSet<string>(StringComparer.Ordinal);
        // C# DataAsset classes (Project window: + > Data Asset); their fields are in fieldRows as a script's are.
        var dataAssetRows = new SortedSet<string>(StringComparer.Ordinal);
        var fieldDocRows = new SortedSet<string>(StringComparer.Ordinal);
        // Build-only metadata for a future AOT static serializer. No new
        // runtime reflection or scene format is introduced by this manifest.
        var aotFieldRows = new SortedSet<string>(StringComparer.Ordinal);
        // A schema-only preview of user-defined C# Flecs data structs.
        // A future native bridge must validate sizeof/alignment and Sync
        // layouts before allowing writes or network replication.
        // By type name; each type's @layout row, then its fields in declaration order (the graph editor's ECS
        // nodes number their pins in that order).
        var ecsDataRows = new SortedDictionary<string, List<string>>(StringComparer.Ordinal);

        foreach (SyntaxTree tree in trees)
        {
            SemanticModel model = compilation.GetSemanticModel(tree);
            foreach (ClassDeclarationSyntax node in tree.GetRoot().DescendantNodes()
                .OfType<ClassDeclarationSyntax>())
            {
                if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol type || type.IsAbstract)
                    continue;
                // A concrete Script subclass is already a component.
                // Keep [Component] only for ECS structs, where inheritance
                // cannot distinguish data from an ordinary value type.
                bool script = false, dataAsset = false;
                for (INamedTypeSymbol? parent = type.BaseType; parent != null;
                    parent = parent.BaseType)
                {
                    if (parent.ToDisplayString() == "Tallow.Script")
                    {
                        script = true;
                        break;
                    }
                    if (parent.ToDisplayString() == "Tallow.DataAsset")
                    {
                        dataAsset = true;
                        break;
                    }
                }
                if (!script && !dataAsset)
                    continue;

                string className = type.ToDisplayString(SymbolDisplayFormat.CSharpErrorMessageFormat);
                if (dataAsset)
                {
                    // Column 2: "saved" when it has [Saved] fields (the Inspector offers to forget the player's copy).
                    bool hasSaved = false;
                    for (INamedTypeSymbol? owner = type; owner != null && owner.ToDisplayString() != "Tallow.DataAsset";
                         owner = owner.BaseType)
                        hasSaved |= owner.GetMembers().OfType<IFieldSymbol>().Any(f => f.GetAttributes()
                            .Any(a => a.AttributeClass?.ToDisplayString() == "Tallow.SavedAttribute"));
                    dataAssetRows.Add(hasSaved ? className + "\tsaved" : className);
                }
                else
                {
                    components.Add(className);
                    sourceRows.Add(tree.FilePath + "\t" + className);
                    foreach (string former in FormerNamesOf(type))
                        formerRows.Add(former + "\t" + className);
                }
                var seenFieldIds = new HashSet<string>(StringComparer.Ordinal);

                // Limit the first Inspector bridge to deterministic, supported
                // value types. Managed objects/references need their own handles.
                // Fields declared on user base classes belong to the component
                // too: list them base-first, as the runtime restores them.
                var fieldOwners = new List<INamedTypeSymbol>();
                for (INamedTypeSymbol? owner = type; owner != null &&
                     owner.ToDisplayString() is not ("Tallow.Script" or "Tallow.DataAsset") &&
                     owner.SpecialType != SpecialType.System_Object; owner = owner.BaseType)
                    fieldOwners.Insert(0, owner);
                var seenFieldNames = new HashSet<string>(StringComparer.Ordinal);
                foreach (IFieldSymbol field in fieldOwners.SelectMany(
                    owner => owner.GetMembers().OfType<IFieldSymbol>()))
                {
                    // A derived field hiding a base field of the same name
                    // cannot be told apart in the name-keyed scene format.
                    if (!seenFieldNames.Add(field.Name))
                        continue;
                    // Match native Beef's Show/Hide semantics: public fields
                    // serialize by default, while private ones require an
                    // explicit serialization marker. Hide means persisted
                    // but omitted from Inspector UI; NonSerialized always wins.
                    var fieldAttributes = field.GetAttributes()
                        .Select(a => a.AttributeClass?.ToDisplayString())
                        .ToHashSet(StringComparer.Ordinal);
                    bool show = fieldAttributes.Contains("Tallow.ShowInInspectorAttribute");
                    bool hide = fieldAttributes.Contains("Tallow.HideInInspectorAttribute");
                    bool explicitlySerialized = show || hide;
                    if ((field.DeclaredAccessibility != Accessibility.Public && !explicitlySerialized) ||
                        field.IsStatic || field.IsConst || field.IsReadOnly ||
                        field.IsImplicitlyDeclared ||
                        fieldAttributes.Contains("System.NonSerializedAttribute"))
                        continue;
                    EmitField(field, "", hide, 0);
                }

                // One Inspector field's rows (a nested [Serializable] type's fields as "Outer.Inner").
                // given: the value an enclosing field's initializer sets this nested field to
                // (`Stats = new() { Health = 10 }`), which wins over the field's own initializer.
                void EmitField(IFieldSymbol field, string prefix, bool hide, int depth, ExpressionSyntax? given = null)
                {
                    ExpressionSyntax? initializer = given ?? (field.DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax()
                        is VariableDeclaratorSyntax { Initializer: { } declared } ? declared.Value : null);
                    // Object references: a GameObject, its Transform, a built-in component handle or a C# script,
                    // set in the Inspector by dragging an object in (column 8 says which).
                    string? referenceType = ReferenceDescriptor(field.Type);
                    // A data asset is not in a scene: it has no objects to point at.
                    if (dataAsset && referenceType != null)
                        return;
                    // A list or array of a value kind is "list:<kind>" (column 8: the element enum's names).
                    ITypeSymbol? element = field.Type switch
                    {
                        IArrayTypeSymbol { Rank: 1 } array => array.ElementType,
                        INamedTypeSymbol { IsGenericType: true } named when
                            named.OriginalDefinition.ToDisplayString() == "System.Collections.Generic.List<T>" =>
                            named.TypeArguments[0],
                        _ => null
                    };
                    string? elementKind = element != null ? InspectorScalarKind(element) : null;
                    // A list of a [Serializable] struct/class of the game's: "list:record", column 8 its fields.
                    string? recordSchema = element != null && elementKind == null && IsNestedInspectorType(element)
                        ? RecordSchema(element) : null;
                    if (recordSchema != null)
                        elementKind = "record";
                    string? kind = referenceType != null ? "object" :
                        element != null ? (elementKind != null ? "list:" + elementKind : null) :
                        InspectorScalarKind(field.Type);
                    if (kind is null)
                    {
                        // A [Serializable] struct or class of the game's: its own fields, as "Field.Inner" rows.
                        if (depth < 4 && IsNestedInspectorType(field.Type))
                        {
                            // What this field's own initializer sets its fields to: `new() { Health = 10 }`.
                            InitializerExpressionSyntax? members = initializer switch
                            {
                                ObjectCreationExpressionSyntax created => created.Initializer,
                                ImplicitObjectCreationExpressionSyntax created => created.Initializer,
                                _ => null
                            };
                            var set = new Dictionary<string, ExpressionSyntax>(StringComparer.Ordinal);
                            foreach (AssignmentExpressionSyntax assignment in members?.Expressions
                                .OfType<AssignmentExpressionSyntax>() ?? [])
                                if (assignment.Left is IdentifierNameSyntax member)
                                    set[member.Identifier.Text] = assignment.Right;
                            foreach (IFieldSymbol inner in field.Type.GetMembers().OfType<IFieldSymbol>())
                            {
                                var innerAttributes = inner.GetAttributes()
                                    .Select(a => a.AttributeClass?.ToDisplayString())
                                    .ToHashSet(StringComparer.Ordinal);
                                bool innerHide = innerAttributes.Contains("Tallow.HideInInspectorAttribute");
                                bool innerShown = innerHide || innerAttributes.Contains("Tallow.ShowInInspectorAttribute");
                                if ((inner.DeclaredAccessibility != Accessibility.Public && !innerShown) ||
                                    inner.IsStatic || inner.IsConst || inner.IsReadOnly || inner.IsImplicitlyDeclared ||
                                    innerAttributes.Contains("System.NonSerializedAttribute"))
                                    continue;
                                EmitField(inner, prefix + field.Name + ".", hide || innerHide, depth + 1,
                                    set.GetValueOrDefault(inner.Name));
                            }
                        }
                        return;
                    }
                    ITypeSymbol valueType = element ?? field.Type;

                    string defaultValue = kind switch
                    {
                        "bool" => "false", "string" => "", "object" => "", "Vector2" => "0,0",
                        "Vector3" => "0,0,0", "Vector4" => "0,0,0,0", "Color" => "1,1,1,1", _ => "0"
                    };
                    if (initializer != null)
                    {
                        SemanticModel fieldModel = compilation.GetSemanticModel(initializer.SyntaxTree);
                        var constant = fieldModel.GetConstantValue(initializer);
                        if (constant.HasValue && constant.Value is not null &&
                            kind is "bool" or "float" or "int" or "enum" or "string" or "double" or "uint" or "long")
                        {
                            defaultValue = Convert.ToString(constant.Value, CultureInfo.InvariantCulture) ?? defaultValue;
                            // The Inspector and scene files spell booleans in
                            // lower case; Convert.ToString gives "True".
                            if (kind == "bool")
                                defaultValue = constant.Value is true ? "true" : "false";
                            if (kind == "string" &&
                                defaultValue.IndexOfAny(['\t', '\n', '\r', '\0']) >= 0)
                                throw new InvalidOperationException(
                                    $"Inspector string initializer for {className}.{field.Name} " +
                                    "contains a tab, newline or NUL. Only single-line text is supported.");
                            if (kind == "enum" && field.Type is INamedTypeSymbol enumType)
                            {
                                IFieldSymbol? memberName = enumType.GetMembers()
                                    .OfType<IFieldSymbol>().FirstOrDefault(member =>
                                        member.HasConstantValue &&
                                        Equals(member.ConstantValue, constant.Value));
                                if (memberName != null)
                                    defaultValue = memberName.Name;
                            }
                        }
                        else if (kind.StartsWith("Vector", StringComparison.Ordinal))
                        {
                            ArgumentListSyntax? args = initializer switch
                            {
                                ObjectCreationExpressionSyntax v => v.ArgumentList,
                                ImplicitObjectCreationExpressionSyntax v => v.ArgumentList,
                                _ => null
                            };
                            if (args != null && args.Arguments.Count == int.Parse(kind["Vector".Length..],
                                    CultureInfo.InvariantCulture))
                            {
                                var numbers = args.Arguments.Select(a => fieldModel.GetConstantValue(a.Expression)).ToArray();
                                if (numbers.All(c => c.HasValue && c.Value is not null))
                                    defaultValue = string.Join(",", numbers.Select(c =>
                                        Convert.ToString(c.Value, CultureInfo.InvariantCulture)));
                            }
                        }
                    }
                    string rangeMin = "", rangeMax = "";
                    AttributeData? range = field.GetAttributes().FirstOrDefault(a =>
                        a.AttributeClass?.ToDisplayString() == "Tallow.RangeAttribute");
                    if (range is { ConstructorArguments.Length: 2 })
                    {
                        rangeMin = Convert.ToString(range.ConstructorArguments[0].Value,
                            CultureInfo.InvariantCulture) ?? "";
                        rangeMax = Convert.ToString(range.ConstructorArguments[1].Value,
                            CultureInfo.InvariantCulture) ?? "";
                    }
                    // The seventh column is a backwards-compatible
                    // visibility flag: older catalogs have 6 fields and
                    // therefore remain visible by default in the editor.
                    // Optional eighth field lists compiler-discovered enum
                    // choices without breaking the existing seven columns.
                    string row = string.Join("\t", className, prefix + field.Name, kind,
                        defaultValue, rangeMin, rangeMax, hide ? "1" : "0");
                    if ((kind == "enum" || kind == "list:enum") && valueType is INamedTypeSymbol enumDeclaration)
                    {
                        string names = string.Join("|", enumDeclaration.GetMembers()
                            .OfType<IFieldSymbol>()
                            .Where(member => member.HasConstantValue && !member.IsImplicitlyDeclared)
                            .Select(member => member.Name));
                        row += "\t" + names;
                    }
                    else if (recordSchema != null)
                        row += "\t" + recordSchema;
                    else if (referenceType != null)
                        row += "\t" + referenceType;
                    else if ((kind == "string" || kind == "list:string") && field.GetAttributes().FirstOrDefault(a =>
                        a.AttributeClass?.ToDisplayString() == "Tallow.AssetAttribute") is { ConstructorArguments.Length: 1 } asset &&
                        asset.ConstructorArguments[0].Value is string assetKind && SerializedIdName.IsMatch(assetKind))
                        // Column 8 of a string: "asset:<kind>", an asset path the Inspector picks.
                        row += "\t" + "asset:" + assetKind;
                    fieldRows.Add(row);
                    // The field's /// <summary> is its Inspector tooltip.
                    if (FieldDocumentation(field) is { Length: > 0 } documentation)
                        fieldDocRows.Add(string.Join("\t", className, prefix + field.Name, documentation));

                    AttributeData? identityAttribute = field.GetAttributes().FirstOrDefault(a =>
                        a.AttributeClass?.ToDisplayString() == "Tallow.SerializedFieldIdAttribute");
                    string identity = prefix + (identityAttribute is null ? field.Name :
                        identityAttribute.ConstructorArguments.FirstOrDefault().Value as string ?? "");
                    if (!SerializedIdName.IsMatch(identity))
                        throw new InvalidOperationException(
                            $"Invalid [SerializedFieldId] for {className}.{field.Name}: " +
                            "use 1-64 letters, digits, '.', '_' or '-'.");
                    string stableId = StableFieldId(className, identity);
                    if (!seenFieldIds.Add(stableId))
                        throw new InvalidOperationException(
                            $"Duplicate serialized field identity on {className}: {identity}.");
                    aotFieldRows.Add(string.Join("\t",
                        className, stableId, prefix + field.Name, kind, hide ? "1" : "0"));
                }
            }
        }

        // C# structs marked [Component] can become native Flecs columns,
        // but NOT before the runtime proves the binary layout and lifetime
        // are safe. Describe only explicitly supported unmanaged field kinds
        // so we can generate typed bindings without runtime type scanning.
        foreach (SyntaxTree tree in trees)
        {
            SemanticModel model = compilation.GetSemanticModel(tree);
            foreach (StructDeclarationSyntax node in tree.GetRoot().DescendantNodes()
                .OfType<StructDeclarationSyntax>())
            {
                if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol type ||
                    !type.GetAttributes().Any(a =>
                        a.AttributeClass?.ToDisplayString() == "Tallow.ComponentAttribute"))
                    continue;
                string componentName = type.ToDisplayString(
                    SymbolDisplayFormat.CSharpErrorMessageFormat);
                bool allSupported = !type.IsGenericType && type.IsUnmanagedType;
                var rows = new List<string>();
                foreach (IFieldSymbol field in type.GetMembers().OfType<IFieldSymbol>())
                {
                    if (field.IsStatic || field.IsConst || field.IsImplicitlyDeclared)
                        continue;
                    string? kind = field.Type.SpecialType switch
                    {
                        SpecialType.System_Boolean => "bool",
                        SpecialType.System_Int32 => "int",
                        SpecialType.System_UInt32 => "uint",
                        SpecialType.System_Int64 => "long",
                        SpecialType.System_UInt64 => "ulong",
                        SpecialType.System_Single => "float",
                        SpecialType.System_Double => "double",
                        _ => field.Type.ToDisplayString() switch
                        {
                            "System.Numerics.Vector2" => "Vector2",
                            "System.Numerics.Vector3" => "Vector3",
                            "System.Numerics.Vector4" => "Vector4",
                            "System.Numerics.Quaternion" => "Quaternion",
                            _ => null
                        }
                    };
                    if (kind is null || field.IsReadOnly || field.IsFixedSizeBuffer)
                        allSupported = false;
                    bool synced = field.GetAttributes().Any(a =>
                        a.AttributeClass?.ToDisplayString() == "Tallow.SyncAttribute");
                    rows.Add(string.Join("\t", componentName, field.Name,
                        kind ?? "unsupported", synced ? "1" : "0"));
                }
                // Explicit status prevents the shipping exporter from
                // misinterpreting an incomplete source layout as compatible.
                rows.Insert(0, string.Join("\t", componentName, "@layout",
                    allSupported ? "candidate" : "unsupported", "0"));
                ecsDataRows[componentName] = rows;
            }
        }

        string catalog = Path.Combine(project, ".tallow-csharp", "components.tsv");
        Directory.CreateDirectory(Path.GetDirectoryName(catalog)!);
        // Keep no-op catalog timestamps stable; the editor only needs a
        // metadata refresh when the actual field/type schema has changed.
        // Changed output is still published via an atomic rename.
        Publish(catalog, components);
        Publish(Path.Combine(project, ".tallow-csharp", "component-sources.tsv"), sourceRows);
        Publish(Path.Combine(project, ".tallow-csharp", "former-names.tsv"), formerRows);
        Publish(Path.Combine(project, ".tallow-csharp", "fields.tsv"), fieldRows);
        Publish(Path.Combine(project, ".tallow-csharp", "data-assets.tsv"), dataAssetRows);
        Publish(Path.Combine(project, ".tallow-csharp", "fields-aot.tsv"), aotFieldRows);
        Publish(Path.Combine(project, ".tallow-csharp", "field-docs.tsv"), fieldDocRows);
        Publish(Path.Combine(project, ".tallow-csharp", "ecs-data.tsv"), ecsDataRows.Values.SelectMany(rows => rows));
        GraphNodeCatalog.Write(compilation, trees, GraphNodesPath(project));
        BehaviorNodeCatalog.Write(compilation, trees, Path.Combine(project, ".tallow-csharp", "behavior-nodes.tsv"));
        Console.WriteLine($"Discovered {components.Count} managed gameplay components and {fieldRows.Count} editable fields.");
    }

    /// <summary>
    /// After a build: the NuGet packages the game uses (those its assembly definitions list and what they need),
    /// from each project's restore. Writes .tallow-csharp/third-party.tsv (id, version, licence, project URL) and
    /// package-references.tsv (the assemblies the editor's code service references), and for a game build
    /// THIRD-PARTY-NOTICES.txt beside the assemblies. Package code runs with the game's full trust: Tallow's
    /// script rules (no unsafe code) are not applied to it.
    /// </summary>
    private static void WritePackageLists(string project, string? outputRoot)
    {
        string generated = Path.Combine(project, ".tallow-csharp", "generated");
        var packages = new SortedDictionary<string, (string Version, string Licence, string Url)>(StringComparer.OrdinalIgnoreCase);
        var references = new SortedSet<string>(StringComparer.Ordinal);
        if (Directory.Exists(generated))
        {
            foreach (string assets in Directory.EnumerateFiles(generated, "project.assets.json", SearchOption.AllDirectories))
            {
                using JsonDocument json = JsonDocument.Parse(File.ReadAllText(assets));
                JsonElement root = json.RootElement;
                var folders = new List<string>();
                if (root.TryGetProperty("packageFolders", out JsonElement packageFolders))
                    foreach (JsonProperty folder in packageFolders.EnumerateObject())
                        folders.Add(folder.Name);
                if (!root.TryGetProperty("libraries", out JsonElement libraries))
                    continue;
                foreach (JsonProperty library in libraries.EnumerateObject())
                {
                    if (!library.Value.TryGetProperty("type", out JsonElement type) || type.GetString() != "package")
                        continue;
                    string[] parts = library.Name.Split('/');
                    if (parts.Length != 2 || !library.Value.TryGetProperty("path", out JsonElement relative))
                        continue;
                    string? home = folders.Select(folder => Path.Combine(folder, relative.GetString()!))
                        .FirstOrDefault(Directory.Exists);
                    if (home == null)
                        continue;
                    (string licence, string url) = ReadNuspec(home, parts[0]);
                    packages[parts[0]] = (parts[1], licence, url);
                    if (root.TryGetProperty("targets", out JsonElement targets))
                    {
                        foreach (JsonProperty target in targets.EnumerateObject())
                        {
                            if (!target.Value.TryGetProperty(library.Name, out JsonElement entry) ||
                                !entry.TryGetProperty("compile", out JsonElement compile))
                                continue;
                            foreach (JsonProperty file in compile.EnumerateObject())
                                if (file.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                                    references.Add(Path.GetFullPath(Path.Combine(home, file.Name)));
                        }
                    }
                }
            }
        }
        Publish(Path.Combine(project, ".tallow-csharp", "third-party.tsv"),
            new SortedSet<string>(packages.Select(item =>
                $"{item.Key}\t{item.Value.Version}\t{item.Value.Licence}\t{item.Value.Url}"), StringComparer.Ordinal));
        Publish(Path.Combine(project, ".tallow-csharp", "package-references.tsv"), references);
        if (packages.Count == 0)
            return;
        Console.WriteLine("Third-party packages (they run with the game's full trust; Tallow's script rules do not apply to them): " +
            string.Join(", ", packages.Select(item => $"{item.Key} {item.Value.Version} ({item.Value.Licence})")));
        if (outputRoot != null)
        {
            var notices = new StringBuilder("This game includes these third-party packages:\n\n");
            foreach ((string id, (string version, string licence, string url)) in packages)
                notices.Append($"{id} {version}\n  Licence: {licence}\n" + (url.Length > 0 ? $"  {url}\n" : "") + "\n");
            File.WriteAllText(Path.Combine(outputRoot, "THIRD-PARTY-NOTICES.txt"), notices.ToString());
        }
    }

    /// <summary>Writes rows (one a line) unless the file already holds exactly them, so its time only changes
    /// with its content.</summary>
    private static void Publish(string path, IEnumerable<string> rows)
    {
        string updated = string.Join(Environment.NewLine, rows);
        if (updated.Length != 0)
            updated += Environment.NewLine;
        if (File.Exists(path) && File.ReadAllText(path) == updated)
            return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", updated);
        File.Move(path + ".tmp", path, overwrite: true);
    }

    /// <summary>A package's licence (an SPDX expression, a licence file's name, or its licence URL) and
    /// project URL, from the .nuspec in its folder.</summary>
    private static (string Licence, string Url) ReadNuspec(string folder, string id)
    {
        string? nuspec = Directory.EnumerateFiles(folder, "*.nuspec").FirstOrDefault();
        if (nuspec == null)
            return ("unknown", "");
        XElement metadata = XDocument.Load(nuspec).Root?.Elements().FirstOrDefault(e => e.Name.LocalName == "metadata")
            ?? new XElement("metadata");
        string Value(string name) =>
            metadata.Elements().FirstOrDefault(e => e.Name.LocalName == name)?.Value.Trim() ?? "";
        string licence = Value("license");
        if (licence.Length == 0)
            licence = Value("licenseUrl");
        return (licence.Length > 0 ? licence : "unknown", Value("projectUrl"));
    }

    /// <summary>Holds .tallow-csharp/build.lock open (no sharing) for the build, waiting up to five minutes for a build
    /// of the same project already running. The operating system lets go of it if the process dies.</summary>
    private static FileStream LockProject(string project)
    {
        string folder = Path.Combine(project, ".tallow-csharp");
        Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, "build.lock");
        var waited = Stopwatch.StartNew();
        bool told = false;
        while (true)
        {
            try
            {
                return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            }
            catch (IOException) when (waited.Elapsed < TimeSpan.FromMinutes(5))
            {
                if (!told)
                {
                    Console.WriteLine("Another build of this project is running; waiting for it.");
                    told = true;
                }
                Thread.Sleep(100);
            }
        }
    }

    public static int Main(string[] args)
    {
        // export: a game folder for a platform (Export/Exporter.cs); web-setup: what web exports need, once;
        // serve: the editor's local web server for trying a web build.
        string[] command = args.SkipWhile(arg => arg == "--").ToArray();
        if (command.Length > 0 && command[0] == "export")
            return Export.Exporter.Run(command[1..]);
        if (command.Length > 0 && command[0] == "web-setup")
            return Export.WebExport.Setup(command[1..]);
        if (command.Length > 0 && command[0] == "serve")
            return Export.WebServer.Run(command[1..]);
        if (command.Length > 0 && command[0] == "pack")
            return Export.AssetCommands.Pack(command[1..]);
        if (command.Length > 0 && command[0] == "convert-models")
            return Export.AssetCommands.ConvertModels(command[1..]);
        if (command.Length > 0 && command[0] == "compress-textures")
            return Export.AssetCommands.CompressTextures(command[1..]);
        try
        {
            string project = Path.GetFullPath(RequiredOption(args, "--project"));
            string engine = Path.GetFullPath(RequiredOption(args, "--engine-root"));
            // One build of a project at a time: the editor, the launcher and a command line can all start one, and two
            // writing the same generated projects and obj folders would break each other. The next waits its turn.
            using FileStream buildLock = LockProject(project);
            string game = Generate(project, engine, out string? editorProject);
            if (Flag(args, "--generate-only"))
                return 0;

            var process = new ProcessStartInfo("dotnet")
            {
                UseShellExecute = false
            };
            // --configuration Release --output DIR: an optimised build of every assembly into DIR/<name>/ (a game
            // build), leaving the editor's .tallow-csharp/bin alone.
            string configuration = OptionalOption(args, "--configuration") ?? "Debug";
            if (configuration is not ("Debug" or "Release"))
                throw new ArgumentException("--configuration is Debug or Release.");
            string? outputRoot = OptionalOption(args, "--output");
            // The editor's build is of the editor scripts when there are some: they reference every game assembly, so
            // building them builds the game too. A game build (--output) never has them.
            string target = outputRoot == null && editorProject != null ? editorProject : game;
            foreach (string part in new[] { "build", target, "--configuration", configuration,
                "--nologo", "--verbosity", "minimal" })
                process.ArgumentList.Add(part);
            if (outputRoot != null)
                process.ArgumentList.Add("-p:TallowBinRoot=" + Path.GetFullPath(outputRoot).TrimEnd('/', '\\') + Path.DirectorySeparatorChar);
            using Process? build = Process.Start(process);
            if (build == null)
                throw new InvalidOperationException("Could not start the .NET SDK.");
            build.WaitForExit();
            if (build.ExitCode == 0)
            {
                WritePackageLists(project, outputRoot);
                string gameBin = Path.Combine(outputRoot != null ? Path.GetFullPath(outputRoot)
                    : Path.Combine(project, ".tallow-csharp", "bin"), "Tallow.Game");
                if (sCodeId != null && Directory.Exists(gameBin))
                {
                    string idPath = Path.Combine(gameBin, "Tallow.Game.codeid");
                    if (!File.Exists(idPath) || File.ReadAllText(idPath).Trim() != sCodeId)
                        File.WriteAllText(idPath, sCodeId + "\n");
                }
            }
            // A game build lists what would make networked play go out of step (the code editor shows the same).
            if (build.ExitCode == 0 && outputRoot != null)
                ReportDeterminism(project, engine);
            if (build.ExitCode == 0 && outputRoot == null)
                WriteComponentCatalog(project, engine);
            // A graph can still be worked on while the game does not compile: its nodes come from the sources.
            else if (outputRoot == null)
                GraphNodeCatalog.Write(CatalogCompilation(project, engine, out SyntaxTree[] trees), trees, GraphNodesPath(project));
            return build.ExitCode;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or
            ArgumentException or InvalidOperationException or JsonException)
        {
            Console.Error.WriteLine($"C# gameplay build failed: {exception.Message}");
            return 1;
        }
    }
}
