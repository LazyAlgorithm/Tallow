using Tallow;
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
        // Mirror FromEditor's full trusted API snapshot, including the
        // engine-build generated properties/methods. Exclude obj/bin SDK
        // output; those aren't user-facing API source files.
        string apiRoot = Path.GetFullPath(Path.Combine("Managed", "Tallow.API"));
        if (!File.Exists(Path.Combine(apiRoot, "Script.cs")))
            throw new FileNotFoundException("Test requires the trusted gameplay API source.",
                Path.Combine(apiRoot, "Script.cs"));
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
                sources = Directory.EnumerateFiles(apiRoot, "*.cs", SearchOption.AllDirectories)
                    .Where(path => !Path.GetRelativePath(apiRoot, path)
                        .Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                        .Any(segment => segment is "obj" or "bin"))
                    .Select(path => new { path, text = File.ReadAllText(path) })
                    .Prepend(new { path = source, text = code })
                    .ToArray()
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

    private static void TestPersistentServer(string service)
    {
        string root = Path.Combine(Path.GetTempPath(),
            "tallow-roslyn-server-" + Guid.NewGuid());
        string project = Path.Combine(root, "project");
        string source = Path.Combine(project, "src");
        string queue = Path.Combine(root, "queue");
        string engine = Directory.GetCurrentDirectory();
        Directory.CreateDirectory(source);
        Directory.CreateDirectory(queue);
        string file = Path.Combine(source, "Mover.cs");
        File.WriteAllText(file, """
            using Tallow;
            [Component] public sealed class Mover : Script
            {
                public override void Update(TickInput input, float deltaTime)
                { Transform.Position += Vector3.UnitX * deltaTime; }
            }
            """);
        var start = new ProcessStartInfo("dotnet")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (string arg in new[] { service, "--serve", queue, "--project",
            project, "--engine-root", engine })
            start.ArgumentList.Add(arg);
        using Process worker = Process.Start(start) ??
            throw new InvalidOperationException("Cannot start persistent Roslyn service.");
        try
        {
            static void PublishRequest(string folder, string content)
            {
                // Mirroring the editor's queue protocol avoids exposing a
                // partially written request.tsv to the persistent worker.
                string pending = Path.Combine(folder, "request.pending");
                File.WriteAllText(pending, content);
                File.Move(pending, Path.Combine(folder, "request.tsv"));
            }

            static void WaitFor(string file, Process worker)
            {
                for (int i = 0; i < 300; i++)
                {
                    if (File.Exists(file))
                        return;
                    if (worker.HasExited)
                        throw new InvalidOperationException("Persistent Roslyn service stopped unexpectedly.");
                    Thread.Sleep(25);
                }
                throw new TimeoutException("Persistent Roslyn service did not respond.");
            }
            WaitFor(Path.Combine(queue, "ready"), worker);
            for (int i = 0; i < 2; i++)
            {
                string folder = Path.Combine(queue, $"request-{i}");
                Directory.CreateDirectory(folder);
                PublishRequest(folder,
                    $"operation\tdiagnostics\nfile\t{file}\ncursor\t0\n");
                string response = Path.Combine(folder, "response.tsv");
                WaitFor(response, worker);
                string result = File.ReadAllText(response);
                if (result.Contains("diagnostic\t") || result.Contains("error\t"))
                    throw new InvalidOperationException(
                        $"FAIL: persistent Roslyn request {i + 1} returned:\n{result}");
                Check($"persistent Roslyn request {i + 1} without restarting .NET", true);
            }
            // Confirm cached syntax is invalidated when a file changes,
            // while reusing the same compiler process and other API trees.
            string goodSource = File.ReadAllText(file);
            string changedSource = goodSource.Replace(
                "Transform.Position += Vector3.UnitX * deltaTime;",
                "Transform.Position = \"invalid\";");
            if (changedSource == goodSource)
                throw new InvalidOperationException(
                    "Persistent Roslyn test fixture did not replace the original source.");
            File.WriteAllText(file, changedSource);
            string invalidFolder = Path.Combine(queue, "request-2");
            Directory.CreateDirectory(invalidFolder);
            PublishRequest(invalidFolder,
                $"operation\tdiagnostics\nfile\t{file}\ncursor\t0\n");
            string invalidResponse = Path.Combine(invalidFolder, "response.tsv");
            WaitFor(invalidResponse, worker);
            string changedResult = File.ReadAllText(invalidResponse);
            if (!changedResult.Contains("CS0029") ||
                !changedResult.Contains("diagnostic\t"))
                throw new InvalidOperationException(
                    "FAIL: persistent Roslyn invalidates changed game source." +
                    "\nActual response:\n" + changedResult +
                    "\nSource read from disk:\n" + File.ReadAllText(file));
            Check("persistent Roslyn invalidates changed game source", true);

            File.WriteAllText(file, goodSource);
            string restoredFolder = Path.Combine(queue, "request-3");
            Directory.CreateDirectory(restoredFolder);
            PublishRequest(restoredFolder,
                $"operation\tdiagnostics\nfile\t{file}\ncursor\t0\n");
            string restoredResponse = Path.Combine(restoredFolder, "response.tsv");
            WaitFor(restoredResponse, worker);
            string restoredResult = File.ReadAllText(restoredResponse);
            Check("persistent Roslyn restores diagnostics after fixing the source",
                !restoredResult.Contains("diagnostic\t") &&
                !restoredResult.Contains("error\t"));

            File.WriteAllText(Path.Combine(queue, "stop"), "stop");
            Check("persistent Roslyn worker stops cleanly", worker.WaitForExit(5000) &&
                worker.ExitCode == 0);
        }
        finally
        {
            if (!worker.HasExited)
                worker.Kill(entireProcessTree: true);
            worker.WaitForExit();
            Directory.Delete(root, recursive: true);
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

            string inherited = "class Parent { public void ParentMethod() {} } " +
                "class Child : Parent { void Go() { this.Par";
            string inheritedResult = Request(service, "completion", inherited, inherited.Length);
            Check("compiler completion includes inherited methods",
                inheritedResult.Contains("completion\tParentMethod"));

            string staticType = "static class StaticUtilities { public static int Calculate() => 1; }" +
                "class Consumer { void Go() { StaticUtilities.Cal";
            string staticResult = Request(service, "completion", staticType, staticType.Length);
            Check("compiler completion includes static methods",
                staticResult.Contains("completion\tCalculate"));

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

            // Beef and .NET implement getters/setters internally, but a
            // gameplay author should see only the property in completion.
            string transformCompletionSource = "using Tallow; " +
                "[Component] public sealed class Probe : Script " +
                "{ void Go() { Transform.Po";
            string transformCompletions = RequestWithApi(service, "completion",
                transformCompletionSource, transformCompletionSource.Length);
            Check("C# completion shows Transform.Position as a property",
                transformCompletions.Contains("completion\tPosition"));
            Check("C# completion hides generated property accessor methods",
                !transformCompletions.Contains("completion\tget_Position") &&
                !transformCompletions.Contains("completion\tset_Position"));

            string ordinaryGetter = "class Probe { public int get_Answer() => 42; " +
                "void Go() { this.get_A";
            string ordinaryGetterCompletions = Request(service, "completion",
                ordinaryGetter, ordinaryGetter.Length);
            Check("C# completion preserves genuine methods named get_*",
                ordinaryGetterCompletions.Contains("completion\tget_Answer"));

            string timeCode = "using Tallow; " +
                "[Component] public sealed class ClockProbe : Script " +
                "{ public override void Start() { float step = Time.DeltaTime; " +
                "long frames = Time.FrameCount; } }";
            string timeDiagnostics = RequestWithApi(service, "diagnostics",
                timeCode, timeCode.Length);
            if (timeDiagnostics.Contains("diagnostic\t"))
                throw new InvalidOperationException(
                    "Generated C# Time properties produced diagnostics:\n" + timeDiagnostics);
            Check("generated C# Time fields appear as typed read-only properties", true);
            string timeCompletion = RequestWithApi(service, "completion",
                "using Tallow; class Probe { void Go() { var fps = Time.Smoo",
                "using Tallow; class Probe { void Go() { var fps = Time.Smoo".Length);
            Check("generated C# Time.SmoothedFps appears in Roslyn autocomplete",
                timeCompletion.Contains("completion\tSmoothedFps") &&
                !timeCompletion.Contains("completion\tget_SmoothedFps"));

            // Generated native wrappers contain private pointer caches and
            // internal rebind helpers; neither belongs in gameplay completion.
            string mathSource = "using Tallow; class Probe { void Go() { var x = Mathf.";
            string mathResults = RequestWithApi(service, "completion",
                mathSource, mathSource.Length);
            Check("public C# Mathf gameplay helpers remain in autocomplete",
                mathResults.Contains("completion\tLerp\t") &&
                mathResults.Contains("completion\tMoveTowards\t") &&
                mathResults.Contains("completion\tSmoothStep\t"));
            Check("generated native pointers and rebind helpers are hidden",
                !mathResults.Contains("completion\ts_Ptr_") &&
                !mathResults.Contains("completion\ts_SetPtr_") &&
                !mathResults.Contains("completion\t__TallowResetGeneratedNativeBindings") &&
                !mathResults.Contains("completion\t__TallowGet_") &&
                !mathResults.Contains("completion\t__TallowSet_"));
            Check("standard .NET math is not duplicated by Tallow.Mathf completion",
                !mathResults.Contains("completion\tAbs\t") &&
                !mathResults.Contains("completion\tSin\t") &&
                !mathResults.Contains("completion\tCos\t") &&
                !mathResults.Contains("completion\tSqrt\t"));
            string userPrivate = "class Demo { private int secret; void Go() { this.se";
            string userResults = Request(service, "completion",
                userPrivate, userPrivate.Length);
            Check("private user gameplay members still appear in their own class",
                userResults.Contains("completion\tsecret\t"));

            string sceneSwitch = "using Tallow; class Demo { void Go() { " +
                "SceneManager.Load(\"Scenes/Example.tscene\"); Application.Quit(); } }";
            string sceneSwitchDiagnostics = RequestWithApi(service, "diagnostics",
                sceneSwitch, sceneSwitch.Length);
            Check("generated SceneManager.Load and Application.Quit are valid C# APIs",
                !sceneSwitchDiagnostics.Contains("diagnostic\t"));

            string guiSource = "using Tallow; [Component] class GuiExample : Script " +
                "{ public override void OnGUI() { if (GUI.Button(GUI.Width - 120f, " +
                "10f, 100f, 30f, \"Respawn\")) { } } }";
            string guiDiagnostics = RequestWithApi(service, "diagnostics",
                guiSource, guiSource.Length);
            Check("generated GUI.Button and read-only viewport dimensions compile in C#",
                !guiDiagnostics.Contains("diagnostic\t"));

            string physicsCode = """
                using Tallow;
                using System.Numerics;
                [Component] class PhysicsProbe : Script
                {
                    public override void Start()
                    {
                        var rb = GetRigidbody();
                        if (rb is { } rigidbody)
                        {
                            rigidbody.AddImpulse(Vector3.UnitY);
                            rigidbody.Velocity = Vector3.UnitX;
                        }
                        var soft = GetSoftBody();
                        if (soft is { } jelly)
                        {
                            jelly.AddForce(Vector3.UnitY);
                            jelly.AddImpulse(Vector3.UnitX);
                            float p = jelly.Pressure;
                            float d = jelly.DeepestDent;
                        }
                        float distance = Scene.RaycastDistance(
                            Vector3.Zero, Vector3.UnitZ, 50f);
                    }
                }
                """;
            string physicsDiagnostics = RequestWithApi(service, "diagnostics",
                physicsCode, physicsCode.Length);
            if (physicsDiagnostics.Contains("diagnostic\t") ||
                physicsDiagnostics.Contains("error\t"))
                throw new InvalidOperationException(
                    "Generated physics / soft-body facades produced diagnostics:\n" + physicsDiagnostics);
            Check("native ECS rigidbodies and Jolt soft bodies compile in C# gameplay", true);

            string castCode = """
                using System.Numerics;
                using Tallow;
                [Component] class CastProbe : Script
                {
                    public override void Start()
                    {
                        PhysicsContact? hit = Scene.Raycast(
                            Vector3.Zero, Vector3.UnitZ, 10f);
                        PhysicsContact? sphere = Scene.SphereCast(
                            Vector3.Zero, 0.5f, Vector3.UnitZ, 10f);
                        if (GetSoftBody() is { } soft)
                        {
                            SoftBodyKind? kind = soft.Kind;
                            int vertices = soft.SimulatedVertexCount;
                            bool sleeping = soft.IsSleeping;
                        }
                        if (GetRigidbody() is { } body && body.IsSleeping)
                        {
                        }
                    }
                }
                """;
            string castDiagnostics = RequestWithApi(service, "diagnostics",
                castCode, castCode.Length);
            if (castDiagnostics.Contains("diagnostic\t"))
                throw new InvalidOperationException(
                    "Generated raycast and SoftBody metadata API produced diagnostics:\n" +
                    castDiagnostics);
            Check("raycast, sphere cast and native SoftBody metadata C# facade compile", true);

            // The native hit payload must be truly blittable on both Windows
            // and Linux; future generator changes may not alter the ABI.
            Check("PhysicsQueryHit has a stable 48-byte C ABI",
                System.Runtime.InteropServices.Marshal.SizeOf<PhysicsQueryHit>() == 48 &&
                System.Runtime.InteropServices.Marshal.OffsetOf<PhysicsQueryHit>(
                    nameof(PhysicsQueryHit.PointX)).ToInt32() == 8 &&
                System.Runtime.InteropServices.Marshal.OffsetOf<PhysicsQueryHit>(
                    nameof(PhysicsQueryHit.Flags)).ToInt32() == 44);
            string detailedHit = """
                using System.Numerics;
                using Tallow;
                [Component] class HitProbe : Script
                {
                    public override void Start()
                    {
                        PhysicsHit? ray = Scene.RaycastHit(Vector3.Zero, Vector3.UnitZ, 10);
                        PhysicsHit? sphere = Scene.SphereCastHit(
                            Vector3.Zero, 0.4f, Vector3.UnitZ, 10);
                        if (sphere is { Normal: { } surfaceNormal })
                        {
                            Vector3 surface = surfaceNormal;
                        }
                    }
                }
                """;
            string detailedDiagnostics = RequestWithApi(service, "diagnostics",
                detailedHit, detailedHit.Length);
            if (detailedDiagnostics.Contains("diagnostic\t"))
                throw new InvalidOperationException(
                    "Generated PhysicsQueryHit and PhysicsHit produced diagnostics:\n" +
                    detailedDiagnostics);
            Check("structured Jolt hit C# facade compiles", true);

            string colliderCode = """
                using Tallow;
                using System.Numerics;
                [Component] class ColliderProbe : Script
                {
                    public override void Start()
                    {
                        int count = ColliderCount;
                        for (int i = 0; i < count; i++)
                        {
                            ColliderHandle? collider = GetCollider(i);
                            if (collider is { } c)
                            {
                                ColliderKind? kind = c.Kind;
                                Vector3 center = c.Center;
                                float? radius = c.SphereRadius;
                                Vector3? size = c.BoxSize;
                            }
                        }
                        if (GetSoftBody() is { } soft)
                        {
                            soft.Stiffness = 0.75f;
                            soft.WobbleDamping = 4f;
                        }
                    }
                }
                """;
            string colliderDiagnostics = RequestWithApi(service, "diagnostics",
                colliderCode, colliderCode.Length);
            if (colliderDiagnostics.Contains("diagnostic\t"))
                throw new InvalidOperationException(
                    "Generated collider and soft-body control API produced diagnostics:\n" +
                    colliderDiagnostics);
            Check("indexed native collider and soft-body parameter C# API compiles", true);

            string jointCode = """
                using Tallow;
                using System.Numerics;
                [Component] class JointProbe : Script
                {
                    public override void Start()
                    {
                        Joint? joint = GetJoint();
                        if (joint is { } constraint)
                        {
                            float limit = constraint.SwingLimit;
                            bool active = constraint.IsConnected;
                            Rigidbody? other = constraint.ConnectedTo;
                            constraint.SwingLimit = 30f;
                        }
                        var rigidbody = GetRigidbody();
                        if (rigidbody is { } rb)
                        {
                            Joint? created = Joint.Connect(rb, rb,
                                Vector3.Zero, Vector3.UnitY);
                        }
                    }
                }
                """;
            string jointDiagnostics = RequestWithApi(service, "diagnostics",
                jointCode, jointCode.Length);
            if (jointDiagnostics.Contains("diagnostic\t"))
                throw new InvalidOperationException(
                    "Generated ECS Joint bridge produced diagnostics:\n" + jointDiagnostics);
            Check("native Jolt joint C# API and ECS JointData handle compile", true);

            string logCode = "using Tallow; class Demo { void Go() { Log.Info(\"hello\"); } }";
            string logDiagnostics = RequestWithApi(service, "diagnostics", logCode, logCode.Length);
            Check("generated Log.Info accepts managed C# strings",
                !logDiagnostics.Contains("diagnostic\t"));
            string logCompletion = RequestWithApi(service, "completion",
                "using Tallow; class Demo { void Go() { Log.War",
                "using Tallow; class Demo { void Go() { Log.War".Length);
            Check("generated Log.Warning appears in Roslyn autocomplete",
                logCompletion.Contains("completion\tWarning"));

            // Preserve the original editor's network (purple) and performance
            // (cyan) diagnostics when the gameplay language is C#.
            string networkedTick = """
                using Tallow;
                [Component] public sealed class NetProbe : Script
                {
                    public override void Update(TickInput input, float deltaTime)
                    {
                        var nondeterministic = DateTime.UtcNow;
                        var random = new System.Random();
                        var allocation = new System.Text.StringBuilder();
                        var vector = new Vector3(1, 2, 3);
                    }
                }
                """;
            string tickWarnings = RequestWithApi(service, "diagnostics",
                networkedTick, networkedTick.Length);
            Check("C# replay analysis uses the existing purple deterministic warning category",
                tickWarnings.Contains("TAL-NET002") &&
                tickWarnings.Contains("TAL-NET001") &&
                tickWarnings.Contains("\twarning\tTAL-NET002") &&
                tickWarnings.Contains("\tdeterminism"));
            Check("C# hot-path analysis uses existing cyan optimization warning category",
                tickWarnings.Contains("TAL-PERF001") &&
                tickWarnings.Contains("\toptimization"));
            Check("C# value-type Vector3 construction does not count as a heap allocation",
                tickWarnings.Split("TAL-PERF001").Length == 2);
            string notNetworked = networkedTick.Replace(
                "public override void Update(TickInput input, float deltaTime)",
                "public override void Start()");
            string noTickWarnings = RequestWithApi(service, "diagnostics",
                notNetworked, notNetworked.Length);
            Check("C# engine warnings do not flag non-predicted Start methods",
                !noTickWarnings.Contains("TAL-NET") && !noTickWarnings.Contains("TAL-PERF"));

            string localFrame = """
                using Tallow;
                [Component] public sealed class FrameProbe : Script
                {
                    public override void LateUpdate(float deltaTime)
                    {
                        var message = new System.Text.StringBuilder();
                        var time = DateTime.UtcNow;
                    }
                    public override void FixedUpdate(float deltaTime)
                    {
                        var values = new float[32];
                    }
                    public override void OnLocalUpdate()
                    {
                        var values = new int[8];
                    }
                }
                """;
            string frameWarnings = RequestWithApi(service, "diagnostics",
                localFrame, localFrame.Length);
            Check("C# performance hints include LateUpdate, FixedUpdate and OnLocalUpdate",
                frameWarnings.Split("TAL-PERF001").Length == 4);
            Check("local frame callbacks do not get misleading network replay warnings",
                !frameWarnings.Contains("TAL-NET"));

            string componentLookup = """
                using Tallow;
                [Component] public sealed class LookupProbe : Script
                {
                    public override void Update(TickInput input, float deltaTime)
                    {
                        for (int i = 0; i < 10; i++)
                            GameObject.GetComponent<LookupProbe>();
                    }
                }
                """;
            string componentWarnings = RequestWithApi(service, "diagnostics",
                componentLookup, componentLookup.Length);
            Check("C# analyzer warns about Tallow component lookups in hot loops",
                componentWarnings.Contains("TAL-PERF002") &&
                componentWarnings.Contains("\toptimization"));

            string unrelatedLookup = """
                using Tallow;
                [Component] public sealed class LookupProbe : Script
                {
                    public int GetComponent() => 42;
                    public override void Update(TickInput input, float deltaTime)
                    {
                        for (int i = 0; i < 10; i++)
                            GetComponent();
                    }
                }
                """;
            string unrelatedWarnings = RequestWithApi(service, "diagnostics",
                unrelatedLookup, unrelatedLookup.Length);
            Check("C# analyzer ignores unrelated user methods named GetComponent",
                !unrelatedWarnings.Contains("TAL-PERF002"));

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

            TestPersistentServer(service);
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
