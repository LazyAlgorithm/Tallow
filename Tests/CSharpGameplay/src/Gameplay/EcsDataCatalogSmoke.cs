using System.Numerics;
using Tallow;

namespace Gameplay;

/// C# gameplay data schema intended for eventual direct Flecs column storage.
/// [Sync] describes a replicated field but is not wired to native replication yet.
[Component]
public struct VelocityData
{
    [Sync] public Vector3 Velocity;
    public float Drag;
    public int Owner;
}

/// Managed references cannot be copied into native packed Flecs columns.
[Component]
public struct InvalidNativeLayout
{
    public string Text;
}
