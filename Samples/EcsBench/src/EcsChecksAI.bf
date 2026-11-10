using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// The AI systems: what behaviour trees look for (AIPerception), runners and agents taken from Flecs in object order
/// (HandleRoster), switching them off mid-run, and the agents' steering done for all of them at once
/// (NavigationAgentSystem).
extension EcsChecks
{
	static void WriteTree(String path, StringView name, StringView text)
	{
		path.AppendF("{}/../build/{}.tbt", Assets.ProjectPath, name);
		if (System.IO.File.WriteAllText(path, text) case .Err)
			Expect(false, scope $"the check tree could not be written to {path}");
	}

	static void AIChecks()
	{
		let previous = Scene.Active;
		PerceptionChecks();
		RosterChecks();
		SteeringChecks();
		Scene.Active = previous;
	}

	/// Is Near and FindOne answer from the scene's AIPerception, with the grid (over 48 matches) and without.
	static void PerceptionChecks()
	{
		let path = WriteTree(.. scope .(), "check_near", "tree \"Near\"\nnode 1 root 0 0\nnode 2 near 0 110 \"#Target\" \"10\" \"target\"\nlink 1 2\n");
		int[2] counts = .(5, 80);
		for (let count in counts)
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let guard = scene.CreateGameObject("Guard");
			let runner = guard.AddComponent<BehaviorTreeRunner>();
			runner.tree.Set(path);
			let targets = scope List<GameObject>();
			let random = scope Random(7);
			for (int i < count)
			{
				let target = scene.CreateGameObject("Target");
				target.AddTag("Target");
				var at = Vector3((float)random.NextDouble() * 40 - 20, 0, (float)random.NextDouble() * 40 - 20);
				// None nearer the guard than the two below.
				if (at.Length < 2)
					at = at.LengthSquared > 0.0001f ? at.Normalized * 2 : Vector3(2, 0, 0);
				target.Transform.Position = at;
				targets.Add(target);
			}
			// Two at the same spot nearer than any other: the older one wins the tie.
			targets[1].Transform.Position = .(0.5f, 0, 0.5f);
			targets[2].Transform.Position = .(0.5f, 0, 0.5f);
			// One always in range.
			targets[3].Transform.Position = .(3, 0, 0);
			scene.StartPlay();
			Time.DeltaTime = 0.1f;
			scene.Update();
			GameObject Nearest()
			{
				GameObject best = null;
				float bestDistance = 10;
				for (let target in targets)
				{
					if (!target.ActiveInHierarchy || target.IsDestroyed)
						continue;
					let distance = (target.Transform.Position - guard.Transform.Position).Length;
					if (distance < bestDistance || (distance == bestDistance && best != null && target.Id < best.Id))
					{
						best = target;
						bestDistance = distance;
					}
				}
				return best;
			}
			let found = runner.Blackboard.GetObject("target", scene);
			Expect(found == targets[1] && found == Nearest(), scope $"Is Near finds the nearest tagged object, older first on a tie ({count} targets)");
			targets[1].SetActive(false);
			scene.Update();
			Expect(runner.Blackboard.GetObject("target", scene) == targets[2], scope $"a switched-off object is passed over ({count} targets)");
			let gone = targets[2];
			targets.Remove(gone);
			scene.Destroy(gone);
			let fresh = scene.CreateGameObject("Late");
			fresh.Transform.Position = .(0.2f, 0, 0.1f);
			fresh.AddTag("Target");
			targets.Add(fresh);
			// In the same frame: the scene's objects changed, so the matches are gathered again.
			runner.Tick(0.1f);
			Expect(runner.Blackboard.GetObject("target", scene) == fresh, scope $"an object tagged this frame is found at once ({count} targets)");
			scene.Update();
			Expect(runner.Blackboard.GetObject("target", scene) == Nearest(), scope $"a destroyed object is not found ({count} targets)");
			fresh.Transform.Position = .(30, 0, 30);
			scene.Update();
			Expect(runner.Blackboard.GetObject("target", scene) == Nearest(), scope $"an object that moved away is no longer the nearest ({count} targets)");
			scene.StopPlay();
		}
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let first = scene.CreateGameObject("Enemy A");
			first.SetActive(false);
			let second = scene.CreateGameObject("Enemy B");
			Expect(BTSenses.FindOne(scene, "Enemy A") == first, "an exact name finds the object even when it is switched off, as Scene.Find does");
			Expect(BTSenses.FindOne(scene, "Enemy*") == second, "a prefix finds the first active match");
			let third = scene.CreateGameObject("Enemy C");
			third.AddTag("Boss");
			Expect(BTSenses.FindOne(scene, "#Boss") == third, "a tag added after a search is found");
			second.Name.Set("Friend");
			scene.Update();
			Expect(BTSenses.FindOne(scene, "Enemy*") == third, "a renamed object is not matched by its old name next frame");
		}
		System.IO.File.Delete(path).IgnoreError();
	}

	/// Runners tick oldest object first whatever table Flecs keeps them in, and switching one off (or its object)
	/// aborts it at once; a runner removed by another tree's event in the same frame is not ticked.
	static void RosterChecks()
	{
		let tickPath = WriteTree(.. scope .(), "check_tick", "tree \"Tick\"\nnode 1 root 0 0\nnode 2 event.send 0 110 \"Tick\"\nlink 1 2\n");
		let waitPath = WriteTree(.. scope .(), "check_wait", "tree \"Wait\"\nnode 1 root 0 0\nnode 2 wait 0 110 \"5\" \"0\"\nlink 1 2\n");
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let order = scope List<String>();
			let runners = scope List<BehaviorTreeRunner>();
			StringView[4] names = .("A", "B", "C", "D");
			for (let name in names)
			{
				let gameObject = scene.CreateGameObject(name);
				let runner = gameObject.AddComponent<BehaviorTreeRunner>();
				runner.tree.Set(tickPath);
				runners.Add(runner);
			}
			// B and D get another component, which moves them to other Flecs tables (and later in its order).
			runners[1].GameObject.AddComponent<WindZone>();
			runners[3].GameObject.AddComponent<WindZone>();
			for (let runner in runners)
			{
				let name = runner.GameObject.Name;
				runner.OnTreeEvent.Add(new (event) => order.Add(name));
			}
			scene.StartPlay();
			Time.DeltaTime = 0.1f;
			scene.Update();
			let text = scope String();
			for (let name in order)
				text.Append(name);
			Expect(text == "ABCD", scope $"runners tick oldest object first ({text})");
			// A's event removes C's runner: C is not ticked in this frame and nothing breaks.
			bool removed = false;
			runners[0].OnTreeEvent.Add(new [&] (event) =>
				{
					if (!removed)
					{
						removed = true;
						runners[2].GameObject.RemoveComponent<BehaviorTreeRunner>();
					}
				});
			order.Clear();
			scene.Update();
			text.Clear();
			for (let name in order)
				text.Append(name);
			Expect(text == "ABD", scope $"a runner removed during the step is not ticked ({text})");
			scene.StopPlay();
		}
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let guard = scene.CreateGameObject("Waiter");
			let runner = guard.AddComponent<BehaviorTreeRunner>();
			runner.tree.Set(waitPath);
			scene.StartPlay();
			Time.DeltaTime = 0.1f;
			scene.Update();
			Expect(runner.StatusOf(2) == .Running, "the Wait node is running");
			runner.enabled = false;
			Expect(runner.StatusOf(2) == .Idle, "switching the runner off aborts its running node at once");
			let ticks = runner.TickCount;
			scene.Update();
			Expect(runner.TickCount == ticks, "a switched-off runner does not tick");
			runner.enabled = true;
			scene.Update();
			Expect(runner.StatusOf(2) == .Running && runner.TickCount == ticks + 1, "switched on again, it runs again");
			guard.SetActive(false);
			Expect(runner.StatusOf(2) == .Idle, "switching its object off aborts it at once");
			scene.Update();
			Expect(runner.TickCount == ticks + 1, "on a switched-off object it does not tick");
			guard.SetActive(true);
			scene.Update();
			Expect(runner.TickCount == ticks + 2 && scene.BehaviorTrees.Count == 1, "its object switched on again, it ticks");
			scene.StopPlay();
		}
		{
			// A value read as a number is read again when its text changes.
			let data = scope BTNodeData();
			data.values.Add(new .("2.5"));
			Expect(data.Number(0) == 2.5f, "a node value reads as a number");
			data.values[0].Set("4");
			Expect(data.Number(0) == 4 && data.Number(3) == 0, "a changed value is read again; a missing one is 0");
		}
		System.IO.File.Delete(tickPath).IgnoreError();
		System.IO.File.Delete(waitPath).IgnoreError();
	}

	/// A crowd steering round each other: agents crossing head-on do not walk through each other, every one arrives,
	/// and two identical crowds end in exactly the same places (the steering, spread over threads, does not depend on
	/// which thread did what).
	static void SteeringChecks()
	{
		Vector3[32] ends = default;
		bool[2] arrived = default;
		float[2] closest = default;
		int[2] steered = default;
		for (int run < 2)
		{
			let scene = scope Scene();
			Scene.Active = scene;
			let floor = scene.CreateGameObject("Floor");
			floor.Transform.Position = .(0, -0.1f, 0);
			floor.AddComponent<BoxCollider>().size = .(30, 0.2f, 30);
			let area = scene.CreateGameObject("Area");
			area.Transform.Position = .(-15, -0.5f, -15);
			let surface = area.AddComponent<NavigationSurface>();
			surface.backend = .Grid;
			surface.size = .(30, 4, 30);
			surface.cellSize = 0.5f;
			surface.includeRenderMeshes = false;
			Expect(surface.Bake(), "the steering floor bakes");
			let agents = scope List<NavigationAgent>();
			// Two lines of eight walking through each other.
			for (int i < 16)
			{
				let side = i < 8 ? -1.0f : 1.0f;
				let lane = (i % 8) * 1.2f - 4.2f;
				let walker = scene.CreateGameObject("Walker");
				walker.Transform.Position = .(side * 8, 0, lane);
				let agent = walker.AddComponent<NavigationAgent>();
				agent.surface = surface;
				agent.radius = 0.4f;
				agents.Add(agent);
			}
			scene.StartPlay();
			for (int i < 16)
			{
				let side = i < 8 ? -1.0f : 1.0f;
				let lane = (i % 8) * 1.2f - 4.2f;
				agents[i].SetDestination(.(-side * 8, 0, lane), 3, 0.3f);
			}
			closest[run] = float.MaxValue;
			for (int frame < 400)
			{
				Time.DeltaTime = 1 / 30.0f;
				scene.Update();
				steered[run] = Math.Max(steered[run], scene.NavigationAgents.SteeredCount);
				for (int a < 16)
				{
					for (int b = a + 1; b < 16; b++)
					{
						var d = agents[a].Transform.Position - agents[b].Transform.Position;
						d.y = 0;
						closest[run] = Math.Min(closest[run], d.Length);
					}
				}
				bool all = true;
				for (let agent in agents)
					all &= agent.HasArrived;
				if (all)
				{
					arrived[run] = true;
					break;
				}
			}
			for (int i < 16)
				ends[run * 16 + i] = agents[i].Transform.Position;
			scene.StopPlay();
		}
		Console.WriteLine($"EcsBench checks: crowd of 16 crossing, closest {closest[0]:F2} m, up to {steered[0]} steering at once");
		Expect(steered[0] > 0, "the agents steered round each other");
		Expect(arrived[0] && arrived[1], "every agent of the crowd arrives");
		// Head-on in the same lanes, agents that did not steer would meet at 0 m.
		Expect(closest[0] > 0.2f, scope $"crossing agents steer round each other (closest {closest[0]:F2} m, radius 0.4 each)");
		bool same = true;
		for (int i < 16)
			same &= ends[i] == ends[16 + i];
		Expect(same && closest[0] == closest[1], "two identical crowds end in exactly the same places");
	}
}
