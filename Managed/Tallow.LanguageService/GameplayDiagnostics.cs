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
            string[] sourceLines = source.Text.Split('\n');
            foreach (MethodDeclarationSyntax method in root.DescendantNodes()
                .OfType<MethodDeclarationSyntax>())
            {
                bool networkTick = IsNetworkTick(method, semantic);
                // Allocation hints also matter in local frame callbacks and
                // fixed physics ticks. Determinism warnings remain restricted
                // to predicted input-tick methods.
                if (!networkTick && !IsHotLifecycleCallback(method, semantic))
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
                                invocation.Ancestors().Any(IsLoop) &&
                                IsGameObjectComponentLookup(called))
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
                    if (category is null || message is null ||
                        category == "determinism" && !networkTick)
                        continue;

                    var pos = tree.GetLineSpan(location.Span).StartLinePosition;
                    if (pos.Line < 0 || pos.Line >= sourceLines.Length)
                        continue;
                    string lineText = sourceLines[pos.Line];
                    int column = System.Text.Encoding.UTF8.GetByteCount(
                        lineText.AsSpan(0, Math.Min(pos.Character, lineText.Length)));
                    yield return new Warning(tree.FilePath, pos.Line, column, category, message);
                }
            }
        }
    }

    private static bool IsGameObjectComponentLookup(IMethodSymbol method)
    {
        // Only warn about real Tallow component lookups. An unrelated game
        // utility named GetComponent is not inherently an ECS hot spot.
        return method.OriginalDefinition.ContainingType?.ToDisplayString()
            is "Tallow.Script" or "Tallow.GameObject";
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

    private static bool IsHotLifecycleCallback(MethodDeclarationSyntax method,
        SemanticModel semantic)
    {
        IMethodSymbol? symbol = semantic.GetDeclaredSymbol(method);
        if (symbol is null || !symbol.ReturnsVoid || !IsGameplayScript(symbol))
            return false;
        return method.Identifier.ValueText switch
        {
            "FixedUpdate" or "LateUpdate" =>
                symbol.Parameters.Length == 1 &&
                symbol.Parameters[0].Type.SpecialType == SpecialType.System_Single,
            "OnLocalUpdate" => symbol.Parameters.Length == 0,
            _ => false
        };
    }

    private static bool IsGameplayScript(IMethodSymbol symbol)
    {
        for (INamedTypeSymbol? current = symbol.ContainingType;
            current is not null; current = current.BaseType)
            if (current.ToDisplayString() is "Tallow.Script" or "Tallow.NetworkBehaviour")
                return true;
        return false;
    }

    private static bool IsNetworkTick(MethodDeclarationSyntax method, SemanticModel semantic)
    {
        string name = method.Identifier.ValueText;
        if (name is not ("Update" or "Simulate"))
            return false;
        IMethodSymbol? symbol = semantic.GetDeclaredSymbol(method);
        if (symbol is null || symbol.Parameters.Length == 0 ||
            symbol.ReturnsVoid == false || symbol.ContainingType is null)
            return false;
        string input = symbol.Parameters[0].Type.Name;
        if (name == "Update" && input != "TickInput" ||
            name == "Simulate" && input != "NetInput")
            return false;
        // Only actual gameplay script components run in predicted ticks.
        return IsGameplayScript(symbol);
    }
}
