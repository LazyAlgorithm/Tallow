using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Tallow.LanguageService.Tests;

/// <summary>Dependency-free integration tests for C# semantic requests.</summary>
internal static class Program
{
    private static int _passed;

    private static string Request(string service, string operation, string code, int cursor)
    {
        string temporary = Path.Combine(Path.GetTempPath(), "tallow-csharp-semantic-" + Guid.NewGuid());
        Directory.CreateDirectory(temporary);
        try
        {
            string source = Path.Combine(temporary, "SemanticSample.cs");
            string request = Path.Combine(temporary, "request.json");
            string response = Path.Combine(temporary, "response.tsv");
            var payload = new
            {
                operation,
                file = source,
                cursor = Encoding.UTF8.GetByteCount(code.AsSpan(0, cursor)),
                sources = new[] { new { path = source, text = code } }
            };
            File.WriteAllText(request, JsonSerializer.Serialize(payload));
            var start = new ProcessStartInfo("dotnet") { UseShellExecute = false };
            start.ArgumentList.Add(service);
            start.ArgumentList.Add(request);
            start.ArgumentList.Add(response);
            using var process = Process.Start(start) ??
                throw new InvalidOperationException("Cannot launch Roslyn worker");
            process.WaitForExit();
            if (process.ExitCode != 0)
                throw new InvalidOperationException($"Roslyn worker failed: {File.ReadAllText(response)}");
            return File.ReadAllText(response);
        }
        finally
        {
            Directory.Delete(temporary, recursive: true);
        }
    }

    private static string RequestWithApi(string service, string operation, string code, int cursor)
    {
        // Reproduce the editor's actual semantic compilation: game source
        // plus Tallow.API source, not just an isolated Vector3 expression.
        string apiPath = Path.GetFullPath(
            Path.Combine("Managed", "Tallow.API", "Script.cs"));
        if (!File.Exists(apiPath))
            throw new FileNotFoundException("Test requires the trusted gameplay API source.", apiPath);
        string temporary = Path.Combine(Path.GetTempPath(),
            "tallow-csharp-api-semantic-" + Guid.NewGuid());
        Directory.CreateDirectory(temporary);
        try
        {
            string source = Path.Combine(temporary, "VectorOperator.cs");
            string request = Path.Combine(temporary, "request.json");
            string response = Path.Combine(temporary, "response.tsv");
            var payload = new
            {
                operation,
                file = source,
                cursor = Encoding.UTF8.GetByteCount(code.AsSpan(0, cursor)),
                sources = new[]
                {
                    new { path = source, text = code },
                    new { path = apiPath, text = File.ReadAllText(apiPath) }
                }
            };
            File.WriteAllText(request, JsonSerializer.Serialize(payload));
            var info = new ProcessStartInfo("dotnet") { UseShellExecute = false };
            info.ArgumentList.Add(service);
            info.ArgumentList.Add(request);
            info.ArgumentList.Add(response);
            using var process = Process.Start(info) ??
                throw new InvalidOperationException("Could not start Roslyn with gameplay API.");
            process.WaitForExit();
            if (process.ExitCode != 0)
                throw new InvalidOperationException(
                    $"Roslyn gameplay API worker failed: {File.ReadAllText(response)}");
            return File.ReadAllText(response);
        }
        finally
        {
            Directory.Delete(temporary, recursive: true);
        }
    }

    private static void Check(string label, bool condition)
    {
        if (!condition)
            throw new InvalidOperationException($"FAIL: {label}");
        _passed++;
        Console.WriteLine($"PASS: {label}");
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length != 1 || !File.Exists(args[0]))
                throw new ArgumentException("Pass the compiled Tallow.LanguageService.dll.");

            string service = Path.GetFullPath(args[0]);
            string badSource = "class Example { int count = \"wrong\"; }";
            string diagnostics = Request(service, "diagnostics", badSource, badSource.Length);
            Check("compiler diagnostics", diagnostics.Contains("CS0029"));

            string vectorSource = "class Example { Vector3 v = new(1, 2, 3); " +
                "void Go() { v += Vector3.UnitX * 2f; v *= 0.5f; } }";
            string vectorDiagnostics = Request(service, "diagnostics", vectorSource,
                vectorSource.Length);
            Check("implicit vectors and arithmetic in Roslyn",
                !vectorDiagnostics.Contains("diagnostic\t"));

            string gameplayVector = @"using Tallow;
[Component]
public sealed class CubeMover : Script
{
    public float Speed = 2f;
    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Position += Vector3.UnitX * Speed * deltaTime;
        Transform.Position = Transform.Position + new Vector3(1, 0, 0);
    }
}";
            string gameplayDiagnostics = RequestWithApi(
                service, "diagnostics", gameplayVector, gameplayVector.Length);
            Check("gameplay Transform.Position += Vector3 * float operators",
                !gameplayDiagnostics.Contains("diagnostic\t"));

            string memberSource = "class Player { public int Speed; }\n" +
                "class Example { void Go() { Player player = new(); player.S";
            string completions = Request(service, "completion", memberSource, memberSource.Length);
            Check("member completion", completions.Contains("completion\tSpeed"));

            string source = "class Example { int count; void Go() { count = 1; } }";
            int cursor = source.LastIndexOf("count", StringComparison.Ordinal) + "count".Length;
            string definition = Request(service, "definition", source, cursor);
            Check("go to definition", definition.Contains("definition\t"));

            string references = Request(service, "references", source, cursor);
            Check("compiler symbol references", references.Split("reference\t").Length - 1 >= 2);

            string signatureSource = "class Example { void Move(float speed) {} " +
                "void Go() { Move(1); } }";
            string signature = Request(service, "signature", signatureSource,
                signatureSource.IndexOf("Move(1)", StringComparison.Ordinal) + "Move(".Length);
            Check("signature information", signature.Contains("signature\t"));

            string completionSignature = Request(service, "completion", signatureSource,
                signatureSource.IndexOf("Move(1)", StringComparison.Ordinal) + "Move(".Length);
            Check("parameter hints in completion popup", completionSignature.Contains("signature\t"));

            string unicodeSource = "class 猫 { int 数; void Go() { 数 = 1; } }";
            int unicodeCursor = unicodeSource.LastIndexOf('数') + 1;
            string unicodeReferences = Request(service, "references", unicodeSource, unicodeCursor);
            Check("UTF-8 source offsets", unicodeReferences.Split("reference\t").Length - 1 >= 2);

            Console.WriteLine($"Passed {_passed} Roslyn integration tests.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
    }
}
