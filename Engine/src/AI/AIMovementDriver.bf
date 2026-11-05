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

/// What moves an object for a behaviour tree (BTContext.Mover): its Navigation Agent, or a project's own
/// AIMovementDriver. Calls on one with neither do nothing.
struct AIMover
{
	public NavigationAgent agent;
	public AIMovementDriver driver;

	public bool IsValid => agent.IsValid || driver != null;

	public void SetDestination(Vector3 point, float speed, float stoppingDistance)
	{
		if (agent)
			agent.SetDestination(point, speed, stoppingDistance);
		else
			driver?.SetDestination(point, speed, stoppingDistance);
	}

	public void StopMovement()
	{
		if (agent)
			agent.StopMovement();
		else
			driver?.StopMovement();
	}

	public bool PathPending => agent ? agent.PathPending : (driver?.PathPending ?? false);
	public bool PathFailed => agent ? agent.PathFailed : (driver?.PathFailed ?? false);
	public bool HasArrived => agent ? agent.HasArrived : (driver?.HasArrived ?? false);
}
