using System.Runtime.CompilerServices;

// Only the engine-owned trusted managed runtime can bind native function
// pointers. Ordinary gameplay assemblies only see generated public methods.
[assembly: InternalsVisibleTo("Tallow.ManagedRuntime")]
