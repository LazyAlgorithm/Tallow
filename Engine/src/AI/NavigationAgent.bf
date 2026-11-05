using System;
using System.Collections;

namespace Tallow;

/// A Navigation Agent's settings, in its entity (NavigationAgent is the handle).
[Component, HandleData]
struct NavigationAgentData
{
	/// The surface to find paths on. Empty: the one in the scene's active world state.
	public ObjectRef<NavigationSurface> surface = .();
	/// How far the start and destination may be moved to reach a usable cell.
	public float snapDistance = 2;
	/// Offset from the object's origin to the agent's feet (walking) or centre (flying).
	public Vector3 baseOffset = .Zero;
	/// Shortest time between two path searches. A search runs only when the destination or the navigation data changed,
	/// or the agent was pushed off its path.
	public float repathInterval = 0.3f;
	public bool faceMovement = true;
	/// Degrees per second when turning to face movement; 0 turns instantly.
	public float turnSpeed = 720;
	/// Goes straight wherever it can, at any angle, rather than along the grid's directions.
	public bool smoothPath = true;
	/// Steers round other agents and moving obstacles near it.
	public bool avoidOthers = true;
	/// How far the agent reaches out from its centre, for steering round others.
	public float radius = 0.4f;
	/// When two agents meet, the one with the lower priority gives way more (0 to 100).
	[Range(0, 100)]
	public int32 avoidancePriority = 50;
	/// Uses Navigation Links (jumps, ladders, teleporters) when they are the shorter way.
	public bool useLinks = true;

	public this() { }
}

/// Moves its object along paths found on a Navigation Surface: call SetDestination, then watch HasArrived or
/// PathFailed. It walks through the object's Character Controller or Rigidbody when it has one. See
/// docs/navigation.md.
///
/// A handle (ComponentHandle): its settings are NavigationAgentData's fields, its path and steering its
/// NavigationAgentState. Agents move on in the Frame.Navigation step after the scripts' Update and in the
/// Tick.Navigation step after their FixedUpdate, as OnLocalUpdate and FixedUpdate did.
[Component, HandleFields]
struct NavigationAgent : ComponentHandle<NavigationAgentData>
{
	/// Steering round others looks only at the agents near this one (Scene.NavigationCrowd); off, at every agent in the
	/// scene, for comparing.
	public static bool UseSpatialAvoidance = true;

	/// Its path and steering, made (and listed in the scene's crowd) the first time it is asked for.
	public NavigationAgentState Runtime
	{
		get
		{
			CheckValid();
			let state = ComponentState<NavigationAgentState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			if (state.[Friend]mGameObject == null)
			{
				state.[Friend]mGameObject = mGameObject;
				mGameObject.Scene.NavigationCrowd.Register(state);
			}
			return state;
		}
	}

	// The API, unchanged: each member is documented on NavigationAgentState.
	/// The surface it finds paths on (its `surface`, or the one it found), or null.
	public NavigationSurface Surface => Runtime.Surface;
	public bool PathPending => Runtime.PathPending;
	public bool PathFailed => Runtime.PathFailed;
	public bool HasArrived => Runtime.HasArrived;
	public List<Vector3> Path => Runtime.Path;
	public List<int32> PathLinks => Runtime.PathLinks;
	public NavigationLink CurrentLink => Runtime.CurrentLink;
	public bool IsCrossingLink => Runtime.IsCrossingLink;
	public Vector3 Velocity => Runtime.Velocity;
	public float RemainingDistance => Runtime.RemainingDistance;
	public ref Event<delegate void(NavigationLink link)> OnLinkStarted => ref Runtime.OnLinkStarted;
	public ref Event<delegate void(NavigationLink link)> OnLinkFinished => ref Runtime.OnLinkFinished;
	public void SetDestination(Vector3 point, float speed, float stoppingDistance) => Runtime.SetDestination(point, speed, stoppingDistance);
	public void StopMovement() => Runtime.StopMovement();

	/// Scene.Update calls it after the components' Update (NavigationAgentState.FindQueuedPaths).
	public static void FindQueuedPaths() => NavigationAgentState.FindQueuedPaths();

	/// Moves every switched-on agent on an active object a frame on, and stops one that has been switched off.
	public static void FrameAll(Scene scene)
	{
		if (!scene.IsPlaying)
			return;
		for (let agent in scene.FindComponents<NavigationAgent>(.. scope .()))
		{
			let state = agent.Runtime;
			if (!agent.IsActiveAndEnabled)
			{
				if (state.[Friend]mWasActive)
				{
					state.[Friend]mWasActive = false;
					state.StopMovement();
				}
				continue;
			}
			state.[Friend]mWasActive = true;
			state.Frame();
		}
	}

	/// Moves every switched-on agent on an active object a fixed tick on (through its controller or body).
	public static void TickAll(Scene scene)
	{
		if (!scene.IsPlaying)
			return;
		for (let agent in scene.Components<NavigationAgent>(.. scope .()))
		{
			if (agent.GameObject.ActiveInHierarchy)
				agent.Runtime.Tick();
		}
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		if (selected && gameObject.Scene != null)
			gameObject.GetComponent<NavigationAgent>().Runtime.DrawGizmos(selected);
	}

	static void OnRemove(void* world, uint64 entity)
	{
		if (let state = ComponentState<NavigationAgentState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
			state.[Friend]Leave();
		ComponentState<NavigationAgentState>.Release(world, entity);
	}
}

/// What a Navigation Agent keeps between frames: its path, where it is on it and how it is steering. Its settings
/// are read from the entity each time.
[DataFields(typeof(NavigationAgentData), "Settings")]
class NavigationAgentState
{
	GameObject mGameObject;
	// The surface, found again once per update or tick (its object may have gone, or `surface` been changed).
	NavigationSurface mSurface;
	ObjectRef<NavigationSurface> mSurfaceRef;
	int64 mSurfaceUpdate = -1;
	int32 mSurfaceTick = -1;

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject?.Scene;
	public bool IsActiveAndEnabled => mGameObject.ActiveInHierarchy && mGameObject.GetComponent<NavigationAgent>().enabled;
	T GetComponent<T>() where T : struct, IComponentHandle => mGameObject.GetComponent<T>();
	bool HasComponent<T>() where T : struct, IComponentHandle => mGameObject.HasComponent<T>();
	ref NavigationAgentData Settings
	{
		[Inline]
		get => ref *mGameObject.GetComponent<NavigationAgentData>();
	}

	/// The surface it finds paths on: its `surface` setting, or the one SetDestination found for it.
	public NavigationSurface Surface
	{
		get
		{
			let scene = Scene;
			if (scene == null)
				return null;
			let wanted = Settings.surface;
			if (!wanted.Equals(mSurfaceRef) || mSurfaceUpdate != scene.UpdateCount || mSurfaceTick != Time.Tick)
			{
				mSurfaceRef = wanted;
				mSurfaceUpdate = scene.UpdateCount;
				mSurfaceTick = Time.Tick;
				mSurface = wanted.Component(scene) as NavigationSurface;
			}
			return mSurface;
		}
	}

	/// The agent started crossing a Navigation Link (to play a jump or climb animation).
	public Event<delegate void(NavigationLink link)> OnLinkStarted ~ _.Dispose();
	/// The agent got to the far end of a link.
	public Event<delegate void(NavigationLink link)> OnLinkFinished ~ _.Dispose();

	/// Leaves the crowd and the path queue (its component was removed or its object destroyed).
	void Leave()
	{
		if (mQueued)
		{
			mQueued = false;
			sQueue.Remove(this);
		}
		if (let scene = Scene)
			scene.[Friend]mNavigationCrowd?.Unregister(this);
	}

	static ProfilerMarker sAvoidProfile = .("Navigation.Avoid", .AI);
	static ProfilerMarker sNeighborsProfile = .("Navigation.Avoid.Neighbors", .AI);
	static ProfilerMarker sSteerProfile = .("Navigation.Avoid.Candidates", .AI);

	/// The turns Avoid tries each side of the wanted direction, in degrees.
	const int AvoidTurns = 11;
	static float[AvoidTurns] sAvoidAngles = .(0, 15, -15, 30, -30, 50, -50, 75, -75, 105, -105);
	static Quaternion[AvoidTurns] sAvoidRotations;

	static this()
	{
		for (int i < AvoidTurns)
			sAvoidRotations[i] = Quaternion.AngleAxis(sAvoidAngles[i], Vector3.Up);
	}

	bool mFoundSurface;
	/// Switched on and active last frame (switching off stops it, as OnDisable did).
	bool mWasActive;

	List<Vector3> mPath = new .() ~ delete _;
	List<int32> mLegLinks = new .() ~ delete _;
	// Crossing a link: which, from where to where, and how far (0 to 1).
	NavigationLink mLink;
	Vector3 mLinkFrom, mLinkTo;
	float mLinkProgress;
	Vector3 mVelocity;
	Vector3 mDestination;
	float mSpeed, mStop, mTimer, mRetry, mDeviation;
	int32 mWaypoint, mRevision = -1;
	bool mRequested, mFailed, mDirty, mDriving;
	/// Waiting in sQueue for its path to be found with the others this frame.
	bool mQueued;
	/// Agents whose paths are found together after the frame's Update, on the job threads (FindQueuedPaths).
	static List<NavigationAgentState> sQueue = new .() ~ delete _;
	public bool PathPending => mQueued;
	public bool PathFailed
	{
		get
		{
			FindQueuedPath();
			return mFailed;
		}
	}

	public bool HasArrived
	{
		get
		{
			FindQueuedPath();
			return mRequested && !mFailed && mPath.Count > 0 && mWaypoint >= mPath.Count;
		}
	}

	public List<Vector3> Path
	{
		get
		{
			FindQueuedPath();
			return mPath;
		}
	}

	/// Which leg of Path crosses a link: the link's id on its surface for the leg from point i to i + 1, or -1.
	public List<int32> PathLinks
	{
		get
		{
			FindQueuedPath();
			return mLegLinks;
		}
	}

	/// While crossing a link, that link.
	public NavigationLink CurrentLink => mLink;
	public bool IsCrossingLink => mLink != null;
	/// How fast the agent means to move now (after steering round others).
	public Vector3 Velocity => mVelocity;
	/// How far it still has to go along its path.
	public float RemainingDistance
	{
		get
		{
			FindQueuedPath();
			if (!mRequested || mFailed || mWaypoint >= mPath.Count)
				return 0;
			var total = Distance(Feet, mPath[mWaypoint]);
			for (int i = mWaypoint; i + 1 < mPath.Count; i++)
				total += Distance(mPath[i], mPath[i + 1]);
			return total;
		}
	}

	bool Flying => Surface?.Data?.flying ?? false;
	Vector3 Feet => Transform.Position + baseOffset;
	/// Walking compares positions on the ground plane, so a pivot that floats above or sinks below the baked floor still arrives.
	float Distance(Vector3 a, Vector3 b)
	{
		var d = a - b;
		if (!Flying)
			d.y = 0;
		return d.Length;
	}

	float SegmentDistance(Vector3 point, Vector3 a, Vector3 b)
	{
		var ab = b - a;
		var ap = point - a;
		if (!Flying)
		{
			ab.y = 0;
			ap.y = 0;
		}
		let length = ab.LengthSquared;
		let t = length > 0.000001f ? Mathf.Clamp((ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / length, 0, 1) : 0;
		return (ap - ab * t).Length;
	}

	bool SurfaceFits(NavigationSurface candidate)
	{
		if (Scene.Physics.SeparatesWorldStates)
		{
			// A surface bakes one state: it fits an agent that is in that state.
			let states = GameObject.EffectiveWorldStates & candidate.BakeWorlds;
			return states != 0;
		}
		return candidate.GameObject.InActiveWorld;
	}

	public void SetDestination(Vector3 point, float speed, float stoppingDistance)
	{
		if (NetworkSync.IsClientOf(Scene)) return;
		mSpeed = Math.Max(speed, 0);
		mStop = Math.Max(stoppingDistance, 0.05f);
		// With no surface set, the one in the scene's world state (looked for again when the world state changes);
		// with world states set apart, one sharing the agent's own world states.
		let current = Surface;
		if (current == null || (mFoundSurface && !SurfaceFits(current)))
		{
			for (let component in Scene.ComponentsOfType(typeof(NavigationSurface)))
			{
				if (let candidate = component as NavigationSurface)
				{
					if (candidate.IsActiveAndEnabled && SurfaceFits(candidate))
					{
						if (candidate != current)
							mDirty = true;
						surface = candidate;
						mFoundSurface = true;
						break;
					}
				}
			}
		}
		if (!mRequested || (point - mDestination).LengthSquared > 0.01f)
			mDirty = true;
		mDestination = point;
		mRequested = true;
		if (mDirty && (mTimer <= 0 || mPath.Count == 0))
			Repath();
	}

	/// Asks for a new path: found with the other agents' after this frame's Update (FindQueuedPaths), or at once if
	/// something wants it sooner. The agent keeps to its old path until then.
	void Repath()
	{
		mTimer = Math.Max(repathInterval, 0.01f);
		mDirty = false;
		mRetry = Math.Max(repathInterval, 1);
		if (Surface?.Data == null)
		{
			mQueued = false;
			sQueue.Remove(this);
			mFailed = true;
			mPath.Clear();
			mLegLinks.Clear();
			mWaypoint = 0;
			return;
		}
		if (!mQueued)
		{
			mQueued = true;
			sQueue.Add(this);
		}
		// Outside Scene.Update nothing finds the queue: found now.
		if (Scene == null || !Scene.Updating || !Scene.IsPlaying)
			FindQueuedPath();
	}

	/// Finds this agent's queued path now, on its own.
	void FindQueuedPath()
	{
		if (!mQueued)
			return;
		mQueued = false;
		sQueue.Remove(this);
		let data = Surface?.Data;
		if (data == null)
			return;
		let found = data.FindPath(Feet, mDestination + baseOffset, mPath, mLegLinks, snapDistance, useLinks, smoothPath);
		UsePath(data, found);
	}

	/// Finds every queued agent's path, the agents on each surface together on the job threads. Scene.Update calls it
	/// after the components' Update.
	public static void FindQueuedPaths()
	{
		while (!sQueue.IsEmpty)
		{
			let data = sQueue[0].Surface?.Data;
			let agents = scope List<NavigationAgentState>();
			for (int i = sQueue.Count - 1; i >= 0; i--)
			{
				let agent = sQueue[i];
				if (agent.Surface?.Data == data)
				{
					agents.Add(agent);
					sQueue.RemoveAt(i);
					agent.mQueued = false;
				}
			}
			// Their surface lost its data since they asked: no path, as Repath gives.
			if (data == null)
			{
				for (let agent in agents)
				{
					agent.mFailed = true;
					agent.mPath.Clear();
					agent.mLegLinks.Clear();
					agent.mWaypoint = 0;
				}
				continue;
			}
			// Everything the searches need from the agents is read here, on this thread.
			let requests = scope NavigationData.PathRequest[agents.Count];
			for (int i < agents.Count)
			{
				let agent = agents[i];
				requests[i] = .()
					{
						from = agent.Feet, to = agent.mDestination + agent.baseOffset, path = agent.mPath, legLinks = agent.mLegLinks,
						snapDistance = agent.snapDistance, withLinks = agent.useLinks, smooth = agent.smoothPath
					};
			}
			data.FindPaths(requests);
			for (int i < agents.Count)
				agents[i].UsePath(data, requests[i].found);
		}
	}

	/// Takes a path just found (or its failure).
	void UsePath(NavigationData data, bool found)
	{
		mRevision = data.Revision;
		mWaypoint = 0;
		mFailed = !found;
		if (mFailed)
		{
			mPath.Clear();
			mLegLinks.Clear();
			return;
		}
		// Cells in a straight line become one leg, so the agent does not slow for a waypoint in every cell.
		int kept = 1;
		for (int i = 1; i < mPath.Count; i++)
		{
			if (i < mPath.Count - 1 && mLegLinks[i] < 0 && mLegLinks[i - 1] < 0)
			{
				let a = (mPath[i] - mPath[kept - 1]).Normalized;
				let b = (mPath[i + 1] - mPath[i]).Normalized;
				if (a.x * b.x + a.y * b.y + a.z * b.z > 0.9999f) continue;
			}
			mLegLinks[kept - 1] = mLegLinks[i - 1];
			mPath[kept] = mPath[i];
			mLegLinks[kept] = mLegLinks[i];
			kept++;
		}
		if (kept < mPath.Count)
		{
			mPath.RemoveRange(kept, mPath.Count - kept);
			mLegLinks.RemoveRange(kept, mLegLinks.Count - kept);
		}
		if (mPath.Count > 1)
			mWaypoint = 1;
		// The agent may start up to the snap distance away from the first cell; that much is not being off the path.
		mDeviation = Math.Max(data.cellSize * 1.5f, (mWaypoint == 1 ? SegmentDistance(Feet, mPath[0], mPath[1]) : 0) + data.cellSize * 0.5f);
	}

	public void StopMovement()
	{
		if (mQueued)
		{
			mQueued = false;
			sQueue.Remove(this);
		}
		mRequested = false;
		mDirty = false;
		mPath.Clear();
		mLegLinks.Clear();
		mVelocity = .Zero;
		if (mLink != null)
		{
			let link = mLink;
			mLink = null;
			OnLinkFinished(link);
		}
		mWaypoint = 0;
		Halt();
	}

	/// Stops the velocity this agent was applying. An agent that is not steering leaves its body alone.
	void Halt()
	{
		if (!mDriving) return;
		mDriving = false;
		let body = GetComponent<Rigidbody>();
		if (body.IsValid && body.HasBody && !body.isKinematic)
		{
			var velocity = body.Velocity;
			velocity.x = 0;
			velocity.z = 0;
			if (Flying)
				velocity.y = 0;
			body.Velocity = velocity;
		}
	}

	Vector3 Desired(float dt)
	{
		mVelocity = .Zero;
		if (!mRequested || mFailed || mWaypoint >= mPath.Count || Surface?.Data == null || mLink != null) return .Zero;
		let position = Feet;
		while (mWaypoint < mPath.Count && Distance(mPath[mWaypoint], position) <= (mWaypoint == mPath.Count - 1 ? mStop : Math.Min(0.1f, Surface.Data.cellSize * 0.2f)))
		{
			mWaypoint++;
			// At the start of a link: cross it.
			if (mWaypoint < mPath.Count && mLegLinks.Count == mPath.Count && mLegLinks[mWaypoint - 1] >= 0)
			{
				let link = Surface.LinkOf(mLegLinks[mWaypoint - 1]);
				if (link != null)
				{
					StartLink(link, mPath[mWaypoint - 1], mPath[mWaypoint]);
					return .Zero;
				}
			}
		}
		if (mWaypoint >= mPath.Count) return .Zero;
		var delta = mPath[mWaypoint] - position;
		let body = GetComponent<Rigidbody>();
		// Gravity or the character controller keeps these on the floor, so they are only steered sideways.
		if (((body.IsValid && !body.isKinematic) || HasComponent<CharacterController>()) && !Surface.Data.flying)
			delta.y = 0;
		if (faceMovement && delta.x * delta.x + delta.z * delta.z > 0.00001f)
		{
			var yaw = Math.Atan2(delta.x, delta.z) * Mathf.Rad2Deg;
			if (turnSpeed > 0)
			{
				let forward = Transform.Forward;
				let current = Math.Atan2(forward.x, forward.z) * Mathf.Rad2Deg;
				var turn = yaw - current;
				while (turn > 180)
					turn -= 360;
				while (turn < -180)
					turn += 360;
				yaw = current + Mathf.Clamp(turn, -turnSpeed * dt, turnSpeed * dt);
			}
			Transform.Rotation = Quaternion.Euler(0, yaw, 0);
		}
		if (delta.LengthSquared < 0.00000001f) return .Zero;
		var wanted = delta.Normalized * Math.Min(mSpeed, delta.Length / Math.Max(dt, 0.001f));
		if (avoidOthers)
			wanted = Avoid(wanted, position);
		mVelocity = wanted;
		return wanted;
	}

	/// Picks the velocity nearest the wanted one that does not run into another agent or a moving obstacle in the
	/// next second or so, and that stays on the surface. Agents meeting each take half the turn (reciprocal velocity
	/// obstacles), weighted by priority.
	Vector3 Avoid(Vector3 wanted, Vector3 position)
	{
		using (sAvoidProfile.Sample())
		{
			let data = Surface.Data;
			let horizon = 1.5f;
			let lookAround = radius + mSpeed * horizon + 1;
			// Who is near.
			let others = scope List<(Vector3 position, Vector3 velocity, float radius, float share)>();
			using (sNeighborsProfile.Sample())
			{
				void AddAgent(NavigationAgentState other)
				{
					if (other == this || !other.IsActiveAndEnabled || other.Surface != Surface)
						return;
					let at = other.Feet;
					if (Distance(at, position) > lookAround + other.radius)
						return;
					// Equal priority: each turns half. Against a more important agent this one does it all, against a less
					// important one a quarter.
					let share = other.avoidancePriority > avoidancePriority ? 0.25f : (other.avoidancePriority < avoidancePriority ? 1.0f : 0.5f);
					others.Add((at, other.mVelocity, other.radius, share));
				}
				if (NavigationAgent.UseSpatialAvoidance)
				{
					for (let other in Scene.NavigationCrowd.Query(position, lookAround))
						AddAgent(other);
				}
				else
				{
					for (let agent in Scene.Components<NavigationAgent>(.. scope .()))
						AddAgent(agent.Runtime);
				}
				for (let component in Scene.ComponentsOfType(typeof(NavigationObstacle)))
				{
					let obstacle = (NavigationObstacle)component;
					// A carved obstacle is in the grid already; a moving (or uncarved) one is steered round.
					if (!obstacle.IsActiveAndEnabled || obstacle.Carving)
						continue;
					let at = obstacle.Transform.Position + obstacle.Transform.Rotation * obstacle.center;
					if (Distance(at, position) > lookAround + obstacle.Radius)
						continue;
					others.Add((at, obstacle.Velocity, obstacle.Radius, 1.0f));
				}
			}
			if (others.IsEmpty)
				return wanted;
			using (sSteerProfile.Sample())
			{
				let speed = wanted.Length;
				// Time until this velocity first touches each of the others (a large number when never).
				float TimeToHit(Vector3 velocity)
				{
					var soonest = float.MaxValue;
					for (let other in others)
					{
						// Reciprocal: this agent makes its share of the change and counts on the other making the rest, so the
						// velocity they would close at is its own plus what the other does.
						var relative = mVelocity - other.velocity + (velocity - mVelocity) / other.share;
						var offset = other.position - position;
						if (!Flying)
						{
							relative.y = 0;
							offset.y = 0;
						}
						let reach = radius + other.radius;
						let distanceSquared = offset.LengthSquared;
						if (distanceSquared < reach * reach)
						{
							// Already touching: any velocity that does not move apart counts as an immediate hit.
							if (Vector3.Dot(relative, offset) > 0)
								soonest = 0;
							continue;
						}
						let a = relative.LengthSquared;
						if (a < 0.000001f)
							continue;
						let b = Vector3.Dot(offset, relative);
						let c = distanceSquared - reach * reach;
						let discriminant = b * b - a * c;
						if (b <= 0 || discriminant < 0)
							continue;
						let t = (b - Math.Sqrt(discriminant)) / a;
						if (t >= 0 && t < soonest)
							soonest = t;
					}
					return soonest;
				}
				// A collision-free wanted velocity has score zero, the global minimum of the existing objective.
				// Returning it is equivalent to testing all remaining candidates and rejecting their nonnegative scores.
				if (TimeToHit(wanted) >= horizon) return wanted;
				var best = wanted;
				var bestScore = float.MaxValue;
				for (int s < 3)
				{
					let scale = s == 0 ? 1.0f : (s == 1 ? 0.6f : 0.3f);
					for (int a < AvoidTurns)
					{
						// 0, then turning further each side.
						let candidate = sAvoidRotations[a] * wanted * scale;
						let hit = TimeToHit(candidate);
						// Being near what is wanted, and not running into anything soon.
						var score = (candidate - wanted).Length + (hit < horizon ? speed * 2 * (horizon - hit) / horizon + 0.5f : 0);
						if (score >= bestScore)
							continue;
						// It must stay on the surface for the next moment.
						if (a != 0 && !data.LineClear(position, position + candidate * 0.4f, ?))
							continue;
						best = candidate;
						bestScore = score;
					}
				}
				// Standing still is the last resort.
				if (TimeToHit(.Zero) >= horizon && speed * 2.5f < bestScore)
					best = .Zero;
				return best;
			}
		}
	}

	void StartLink(NavigationLink link, Vector3 from, Vector3 to)
	{
		mLink = link;
		// From where the agent is to the cell past the link, so it carries on from there.
		mLinkFrom = Feet;
		mLinkTo = to;
		mLinkProgress = 0;
		Halt();
		OnLinkStarted(link);
	}

	/// Moves along a link: kinematically, whatever moves the agent otherwise.
	void CrossLink(float dt)
	{
		let link = mLink;
		let duration = link.kind == .Teleport ? 0 : Math.Max(link.duration, 0.01f);
		mLinkProgress = duration > 0 ? Math.Min(mLinkProgress + dt / duration, 1) : 1;
		let point = link.Along(mLinkFrom, mLinkTo, mLinkProgress);
		if (faceMovement)
		{
			let flat = Vector3(mLinkTo.x - mLinkFrom.x, 0, mLinkTo.z - mLinkFrom.z);
			if (flat.LengthSquared > 0.0001f)
				Transform.Rotation = Quaternion.Euler(0, Math.Atan2(flat.x, flat.z) * Mathf.Rad2Deg, 0);
		}
		Place(point - baseOffset);
		if (mLinkProgress < 1)
			return;
		mLink = null;
		// On to the leg after the link.
		mWaypoint = Math.Min(mWaypoint + 1, (int32)mPath.Count);
		if (mWaypoint < mPath.Count)
			mDeviation = Math.Max(mDeviation, Distance(Feet, mPath[mWaypoint - 1]) + Surface.Data.cellSize);
		OnLinkFinished(link);
	}

	/// Puts the agent somewhere directly (crossing a link), through its controller or body when it has one.
	void Place(Vector3 position)
	{
		let controller = GetComponent<CharacterController>();
		if (controller.IsValid)
		{
			controller.Teleport(position);
			return;
		}
		let body = GetComponent<Rigidbody>();
		if (body.IsValid && body.HasBody && !body.isKinematic)
		{
			var state = body.State;
			state.position = position;
			state.linearVelocity = .Zero;
			body.SetState(state);
		}
		Transform.Position = position;
	}

	/// What OnLocalUpdate did: once a frame while playing (NavigationAgent.FrameAll).
	public void Frame()
	{
		// In multiplayer the server moves agents; a client's copy follows what the server sends.
		if (NetworkSync.IsClientOf(Scene)) return;
		mTimer -= Time.DeltaTime;
		if (mRequested)
		{
			let data = Surface?.Data;
			if (data != null && data.Revision != mRevision)
				mDirty = true;
			// A failed search is retried slowly in case the agent has since moved somewhere routable.
			if (mFailed)
			{
				mRetry -= Time.DeltaTime;
				if (mRetry <= 0)
					mDirty = true;
			}
			else if (mWaypoint > 0 && mWaypoint < mPath.Count && SegmentDistance(Feet, mPath[mWaypoint - 1], mPath[mWaypoint]) > mDeviation)
				mDirty = true;
			if (mDirty && mTimer <= 0)
				Repath();
		}
		let body = GetComponent<Rigidbody>();
		if (!HasComponent<CharacterController>() && (!body.IsValid || body.isKinematic))
		{
			if (mLink != null)
				CrossLink(Time.DeltaTime);
			else
				Transform.Position += Desired(Time.DeltaTime) * Time.DeltaTime;
		}
	}

	/// What FixedUpdate did: once a tick while playing (NavigationAgent.TickAll).
	public void Tick()
	{
		if (NetworkSync.IsClientOf(Scene)) return;
		let controller = GetComponent<CharacterController>();
		let physical = controller.IsValid || GetComponent<Rigidbody>().HasBody && !GetComponent<Rigidbody>().isKinematic;
		if (mLink != null && physical)
		{
			CrossLink(Time.FixedDeltaTime);
			return;
		}
		if (controller.IsValid)
		{
			// A character controller walks the path itself: it climbs steps, stays on slopes and keeps falling when idle.
			let wanted = Desired(Time.FixedDeltaTime);
			if (Flying)
				controller.Move(wanted, Time.FixedDeltaTime);
			else
				controller.SimpleMove(wanted, Time.FixedDeltaTime);
			return;
		}
		let body = GetComponent<Rigidbody>();
		if (!body.IsValid || body.isKinematic || !body.HasBody) return;
		let desired = Desired(Time.FixedDeltaTime);
		// Velocity is only written while following a path; an idle or arrived agent can be pushed, thrown or dropped.
		if (!mRequested || mFailed || mWaypoint >= mPath.Count)
		{
			Halt();
			return;
		}
		mDriving = true;
		var velocity = body.Velocity;
		velocity.x = desired.x;
		velocity.z = desired.z;
		if (Flying)
			velocity.y = desired.y;
		body.Velocity = velocity;
	}

	/// While selected: its path, with link legs dashed orange.
	public void DrawGizmos(bool selected)
	{
		if (!selected || mPath.Count == 0)
			return;
		let lift = Vector3(0, 0.08f, 0);
		for (int i = Math.Max(mWaypoint - 1, 0); i + 1 < mPath.Count; i++)
		{
			let link = mLegLinks.Count == mPath.Count && mLegLinks[i] >= 0;
			Gizmos.Lines.Line(mPath[i] + lift, mPath[i + 1] + lift, link ? Color(1, 0.6f, 0.1f, 1) : Color(0.3f, 1, 0.4f, 1));
		}
		if (mWaypoint < mPath.Count)
			Gizmos.Lines.Line(Feet + lift, mPath[mWaypoint] + lift, .(0.3f, 1, 0.4f, 0.6f));
		Gizmos.Lines.Circle(Feet + lift, .Up, radius, .(0.3f, 1, 0.4f, 0.6f), 24);
	}
}
