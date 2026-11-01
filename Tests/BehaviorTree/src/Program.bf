using System;
using System.Collections;
using System.IO;
using Tallow;

namespace BehaviorTreeTests;

[Component]
class Counter : Component
{
	public int32 count;
	public void Bump()
	{
		count++;
	}

	public bool IsThree() => count >= 3;
}

/// A node kind defined by the game: succeeds once the object's counter has been bumped enough.
class CountAtLeast : BTNode
{
	protected override BTStatus OnTick(BTContext context)
	{
		let counter = context.Object.GetComponent<Counter>();
		return counter != null && counter.count >= (int)Number(0) ? .Success : .Failure;
	}
}

[Component]
class PendingMovement : AIMovementDriver
{
	public bool pending, statusRead;
	public override bool PathPending => pending;
	public override bool PathFailed
	{
		get
		{
			statusRead = true;
			return false;
		}
	}

	public override bool HasArrived
	{
		get
		{
			statusRead = true;
			return !pending;
		}
	}

	public override void SetDestination(Vector3 point, float speed, float stoppingDistance)
	{
		pending = true;
	}

	public override void StopMovement()
	{
		pending = false;
	}
}

class Program
{
	const float Dt = 1 / 60f;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static String sFolder = new .("/tmp/tallow-behavior-tree-test") ~ delete _;
	static int sFile;

	/// Small builder: Node("key", parent, x, values...) returns the new node's id.
	class TreeBuilder
	{
		public BehaviorTreeData data = new .() ~ delete _;
		public int32 root;
		public this()
		{
			root = data.AddNode(BehaviorLibrary.Find("root"), .(0, 0)).id;
		}
		public int32 Node(StringView key, int32 parent, float x, params StringView[] values)
		{
			let node = data.AddNode(BehaviorLibrary.Find(key), .(x, 100));
			for (int i < values.Count)
				node.values[i].Set(values[i]);
			data.Connect(parent, node.id);
			return node.id;
		}
		/// Saves the tree to a new file and returns its path.
		public void Save(String path)
		{
			path.Set(scope $"{sFolder}/tree{sFile++}.tbt");
			data.Save(path);
		}
		/// Writes a changed tree over the file a runner uses and reloads it.
		public void Rewrite(BehaviorTreeRunner runner)
		{
			let path = scope String();
			Assets.ResolvePath(runner.tree, path);
			data.Save(path);
			BehaviorTreeAssets.Invalidate(path);
			runner.Reload();
		}
		/// Saves the tree and gives a runner on a new object.
		public BehaviorTreeRunner Run(Scene scene, GameObject object = null)
		{
			let path = scope $"{sFolder}/tree{sFile++}.tbt";
			data.Save(path);
			let go = object ?? scene.CreateGameObject("Runner");
			let runner = go.AddComponent<BehaviorTreeRunner>();
			runner.tree.Set(path);
			runner.Start();
			return runner;
		}
	}

	/// E15: subtrees, shared files, events, hearing, tags, numbers, chance, Run Once, duplicating, sight points.
	static bool Upgrades(Scene scene, delegate void(Vector3 min, Vector3 max) solid)
	{
		bool ok = true;
		// ---- subtrees ----
		{
			let sub = scope TreeBuilder();
			let subFlag = sub.Node("bb.set", sub.root, 0, "fromSub", "true");
			let subPath = sub.Save(.. scope .());
			let main = scope TreeBuilder();
			let sequence = main.Node("sequence", main.root, 0);
			main.Node("bb.set", sequence, -100, "fromMain", "true");
			let call = main.Node("subtree", sequence, 100, subPath);
			let before = BehaviorTreeAssets.LoadedCount;
			let runner = main.Run(scene);
			ok &= Check(runner.Tick(Dt) == .Success && runner.Blackboard.GetFlag("fromMain") && runner.Blackboard.GetFlag("fromSub") && runner.StatusOf(call) == .Success, "a Run Subtree node runs another file's tree with the same blackboard");
			ok &= Check(runner.UsesFile(subPath) && runner.StatusOf(subPath, subFlag) == .Success, "the runner reports the subtree's nodes by file, for the editor");
			ok &= Check(BehaviorTreeAssets.LoadedCount == before + 2, "the tree and its subtree are each read once");
			let mainPath = scope String(runner.tree);
			let second = scene.CreateGameObject("Second").AddComponent<BehaviorTreeRunner>();
			second.tree.Set(mainPath);
			second.Start();
			ok &= Check(BehaviorTreeAssets.LoadedCount == before + 2 && second.Tick(Dt) == .Success, "a second runner of the same tree shares the loaded files");
			// The subtree changes: after Invalidate, a reload reads it again.
			sub.data.Find(subFlag).values[0].Set("changed");
			sub.data.Save(subPath);
			BehaviorTreeAssets.Invalidate(subPath);
			runner.Reload();
			runner.Tick(Dt);
			ok &= Check(runner.Blackboard.GetFlag("changed"), "an invalidated file is read again on reload");
			// A tree that runs itself is refused rather than built forever.
			let loop = scope TreeBuilder();
			let itself = loop.Node("subtree", loop.root, 0, "");
			let loopPath = loop.Save(.. scope .());
			loop.data.Find(itself).values[0].Set(loopPath);
			loop.data.Save(loopPath);
			let looping = scene.CreateGameObject("Loop").AddComponent<BehaviorTreeRunner>();
			looping.tree.Set(loopPath);
			looping.Start();
			ok &= Check(looping.Tick(Dt) == .Failure, "a subtree that runs its own tree fails instead of looping");
		}
		// ---- events ----
		{
			let b = scope TreeBuilder();
			b.Node("event.received", b.root, 0, "Hit", "1", "true");
			let runner = b.Run(scene);
			let none = runner.Tick(Dt);
			runner.SendEvent("Hit");
			let got = runner.Tick(Dt);
			let again = runner.Tick(Dt);
			runner.SendEvent("Hit");
			Time.Time += 5;
			let stale = runner.Tick(Dt);
			ok &= Check(none == .Failure && got == .Success && again == .Failure && stale == .Failure, "Event Received succeeds once per event sent, and not for an old one");
			let b2 = scope TreeBuilder();
			b2.Node("event.send", b2.root, 0, "Alarm");
			let sender = b2.Run(scene);
			List<String> heard = scope .();
			defer
			{
				ClearAndDeleteItems!(heard);
			}
			sender.OnTreeEvent.Add(new (name) => heard.Add(new String(name)));
			sender.Tick(Dt);
			ok &= Check(heard.Count == 1 && heard[0] == "Alarm", "Send Event calls the runner's OnTreeEvent");
		}
		// ---- hearing and tags ----
		{
			let b = scope TreeBuilder();
			b.Node("hear", b.root, 0, "1", "1", "noise");
			let runner = b.Run(scene, scene.CreateGameObject("Ears"));
			runner.Transform.Position = .(4, 0, 4);
			let shooter = scene.CreateGameObject("Shooter");
			AINoise.Forget();
			ok &= Check(runner.Tick(Dt) == .Failure, "nothing is heard in silence");
			AINoise.Make(scene, .(6, 0, 4), 3, shooter);
			let heard = runner.Tick(Dt);
			Vector3 noisePoint = default;
			let remembered = runner.Blackboard.TryGetPosition("noise", scene, out noisePoint) && (noisePoint - Vector3(6, 0, 4)).Length < 0.01f;
			ok &= Check(heard == .Success && remembered && runner.Blackboard.GetObject("noise.source", scene) == shooter, "a noise within earshot is heard, with where and who");
			ok &= Check(runner.Tick(Dt) == .Failure, "each noise is heard once");
			AINoise.Make(scene, .(9, 0, 4), 3, shooter);
			ok &= Check(runner.Tick(Dt) == .Failure, "a noise out of earshot is not heard");
			AINoise.Make(scene, .(4, 0, 4), 3, runner.GameObject);
			ok &= Check(runner.Tick(Dt) == .Failure, "an object does not hear its own noise");
			AINoise.Make(scene, .(5, 0, 4), 3, shooter);
			Time.Time += 3;
			ok &= Check(runner.Tick(Dt) == .Failure, "an old noise is not heard");
			shooter.Transform.Position = .(5, 0, 5);
			shooter.AddTag("Enemy");
			let b2 = scope TreeBuilder();
			b2.Node("near", b2.root, 0, "#Enemy", "3", "foe");
			let tagRunner = b2.Run(scene, scene.CreateGameObject("Tag Looker"));
			tagRunner.Transform.Position = .(4, 0, 4);
			ok &= Check(tagRunner.Tick(Dt) == .Success && tagRunner.Blackboard.GetObject("foe", scene) == shooter, "#Tag finds objects by tag");
		}
		// ---- numbers, start values, chance, random selector, Run Once ----
		{
			let b = scope TreeBuilder();
			let sequence = b.Node("sequence", b.root, 0);
			b.Node("bb.number", sequence, -200, "count", "2", "false");
			b.Node("bb.number", sequence, -100, "count", "1", "true");
			b.Node("bb.compare", sequence, 0, "count", ">=", "3");
			let less = b.Node("bb.compare", sequence, 100, "count", "<", "3");
			let runner = b.Run(scene);
			ok &= Check(runner.Tick(Dt) == .Failure && runner.Blackboard.GetNumber("count") == 3 && runner.StatusOf(less) == .Failure, "Set Number sets and adds; Compare Number compares");
			let starter = scene.CreateGameObject("Starter").AddComponent<BehaviorTreeRunner>();
			starter.startValues.Set("ammo 3; alert true;post 1 2 3");
			starter.Start();
			Vector3 post = default;
			let hasPost = starter.Blackboard.TryGetPosition("post", scene, out post);
			ok &= Check(starter.Blackboard.GetNumber("ammo") == 3 && starter.Blackboard.GetFlag("alert") && hasPost && post == Vector3(1, 2, 3), "Start Values fill the blackboard");
			let chance = scope TreeBuilder();
			let never = chance.Node("chance", chance.root, 0, "0");
			let chanceRunner = chance.Run(scene);
			bool anySuccess = false;
			for (int i < 20)
				anySuccess |= chanceRunner.Tick(Dt) == .Success;
			chance.data.Find(never).values[0].Set("1");
			chance.Rewrite(chanceRunner);
			ok &= Check(!anySuccess && chanceRunner.Tick(Dt) == .Success, "Chance 0 never succeeds and 1 always does");
			let random = scope TreeBuilder();
			let pick = random.Node("random.selector", random.root, 0);
			random.Node("bb.number", pick, -100, "a", "1", "true");
			random.Node("bb.number", pick, 100, "b", "1", "true");
			let randomRunner = random.Run(scene);
			for (int i < 40)
				randomRunner.Tick(Dt);
			let a = randomRunner.Blackboard.GetNumber("a");
			let bCount = randomRunner.Blackboard.GetNumber("b");
			ok &= Check(a + bCount == 40 && a > 5 && bCount > 5, "Random Selector tries its children in a random order");
			let once = scope TreeBuilder();
			let gate = once.Node("once", once.root, 0);
			once.Node("bb.number", gate, 0, "times", "1", "true");
			let onceRunner = once.Run(scene);
			for (int i < 5)
				onceRunner.Tick(Dt);
			ok &= Check(onceRunner.Blackboard.GetNumber("times") == 1 && onceRunner.StatusOf(gate) == .Success, "Run Once runs its child once");
		}
		// ---- duplicating in the editor ----
		{
			let b = scope TreeBuilder();
			let sequence = b.Node("sequence", b.root, 0);
			b.Node("wait", sequence, -100, "2");
			b.Node("log", sequence, 100, "hi");
			let nodes = b.data.nodes.Count;
			let links = b.data.links.Count;
			let copy = b.data.Duplicate(sequence, .(40, 40));
			List<int32> children = scope .();
			b.data.ChildrenOf(copy, children);
			ok &= Check(copy != 0 && b.data.nodes.Count == nodes + 3 && b.data.links.Count == links + 2 && b.data.ParentOf(copy) == 0 && children.Count == 2 && b.data.Find(children[1]).values[0] == "hi", "Duplicate copies a node and what is under it");
			ok &= Check(b.data.Duplicate(b.root, .(40, 40)) == 0, "the Root is not duplicated");
		}
		// ---- sight points: a target half behind low cover ----
		{
			solid(.(4, 0, -4.2f), .(8, 1.2f, -3.8f));
			let target = scene.CreateGameObject("Crouching Target");
			target.Transform.Position = .(6, 0.02f, -3);
			target.AddComponent<CapsuleCollider>();
			scene.Physics.CreateBody(target.Transform, target.GetComponent<CapsuleCollider>().GetShape(), null);
			scene.Physics.Step(Dt);
			let looker = scene.CreateGameObject("Sentry");
			looker.Transform.Position = .(6, 0.02f, -8);
			let one = scope TreeBuilder();
			let seeOne = one.Node("see", one.root, 0, "Crouching Target", "10", "90", "1.6", "target", "1");
			let oneRunner = one.Run(scene, looker);
			let missed = oneRunner.Tick(Dt);
			one.data.Find(seeOne).values[5].Set("3");
			one.Rewrite(oneRunner);
			ok &= Check(missed == .Failure && oneRunner.Tick(Dt) == .Success, "one sight ray misses a target behind low cover; three see its head");
		}
		return ok;
	}

	public static int Main(String[] args)
	{
		Directory.CreateDirectory(sFolder).IgnoreError();
		defer
		{
			for (int i < sFile)
				File.Delete(scope $"{sFolder}/tree{i}.tbt").IgnoreError();
			Directory.Delete(sFolder).IgnoreError();
		}
		let scene = scope Scene();
		Scene.Active = scene;
		bool ok = true;
		Time.DeltaTime = Dt;

		// ---- structure ----
		{
			let b = scope TreeBuilder();
			let sequence = b.Node("sequence", b.root, 0);
			let right = b.Node("wait", sequence, 200, "1");
			let left = b.Node("log", sequence, -200, "hi");
			let invert = b.Node("invert", sequence, 0);
			let inner = b.Node("wait", invert, 0, "1");
			List<int32> order = scope .();
			b.data.ChildrenOf(sequence, order);
			ok &= Check(order.Count == 3 && order[0] == left && order[1] == invert && order[2] == right, "children run in left-to-right canvas order");
			let error = scope String();
			ok &= Check(!b.data.Connect(inner, sequence, error) && !error.IsEmpty, "a link that would make a loop is refused");
			ok &= Check(!b.data.Connect(left, right), "an action cannot have children");
			let other = b.data.AddNode(BehaviorLibrary.Find("log"), .(50, 200)).id;
			b.data.Connect(invert, other);
			order.Clear();
			b.data.ChildrenOf(invert, order);
			ok &= Check(order.Count == 1 && order[0] == other && b.data.ParentOf(inner) == 0, "a decorator keeps only its newest child");
			let path = scope $"{sFolder}/roundtrip.tbt";
			b.data.Save(path);
			let loaded = scope BehaviorTreeData();
			ok &= Check(loaded.Load(path) && loaded.nodes.Count == b.data.nodes.Count && loaded.links.Count == b.data.links.Count && loaded.Find(left).values[0] == "hi" && loaded.Root != null, "a tree survives save and load");
			File.Delete(path).IgnoreError();
		}

		// ---- flow ----
		{
			let b = scope TreeBuilder();
			let sequence = b.Node("sequence", b.root, 0);
			let wait = b.Node("wait", sequence, -100, "0.1");
			let flag = b.Node("bb.set", sequence, 100, "done", "true");
			let runner = b.Run(scene);
			runner.restartWhenDone = false;
			let first = runner.Tick(Dt);
			ok &= Check(first == .Running && runner.StatusOf(wait) == .Running && runner.StatusOf(flag) == .Idle && runner.LastTickOf(wait) == runner.TickCount && !runner.Blackboard.GetFlag("done"), "a sequence waits on its running child and reports which node is active");
			BTStatus last = .Running;
			int ticks = 1;
			while (last == .Running && ticks++ < 100)
				last = runner.Tick(Dt);
			ok &= Check(last == .Success && ticks >= 6 && ticks <= 8 && runner.Blackboard.GetFlag("done") && runner.StatusOf(sequence) == .Success, "then runs the next child and succeeds");
		}
		{
			let b = scope TreeBuilder();
			let selector = b.Node("selector", b.root, 0);
			let missing = b.Node("bb.flag", selector, -100, "nope");
			let inverted = b.Node("invert", selector, 0);
			b.Node("bb.flag", inverted, 0, "nope");
			let never = b.Node("log", selector, 100, "unreached");
			let runner = b.Run(scene);
			ok &= Check(runner.Tick(Dt) == .Success && runner.StatusOf(missing) == .Failure && runner.StatusOf(inverted) == .Success && runner.StatusOf(never) == .Idle, "a selector stops at the first success; invert flips a failure");
		}
		{
			let b = scope TreeBuilder();
			let again = b.Node("repeat", b.root, 0, "3");
			b.Node("call", again, 0, "Bump");
			let go = scene.CreateGameObject("Counted");
			let counter = go.AddComponent<Counter>();
			let runner = b.Run(scene, go);
			runner.restartWhenDone = false;
			BTStatus last = .Running;
			for (int i = 0; i < 10 && last == .Running; i++)
				last = runner.Tick(Dt);
			ok &= Check(last == .Success && counter.count == 3, "repeat runs its child three times; call method runs code on the object");
			let b2 = scope TreeBuilder();
			let check = b2.Node("call", b2.root, 0, "IsThree");
			let runner2 = b2.Run(scene, go);
			let yes = runner2.Tick(Dt);
			counter.count = 0;
			let no = runner2.Tick(Dt);
			ok &= Check(yes == .Success && no == .Failure && runner2.StatusOf(check) == .Failure, "a method that returns bool decides success or failure");
		}
		{
			let b = scope TreeBuilder();
			let timeout = b.Node("timeout", b.root, 0, "0.1");
			let wait = b.Node("wait", timeout, 0, "5");
			let runner = b.Run(scene);
			runner.restartWhenDone = false;
			BTStatus last = .Running;
			int ticks = 0;
			while (last == .Running && ticks++ < 100)
				last = runner.Tick(Dt);
			ok &= Check(last == .Failure && ticks <= 8 && runner.StatusOf(wait) == .Idle, "timeout stops a child that takes too long");
		}
		{
			// The alarm branch has priority; raising the flag interrupts the long wait on the right.
			let b = scope TreeBuilder();
			let selector = b.Node("reactive.selector", b.root, 0);
			let alarmed = b.Node("sequence", selector, -100);
			b.Node("bb.flag", alarmed, -150, "alarm");
			let react = b.Node("wait", alarmed, -50, "0.05");
			let idle = b.Node("wait", selector, 100, "100");
			let runner = b.Run(scene);
			runner.Tick(Dt);
			runner.Tick(Dt);
			ok &= Check(runner.StatusOf(idle) == .Running && runner.StatusOf(react) == .Idle, "the low-priority branch runs while nothing is wrong");
			runner.Blackboard.SetFlag("alarm", true);
			runner.Tick(Dt);
			ok &= Check(runner.StatusOf(idle) == .Idle && runner.StatusOf(react) == .Running && runner.LastTickOf(idle) < runner.TickCount, "a reactive selector interrupts it when the higher branch becomes possible");
		}
		{
			BehaviorLibrary.Add("test.count", "Game", "Count At Least", .Condition, new () => new CountAtLeast()).With("Count", .Number, "2");
			let b = scope TreeBuilder();
			let check = b.Node("test.count", b.root, 0, "2");
			let go = scene.CreateGameObject("Custom");
			let counter = go.AddComponent<Counter>();
			let runner = b.Run(scene, go);
			let before = runner.Tick(Dt);
			counter.count = 2;
			let after = runner.Tick(Dt);
			ok &= Check(before == .Failure && after == .Success && runner.StatusOf(check) == .Success && BehaviorLibrary.Find("test.count").parameters.Count == 1, "a node kind registered by the game loads from a file and runs");
		}
		{
			let b = scope TreeBuilder();
			let move = b.Node("nav.position", b.root, 0, "0 0 0", "4", "0.3");
			let go = scene.CreateGameObject("Deferred mover");
			let driver = go.AddComponent<PendingMovement>();
			let runner = b.Run(scene, go);
			runner.restartWhenDone = false;
			runner.Tick(Dt);
			ok &= Check(runner.StatusOf(move) == .Running && driver.pending && !driver.statusRead, "movement tasks leave pending requests queued instead of forcing status resolution");
			driver.pending = false;
			runner.Tick(Dt);
			ok &= Check(runner.StatusOf(move) == .Success && driver.statusRead, "movement tasks consume the result after queued work finishes");
			runner.Enabled = false;
		}

		// ---- a level: floor, a wall, baked navigation ----
		void Solid(Vector3 min, Vector3 max)
		{
			let go = scene.CreateGameObject("Level");
			go.Transform.Position = (min + max) * 0.5f;
			let collider = go.AddComponent<BoxCollider>();
			collider.size = max - min;
			scene.Physics.CreateBody(go.Transform, collider.GetShape(), null);
		}
		Solid(.(-10, -1, -10), .(10, 0, 10));
		Solid(.(-0.3f, 0, -10), .(0.3f, 3, 4)); // a wall along z, open at the far end
		let surface = scene.CreateGameObject("Navigation").AddComponent<NavigationSurface>();
		surface.Transform.Position = .(-10, -1, -10);
		surface.size = .(20, 5, 20);
		surface.cellSize = 0.5f;
		ok &= Check(surface.Bake(), "navigation bakes for the test level");
		scene.Physics.Step(Dt);
		GameObject Walker(StringView name, Vector3 position)
		{
			let go = scene.CreateGameObject(name);
			go.Transform.Position = position;
			go.AddComponent<NavigationAgent>().surface = surface;
			return go;
		}
		void Run(BehaviorTreeRunner runner, int ticks, delegate bool() until = null)
		{
			for (int i < ticks)
			{
				runner.Tick(Dt);
				for (let c in scene.Components)
				{
					if (let agent = c as NavigationAgent)
						agent.Update();
				}
				if (until != null && until()) break;
			}
		}

		// ---- navigation ----
		{
			let b = scope TreeBuilder();
			let move = b.Node("nav.position", b.root, 0, "-6 0 6", "4", "0.3");
			let go = Walker("Mover", .(-6, 0.02f, -6));
			let runner = b.Run(scene, go);
			runner.restartWhenDone = false;
			runner.Tick(Dt);
			ok &= Check(runner.StatusOf(move) == .Running, "move to position is running while the agent walks");
			Run(runner, 600, scope () => runner.StatusOf(move) != .Running);
			ok &= Check(runner.StatusOf(move) == .Success && (go.Transform.Position - Vector3(-6, 0.02f, 6)).Length < 0.6f, "and succeeds on arrival");
			go.GetComponent<BehaviorTreeRunner>().Enabled = false;
		}
		{
			let route = scene.CreateGameObject("Route");
			for (let point in Vector3[?](.(-8, 0.02f, -8), .(-4, 0.02f, -8), .(-4, 0.02f, -4)))
			{
				let waypoint = scene.CreateGameObject("Waypoint");
				waypoint.Transform.Position = point;
				waypoint.Transform.SetParent(route.Transform, true);
			}
			let b = scope TreeBuilder();
			let again = b.Node("repeat", b.root, 0, "0");
			b.Node("nav.patrol", again, 0, "Route", "5", "0.3");
			let go = Walker("Patroller", .(-8, 0.02f, -6));
			let runner = b.Run(scene, go);
			List<int> visited = scope .();
			for (int i < 1500)
			{
				Run(runner, 1);
				for (int w < 3)
				{
					if ((go.Transform.Position - route.Transform.Children[w].Position).Length < 0.8f && (visited.Count == 0 || visited.Back != w))
						visited.Add(w);
				}
				if (visited.Count >= 4) break;
			}
			ok &= Check(visited.Count >= 4 && visited[0] == 0 && visited[1] == 1 && visited[2] == 2 && visited[3] == 0, "patrol visits the waypoints in order and wraps around");
			go.GetComponent<BehaviorTreeRunner>().Enabled = false;
		}

		// ---- detection ----
		{
			let guard = Walker("Guard", .(-5, 0.02f, 0)); // faces +z
			let intruder = scene.CreateGameObject("Intruder Bob");
			intruder.Transform.Position = .(-5, 0.02f, 6);
			intruder.AddComponent<CapsuleCollider>();
			scene.Physics.CreateBody(intruder.Transform, intruder.GetComponent<CapsuleCollider>().GetShape(), null);
			scene.Physics.Step(Dt);
			let b = scope TreeBuilder();
			let see = b.Node("see", b.root, 0, "Intruder*", "10", "110", "1.6", "target");
			let runner = b.Run(scene, guard);
			ok &= Check(runner.Tick(Dt) == .Success && runner.Blackboard.GetObject("target", scene) == intruder && runner.Blackboard.Has("target.position"), "can see finds a named object ahead and remembers it");
			intruder.Transform.Position = .(-5, 0.02f, -6);
			scene.Physics.Step(Dt);
			ok &= Check(runner.Tick(Dt) == .Failure, "an object behind the looker is outside the view cone");
			intruder.Transform.Position = .(-5, 0.02f, 14);
			ok &= Check(runner.Tick(Dt) == .Failure, "an object beyond the range is not seen");
			guard.Transform.Rotation = Quaternion.Euler(0, 90, 0); // face +x, toward the wall
			intruder.Transform.Position = .(5, 0.02f, 0);
			scene.Physics.Step(Dt);
			ok &= Check(runner.Tick(Dt) == .Failure, "a wall blocks the view");
			intruder.Transform.Position = .(-2, 0.02f, 0);
			scene.Physics.Step(Dt);
			ok &= Check(runner.Tick(Dt) == .Success && runner.StatusOf(see) == .Success, "the same direction is visible on this side of the wall");
			let b2 = scope TreeBuilder();
			b2.Node("near", b2.root, 0, "Intruder Bob", "4", "close");
			let nearRunner = b2.Run(scene, scene.CreateGameObject("Listener"));
			nearRunner.Transform.Position = .(1.5f, 0.02f, 0);
			ok &= Check(nearRunner.Tick(Dt) == .Success && nearRunner.Blackboard.GetObject("close", scene) == intruder, "is near works through walls");
			runner.Enabled = false;

			// ---- a whole behaviour: patrol until an intruder is seen, then chase ----
			let chaser = Walker("Chaser", .(-8, 0.02f, -8));
			intruder.Transform.Position = .(6, 0.02f, 8);
			scene.Physics.Step(Dt); // other side of the wall, out of sight
			let tree = scope TreeBuilder();
			let top = tree.Node("reactive.selector", tree.root, 0);
			let chase = tree.Node("reactive.sequence", top, -200);
			tree.Node("see", chase, -300, "Intruder*", "9", "360", "1.6", "target");
			let follow = tree.Node("nav.target", chase, -100, "target", "5", "1.2", "true");
			let patrol = tree.Node("nav.patrol", top, 200, "Route", "3", "0.3");
			let brain = tree.Run(scene, chaser);
			Run(brain, 60);
			ok &= Check(brain.StatusOf(patrol) == .Running && brain.StatusOf(follow) == .Idle, "the guard patrols while it sees nobody");
			intruder.Transform.Position = .(-3, 0.02f, -3);
			scene.Physics.Step(Dt);
			Run(brain, 5);
			ok &= Check(brain.StatusOf(patrol) == .Idle && brain.StatusOf(follow) == .Running, "seeing the intruder interrupts the patrol and starts the chase");
			Run(brain, 600, scope () => (chaser.Transform.Position - intruder.Transform.Position).Length < 1.3f);
			ok &= Check((chaser.Transform.Position - intruder.Transform.Position).Length < 1.4f, "the chase ends beside the intruder");
			intruder.Transform.Position = .(6, 0.02f, 8);
			scene.Physics.Step(Dt);
			Run(brain, 30);
			ok &= Check(brain.StatusOf(patrol) == .Running, "losing sight sends the guard back to its patrol");
		}

		ok &= Upgrades(scene, scope (min, max) => Solid(min, max));

		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
