using System.Diagnostics;
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
    private sealed record Definition(string Name, string Folder, List<string> References);

    private static readonly Regex AssemblyName = new(
        @"^[A-Za-z_][A-Za-z0-9_.]*$", RegexOptions.CultureInvariant);

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
            definitions.Add(name, new Definition(name, folder, references));
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
        string name, IEnumerable<string> files, IEnumerable<string> references, string api,
        string output)
    {
        var properties = new XElement("PropertyGroup",
            new XElement("TargetFramework", "net11.0"),
            new XElement("LangVersion", "15.0"),
            new XElement("AssemblyName", name),
            new XElement("RootNamespace", name),
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
            files.Select(file => new XElement("Compile", new XAttribute("Include", file))));
        var refs = new XElement("ItemGroup",
            new XElement("ProjectReference", new XAttribute("Include", api)));
        foreach (string reference in references)
            refs.Add(new XElement("ProjectReference", new XAttribute("Include", reference)));
        return new XDocument(new XElement("Project", new XAttribute("Sdk", "Microsoft.NET.Sdk"),
            properties, includes, refs));
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

        foreach ((string name, string path) in paths)
        {
            string[] references = name == "Tallow.Game"
                ? definitions.Keys.ToArray()
                : definitions[name].References.ToArray();
            string[] refPaths = references.Select(reference => paths[reference]).ToArray();
            string outputFolder = Path.Combine(output, name);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var csproj = CreateProject(name, filesByAssembly[name].Order(), refPaths, api, outputFolder);
            csproj.Save(path);
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

        foreach (SyntaxTree tree in trees)
        {
            SemanticModel model = compilation.GetSemanticModel(tree);
            foreach (ClassDeclarationSyntax node in tree.GetRoot().DescendantNodes()
                .OfType<ClassDeclarationSyntax>())
            {
                if (model.GetDeclaredSymbol(node) is not INamedTypeSymbol type || type.IsAbstract)
                    continue;
                bool marked = type.GetAttributes().Any(attribute =>
                    attribute.AttributeClass?.ToDisplayString() == "Tallow.ComponentAttribute");
                if (!marked)
                    continue;
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
                if (script)
                    components.Add(type.ToDisplayString(SymbolDisplayFormat.CSharpErrorMessageFormat));
            }
        }

        string catalog = Path.Combine(project, ".tallow-csharp", "components.tsv");
        Directory.CreateDirectory(Path.GetDirectoryName(catalog)!);
        string temporary = catalog + ".tmp";
        File.WriteAllLines(temporary, components);
        File.Move(temporary, catalog, overwrite: true);
        Console.WriteLine($"Discovered {components.Count} managed gameplay components.");
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
