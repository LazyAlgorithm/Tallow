using System;
using System.Collections;

namespace Tallow;

/// Jolt's static collision triangles for navigation baking. The native collector lives with the Jolt navigation
/// code; the engine only sees the neutral PhysicsGeometryExtension.
class JoltGeometryExtension : PhysicsGeometryExtension
{
	static class Native
	{
		[CLink] public static extern int32 tn_physics_collect_geometry(void* world, float* min, float* max, function void(void* user, float* triangle) callback, void* user);
	}

	static void Append(void* user, float* triangle)
	{
		let triangles = (List<float>)Internal.UnsafeCastToObject(user);
		for (int i < 9)
			triangles.Add(triangle[i]);
	}

	void* mSystem;

	public this(void* system)
	{
		mSystem = system;
	}

	public override bool Collect(Vector3 min, Vector3 max, List<float> triangles)
	{
		triangles.Clear();
		if (mSystem == null)
			return false;
		var lo = min;
		var hi = max;
		return Native.tn_physics_collect_geometry(mSystem, (float*)&lo, (float*)&hi, => Append, Internal.UnsafeCastToPtr(triangles)) != 0;
	}
}
