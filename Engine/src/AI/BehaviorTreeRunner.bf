using System;
using System.Collections;

namespace Tallow;

/// Loaded tree files, shared by every runner that uses them: a hundred guards running one tree read it once.
static class BehaviorTreeAssets
{
	class Entry
	{
		public String path = new .() ~ delete _;
		public BehaviorTreeData data ~ delete _;
		public int32 users;
	}

	static List<Entry> sEntries = new .() ~ DeleteContainerAndItems!(_);
	// Files changed while runners still used the old copy: freed when the last of them lets go.
	static List<Entry> sStale = new .() ~ DeleteContainerAndItems!(_);

	/// The tree at a resolved path, read on first use, or null if it cannot be read. Pair with Release.
	public static BehaviorTreeData Acquire(StringView path)
	{
		for (let entry in sEntries)
		{
			if (entry.path == path)
			{
				entry.users++;
				return entry.data;
			}
		}
		let data = new BehaviorTreeData();
		if (!data.Load(path))
		{
			delete data;
			return null;
		}
		let entry = new Entry();
		entry.path.Set(path);
		entry.data = data;
		entry.users = 1;
		sEntries.Add(entry);
		return data;
	}

	/// Lets go of a tree from Acquire.
	public static void Release(BehaviorTreeData data)
	{
		List<Entry>[2] lists = .(sEntries, sStale);
		for (let list in lists)
		{
			for (let entry in list)
			{
				if (entry.data != data)
					continue;
				if (--entry.users <= 0)
				{
					list.Remove(entry);
					delete entry;
				}
				return;
			}
		}
	}

	/// The file at a path changed: the next Acquire reads it again.
	public static void Invalidate(StringView path)
	{
		for (let entry in sEntries)
		{
			if (entry.path == path)
			{
				sEntries.Remove(entry);
				sStale.Add(entry);
				return;
			}
		}
	}

	/// How many tree files are loaded (for tests).
	public static int LoadedCount => sEntries.Count + sStale.Count;
}

/// A Behavior Tree Runner's settings, in its entity (BehaviorTreeRunner is the handle). `tree` and `startValues`
/// are text the data owns.
[Component, HandleData]
struct BehaviorTreeRunnerData
{
	/// Tree file, relative to the project's asset folder.
	public String tree = new .();
	/// Seconds between ticks. 0 ticks every frame; a little higher is cheaper for crowds.
	public float tickInterval = 0;
	/// Start over when the tree finishes. Off leaves it stopped.
	public bool restartWhenDone = true;
	/// What the blackboard holds at the start, so one tree can be tuned per character:
	/// `ammo 3; alert false; post 4 0 -2` (a number, true or false, or a position), separated by semicolons.
	public String startValues = new .();

	public this() { }
}

/// Runs a behaviour tree asset (.tbt) for its object. Movement nodes drive a Navigation Agent on the same object.
/// The Behavior tab in the editor shows the tree of the selected object live while the game plays.
///
/// A handle (ComponentHandle): its settings are BehaviorTreeRunnerData's fields; the running tree, blackboard and
/// events are its BehaviorTreeRunnerState (what nodes see as `context.runner`). Trees start and tick in the
/// Frame.Behaviour step after the scripts' Update (before agents move), as Start and OnLocalUpdate did.
[Component, HandleFields]
struct BehaviorTreeRunner : ComponentHandle<BehaviorTreeRunnerData>
{
	/// The running tree, made the first time it is asked for.
	public BehaviorTreeRunnerState Runtime
	{
		get
		{
			CheckValid();
			let state = ComponentState<BehaviorTreeRunnerState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			state.[Friend]mGameObject = mGameObject;
			return state;
		}
	}

	// The API, unchanged: each member is documented on BehaviorTreeRunnerState.
	public Blackboard Blackboard => Runtime.Blackboard;
	/// The tree file it runs, or null (the state's Data: a handle's Data is its settings).
	public BehaviorTreeData TreeData => Runtime.Data;
	public int32 TickCount => Runtime.TickCount;
	public ref Vector3 Home => ref Runtime.Home;
	public ref Event<delegate void(StringView name)> OnTreeEvent => ref Runtime.OnTreeEvent;
	public BTStatus StatusOf(int32 nodeId) => Runtime.StatusOf(nodeId);
	public int32 LastTickOf(int32 nodeId) => Runtime.LastTickOf(nodeId);
	public BTStatus StatusOf(StringView path, int32 nodeId) => Runtime.StatusOf(path, nodeId);
	public int32 LastTickOf(StringView path, int32 nodeId) => Runtime.LastTickOf(path, nodeId);
	public bool UsesFile(StringView path) => Runtime.UsesFile(path);
	public void ApplyStartValues() => Runtime.ApplyStartValues();
	public void Reload() => Runtime.Reload();
	public BTStatus Tick(float deltaTime) => Runtime.Tick(deltaTime);
	public void SendEvent(StringView name) => Runtime.SendEvent(name);
	public bool TakeEvent(StringView name, float withinSeconds, bool consume) => Runtime.TakeEvent(name, withinSeconds, consume);
	public void RaiseTreeEvent(StringView name) => Runtime.RaiseTreeEvent(name);

	/// Starts and updates active runners through the cached Flecs handle query.
	/// Disabled handles do not appear in this query; OnSwitched aborts running
	/// nodes immediately, without walking every GameObject to find disabled AI.
	public static void FrameAll(Scene scene)
	{
		if (!scene.IsPlaying)
			return;
		let runners = scope List<BehaviorTreeRunner>();
		scene.Components<BehaviorTreeRunner>(runners);
		// ECS tables have no defined iteration order. Preserve a stable per-object
		// processing order for AI side effects and authoritative networking.
		runners.Sort(scope (a, b) => a.GameObject.Id <=> b.GameObject.Id);
		for (let runner in runners)
		{
			if (!runner.GameObject.ActiveInHierarchy)
				continue;
			let state = runner.Runtime;
			state.[Friend]mWasActive = true;
			if (!state.[Friend]mStarted)
			{
				state.[Friend]mStarted = true;
				state.Start();
			}
			state.Frame();
		}
	}

	/// Fired by the existing GameObject/handle lifecycle on disabling an AI
	/// component or its hierarchy, and when play stops. Keep the old abort
	/// semantics without a separate per-frame scan over inactive objects.
	static void OnSwitched(GameObject gameObject, bool on)
	{
		if (on)
			return;
		let state = ComponentState<BehaviorTreeRunnerState>.Get(gameObject.Scene.World, gameObject.Entity);
		if (state != null && state.[Friend]mWasActive)
		{
			state.[Friend]mWasActive = false;
			state.OnDisable();
		}
	}

	/// When play stops, runners start again next time (as Start runs once per play).
	public static void StopAll(Scene scene)
	{
		for (let (entity, state) in ComponentState<BehaviorTreeRunnerState>.In(scene.World, .. scope .()))
		{
			state.[Friend]mStarted = false;
			state.[Friend]mWasActive = false;
		}
	}

	static void OnRemove(void* world, uint64 entity)
	{
		// As OnDestroy did: running nodes end (stopping the agent), unless the whole object is going (IsGoing).
		if (let state = ComponentState<BehaviorTreeRunnerState>.Get((World)Internal.UnsafeCastToObject(world), Entity(entity)))
		{
			let owner = state.[Friend]mGameObject;
			if (owner != null && !owner.IsGoing)
				state.[Friend]Unload();
		}
		ComponentState<BehaviorTreeRunnerState>.Release(world, entity);
		HandleComponents.FreeLists(world, entity, typeof(BehaviorTreeRunner));
	}
}

/// What a Behavior Tree Runner keeps between frames: the tree it runs, its blackboard and the events sent to it.
/// Its settings are read from the entity each time.
[DataFields(typeof(BehaviorTreeRunnerData), "Settings")]
class BehaviorTreeRunnerState
{
	GameObject mGameObject;

	public GameObject GameObject => mGameObject;
	public Transform Transform => mGameObject.Transform;
	public Scene Scene => mGameObject.Scene;
	/// A component on the runner's object (nodes find its mover and the like through it).
	public T GetComponent<T>() where T : Component => mGameObject.GetComponent<T>();
	public T GetComponent<T>() where T : struct, IComponentHandle => mGameObject.GetComponent<T>();
	ref BehaviorTreeRunnerData Settings
	{
		[Inline]
		get => ref *mGameObject.GetComponent<BehaviorTreeRunnerData>();
	}

	/// A tree file the runner uses (its own, or one run as a subtree), with its running nodes by id.
	class TreeFile
	{
		public String path = new .() ~ delete _;
		public BehaviorTreeData data;
		public Dictionary<int32, BTNode> byId = new .() ~ delete _;
	}

	List<TreeFile> mFiles = new .() ~
		{
			// Gives the shared files back even when the object goes without OnDestroy (its scene unloaded).
			for (let file in _)
				BehaviorTreeAssets.Release(file.data);
			DeleteContainerAndItems!(_);
		};
	BTNode mRoot ~ delete _;
	BTContext mContext = new .() ~ delete _;
	Blackboard mBlackboard = new .() ~ delete _;
	String mLoaded = new .() ~ delete _;
	// Events sent to the tree and not yet handled, with when they came.
	Dictionary<String, float> mEvents = new .() ~ DeleteDictionaryAndKeys!(_);
	float mSinceTick;
	bool mFinished;

	public Blackboard Blackboard => mBlackboard;
	/// The tree file it runs, or null.
	public BehaviorTreeData Data => mFiles.IsEmpty ? null : mFiles[0].data;
	/// Number of ticks run so far; a node whose LastTick equals TickCount ran on the latest tick.
	public int32 TickCount => mContext.tick;
	/// Where the object was when the tree started.
	public Vector3 Home;
	bool mStarted;
	bool mWasActive;
	/// The tree's Send Event nodes: `runner.OnTreeEvent.Add(new (name) => { if (name == "Alarm") RingBell(); });`
	public Event<delegate void(StringView name)> OnTreeEvent ~ _.Dispose();

	/// A node of the runner's own tree, by id.
	public BTStatus StatusOf(int32 nodeId) => mFiles.IsEmpty ? .Idle : StatusOf(mFiles[0].path, nodeId);
	public int32 LastTickOf(int32 nodeId) => mFiles.IsEmpty ? -1 : LastTickOf(mFiles[0].path, nodeId);

	/// A node of a tree file the runner uses (its own or a subtree's), by the file's resolved path and the node's id.
	public BTStatus StatusOf(StringView path, int32 nodeId) => NodeAt(path, nodeId)?.status ?? .Idle;
	public int32 LastTickOf(StringView path, int32 nodeId) => NodeAt(path, nodeId)?.lastTick ?? -1;

	BTNode NodeAt(StringView path, int32 nodeId)
	{
		let file = FileAt(path);
		if (file == null)
			return null;
		return file.byId.TryGetValue(nodeId, let node) ? node : null;
	}

	/// Whether the runner uses a tree file, as its tree or as a subtree.
	public bool UsesFile(StringView path) => FileAt(path) != null;

	TreeFile FileAt(StringView path)
	{
		for (let file in mFiles)
		{
			if (file.path == path)
				return file;
		}
		return null;
	}

	public void Start()
	{
		Home = Transform.Position;
		ApplyStartValues();
		Reload();
	}

	/// Puts Start Values on the blackboard.
	public void ApplyStartValues()
	{
		for (var entry in startValues.Split(';'))
		{
			entry.Trim();
			var parts = entry.Split(' ', .RemoveEmptyEntries);
			StringView key = default;
			if (!(parts.GetNext() case .Ok(out key)))
				continue;
			List<StringView> values = scope .();
			for (let part in parts)
				values.Add(part);
			if (values.Count == 1 && (values[0] == "true" || values[0] == "false"))
				mBlackboard.SetFlag(key, values[0] == "true");
			else if (values.Count == 1)
				mBlackboard.SetNumber(key, SceneSerializer.ParseFloat(values[0]));
			else if (values.Count == 3)
				mBlackboard.SetVector(key, .(SceneSerializer.ParseFloat(values[0]), SceneSerializer.ParseFloat(values[1]), SceneSerializer.ParseFloat(values[2])));
			else
				Log.Warning(scope $"{GameObject.Name}: Start Values entry '{entry}' is not a key with a number, true or false, or three numbers.");
		}
	}

	void Unload()
	{
		if (mRoot != null)
			mRoot.Abort(mContext);
		DeleteAndNullify!(mRoot);
		for (let file in mFiles)
			BehaviorTreeAssets.Release(file.data);
		ClearAndDeleteItems!(mFiles);
	}

	/// Reads the tree file again (if it changed) and starts from the top. The blackboard is kept.
	public void Reload()
	{
		Unload();
		mLoaded.Set(tree);
		mFinished = false;
		mContext.runner = this;
		mContext.blackboard = mBlackboard;
		if (tree.IsEmpty)
			return;
		let path = scope String();
		Assets.ResolvePath(tree, path);
		let file = Use(path);
		if (file == null)
		{
			Log.Warning(scope $"Behaviour tree not found: {tree}");
			return;
		}
		let root = file.data.Root;
		if (root == null)
		{
			Log.Warning(scope $"Behaviour tree {tree} has no Root node.");
			return;
		}
		List<String> stack = scope .();
		stack.Add(file.path);
		mRoot = Build(file, root, stack);
	}

	TreeFile Use(StringView path)
	{
		if (let existing = FileAt(path))
			return existing;
		let data = BehaviorTreeAssets.Acquire(path);
		if (data == null)
			return null;
		let file = new TreeFile();
		file.path.Set(path);
		file.data = data;
		mFiles.Add(file);
		return file;
	}

	/// Makes the running node for a node of a file, and its children. A Run Subtree node gets the other file's tree
	/// as its child; stack holds the files being built, so a tree that runs itself is refused.
	BTNode Build(TreeFile file, BTNodeData data, List<String> stack)
	{
		let node = data.def.create();
		node.data = data;
		file.byId[data.id] = node;
		if (data.def.key == "subtree")
		{
			let path = scope String();
			Assets.ResolvePath(data.values.Count > 0 ? (StringView)data.values[0] : "", path);
			if (stack.Count >= 16 || stack.Contains(path))
				Log.Warning(scope $"Behaviour tree {file.path} runs {data.values[0]} inside itself; that Run Subtree node fails.");
			else if (let sub = Use(path))
			{
				if (let subRoot = sub.data.Root)
				{
					List<int32> top = scope .();
					sub.data.ChildrenOf(subRoot.id, top);
					stack.Add(sub.path);
					// The subtree's Root is left out; what is under it runs as this node's child.
					if (!top.IsEmpty)
						node.children.Add(Build(sub, sub.data.Find(top[0]), stack));
					stack.PopBack();
				}
			}
			else
				Log.Warning(scope $"Behaviour tree {file.path}: subtree not found: {data.values[0]}");
			return node;
		}
		List<int32> children = scope .();
		file.data.ChildrenOf(data.id, children);
		for (let child in children)
			node.children.Add(Build(file, file.data.Find(child), stack));
		return node;
	}

	/// What OnLocalUpdate did: once a frame while playing (BehaviorTreeRunner.FrameAll).
	public void Frame()
	{
		if (mLoaded != tree)
			Reload();
		// In multiplayer the tree thinks on the server only; clients see what it does through the object's movement.
		if (mRoot == null || mFinished || NetworkSync.IsClientOf(Scene))
			return;
		mSinceTick += Time.DeltaTime;
		if (mSinceTick < tickInterval)
			return;
		Tick(mSinceTick);
		mSinceTick = 0;
	}

	/// Runs the tree once. deltaTime is how long it has been since the last tick.
	public BTStatus Tick(float deltaTime)
	{
		if (mRoot == null)
			return .Failure;
		mContext.deltaTime = deltaTime;
		mContext.tick++;
		let result = mRoot.Tick(mContext);
		if (result != .Running && !restartWhenDone)
			mFinished = true;
		return result;
	}

	/// Tells the tree something happened ("Hit", "AlarmRaised"): its Event Received nodes for that name succeed
	/// (within their Within Seconds). In multiplayer, send it on the server, where the tree runs.
	public void SendEvent(StringView name)
	{
		if (mEvents.TryGetAlt(name, let key, ?))
			mEvents[key] = Time.Time;
		else
			mEvents[new String(name)] = Time.Time;
	}

	/// Whether an event came within the last seconds; consume forgets it.
	public bool TakeEvent(StringView name, float withinSeconds, bool consume)
	{
		if (!mEvents.TryGetAlt(name, let key, let time))
			return false;
		let fresh = Time.Time - time <= withinSeconds;
		if (consume || !fresh)
		{
			mEvents.Remove(key);
			delete key;
		}
		return fresh;
	}

	/// Called by Send Event nodes.
	public void RaiseTreeEvent(StringView name)
	{
		OnTreeEvent(name);
	}

	/// What OnDisable did.
	public void OnDisable()
	{
		if (mRoot != null)
			mRoot.Abort(mContext);
	}
}
