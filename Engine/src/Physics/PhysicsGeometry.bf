using System;
using System.Collections;

namespace Tallow;

/// Static collision geometry for navigation baking. The selected backend supplies it, so navigation no longer reaches
/// into a physics library: Jolt walks its shapes, another backend walks its colliders.
abstract class PhysicsGeometryExtension
{
	/// Appends every static triangle inside the bounds to `triangles` as nine floats (a, b, c). False when the backend
	/// cannot supply them (or hit its safety limit).
	public abstract bool Collect(Vector3 min, Vector3 max, List<float> triangles);
}
