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
    private sealed record Definition(string Name, string Folder, List<string> References, string RootNamespace);

    private static readonly Regex AssemblyName = new(
        @"^[A-Za-z_][A-Za-z0-9_.]*$", RegexOptions.CultureInvariant);

    // Identifiers can survive renames when explicitly supplied. Limit their
    // alphabet so the generated source/scene manifest needs no escaping.
    private static readonly Regex SerializedIdName = new(
        @"^[A-Za-z0-9_.-]{1,64}$", RegexOptions.CultureInvariant);

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
            if (!AssemblyName.IsMatch(name) || name is "Tallow.Game" or "Tallow.API" ||
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
            definitions.Add(name, new Definition(name, folder, references, rootNamespace));
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

    private static bool IsInFolder(string file, string folder)
    {
        string relative = Path.GetRelativePath(folder, file);
        return relative != ".." && !Path.IsPathRooted(relative) &&
            !relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal);
    }

    private static XDocument CreateProject(
        string name, string rootNamespace, IEnumerable<string> files, IEnumerable<string> references,
        string api, string output)
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
            new XElement("OutputPath", output + Path.DirectorySeparatorChar));
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
        return new XDocument(new XElement("Project", new XAttribute("Sdk", "Microsoft.NET.Sdk"),
            properties, includes, refs));
    }


    /// <summary>
    /// Generate direct C# factories in each trusted gameplay assembly, before
    /// building that assembly. This preserves access to internal component
    /// classes and provides an AOT-linkable root without reflection or IL DLL
    /// discovery. The current editor keeps its collectible JIT loader.
    /// </summary>
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
        var compilation = CSharpCompilation.Create("Tallow.StaticComponentFactories",
            treesByPath.Values.Cast<SyntaxTree>().Concat(apiTrees).Append(
                CSharpSyntaxTree.ParseText("global using System.Numerics;", parse)),
            refs, new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary,
                allowUnsafe: true));

        static string FactoryName(string assembly) =>
            "ComponentFactory_" + Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(assembly)).AsSpan(0, 8));

        var allTypes = new Dictionary<string, SortedDictionary<string, string>>(
            StringComparer.Ordinal);
        // Each assembly gets its own typed local-data adapters. No gameplay
        // assembly scanning or reflection is needed after C# compilation.
        var allEcsTypes = new Dictionary<string,
            SortedDictionary<string, (string CSharpType, string SchemaId)>>(
                StringComparer.Ordinal);
        foreach (var (assembly, sourceFiles) in filesByAssembly)
        {
            var types = new SortedDictionary<string, string>(StringComparer.Ordinal);
            var ecsTypes = new SortedDictionary<string, (string CSharpType, string SchemaId)>(
                StringComparer.Ordinal);
            foreach (string sourceFile in sourceFiles)
            {
                SyntaxTree tree = treesByPath[sourceFile];
                SemanticModel model = compilation.GetSemanticModel(tree);
                foreach (ClassDeclarationSyntax node in tree.GetRoot().DescendantNodes()
                    .OfType<ClassDeclarationSyntax>())
                {
                    if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol symbol)
                        continue;
                    // Deriving from Script identifies a gameplay behaviour;
                    // [Component] is reserved for explicit ECS data structs.
                    bool isScript = false;
                    for (INamedTypeSymbol? parent = symbol.BaseType; parent != null;
                         parent = parent.BaseType)
                        if (parent.ToDisplayString() == "Tallow.Script")
                        {
                            isScript = true;
                            break;
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
                    bool supported = fields.Length > 0 && fields.Length <= 128;
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
                    ecsTypes[name] = (
                        symbol.ToDisplayString(SymbolDisplayFormat.FullyQualifiedFormat),
                        schemaId);
                }
            }
            allTypes.Add(assembly, types);
            allEcsTypes.Add(assembly, ecsTypes);
        }

        // Source is generated under .tallow-csharp, NEVER in the user's src.
        // Avoid changing timestamps on no-op builds.
        static void WriteIfDifferent(string path, string value)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (!File.Exists(path) || File.ReadAllText(path) != value)
                File.WriteAllText(path, value);
        }
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

        // Generate strongly typed local data adapters before compilation.
        // The managed value is copied into a pinned Span<byte> only for one
        // synchronous generated ABI call. Native Flecs stores opaque bytes;
        // no C# references/pointers escape, no Jolt state is modified, and
        // the scene/session/network guards still live in Beef.
        foreach ((string assembly, var ecsTypes) in allEcsTypes)
        {
            var generatedEcs = new StringBuilder();
            generatedEcs.AppendLine("// Generated by Tallow.Build. Offline-only packed ECS data.")
                .AppendLine("#nullable enable")
                .AppendLine("namespace Tallow.Generated;")
                .Append("public static class EcsLocalData_")
                .Append(FactoryName(assembly)).AppendLine()
                .AppendLine("{");
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
    }

    private static string Generate(string project, string engine)
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
        foreach (string file in Directory.EnumerateFiles(source, "*.cs", SearchOption.AllDirectories))
        {
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

        foreach ((string name, string path) in paths)
        {
            string[] references = name == "Tallow.Game"
                ? definitions.Keys.ToArray()
                : definitions[name].References.ToArray();
            string[] refPaths = references.Select(reference => paths[reference]).ToArray();
            string outputFolder = Path.Combine(output, name);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string rootNamespace = name == "Tallow.Game" ? name : definitions[name].RootNamespace;
            var csproj = CreateProject(name, rootNamespace, filesByAssembly[name].Order(), refPaths, api,
                outputFolder);
            // MSBuild treats project file timestamps as inputs. Saving an
            // identical .csproj on every no-op build invalidates otherwise
            // reusable compilation state, including referenced asmdefs.
            using var xml = new MemoryStream();
            csproj.Save(xml);
            byte[] bytes = xml.ToArray();
            if (!File.Exists(path) || !File.ReadAllBytes(path).AsSpan().SequenceEqual(bytes))
                File.WriteAllBytes(path, bytes);
        }
        Console.WriteLine($"Generated {paths.Count} C# assemblies; game: {paths["Tallow.Game"]}");
        return paths["Tallow.Game"];
    }

    /// <summary>
    /// Publish the managed component catalog only after all trusted assemblies
    /// compiled successfully. Roslyn checks inheritance and attributes, rather
    /// than guessing classes from file names or executing the user's game.
    /// </summary>
    private static void WriteComponentCatalog(string project, string engine)
    {
        string source = Path.Combine(project, "src");
        string api = Path.Combine(engine, "Managed", "Tallow.API");
        var parse = new CSharpParseOptions(LanguageVersion.CSharp15);
        var sources = Directory.EnumerateFiles(source, "*.cs", SearchOption.AllDirectories)
            .Order(StringComparer.Ordinal).ToArray();
        var trees = sources.Select(path => CSharpSyntaxTree.ParseText(
            File.ReadAllText(path), parse, path: Path.GetFullPath(path))).ToArray();
        var apiTrees = Directory.EnumerateFiles(api, "*.cs", SearchOption.AllDirectories)
            .Select(path => CSharpSyntaxTree.ParseText(
                File.ReadAllText(path), parse, path: Path.GetFullPath(path)));
        string trusted = (string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES") ?? "";
        var references = trusted.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(path => MetadataReference.CreateFromFile(path));
        var globalNumerics = CSharpSyntaxTree.ParseText(
            "global using System.Numerics;", parse, path: "Tallow.GlobalNumerics.g.cs");
        var compilation = CSharpCompilation.Create("Tallow.ComponentCatalog",
            trees.Concat(apiTrees).Append(globalNumerics), references,
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary));
        var components = new SortedSet<string>(StringComparer.Ordinal);
        var sourceRows = new SortedSet<string>(StringComparer.Ordinal);
        var fieldRows = new SortedSet<string>(StringComparer.Ordinal);
        // Build-only metadata for a future AOT static serializer. No new
        // runtime reflection or scene format is introduced by this manifest.
        var aotFieldRows = new SortedSet<string>(StringComparer.Ordinal);
        // A schema-only preview of user-defined C# Flecs data structs.
        // A future native bridge must validate sizeof/alignment and Sync
        // layouts before allowing writes or network replication.
        var ecsDataRows = new SortedSet<string>(StringComparer.Ordinal);

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
                bool script = false;
                for (INamedTypeSymbol? parent = type.BaseType; parent != null;
                    parent = parent.BaseType)
                {
                    if (parent.ToDisplayString() == "Tallow.Script")
                    {
                        script = true;
                        break;
                    }
                }
                if (!script)
                    continue;

                string className = type.ToDisplayString(SymbolDisplayFormat.CSharpErrorMessageFormat);
                components.Add(className);
                sourceRows.Add(tree.FilePath + "\t" + className);
                var seenFieldIds = new HashSet<string>(StringComparer.Ordinal);

                // Limit the first Inspector bridge to deterministic, supported
                // value types. Managed objects/references need their own handles.
                // Fields declared on user base classes belong to the component
                // too: list them base-first, as the runtime restores them.
                var fieldOwners = new List<INamedTypeSymbol>();
                for (INamedTypeSymbol? owner = type; owner != null &&
                     owner.ToDisplayString() != "Tallow.Script" &&
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
                    string? kind = field.Type.TypeKind == TypeKind.Enum ? "enum" :
                        field.Type.SpecialType switch
                    {
                        SpecialType.System_Single => "float",
                        SpecialType.System_Int32 => "int",
                        SpecialType.System_Boolean => "bool",
                        SpecialType.System_String => "string",
                        _ => field.Type.ToDisplayString() switch
                        {
                            "System.Numerics.Vector2" => "Vector2",
                            "System.Numerics.Vector3" => "Vector3",
                            "System.Numerics.Vector4" => "Vector4",
                            _ => null
                        }
                    };
                    if (kind is null)
                        continue;

                    string defaultValue = kind switch
                    {
                        "bool" => "false", "string" => "", "Vector2" => "0,0",
                        "Vector3" => "0,0,0", "Vector4" => "0,0,0,0", _ => "0"
                    };
                    if (field.DeclaringSyntaxReferences.FirstOrDefault()?.GetSyntax()
                        is VariableDeclaratorSyntax variable && variable.Initializer != null)
                    {
                        SemanticModel fieldModel = compilation.GetSemanticModel(variable.SyntaxTree);
                        var constant = fieldModel.GetConstantValue(variable.Initializer.Value);
                        if (constant.HasValue && constant.Value is not null &&
                            kind is "bool" or "float" or "int" or "enum" or "string")
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
                            ArgumentListSyntax? args = variable.Initializer.Value switch
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
                    string row = string.Join("\t", className, field.Name, kind,
                        defaultValue, rangeMin, rangeMax, hide ? "1" : "0");
                    if (kind == "enum" && field.Type is INamedTypeSymbol enumDeclaration)
                    {
                        string names = string.Join("|", enumDeclaration.GetMembers()
                            .OfType<IFieldSymbol>()
                            .Where(member => member.HasConstantValue && !member.IsImplicitlyDeclared)
                            .Select(member => member.Name));
                        row += "\t" + names;
                    }
                    fieldRows.Add(row);

                    AttributeData? identityAttribute = field.GetAttributes().FirstOrDefault(a =>
                        a.AttributeClass?.ToDisplayString() == "Tallow.SerializedFieldIdAttribute");
                    string identity = identityAttribute is null ? field.Name :
                        identityAttribute.ConstructorArguments.FirstOrDefault().Value as string ?? "";
                    if (!SerializedIdName.IsMatch(identity))
                        throw new InvalidOperationException(
                            $"Invalid [SerializedFieldId] for {className}.{field.Name}: " +
                            "use 1-64 letters, digits, '.', '_' or '-'.");
                    string stableId = StableFieldId(className, identity);
                    if (!seenFieldIds.Add(stableId))
                        throw new InvalidOperationException(
                            $"Duplicate serialized field identity on {className}: {identity}.");
                    aotFieldRows.Add(string.Join("\t",
                        className, stableId, field.Name, kind, hide ? "1" : "0"));
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
                ecsDataRows.Add(string.Join("\t", componentName, "@layout",
                    allSupported ? "candidate" : "unsupported", "0"));
                foreach (string row in rows)
                    ecsDataRows.Add(row);
            }
        }

        string catalog = Path.Combine(project, ".tallow-csharp", "components.tsv");
        Directory.CreateDirectory(Path.GetDirectoryName(catalog)!);
        // Keep no-op catalog timestamps stable; the editor only needs a
        // metadata refresh when the actual field/type schema has changed.
        // Changed output is still published via an atomic rename.
        static void Publish(string path, IEnumerable<string> rows)
        {
            string updated = string.Join(Environment.NewLine, rows);
            if (updated.Length != 0)
                updated += Environment.NewLine;
            if (File.Exists(path) && File.ReadAllText(path) == updated)
                return;
            File.WriteAllText(path + ".tmp", updated);
            File.Move(path + ".tmp", path, overwrite: true);
        }
        Publish(catalog, components);
        Publish(Path.Combine(project, ".tallow-csharp", "component-sources.tsv"), sourceRows);
        Publish(Path.Combine(project, ".tallow-csharp", "fields.tsv"), fieldRows);
        Publish(Path.Combine(project, ".tallow-csharp", "fields-aot.tsv"), aotFieldRows);
        Publish(Path.Combine(project, ".tallow-csharp", "ecs-data.tsv"), ecsDataRows);
        Console.WriteLine($"Discovered {components.Count} managed gameplay components and {fieldRows.Count} editable fields.");
    }

    public static int Main(string[] args)
    {
        try
        {
            string project = Path.GetFullPath(RequiredOption(args, "--project"));
            string engine = Path.GetFullPath(RequiredOption(args, "--engine-root"));
            string game = Generate(project, engine);
            if (Flag(args, "--generate-only"))
                return 0;

            var process = new ProcessStartInfo("dotnet")
            {
                UseShellExecute = false
            };
            foreach (string part in new[] { "build", game, "--configuration", "Debug",
                "--nologo", "--verbosity", "minimal" })
                process.ArgumentList.Add(part);
            using Process? build = Process.Start(process);
            if (build == null)
                throw new InvalidOperationException("Could not start the .NET SDK.");
            build.WaitForExit();
            if (build.ExitCode == 0)
                WriteComponentCatalog(project, engine);
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
