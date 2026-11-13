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

    private static IEnumerable<MetadataReference> References()
    {
        string assemblies = (string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES") ?? "";
        foreach (string path in assemblies.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            if (File.Exists(path))
                yield return MetadataReference.CreateFromFile(path);
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
        var trees = sourceByPath.Select(pair =>
            CSharpSyntaxTree.ParseText(pair.Value.Text, parse, path: pair.Key)).ToList();
        var compilation = CSharpCompilation.Create("Tallow.SemanticWorkspace", trees,
            References(), new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary,
                nullableContextOptions: NullableContextOptions.Enable));
        SyntaxTree selected = trees.First(tree =>
            string.Equals(tree.FilePath, Path.GetFullPath(request.File), StringComparison.OrdinalIgnoreCase));
        SemanticModel model = compilation.GetSemanticModel(selected);
        SyntaxNode root = selected.GetRoot();
        int position = ToUtf16(active.Text, request.Cursor);
        position = Math.Clamp(position, 0, active.Text.Length);

        if (request.Operation == "diagnostics")
        {
            Diagnostics(compilation, sourceByPath, output);
            return;
        }

        if (request.Operation == "completion")
        {
            var symbols = model.LookupSymbols(position);
            SyntaxNode? node = root.FullSpan.IsEmpty ? null :
                root.FindToken(position > 0 ? position - 1 : position).Parent;
            MemberAccessExpressionSyntax? member = node?.AncestorsAndSelf()
                .OfType<MemberAccessExpressionSyntax>().FirstOrDefault();
            if (member != null)
            {
                ITypeSymbol? type = model.GetTypeInfo(member.Expression).Type;
                if (type != null)
                    symbols = model.LookupSymbols(position, container: type);
            }
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (ISymbol symbol in symbols.OrderBy(s => s.Name).Take(2000))
            {
                if (!string.IsNullOrEmpty(symbol.Name) && seen.Add(symbol.Name))
                    output.Add(Line("completion", symbol.Name, symbol.Kind));
                if (seen.Count >= 300)
                    break;
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

    public static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("Usage: Tallow.LanguageService <request.json> <response.tsv>");
            return 2;
        }
        var response = new List<string>();
        try
        {
            LanguageRequest request = JsonSerializer.Deserialize<LanguageRequest>(
                File.ReadAllText(args[0]), new JsonSerializerOptions
                { PropertyNameCaseInsensitive = true }) ??
                throw new InvalidOperationException("Empty language-service request.");
            Run(request, response);
        }
        catch (Exception exception)
        {
            response.Clear();
            response.Add(Line("error", exception.Message));
        }
        File.WriteAllText(args[1], string.Join("\n", response) + "\n");
        return response.Count > 0 && response[0].StartsWith("error\t", StringComparison.Ordinal) ? 1 : 0;
    }
}
