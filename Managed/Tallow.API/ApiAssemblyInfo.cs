using System.Runtime.CompilerServices;

// Only the engine-owned trusted managed runtime can bind native function
// pointers. Ordinary gameplay assemblies only see generated public methods.
[assembly: InternalsVisibleTo("Tallow.ManagedRuntime")]
[assembly: InternalsVisibleTo("Tallow.Editor")]
// The pure-managed lifecycle smoke test binds its own engine bridge (Engine.Bind).
[assembly: InternalsVisibleTo("Tallow.ManagedHost")]
