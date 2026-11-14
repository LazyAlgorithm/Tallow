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
/// This attribute describes the future binding contract. The generator is
/// not wired up yet: adding it alone does not create managed wrappers.
/// Unsupported types, pointers and unsafe ownership patterns must be
/// rejected at generation time, never silently marshalled.
// The type must survive Beef's compile-on-demand elimination even when no
// native code calls it yet. Include method metadata so the engine-build scanner
// sees deliberately annotated members on otherwise-unused static classes.
[AttributeUsage(.Class | .Struct | .Method | .Property | .Field,
    .ReflectAttribute | .AlwaysIncludeTarget, ReflectUser = .All,
    AlwaysIncludeUser = .IncludeAllMethods | .AssumeInstantiated)]
struct CSharpExposeAttribute : Attribute
{
}
