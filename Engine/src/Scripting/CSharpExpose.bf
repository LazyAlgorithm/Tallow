using System;

namespace Tallow;

/// Explicit opt-in for the public C# gameplay binding generator.
///
/// The engine remains native Beef. Mark the *type* and each safe member you
/// want C# gameplay to see. The generator must never expose an entire Beef
/// class just because that class is public or has this marker.
///
///     [CSharpExpose]
///     class Transform
///     {
///         [CSharpExpose] public Vector3 Position { get; set; }
///         [CSharpExpose] public void Translate(Vector3 delta) { ... }
///         void MarkDirty() { ... } // stays native and invisible to C#
///     }
///
/// The stage-1 generator is wired into source builds. Marked public static
/// methods with supported scalar/vector signatures generate native ABI wrappers
/// and C# declarations automatically. Stage-2 properties, instance handles and
/// resource ownership need additional generator support before annotation.
/// Unsupported types, pointers and unsafe ownership patterns must be
/// rejected at generation time, never silently marshalled.
// The type must survive Beef's compile-on-demand elimination even when no
// native code calls it yet. Include method metadata so the engine-build scanner
// sees deliberately annotated members on otherwise-unused static classes.
[AttributeUsage(.Class | .Struct | .Method | .Property | .Field | .StaticField,
    .ReflectAttribute | .AlwaysIncludeTarget, ReflectUser = .All,
    AlwaysIncludeUser = .IncludeAllMethods | .AssumeInstantiated)]
struct CSharpExposeAttribute : Attribute
{
    // Static fields are read-only in C# unless the engine author explicitly
    // grants write access. A mutable native counter is not automatically
    // writable by gameplay scripts.
    public bool Writable;
}

/// Engine-internal marker applied ONLY to generated ABI entrypoints.
/// The native resolver must never hand C# a pointer to an unrelated public
/// method merely because a name happens to begin with "CSharpApi_".
[AttributeUsage(.Method, .ReflectAttribute | .AlwaysIncludeTarget)]
struct CSharpApiExportAttribute : Attribute
{
}
