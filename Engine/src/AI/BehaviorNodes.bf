using System;
using System.Collections;
using System.Reflection;

namespace Tallow;

// ---- flow control ----

class BTRoot : BTNode
{
	protected override BTStatus OnTick(BTContext context) => children.Count > 0 ? children[0].Tick(context) : .Failure;
}

/// Runs children left to right until one fails. A running child is resumed next tick.
class BTSequence : BTNode
{
	int mIndex;
	protected override void OnStart(BTContext context)
	{
		mIndex = 0;
	}

	protected override BTStatus OnTick(BTContext context)
	{
		while (mIndex < children.Count)
		{
			let result = children[mIndex].Tick(context);
			if (result != .Success)
				return result;
			mIndex++;
		}
		return .Success;
	}
}

/// Runs children left to right until one succeeds. A running child is resumed next tick.
class BTSelector : BTNode
{
	int mIndex;
	protected override void OnStart(BTContext context)
	{
		mIndex = 0;
	}

	protected override BTStatus OnTick(BTContext context)
	{
		while (mIndex < children.Count)
		{
			let result = children[mIndex].Tick(context);
			if (result != .Failure)
				return result;
			mIndex++;
		}
		return .Failure;
	}
}

/// Like Sequence, but starts from the first child every tick, so an earlier condition that turns false
/// interrupts whatever a later child was doing.
class BTReactiveSequence : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		for (int i < children.Count)
		{
			let result = children[i].Tick(context);
			if (result == .Success)
				continue;
			// Whatever was running further right no longer applies.
			for (int later = i + 1; later < children.Count; later++)
				children[later].Abort(context);
			return result;
		}
		return .Success;
	}
}

/// Like Selector, but starts from the first child every tick, so a higher-priority branch that becomes
/// possible interrupts a lower one.
class BTReactiveSelector : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		for (int i < children.Count)
		{
			let result = children[i].Tick(context);
			if (result == .Failure)
				continue;
			for (int later = i + 1; later < children.Count; later++)
				children[later].Abort(context);
			return result;
		}
		return .Failure;
	}
}

/// Runs every child each tick. Succeeds when all have (Require All) or when any has.
class BTParallel : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		let requireAll = Flag(0);
		int succeeded = 0, failed = 0;
		for (let child in children)
		{
			// A child that already finished this run keeps its result.
			let result = (child.status == .Success || child.status == .Failure) && child.lastTick >= mStarted ? child.status : child.Tick(context);
			if (result == .Success)
				succeeded++;
			else if (result == .Failure)
				failed++;
		}
		BTStatus outcome = .Running;
		if (requireAll)
			outcome = failed > 0 ? .Failure : (succeeded == children.Count ? .Success : .Running);
		else
			outcome = succeeded > 0 ? .Success : (failed == children.Count ? .Failure : .Running);
		if (outcome != .Running)
		{
			for (let child in children)
				child.Abort(context);
		}
		return outcome;
	}

	int32 mStarted;
	protected override void OnStart(BTContext context)
	{
		mStarted = context.tick;
	}
}

class BTInvert : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		if (children.Count == 0) return .Failure;
		let result = children[0].Tick(context);
		return result == .Success ? .Failure : (result == .Failure ? .Success : .Running);
	}
}

class BTAlwaysSucceed : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		if (children.Count == 0) return .Success;
		return children[0].Tick(context) == .Running ? .Running : .Success;
	}
}

/// Runs its child again each time it succeeds: a number of times, or forever when Times is 0.
class BTRepeat : BTNode
{
	int mDone;
	protected override void OnStart(BTContext context)
	{
		mDone = 0;
	}

	protected override BTStatus OnTick(BTContext context)
	{
		if (children.Count == 0) return .Failure;
		let result = children[0].Tick(context);
		if (result == .Running) return .Running;
		if (result == .Failure) return .Failure;
		mDone++;
		let times = (int)Number(0);
		// One run per tick, so a child that finishes at once cannot spin forever inside a single frame.
		return times > 0 && mDone >= times ? .Success : .Running;
	}
}

/// Runs its child over and over until it fails, then succeeds.
class BTUntilFail : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		if (children.Count == 0) return .Failure;
		return children[0].Tick(context) == .Failure ? .Success : .Running;
	}
}

/// After its child finishes, fails for a number of seconds without running it.
class BTCooldown : BTNode
{
	float mReadyAt = float.MinValue;
	protected override BTStatus OnTick(BTContext context)
	{
		if (children.Count == 0) return .Failure;
		if (children[0].status != .Running && Time.Time < mReadyAt)
			return .Failure;
		let result = children[0].Tick(context);
		if (result != .Running)
			mReadyAt = Time.Time + Number(0);
		return result;
	}
}

/// Fails, stopping its child, if the child runs longer than a number of seconds.
class BTTimeout : BTNode
{
	float mElapsed;
	protected override void OnStart(BTContext context)
	{
		mElapsed = 0;
	}

	protected override BTStatus OnTick(BTContext context)
	{
		if (children.Count == 0) return .Failure;
		mElapsed += context.deltaTime;
		if (mElapsed > Number(0))
		{
			children[0].Abort(context);
			return .Failure;
		}
		return children[0].Tick(context);
	}
}

// ---- simple actions ----

class BTWait : BTNode
{
	float mLeft;
	protected override void OnStart(BTContext context)
	{
		let low = Number(0);
		let high = Math.Max(Number(1), low);
		mLeft = low + (high - low) * (float)context.random.NextDouble();
	}

	protected override BTStatus OnTick(BTContext context)
	{
		mLeft -= context.deltaTime;
		return mLeft <= 0 ? .Success : .Running;
	}
}

class BTLog : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		Log.Info(scope $"{context.Object.Name}: {Text(0)}");
		return .Success;
	}
}

/// Calls a method by name on any component of the object. A method that returns bool decides success or
/// failure; any other method counts as success. This is the way to run your own code from a tree.
class BTCallMethod : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		let name = Text(0);
		for (let component in context.Object.Components)
		{
			let type = component.GetType() as TypeInstance;
			if (type == null)
				continue;
			if (type.GetMethod(name, .Instance | .Public | .NonPublic) case .Ok(let method))
			{
				if (method.ParamCount != 0)
					continue;
				switch (method.Invoke(component))
				{
				case .Ok(var result):
					defer result.Dispose();
					if (method.ReturnType == typeof(bool))
						return result.Get<bool>() ? .Success : .Failure;
					return .Success;
				case .Err:
					return .Failure;
				}
			}
		}
		if (!mWarned)
		{
			mWarned = true;
			Log.Warning(scope $"Behaviour tree on '{context.Object.Name}': no component has a method '{name}' without parameters.");
		}
		return .Failure;
	}

	bool mWarned;
}

// ---- blackboard ----

class BTHasValue : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		// A remembered object that has since been destroyed no longer counts.
		Vector3 position;
		return context.blackboard.Has(Text(0)) && (context.blackboard.TryGetPosition(Text(0), context.Scene, out position) || context.blackboard.Values[scope String(Text(0))].kind != .Object) ? .Success : .Failure;
	}
}

class BTClearValue : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		context.blackboard.Clear(Text(0));
		return .Success;
	}
}

class BTSetFlag : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		context.blackboard.SetFlag(Text(0), Flag(1));
		return .Success;
	}
}

class BTIsFlagSet : BTNode
{
	protected override BTStatus OnTick(BTContext context) => context.blackboard.GetFlag(Text(0)) ? .Success : .Failure;
}

/// Succeeds while a remembered object or position is within a distance of this object.
class BTWithinDistance : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		Vector3 position;
		if (!context.blackboard.TryGetPosition(Text(0), context.Scene, out position))
			return .Failure;
		return (position - context.Transform.Position).Length <= Number(1) ? .Success : .Failure;
	}
}

// ---- detection ----

/// Shared search for the detection nodes.
static class BTSenses
{
	/// A name matches exactly, or as a prefix when the pattern ends in '*'.
	public static bool NameMatches(StringView name, StringView pattern)
	{
		if (pattern.EndsWith('*'))
			return name.StartsWith(pattern.Substring(0, pattern.Length - 1));
		return name == pattern;
	}

	/// An object matches a pattern: `#Enemy` is any object tagged Enemy, otherwise its name (see NameMatches).
	public static bool Matches(GameObject object, StringView pattern)
	{
		if (pattern.StartsWith('#'))
			return object.HasTag(pattern.Substring(1));
		return NameMatches(object.Name, pattern);
	}

	/// The first active object a pattern matches (`#Tag` or a name), or null.
	public static GameObject FindOne(Scene scene, StringView pattern)
	{
		if (pattern.StartsWith('#'))
			return scene.FindWithTag(pattern.Substring(1));
		if (!pattern.EndsWith('*'))
			return scene.Find(pattern);
		for (let object in scene.Objects)
		{
			if (object.ActiveInHierarchy && NameMatches(object.Name, pattern))
				return object;
		}
		return null;
	}

	static bool IsPartOf(GameObject object, GameObject root)
	{
		var transform = object?.Transform;
		while (transform != null)
		{
			if (transform.GameObject == root)
				return true;
			transform = transform.Parent;
		}
		return false;
	}

	/// True if nothing solid lies between the eye and the target. Colliders of the looker and of the target
	/// themselves do not block the view.
	public static bool HasLineOfSight(Scene scene, GameObject looker, Vector3 eye, GameObject target, Vector3 targetPoint)
	{
		var origin = eye;
		for (int attempt < 4)
		{
			let delta = targetPoint - origin;
			let distance = delta.Length;
			if (distance < 0.05f)
				return true;
			RaycastHit hit;
			if (!scene.Physics.Raycast(origin, delta, distance, out hit))
				return true;
			if (IsPartOf(hit.gameObject, target))
				return true;
			if (!IsPartOf(hit.gameObject, looker))
				return false;
			// The ray started inside, or grazed, the looker's own collider: carry on from just past it.
			origin = hit.point + delta / distance * 0.05f;
		}
		return false;
	}

	/// Seen if any of several points up the target is in view: one ray to its middle, or (sightPoints 3) also its
	/// head and feet, so a target half behind low cover is still seen.
	static bool CanSeeAny(Scene scene, GameObject looker, Vector3 eye, GameObject target, Vector3 middle, float eyeHeight, int sightPoints)
	{
		if (HasLineOfSight(scene, looker, eye, target, middle))
			return true;
		if (sightPoints < 2)
			return false;
		let feet = target.Transform.Position + Vector3(0, Math.Max(eyeHeight * 0.1f, 0.1f), 0);
		let head = target.Transform.Position + Vector3(0, eyeHeight * 0.95f, 0);
		return HasLineOfSight(scene, looker, eye, target, head) || (sightPoints >= 3 && HasLineOfSight(scene, looker, eye, target, feet));
	}

	/// Nearest object whose name matches and that passes the range, view-cone and line-of-sight tests.
	/// fieldOfView is the full cone angle in degrees; 360 or more looks all around. needSight false skips the ray.
	public static GameObject Find(BTContext context, StringView pattern, float range, float fieldOfView, float eyeHeight, bool needSight, int sightPoints = 1)
	{
		let self = context.Object;
		let eye = context.Transform.Position + Vector3(0, eyeHeight, 0);
		var forward = context.Transform.Forward;
		forward.y = 0;
		forward = forward.LengthSquared > 0.0001f ? forward.Normalized : Vector3.Forward;
		let minimumDot = fieldOfView >= 360 ? -2.0f : Math.Cos(Mathf.Clamp(fieldOfView, 0, 360) * 0.5f * Mathf.Deg2Rad);
		GameObject best = null;
		float bestDistance = range;
		// One scene spatial snapshot feeds all AI in this frame; the old code
		// walked every scene object *for every guard* (O(guards * objects)).
		// Range, name/tag, cone and raycast checks remain unchanged below.
		let candidates = scope List<GameObject>();
		context.Scene.AISpatial.QueryObjects(context.Transform.Position, range, candidates);
		for (let candidate in candidates)
		{
			if (candidate == self || candidate.IsDestroyed || !candidate.ActiveInHierarchy || !Matches(candidate, pattern) || IsPartOf(candidate, self))
				continue;
			let targetPoint = candidate.Transform.Position + Vector3(0, eyeHeight * 0.5f, 0);
			var flat = candidate.Transform.Position - context.Transform.Position;
			let distance = flat.Length;
			// Spatial buckets have no insertion order. A stable tie-break by
			// scene ID makes equal-distance target selection reproducible.
			if (distance > bestDistance || (distance == bestDistance && best != null && candidate.Id < best.Id))
				continue;
			flat.y = 0;
			if (flat.LengthSquared > 0.0001f && Vector3.Dot(flat.Normalized, forward) < minimumDot)
				continue;
			if (needSight && !CanSeeAny(context.Scene, self, eye, candidate, targetPoint, eyeHeight, sightPoints))
				continue;
			best = candidate;
			bestDistance = distance;
		}
		return best;
	}
}

/// Succeeds when an object with a matching name is in range, inside the view cone and not hidden behind
/// anything solid. The object and where it was seen are remembered under Store As and Store As + ".position".
class BTCanSee : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		let found = BTSenses.Find(context, Text(0), Number(1), Number(2), Number(3), true, (int)Number(5));
		if (found == null)
			return .Failure;
		let key = Text(4);
		if (!key.IsEmpty)
		{
			context.blackboard.SetObject(key, found);
			context.blackboard.SetVector(scope $"{key}.position" , found.Transform.Position);
		}
		return .Success;
	}
}

/// Succeeds when an object with a matching name is within a distance, in any direction and through walls.
class BTIsNear : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		let found = BTSenses.Find(context, Text(0), Number(1), 360, 0, false);
		if (found == null)
			return .Failure;
		let key = Text(2);
		if (!key.IsEmpty)
		{
			context.blackboard.SetObject(key, found);
			context.blackboard.SetVector(scope $"{key}.position" , found.Transform.Position);
		}
		return .Success;
	}
}

// ---- navigation ----

/// Common part of the movement nodes: ask the object's Navigation Agent for a path and wait for the result.
abstract class BTMove : BTNode
{
	protected bool mAsked;

	/// Where to go this tick, or false if there is nowhere.
	protected abstract bool Destination(BTContext context, out Vector3 point);
	protected abstract float Speed { get; }
	protected abstract float StopDistance { get; }
	/// Keep asking for the destination, for targets that move.
	protected virtual bool Follow => false;

	protected override void OnStart(BTContext context)
	{
		mAsked = false;
	}

	protected override BTStatus OnTick(BTContext context)
	{
		let mover = context.Mover;
		if (!mover.IsValid)
			return .Failure;
		if (!mAsked || Follow)
		{
			Vector3 point;
			if (!Destination(context, out point))
			{
				if (mAsked)
					mover.StopMovement();
				return .Failure;
			}
			mover.SetDestination(point, Speed, StopDistance);
			mAsked = true;
		}
		// Status getters may synchronously resolve a queued path. Let the scene batch pending requests
		// after Update instead of forcing a separate search for each behaviour tree.
		if (mover.PathPending)
			return .Running;
		if (mover.PathFailed)
			return .Failure;
		return mover.HasArrived ? .Success : .Running;
	}

	protected override void OnEnd(BTContext context, bool aborted)
	{
		// Finishing normally leaves the agent standing where it arrived; being interrupted must stop it.
		if (aborted)
			context.Mover.StopMovement();
	}
}

class BTMoveToPosition : BTMove
{
	protected override float Speed => Number(1);
	protected override float StopDistance => Number(2);
	protected override bool Destination(BTContext context, out Vector3 point)
	{
		point = Vector(0);
		return true;
	}
}

class BTMoveToObject : BTMove
{
	protected override float Speed => Number(1);
	protected override float StopDistance => Number(2);
	protected override bool Follow => true;
	protected override bool Destination(BTContext context, out Vector3 point)
	{
		point = default;
		let target = BTSenses.FindOne(context.Scene, Text(0));
		if (target == null)
			return false;
		point = target.Transform.Position;
		return true;
	}
}

/// Goes to an object or position remembered on the blackboard, for example one stored by Can See.
class BTMoveToTarget : BTMove
{
	protected override float Speed => Number(1);
	protected override float StopDistance => Number(2);
	protected override bool Follow => Flag(3);
	protected override bool Destination(BTContext context, out Vector3 point) => context.blackboard.TryGetPosition(Text(0), context.Scene, out point);
}

/// Goes to the next child of a waypoint object, in order, wrapping around. Each run visits one waypoint.
class BTPatrol : BTMove
{
	int mIndex = -1;
	protected override float Speed => Number(1);
	protected override float StopDistance => Number(2);
	protected override void OnStart(BTContext context)
	{
		base.OnStart(context);
		mIndex++;
	}

	protected override bool Destination(BTContext context, out Vector3 point)
	{
		point = default;
		let route = context.Scene.Find(Text(0));
		if (route == null || route.Transform.Children.Count == 0)
			return false;
		point = route.Transform.Children[mIndex % route.Transform.Children.Count].Position;
		return true;
	}

	protected override void OnEnd(BTContext context, bool aborted)
	{
		base.OnEnd(context, aborted);
		// An interrupted leg is walked again, not skipped.
		if (aborted)
			mIndex--;
	}
}

/// Goes to a random point within a radius of where the object was when the tree started.
class BTWander : BTMove
{
	Vector3 mPoint;
	protected override float Speed => Number(1);
	protected override float StopDistance => 0.3f;
	protected override void OnStart(BTContext context)
	{
		base.OnStart(context);
		// A point the agent can reach, when its surface is baked; otherwise anywhere in the circle.
		let agent = context.Object.GetComponent<NavigationAgent>();
		let data = agent ? agent.Surface?.Data : null;
		if (data != null && data.RandomPoint(context.runner.Home, Number(0), context.random, let reachable))
		{
			mPoint = reachable;
			return;
		}
		let angle = (float)(context.random.NextDouble() * Math.PI_d * 2);
		let distance = Number(0) * Math.Sqrt((float)context.random.NextDouble());
		mPoint = context.runner.Home + Vector3(Math.Cos(angle), 0, Math.Sin(angle)) * distance;
	}

	protected override bool Destination(BTContext context, out Vector3 point)
	{
		point = mPoint;
		return true;
	}
}

class BTStopMoving : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		context.Mover.StopMovement();
		return .Success;
	}
}

/// Turns to face a remembered object or position. Succeeds once it is facing it.
class BTFaceTarget : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		Vector3 position;
		if (!context.blackboard.TryGetPosition(Text(0), context.Scene, out position))
			return .Failure;
		let delta = position - context.Transform.Position;
		if (delta.x * delta.x + delta.z * delta.z < 0.0001f)
			return .Success;
		let wanted = Math.Atan2(delta.x, delta.z) * Mathf.Rad2Deg;
		let forward = context.Transform.Forward;
		let current = Math.Atan2(forward.x, forward.z) * Mathf.Rad2Deg;
		let turn = Mathf.WrapAngle(wanted - current);
		let step = Math.Max(Number(1), 1) * context.deltaTime;
		context.Transform.Rotation = Quaternion.Euler(0, current + Mathf.Clamp(turn, -step, step), 0);
		return Math.Abs(turn) <= step ? .Success : .Running;
	}
}

// ---- subtrees, events, hearing, numbers, chance ----

/// Runs another tree file in its place; the runner builds that tree as this node's child, sharing the blackboard.
class BTSubtree : BTNode
{
	protected override BTStatus OnTick(BTContext context) => children.Count > 0 ? children[0].Tick(context) : .Failure;
}

/// Succeeds if the game sent this event to the tree (BehaviorTreeRunner.SendEvent) within the last seconds.
class BTEventReceived : BTNode
{
	protected override BTStatus OnTick(BTContext context) => context.runner.TakeEvent(Text(0), Number(1), Flag(2)) ? .Success : .Failure;
}

/// Tells the game something (BehaviorTreeRunner.OnTreeEvent).
class BTSendEvent : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		context.runner.RaiseTreeEvent(Text(0));
		return .Success;
	}
}

/// Sounds the AI can hear: gunshots, footsteps, a thrown bottle. Made by the game with AINoise.Make; Heard Noise
/// nodes pick them up.
static class AINoise
{
	public struct Noise
	{
		public Scene scene;
		public Vector3 position;
		/// How far away it can be heard (times the listener's Hearing).
		public float radius;
		public float time;
		public uint32 sourceId;
		public int32 id;
	}

	static List<Noise> sNoises = new .() ~ delete _;
	static int32 sNextId = 1;

	/// Recent noises, oldest first.
	public static Span<Noise> Recent => sNoises;

	/// A noise at a point, heard within radius metres. The source (who made it) is remembered by those who hear it,
	/// and does not hear itself.
	public static void Make(Scene scene, Vector3 position, float radius, GameObject source = null)
	{
		Forget(10);
		Noise noise;
		noise.scene = scene;
		noise.position = position;
		noise.radius = radius;
		noise.time = Time.Time;
		noise.sourceId = source != null ? source.Id : 0;
		noise.id = sNextId++;
		sNoises.Add(noise);
	}

	/// Drops noises older than some seconds (all of them with 0, for a new level).
	public static void Forget(float olderThan = 0)
	{
		for (int i = sNoises.Count - 1; i >= 0; i--)
		{
			if (olderThan <= 0 || Time.Time - sNoises[i].time > olderThan || sNoises[i].time > Time.Time)
				sNoises.RemoveAt(i);
		}
	}
}

/// Succeeds if a noise was made within hearing in the last seconds. Where it was is remembered under Store As, and
/// who made it under Store As + ".source". Each noise is heard once, so the guard reacts and then carries on.
class BTHeardNoise : BTNode
{
	int32 mLastHeard;

	protected override BTStatus OnTick(BTContext context)
	{
		let here = context.Transform.Position;
		let hearing = Math.Max(Number(1), 0);
		let selfId = context.Object.Id;
		int best = -1;
		for (int i < AINoise.Recent.Length)
		{
			let noise = AINoise.Recent[i];
			if (noise.scene != context.Scene || noise.id <= mLastHeard || noise.sourceId == selfId || Time.Time - noise.time > Number(0))
				continue;
			if ((noise.position - here).Length <= noise.radius * hearing)
				best = i;
		}
		if (best < 0)
			return .Failure;
		let noise = AINoise.Recent[best];
		mLastHeard = noise.id;
		let key = Text(2);
		if (!key.IsEmpty)
		{
			context.blackboard.SetVector(key, noise.position);
			if (let source = context.Scene.FindById(noise.sourceId))
				context.blackboard.SetObject(scope $"{key}.source" , source);
		}
		return .Success;
	}
}

/// Remembers a number, or adds to it.
class BTSetNumber : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		let value = Flag(2) ? context.blackboard.GetNumber(Text(0)) + Number(1) : Number(1);
		context.blackboard.SetNumber(Text(0), value);
		return .Success;
	}
}

/// Compares a remembered number with a value: <, <=, >, >=, == or !=.
class BTCompareNumber : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		if (!context.blackboard.Has(Text(0)))
			return .Failure;
		let a = context.blackboard.GetNumber(Text(0));
		let b = Number(2);
		bool result;
		switch (Text(1))
		{
		case "<": result = a < b;
		case "<=": result = a <= b;
		case ">": result = a > b;
		case ">=": result = a >= b;
		case "!=": result = Math.Abs(a - b) > 0.0001f;
		default: result = Math.Abs(a - b) <= 0.0001f;
		}
		return result ? .Success : .Failure;
	}
}

/// Remembers where the object is now (to come back to it later).
class BTRememberPosition : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		context.blackboard.SetVector(Text(0), context.Transform.Position);
		return .Success;
	}
}

/// Succeeds with a probability each time it is asked.
class BTChance : BTNode
{
	protected override BTStatus OnTick(BTContext context) => context.random.NextDouble() < Number(0) ? .Success : .Failure;
}

/// A Selector that tries its children in a random order, made again each time it starts.
class BTRandomSelector : BTNode
{
	List<int> mOrder = new .() ~ delete _;
	int mIndex;

	protected override void OnStart(BTContext context)
	{
		mIndex = 0;
		mOrder.Clear();
		for (int i < children.Count)
			mOrder.Add(i);
		for (int i = mOrder.Count - 1; i > 0; i--)
		{
			let j = context.random.Next(0, (int32)i + 1);
			Swap!(mOrder[i], mOrder[j]);
		}
	}

	protected override BTStatus OnTick(BTContext context)
	{
		while (mIndex < mOrder.Count)
		{
			let result = children[mOrder[mIndex]].Tick(context);
			if (result != .Failure)
				return result;
			mIndex++;
		}
		return .Failure;
	}
}

/// Runs its child until it finishes once, then keeps answering with that result without running it again.
class BTRunOnce : BTNode
{
	BTStatus mDone = .Idle;
	protected override BTStatus OnTick(BTContext context)
	{
		if (mDone != .Idle)
			return mDone;
		if (children.Count == 0) return .Failure;
		let result = children[0].Tick(context);
		if (result != .Running)
			mDone = result;
		return result;
	}
}

/// Every node kind the editor offers and the runner can build.
static class BehaviorLibrary
{
	static List<BTNodeDef> sDefs ~ DeleteContainerAndItems!(_);

	public static List<BTNodeDef> Defs
	{
		get
		{
			if (sDefs == null)
				Build();
			return sDefs;
		}
	}

	public static BTNodeDef Find(StringView key)
	{
		for (let def in Defs)
		{
			if (def.key == key)
				return def;
		}
		return null;
	}

	/// Adds a node kind. Games can call this at startup to offer their own nodes: derive from BTNode and register it.
	public static BTNodeDef Add(StringView key, StringView category, StringView title, BTKind kind, BTNodeDef.Factory create)
	{
		if (sDefs == null)
			Build();
		let def = new BTNodeDef();
		def.key.Set(key);
		def.category.Set(category);
		def.title.Set(title);
		def.kind = kind;
		def.create = create;
		sDefs.Add(def);
		return def;
	}

	static void Build()
	{
		sDefs = new .();
		Add("root", "Flow", "Root", .Root, new () => new BTRoot()).Describe("Where the tree starts. Connect one node below it.");
		Add("sequence", "Flow", "Sequence", .Composite, new () => new BTSequence()).Describe("Runs children left to right. Stops and fails when one fails; succeeds when all have.");
		Add("selector", "Flow", "Selector", .Composite, new () => new BTSelector()).Describe("Tries children left to right. Stops and succeeds when one succeeds; fails when all have.");
		Add("reactive.sequence", "Flow", "Reactive Sequence", .Composite, new () => new BTReactiveSequence()).Describe("A Sequence that rechecks from the left every tick, so a condition turning false interrupts the action after it.");
		Add("reactive.selector", "Flow", "Reactive Selector", .Composite, new () => new BTReactiveSelector()).Describe("A Selector that rechecks from the left every tick, so a higher-priority branch interrupts a lower one.");
		Add("random.selector", "Flow", "Random Selector", .Composite, new () => new BTRandomSelector()).Describe("A Selector that tries its children in a random order each time it starts: idle animations, different routes.");
		Add("subtree", "Flow", "Run Subtree", .Action, new () => new BTSubtree()).With("Tree", .Text, "AI/Subtree.tbt").Describe("Runs another tree file here, with the same blackboard. Its result is that tree's. Select it and press Open to edit that tree.");
		Add("parallel", "Flow", "Parallel", .Composite, new () => new BTParallel()).With("Require All", .Bool, "true").Describe("Runs all children together. Succeeds when all have, or when any has if Require All is off.");

		Add("invert", "Decorators", "Invert", .Decorator, new () => new BTInvert()).Describe("Turns its child's success into failure and failure into success.");
		Add("succeed", "Decorators", "Always Succeed", .Decorator, new () => new BTAlwaysSucceed()).Describe("Reports success whatever its child returns.");
		Add("repeat", "Decorators", "Repeat", .Decorator, new () => new BTRepeat()).With("Times", .Number, "0").Describe("Runs its child again each time it succeeds. Times 0 repeats forever.");
		Add("until.fail", "Decorators", "Repeat Until Failure", .Decorator, new () => new BTUntilFail()).Describe("Runs its child over and over until it fails.");
		Add("cooldown", "Decorators", "Cooldown", .Decorator, new () => new BTCooldown()).With("Seconds", .Number, "2").Describe("After its child finishes, fails for this long without running it.");
		Add("once", "Decorators", "Run Once", .Decorator, new () => new BTRunOnce()).Describe("Runs its child until it finishes once; after that it answers with the same result without running it.");
		Add("timeout", "Decorators", "Timeout", .Decorator, new () => new BTTimeout()).With("Seconds", .Number, "5").Describe("Stops its child and fails if the child runs longer than this.");

		Add("wait", "Actions", "Wait", .Action, new () => new BTWait()).With("Seconds", .Number, "1").With("Up To", .Number, "0").Describe("Waits. With Up To above Seconds the time is random between the two.");
		Add("log", "Actions", "Log", .Action, new () => new BTLog()).With("Text", .Text, "Hello").Describe("Writes a line to the Console.");
		Add("call", "Actions", "Call Method", .Action, new () => new BTCallMethod()).With("Method", .Text, "DoSomething").Describe("Calls a method with no parameters on a component of this object. A bool result decides success.");

		Add("nav.position", "Navigation", "Move To Position", .Action, new () => new BTMoveToPosition()).With("Position", .Vector, "0 0 0").With("Speed", .Number, "3").With("Stop Distance", .Number, "0.3").Describe("Walks to a fixed point using the object's Navigation Agent.");
		Add("nav.object", "Navigation", "Move To Object", .Action, new () => new BTMoveToObject()).With("Object", .Text, "Player").With("Speed", .Number, "3").With("Stop Distance", .Number, "1").Describe("Walks to the object with this name, following it if it moves.");
		Add("nav.target", "Navigation", "Move To Target", .Action, new () => new BTMoveToTarget()).With("Key", .Text, "target").With("Speed", .Number, "4").With("Stop Distance", .Number, "1").With("Follow", .Bool, "true").Describe("Walks to an object or position remembered on the blackboard, for example by Can See.");
		Add("nav.patrol", "Navigation", "Patrol", .Action, new () => new BTPatrol()).With("Waypoints", .Text, "Waypoints").With("Speed", .Number, "2").With("Stop Distance", .Number, "0.3").Describe("Walks to the next child of the named object, in order. Each run visits one waypoint.");
		Add("nav.wander", "Navigation", "Wander", .Action, new () => new BTWander()).With("Radius", .Number, "6").With("Speed", .Number, "2").Describe("Walks to a random point within a radius of where the object started.");
		Add("nav.stop", "Navigation", "Stop Moving", .Action, new () => new BTStopMoving()).Describe("Stops the Navigation Agent.");
		Add("nav.face", "Navigation", "Face Target", .Action, new () => new BTFaceTarget()).With("Key", .Text, "target").With("Turn Speed", .Number, "360").Describe("Turns toward a remembered object or position.");

		Add("see", "Detection", "Can See", .Condition, new () => new BTCanSee()).With("Object", .Text, "Player").With("Range", .Number, "12").With("Field Of View", .Number, "110").With("Eye Height", .Number, "1.6").With("Store As", .Text, "target").With("Sight Points", .Number, "1").Describe("Succeeds if an object with this name (end with * for a prefix, or #Tag for a tag) is in range, in the view cone and not behind anything solid. Sight Points 3 also looks for its head and feet.");
		Add("near", "Detection", "Is Near", .Condition, new () => new BTIsNear()).With("Object", .Text, "Player").With("Distance", .Number, "3").With("Store As", .Text, "target").Describe("Succeeds if an object with this name is within a distance, in any direction and through walls.");
		Add("within", "Detection", "Target Within", .Condition, new () => new BTWithinDistance()).With("Key", .Text, "target").With("Distance", .Number, "2").Describe("Succeeds while a remembered object or position is within a distance.");
		Add("hear", "Detection", "Heard Noise", .Condition, new () => new BTHeardNoise()).With("Within Seconds", .Number, "1").With("Hearing", .Number, "1").With("Store As", .Text, "noise").Describe("Succeeds if a noise (AINoise.Make) was made within earshot lately. Remembers where under Store As. Each noise is heard once.");
		Add("event.received", "Events", "Event Received", .Condition, new () => new BTEventReceived()).With("Event", .Text, "Hit").With("Within Seconds", .Number, "1").With("Consume", .Bool, "true").Describe("Succeeds if the game sent this event to the tree (runner.SendEvent) lately. Consume makes each one count once.");
		Add("event.send", "Events", "Send Event", .Action, new () => new BTSendEvent()).With("Event", .Text, "Alarm").Describe("Tells the game something: the runner's OnTreeEvent is called with this name.");
		Add("chance", "Actions", "Chance", .Condition, new () => new BTChance()).With("Probability", .Number, "0.5").Describe("Succeeds with this probability (0 to 1) each time.");

		Add("bb.has", "Blackboard", "Has Value", .Condition, new () => new BTHasValue()).With("Key", .Text, "target").Describe("Succeeds if something is remembered under this key.");
		Add("bb.clear", "Blackboard", "Forget", .Action, new () => new BTClearValue()).With("Key", .Text, "target").Describe("Forgets what is remembered under this key.");
		Add("bb.set", "Blackboard", "Set Flag", .Action, new () => new BTSetFlag()).With("Key", .Text, "alert").With("Value", .Bool, "true").Describe("Remembers a true or false value.");
		Add("bb.number", "Blackboard", "Set Number", .Action, new () => new BTSetNumber()).With("Key", .Text, "count").With("Value", .Number, "1").With("Add", .Bool, "false").Describe("Remembers a number; with Add on, adds the value to it (a negative value takes away).");
		Add("bb.compare", "Blackboard", "Compare Number", .Condition, new () => new BTCompareNumber()).With("Key", .Text, "count").With("Test", .Text, ">=").With("Value", .Number, "3").Describe("Compares a remembered number with a value. Test is <, <=, >, >=, == or !=.");
		Add("bb.here", "Blackboard", "Remember Position", .Action, new () => new BTRememberPosition()).With("Key", .Text, "post").Describe("Remembers where this object is now, to go back to it with Move To Target.");
		Add("bb.flag", "Blackboard", "Is Flag Set", .Condition, new () => new BTIsFlagSet()).With("Key", .Text, "alert").Describe("Succeeds if the flag is true.");
	}
}
