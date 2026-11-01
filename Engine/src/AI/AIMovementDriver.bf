using System;

namespace Tallow;

/// Base API for navigation and project movement components.
[Component]
abstract class AIMovementDriver : Component
{
	public abstract void SetDestination(Vector3 point, float speed, float stoppingDistance);
	public abstract void StopMovement();
	/// A path request waiting for deferred/batched completion. Status consumers should remain running.
	public virtual bool PathPending => false;
	public virtual bool PathFailed => false;
	public virtual bool HasArrived => false;
}
