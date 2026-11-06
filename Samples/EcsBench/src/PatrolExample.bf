using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// A local patrol script demonstrating the ordinary gameplay API and component-owned resources.
/// Attach it to a visible GameObject; speed is metres per second and distance is metres from its starting point.
[Component]
class PatrolExample : Script
{
	public float speed = 2;
	public float distance = 5;

	List<Vector3> mWaypoints;
	int mWaypoint;

	public override void Awake()
	{
		// Recreated each play session and released by the component when that session ends.
		mWaypoints = Own(new List<Vector3>());
		let origin = Transform.Position;
		mWaypoints.Add(origin + Vector3.Right * distance);
		mWaypoints.Add(origin);
		mWaypoint = 0;
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (speed <= 0 || deltaTime <= 0) return;
		let target = mWaypoints[mWaypoint];
		let offset = target - Transform.Position;
		let step = speed * deltaTime;
		if (offset.LengthSquared <= step * step)
		{
			Transform.Position = target;
			mWaypoint = (mWaypoint + 1) % mWaypoints.Count;
		}
		else
			Transform.Position += offset.Normalized * step;
	}
}
