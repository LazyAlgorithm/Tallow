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
/// Tick.Navigation step after their FixedUpdate, as OnLocalUpdate and FixedUpdate did, all of a scene's agents
/// together (Scene.NavigationAgents, NavigationAgentSystem): they follow their paths oldest first, then steer round
/// each other at once on the job threads.
[Component, HandleFields]
struct NavigationAgent : ComponentHandle<NavigationAgentData>
{
	/// Steering round others looks only at the agents near this one (a grid of where they are, made each step); off, at
	/// every agent in the scene, for comparing.
	public static bool UseSpatialAvoidance = true;

	/// Its path and steering, made (and listed in the scene's crowd) the first time it is asked for.
	public NavigationAgentState Runtime
	{
		get
		{
			CheckValid();
			return StateOf(mGameObject);
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

	/// The state of the agent on an object that has one, made (and listed in the scene's crowd) the first time.
	static NavigationAgentState StateOf(GameObject gameObject)
	{
		let world = gameObject.Scene.World;
		let state = ComponentState<NavigationAgentState>.Make(world, gameObject.Entity);
		if (state.[Friend]mGameObject == null)
		{
			state.[Friend]Bind(gameObject);
			gameObject.Scene.NavigationCrowd.Register(state);
		}
		return state;
	}

	/// Moves every switched-on agent on an active object a frame on, and stops one whose object has been switched off
	/// (OnSwitched stops one switched off itself). In multiplayer only the server moves agents; a client's copies follow
	/// what it sends.
	public static void FrameAll(Scene scene)
	{
		if (!scene.IsPlaying || scene.World.Count(DataIndex) == 0 || NetworkSync.IsClientOf(scene))
			return;
		scene.NavigationAgents.Frame();
	}

	/// Moves every switched-on agent on an active object a fixed tick on (through its controller or body).
	public static void TickAll(Scene scene)
	{
		if (!scene.IsPlaying || scene.World.Count(DataIndex) == 0 || NetworkSync.IsClientOf(scene))
			return;
		scene.NavigationAgents.Tick();
	}

	/// Switched off (or its object, or play stopped): it stops, as OnDisable did.
	static void OnSwitched(GameObject gameObject, bool on)
	{
		if (on)
			return;
		if (let state = ComponentState<NavigationAgentState>.Get(gameObject.Scene.World, gameObject.Entity))
		{
			state.[Friend]mWasActive = false;
			state.StopMovement();
		}
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		if (selected && gameObject.Scene != null)
			gameObject.GetComponent<NavigationAgent>().Runtime.DrawGizmos(selected);
	}

	/// Listed in the scene's crowd as soon as it is added (as OnRegister did), so the crowd index and the other
	/// agents' avoidance see it before its first frame and in edit mode.
	static void ReadRuntime(NavigationAgentState state) { }
	static void OnAdded(GameObject gameObject)
	{
		if (gameObject.Scene != null)
			ReadRuntime(gameObject.GetComponent<NavigationAgent>().Runtime);
	}

	static void OnRemove(void* world, uint64 entity)
	{
		if (let state = ComponentState<NavigationAgentState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
		{
			state.[Friend]Leave();
			NavigationAgentSystem.sReleased++;
		}
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
	// The settings, through a reference that follows the entity's data (a version compare, not a lookup, per read).
	ComponentRef<NavigationAgentData> mSettings;
	World mWorld;
	ref NavigationAgentData Settings
	{
		[Inline]
		get
		{
			let world = mGameObject.Scene.World;
			if (world != mWorld)
				Bind(mGameObject);
			return ref *mSettings.Get(world);
		}
	}

	void Bind(GameObject gameObject)
	{
		mGameObject = gameObject;
		mWorld = gameObject.Scene.World;
		mSettings = .(mWorld, gameObject.Entity);
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

	bool mFoundSurface;
	/// Its place in this step's NavigationAgentSystem members, or -1.
	int32 mMember = -1;
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

	/// Moves on along the path (waypoints passed, a link reached, turning to face the way) and returns the velocity it
	/// wants before steering round others; steer says whether it should steer (NavigationAgentSystem does that for
	/// every agent at once).
	Vector3 Prepare(float dt, out bool steer)
	{
		steer = false;
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
		mVelocity = wanted;
		steer = avoidOthers && (wanted.x != 0 || wanted.y != 0 || wanted.z != 0);
		return wanted;
	}

	/// The velocity steering round the others would pick for this agent wanting `wanted` at position, against where
	/// they are now.
	Vector3 Avoid(Vector3 wanted, Vector3 position) => Scene.NavigationAgents.SteerNow(this, wanted, position);

	/// Moves on along the path and either moves now (not steering round others) or asks the system to steer first.
	void Follow(NavigationAgentSystem system, NavigationAgentSystem.Drive drive, float dt)
	{
		let wanted = Prepare(dt, let steer);
		if (steer)
			system.Request(this, drive, Feet, wanted, mSpeed, Surface.Data);
		else
		{
			ApplySteering(drive, wanted);
			system.Moved(this, drive, wanted);
		}
	}

	/// Goes at the velocity steering chose (or the one it wanted), the way its drive moves it.
	void ApplySteering(NavigationAgentSystem.Drive drive, Vector3 velocity)
	{
		mVelocity = velocity;
		switch (drive)
		{
		case .Transform:
			Transform.Position += velocity * Time.DeltaTime;
		case .Controller:
			let controller = GetComponent<CharacterController>();
			if (!controller.IsValid)
				return;
			if (Flying)
				controller.Move(velocity, Time.FixedDeltaTime);
			else
				controller.SimpleMove(velocity, Time.FixedDeltaTime);
		case .Body:
			let body = GetComponent<Rigidbody>();
			if (!body.IsValid || body.isKinematic || !body.HasBody)
				return;
			// Velocity is only written while following a path; an idle or arrived agent can be pushed, thrown or dropped.
			if (!mRequested || mFailed || mWaypoint >= mPath.Count)
			{
				Halt();
				return;
			}
			mDriving = true;
			var current = body.Velocity;
			current.x = velocity.x;
			current.z = velocity.z;
			if (Flying)
				current.y = velocity.y;
			body.Velocity = current;
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

	/// Moves this agent a frame on, on its own (agents are moved together each frame while playing; this is for code
	/// that drives one itself). It steers round the others as they are now.
	public void Frame()
	{
		// In multiplayer the server moves agents; a client's copy follows what the server sends.
		if (Scene == null || NetworkSync.IsClientOf(Scene)) return;
		Scene.NavigationAgents.StepOne(this, false);
	}

	/// Moves this agent a fixed tick on (through its controller or body), on its own.
	public void Tick()
	{
		if (Scene == null || NetworkSync.IsClientOf(Scene)) return;
		Scene.NavigationAgents.StepOne(this, true);
	}

	/// What OnLocalUpdate did: once a frame while playing (NavigationAgentSystem.Frame).
	void FrameStep(NavigationAgentSystem system)
	{
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
		if (HasComponent<CharacterController>())
			return;
		let body = GetComponent<Rigidbody>();
		if (body.IsValid && !body.isKinematic)
			return;
		if (mLink != null)
			CrossLink(Time.DeltaTime);
		else
			Follow(system, .Transform, Time.DeltaTime);
	}

	/// What FixedUpdate did: once a tick while playing (NavigationAgentSystem.Tick).
	void TickStep(NavigationAgentSystem system)
	{
		let controller = GetComponent<CharacterController>();
		let body = GetComponent<Rigidbody>();
		let physical = controller.IsValid || body.HasBody && !body.isKinematic;
		if (mLink != null && physical)
		{
			CrossLink(Time.FixedDeltaTime);
			return;
		}
		if (controller.IsValid)
		{
			// A character controller walks the path itself: it climbs steps, stays on slopes and keeps falling when idle.
			Follow(system, .Controller, Time.FixedDeltaTime);
			return;
		}
		if (!body.IsValid || body.isKinematic || !body.HasBody)
			return;
		Follow(system, .Body, Time.FixedDeltaTime);
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
