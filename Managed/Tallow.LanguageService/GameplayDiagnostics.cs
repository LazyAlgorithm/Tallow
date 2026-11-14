using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Tallow.LanguageService;

/// <summary>
/// Conservative C# gameplay diagnostics. These are editor-only suggestions:
/// they never change the C# compiler's severity or prevent Play.
/// Only report patterns that can be identified from Roslyn syntax/types rather
/// than scanning comments, strings, or unrelated user method names.
/// </summary>
internal static class GameplayDiagnostics
{
    internal sealed record Warning(string Path, int Line, int Utf8Column,
        string Category, string Message);

    internal static IEnumerable<Warning> Analyze(CSharpCompilation compilation,
        IReadOnlyDictionary<string, SourceFile> sources)
    {
        foreach (SyntaxTree tree in compilation.SyntaxTrees)
        {
            if (!sources.TryGetValue(tree.FilePath, out SourceFile? source))
                continue;
            // Tallow.API internals are not user gameplay scripts.
            SyntaxNode root = tree.GetRoot();
            SemanticModel semantic = compilation.GetSemanticModel(tree);
            foreach (MethodDeclarationSyntax method in root.DescendantNodes()
                .OfType<MethodDeclarationSyntax>())
            {
                if (!IsNetworkTick(method, semantic))
                    continue;

                string context = method.Identifier.ValueText;
                foreach (SyntaxNode node in method.Body?.DescendantNodesAndSelf() ??
                    (IEnumerable<SyntaxNode>)(method.ExpressionBody?.Expression.DescendantNodesAndSelf() ??
                        Enumerable.Empty<SyntaxNode>()))
                {
                    string? message = null;
                    string? category = null;
                    SyntaxNode location = node;
                    if (node is MemberAccessExpressionSyntax member)
                    {
                        // Diagnostics are only about deterministic network replay,
                        // not about arbitrary local UI or editor code.
                        if (IsBoundMember(semantic, member, "System.Random", "Shared"))
                        {
                            category = "determinism";
                            message = "TAL-NET001: Random.Shared varies by process; use a shared deterministic seed in networked " + context + ".";
                        }
                        else if (IsBoundMember(semantic, member, "System.DateTime", "Now", "UtcNow"))
                        {
                            category = "determinism";
                            message = "TAL-NET002: Wall-clock time differs across clients and replays; count simulation ticks instead.";
                        }
                        else if (IsBoundMember(semantic, member, "Tallow.Time",
                            "DeltaTime", "RealTime", "Time", "FrameCount"))
                        {
                            category = "determinism";
                            message = "TAL-NET003: Local frame time/count differs across clients; use the supplied fixed tick values.";
                        }
                        else if (IsBoundMember(semantic, member, "Tallow.Input", "MousePosition",
                            "MouseDelta", "MouseX", "MouseY"))
                        {
                            category = "determinism";
                            message = "TAL-NET004: Local mouse polling cannot be replayed; use the tick's networked input.";
                        }
                        else if (IsBoundMember(semantic, member, "System.Environment",
                            "TickCount", "TickCount64"))
                        {
                            category = "determinism";
                            message = "TAL-NET005: Wall-clock or uptime values cannot be replayed; use deterministic tick state.";
                        }
                    }
                    else if (node is InvocationExpressionSyntax invocation)
                    {
                        IMethodSymbol? called = semantic.GetSymbolInfo(invocation).Symbol as IMethodSymbol;
                        if (called is not null)
                        {
                            string container = called.ContainingType.ToDisplayString();
                            if (called.Name.StartsWith("Get", StringComparison.Ordinal) &&
                                container == "Tallow.Input")
                            {
                                category = "determinism";
                                message = "TAL-NET004: Local input polling cannot be replayed on other machines; use the tick's networked input.";
                            }
                            else if (container == "System.Guid" && called.Name == "NewGuid" ||
                                     container == "System.Diagnostics.Stopwatch" && called.Name == "GetTimestamp" ||
                                     container == "System.Environment" && called.Name == "get_TickCount")
                            {
                                category = "determinism";
                                message = "TAL-NET005: Nondeterministic IDs or clocks cannot be replayed; use deterministic tick state.";
                            }
                            else if (called.Name == "GetComponent" &&
                                invocation.Ancestors().Any(IsLoop))
                            {
                                category = "optimization";
                                message = "TAL-PERF002: Repeated component lookup inside a loop; cache references or use a batched ECS query.";
                            }
                        }
                    }
                    else if (node is ObjectCreationExpressionSyntax creation &&
                        creation.ArgumentList?.Arguments.Count == 0 &&
                        IsSystemRandom(semantic.GetTypeInfo(creation).Type))
                    {
                        category = "determinism";
                        message = "TAL-NET001: Random() without a shared seed differs across clients; use deterministic state.";
                    }
                    else if (node is ImplicitObjectCreationExpressionSyntax implicitCreation &&
                        implicitCreation.ArgumentList.Arguments.Count == 0 &&
                        IsSystemRandom(semantic.GetTypeInfo(implicitCreation).Type))
                    {
                        category = "determinism";
                        message = "TAL-NET001: Random() without a shared seed differs across clients; use deterministic state.";
                    }
                    else if (node is ObjectCreationExpressionSyntax explicitAllocation &&
                        semantic.GetTypeInfo(explicitAllocation).Type is { IsReferenceType: true } allocated &&
                        !IsSystemRandom(allocated))
                    {
                        category = "optimization";
                        message = "TAL-PERF001: Allocating a managed object each simulation tick can cause GC pressure; reuse it when practical.";
                    }
                    else if (node is ImplicitObjectCreationExpressionSyntax implicitAllocation &&
                        semantic.GetTypeInfo(implicitAllocation).Type is { IsReferenceType: true } &&
                        !IsSystemRandom(semantic.GetTypeInfo(implicitAllocation).Type))
                    {
                        category = "optimization";
                        message = "TAL-PERF001: Allocating a managed object each simulation tick can cause GC pressure; reuse it when practical.";
                    }
                    else if (node is ArrayCreationExpressionSyntax or ImplicitArrayCreationExpressionSyntax)
                    {
                        category = "optimization";
                        message = "TAL-PERF001: Allocating an array each simulation tick can cause GC pressure; reuse a buffer when practical.";
                    }
                    if (category is null || message is null)
                        continue;

                    var pos = tree.GetLineSpan(location.Span).StartLinePosition;
                    string lineText = source.Text.Split('\n')[pos.Line];
                    int column = System.Text.Encoding.UTF8.GetByteCount(
                        lineText.AsSpan(0, Math.Min(pos.Character, lineText.Length)));
                    yield return new Warning(tree.FilePath, pos.Line, column, category, message);
                }
            }
        }
    }

    private static bool IsLoop(SyntaxNode syntax) =>
        syntax is ForStatementSyntax or ForEachStatementSyntax or ForEachVariableStatementSyntax
            or WhileStatementSyntax or DoStatementSyntax;

    private static bool IsSystemRandom(ITypeSymbol? type) =>
        type?.ToDisplayString() == "System.Random";

    private static bool IsBoundMember(SemanticModel model, MemberAccessExpressionSyntax member,
        string type, params string[] names)
    {
        ISymbol? symbol = model.GetSymbolInfo(member).Symbol;
        return symbol != null && names.Contains(symbol.Name) &&
            symbol.ContainingType?.ToDisplayString() == type;
    }

    private static bool IsNetworkTick(MethodDeclarationSyntax method, SemanticModel semantic)
    {
        string name = method.Identifier.ValueText;
        if (name is not ("Update" or "Simulate"))
            return false;
        IMethodSymbol? symbol = semantic.GetDeclaredSymbol(method);
        if (symbol is null || symbol.Parameters.Length == 0 ||
            symbol.ReturnsVoid == false || symbol.ContainingType is not { } owner)
            return false;
        string input = symbol.Parameters[0].Type.Name;
        if (name == "Update" && input != "TickInput" ||
            name == "Simulate" && input != "NetInput")
            return false;
        // Only script components participate in Tallow's predicted ticks.
        for (INamedTypeSymbol? current = owner; current is not null; current = current.BaseType)
            if (current.ToDisplayString() is "Tallow.Script" or "Tallow.NetworkBehaviour")
                return true;
        return false;
    }
}
