using System;
using System.Collections;

namespace Tallow;

/// The objects with one kind of switched-on handle component (BehaviorTreeRunner, NavigationAgent), straight from a
/// cached Flecs query, in object id order so that what one does before another is the same on every run and
/// machine. A frame where nothing was added, removed or switched costs one walk over the query's entity ids; only a
/// change sorts the list again.
class HandleRoster
{
	public struct Entry
	{
		public Entity entity;
		public GameObject gameObject;
	}

	Scene mScene;
	int32 mIndex;
	IndexQuery mQuery ~ delete _;
	List<uint64> mSeen = new .() ~ delete _;
	/// The objects, oldest (lowest id) first. Valid until the next Refresh.
	public List<Entry> Entries = new .() ~ delete _;

	/// dataIndex: the ComponentTypes index of the handle's data (T.DataIndex).
	public this(Scene scene, int32 dataIndex)
	{
		mScene = scene;
		mIndex = dataIndex;
	}

	/// Brings Entries up to date with the world; true when they changed.
	public bool Refresh()
	{
		if (mQuery == null)
		{
			int32[2] types = .(mIndex, ComponentId<ObjectLink>.Index);
			Flecs.TermAccess[2] access = .(.Filter, .Read);
			mQuery = new IndexQuery(mScene.World, types, access);
		}
		int count = 0;
		bool changed = false;
		for (var chunk in mQuery)
		{
			for (let entity in chunk.Entities)
			{
				if (count < mSeen.Count)
				{
					if (mSeen[count] != entity.id)
					{
						mSeen[count] = entity.id;
						changed = true;
					}
				}
				else
				{
					mSeen.Add(entity.id);
					changed = true;
				}
				count++;
			}
		}
		if (count != mSeen.Count)
		{
			mSeen.Count = count;
			changed = true;
		}
		if (!changed)
			return false;
		Entries.Clear();
		for (var chunk in mQuery)
		{
			let entities = chunk.Entities;
			let links = chunk.Read<ObjectLink>();
			for (int i < chunk.Count)
				Entries.Add(.() { entity = entities[i], gameObject = links[i].gameObject });
		}
		Entries.Sort(scope (a, b) => a.gameObject.Id <=> b.gameObject.Id);
		return true;
	}
}

/// Ticks a scene's behaviour trees (Scene.BehaviorTrees): every switched-on Behavior Tree Runner on an active object,
/// oldest object first, once a frame in the Frame.Behaviour step. The runners come from Flecs (HandleRoster) and each
/// state reads its settings through a ComponentRef, so a frame does no search of the scene and no lookup per setting.
/// Trees still tick one after another on the main thread: their nodes (and a project's own) may touch any object.
class BehaviorTreeSystem
{
	Scene mScene;
	HandleRoster mRoster ~ delete _;
	List<BehaviorTreeRunnerState> mStates = new .() ~ delete _;
	/// Goes up whenever a runner's state is freed (BehaviorTreeRunner.OnRemove), so a frame that removes one checks the
	/// rest before using them.
	public static int32 sReleased;

	public this(Scene scene)
	{
		mScene = scene;
	}

	/// How many runners the last frame looked at (for tests and the profiler).
	public int Count => mStates.Count;

	public void Frame()
	{
		if (mRoster == null)
			mRoster = new .(mScene, BehaviorTreeRunner.DataIndex);
		let world = mScene.World;
		if (mRoster.Refresh())
		{
			mStates.Clear();
			for (let entry in mRoster.Entries)
				mStates.Add(BehaviorTreeRunner.[Friend]StateOf(entry.gameObject));
		}
		let released = sReleased;
		for (int i < mStates.Count)
		{
			var state = mStates[i];
			// A tree removed a runner (or destroyed its object at once): the states left are looked up again.
			if (sReleased != released)
			{
				state = ComponentState<BehaviorTreeRunnerState>.Get(world, mRoster.Entries[i].entity);
				if (state == null)
					continue;
			}
			let gameObject = state.[Friend]mGameObject;
			if (!gameObject.ActiveInHierarchy)
			{
				if (state.[Friend]mWasActive)
				{
					state.[Friend]mWasActive = false;
					state.OnDisable();
				}
				continue;
			}
			state.[Friend]mWasActive = true;
			if (!state.[Friend]mStarted)
			{
				state.[Friend]mStarted = true;
				state.Start();
			}
			state.Frame();
		}
	}
}

/// Moves a scene's Navigation Agents (Scene.NavigationAgents), in the Frame.Navigation step (agents moved by their
/// transform) and the Tick.Navigation step (agents walking through a Character Controller or Rigidbody).
///
/// Each step works in three passes. First, where every switched-on agent and moving obstacle stands and how fast it
/// goes is copied into packed arrays and sorted into a PointGrid. Then each agent, oldest first, follows its path on
/// the main thread (waypoints, links, turning, asking for paths) and says which way it wants to go. Then the steering
/// round each other (reciprocal velocity obstacles) runs on the job threads, tile by tile (Steer), reading and
/// updating only the packed copy, and the results are applied oldest first. Agents steer one after another as they
/// did when each moved in its own update, so crowds behave as before; the result does not depend on how many threads
/// there are.
class NavigationAgentSystem
{
	/// One agent or moving obstacle, as it was at the start of the step.
	public struct Member
	{
		public Vector3 position;
		public Vector3 velocity;
		public float radius;
		/// Its avoidance priority; Obstacle for a Navigation Obstacle.
		public int32 priority;
		/// The surface it walks on (agents only meet agents on the same one); null for an obstacle, which every agent
		/// steers round.
		public NavigationSurface surface;
	}

	public const int32 Obstacle = int32.MinValue;

	/// What moves an agent, and so how its steered velocity is applied.
	public enum Drive : uint8
	{
		/// Its transform, in the frame step.
		Transform,
		/// A Character Controller, in the tick step.
		Controller,
		/// A dynamic Rigidbody's velocity, in the tick step.
		Body
	}

	/// An agent that wants to steer round the others this step.
	public struct Request
	{
		public NavigationAgentState agent;
		/// Its place in the members (to leave itself out), or -1.
		public int32 member;
		public Drive drive;
		public bool flying;
		public Vector3 position;
		public Vector3 wanted;
		/// The speed it was asked to go (how far ahead it looks).
		public float speed;
		public float radius;
		public int32 priority;
		public NavigationSurface surface;
		public NavigationData data;
		/// What the steering chose.
		public Vector3 result;
	}

	struct Other
	{
		public Vector3 position;
		public Vector3 velocity;
		public float radius;
		public float share;
	}

	class Scratch
	{
		public List<int32> near = new .() ~ delete _;
		public List<Other> others = new .() ~ delete _;
	}

	Scene mScene;
	HandleRoster mRoster ~ delete _;
	List<NavigationAgentState> mStates = new .() ~ delete _;
	List<Member> mMembers = new .() ~ delete _;
	List<Vector3> mPositions = new .() ~ delete _;
	PointGrid mGrid = new .() ~ delete _;
	float mLargestRadius;
	/// The furthest an agent has moved since the grid was built, in this step (agents that do not steer, then each
	/// steered one): how much further than they look round the grid is searched.
	float mMoveSlack;
	List<Request> mRequests = new .() ~ delete _;
	List<Request> mOneRequests = new .() ~ delete _;
	/// Where Request adds to: mRequests during a step, mOneRequests for StepOne.
	List<Request> mTarget;
	bool mStepping;
	List<Scratch> mScratch = new .() ~ DeleteContainerAndItems!(_);
	List<NavigationData> mPrepared = new .() ~ delete _;
	/// Goes up whenever an agent's state is freed (NavigationAgent.OnRemove).
	public static int32 sReleased;

	static ProfilerMarker sSnapshotMarker = .("Navigation.Snapshot", .AI);
	static ProfilerMarker sFollowMarker = .("Navigation.Follow", .AI);
	static ProfilerMarker sAvoidMarker = .("Navigation.Avoid", .AI);
	static ProfilerMarker sApplyMarker = .("Navigation.Apply", .AI);

	/// The turns steering tries each side of the wanted direction, in degrees.
	const int AvoidTurns = 11;
	static float[AvoidTurns] sAvoidAngles = .(0, 15, -15, 30, -30, 50, -50, 75, -75, 105, -105);
	static Quaternion[AvoidTurns] sAvoidRotations;
	/// How far ahead (seconds) steering looks for a collision.
	const float Horizon = 1.5f;

	static this()
	{
		for (int i < AvoidTurns)
			sAvoidRotations[i] = Quaternion.AngleAxis(sAvoidAngles[i], Vector3.Up);
	}

	public this(Scene scene)
	{
		mScene = scene;
	}

	/// How many agents the last step looked at (for tests).
	public int Count => mStates.Count;
	/// How many agents steered round others in the last step (for tests).
	public int SteeredCount => mRequests.Count;

	/// The agents moved by their transform, a frame on.
	public void Frame() => Step(false);

	/// The agents moved by a controller or body, a fixed tick on.
	public void Tick() => Step(true);

	void Refresh()
	{
		if (mRoster == null)
			mRoster = new .(mScene, NavigationAgent.DataIndex);
		if (mRoster.Refresh())
		{
			mStates.Clear();
			for (let entry in mRoster.Entries)
				mStates.Add(NavigationAgent.[Friend]StateOf(entry.gameObject));
		}
	}

	/// Moves one agent on its own, a frame (tick false) or a fixed tick on: NavigationAgentState.Frame and Tick, for
	/// code that drives an agent itself. It steers round the others as they are now.
	public void StepOne(NavigationAgentState agent, bool tick)
	{
		// From inside a step (a link handler moving another agent) the step's copy of the others is used as it is.
		if (!mStepping)
		{
			Refresh();
			agent.[Friend]mMember = -1;
			Snapshot();
		}
		mOneRequests.Clear();
		let previous = mTarget;
		mTarget = mOneRequests;
		if (tick)
			agent.[Friend]TickStep(this);
		else
			agent.[Friend]FrameStep(this);
		mTarget = previous;
		if (mOneRequests.IsEmpty)
			return;
		var request = mOneRequests[0];
		mOneRequests.Clear();
		while (mScratch.Count < Jobs.ThreadCount)
			mScratch.Add(new .());
		request.data.PrepareLines(Jobs.ThreadCount);
		request.result = SteerOne(request, NavigationAgent.UseSpatialAvoidance, mScratch[Jobs.ThreadIndex], Jobs.ThreadIndex);
		agent.[Friend]ApplySteering(request.drive, request.result);
	}

	/// The velocity steering picks for an agent that wants `wanted` at position, against the others as they are now
	/// (what each step does for every agent; NavigationAgentState.Avoid).
	public Vector3 SteerNow(NavigationAgentState agent, Vector3 wanted, Vector3 position)
	{
		let data = agent.Surface?.Data;
		if (data == null)
			return wanted;
		if (!mStepping)
		{
			Refresh();
			agent.[Friend]mMember = -1;
			Snapshot();
		}
		Request request = default;
		request.agent = agent;
		request.member = agent.[Friend]mMember;
		request.data = data;
		request.flying = data.flying;
		request.position = position;
		request.wanted = wanted;
		request.speed = agent.[Friend]mSpeed;
		request.radius = agent.radius;
		request.priority = agent.avoidancePriority;
		request.surface = agent.Surface;
		while (mScratch.Count < Jobs.ThreadCount)
			mScratch.Add(new .());
		data.PrepareLines(Jobs.ThreadCount);
		return SteerOne(request, NavigationAgent.UseSpatialAvoidance, mScratch[Jobs.ThreadIndex], Jobs.ThreadIndex);
	}

	void Step(bool tick)
	{
		Refresh();
		let world = mScene.World;
		if (mStates.IsEmpty)
			return;
		mStepping = true;
		defer
		{
			mStepping = false;
		}
		Snapshot();
		mRequests.Clear();
		mTarget = mRequests;
		using (sFollowMarker.Sample())
		{
			let released = sReleased;
			for (int i < mStates.Count)
			{
				var state = mStates[i];
				if (sReleased != released)
				{
					state = ComponentState<NavigationAgentState>.Get(world, mRoster.Entries[i].entity);
					if (state == null)
						continue;
				}
				if (tick)
				{
					if (state.[Friend]mGameObject.ActiveInHierarchy)
						state.[Friend]TickStep(this);
					continue;
				}
				if (!state.[Friend]mGameObject.ActiveInHierarchy)
				{
					if (state.[Friend]mWasActive)
					{
						state.[Friend]mWasActive = false;
						state.StopMovement();
					}
					continue;
				}
				state.[Friend]mWasActive = true;
				state.[Friend]FrameStep(this);
			}
		}
		if (mRequests.IsEmpty)
			return;
		Steer();
		using (sApplyMarker.Sample())
		{
			let released = sReleased;
			for (let request in mRequests)
			{
				// An OnLinkStarted handler or the like removed agents: skip those that went.
				if (sReleased != released && !Alive(request.agent))
					continue;
				request.agent.[Friend]ApplySteering(request.drive, request.result);
			}
		}
	}

	bool Alive(NavigationAgentState agent)
	{
		for (let entry in mRoster.Entries)
		{
			if (ComponentState<NavigationAgentState>.Get(mScene.World, entry.entity) == agent)
				return true;
		}
		return false;
	}

	/// Copies where every switched-on agent on an active object and every moving obstacle is, and how fast it goes.
	void Snapshot()
	{
		using (sSnapshotMarker.Sample())
		{
			mMembers.Clear();
			mPositions.Clear();
			mLargestRadius = 0;
			mMoveSlack = 0;
			for (let state in mStates)
			{
				state.[Friend]mMember = -1;
				let gameObject = state.[Friend]mGameObject;
				if (gameObject == null || gameObject.IsGoing || !gameObject.ActiveInHierarchy)
					continue;
				state.[Friend]mMember = (int32)mMembers.Count;
				let radius = state.radius;
				mMembers.Add(.() { position = state.[Friend]Feet, velocity = state.Velocity, radius = radius, priority = state.avoidancePriority, surface = state.Surface });
				mLargestRadius = Math.Max(mLargestRadius, radius);
			}
			for (let component in mScene.ComponentsOfType(typeof(NavigationObstacle)))
			{
				let obstacle = (NavigationObstacle)component;
				// A carved obstacle is in the grid already; a moving (or uncarved) one is steered round.
				if (!obstacle.IsActiveAndEnabled || obstacle.Carving)
					continue;
				let radius = obstacle.Radius;
				mMembers.Add(.() { position = obstacle.Transform.Position + obstacle.Transform.Rotation * obstacle.center, velocity = obstacle.Velocity, radius = radius, priority = Obstacle });
				mLargestRadius = Math.Max(mLargestRadius, radius);
			}
			for (let member in mMembers)
				mPositions.Add(member.position);
			mGrid.Build(mPositions, 4);
		}
	}

	/// An agent that does not steer has moved at velocity (NavigationAgentState.Follow): the step's copy of it is
	/// brought up to date, so the agents steering after it see where it is going, as they would one after another.
	public void Moved(NavigationAgentState agent, Drive drive, Vector3 velocity)
	{
		let index = agent.[Friend]mMember;
		if (index < 0 || index >= mMembers.Count || mTarget != mRequests)
			return;
		ref Member member = ref mMembers[index];
		member.velocity = velocity;
		if (drive == .Transform)
		{
			member.position += velocity * Time.DeltaTime;
			mMoveSlack = Math.Max(mMoveSlack, velocity.Length * Time.DeltaTime);
		}
	}

	/// An agent asks to steer round the others from position towards wanted (NavigationAgentState.Frame and Tick).
	public void Request(NavigationAgentState agent, Drive drive, Vector3 position, Vector3 wanted, float speed, NavigationData data)
	{
		Request request = default;
		request.agent = agent;
		request.member = agent.[Friend]mMember;
		request.drive = drive;
		request.data = data;
		request.flying = data.flying;
		request.position = position;
		request.wanted = wanted;
		request.speed = speed;
		request.radius = agent.radius;
		request.priority = agent.avoidancePriority;
		request.surface = agent.Surface;
		request.result = wanted;
		mTarget.Add(request);
	}

	// Steering's tiles: the requests in each, and each 2 x 2 colour's tiles.
	Dictionary<int64, List<int32>> mTiles = new .() ~ DeleteDictionaryAndValues!(_);
	List<List<int32>>[4] mPhases = .(new .(), new .(), new .(), new .()) ~ { for (let phase in _) delete phase; };

	/// Steers the requests one after another, oldest first, each seeing where the ones before it are going (as when
	/// agents moved one at a time), but tile by tile so the job threads share the work: requests are sorted into square
	/// tiles wider than any agent looks round, and the tiles of one colour of a 2 x 2 checkerboard are at least a tile
	/// apart, so their agents never see each other and every tile of a colour runs at once. Which thread runs a tile
	/// does not change anything: the result depends only on where the agents are and their order.
	void Steer()
	{
		using (sAvoidMarker.Sample())
		{
			let threads = Jobs.ThreadCount;
			while (mScratch.Count < threads)
				mScratch.Add(new .());
			// Path data is read by many threads at once: anything it builds lazily is built first, here.
			mPrepared.Clear();
			float reach = 0, moving = 0;
			for (let request in mRequests)
			{
				if (!mPrepared.Contains(request.data))
				{
					mPrepared.Add(request.data);
					request.data.PrepareLines(threads);
				}
				// How far it looks round, plus the widest other and how far agents move while their tiles run.
				let step = request.drive == .Transform ? Time.DeltaTime : Time.FixedDeltaTime;
				reach = Math.Max(reach, request.radius + request.speed * Horizon + 1 + mLargestRadius + request.speed * step * 2 + 0.1f);
				if (request.drive == .Transform)
					moving = Math.Max(moving, request.speed * step);
			}
			mMoveSlack += moving;
			// Without the grid (UseSpatialAvoidance off, for comparing) every agent looks at every other: one tile.
			let spatial = NavigationAgent.UseSpatialAvoidance;
			let tile = spatial ? Math.Max(reach + mMoveSlack, 1) : float.MaxValue;
			if (mTiles.Count > 4096)
			{
				for (let list in mTiles.Values)
					delete list;
				mTiles.Clear();
			}
			for (let list in mTiles.Values)
				list.Clear();
			for (let phase in mPhases)
				phase.Clear();
			for (int32 i < (int32)mRequests.Count)
			{
				let p = mRequests[i].position;
				let tx = p.x.IsFinite ? (int32)Math.Floor(p.x / tile) : 0;
				let tz = p.z.IsFinite ? (int32)Math.Floor(p.z / tile) : 0;
				let key = ((int64)tx << 32) | (uint32)tz;
				List<int32> list;
				if (!mTiles.TryGetValue(key, out list))
				{
					list = new .();
					mTiles[key] = list;
				}
				if (list.IsEmpty)
					mPhases[(tx & 1) | ((tz & 1) << 1)].Add(list);
				list.Add(i);
			}
			for (let phase in mPhases)
			{
				Jobs.For(phase.Count, scope [&] (index) =>
					{
						let scratch = mScratch[Jobs.ThreadIndex];
						for (let i in phase[index])
						{
							ref Request request = ref mRequests[i];
							request.result = SteerOne(request, spatial, scratch, Jobs.ThreadIndex);
							// The agents after it in its tile see where it is going.
							if (request.member >= 0)
							{
								ref Member member = ref mMembers[request.member];
								member.velocity = request.result;
								if (request.drive == .Transform)
									member.position += request.result * Time.DeltaTime;
							}
						}
					});
			}
		}
	}

	/// Picks the velocity nearest the wanted one that does not run into another agent or a moving obstacle in the
	/// next second or so, and that stays on the surface. Agents meeting each take half the turn (reciprocal velocity
	/// obstacles), weighted by priority. Reads only the step's copy of the members, so any thread can run it.
	Vector3 SteerOne(Request request, bool spatial, Scratch scratch, int worker)
	{
		let position = request.position;
		let wanted = request.wanted;
		let flying = request.flying;
		let self = request.member;
		let surface = request.surface;
		let priority = request.priority;
		let data = request.data;
		let lookAround = request.radius + request.speed * Horizon + 1;
		float Distance(Vector3 a, Vector3 b)
		{
			var d = a - b;
			if (!flying)
				d.y = 0;
			return d.Length;
		}
		// Who is near.
		let others = scratch.others;
		others.Clear();
		let near = scratch.near;
		near.Clear();
		if (spatial)
			mGrid.Query(position, lookAround + mLargestRadius + mMoveSlack, near);
		else
		{
			for (int32 i < (int32)mMembers.Count)
				near.Add(i);
		}
		for (let index in near)
		{
			if (index == self)
				continue;
			ref Member other = ref mMembers[index];
			if (other.priority != Obstacle && other.surface != surface)
				continue;
			if (Distance(other.position, position) > lookAround + other.radius)
				continue;
			// Equal priority: each turns half. Against a more important agent this one does it all, against a less
			// important one a quarter. An obstacle does not turn at all.
			float share = 1;
			if (other.priority != Obstacle)
				share = other.priority > priority ? 0.25f : (other.priority < priority ? 1.0f : 0.5f);
			others.Add(.() { position = other.position, velocity = other.velocity, radius = other.radius, share = share });
		}
		if (others.IsEmpty)
			return wanted;
		let speed = wanted.Length;
		let radius = request.radius;
		// Time until this velocity first touches each of the others (a large number when never).
		float TimeToHit(Vector3 velocity)
		{
			var soonest = float.MaxValue;
			for (let other in others)
			{
				// Reciprocal: this agent makes its share of the change and counts on the other making the rest, so the
				// velocity they would close at is its own plus what the other does.
				var relative = velocity / other.share - other.velocity;
				var offset = other.position - position;
				if (!flying)
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
		// A collision-free wanted velocity scores zero, the lowest any candidate can.
		if (TimeToHit(wanted) >= Horizon)
			return wanted;
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
				var score = (candidate - wanted).Length + (hit < Horizon ? speed * 2 * (Horizon - hit) / Horizon + 0.5f : 0);
				if (score >= bestScore)
					continue;
				// It must stay on the surface for the next moment.
				if (a != 0 && !data.LineClear(position, position + candidate * 0.4f, ?, worker))
					continue;
				best = candidate;
				bestScore = score;
			}
		}
		// Standing still is the last resort.
		if (TimeToHit(.Zero) >= Horizon && speed * 2.5f < bestScore)
			best = .Zero;
		return best;
	}
}
