using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Tallow.BindingGen;

/// <summary>
/// Engine-build-only compiler manifest consumer. Generates the *same* approved
/// public API as C ABI Beef wrappers and managed C# methods. No Beef source
/// regexes, hand-maintained symbol lists, or per-game binding regeneration.
/// </summary>
internal static class Program
{
    private sealed record Parameter(string Name, string Type);
    private sealed record Method(string Owner, string Name, string Result,
        IReadOnlyList<Parameter> Parameters, string Id, bool IsField, bool CanWrite);
    private static readonly Regex Identifier = new(
        @"^[A-Za-z_][A-Za-z0-9_]*$", RegexOptions.CultureInvariant);

    private static string Required(string[] args, string option)
    {
        int i = Array.IndexOf(args, option);
        if (i < 0 || i + 1 == args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
            throw new ArgumentException($"Missing {option}.");
        return args[i + 1];
    }

    private static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)))[..16].ToLowerInvariant();

    private static bool IsType(string type, bool allowVoid = false) =>
        type is "bool" or "int" or "uint" or "long" or "ulong" or
            "float" or "double" or "string" or "System.Numerics.Vector2" or
            "System.Numerics.Vector3" or "System.Numerics.Vector4" or
            "System.Numerics.Quaternion" ||
        (allowVoid && type == "void");

    private static int Dimensions(string type) => type switch
    {
        "System.Numerics.Vector2" => 2,
        "System.Numerics.Vector3" => 3,
        "System.Numerics.Vector4" or "System.Numerics.Quaternion" => 4,
        _ => 0
    };

    private static string CSharpType(string type) => type == "int" ? "int" :
        type.StartsWith("System.Numerics.Vector", StringComparison.Ordinal) ?
            type : type;

    private static string NativeType(string type) =>
        Dimensions(type) > 0 ? "float*" : type switch
        {
            "bool" or "int" => "int32",
            "uint" => "uint32",
            "long" => "int64",
            "ulong" => "uint64",
            _ => type
        };

    private static string CAbiType(string type) =>
        Dimensions(type) > 0 ? "float*" : type == "bool" ? "int" : type;

    private static List<Method> Parse(string manifest)
    {
        string[] lines = manifest.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        if (lines.Length < 1 || lines[0] != "TALLOW_CSHARP_API_V1")
            throw new FormatException("Unknown C# exposure manifest version.");
        List<Method> methods = [];
        HashSet<string> signatures = new(StringComparer.Ordinal);
        HashSet<string> ids = new(StringComparer.Ordinal);
        for (int i = 1; i < lines.Length; i++)
        {
            if (lines[i].Length == 0 && i == lines.Length - 1)
                break;
            string[] fields = lines[i].Split('\t');
            bool isField = fields[0] == "field";
            if (fields.Length < 4 || fields[0] is not ("method" or "field") ||
                isField && (fields.Length != 5 || fields[4] is not ("get" or "getset")))
                throw new FormatException($"Manifest line {i + 1}: expected annotated method or read-only field.");
            string owner = fields[1], name = fields[2], result = fields[3];
            // Stage 1 intentionally exposes only public Tallow-root static
            // classes. Nested types/properties/instance handles follow later.
            if (!owner.StartsWith("Tallow.", StringComparison.Ordinal) ||
                !Identifier.IsMatch(owner["Tallow.".Length..]) ||
                !Identifier.IsMatch(name) || !IsType(result, allowVoid: !isField) ||
                result == "string" ||
                isField && name == owner["Tallow.".Length..])
                throw new FormatException($"Manifest line {i + 1}: unsupported owner or return type: {owner}.{name}.");
            bool canWrite = isField && fields[4] == "getset";
            if (canWrite && Dimensions(result) != 0)
                throw new FormatException($"Manifest line {i + 1}: vector field setters are not supported yet.");
            if (isField && result == "string")
                throw new FormatException($"Manifest line {i + 1}: string-returning fields are not supported yet.");
            List<Parameter> parameters = [];
            for (int j = 4; j < (isField ? 4 : fields.Length); j++)
            {
                int colon = fields[j].IndexOf(':');
                if (colon <= 0)
                    throw new FormatException($"Manifest line {i + 1}: malformed parameter {j - 3}.");
                string paramName = fields[j][..colon], type = fields[j][(colon + 1)..];
                if (!Identifier.IsMatch(paramName) || !IsType(type) ||
                    parameters.Any(p => p.Name == paramName))
                    throw new FormatException($"Manifest line {i + 1}: invalid parameter {fields[j]}.");
                parameters.Add(new(paramName, type));
            }
            string signature = string.Join("|",
                new[] { owner, name, result }.Concat(parameters.Select(p => p.Type)));
            if (isField)
                signature = "field|" + signature;
            string id = Hash(signature);
            if (!signatures.Add(signature) || !ids.Add(id))
                throw new FormatException($"Duplicate or colliding exposed method signature: {signature}.");
            methods.Add(new(owner, name, result, parameters, id, isField, canWrite));
        }
        return methods.OrderBy(m => m.Owner, StringComparer.Ordinal)
            .ThenBy(m => m.Name, StringComparer.Ordinal)
            .ThenBy(m => string.Join("|", m.Parameters.Select(p => p.Type)),
                StringComparer.Ordinal).ToList();
    }

    private static string ArgumentExpression(Parameter p, int i) =>
        p.Type == "string" ? $"s{i}" :
        p.Type == "bool" ? $"(p{i} != 0)" :
        Dimensions(p.Type) != 0 ? $"v{i}" : $"p{i}";

    private static string EmitBeef(IReadOnlyList<Method> methods, string version)
    {
        StringBuilder text = new();
        text.AppendLine("// <auto-generated> CSharpExpose native ABI. Do not edit. </auto-generated>")
            .AppendLine("using System;").AppendLine().AppendLine("namespace Tallow;")
            .AppendLine();
        foreach (IGrouping<string, Method> group in methods.GroupBy(m => m.Owner))
        {
            text.AppendLine($"extension {group.Key["Tallow.".Length..]}").AppendLine("{");
            foreach (Method m in group)
            {
                string symbol = $"CSharpApi_{m.Id}";
                List<string> args = [];
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    if (p.Type == "string")
                    {
                        args.Add($"char8* p{i}");
                        args.Add($"int32 p{i}Length");
                    }
                    else
                        args.Add($"{NativeType(p.Type)} p{i}");
                }
                if (Dimensions(m.Result) > 0)
                    args.Add("float* result");
                string returnType = Dimensions(m.Result) > 0 ? "void" : NativeType(m.Result);
                text.AppendLine("\t[Export, CLink, Reflect, AlwaysInclude, CSharpApiExport]")
                    .AppendLine($"\tpublic static {returnType} {symbol}({string.Join(", ", args)})")
                    .AppendLine("\t{");
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    int count = Dimensions(p.Type);
                    if (p.Type == "string")
                    {
                        text.AppendLine($"\t\tif (p{i}Length < 0 || (p{i}Length > 0 && p{i} == null)) return{(returnType == "void" ? ";" : " default;")}");
                        text.AppendLine($"\t\tStringView s{i} = .(p{i}, p{i}Length);");
                    }
                    if (count > 0)
                    {
                        string name = p.Type == "System.Numerics.Quaternion" ?
                            "Quaternion" : $"Vector{count}";
                        text.AppendLine($"\t\tif (p{i} == null) return{(returnType == "void" ? ";" : " default;")}");
                        text.AppendLine($"\t\t{name} v{i} = .({string.Join(", ", Enumerable.Range(0, count).Select(j => $"p{i}[{j}]"))});");
                    }
                }
                if (Dimensions(m.Result) > 0)
                    text.AppendLine("\t\tif (result == null) return;");
                string call = m.IsField ? $"{m.Owner}.{m.Name}" :
                    $"{m.Owner}.{m.Name}({string.Join(", ", m.Parameters.Select(ArgumentExpression))})";
                if (m.Result == "void")
                    text.AppendLine($"\t\t{call};");
                else if (m.Result == "bool")
                    text.AppendLine($"\t\treturn {call} ? 1 : 0;");
                else if (Dimensions(m.Result) > 0)
                {
                    text.AppendLine($"\t\tlet value = {call};");
                    string[] components = ["x", "y", "z", "w"];
                    for (int i = 0; i < Dimensions(m.Result); i++)
                        text.AppendLine($"\t\tresult[{i}] = value.{components[i]};");
                }
                else
                    text.AppendLine($"\t\treturn {call};");
                text.AppendLine("\t}").AppendLine();
                if (m.CanWrite)
                {
                    string setter = $"CSharpApi_{Hash("set|" + m.Id)}";
                    string type = NativeType(m.Result);
                    text.AppendLine("\t[Export, CLink, Reflect, AlwaysInclude, CSharpApiExport]")
                        .AppendLine($"\tpublic static void {setter}({type} value)")
                        .AppendLine("\t{")
                        .AppendLine($"\t\t{m.Owner}.{m.Name} = {(m.Result == "bool" ? "(value != 0)" : "value")};")
                        .AppendLine("\t}").AppendLine();
                }
            }
            text.AppendLine("}").AppendLine();
        }
        // A version entrypoint lets C# reject mismatched binaries before
        // invoking any methods. Names are stable for identical manifests.
        text.AppendLine("extension CSharpBindingManifest").AppendLine("{")
            .AppendLine("\t[Export, CLink, Reflect, AlwaysInclude, CSharpApiExport]")
            .AppendLine($"\tpublic static int32 CSharpApiVersion_{version}() => 1;")
            .AppendLine("}");
        return text.ToString();
    }

    private static string EmitCSharp(IReadOnlyList<Method> methods, string version)
    {
        StringBuilder text = new();
        text.AppendLine("// <auto-generated> CSharpExpose gameplay API. Do not edit. </auto-generated>")
            .AppendLine("using System;").AppendLine("using System.Numerics;")
            .AppendLine("using System.Text;")
            .AppendLine().AppendLine("namespace Tallow;").AppendLine();
        text.AppendLine("internal static unsafe partial class GeneratedNativeApi")
            .AppendLine("{").AppendLine("\tprivate static bool sVerified;")
            .AppendLine("\tstatic partial void ResetVersion()")
            .AppendLine("\t{")
            .AppendLine("\t\tsVerified = false;");
        // Reset every cached unmanaged function pointer when the editor
        // rebinds a scene or reloads the runtime. This is a one-time cost,
        // not an extra lookup/branch in the per-frame gameplay hot path.
        foreach (string owner in methods.Select(m => m.Owner).Distinct(StringComparer.Ordinal))
            text.AppendLine($"\t\t{owner["Tallow.".Length..]}.__TallowResetGeneratedNativeBindings();");
        text.AppendLine("\t}")
            .AppendLine("\tstatic partial void VerifyVersion()")
            .AppendLine("\t{")
            .AppendLine("\t\tif (sVerified) return;")
            .AppendLine($"\t\tnint ptr = ResolveRaw(\"CSharpApiVersion_{version}\");")
            .AppendLine("\t\tif (ptr == 0 || ((delegate* unmanaged[Cdecl]<int>)ptr)() != 1)")
            .AppendLine("\t\t\tthrow new InvalidOperationException(\"The precompiled native Tallow C# API does not match its managed bindings.\");")
            .AppendLine("\t\tsVerified = true;")
            .AppendLine("\t}")
            .AppendLine("}").AppendLine();
        foreach (IGrouping<string, Method> group in methods.GroupBy(m => m.Owner))
        {
            text.AppendLine($"public static unsafe partial class {group.Key["Tallow.".Length..]}")
                .AppendLine("{")
                .AppendLine("\tinternal static void __TallowResetGeneratedNativeBindings()")
                .AppendLine("\t{");
            foreach (Method m in group)
            {
                text.AppendLine($"\t\ts_Ptr_{m.Id} = 0;");
                if (m.CanWrite)
                    text.AppendLine($"\t\ts_SetPtr_{m.Id} = 0;");
            }
            text.AppendLine("\t}");
            foreach (Method m in group)
            {
                string symbol = $"CSharpApi_{m.Id}";
                string cache = $"s_Ptr_{m.Id}";
                text.AppendLine($"\tprivate static nint {cache};");
                string publicArgs = string.Join(", ", m.Parameters.Select(p => $"{CSharpType(p.Type)} {p.Name}"));
                if (m.IsField)
                {
                    text.AppendLine($"\tpublic static {CSharpType(m.Result)} {m.Name}")
                        .AppendLine("\t{")
                        .AppendLine($"\t\tget => __TallowGet_{m.Id}();");
                    if (m.CanWrite)
                        text.AppendLine($"\t\tset => __TallowSet_{m.Id}(value);");
                    text.AppendLine("\t}");
                }
                text.AppendLine($"\t{(m.IsField ? "private" : "public")} static {CSharpType(m.Result)} {(m.IsField ? $"__TallowGet_{m.Id}" : m.Name)}({publicArgs})")
                    .AppendLine("\t{")
                    .AppendLine($"\t\tnint ptr = {cache};")
                    .AppendLine($"\t\tif (ptr == 0) {cache} = ptr = GeneratedNativeApi.Resolve(\"{symbol}\");");
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    int count = Dimensions(p.Type);
                    if (p.Type == "string")
                        text.AppendLine($"\t\tbyte[] p{i}Utf8 = Encoding.UTF8.GetBytes({p.Name} ?? string.Empty);");
                    if (count > 0)
                    {
                        string[] components = ["X", "Y", "Z", "W"];
                        text.AppendLine($"\t\tfloat* p{i} = stackalloc float[{count}] {{ {string.Join(", ", components.Take(count).Select(c => p.Name + "." + c))} }};");
                    }
                }
                if (Dimensions(m.Result) > 0)
                    text.AppendLine($"\t\tfloat* result = stackalloc float[{Dimensions(m.Result)}];");
                List<string> nativeArgs = [];
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    if (p.Type == "string")
                    {
                        nativeArgs.Add($"p{i}");
                        nativeArgs.Add($"p{i}Utf8.Length");
                    }
                    else
                        nativeArgs.Add(Dimensions(p.Type) > 0 ? $"p{i}" :
                            p.Type == "bool" ? $"({p.Name} ? 1 : 0)" : p.Name);
                }
                if (Dimensions(m.Result) > 0)
                    nativeArgs.Add("result");
                List<string> types = [];
                foreach (Parameter p in m.Parameters)
                {
                    if (p.Type == "string")
                    {
                        types.Add("byte*");
                        types.Add("int");
                    }
                    else
                        types.Add(CAbiType(p.Type));
                }
                if (Dimensions(m.Result) > 0)
                    types.Add("float*");
                types.Add(Dimensions(m.Result) > 0 ? "void" : CAbiType(m.Result));
                string call = $"((delegate* unmanaged[Cdecl]<{string.Join(", ", types)}>)ptr)({string.Join(", ", nativeArgs)})";
                // The UTF-8 arrays remain pinned for this single native call.
                bool hasStrings = m.Parameters.Any(p => p.Type == "string");
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                    if (p.Type == "string")
                        text.AppendLine($"\t\tfixed (byte* p{i} = p{i}Utf8)");
                if (hasStrings)
                    text.AppendLine("\t\t{");
                if (m.Result == "void")
                    text.AppendLine($"\t\t{call};");
                else if (m.Result == "bool")
                    text.AppendLine($"\t\treturn {call} != 0;");
                else if (Dimensions(m.Result) > 0)
                    text.AppendLine($"\t\t{call};")
                        .AppendLine($"\t\treturn new {CSharpType(m.Result)}({string.Join(", ", Enumerable.Range(0, Dimensions(m.Result)).Select(i => $"result[{i}]"))});");
                else
                    text.AppendLine($"\t\treturn {call};");
                if (hasStrings)
                    text.AppendLine("\t\t}");
                text.AppendLine("\t}").AppendLine();
                if (m.CanWrite)
                {
                    string setter = $"CSharpApi_{Hash("set|" + m.Id)}";
                    string abi = CAbiType(m.Result);
                    text.AppendLine($"\tprivate static nint s_SetPtr_{m.Id};")
                        .AppendLine($"\tprivate static void __TallowSet_{m.Id}({CSharpType(m.Result)} value)")
                        .AppendLine("\t{")
                        .AppendLine($"\t\tnint ptr = s_SetPtr_{m.Id};")
                        .AppendLine($"\t\tif (ptr == 0) s_SetPtr_{m.Id} = ptr = GeneratedNativeApi.Resolve(\"{setter}\");")
                        .AppendLine($"\t\t((delegate* unmanaged[Cdecl]<{abi}, void>)ptr)({(m.Result == "bool" ? "(value ? 1 : 0)" : "value")});")
                        .AppendLine("\t}").AppendLine();
                }
            }
            text.AppendLine("}").AppendLine();
        }
        return text.ToString();
    }

    private static void WriteIfChanged(string path, string data)
    {
        if (File.Exists(path) && File.ReadAllText(path) == data)
            return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, data, new UTF8Encoding(false));
    }

    private static int SelfTest()
    {
        const string sample = "TALLOW_CSHARP_API_V1\nmethod\tTallow.CSharpBindingFixture\tAverage\tfloat\ta:float\tb:float\n";
        List<Method> parsed = Parse(sample);
        string version = Hash(sample);
        string beef = EmitBeef(parsed, version);
        string csharp = EmitCSharp(parsed, version);
        if (parsed.Count != 1 || !beef.Contains("CSharpBindingFixture.Average(p0, p1);") ||
            !beef.Contains("CSharpApiVersion_") ||
            !csharp.Contains("public static unsafe partial class CSharpBindingFixture") ||
            !csharp.Contains("public static float Average(float a, float b)") ||
            !csharp.Contains("delegate* unmanaged[Cdecl]<float, float, float>") ||
            !csharp.Contains("__TallowResetGeneratedNativeBindings()") ||
            !csharp.Contains("s_Ptr_17858942906a9c6f = 0;") ||
            !beef.Contains("CSharpApiExport]") ||
            beef.Contains("NativeOnly") || csharp.Contains("NativeOnly"))
            throw new Exception("The fixture's native and managed exports differ.");
        string vectors = "TALLOW_CSHARP_API_V1\nmethod\tTallow.VectorChecks\tScale\tSystem.Numerics.Vector3\tvalue:System.Numerics.Vector3\tfactor:float\n";
        List<Method> v = Parse(vectors);
        if (!EmitBeef(v, Hash(vectors)).Contains("result[2] = value.z;") ||
            !EmitCSharp(v, Hash(vectors)).Contains("float* result = stackalloc float[3];"))
            throw new Exception("Vector ABI lowering failed.");
        const string quaternion = "TALLOW_CSHARP_API_V1\nmethod\tTallow.RotationMath\tEulerDegrees\tSystem.Numerics.Quaternion\tdegrees:System.Numerics.Vector3\nmethod\tTallow.RotationMath\tToEulerDegrees\tSystem.Numerics.Vector3\trotation:System.Numerics.Quaternion\n";
        List<Method> quaternionMethods = Parse(quaternion);
        string beefQuaternion = EmitBeef(quaternionMethods, Hash(quaternion));
        string managedQuaternion = EmitCSharp(quaternionMethods, Hash(quaternion));
        if (quaternionMethods.Count != 2 ||
            !beefQuaternion.Contains("Quaternion v0 = .(p0[0], p0[1], p0[2], p0[3]);") ||
            !beefQuaternion.Contains("result[3] = value.w;") ||
            !managedQuaternion.Contains("public static System.Numerics.Quaternion EulerDegrees(System.Numerics.Vector3 degrees)") ||
            !managedQuaternion.Contains("public static System.Numerics.Vector3 ToEulerDegrees(System.Numerics.Quaternion rotation)") ||
            !managedQuaternion.Contains("return new System.Numerics.Quaternion(result[0], result[1], result[2], result[3]);") ||
            !managedQuaternion.Contains("float* p0 = stackalloc float[4] { rotation.X, rotation.Y, rotation.Z, rotation.W };"))
            throw new Exception("Quaternion ABI lowering failed.");
        const string numeric = "TALLOW_CSHARP_API_V1\nmethod\tTallow.NumericChecks\tHash\tulong\tseed:uint\twide:long\tvalue:double\n";
        List<Method> numericMethods = Parse(numeric);
        string nativeNumeric = EmitBeef(numericMethods, Hash(numeric));
        string managedNumeric = EmitCSharp(numericMethods, Hash(numeric));
        if (!nativeNumeric.Contains("public static uint64 CSharpApi_") ||
            !nativeNumeric.Contains("uint32 p0, int64 p1, double p2") ||
            !managedNumeric.Contains("public static ulong Hash(uint seed, long wide, double value)") ||
            !managedNumeric.Contains("delegate* unmanaged[Cdecl]<uint, long, double, ulong>"))
            throw new Exception("Signed/unsigned 32/64-bit and double ABI lowering failed.");
        const string fieldsManifest = "TALLOW_CSHARP_API_V1\nfield\tTallow.Time\tFrameCount\tlong\tget\nfield\tTallow.Time\tDeltaTime\tfloat\tget\n";
        List<Method> fieldBindings = Parse(fieldsManifest);
        string beefFields = EmitBeef(fieldBindings, Hash(fieldsManifest));
        string csharpFields = EmitCSharp(fieldBindings, Hash(fieldsManifest));
        if (fieldBindings.Count != 2 ||
            !beefFields.Contains("return Tallow.Time.FrameCount;") ||
            !beefFields.Contains("return Tallow.Time.DeltaTime;") ||
            !csharpFields.Contains("public static long FrameCount") ||
            !csharpFields.Contains("public static float DeltaTime") ||
            !csharpFields.Contains("get => __TallowGet_") ||
            csharpFields.Contains("public static long get_FrameCount"))
            throw new Exception("Read-only static field/property lowering failed.");
        const string stringManifest = "TALLOW_CSHARP_API_V1\nmethod\tTallow.Log\tInfo\tvoid\ttext:string\n";
        List<Method> stringBindings = Parse(stringManifest);
        string beefString = EmitBeef(stringBindings, Hash(stringManifest));
        string csharpString = EmitCSharp(stringBindings, Hash(stringManifest));
        if (!beefString.Contains("char8* p0, int32 p0Length") ||
            !beefString.Contains("StringView s0 = .(p0, p0Length);") ||
            !csharpString.Contains("public static void Info(string text)") ||
            !csharpString.Contains("Encoding.UTF8.GetBytes(text ?? string.Empty)") ||
            !csharpString.Contains("fixed (byte* p0 = p0Utf8)") ||
            !csharpString.Contains("delegate* unmanaged[Cdecl]<byte*, int, void>"))
            throw new Exception("UTF-8 StringView parameter lowering failed.");
        const string writableManifest = "TALLOW_CSHARP_API_V1\nfield\tTallow.Time\tTimeScale\tfloat\tgetset\n";
        List<Method> writable = Parse(writableManifest);
        string nativeWritable = EmitBeef(writable, Hash(writableManifest));
        string managedWritable = EmitCSharp(writable, Hash(writableManifest));
        if (!nativeWritable.Contains("Tallow.Time.TimeScale = value;") ||
            !managedWritable.Contains("set => __TallowSet_") ||
            !managedWritable.Contains("delegate* unmanaged[Cdecl]<float, void>") ||
            !managedWritable.Contains("s_SetPtr_"))
            throw new Exception("Explicitly writable field setter binding failed.");
        foreach (string invalid in new[]
        {
            "TALLOW_CSHARP_API_V1\nmethod\tTallow.Bad\tOops\tSystem.String\n",
            "TALLOW_CSHARP_API_V1\nmethod\tTallow.Bad\tOops\tfloat\tx:void\n",
            sample + sample.Split('\n')[1] + "\n",
            "TALLOW_CSHARP_API_V1\nmethod\tOther.Bad\tOops\tfloat\n",
            "TALLOW_CSHARP_API_V1\nfield\tTallow.Bad\tBad\tfloat\tget\n",
            "TALLOW_CSHARP_API_V1\nfield\tTallow.Time\tNotSafe\tSystem.String\tget\n",
            "TALLOW_CSHARP_API_V1\nfield\tTallow.Time\tSomething\tfloat\tset\n",
            "TALLOW_CSHARP_API_V1\nmethod\tTallow.Bad\tGetText\tstring\n",
            "TALLOW_CSHARP_API_V1\nfield\tTallow.Bad\tText\tstring\tget\n"
        })
        {
            try { Parse(invalid); throw new Exception("Invalid manifest was accepted."); }
            catch (FormatException) { }
        }
        Console.WriteLine("PASS: CSharpExpose deterministic, opt-in, static fields, scalar/vector and invalid-manifest tests.");
        return 0;
    }

    public static int Main(string[] args)
    {
        try
        {
            if (args.Contains("--self-test"))
                return SelfTest();
            string manifest = File.ReadAllText(Required(args, "--manifest"));
            string root = Path.GetFullPath(Required(args, "--engine-root"));
            List<Method> methods = Parse(manifest);
            string version = Hash(manifest.Replace("\r\n", "\n", StringComparison.Ordinal));
            WriteIfChanged(Path.Combine(root, "Engine/src/Scripting/CSharpBindings.Generated.bf"),
                EmitBeef(methods, version));
            WriteIfChanged(Path.Combine(root, "Managed/Tallow.API/Generated/CSharpBindings.g.cs"),
                EmitCSharp(methods, version));
            Console.WriteLine($"Generated {methods.Count} native/C# bindings (ABI {version}).");
            return 0;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or
            ArgumentException or FormatException or InvalidOperationException)
        {
            Console.Error.WriteLine("CSharpExpose binding generation failed: " + e.Message);
            return 1;
        }
    }
}
