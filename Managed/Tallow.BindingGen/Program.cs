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

    private const string HitRecordType = "Tallow.PhysicsQueryHit";
    private static bool IsHitRecord(string type) => type == HitRecordType;
    // Only these tightly scoped writable buffers cross the generated ABI.
    // Never expose generic spans, object pointers, references or span returns.
    private static bool IsSpan(string type) =>
        type is "System.Span<ulong>" or "System.Span<float>" or "System.Span<byte>";
    private static string SpanElement(string type) => type switch
    {
        "System.Span<ulong>" => "ulong",
        "System.Span<float>" => "float",
        "System.Span<byte>" => "byte",
        _ => throw new ArgumentOutOfRangeException(nameof(type))
    };
    private static string NativeSpanElement(string type) => type switch
    {
        "System.Span<ulong>" => "uint64",
        "System.Span<float>" => "float",
        "System.Span<byte>" => "uint8",
        _ => throw new ArgumentOutOfRangeException(nameof(type))
    };

    private static bool IsType(string type, bool allowVoid = false) =>
        type is "bool" or "int" or "uint" or "long" or "ulong" or
            "float" or "double" or "string" or "System.Numerics.Vector2" or
            "System.Numerics.Vector3" or "System.Numerics.Vector4" or
            "System.Numerics.Quaternion" or "Tallow.PhysicsQueryHit" or
            "System.Span<ulong>" or "System.Span<float>" or "System.Span<byte>" ||
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
        IsSpan(type) ? NativeSpanElement(type) + "*" :
        Dimensions(type) > 0 ? "float*" : type switch
        {
            "bool" or "int" => "int32",
            "uint" => "uint32",
            "long" => "int64",
            "ulong" => "uint64",
            _ => type
        };

    /// <summary>
    /// .NET's WebAssembly interpreter calls native code with at most 12 integer-class argument slots (pointers and
    /// 32-bit values take one, 64-bit integers two on wasm32; mono/mini/interp/interp.h INTERP_ICALL_TRAMP_IARGS) and
    /// stops the program for more. A binding whose lowered signature would need more passes its strings packed: one
    /// pointer to an array of (UTF-8 pointer, byte length) pairs, in parameter order, as the first native argument.
    /// The same ABI on every platform, so desktop and browser builds call the same export.
    /// </summary>
    internal const int WasmIntegerSlots = 12;

    private static int IntegerSlots(Method m, bool packed)
    {
        int slots = packed && m.Parameters.Any(p => p.Type == "string") ? 1 : 0;
        foreach (Parameter p in m.Parameters)
        {
            if (p.Type == "string")
                slots += packed ? 0 : 2;
            else if (IsSpan(p.Type))
                slots += 2;
            else if (p.Type is "long" or "ulong")
                slots += 2;
            else if (p.Type is not ("float" or "double") || Dimensions(p.Type) > 0)
                slots += 1;
        }
        if (Dimensions(m.Result) > 0 || IsHitRecord(m.Result))
            slots += 1;
        return slots;
    }

    private static bool PacksStrings(Method m)
    {
        if (IntegerSlots(m, false) <= WasmIntegerSlots)
            return false;
        if (IntegerSlots(m, true) > WasmIntegerSlots)
            throw new InvalidOperationException($"{m.Owner}.{m.Name}: {IntegerSlots(m, true)} integer argument slots even with " +
                $"its strings packed; .NET in a browser allows {WasmIntegerSlots}. Pass fewer arguments.");
        return true;
    }

    private static string CAbiType(string type) =>
        IsSpan(type) ? SpanElement(type) + "*" :
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
                (result == "string" || IsSpan(result)) ||
                isField && (name == owner["Tallow.".Length..] || IsHitRecord(result)))
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
                if (IsHitRecord(type))
                    throw new FormatException($"Manifest line {i + 1}: struct ABI parameters are not supported; only generated struct results.");
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
        p.Type == "string" || IsSpan(p.Type) ? $"s{i}" :
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
                bool packed = PacksStrings(m);
                List<string> args = [];
                if (packed)
                    args.Add("CSharpStringArg* strings");
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    if (packed && p.Type == "string")
                        continue;
                    if (p.Type == "string" || IsSpan(p.Type))
                    {
                        args.Add($"{(p.Type == "string" ? "char8*" : NativeType(p.Type))} p{i}");
                        args.Add($"int32 p{i}Length");
                    }
                    else
                        args.Add($"{NativeType(p.Type)} p{i}");
                }
                if (Dimensions(m.Result) > 0)
                    args.Add("float* result");
                else if (IsHitRecord(m.Result))
                    args.Add("PhysicsQueryHit* result");
                string returnType = Dimensions(m.Result) > 0 || IsHitRecord(m.Result) ?
                    "void" : NativeType(m.Result);
                text.AppendLine("\t[Export, CLink, Reflect, AlwaysInclude, CSharpApiExport]")
                    .AppendLine($"\tpublic static {returnType} {symbol}({string.Join(", ", args)})")
                    .AppendLine("\t{");
                if (packed)
                    text.AppendLine($"\t\tif (strings == null) return{(returnType == "void" ? ";" : " default;")}");
                int packedIndex = 0;
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    int count = Dimensions(p.Type);
                    if (packed && p.Type == "string")
                    {
                        text.AppendLine($"\t\tif (strings[{packedIndex}].Length < 0 || (strings[{packedIndex}].Length > 0 && strings[{packedIndex}].Ptr == null)) return{(returnType == "void" ? ";" : " default;")}");
                        text.AppendLine($"\t\tStringView s{i} = .(strings[{packedIndex}].Ptr, strings[{packedIndex}].Length);");
                        packedIndex++;
                    }
                    else if (p.Type == "string" || IsSpan(p.Type))
                    {
                        text.AppendLine($"\t\tif (p{i}Length < 0 || (p{i}Length > 0 && p{i} == null)) return{(returnType == "void" ? ";" : " default;")}");
                        text.AppendLine(p.Type == "string" ?
                            $"\t\tStringView s{i} = .(p{i}, p{i}Length);" :
                            $"\t\tSpan<{NativeSpanElement(p.Type)}> s{i} = .(p{i}, p{i}Length);");
                    }
                    if (count > 0)
                    {
                        string name = p.Type == "System.Numerics.Quaternion" ?
                            "Quaternion" : $"Vector{count}";
                        text.AppendLine($"\t\tif (p{i} == null) return{(returnType == "void" ? ";" : " default;")}");
                        text.AppendLine($"\t\t{name} v{i} = .({string.Join(", ", Enumerable.Range(0, count).Select(j => $"p{i}[{j}]"))});");
                    }
                }
                if (Dimensions(m.Result) > 0 || IsHitRecord(m.Result))
                    text.AppendLine("\t\tif (result == null) return;");
                string call = m.IsField ? $"{m.Owner}.{m.Name}" :
                    $"{m.Owner}.{m.Name}({string.Join(", ", m.Parameters.Select(ArgumentExpression))})";
                if (m.Result == "void")
                    text.AppendLine($"\t\t{call};");
                else if (m.Result == "bool")
                    text.AppendLine($"\t\treturn {call} ? 1 : 0;");
                else if (IsHitRecord(m.Result))
                    text.AppendLine($"\t\tresult[0] = {call};");
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

    /// <summary>
    /// The <c>///</c> comment above each public static member of a Beef class, keyed "Tallow.Class.Member" (the first
    /// overload's), so the generated C# carries the engine's own documentation. Classes are keyed "Tallow.Class".
    /// </summary>
    internal static Dictionary<string, string> ReadBeefDocs(string engineSource)
    {
        Dictionary<string, string> docs = new(StringComparer.Ordinal);
        foreach (string file in Directory.EnumerateFiles(engineSource, "*.bf", SearchOption.AllDirectories).Order(StringComparer.Ordinal))
            ReadBeefDocs(File.ReadAllLines(file), docs);
        return docs;
    }

    internal static void ReadBeefDocs(string[] lines, Dictionary<string, string> docs)
    {
        string? owner = null;
        List<string> comment = [];
        var classPattern = new System.Text.RegularExpressions.Regex(@"^(?:public\s+)?(?:static\s+)?(?:sealed\s+)?(?:abstract\s+)?(?:partial\s+)?(?:class|struct)\s+([A-Za-z_][A-Za-z0-9_]*)");
        var memberPattern = new System.Text.RegularExpressions.Regex(@"^public\s+static\s+(?:extern\s+)?[^=(]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(|\{|=>|=|;)");
        var attributes = new System.Text.RegularExpressions.Regex(@"^(?:\[[^\]]*\]\s*)+");
        foreach (string raw in lines)
        {
            string line = raw.TrimEnd();
            string trimmed = line.TrimStart();
            if (trimmed.StartsWith("///", StringComparison.Ordinal))
            {
                comment.Add(trimmed[3..].StartsWith(' ') ? trimmed[4..] : trimmed[3..]);
                continue;
            }
            // Attributes sit between a comment and its member, on their own lines or before it on the same one.
            trimmed = attributes.Replace(trimmed, "");
            if (trimmed.Length == 0)
                continue;
            System.Text.RegularExpressions.Match type = classPattern.Match(trimmed);
            if (type.Success)
            {
                owner = "Tallow." + type.Groups[1].Value;
                if (comment.Count > 0)
                    docs.TryAdd(owner, string.Join("\n", comment));
            }
            else if (owner != null && comment.Count > 0)
            {
                System.Text.RegularExpressions.Match member = memberPattern.Match(trimmed);
                if (member.Success)
                    docs.TryAdd(owner + "." + member.Groups[1].Value, string.Join("\n", comment));
            }
            comment.Clear();
        }
    }

    /// <summary>Classes Tallow.API declares by hand too ("Tallow.SceneManager"): they document themselves there.</summary>
    internal static HashSet<string> HandWrittenClasses(string apiFolder)
    {
        HashSet<string> names = new(StringComparer.Ordinal);
        var pattern = new System.Text.RegularExpressions.Regex(@"\bpartial\s+class\s+([A-Za-z_][A-Za-z0-9_]*)");
        foreach (string file in Directory.EnumerateFiles(apiFolder, "*.cs", SearchOption.TopDirectoryOnly))
            foreach (System.Text.RegularExpressions.Match match in pattern.Matches(File.ReadAllText(file)))
                names.Add("Tallow." + match.Groups[1].Value);
        return names;
    }

    private static void AppendDoc(StringBuilder text, string indent, string? doc)
    {
        if (string.IsNullOrWhiteSpace(doc))
            return;
        string escaped = doc.Replace("&", "&amp;", StringComparison.Ordinal).Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);
        string[] lines = escaped.Split('\n');
        if (lines.Length == 1)
        {
            text.AppendLine($"{indent}/// <summary>{escaped}</summary>");
            return;
        }
        text.AppendLine($"{indent}/// <summary>");
        foreach (string line in lines)
            text.AppendLine($"{indent}/// {line}".TrimEnd());
        text.AppendLine($"{indent}/// </summary>");
    }

    private static string EmitCSharp(IReadOnlyList<Method> methods, string version,
        IReadOnlyDictionary<string, string>? docs = null, IReadOnlySet<string>? handWritten = null)
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
            // A hand-written partial (SceneManager, Application) documents the class itself.
            // The CSharp* classes are the plumbing under the C# API: documented, but kept out of completion lists.
            bool plumbing = group.Key.StartsWith("Tallow.CSharp", StringComparison.Ordinal);
            if (handWritten?.Contains(group.Key) != true)
                AppendDoc(text, "", docs?.GetValueOrDefault(group.Key) ?? (plumbing ?
                "Engine calls behind the C# API. Scripts use the API's own types (GameObject, components, Scene...)." : null));
            if (plumbing)
                text.AppendLine("[System.ComponentModel.EditorBrowsable(System.ComponentModel.EditorBrowsableState.Never)]");
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
                AppendDoc(text, "\t", docs?.GetValueOrDefault(m.Owner + "." + m.Name) ??
                    $"The engine's {m.Owner["Tallow.".Length..]}.{m.Name}, as the C# API calls it.");
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
                    {
                        // Short strings (names, fields, paths) encode on the stack: a call allocates nothing.
                        text.AppendLine($"\t\tstring p{i}Text = {p.Name} ?? string.Empty;")
                            .AppendLine($"\t\tSpan<byte> p{i}Utf8 = p{i}Text.Length <= 128 ? stackalloc byte[384] : new byte[Encoding.UTF8.GetMaxByteCount(p{i}Text.Length)];")
                            .AppendLine($"\t\tint p{i}Length = Encoding.UTF8.GetBytes(p{i}Text, p{i}Utf8);");
                    }
                    if (count > 0)
                    {
                        string[] components = ["X", "Y", "Z", "W"];
                        text.AppendLine($"\t\tfloat* p{i} = stackalloc float[{count}] {{ {string.Join(", ", components.Take(count).Select(c => p.Name + "." + c))} }};");
                    }
                }
                if (Dimensions(m.Result) > 0)
                    text.AppendLine($"\t\tfloat* result = stackalloc float[{Dimensions(m.Result)}];");
                else if (IsHitRecord(m.Result))
                    text.AppendLine("\t\tPhysicsQueryHit result = default;");
                bool packed = PacksStrings(m);
                List<string> nativeArgs = [];
                if (packed)
                    nativeArgs.Add("(byte*)strings");
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    if (packed && p.Type == "string")
                        continue;
                    if (p.Type == "string" || IsSpan(p.Type))
                    {
                        nativeArgs.Add($"p{i}");
                        nativeArgs.Add(p.Type == "string" ? $"p{i}Length" : $"{p.Name}.Length");
                    }
                    else
                        nativeArgs.Add(Dimensions(p.Type) > 0 ? $"p{i}" :
                            p.Type == "bool" ? $"({p.Name} ? 1 : 0)" : p.Name);
                }
                if (Dimensions(m.Result) > 0)
                    nativeArgs.Add("result");
                else if (IsHitRecord(m.Result))
                    nativeArgs.Add("&result");
                List<string> types = [];
                if (packed)
                    types.Add("byte*");
                foreach (Parameter p in m.Parameters)
                {
                    if (packed && p.Type == "string")
                        continue;
                    if (p.Type == "string" || IsSpan(p.Type))
                    {
                        types.Add(p.Type == "string" ? "byte*" : CAbiType(p.Type));
                        types.Add("int");
                    }
                    else
                        types.Add(CAbiType(p.Type));
                }
                if (Dimensions(m.Result) > 0)
                    types.Add("float*");
                else if (IsHitRecord(m.Result))
                    types.Add("PhysicsQueryHit*");
                types.Add(Dimensions(m.Result) > 0 || IsHitRecord(m.Result) ?
                    "void" : CAbiType(m.Result));
                string call = $"((delegate* unmanaged[Cdecl]<{string.Join(", ", types)}>)ptr)({string.Join(", ", nativeArgs)})";
                // Pin only for the lifetime of this call. Spans can be
                // stackalloc or array-backed and may never be retained natively.
                bool hasPinned = m.Parameters.Any(p => p.Type == "string" || IsSpan(p.Type));
                foreach ((Parameter p, int i) in m.Parameters.Select((p, i) => (p, i)))
                {
                    if (p.Type == "string")
                        text.AppendLine($"\t\tfixed (byte* p{i} = p{i}Utf8)");
                    else if (IsSpan(p.Type))
                        text.AppendLine($"\t\tfixed ({CAbiType(p.Type)} p{i} = {p.Name})");
                }
                if (hasPinned)
                    text.AppendLine("\t\t{");
                if (packed)
                {
                    string[] pairs = m.Parameters.Select((p, i) => (p, i)).Where(x => x.p.Type == "string")
                        .Select(x => $"new NativeStringArg(p{x.i}, p{x.i}Length)").ToArray();
                    text.AppendLine($"\t\tNativeStringArg* strings = stackalloc NativeStringArg[{pairs.Length}] {{ {string.Join(", ", pairs)} }};");
                }
                if (m.Result == "void")
                    text.AppendLine($"\t\t{call};");
                else if (m.Result == "bool")
                    text.AppendLine($"\t\treturn {call} != 0;");
                else if (Dimensions(m.Result) > 0)
                    text.AppendLine($"\t\t{call};")
                        .AppendLine($"\t\treturn new {CSharpType(m.Result)}({string.Join(", ", Enumerable.Range(0, Dimensions(m.Result)).Select(i => $"result[{i}]"))});");
                else if (IsHitRecord(m.Result))
                    text.AppendLine($"\t\t{call};")
                        .AppendLine("\t\treturn result;");
                else
                    text.AppendLine($"\t\treturn {call};");
                if (hasPinned)
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
        AppendWebSignatures(text);
        return text.ToString();
    }

    /// <summary>
    /// .NET's WebAssembly interpreter calls native code only through signatures it was built with, which it takes
    /// from the P/Invoke declarations it bundles, not from function-pointer calls. So every signature the bindings
    /// above call through gets a declaration of its own, never called (Tallow.ManagedRuntime's WebHost has the
    /// engine callback table's). Desktop .NET ignores them.
    /// </summary>
    private static void AppendWebSignatures(StringBuilder text)
    {
        SortedSet<string> signatures = new(StringComparer.Ordinal);
        foreach (System.Text.RegularExpressions.Match match in
                 System.Text.RegularExpressions.Regex.Matches(text.ToString(), @"delegate\* unmanaged\[Cdecl\]<([^<>]+)>"))
            signatures.Add(match.Groups[1].Value);
        text.AppendLine("/// <summary>The bindings' native signatures, for .NET in a browser (never called).</summary>")
            .AppendLine("[System.ComponentModel.EditorBrowsable(System.ComponentModel.EditorBrowsableState.Never)]")
            .AppendLine("internal static unsafe class GeneratedWebSignatures")
            .AppendLine("{");
        int index = 0;
        foreach (string signature in signatures)
        {
            string[] types = signature.Split(", ");
            string parameters = string.Join(", ", types[..^1].Select((type, i) => $"{type} a{i}"));
            text.AppendLine($"\t[System.Runtime.InteropServices.DllImport(\"tallow_signatures\")] private static extern {types[^1]} S{index++}({parameters});");
        }
        text.AppendLine("}");
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
        const string many = "TALLOW_CSHARP_API_V1\nmethod\tTallow.PackChecks\tPublish\tint\ta:string\tb:string\tc:string\tn:int\td:string\tid:ulong\te:string\tf:string\n";
        List<Method> manyMethods = Parse(many);
        string beefMany = EmitBeef(manyMethods, Hash(many));
        string managedMany = EmitCSharp(manyMethods, Hash(many));
        if (!beefMany.Contains("(CSharpStringArg* strings, int32 p3, uint64 p5)") ||
            !beefMany.Contains("StringView s7 = .(strings[5].Ptr, strings[5].Length);") ||
            !managedMany.Contains("NativeStringArg* strings = stackalloc NativeStringArg[6] { new NativeStringArg(p0, p0Length),") ||
            !managedMany.Contains("delegate* unmanaged[Cdecl]<byte*, int, ulong, int>)ptr)((byte*)strings, n, id)"))
            throw new Exception("Packed string lowering (WebAssembly argument limit) failed.");
        const string hitRecord = "TALLOW_CSHARP_API_V1\nmethod\tTallow.Physics\tRaycastDetails\tTallow.PhysicsQueryHit\tsession:ulong\torigin:System.Numerics.Vector3\tdirection:System.Numerics.Vector3\tmaxDistance:float\tlayerMask:uint\n";
        List<Method> hitMethods = Parse(hitRecord);
        string beefHit = EmitBeef(hitMethods, Hash(hitRecord));
        string managedHit = EmitCSharp(hitMethods, Hash(hitRecord));
        if (!beefHit.Contains("PhysicsQueryHit* result") ||
            !beefHit.Contains("result[0] = Tallow.Physics.RaycastDetails(") ||
            !managedHit.Contains("public static Tallow.PhysicsQueryHit RaycastDetails(") ||
            !managedHit.Contains("PhysicsQueryHit result = default;") ||
            !managedHit.Contains("delegate* unmanaged[Cdecl]<ulong, float*, float*, float, uint, PhysicsQueryHit*, void>") ||
            !managedHit.Contains("return result;"))
            throw new Exception("Structured hit return ABI lowering failed.");
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
            !csharpString.Contains("string p0Text = text ?? string.Empty;") ||
            !csharpString.Contains("stackalloc byte[384]") ||
            !csharpString.Contains("int p0Length = Encoding.UTF8.GetBytes(p0Text, p0Utf8);") ||
            !csharpString.Contains("fixed (byte* p0 = p0Utf8)") ||
            !csharpString.Contains("delegate* unmanaged[Cdecl]<byte*, int, void>"))
            throw new Exception("UTF-8 StringView parameter lowering failed.");
        const string spanManifest = "TALLOW_CSHARP_API_V1\nmethod\tTallow.Ecs\tCopyRigidbodyMasses\tint\tsession:ulong\toffset:int\tentityIds:System.Span<ulong>\tmasses:System.Span<float>\n";
        List<Method> spanMethods = Parse(spanManifest);
        string nativeSpan = EmitBeef(spanMethods, Hash(spanManifest));
        string managedSpan = EmitCSharp(spanMethods, Hash(spanManifest));
        if (!nativeSpan.Contains("uint64* p2, int32 p2Length, float* p3, int32 p3Length") ||
            !nativeSpan.Contains("Span<uint64> s2 = .(p2, p2Length);") ||
            !nativeSpan.Contains("Span<float> s3 = .(p3, p3Length);") ||
            !nativeSpan.Contains("p2Length < 0 || (p2Length > 0 && p2 == null)") ||
            !managedSpan.Contains("public static int CopyRigidbodyMasses(ulong session, int offset, System.Span<ulong> entityIds, System.Span<float> masses)") ||
            !managedSpan.Contains("fixed (ulong* p2 = entityIds)") ||
            !managedSpan.Contains("fixed (float* p3 = masses)") ||
            !managedSpan.Contains("delegate* unmanaged[Cdecl]<ulong, int, ulong*, int, float*, int, int>"))
            throw new Exception("Pinned, counted ECS span ABI lowering failed.");
        const string bytesManifest = "TALLOW_CSHARP_API_V1\nmethod\tTallow.Ecs\tSetLocalData\tbool\tsession:ulong\tdata:System.Span<byte>\n";
        List<Method> byteMethods = Parse(bytesManifest);
        string nativeBytes = EmitBeef(byteMethods, Hash(bytesManifest));
        string managedBytes = EmitCSharp(byteMethods, Hash(bytesManifest));
        if (!nativeBytes.Contains("uint8* p1, int32 p1Length") ||
            !nativeBytes.Contains("Span<uint8> s1 = .(p1, p1Length);") ||
            !managedBytes.Contains("System.Span<byte> data") ||
            !managedBytes.Contains("fixed (byte* p1 = data)") ||
            !managedBytes.Contains("delegate* unmanaged[Cdecl]<ulong, byte*, int, int>"))
            throw new Exception("Pinned, counted ECS byte buffer ABI lowering failed.");
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
            "TALLOW_CSHARP_API_V1\nfield\tTallow.Bad\tText\tstring\tget\n",
            "TALLOW_CSHARP_API_V1\nfield\tTallow.Bad\tRaw\tTallow.PhysicsQueryHit\tget\n",
            "TALLOW_CSHARP_API_V1\nmethod\tTallow.Physics\tEcho\tTallow.PhysicsQueryHit\tvalue:Tallow.PhysicsQueryHit\n",
            "TALLOW_CSHARP_API_V1\nmethod\tTallow.Bad\tReturnSpan\tSystem.Span<float>\n",
            "TALLOW_CSHARP_API_V1\nfield\tTallow.Bad\tSpanField\tSystem.Span<ulong>\tget\n",
            "TALLOW_CSHARP_API_V1\nmethod\tTallow.Bad\tUnsafe\tint\tbuffer:System.Span<int>\n"
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
                EmitCSharp(methods, version, ReadBeefDocs(Path.Combine(root, "Engine/src")),
                    HandWrittenClasses(Path.Combine(root, "Managed/Tallow.API"))));
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
