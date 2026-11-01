using System;
using Tallow;

namespace ReloadTests;

[Component]
class ReloadProbe : Component
{
	public float amount = 1;
	public int platformInt = 5000000000;
	public uint64 quota = uint64.MaxValue;
	public double precise = 0.12345678901234567;
	public Vector4 vector = .(1, 2, 3, 4);
	public ParticleSystem particles;
	float mTotal;
	public static int32 calls;
	public float Total => mTotal;
	public override void Update()
	{
		mTotal += amount;
		calls++;
		Transform.LocalPosition += Vector3.Right * amount;
		if (Input.GetKeyDown(.Space))
			particles.Enabled = !particles.Enabled;
	}
}
