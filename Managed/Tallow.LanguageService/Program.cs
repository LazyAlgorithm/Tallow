using System.Text;
using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Tallow.LanguageService;

// Tallow's native text widget exchanges UTF-8 byte offsets. Roslyn uses UTF-16
// positions; convert only at the boundary to preserve locations in non-ASCII files.
internal sealed class SourceFile
{
    public string Path { get; set; } = "";
    public string Text { get; set; } = "";
}

internal sealed class LanguageRequest
{
    public string Operation { get; set; } = "";
    public string File { get; set; } = "";
    public int Cursor { get; set; }
    public string NewName { get; set; } = "";
    public List<SourceFile> Sources { get; set; } = [];
}

internal static class Program
{
    private static string Clean(string value) =>
        value.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');

    private static string Line(params object?[] parts) =>
        string.Join("\t", parts.Select(part => Clean(part?.ToString() ?? "")));

    private static int ToUtf16(string value, int byteOffset)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value);
        byteOffset = Math.Clamp(byteOffset, 0, bytes.Length);
        return Encoding.UTF8.GetString(bytes, 0, byteOffset).Length;
    }

    private static int ToUtf8(string value, int utf16Offset) =>
        Encoding.UTF8.GetByteCount(value.AsSpan(0, Math.Clamp(utf16Offset, 0, value.Length)));

    // Loaded once for the lifetime of the long-running Roslyn service.
    // Hundreds of framework references are expensive to rebuild per request.
    private static readonly Lazy<MetadataReference[]> CachedReferences = new(() =>
    {
        string assemblies = (string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES") ?? "";
        return assemblies.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Where(File.Exists).Select(path => (MetadataReference)MetadataReference.CreateFromFile(path)).ToArray();
    });

    private static IEnumerable<MetadataReference> References() => CachedReferences.Value;

    // The editor holds one Roslyn process for many requests. Reuse immutable
    // parsed trees for sources that did not change instead of lexing the full
    // game + public API on every keystroke. A changed overlay replaces its
    // tree immediately; closed/deleted files are evicted below.
    private sealed record CachedSyntax(string Text, SyntaxTree Tree);
    private static readonly Dictionary<string, CachedSyntax> ParsedSources =
        new(StringComparer.OrdinalIgnoreCase);

    private static List<SyntaxTree> ParseSnapshots(
        IReadOnlyDictionary<string, SourceFile> sourceByPath, CSharpParseOptions options)
    {
        var trees = new List<SyntaxTree>(sourceByPath.Count + 1);
        foreach ((string path, SourceFile source) in sourceByPath)
        {
            if (!ParsedSources.TryGetValue(path, out CachedSyntax? cached) ||
                !string.Equals(cached.Text, source.Text, StringComparison.Ordinal))
            {
                cached = new CachedSyntax(source.Text,
                    CSharpSyntaxTree.ParseText(source.Text, options, path: path));
                ParsedSources[path] = cached;
            }
            trees.Add(cached.Tree);
        }
        // Live game source sets change when scripts are added/deleted. Never
        // keep a stale tree from a previous game or scene session.
        foreach (string stale in ParsedSources.Keys
            .Where(path => !sourceByPath.ContainsKey(path)).ToArray())
            ParsedSources.Remove(stale);
        return trees;
    }


    private static ISymbol? SymbolAt(SemanticModel model, SyntaxNode root, int position)
    {
        if (root.FullSpan.IsEmpty)
            return null;
        position = Math.Clamp(position, 0, root.FullSpan.End);
        SyntaxNode? node = root.FindToken(position > 0 ? position - 1 : position).Parent;
        while (node != null)
        {
            ISymbol? symbol = model.GetDeclaredSymbol(node) ?? model.GetSymbolInfo(node).Symbol;
            if (symbol != null)
                return symbol;
            node = node.Parent;
        }
        return null;
    }

    private static void Diagnostics(CSharpCompilation compilation,
        Dictionary<string, SourceFile> sourceByPath, List<string> output)
    {
        foreach (Diagnostic problem in compilation.GetDiagnostics())
        {
            if (problem.Severity is not (DiagnosticSeverity.Error or DiagnosticSeverity.Warning) ||
                !problem.Location.IsInSource)
                continue;
            var location = problem.Location.GetLineSpan();
            string path = location.Path;
            if (!sourceByPath.TryGetValue(path, out SourceFile? source))
                continue;
            int line = location.StartLinePosition.Line;
            int column = location.StartLinePosition.Character;
            int lineStart = source.Text.LastIndexOf('\n',
                Math.Max(0, Math.Min(problem.Location.SourceSpan.Start, source.Text.Length) - 1)) + 1;
            int charPosition = Math.Min(source.Text.Length, lineStart + column);
            int byteColumn = Encoding.UTF8.GetByteCount(source.Text.AsSpan(lineStart, Math.Max(0, charPosition - lineStart)));
            output.Add(Line("diagnostic", path, line, byteColumn,
                problem.Severity == DiagnosticSeverity.Error ? "error" : "warning",
                $"{problem.Id}: {problem.GetMessage()}"));
        }
    }

    private static void References(CSharpCompilation compilation,
        ISymbol symbol, List<string> output)
    {
        foreach (SyntaxTree tree in compilation.SyntaxTrees)
        {
            SemanticModel model = compilation.GetSemanticModel(tree);
            SyntaxNode root = tree.GetRoot();
            string source = tree.GetText().ToString();
            var found = new HashSet<int>();
            foreach (SyntaxToken token in root.DescendantTokens())
            {
                if (!token.IsKind(SyntaxKind.IdentifierToken))
                    continue;
                ISymbol? candidate = model.GetDeclaredSymbol(token.Parent!) ??
                    model.GetSymbolInfo(token.Parent!).Symbol;
                if (!SymbolEqualityComparer.Default.Equals(symbol, candidate) ||
                    !found.Add(token.SpanStart))
                    continue;
                output.Add(Line("reference", tree.FilePath, ToUtf8(source, token.SpanStart),
                    Encoding.UTF8.GetByteCount(token.ValueText), token.ValueText));
            }
        }
    }

    private static void Run(LanguageRequest request, List<string> output)
    {
        var sourceByPath = new Dictionary<string, SourceFile>(StringComparer.OrdinalIgnoreCase);
        foreach (SourceFile source in request.Sources)
            sourceByPath[Path.GetFullPath(source.Path)] = source;
        if (!sourceByPath.TryGetValue(Path.GetFullPath(request.File), out SourceFile? active))
            throw new InvalidOperationException("Requested source is outside the C# project.");

        var parse = new CSharpParseOptions(LanguageVersion.CSharp15);
        List<SyntaxTree> trees = ParseSnapshots(sourceByPath, parse);
        // Match the generated game assemblies' implicit System.Numerics import.
        // The game uses SDK-generated implicit usings plus Tallow's extra
        // System.Numerics import. Roslyn's standalone semantic compilation
        // must use the SAME global imports as the real generated .csproj,
        // otherwise source API types produce misleading CS0246 and operator
        // errors even when the actual game assembly compiles correctly.
        trees.Add(CSharpSyntaxTree.ParseText("""
            global using System;
            global using System.Collections.Generic;
            global using System.IO;
            global using System.Linq;
            global using System.Net.Http;
            global using System.Threading;
            global using System.Threading.Tasks;
            global using System.Numerics;
            """, parse, path: "Tallow.GameImplicitUsings.g.cs"));
        var compilation = CSharpCompilation.Create("Tallow.SemanticWorkspace", trees,
            References(), // The workspace includes trusted Tallow.API source, whose generated
            // native function-pointer wrappers use unsafe internally. Game
            // project MSBuild still forbids unsafe gameplay code.
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary,
                allowUnsafe: true,
                nullableContextOptions: NullableContextOptions.Enable));
        SyntaxTree selected = trees.First(tree =>
            string.Equals(tree.FilePath, Path.GetFullPath(request.File), StringComparison.OrdinalIgnoreCase));
        SemanticModel model = compilation.GetSemanticModel(selected);
        SyntaxNode root = selected.GetRoot();
        int position = ToUtf16(active.Text, request.Cursor);
        position = Math.Clamp(position, 0, active.Text.Length);

        // Collect declared engine and game types from the same Roslyn
        // source snapshot used by diagnostics/completion. The editor may
        // color those names without maintaining a handwritten engine list.
        var declaredTypes = new SortedSet<string>(StringComparer.Ordinal);
        foreach (SyntaxTree tree in trees)
        {
            foreach (BaseTypeDeclarationSyntax declaration in tree.GetRoot()
                .DescendantNodes().OfType<BaseTypeDeclarationSyntax>())
                declaredTypes.Add(declaration.Identifier.ValueText);
            foreach (DelegateDeclarationSyntax declaration in tree.GetRoot()
                .DescendantNodes().OfType<DelegateDeclarationSyntax>())
                declaredTypes.Add(declaration.Identifier.ValueText);
        }
        foreach (string name in declaredTypes)
            output.Add(Line("type", name));

        if (request.Operation == "diagnostics")
        {
            Diagnostics(compilation, sourceByPath, output);
            // Keep Tallow's established cyan performance / purple network
            // underlines. New category column is optional; older consumers
            // still understand the first six fields.
            foreach (GameplayDiagnostics.Warning warning in GameplayDiagnostics.Analyze(
                compilation, sourceByPath))
                output.Add(Line("diagnostic", warning.Path, warning.Line,
                    warning.Utf8Column, "warning", warning.Message, warning.Category));
            return;
        }

        if (request.Operation == "completion")
        {
            SyntaxNode? node = root.FullSpan.IsEmpty ? null :
                root.FindToken(position > 0 ? position - 1 : position).Parent;
            MemberAccessExpressionSyntax? member = node?.AncestorsAndSelf()
                .OfType<MemberAccessExpressionSyntax>().FirstOrDefault();
            // Rigidbody?.AddF is a member binding inside a conditional
            // access expression; it is NOT a normal MemberAccessExpression.
            // Without resolving its receiver, autocomplete fell back to
            // unrelated global symbols instead of Rigidbody methods.
            ConditionalAccessExpressionSyntax? conditional = member is null ?
                node?.AncestorsAndSelf().OfType<ConditionalAccessExpressionSyntax>()
                    .FirstOrDefault() : null;
            ExpressionSyntax? receiverExpression =
                member?.Expression ?? conditional?.Expression;

            // The SDK compiler knows project types, members (including inherited
            // ones), and all referenced framework assemblies. Do not maintain a
            // second hand-written API list for C# completion.
            var names = new Dictionary<string, string>(StringComparer.Ordinal);
            void Add(ISymbol symbol)
            {
                if (symbol.IsImplicitlyDeclared || !SyntaxFacts.IsValidIdentifier(symbol.Name) ||
                    symbol.Name.StartsWith("<", StringComparison.Ordinal))
                    return;

                // The editor places engine API source and game source in one
                // Roslyn compilation for fast completion. This makes private
                // fields accessible to our naive GetMembers() fallback, and
                // makes internal engine helpers appear assembly-visible even
                // though they are not part of the public gameplay API.
                // Hide all nonpublic engine API declarations; keep private
                // fields/methods in the user's own game source visible normally.
                if (symbol is not INamespaceSymbol &&
                    symbol.DeclaredAccessibility != Accessibility.Public &&
                    symbol.Locations.Any(location =>
                        location.IsInSource &&
                        location.SourceTree?.FilePath.Replace('\\', '/').Contains(
                            "/Managed/Tallow.API/", StringComparison.OrdinalIgnoreCase) == true))
                    return;

                if (symbol is IMethodSymbol method)
                {
                    // A property/event is already a first-class C# symbol.
                    // Never also suggest its compiler-generated accessor methods
                    // (get_Position, set_Position, add_Changed, ...).
                    if (method.AssociatedSymbol is IPropertySymbol or IEventSymbol ||
                        method.MethodKind is MethodKind.PropertyGet or MethodKind.PropertySet or
                            MethodKind.EventAdd or MethodKind.EventRemove or MethodKind.EventRaise)
                        return;

                    // Some imported native/metadata APIs represent accessors as
                    // ordinary methods. Hide only those whose matching property
                    // or event is actually present; preserve genuine get_* methods.
                    string name = method.Name;
                    int prefix = name.StartsWith("get_", StringComparison.Ordinal) ||
                                 name.StartsWith("set_", StringComparison.Ordinal) ? 4 :
                                 name.StartsWith("add_", StringComparison.Ordinal) ? 4 :
                                 name.StartsWith("remove_", StringComparison.Ordinal) ? 7 : 0;
                    if (prefix != 0 && name.Length > prefix && method.ContainingType is { } container &&
                        container.GetMembers(name[prefix..]).Any(member =>
                            member is IPropertySymbol or IEventSymbol))
                        return;
                }

                names.TryAdd(symbol.Name, symbol.Kind.ToString());
            }

            if (receiverExpression != null)
            {
                SymbolInfo expression = model.GetSymbolInfo(receiverExpression);
                ISymbol? owner = expression.Symbol ?? expression.CandidateSymbols.FirstOrDefault();
                ITypeSymbol? receiver = model.GetTypeInfo(receiverExpression).Type ??
                    (owner as IAliasSymbol)?.Target as ITypeSymbol ?? owner as ITypeSymbol;
                // Nullable<T> conditional access dispatches to the T
                // members; ordinary . on Nullable<T> keeps nullable APIs.
                if (conditional != null && receiver is INamedTypeSymbol nullable &&
                    nullable.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T)
                    receiver = nullable.TypeArguments[0];
                bool staticContext = owner is INamedTypeSymbol ||
                    owner is IAliasSymbol { Target: INamedTypeSymbol };

                if (receiver is INamedTypeSymbol named)
                {
                    // LookupSymbols returns accessible members, including applicable
                    // inherited members and extension methods. Explicitly visit base
                    // types as a fallback for generic and incomplete expressions.
                    foreach (ISymbol symbol in model.LookupSymbols(position, container: named))
                        if (symbol is not IMethodSymbol { MethodKind: MethodKind.Constructor } &&
                            model.IsAccessible(position, symbol) &&
                            (symbol.IsStatic == staticContext ||
                             symbol is IMethodSymbol { IsExtensionMethod: true } && !staticContext))
                            Add(symbol);
                    for (INamedTypeSymbol? parent = named; parent != null; parent = parent.BaseType)
                        foreach (ISymbol symbol in parent.GetMembers())
                            if (symbol is not IMethodSymbol { MethodKind: MethodKind.Constructor } &&
                                model.IsAccessible(position, symbol) &&
                                symbol.IsStatic == staticContext)
                                Add(symbol);
                    foreach (INamedTypeSymbol iface in named.AllInterfaces)
                        foreach (ISymbol symbol in iface.GetMembers())
                            if (!staticContext && model.IsAccessible(position, symbol))
                                Add(symbol);
                }
                else if (receiver != null)
                {
                    foreach (ISymbol symbol in model.LookupSymbols(position, container: receiver))
                        Add(symbol);
                }
                else if (owner is INamespaceSymbol ns)
                {
                    foreach (ISymbol symbol in ns.GetMembers())
                        Add(symbol);
                }
            }
            else
            {
                foreach (ISymbol symbol in model.LookupSymbols(position))
                    Add(symbol);
                foreach (ISymbol symbol in model.LookupNamespacesAndTypes(position))
                    Add(symbol);
                // Compiler-defined contextual keywords are valid suggestions
                // even where they do not have normal ISymbol representations.
                foreach (string keyword in new[] {
                    "async", "await", "base", "bool", "break", "case", "catch", "class",
                    "const", "continue", "decimal", "default", "delegate", "do",
                    "double", "else", "enum", "event", "explicit", "false", "field",
                    "file", "finally", "fixed", "float", "for", "foreach", "get",
                    "global", "goto", "if", "implicit", "in", "init", "int",
                    "interface", "internal", "is", "lock", "long", "namespace",
                    "new", "not", "null", "object", "operator", "out", "override",
                    "params", "partial", "private", "protected", "public", "readonly",
                    "record", "ref", "required", "return", "scoped", "sealed",
                    "set", "short", "sizeof", "static", "string", "struct",
                    "switch", "this", "throw", "true", "try", "typeof", "uint",
                    "ulong", "unsafe", "using", "var", "virtual", "void", "when",
                    "where", "while", "with", "yield", "nameof", "nint", "nuint" })
                    names.TryAdd(keyword, "Keyword");
            }
            foreach ((string name, string kind) in names.OrderBy(pair => pair.Key,
                StringComparer.OrdinalIgnoreCase).Take(1500))
                output.Add(Line("completion", name, kind));

            // The code widget displays the selected call's signature alongside
            // the completion list; unlike its symbol list, overloads are distinct.
            InvocationExpressionSyntax? invocation = node?.AncestorsAndSelf()
                .OfType<InvocationExpressionSyntax>().FirstOrDefault();
            if (invocation != null)
            {
                var callInfo = model.GetSymbolInfo(invocation);
                ISymbol? callable = callInfo.Symbol ?? callInfo.CandidateSymbols.FirstOrDefault() ??
                    model.GetSymbolInfo(invocation.Expression).Symbol;
                if (callable != null)
                    output.Add(Line("signature",
                        callable.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat)));
            }
            return;
        }

        ISymbol? target = SymbolAt(model, root, position);
        if (request.Operation == "signature")
        {
            var node = root.FullSpan.IsEmpty ? null :
                root.FindToken(position > 0 ? position - 1 : position).Parent;
            InvocationExpressionSyntax? call = node?.AncestorsAndSelf()
                .OfType<InvocationExpressionSyntax>().FirstOrDefault();
            var candidate = call == null ? null : model.GetSymbolInfo(call).Symbol ??
                model.GetSymbolInfo(call.Expression).Symbol;
            if (candidate != null)
                output.Add(Line("signature", candidate.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat)));
            return;
        }

        if (target == null)
            return;

        if (request.Operation == "symbol")
        {
            output.Add(Line("info", target.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat)));
            return;
        }

        if (request.Operation == "definition")
        {
            foreach (Location location in target.Locations.Where(l => l.IsInSource))
            {
                var line = location.GetLineSpan();
                output.Add(Line("definition", line.Path, line.StartLinePosition.Line,
                    line.StartLinePosition.Character));
                break;
            }
            return;
        }

        if (request.Operation is "references" or "rename")
        {
            // The editor handles rename as a preview; it never silently changes files.
            References(compilation, target, output);
            return;
        }
        throw new InvalidOperationException($"Unknown semantic operation: {request.Operation}");
    }

    /// <summary>
    /// Consume the native editor's UTF-8 source snapshot request directly.
    /// This replaces the former Python glue and does not write user source.
    /// </summary>
    private static LanguageRequest FromEditor(string project, string engineRoot, string folder)
    {
        string sourceDirectory = Path.GetFullPath(Path.Combine(project, "src"));
        string apiDirectory = Path.GetFullPath(Path.Combine(engineRoot, "Managed", "Tallow.API"));
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        var overlays = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (string line in File.ReadAllLines(Path.Combine(folder, "request.tsv")))
        {
            string[] tokens = line.Split('\t');
            if (tokens.Length == 3 && tokens[0] == "overlay")
                overlays[Path.GetFullPath(tokens[1])] = Path.GetFullPath(tokens[2]);
            else if (tokens.Length == 2)
                fields[tokens[0]] = tokens[1];
            else
                throw new InvalidOperationException("Malformed source-snapshot request.");
        }

        string active = Path.GetFullPath(fields["file"]);
        if (!File.Exists(Path.Combine(apiDirectory, "Tallow.API.csproj")) ||
            !(active.StartsWith(sourceDirectory + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase) && active.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("C# source is outside the trusted game project.");

        var snapshot = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string file in Directory.EnumerateFiles(sourceDirectory, "*.cs", SearchOption.AllDirectories))
            snapshot[Path.GetFullPath(file)] = File.ReadAllText(file);
        foreach (string file in Directory.EnumerateFiles(apiDirectory, "*.cs", SearchOption.AllDirectories))
        {
            // Roslyn must compile the public API source, including our
            // generated native wrappers, but NOT SDK obj/bin assembly-info
            // output. Those files aren't part of the C# project and pollute
            // the editor compilation with duplicate attributes and types.
            string relative = Path.GetRelativePath(apiDirectory, file);
            if (relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                .Any(part => part is "obj" or "bin"))
                continue;
            snapshot[Path.GetFullPath(file)] = File.ReadAllText(file);
        }

        foreach ((string original, string copy) in overlays)
        {
            if (!original.StartsWith(sourceDirectory + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase) || !original.EndsWith(".cs", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("A snapshot references source outside this project.");
            snapshot[original] = File.ReadAllText(copy);
        }

        if (!snapshot.ContainsKey(active))
            throw new InvalidOperationException("The requested C# source is missing.");

        return new LanguageRequest
        {
            Operation = fields["operation"],
            File = active,
            Cursor = int.Parse(fields["cursor"]),
            NewName = fields.GetValueOrDefault("new_name", ""),
            Sources = snapshot.Select(pair => new SourceFile { Path = pair.Key, Text = pair.Value }).ToList()
        };
    }

    /// <summary>
    /// Long-running, trusted editor compiler. Requests are isolated in folders
    /// created by the native editor. Responses use atomic rename, so the editor
    /// never reads a partial result. The service never executes gameplay code.
    /// A single Roslyn process amortizes SDK startup and reference loading.
    /// </summary>
    private static int Serve(string project, string engineRoot, string queue)
    {
        Directory.CreateDirectory(queue);
        File.WriteAllText(Path.Combine(queue, "ready"), "ready");
        DateTime lastActivity = DateTime.UtcNow;
        while (!File.Exists(Path.Combine(queue, "stop")) &&
               DateTime.UtcNow - lastActivity < TimeSpan.FromMinutes(30))
        {
            foreach (string folder in Directory.EnumerateDirectories(queue))
            {
                string requestFile = Path.Combine(folder, "request.tsv");
                string responseFile = Path.Combine(folder, "response.tsv");
                if (!File.Exists(requestFile) || File.Exists(responseFile))
                    continue;

                var response = new List<string>();
                try
                {
                    LanguageRequest request = FromEditor(project, engineRoot, folder);
                    Run(request, response);
                }
                catch (IOException ex) when ((uint)ex.HResult is 0x80070020 or 0x80070021)
                {
                    // A legacy writer may still have request.tsv open on
                    // Windows. Retry when unlocked instead of publishing a
                    // transient sharing violation as a C# compiler error.
                    continue;
                }
                catch (Exception ex)
                {
                    response.Clear();
                    response.Add(Line("error", ex.Message));
                }

                // Atomic publication. The editor is free to delete a completed
                // request folder after consuming its response.
                try
                {
                    string temp = responseFile + ".tmp";
                    File.WriteAllText(temp, string.Join("\n", response) + "\n");
                    File.Move(temp, responseFile, overwrite: true);
                }
                catch (DirectoryNotFoundException)
                {
                    // Closing a code tab can discard an obsolete request.
                }
                lastActivity = DateTime.UtcNow;
            }
            Thread.Sleep(15);
        }
        return 0;
    }

    public static int Main(string[] args)
    {
        var response = new List<string>();
        string output;
        try
        {
            if (args.Length == 6 && args[0] == "--serve" && args[2] == "--project" &&
                args[4] == "--engine-root")
                return Serve(Path.GetFullPath(args[3]), Path.GetFullPath(args[5]),
                    Path.GetFullPath(args[1]));

            if (args.Length == 6 && args[0] == "--project" && args[2] == "--engine-root" &&
                args[4] == "--request")
            {
                output = Path.Combine(args[5], "response.tsv");
                LanguageRequest request = FromEditor(
                    Path.GetFullPath(args[1]), Path.GetFullPath(args[3]), Path.GetFullPath(args[5]));
                Run(request, response);
            }
            else if (args.Length == 2)
            {
                output = args[1];
                LanguageRequest request = JsonSerializer.Deserialize<LanguageRequest>(
                    File.ReadAllText(args[0]), new JsonSerializerOptions
                    { PropertyNameCaseInsensitive = true }) ??
                    throw new InvalidOperationException("Empty language-service request.");
                Run(request, response);
            }
            else
            {
                Console.Error.WriteLine("Usage: Tallow.LanguageService --project <game> --engine-root <engine> --request <folder> (or --serve <queue> --project <game> --engine-root <engine>)");
                return 2;
            }
        }
        catch (Exception exception)
        {
            if (args.Length >= 6 && args[4] == "--request")
                output = Path.Combine(args[5], "response.tsv");
            else if (args.Length == 2)
                output = args[1];
            else
                return 1;
            response.Clear();
            response.Add(Line("error", exception.Message));
        }
        File.WriteAllText(output, string.Join("\n", response) + "\n");
        return response.Count > 0 && response[0].StartsWith("error\t", StringComparison.Ordinal) ? 1 : 0;
    }
}
