using System.Text;
using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Text;

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
    /// <summary>The game's source folder: diagnostics are only reported (and only computed) for files in it, not
    /// for the Tallow.API sources compiled alongside. Empty: every file.</summary>
    public string GameDirectory { get; set; } = "";
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

    private static IEnumerable<MetadataReference> References() => CachedReferences.Value.Concat(PackageReferences());

    // NuGet packages the game's assembly definitions use: listed by Tallow.Build after each build in
    // .tallow-csharp/package-references.tsv. Reread when that file changes.
    private static string sPackageList = "";
    private static DateTime sPackageListTime;
    private static MetadataReference[] sPackageReferences = [];

    internal static void UsePackageList(string project) =>
        sPackageList = Path.Combine(project, ".tallow-csharp", "package-references.tsv");

    private static MetadataReference[] PackageReferences()
    {
        if (sPackageList.Length == 0 || !File.Exists(sPackageList))
            return sPackageReferences = [];
        DateTime time = File.GetLastWriteTimeUtc(sPackageList);
        if (time == sPackageListTime)
            return sPackageReferences;
        sPackageListTime = time;
        sPackageReferences = File.ReadAllLines(sPackageList)
            .Where(line => line.Length > 0 && File.Exists(line))
            .Select(path => (MetadataReference)MetadataReference.CreateFromFile(path)).ToArray();
        return sPackageReferences;
    }

    // A stable tree for implicit imports: don't invalidate Roslyn on each query.
    private static readonly CSharpParseOptions CSharp15 = new(LanguageVersion.CSharp15);
    private static readonly SyntaxTree GlobalUsings = CSharpSyntaxTree.ParseText("""
        global using System;
        global using System.Collections.Generic;
        global using System.IO;
        global using System.Linq;
        global using System.Net.Http;
        global using System.Threading;
        global using System.Threading.Tasks;
        global using System.Numerics;
        """, CSharp15, path: "Tallow.GameImplicitUsings.g.cs");

    // Immutable Roslyn compilation reused within the single-threaded worker.
    // Replacing only changed trees retains semantic state for unchanged files.
    private static CSharpCompilation? CachedCompilation;

    private static CSharpCompilation CompilationFor(IReadOnlyList<SyntaxTree> currentTrees)
    {
        if (CachedCompilation is null)
        {
            CachedCompilation = CSharpCompilation.Create("Tallow.SemanticWorkspace",
                currentTrees, References(),
                // Engine API wrappers use unsafe pointers, but generated game
                // projects continue forbidding unsafe gameplay code.
                new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary,
                    allowUnsafe: true,
                    nullableContextOptions: NullableContextOptions.Enable));
            return CachedCompilation;
        }

        CSharpCompilation compilation = CachedCompilation;
        var previous = compilation.SyntaxTrees.ToDictionary(
            tree => tree.FilePath, tree => tree, StringComparer.OrdinalIgnoreCase);
        var current = currentTrees.ToDictionary(
            tree => tree.FilePath, tree => tree, StringComparer.OrdinalIgnoreCase);

        foreach (SyntaxTree oldTree in previous.Values)
            if (!current.ContainsKey(oldTree.FilePath))
            {
                compilation = compilation.RemoveSyntaxTrees(oldTree);
                DeclarationEpoch++;
            }
        foreach (SyntaxTree newTree in currentTrees)
        {
            if (!previous.TryGetValue(newTree.FilePath, out SyntaxTree? oldTree))
            {
                compilation = compilation.AddSyntaxTrees(newTree);
                DeclarationEpoch++;
            }
            else if (!ReferenceEquals(oldTree, newTree))
            {
                compilation = compilation.ReplaceSyntaxTree(oldTree, newTree);
                if (!BodyOnlyEdit(oldTree, newTree))
                    DeclarationEpoch++;
            }
        }
        CachedCompilation = compilation;
        return compilation;
    }

    /// <summary>
    /// Bumped by any change another file could see (a file added or removed, a declaration, a constant, a field
    /// initializer); per-file diagnostics from an older epoch are worked out again.
    /// </summary>
    private static int DeclarationEpoch;

    /// <summary>
    /// Whether everything that differs between two versions of a file lies inside one method, accessor, constructor,
    /// operator or local function body in both: then nothing outside the file can bind differently.
    /// </summary>
    internal static bool BodyOnlyEdit(SyntaxTree before, SyntaxTree after)
    {
        string a = before.GetText().ToString(), b = after.GetText().ToString();
        int prefix = 0, limit = Math.Min(a.Length, b.Length);
        while (prefix < limit && a[prefix] == b[prefix])
            prefix++;
        int suffix = 0;
        while (suffix < limit - prefix && a[a.Length - 1 - suffix] == b[b.Length - 1 - suffix])
            suffix++;
        return InsideBody(before, prefix, a.Length - suffix) && InsideBody(after, prefix, b.Length - suffix);
    }

    /// <summary>Whether [start, end) is strictly inside the braces (or after the =>) of a member body.</summary>
    private static bool InsideBody(SyntaxTree tree, int start, int end)
    {
        SyntaxNode root = tree.GetRoot();
        SyntaxNode? node = root.FindToken(Math.Min(start, Math.Max(0, root.FullSpan.End - 1))).Parent;
        for (; node != null; node = node.Parent)
        {
            bool body = node.Parent is BaseMethodDeclarationSyntax or AccessorDeclarationSyntax or LocalFunctionStatementSyntax
                && node is BlockSyntax or ArrowExpressionClauseSyntax;
            if (!body)
                continue;
            // Inside a block's braces, or after an arrow's =>, and before its end.
            int inner = node is BlockSyntax block ? block.OpenBraceToken.Span.End : ((ArrowExpressionClauseSyntax)node).ArrowToken.Span.End;
            int innerEnd = node is BlockSyntax closing ? closing.CloseBraceToken.SpanStart : node.Span.End;
            if (start >= inner && end <= innerEnd)
                return true;
        }
        return false;
    }

    // The editor holds one Roslyn process for many requests. Reuse immutable
    // parsed trees for sources that did not change instead of lexing the full
    // game + public API on every keystroke. A changed overlay replaces its
    // tree immediately; closed/deleted files are evicted below.
    private sealed record CachedSyntax(string Text, SyntaxTree Tree);
    // The type names each parsed tree declares (trees are reused while their text is unchanged).
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<SyntaxTree, string[]> DeclaredTypeNames = new();
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

    /// <summary>Each game file's diagnostic lines, kept while its tree and the declaration epoch are unchanged.</summary>
    private static readonly Dictionary<string, (SyntaxTree Tree, int Epoch, List<string> Lines)> FileDiagnostics =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The semantic model the last file checked was bound in (reused for its tokens).</summary>
    private static SemanticModel? LastModel;

    /// <summary>How many files the last diagnostics request worked out again (the rest came from the cache).</summary>
    internal static int LastDiagnosed;

    /// <summary>
    /// The game files' problems and gameplay warnings. Per file, and only for files whose text changed since they
    /// were last checked (or all, after a change another file could see), so an edit inside a method body checks
    /// one file however large the project.
    /// </summary>
    private static void Diagnostics(CSharpCompilation compilation,
        Dictionary<string, SourceFile> sourceByPath, List<string> output)
    {
        LastDiagnosed = 0;
        foreach (SyntaxTree tree in compilation.SyntaxTrees)
        {
            if (!sourceByPath.TryGetValue(tree.FilePath, out SourceFile? source))
                continue;
            if (!FileDiagnostics.TryGetValue(tree.FilePath, out var cached) || !ReferenceEquals(cached.Tree, tree) ||
                cached.Epoch != DeclarationEpoch)
            {
                var lines = new List<string>();
                var one = new Dictionary<string, SourceFile>(StringComparer.OrdinalIgnoreCase) { [tree.FilePath] = source };
                SemanticModel fileModel = compilation.GetSemanticModel(tree);
                LastModel = fileModel;
                FileProblems(fileModel.GetDiagnostics(), one, lines);
                foreach (GameplayDiagnostics.Warning warning in GameplayDiagnostics.Analyze(compilation, one))
                    lines.Add(Line("diagnostic", warning.Path, warning.Line,
                        warning.Utf8Column, "warning", warning.Message, warning.Category));
                cached = (tree, DeclarationEpoch, lines);
                FileDiagnostics[tree.FilePath] = cached;
                LastDiagnosed++;
            }
            output.AddRange(cached.Lines);
        }
        foreach (string gone in FileDiagnostics.Keys.Where(path => !ParsedSources.ContainsKey(path)).ToArray())
            FileDiagnostics.Remove(gone);
    }

    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<SyntaxTree, Tuple<int, List<string>>>
        TokenCache = new();

    /// <summary>A name's colour within a member: its line from the member's first line, its column, kind and text.</summary>
    private readonly record struct MemberToken(int Line, int Column, string Kind, string Name);

    /// <summary>Per file: the declaration epoch and each member's tokens by the member's text (and start column).</summary>
    private static readonly Dictionary<string, (int Epoch, Dictionary<string, MemberToken[]> Members)> MemberTokens =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A member that holds no other members (a method, property, field, enum member...).</summary>
    private static bool LeafMember(SyntaxNode node) =>
        node is MemberDeclarationSyntax and not BaseTypeDeclarationSyntax and not BaseNamespaceDeclarationSyntax;

    /// <summary>
    /// "token\tline\tcolumn\tkind\tname" for each name in a file that the compiler knows, column in code points (the
    /// code editor's glyphs): kind includes types, methods, locals, parameters, and instance or static members. Members whose
    /// text is unchanged keep their tokens (moved to where the member now starts), so typing in one method classifies
    /// that method only; a change other files could see classifies everything again.
    /// </summary>
    internal static List<string> SemanticTokens(CSharpCompilation compilation, SyntaxTree tree)
    {
        if (TokenCache.TryGetValue(tree, out var cached) && cached.Item1 == DeclarationEpoch)
            return cached.Item2;
        SemanticModel? model = null;
        SemanticModel Model() => model ??= LastModel is { } last && last.SyntaxTree == tree && last.Compilation == compilation
            ? last : compilation.GetSemanticModel(tree);
        SourceText text = tree.GetText();
        if (!MemberTokens.TryGetValue(tree.FilePath, out var file) || file.Epoch != DeclarationEpoch)
            file = (DeclarationEpoch, new Dictionary<string, MemberToken[]>(StringComparer.Ordinal));
        var members = new Dictionary<string, MemberToken[]>(StringComparer.Ordinal);
        var lines = new List<string>();
        SyntaxNode root = tree.GetRoot();

        (int Line, int Column) Where(int position)
        {
            var at = text.Lines.GetLinePosition(position);
            TextLine line = text.Lines[at.Line];
            // Code points before the position on its line (a surrogate pair is one glyph).
            int column = 0;
            for (int i = line.Start; i < position; i++)
                if (!char.IsLowSurrogate(text[i]))
                    column++;
            return (at.Line, column);
        }

        foreach (SyntaxNode member in root.DescendantNodes(node => !LeafMember(node)).Where(LeafMember))
        {
            var start = Where(member.FullSpan.Start);
            string key = start.Column + "\n" + member.ToFullString();
            if (!file.Members.TryGetValue(key, out MemberToken[]? tokens) && !members.TryGetValue(key, out tokens))
            {
                var found = new List<MemberToken>();
                foreach (SyntaxToken token in member.DescendantTokens())
                    if (Classify(Model(), token) is { } kind)
                    {
                        var at = Where(token.SpanStart);
                        found.Add(new MemberToken(at.Line - start.Line, at.Column, kind, token.ValueText));
                    }
                tokens = found.ToArray();
            }
            members[key] = tokens;
            foreach (MemberToken token in tokens)
                lines.Add(Line("token", start.Line + token.Line, token.Column, token.Kind, token.Name));
        }
        // Names outside members: usings, namespaces, type headers, base lists, type attributes.
        foreach (SyntaxToken token in root.DescendantTokens(node => !LeafMember(node)))
            if (token.Parent is { } parent && !LeafMember(parent) && !parent.Ancestors().Any(LeafMember) &&
                Classify(Model(), token) is { } kind)
            {
                var at = Where(token.SpanStart);
                lines.Add(Line("token", at.Line, at.Column, kind, token.ValueText));
            }
        MemberTokens[tree.FilePath] = (DeclarationEpoch, members);
        TokenCache.AddOrUpdate(tree, Tuple.Create(DeclarationEpoch, lines));
        return lines;
    }

    /// <summary>What a name is, for colouring: null for keywords, punctuation and names the compiler cannot place.</summary>
    private static string? Classify(SemanticModel model, SyntaxToken token)
    {
        if (!token.IsKind(SyntaxKind.IdentifierToken) || token.Parent is not { } parent)
            return null;
        // var is a keyword to the reader, though it names a type.
        if (parent is IdentifierNameSyntax { IsVar: true })
            return null;
        ISymbol? symbol;
        if (parent is SimpleNameSyntax)
        {
            SymbolInfo info = model.GetSymbolInfo(parent);
            symbol = info.Symbol ?? info.CandidateSymbols.FirstOrDefault();
        }
        else
            symbol = model.GetDeclaredSymbol(parent);
        if (symbol is IAliasSymbol alias)
            symbol = alias.Target;
        return symbol switch
        {
            ITypeParameterSymbol => "typeparam",
            ITypeSymbol => "type",
            IMethodSymbol { MethodKind: MethodKind.Constructor or MethodKind.StaticConstructor or MethodKind.Destructor } => "type",
            IMethodSymbol => "method",
            IFieldSymbol { IsConst: true } or IFieldSymbol { ContainingType.TypeKind: TypeKind.Enum } => "constant",
            // Static fields, properties and events use their own colours, including at references.
            IFieldSymbol or IPropertySymbol or IEventSymbol when symbol.IsStatic =>
                symbol.DeclaredAccessibility == Accessibility.Public ? "staticmember" : "privatestaticmember",
            // Public instance members in one colour, the rest (private, protected, internal) another.
            IFieldSymbol or IPropertySymbol or IEventSymbol =>
                symbol.DeclaredAccessibility == Accessibility.Public ? "member" : "privatemember",
            ILocalSymbol { IsConst: true } => "constant",
            IParameterSymbol => "parameter",
            ILocalSymbol or IRangeVariableSymbol => "variable",
            INamespaceSymbol => "namespace",
            _ => null,
        };
    }

    private static void FileProblems(IEnumerable<Diagnostic> problems,
        Dictionary<string, SourceFile> sourceByPath, List<string> output)
    {
        foreach (Diagnostic problem in problems)
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
        ISymbol symbol, List<string> output, SyntaxTree? onlyTree = null)
    {
        foreach (SyntaxTree tree in compilation.SyntaxTrees)
        {
            if (onlyTree is not null && tree != onlyTree)
                continue;
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

    /// <summary>
    /// After "override " in a class body: the base classes' overridable methods and properties this class has not
    /// overridden yet. Each item shows "Name(parameters)" and inserts the whole member (return type, signature and
    /// a body with the cursor inside), in the editor's "display\x1Finsert" form (\x1C a tab, \x1D a line break, \x1E
    /// the cursor).
    /// </summary>
    private static bool OverrideCompletions(SemanticModel model, string text, int position, List<string> output)
    {
        int wordStart = position;
        while (wordStart > 0 && (char.IsLetterOrDigit(text[wordStart - 1]) || text[wordStart - 1] == '_'))
            wordStart--;
        int lineStart = text.LastIndexOf('\n', Math.Max(wordStart - 1, 0)) + 1;
        string before = text[lineStart..wordStart];
        if (!System.Text.RegularExpressions.Regex.IsMatch(before,
                @"^\s*(?:(?:public|protected|internal|private|sealed|async|unsafe|new|extern)\s+)*override\s+$"))
            return false;
        INamedTypeSymbol? type = model.GetEnclosingSymbol(Math.Max(lineStart - 1, 0)) switch
        {
            INamedTypeSymbol named => named,
            ISymbol other => other.ContainingType,
            null => null
        };
        if (type is null || type.TypeKind is not (TypeKind.Class or TypeKind.Struct))
            return true;

        string indent = before[..(before.Length - before.TrimStart().Length)];
        string inner = indent + (indent.Contains('\t') ? "\t" : "    ");
        var done = new HashSet<ISymbol>(SymbolEqualityComparer.Default);
        foreach (ISymbol member in type.GetMembers())
        {
            if (member is IMethodSymbol { IsOverride: true, OverriddenMethod: { } overridden })
                done.Add(overridden.OriginalDefinition);
            else if (member is IPropertySymbol { IsOverride: true, OverriddenProperty: { } property })
                done.Add(property.OriginalDefinition);
        }
        var format = SymbolDisplayFormat.MinimallyQualifiedFormat;
        var items = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (INamedTypeSymbol? parent = type.BaseType; parent != null; parent = parent.BaseType)
        {
            foreach (ISymbol member in parent.GetMembers())
            {
                if (!(member.IsVirtual || member.IsAbstract || member.IsOverride) || member.IsSealed || member.IsStatic ||
                    member.DeclaredAccessibility is not (Accessibility.Public or Accessibility.Protected or
                        Accessibility.ProtectedOrInternal) ||
                    !done.Add(member.OriginalDefinition))
                    continue;
                // An override of an override hides the one further down.
                if (member is IMethodSymbol { OverriddenMethod: { } deeper })
                    done.Add(deeper.OriginalDefinition);
                if (member is IPropertySymbol { OverriddenProperty: { } deeperProperty })
                    done.Add(deeperProperty.OriginalDefinition);
                if (member is IMethodSymbol { MethodKind: MethodKind.Ordinary } method)
                {
                    string parameters = string.Join(", ", method.Parameters.Select(p =>
                        (p.RefKind switch { RefKind.Ref => "ref ", RefKind.Out => "out ", RefKind.In => "in ", _ => "" }) +
                        p.Type.ToDisplayString(format) + " " + p.Name));
                    string display = $"{method.Name}({parameters})";
                    string returns = method.ReturnsVoid ? "void" : method.ReturnType.ToDisplayString(format);
                    string body = method.IsAbstract || method.ReturnsVoid ? "\x1E" :
                        $"return base.{method.Name}({string.Join(", ", method.Parameters.Select(p =>
                            (p.RefKind switch { RefKind.Ref => "ref ", RefKind.Out => "out ", RefKind.In => "in ", _ => "" }) + p.Name))});\x1E";
                    // The modifiers typed before ("public override") stay as written.
                    items.TryAdd(display, $"{returns} {display}\x1D{indent}{{\x1D{inner}{body}\x1D{indent}}}");
                }
                else if (member is IPropertySymbol property && !property.IsIndexer)
                {
                    string display = property.Name;
                    string accessors = (property.GetMethod != null ? $"get => base.{property.Name};" : "") +
                        (property.SetMethod != null ? (property.GetMethod != null ? " " : "") + $"set => base.{property.Name} = value;" : "");
                    if (property.IsAbstract)
                        accessors = (property.GetMethod != null ? "get => \x1Edefault!;" : "") +
                            (property.SetMethod != null ? " set { }" : "");
                    items.TryAdd(display, $"{property.Type.ToDisplayString(format)} {property.Name} {{ {accessors} }}");
                }
            }
        }
        // Tabs and line breaks cannot cross the line-based result: \x1C and \x1D stand for them.
        foreach ((string display, string insert) in items)
            output.Add(Line("completion", display + "\x1F" + insert.Replace('\t', '\x1C'), "Override"));
        return true;
    }

    /// <summary>
    /// Signature help for the call the caret is inside (its argument list): one "signature" line per overload, the
    /// best fit first, with the parameter the caret is on wrapped in \x01 ... \x02 for the editor to highlight.
    /// </summary>
    internal static void SignatureHelp(SemanticModel model, SyntaxNode root, int position, List<string> output)
    {
        if (root.FullSpan.IsEmpty)
            return;
        SyntaxNode? node = root.FindToken(position > 0 ? position - 1 : position).Parent;
        // The innermost argument list holding the caret (after its "(", before its ")").
        ArgumentListSyntax? arguments = node?.AncestorsAndSelf().OfType<ArgumentListSyntax>().FirstOrDefault(list =>
            position > list.OpenParenToken.SpanStart &&
            (list.CloseParenToken.IsMissing || position <= list.CloseParenToken.SpanStart));
        if (arguments?.Parent is not ExpressionSyntax call)
            return;
        int active = arguments.Arguments.GetSeparators().Count(separator => separator.SpanStart < position);
        // The named argument the caret is in ("speed: 1") picks its parameter by name.
        string? named = arguments.Arguments.FirstOrDefault(argument => argument.Span.Contains(position) ||
            argument.Span.End == position)?.NameColon?.Name.Identifier.ValueText;

        var overloads = new List<IMethodSymbol>();
        ISymbol? best = model.GetSymbolInfo(call).Symbol;
        switch (call)
        {
            case InvocationExpressionSyntax invocation:
                overloads.AddRange(model.GetMemberGroup(invocation.Expression).OfType<IMethodSymbol>());
                break;
            case BaseObjectCreationExpressionSyntax creation:
                if (model.GetTypeInfo(creation).Type is INamedTypeSymbol created)
                    overloads.AddRange(created.InstanceConstructors.Where(constructor =>
                        model.IsAccessible(position, constructor)));
                break;
        }
        if (overloads.Count == 0 && best is IMethodSymbol only)
            overloads.Add(only);
        if (overloads.Count == 0)
            return;
        // The resolved overload first; otherwise the first with room for the argument the caret is on.
        IMethodSymbol first = best as IMethodSymbol ?? overloads.FirstOrDefault(method =>
            method.Parameters.Length > active || method.Parameters.LastOrDefault()?.IsParams == true) ?? overloads[0];
        foreach (IMethodSymbol method in overloads.OrderBy(method => SymbolEqualityComparer.Default.Equals(
                     method.OriginalDefinition, first.OriginalDefinition) ? 0 : 1).ThenBy(method => method.Parameters.Length).Take(20))
        {
            var text = new StringBuilder();
            if (method.MethodKind == MethodKind.Constructor)
                text.Append("new ").Append(method.ContainingType.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat));
            else
                text.Append(method.ReturnType.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat))
                    .Append(' ').Append(method.Name);
            text.Append('(');
            int highlight = named != null
                ? method.Parameters.IndexOf(method.Parameters.FirstOrDefault(parameter => parameter.Name == named)!)
                : Math.Min(active, method.Parameters.Length - 1);
            if (named == null && active >= method.Parameters.Length && method.Parameters.LastOrDefault()?.IsParams != true)
                highlight = -1;
            for (int i = 0; i < method.Parameters.Length; i++)
            {
                IParameterSymbol parameter = method.Parameters[i];
                if (i > 0)
                    text.Append(", ");
                if (i == highlight)
                    text.Append('\x01');
                text.Append(parameter.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat));
                if (i == highlight)
                    text.Append('\x02');
            }
            text.Append(')');
            output.Add(Line("signature", text.ToString()));
        }
    }

    private static void Run(LanguageRequest request, List<string> output)
    {
        var sourceByPath = new Dictionary<string, SourceFile>(StringComparer.OrdinalIgnoreCase);
        foreach (SourceFile source in request.Sources)
            sourceByPath[Path.GetFullPath(source.Path)] = source;
        if (!sourceByPath.TryGetValue(Path.GetFullPath(request.File), out SourceFile? active))
            throw new InvalidOperationException("Requested source is outside the C# project.");

        List<SyntaxTree> trees = ParseSnapshots(sourceByPath, CSharp15);
        trees.Add(GlobalUsings);
        CSharpCompilation compilation = CompilationFor(trees);
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
            declaredTypes.UnionWith(DeclaredTypeNames.GetValue(tree, static tree => tree.GetRoot().DescendantNodes()
                .Select(node => node switch
                {
                    BaseTypeDeclarationSyntax type => type.Identifier.ValueText,
                    DelegateDeclarationSyntax type => type.Identifier.ValueText,
                    _ => null
                }).OfType<string>().ToArray()));
        foreach (string name in declaredTypes)
            output.Add(Line("type", name));

        if (request.Operation == "diagnostics")
        {
            // Problems are reported for the game's files only (when the request says where they are).
            var reported = request.GameDirectory.Length == 0 ? sourceByPath : sourceByPath
                .Where(pair => pair.Key.StartsWith(Path.GetFullPath(request.GameDirectory) + Path.DirectorySeparatorChar,
                    StringComparison.OrdinalIgnoreCase))
                .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
            sourceByPath = reported;
            // Compiler problems, then Tallow's cyan performance / purple network warnings (their category column is
            // optional; older consumers still understand the first six fields).
            Diagnostics(compilation, sourceByPath, output);
            output.Add(Line("checked", LastDiagnosed));
            // The open file's names coloured by what they are, for the code editor.
            output.AddRange(SemanticTokens(compilation, selected));
            return;
        }

        if (request.Operation == "completion")
        {
            if (OverrideCompletions(model, active.Text, position, output))
                return;
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

            // Some requests arrive at EOF while the user is typing an
            // incomplete member access (this.se). Roslyn's accessibility
            // checks need a position *inside* the active syntax tree; the
            // caret at FullSpan.End is outside the source and can incorrectly
            // reject the user's own private members.
            int accessPosition = Math.Clamp(position > 0 ? position - 1 : 0,
                0, Math.Max(0, root.FullSpan.End - 1));
            INamedTypeSymbol? enclosingType = model.GetEnclosingSymbol(accessPosition)
                ?.ContainingType;
            // The SDK compiler knows project types, members (including inherited
            // ones), and all referenced framework assemblies. Do not maintain a
            // second hand-written API list for C# completion.
            var names = new Dictionary<string, string>(StringComparer.Ordinal);

            // Inside [ ... ] (but not an attribute's argument list) C# only
            // accepts attribute classes, written without the "Attribute"
            // suffix: suggest HideInInspector, not HideInInspectorAttribute.
            SyntaxToken caretToken = root.FullSpan.IsEmpty ? default :
                root.FindToken(position > 0 ? position - 1 : position);
            bool attributeContext =
                (caretToken.Parent is AttributeListSyntax &&
                    (caretToken.IsKind(SyntaxKind.OpenBracketToken) ||
                     caretToken.IsKind(SyntaxKind.CommaToken))) ||
                (node?.AncestorsAndSelf().OfType<AttributeSyntax>().Any() == true &&
                 node?.AncestorsAndSelf().OfType<AttributeArgumentListSyntax>().Any() != true);
            INamedTypeSymbol? attributeBase = attributeContext ?
                compilation.GetTypeByMetadataName("System.Attribute") : null;

            void Add(ISymbol symbol)
            {
                if (symbol.IsImplicitlyDeclared || !SyntaxFacts.IsValidIdentifier(symbol.Name) ||
                    symbol.Name.StartsWith("<", StringComparison.Ordinal))
                    return;

                if (attributeContext)
                {
                    if (symbol is INamespaceSymbol)
                    {
                        names.TryAdd(symbol.Name, symbol.Kind.ToString());
                        return;
                    }
                    if (symbol is not INamedTypeSymbol { IsAbstract: false } candidate ||
                        attributeBase is null)
                        return;
                    bool isAttribute = false;
                    for (INamedTypeSymbol? parent = candidate.BaseType; parent != null;
                         parent = parent.BaseType)
                        if (SymbolEqualityComparer.Default.Equals(parent, attributeBase))
                        {
                            isAttribute = true;
                            break;
                        }
                    if (!isAttribute || !model.IsAccessible(accessPosition, symbol))
                        return;
                    const string suffix = "Attribute";
                    string shortName = symbol.Name.Length > suffix.Length &&
                        symbol.Name.EndsWith(suffix, StringComparison.Ordinal) ?
                        symbol.Name[..^suffix.Length] : symbol.Name;
                    names.TryAdd(shortName, symbol.Kind.ToString());
                    return;
                }

                // LookupSymbols checks C# access modifiers, but the inherited
                // member fallback below walks GetMembers() directly. Enforce
                // accessibility here too so another class's private members
                // and a base class's private fields/methods never leak into
                // completion. This preserves private user members when the
                // current code is actually allowed to access them.
                bool ownPrivate = symbol.DeclaredAccessibility == Accessibility.Private &&
                    enclosingType is not null &&
                    SymbolEqualityComparer.Default.Equals(symbol.ContainingType, enclosingType);
                if (symbol is not INamespaceSymbol &&
                    !ownPrivate && !model.IsAccessible(accessPosition, symbol))
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
                            (symbol.IsStatic == staticContext ||
                             symbol is IMethodSymbol { IsExtensionMethod: true } && !staticContext))
                            Add(symbol);
                    for (INamedTypeSymbol? parent = named; parent != null; parent = parent.BaseType)
                        foreach (ISymbol symbol in parent.GetMembers())
                            if (symbol is not IMethodSymbol { MethodKind: MethodKind.Constructor } &&
                                    symbol.IsStatic == staticContext)
                                Add(symbol);
                    foreach (INamedTypeSymbol iface in named.AllInterfaces)
                        foreach (ISymbol symbol in iface.GetMembers())
                            if (!staticContext)
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
                    if (!attributeContext)
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

        if (request.Operation == "highlight")
        {
            if (root.FullSpan.IsEmpty)
                return;
            SyntaxToken selectedToken = root.FindToken(Math.Max(0, position - 1));
            if (!selectedToken.IsKind(SyntaxKind.IdentifierToken) || selectedToken.Span.End != position ||
                selectedToken.Parent is IdentifierNameSyntax { IsVar: true })
                return;
        }
        ISymbol? target = SymbolAt(model, root, position);
        if (request.Operation == "signature")
        {
            SignatureHelp(model, root, position, output);
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

        if (request.Operation is "references" or "rename" or "highlight")
        {
            // The editor handles rename as a preview; it never silently changes files.
            References(compilation, target, output, request.Operation == "highlight" ? selected : null);
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
        UsePackageList(project);
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
        bool gameSource = active.StartsWith(sourceDirectory + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase) && active.EndsWith(".cs", StringComparison.OrdinalIgnoreCase);
        bool apiSource = active.StartsWith(apiDirectory + Path.DirectorySeparatorChar,
            StringComparison.OrdinalIgnoreCase) && active.EndsWith(".cs", StringComparison.OrdinalIgnoreCase) &&
            !Path.GetRelativePath(apiDirectory, active).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                .Any(part => part is "obj" or "bin");
        bool readOnlyApiRequest = apiSource && fields["operation"] is ("definition" or "symbol" or "highlight");
        if (!File.Exists(Path.Combine(apiDirectory, "Tallow.API.csproj")) || !(gameSource || readOnlyApiRequest))
            throw new InvalidOperationException("C# source is outside the trusted game project or read-only engine API.");

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
            GameDirectory = sourceDirectory,
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
