using System.Runtime.InteropServices;

namespace Tallow;

/// <summary>
/// The generated native Jolt hit value ABI. Layout matches Beef's [CRepr]
/// PhysicsQueryHit: one ulong, eight IEEE754 floats and two uints, 48 bytes.
/// No pointers or references are stored in this struct.
/// </summary>
[StructLayout(LayoutKind.Sequential, Pack = 8)]
public struct PhysicsQueryHit
{
    /// <summary>The hit object's entity (0 for none).</summary>
    public ulong EntityId;
    /// <summary>Where it was hit, world space.</summary>
    public float PointX, PointY, PointZ;
    /// <summary>The surface normal there.</summary>
    public float NormalX, NormalY, NormalZ;
    /// <summary>How far along the query it was hit; how deep an overlap goes.</summary>
    public float Distance, PenetrationDepth;
    /// <summary>The physics body hit, and flags: 1 something was hit, 2 the normal is valid, 4 the hit has an object.</summary>
    public uint BodyId, Flags;
}
