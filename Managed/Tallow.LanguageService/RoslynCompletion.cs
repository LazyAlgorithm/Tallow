#if ROSLYN_FEATURES
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.Completion;
using Microsoft.CodeAnalysis.Tags;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.Host.Mef;
using Microsoft.CodeAnalysis.Text;

namespace Tallow.LanguageService;

/// <summary>
/// Completion from Roslyn's own CompletionService (the Features assemblies of the same SDK): every symbol in scope
/// and on the receiver in context, extension methods, keywords valid at the caret, types from namespaces not yet
/// imported (accepting one adds its using), named arguments, object initializer members, enum members where an enum is
/// expected, overrides and partial methods. Tallow.API is its own project referenced by the game, so the compiler
/// hides the engine's internal members as it does in a real build.
///
/// Each item is one "completion" line: display \x1F insert \x1F detail \x1F edits \x1F description, where insert
/// replaces the word being typed (\x1E marks where the caret goes), detail is a short note drawn beside it (the
/// namespace a type comes from, or its kind), edits are other changes the item makes (a using directive, "async"
/// on the method) as "byte offset \x1B length \x1B text" joined by \x1A, and description is the signature and
/// summary for the selected item. Line breaks and tabs inside a field are \x1D and \x1C.
/// </summary>
internal static class RoslynCompletion
{
    private const int MaxItems = 300;
    // Descriptions made here from the semantic model are cheap; Roslyn's own description service (~4 ms an item)
    // is only asked for the first few items the model does not resolve (types from other namespaces, keywords).
    private const int MaxDescriptions = 80;
    private const int MaxServiceDescriptions = 4;

    private static AdhocWorkspace? sWorkspace;
    private static string sLayout = "";
    private static readonly Dictionary<string, ProjectId> sProjects = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, (DocumentId Id, SourceText Text)> sDocuments = new(StringComparer.OrdinalIgnoreCase);
    private static MetadataReference[] sReferences = [];

    /// <summary>Roslyn's services, from the types of its assemblies that load. The SDK's copy of Roslyn's Features
    /// (dotnet-format's) differs between SDK builds in what else it needs; a type that needs an assembly that is
    /// not here (one we do not use, such as a package search index) is left out instead of failing the whole
    /// container, as <c>MefHostServices.Create(assemblies)</c> would.</summary>
    private static System.Composition.CompositionContext Composition()
    {
        var types = new List<Type>();
        foreach (var assembly in MefHostServices.DefaultAssemblies)
        {
            try
            {
                types.AddRange(assembly.GetTypes());
            }
            catch (System.Reflection.ReflectionTypeLoadException partial)
            {
                types.AddRange(partial.Types.Where(type => type != null)!);
            }
        }
        return new System.Composition.Hosting.ContainerConfiguration().WithParts(types).CreateContainer();
    }

    private static Document Sync(IReadOnlyList<SyntaxTree> trees, SyntaxTree active, MetadataReference[] references,
        CSharpParseOptions parse, AssemblyLayout layout)
    {
        if (sWorkspace != null && sLayout != layout.Key)
        {
            sWorkspace = null;
            sDocuments.Clear();
        }
        if (sWorkspace == null)
        {
            // One project per assembly, as the game builds: Tallow.API, each .tasmdef, Tallow.Game.
            sWorkspace = new AdhocWorkspace(MefHostServices.Create(Composition()));
            sLayout = layout.Key;
            sProjects.Clear();
            var options = new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary, allowUnsafe: true,
                nullableContextOptions: NullableContextOptions.Enable);
            Solution created = sWorkspace.CurrentSolution;
            foreach (string name in layout.GameAssemblies.Prepend(AssemblyLayout.Api))
            {
                ProjectId id = ProjectId.CreateNewId(name);
                sProjects[name] = id;
                var projectReferences = name == AssemblyLayout.Api ? [] :
                    layout.ReferencesOf(name).Prepend(AssemblyLayout.Api).Select(reference => new ProjectReference(sProjects[reference]));
                created = created.AddProject(ProjectInfo.Create(id, VersionStamp.Create(), name, name, LanguageNames.CSharp,
                    compilationOptions: options.WithAllowUnsafe(name == AssemblyLayout.Api), parseOptions: parse,
                    metadataReferences: references, projectReferences: projectReferences));
            }
            sWorkspace.TryApplyChanges(created);
            sReferences = references;
        }
        Solution solution = sWorkspace.CurrentSolution;
        if (!ReferenceEquals(sReferences, references) && !sReferences.SequenceEqual(references))
        {
            foreach (ProjectId project in sProjects.Values)
                solution = solution.WithProjectMetadataReferences(project, references);
            sReferences = references;
        }
        var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // A tree without a folder (the implicit global usings) belongs to every project, as every real build has it.
        var entries = new List<(string Key, ProjectId Project, SyntaxTree Tree)>();
        foreach (SyntaxTree tree in trees)
        {
            if (Path.GetDirectoryName(tree.FilePath) is null or "")
            {
                foreach ((string name, ProjectId project) in sProjects)
                    entries.Add((name == AssemblyLayout.Game ? tree.FilePath : name + ":" + tree.FilePath, project, tree));
            }
            else
                entries.Add((tree.FilePath, sProjects[layout.Owner(tree.FilePath)], tree));
        }
        foreach ((string path, ProjectId project, SyntaxTree tree) in entries)
        {
            present.Add(path);
            SourceText text = tree.GetText();
            if (sDocuments.TryGetValue(path, out var known))
            {
                if (!ReferenceEquals(known.Text, text))
                {
                    solution = solution.WithDocumentText(known.Id, text);
                    sDocuments[path] = (known.Id, text);
                }
                continue;
            }
            DocumentId id = DocumentId.CreateNewId(project, path);
            solution = solution.AddDocument(id, Path.GetFileName(tree.FilePath), text, filePath: tree.FilePath);
            sDocuments[path] = (id, text);
        }
        foreach (string gone in sDocuments.Keys.Where(path => !present.Contains(path)).ToArray())
        {
            solution = solution.RemoveDocument(sDocuments[gone].Id);
            sDocuments.Remove(gone);
        }
        if (!sWorkspace.TryApplyChanges(solution))
            throw new InvalidOperationException("The completion workspace did not accept the source snapshot.");
        return sWorkspace.CurrentSolution.GetDocument(sDocuments[active.FilePath].Id)!;
    }

    public static bool TryComplete(IReadOnlyList<SyntaxTree> trees, SyntaxTree active, int position,
        MetadataReference[] references, CSharpParseOptions parse, AssemblyLayout layout, List<string> output)
    {
        try
        {
            Complete(trees, active, position, references, parse, layout, output);
            return true;
        }
        catch (Exception exception)
        {
            // A type that cannot load names the assembly it lacks only in its loader exceptions.
            string detail = exception is System.Reflection.ReflectionTypeLoadException load
                ? string.Join("; ", load.LoaderExceptions.Where(e => e != null).Select(e => e!.Message).Distinct().Take(3))
                : "";
            Console.Error.WriteLine($"Roslyn completion unavailable, using symbol lookup: {exception.Message}"
                + (detail.Length > 0 ? $" ({detail})" : ""));
            // Start again from nothing next time; a half-synchronised workspace would give wrong answers.
            sWorkspace = null;
            sDocuments.Clear();
            return false;
        }
    }

    private static void Complete(IReadOnlyList<SyntaxTree> trees, SyntaxTree active, int position,
        MetadataReference[] references, CSharpParseOptions parse, AssemblyLayout layout, List<string> output)
    {
        var clock = System.Diagnostics.Stopwatch.StartNew();
        // TALLOW_LS_TRACE=<file>: one timing line per completion (workspace sync, Roslyn's list, encoding).
        string? trace = Environment.GetEnvironmentVariable("TALLOW_LS_TRACE");
        Document document = Sync(trees, active, references, parse, layout);
        long synced = clock.ElapsedTicks;
        CompletionService service = CompletionService.GetService(document) ??
            throw new InvalidOperationException("No C# completion service.");
        CompletionList list = service.GetCompletionsAsync(document, position).GetAwaiter().GetResult();
        SourceText text = document.GetTextAsync().GetAwaiter().GetResult();
        string typed = text.ToString(list.Span);
        long listed = clock.ElapsedTicks;

        var ranked = new List<(CompletionItem Item, int Rank)>();
        foreach (CompletionItem item in list.ItemsList)
        {
            // Snippets need tab stops the editor does not have.
            if (item.Tags.Contains(WellKnownTags.Snippet))
                continue;
            int rank = Match(typed, item.FilterText);
            if (rank >= 0)
                ranked.Add((item, rank));
        }
        // Exact-case prefix, any-case prefix, then CamelCase humps ("gc" -> GetComponent); Roslyn's own priority and
        // sort text inside each (types from other namespaces sort last).
        ranked.Sort((a, b) =>
        {
            int order = a.Rank.CompareTo(b.Rank);
            if (order == 0) order = b.Item.Rules.MatchPriority.CompareTo(a.Item.Rules.MatchPriority);
            if (order == 0) order = string.Compare(a.Item.SortText, b.Item.SortText, StringComparison.OrdinalIgnoreCase);
            if (order == 0) order = string.Compare(a.Item.DisplayText, b.Item.DisplayText, StringComparison.Ordinal);
            return order;
        });

        string source = text.ToString();
        SemanticModel? model = document.GetSemanticModelAsync().GetAwaiter().GetResult();
        ITypeSymbol? receiver = model == null ? null : Receiver(model, list.Span.Start);
        int serviceDescriptions = 0;
        // [NonSerialized] is how a Tallow script keeps a field out of scenes, saves and hot reload, but .NET hides it
        // from completion (EditorBrowsable Never, for BinaryFormatter's sake): offer it in attribute lists anyway.
        SyntaxNode root = active.GetRoot();
        SyntaxToken before = root.FindToken(Math.Max(0, list.Span.Start - 1));
        if (Match(typed, "NonSerialized") >= 0 && !ranked.Any(pair => pair.Item.DisplayText == "NonSerialized") &&
            before.Parent is Microsoft.CodeAnalysis.CSharp.Syntax.AttributeListSyntax &&
            (before.IsKind(SyntaxKind.OpenBracketToken) || before.IsKind(SyntaxKind.CommaToken)))
            output.Add("completion\tNonSerialized\x1F\x1F\x1F\x1F" +
                Field("class System.NonSerializedAttribute\nThis field is not saved: not in scenes, saves or hot reload.") +
                "\t" + WellKnownTags.Class);
        bool parensAllowed = ParenthesesAllowed(root, source, list.Span);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        int written = 0;
        foreach ((CompletionItem item, _) in ranked)
        {
            if (written >= MaxItems)
            {
                // The editor asks again as the word grows instead of narrowing this list.
                // "completion-more\t<items not sent>" (result lines have at least two fields).
                output.Add("completion-more\t" + (ranked.Count - MaxItems));
                break;
            }
            string display = item.DisplayTextPrefix + item.DisplayText + item.DisplayTextSuffix;
            string description = "";
            List<ISymbol>? symbols = null;
            if (written < MaxDescriptions && model != null)
            {
                symbols = Symbols(model, receiver, list.Span.Start, item);
                description = Describe(symbols, item);
            }
            if (description.Length == 0 && serviceDescriptions < MaxServiceDescriptions && written < MaxDescriptions)
            {
                serviceDescriptions++;
                description = service.GetDescriptionAsync(document, item).GetAwaiter().GetResult()?.Text.Trim() ?? "";
            }
            string? parens = parensAllowed ? Parentheses(symbols, item) : null;
            if (!Encode(service, document, text, source, list.Span, item, description, parens, out string encoded) ||
                !seen.Add(encoded))
                continue;
            output.Add("completion\t" + encoded + "\t" + Kind(item));
            written++;
        }
        if (!string.IsNullOrEmpty(trace))
            File.AppendAllText(trace, $"completion: sync {synced * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F1} ms, " +
                $"list {(listed - synced) * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F1} ms ({list.ItemsList.Count}), " +
                $"encode {(clock.ElapsedTicks - listed) * 1000.0 / System.Diagnostics.Stopwatch.Frequency:F1} ms ({written})\n");
    }

    /// <summary>Whether a method accepted here is a call that wants "()": not when "(" or "<" already follows the
    /// word, inside nameof(...), a using directive or doc comment, or where a method group is likely meant (the
    /// right of "+=", "-=" or "=" and an argument, as with delegates and events).</summary>
    internal static bool ParenthesesAllowed(SyntaxNode root, string source, TextSpan span)
    {
        int next = span.End;
        while (next < source.Length && (source[next] == ' ' || source[next] == '\t'))
            next++;
        if (next < source.Length && (source[next] == '(' || source[next] == '<'))
            return false;
        SyntaxToken token = root.FindToken(Math.Max(0, span.Start - 1), findInsideTrivia: true);
        if (token.Parent?.FirstAncestorOrSelf<DocumentationCommentTriviaSyntax>(ascendOutOfTrivia: false) != null ||
            token.Parent?.FirstAncestorOrSelf<UsingDirectiveSyntax>() != null)
            return false;
        for (SyntaxNode? node = token.Parent; node != null; node = node.Parent)
        {
            if (node is InvocationExpressionSyntax { Expression: IdentifierNameSyntax { Identifier.ValueText: "nameof" } })
                return false;
            if (node is StatementSyntax or MemberDeclarationSyntax)
                break;
        }
        // The token before the word (or before "x." when completing a member) decides delegate/event contexts.
        SyntaxToken previous = root.FindToken(Math.Max(0, span.Start - 1));
        if (previous.Span.End > span.Start)
            previous = previous.GetPreviousToken();
        while (previous.IsKind(SyntaxKind.DotToken) || previous.IsKind(SyntaxKind.IdentifierToken) &&
               previous.GetNextToken().IsKind(SyntaxKind.DotToken) && previous.GetNextToken().Span.End <= span.Start)
            previous = previous.GetPreviousToken();
        return !previous.IsKind(SyntaxKind.PlusEqualsToken) && !previous.IsKind(SyntaxKind.MinusEqualsToken);
    }

    /// <summary>"()" for a method whose overloads all take no arguments, "(\x1E)" when one takes some (or the
    /// overloads were not looked up: items far down the list); null for anything that is not a method.</summary>
    private static string? Parentheses(List<ISymbol>? symbols, CompletionItem item)
    {
        if (!item.Tags.Contains(WellKnownTags.Method) && !item.Tags.Contains(WellKnownTags.ExtensionMethod))
            return null;
        // Generic methods ("GetComponent<>") need their type argument first.
        if (item.DisplayText.EndsWith('>') || item.DisplayTextSuffix.Contains('<') || !item.Properties.ContainsKey("SymbolName"))
            return null;
        var methods = symbols?.OfType<IMethodSymbol>().ToList();
        return methods is { Count: > 0 } && methods.All(method => method.Parameters.Length == 0) ? "()" : "(\x1E)";
    }

    /// <summary>The type whose members are being completed ("Transform." / "body?."), or null.</summary>
    private static ITypeSymbol? Receiver(SemanticModel model, int position)
    {
        SyntaxToken dot = model.SyntaxTree.GetRoot().FindToken(Math.Max(0, position - 1));
        if (!dot.IsKind(SyntaxKind.DotToken) && !dot.IsKind(SyntaxKind.QuestionToken))
            dot = dot.GetPreviousToken();
        ExpressionSyntax? expression = dot.Parent switch
        {
            MemberAccessExpressionSyntax access when access.OperatorToken == dot => access.Expression,
            MemberBindingExpressionSyntax binding => binding.FirstAncestorOrSelf<ConditionalAccessExpressionSyntax>()?.Expression,
            _ => null
        };
        if (expression == null)
            return null;
        ITypeSymbol? type = model.GetTypeInfo(expression).Type ?? model.GetSymbolInfo(expression).Symbol as ITypeSymbol;
        if (dot.Parent is MemberBindingExpressionSyntax && type is INamedTypeSymbol { OriginalDefinition.SpecialType:
                SpecialType.System_Nullable_T } nullable)
            type = nullable.TypeArguments[0];
        return type;
    }

    private static readonly SymbolDisplayFormat DescriptionFormat = SymbolDisplayFormat.MinimallyQualifiedFormat
        .WithMemberOptions(SymbolDisplayMemberOptions.IncludeParameters | SymbolDisplayMemberOptions.IncludeType |
            SymbolDisplayMemberOptions.IncludeContainingType | SymbolDisplayMemberOptions.IncludeRef)
        .WithParameterOptions(SymbolDisplayParameterOptions.IncludeType | SymbolDisplayParameterOptions.IncludeName |
            SymbolDisplayParameterOptions.IncludeDefaultValue | SymbolDisplayParameterOptions.IncludeParamsRefOut)
        .WithKindOptions(SymbolDisplayKindOptions.IncludeTypeKeyword);

    /// <summary>The symbols an item names at the caret (its overloads), or null when it names none there.</summary>
    private static List<ISymbol>? Symbols(SemanticModel model, ITypeSymbol? receiver, int position, CompletionItem item)
    {
        if (!item.Properties.TryGetValue("SymbolName", out string? name) || item.InlineDescription.Length > 0)
            return null;
        return (receiver != null
                ? model.LookupSymbols(position, receiver, name, includeReducedExtensionMethods: true)
                : model.LookupSymbols(position, name: name))
            .Where(symbol => !item.Properties.TryGetValue("SymbolKind", out string? kind) ||
                kind == ((int)symbol.Kind).ToString(System.Globalization.CultureInfo.InvariantCulture))
            // An extension method item describes the extension, not an instance method of the same name.
            .Where(symbol => item.Tags.Contains(WellKnownTags.ExtensionMethod) ==
                symbol is IMethodSymbol { ReducedFrom: not null } or IMethodSymbol { IsExtensionMethod: true })
            .ToList();
    }

    /// <summary>"void Rigidbody.AddForce(Vector3 force) (+ 1 overload)" and the XML summary, from the symbols the item
    /// names; empty when it names none.</summary>
    private static string Describe(List<ISymbol>? symbols, CompletionItem item)
    {
        if (symbols is not { Count: > 0 })
            return "";
        ISymbol first = symbols[0];
        string prefix = first switch
        {
            IFieldSymbol { IsConst: false } => "(field) ",
            ILocalSymbol => "(local) ",
            IParameterSymbol => "(parameter) ",
            IMethodSymbol { IsExtensionMethod: true } or IMethodSymbol { ReducedFrom: not null } => "(extension) ",
            _ => ""
        };
        var text = new StringBuilder(prefix).Append(first.ToDisplayString(DescriptionFormat));
        if (first is ILocalSymbol local)
            text.Clear().Append(prefix).Append(local.Type.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat))
                .Append(' ').Append(local.Name);
        if (symbols.Count > 1)
            text.Append($" (+ {symbols.Count - 1} overload{(symbols.Count > 2 ? "s" : "")})");
        string summary = Summary((first as IMethodSymbol)?.ReducedFrom ?? first.OriginalDefinition);
        if (summary.Length > 0)
            text.Append('\n').Append(summary);
        return text.ToString();
    }

    // The <summary> of a symbol's XML documentation as plain text (cref names kept), at most a few lines.
    private static string Summary(ISymbol symbol)
    {
        string xml = symbol.GetDocumentationCommentXml(expandIncludes: false) ?? "";
        int open = xml.IndexOf("<summary>", StringComparison.Ordinal);
        int close = xml.IndexOf("</summary>", StringComparison.Ordinal);
        if (open < 0 || close <= open)
            return "";
        string inner = xml[(open + 9)..close];
        inner = System.Text.RegularExpressions.Regex.Replace(inner, "<(see|seealso|paramref|typeparamref)\\s+(cref|name|langword)=\"(?:[A-Z]:)?([^\"]+)\"\\s*/>",
            match => match.Groups[3].Value.Split('.').Last());
        inner = System.Text.RegularExpressions.Regex.Replace(inner, "<[^>]+>", "");
        inner = System.Net.WebUtility.HtmlDecode(System.Text.RegularExpressions.Regex.Replace(inner, "\\s+", " ").Trim());
        return inner.Length > 400 ? inner[..400] + "..." : inner;
    }

    /// <summary>-1: no match; 0 exact-case prefix; 1 prefix ignoring case; 2 CamelCase humps.</summary>
    internal static int Match(string typed, string candidate)
    {
        if (typed.Length == 0 || candidate.StartsWith(typed, StringComparison.Ordinal))
            return 0;
        if (candidate.StartsWith(typed, StringComparison.OrdinalIgnoreCase))
            return 1;
        return Humps(typed, 0, candidate, 0) ? 2 : -1;
    }

    // Each typed letter continues the current word of the name or starts a later one (an upper-case letter, or a
    // letter after '_' or a digit); the first must start the name.
    private static bool Humps(string typed, int t, string candidate, int c)
    {
        if (t == typed.Length)
            return true;
        for (int j = c; j < candidate.Length; j++)
        {
            bool start = j == 0 || char.IsUpper(candidate[j]) && !char.IsUpper(candidate[j - 1]) ||
                !char.IsLetterOrDigit(candidate[j - 1]) || char.IsDigit(candidate[j - 1]) != char.IsDigit(candidate[j]);
            bool next = j == c && t > 0;
            if ((start || next) && char.ToUpperInvariant(candidate[j]) == char.ToUpperInvariant(typed[t]) &&
                Humps(typed, t + 1, candidate, j + 1))
                return true;
            if (t == 0)
                return false;
        }
        return false;
    }

    private static string Kind(CompletionItem item)
    {
        foreach (string tag in item.Tags)
            switch (tag)
            {
                case WellKnownTags.Class: case WellKnownTags.Structure: case WellKnownTags.Interface: case WellKnownTags.Enum:
                case WellKnownTags.Delegate: case WellKnownTags.Namespace: case WellKnownTags.Method: case WellKnownTags.Property:
                case WellKnownTags.Field: case WellKnownTags.Event: case WellKnownTags.Keyword: case WellKnownTags.Local:
                case WellKnownTags.Parameter: case WellKnownTags.Constant: case WellKnownTags.EnumMember:
                case WellKnownTags.ExtensionMethod: case WellKnownTags.TypeParameter: case WellKnownTags.RangeVariable:
                case WellKnownTags.Label:
                    return tag;
            }
        return "Symbol";
    }

    private static string Field(string value) =>
        value.Replace("\r\n", "\n").Replace('\n', '\x1D').Replace('\t', '\x1C').Replace('\x1F', ' ').Replace('\r', ' ');

    private static int Utf8(string value, int offset) =>
        Encoding.UTF8.GetByteCount(value.AsSpan(0, Math.Clamp(offset, 0, value.Length)));

    /// <summary>The item as the editor applies it: the word replaced, plus edits elsewhere. False when the change
    /// cannot be expressed that way (it rewrites the word's surroundings).</summary>
    private static bool Encode(CompletionService service, Document document, SourceText text, string source,
        TextSpan span, CompletionItem item, string description, string? parens, out string encoded)
    {
        encoded = "";
        string display = item.DisplayTextPrefix + item.DisplayText + item.DisplayTextSuffix;
        string insert;
        var extra = new List<TextChange>();
        int? caret = null;
        // A symbol in scope inserts its name (InsertionText) and nothing else: no need to ask for its change
        // (that is most of the cost). Items from other namespaces, keywords and the like are asked.
        CompletionChange? change = item.Properties.TryGetValue("InsertionText", out string? named) &&
            item.InlineDescription.Length == 0 && !item.Properties.ContainsKey("NamespaceName")
            ? null : service.GetChangeAsync(document, item).GetAwaiter().GetResult();
        caret = change?.NewPosition;
        if (change == null)
            insert = named!;
        else if (change.TextChange.Span == span && change.TextChanges.Length <= 1)
            insert = change.TextChange.NewText ?? "";
        else
        {
            // Split one large change (a using added at the top together with the word) into the smallest edits.
            Document changed = document.WithText(text.WithChanges(change.TextChanges.IsDefaultOrEmpty
                ? [change.TextChange] : change.TextChanges));
            IEnumerable<TextChange> edits = changed.GetTextChangesAsync(document).GetAwaiter().GetResult();
            TextChange? main = null;
            foreach (TextChange edit in edits.OrderBy(edit => edit.Span.Start))
            {
                bool touches = edit.Span.End >= span.Start && edit.Span.Start <= span.End;
                if (touches && main == null)
                    main = edit;
                else if (touches)
                    return false;
                else
                    extra.Add(edit);
            }
            if (main is not { } word)
                // Nothing changes at the word: the item is what is already typed.
                insert = source.Substring(span.Start, span.Length);
            else
            {
                if (word.Span.Start < span.Start || word.Span.End > span.End)
                    return false;
                insert = source[span.Start..word.Span.Start] + word.NewText + source[word.Span.End..span.End];
            }
            // Where the caret lands, in the new text: back to an offset inside the inserted word.
            if (caret is int after)
            {
                int shift = extra.Where(edit => edit.Span.End <= span.Start)
                    .Sum(edit => (edit.NewText?.Length ?? 0) - edit.Span.Length);
                caret = after - shift;
            }
        }
        if (caret is int at && at - span.Start >= 0 && at - span.Start < insert.Length)
            insert = insert.Insert(at - span.Start, "\x1E");
        // A method call: "()" after the name, the caret inside when an overload takes arguments.
        if (parens != null && insert == item.DisplayText)
            insert += parens;

        string detail = item.InlineDescription;
        var edited = string.Join('\x1A', extra.Select(edit =>
            $"{Utf8(source, edit.Span.Start)}\x1B{Utf8(source, edit.Span.End) - Utf8(source, edit.Span.Start)}\x1B{Field(edit.NewText ?? "")}"));
        // A plain item (inserts its own name, nothing else) stays a bare name: the editor previews it inline.
        if (insert == display && extra.Count == 0 && detail.Length == 0 && description.Length == 0)
            encoded = Field(display);
        else
            encoded = string.Join('\x1F', Field(display), Field(insert == display ? "" : insert), Field(detail), edited,
                Field(description));
        return true;
    }
}
#endif
