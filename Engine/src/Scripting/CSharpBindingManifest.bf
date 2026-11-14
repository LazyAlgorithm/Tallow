using System;
using System.Collections;
using System.IO;
using System.Reflection;

namespace Tallow;

/// Extracts the explicitly approved C# gameplay surface from *resolved Beef
/// symbols*. This is an engine-side build artifact, not a gameplay-time scanner.
/// Stage 1 supports only stateless static methods over a small, safe value ABI.
static class CSharpBindingManifest
{
    const StringView Header = "TALLOW_CSHARP_API_V1";

    static bool MapValueType(Type type, String name)
    {
        if (type == typeof(void))
            name.Set("void");
        else if (type == typeof(bool))
            name.Set("bool");
        else if (type == typeof(int32))
            name.Set("int");
        else if (type == typeof(uint32))
            name.Set("uint");
        else if (type == typeof(int64))
            name.Set("long");
        else if (type == typeof(uint64))
            name.Set("ulong");
        else if (type == typeof(float))
            name.Set("float");
        else if (type == typeof(double))
            name.Set("double");
        else if (type == typeof(StringView))
            name.Set("string");
        else if (type == typeof(Vector2))
            name.Set("System.Numerics.Vector2");
        else if (type == typeof(Vector3))
            name.Set("System.Numerics.Vector3");
        else if (type == typeof(Vector4))
            name.Set("System.Numerics.Vector4");
        else
            return false;
        return true;
    }

    static bool AddMethod(StringView owner, MethodInfo method, List<String> records, String error)
    {
        let signature = scope $"{owner}.{method.Name}";
        if (!method.IsPublic || !method.IsStatic || method.GenericArgCount != 0 ||
            method.IsMixin || method.IsConstructor || method.IsDestructor)
        {
            error.AppendF("[CSharpExpose] {} must be a public, non-generic static method in binding stage 1.", signature);
            return false;
        }

        let resultType = scope String();
        if (!MapValueType(method.ReturnType, resultType) || resultType == "string")
        {
            error.AppendF("[CSharpExpose] {} has an unsupported return type. Stage 1 accepts void, bool, int32/64, uint32/64, float/double and Vector2/3/4.", signature);
            return false;
        }

        let record = new String();
        record.AppendF("method\t{}\t{}\t{}", owner, method.Name, resultType);
        for (int i < method.ParamCount)
        {
            let parameter = scope String();
            if (method.GetParamFlags(i) != .None ||
                !MapValueType(method.GetParamType(i), parameter) || parameter == "void")
            {
                error.AppendF("[CSharpExpose] {} parameter {} has an unsupported type or modifier (no ref/out, defaults, pointers or generics).", signature, i + 1);
                delete record;
                return false;
            }
            // Parameter names come from the compiler, not source parsing.
            record.AppendF("\t{}:{}", method.GetParamName(i), parameter);
        }
        records.Add(record);
        return true;
    }

    /// Write deterministic, UTF-8, tab-separated binding descriptions for the
    /// subsequent native/C# wrapper generator. Failure leaves no new manifest.
    public static bool Write(StringView path, String error)
    {
        List<String> records = scope .();
        defer
        {
            ClearAndDeleteItems!(records);
        }

        for (let type in ScriptReload.ReflectedTypes)
        {
            if (type == null)
                continue;
            bool exposedType = type.GetCustomAttribute<CSharpExposeAttribute>() case .Ok;
            let owner = scope String();
            type.GetFullName(owner);

            for (let method in type.GetMethods(.Public | .NonPublic | .Static | .Instance | .DeclaredOnly))
            {
                if (!(method.GetCustomAttribute<CSharpExposeAttribute>() case .Ok))
                    continue;
                if (!exposedType)
                {
                    error.AppendF("[CSharpExpose] {}.{} is marked but its declaring type is not.", owner, method.Name);
                    return false;
                }
                if (type.IsGenericType || !AddMethod(owner, method, records, error))
                {
                    if (error.IsEmpty)
                        error.AppendF("[CSharpExpose] {} cannot expose methods on generic types.", owner);
                    return false;
                }
            }

            for (let field in type.GetFields(.Public | .NonPublic | .Static | .Instance | .DeclaredOnly))
            {
                if (!(field.GetCustomAttribute<CSharpExposeAttribute>() case .Ok(let annotation)))
                    continue;
                if (!exposedType)
                {
                    error.AppendF("[CSharpExpose] {}.{} is marked but its declaring type is not.", owner, field.Name);
                    return false;
                }
                if (type.IsGenericType || !field.IsPublic || !field.IsStatic || field.IsConst)
                {
                    error.AppendF("[CSharpExpose] {}.{} must be a public, non-constant static field on a non-generic type.", owner, field.Name);
                    return false;
                }
                let fieldType = scope String();
                if (!MapValueType(field.FieldType, fieldType) || fieldType == "void" || fieldType == "string")
                {
                    error.AppendF("[CSharpExpose] {}.{} has an unsupported field type. Expose a safe scalar or vector value.", owner, field.Name);
                    return false;
                }
                if (annotation.Writable && (field.IsReadOnly || fieldType.StartsWith("System.Numerics.")))
                {
                    error.AppendF("[CSharpExpose] {}.{} cannot be writable: only mutable scalar fields support generated C# setters yet.", owner, field.Name);
                    return false;
                }
                // A native field does not authorize C# writes unless expressly
                // opted in by the engine author.
                records.Add(new String()..AppendF("field\t{}\t{}\t{}\t{}", owner, field.Name, fieldType, annotation.Writable ? "getset" : "get"));
            }
        }

        records.Sort(scope (a, b) => a.CompareTo(b));
        let output = scope String();
        output.AppendF("{}\n", Header);
        for (let record in records)
        {
            output.Append(record);
            output.Append('\n');
        }
        if (File.WriteAllText(path, output) case .Err)
        {
            error.AppendF("Could not write C# binding manifest to {}.", path);
            return false;
        }
        return true;
    }
}

/// Temporary annotated fixture for the manifest and generator integration tests.
/// The second public method deliberately stays invisible to C#.
[CSharpExpose]
static class CSharpBindingFixture
{
    [CSharpExpose]
    public static float Average(float a, float b) => (a + b) * 0.5f;

    public static float NativeOnly(float a) => a;
}
