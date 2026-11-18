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

    /// <summary>The warnings of the files in <paramref name="texts"/> (path to its text). Tallow.Build links this
    /// file too and lists the determinism ones when it builds a game for release.</summary>
    internal static IEnumerable<Warning> Analyze(CSharpCompilation compilation,
        IReadOnlyDictionary<string, string> texts)
    {
        foreach (SyntaxTree tree in compilation.SyntaxTrees)
        {
            if (!texts.TryGetValue(tree.FilePath, out string? text))
                continue;
            // Tallow.API internals are not user gameplay scripts.
            SyntaxNode root = tree.GetRoot();
            SemanticModel semantic = compilation.GetSemanticModel(tree);
            string[] sourceLines = text.Split('\n');
            foreach (MethodDeclarationSyntax method in root.DescendantNodes()
                .OfType<MethodDeclarationSyntax>())
            {
                bool networkTick = IsNetworkTick(method, semantic) || IsEcsSystemTick(method, semantic);
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
                        else if (IsBoundMember(semantic, member, "System.DateTime", "Now", "UtcNow", "Today") ||
                                 IsBoundMember(semantic, member, "System.DateTimeOffset", "Now", "UtcNow"))
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
                            "TickCount", "TickCount64") ||
                            IsBoundMember(semantic, member, "System.Diagnostics.Stopwatch",
                            "Elapsed", "ElapsedMilliseconds", "ElapsedTicks"))
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
                            else if (container == "System.Diagnostics.Stopwatch" &&
                                     called.Name is "StartNew" or "GetElapsedTime")
                            {
                                category = "determinism";
                                message = "TAL-NET005: Nondeterministic IDs or clocks cannot be replayed; use deterministic tick state.";
                            }
                            else if (container == "System.Threading.Tasks.Parallel" ||
                                     container == "System.Threading.Tasks.Task" && called.Name == "Run" ||
                                     container == "System.Threading.Tasks.TaskFactory" && called.Name == "StartNew" ||
                                     container == "System.Threading.ThreadPool" && called.Name.Contains("QueueUserWorkItem"))
                            {
                                category = "determinism";
                                message = "TAL-NET006: Work on other threads finishes in a different order on each machine, so its writes to " +
                                    "simulated state cannot be replayed; keep tick work on the game thread (an ECS query runs it in order).";
                            }
                            else if (IsLocaleParse(called))
                            {
                                category = "determinism";
                                message = "TAL-NET007: " + called.ContainingType.ToDisplayString() + "." + called.Name +
                                    " follows each machine's language settings (\"1,5\" or \"1.5\"); pass CultureInfo.InvariantCulture.";
                            }
                            else if (called.Name == "GetHashCode" && called.ContainingType.SpecialType is
                                         SpecialType.System_String or SpecialType.System_Object ||
                                     container == "System.HashCode")
                            {
                                category = "determinism";
                                message = "TAL-NET008: Hash codes of strings and objects are randomised per process and differ on each machine; " +
                                    "do not keep them in simulated state or order by them.";
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
                    else if (node is AnonymousFunctionExpressionSyntax lambda && AllocatesEachCall(lambda, semantic))
                    {
                        category = "optimization";
                        message = "TAL-PERF003: This lambda uses " + CapturedNames(lambda, semantic) +
                            " from around it, so a new closure and delegate are made each tick; use a method, or a static lambda, made once.";
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

    /// <summary>A lambda that captures locals, parameters or this allocates a closure and delegate on every call of
    /// the method around it (C# caches only lambdas that capture nothing). One handed straight to a Tallow API (a
    /// query's ForEach) runs for the whole call, once a tick, so that one is left alone.</summary>
    private static bool AllocatesEachCall(AnonymousFunctionExpressionSyntax lambda, SemanticModel semantic)
    {
        if (lambda.Modifiers.Any(SyntaxKind.StaticKeyword))
            return false;
        if (lambda.Parent is ArgumentSyntax { Parent: ArgumentListSyntax { Parent: InvocationExpressionSyntax call } } &&
            semantic.GetSymbolInfo(call).Symbol is IMethodSymbol { ContainingNamespace: var space } &&
            space?.ToDisplayString().StartsWith("Tallow", StringComparison.Ordinal) == true)
            return false;
        return Captured(lambda, semantic).Any();
    }

    private static IEnumerable<ISymbol> Captured(AnonymousFunctionExpressionSyntax lambda, SemanticModel semantic)
    {
        DataFlowAnalysis? flow = semantic.AnalyzeDataFlow(lambda);
        if (flow is null || !flow.Succeeded)
            return Enumerable.Empty<ISymbol>();
        // Symbols declared inside the lambda (its own parameters and locals) are not captured from outside.
        return flow.CapturedInside.Where(symbol => !symbol.Locations.Any(location => lambda.Span.Contains(location.SourceSpan)) ||
            symbol is IParameterSymbol { IsThis: true });
    }

    private static string CapturedNames(AnonymousFunctionExpressionSyntax lambda, SemanticModel semantic) =>
        string.Join(", ", Captured(lambda, semantic).Select(symbol =>
            symbol is IParameterSymbol { IsThis: true } ? "this" : "'" + symbol.Name + "'").Distinct().Take(3));

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

    /// <summary>float/double/decimal/Half Parse or TryParse, or Convert.ToSingle/ToDouble/ToDecimal of a string,
    /// without an IFormatProvider: they read "1,5" or "1.5" depending on the machine's culture.</summary>
    private static bool IsLocaleParse(IMethodSymbol called)
    {
        // Nullable-annotated in .NET ("IFormatProvider?"), so by name and namespace.
        bool provider = called.Parameters.Any(p => p.Type.Name == "IFormatProvider" &&
            p.Type.ContainingNamespace?.ToDisplayString() == "System");
        if (provider)
            return false;
        string container = called.ContainingType.ToDisplayString();
        if (called.Name is "Parse" or "TryParse")
            return container is "float" or "double" or "decimal" or "System.Half" &&
                called.Parameters.FirstOrDefault()?.Type.SpecialType == SpecialType.System_String;
        return container == "System.Convert" && called.Name is "ToSingle" or "ToDouble" or "ToDecimal" &&
            called.Parameters.Length == 1 && called.Parameters[0].Type.SpecialType == SpecialType.System_String;
    }

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
        if (symbol is null || !symbol.IsOverride ||
            !symbol.ReturnsVoid || !IsGameplayScript(symbol))
            return false;
        return method.Identifier.ValueText switch
        {
            "FixedUpdate" or "LocalEarlyUpdate" or "LocalUpdate" or "LocalLateUpdate" =>
                symbol.Parameters.Length == 1 &&
                symbol.Parameters[0].Type.SpecialType == SpecialType.System_Single,
            "EarlyUpdate" or "LateUpdate" => symbol.Parameters.Length == 2,
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
        if (name is not ("Update" or "EarlyUpdate" or "LateUpdate" or "Simulate"))
            return false;
        IMethodSymbol? symbol = semantic.GetDeclaredSymbol(method);
        if (symbol is null || !symbol.IsOverride || symbol.Parameters.Length == 0 ||
            symbol.ReturnsVoid == false || symbol.ContainingType is null)
            return false;
        string input = symbol.Parameters[0].Type.ToDisplayString();
        if (name != "Simulate" && input != "Tallow.TickInput" ||
            name == "Simulate" && input != "Tallow.NetInput")
            return false;
        // Only actual gameplay script components run in predicted ticks.
        return IsGameplayScript(symbol);
    }

    /// <summary>An ECS system's Update(entity, ref data..., TickInput, deltaTime): run on the server and predicted on
    /// clients like a script's tick.</summary>
    private static bool IsEcsSystemTick(MethodDeclarationSyntax method, SemanticModel semantic)
    {
        if (method.Identifier.ValueText != "Update")
            return false;
        IMethodSymbol? symbol = semantic.GetDeclaredSymbol(method);
        if (symbol is null || !symbol.IsOverride || !symbol.Parameters.Any(p => p.Type.ToDisplayString() == "Tallow.TickInput"))
            return false;
        for (INamedTypeSymbol? current = symbol.ContainingType; current is not null; current = current.BaseType)
            if (current.OriginalDefinition.ToDisplayString() == "Tallow.EcsSystemBase")
                return true;
        return false;
    }
}
