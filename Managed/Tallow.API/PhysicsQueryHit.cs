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
    public ulong EntityId;
    public float PointX, PointY, PointZ;
    public float NormalX, NormalY, NormalZ;
    public float Distance, PenetrationDepth;
    public uint BodyId, Flags;
}
