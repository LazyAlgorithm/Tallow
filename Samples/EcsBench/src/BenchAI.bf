using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// Server-like AI crowd benchmark: one Behavior Tree Runner and Navigation Agent
/// per object, one shared .tbt file, nearby tagged targets, and a baked walking
/// grid. Only a small number of objects carry NetworkIdentity in offline mode:
/// this measures AI authoring/runtime overhead, not network throughput.
///
/// Unlike "mixed" (1 tree for every 50 cubes), this mode scales the actual
/// expensive systems as TALLOW_BENCH_COUNT increases. No MeshRenderers are added
/// because client graphics/animation are separate network performance budgets.
extension Bench
{
	int mAiAgents, mAiTargets;
	double mNavBakeMs;

	void SpawnAICrowd()
	{
		let width = Math.Max(1, (int)Math.Ceiling(Math.Sqrt((float)mCount)));
		let spacing = 1.7f;
		let side = width * spacing + 20;
		let origin = -side * 0.5f;

		let floor = Scene.CreateGameObject("AI Floor");
		floor.Transform.Position = .(0, -0.1f, 0);
		floor.AddComponent<BoxCollider>().size = .(side, 0.2f, side);
		mSpawned.Add(floor);

		let navigation = Scene.CreateGameObject("AI Navigation");
		navigation.Transform.Position = .(origin, -0.5f, origin);
		let surface = navigation.AddComponent<NavigationSurface>();
		surface.backend = .Grid;
		surface.size = .(side, 4, side);
		surface.cellSize = 1;
		surface.includeRenderMeshes = false;
		let bakeStart = SDL.SDL_GetTicksNS();
		Runtime.Assert(surface.Bake() && surface.Data != null, "AI crowd benchmark failed to bake its navigation surface");
		mNavBakeMs = (SDL.SDL_GetTicksNS() - bakeStart) / 1e6;
		mSpawned.Add(navigation);

		// A sparse population of candidate targets exercises the actual
		// spatial broadphase and #Tag lookup, not an empty search for each AI.
		for (int i = 0; i < mCount; i += 25)
		{
			let target = Scene.CreateGameObject("AI Target");
			target.AddTag("Target");
			target.Transform.Position = .(
				((i % width) - (width - 1) * 0.5f) * spacing,
				0,
				((i / width) - (width - 1) * 0.5f) * spacing);
			mSpawned.Add(target);
			mAiTargets++;
		}

		for (int i = 0; i < mCount; i++)
		{
			let bot = Scene.CreateGameObject("AI Agent");
			bot.Transform.Position = .(
				((i % width) - (width - 1) * 0.5f) * spacing,
				0,
				((i / width) - (width - 1) * 0.5f) * spacing);
			let agent = bot.AddComponent<NavigationAgent>();
			agent.surface = surface;
			agent.avoidOthers = true;
			let runner = bot.AddComponent<BehaviorTreeRunner>();
			runner.tree.Set("BehaviorTrees/Crowd.tbt");
			runner.tickInterval = 0.1f;
			mTrees++;
			mAiAgents++;

			if (i % 50 == 0)
			{
				let identity = bot.AddComponent<NetworkIdentity>();
				identity.playerControlled = false;
				mNetworked++;
			}
			mSpawned.Add(bot);
		}
	}
}
