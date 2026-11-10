using System;
using System.Collections;
using Tallow;

namespace EcsBench;

/// TALLOW_BENCH_MODE=ai: a crowd where every object has a Behavior Tree Runner and a Navigation Agent, on a baked
/// walking grid. The tree (BehaviorTrees/Crowd.tbt) looks for a nearby object tagged Target every tick, walks to it,
/// and wanders when there is none, so perception, path searches and steering round each other all scale with the
/// count. One object in 100 is a moving Navigation Obstacle the agents steer round. No renderers: this measures the
/// AI, not drawing.
///   TALLOW_BENCH_AI_TICK     the runners' Tick Interval (default 0: every frame, the worst case)
///   TALLOW_BENCH_AI_PROFILE  1 records the engine profiler's AI markers and reports their time per frame (recording
///                            costs a little, so compare frame times from runs without it)
extension Bench
{
	int mAiAgents, mAiTargets, mAiObstacles;
	double mNavBakeMs;
	List<GameObject> mAiMovingObstacles = new .() ~ delete _;
	float mAiTime;
	// Engine profiler markers summed over the measured frames (milliseconds).
	double mBehaviourMs, mNavigationMs, mNavigationTickMs, mPathsMs, mAvoidMs;
	int32 mBehaviourId = -1, mNavigationId = -1, mNavigationTickId = -1, mPathsId = -1, mAvoidId = -1;
	delegate void(ProfilerFrame frame) mAiFrame ~ delete _;

	void SpawnAICrowd()
	{
		let width = Math.Max(1, (int)Math.Ceiling(Math.Sqrt((float)mCount)));
		let spacing = 1.7f;
		let side = width * spacing + 20;
		let origin = -side * 0.5f;
		mHalfSize = side * 0.5f;
		Transform.Position = .(0, side * 0.6f, -side * 1.2f);
		Transform.LookAt(.Zero);

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
		Runtime.Assert(surface.Bake() && surface.Data != null, "The AI benchmark could not bake its navigation surface");
		mNavBakeMs = (SDL.SDL_GetTicksNS() - bakeStart) / 1e6;
		mSpawned.Add(navigation);

		Vector3 Place(int i) => .(((i % width) - (width - 1) * 0.5f) * spacing, 0, ((i / width) - (width - 1) * 0.5f) * spacing);

		// Sparse targets, so most agents find one within the tree's 12 m and some do not.
		for (int i = 12; i < mCount; i += 25)
		{
			let target = Scene.CreateGameObject("AI Target");
			target.AddTag("Target");
			target.Transform.Position = Place(i) + Vector3(0.85f, 0, 0.85f);
			mSpawned.Add(target);
			mAiTargets++;
		}

		// Moving obstacles that do not carve: agents steer round them.
		for (int i = 37; i < mCount; i += 100)
		{
			let obstacle = Scene.CreateGameObject("AI Obstacle");
			obstacle.Transform.Position = Place(i) + Vector3(0.85f, 0, 0);
			let shape = obstacle.AddComponent<NavigationObstacle>();
			shape.shape = .Cylinder;
			shape.size = .(1, 1, 1);
			shape.carve = false;
			mSpawned.Add(obstacle);
			mAiMovingObstacles.Add(obstacle);
			mAiObstacles++;
		}

		let text = scope String();
		float tick = 0;
		if (ReadSetting("TALLOW_BENCH_AI_TICK", text) && float.Parse(text) case .Ok(let value))
			tick = value;
		for (int i < mCount)
		{
			let bot = Scene.CreateGameObject("AI Agent");
			bot.Transform.Position = Place(i);
			var agent = bot.AddComponent<NavigationAgent>();
			agent.surface = surface;
			agent.avoidOthers = true;
			var runner = bot.AddComponent<BehaviorTreeRunner>();
			runner.tree.Set("BehaviorTrees/Crowd.tbt");
			runner.tickInterval = tick;
			mSpawned.Add(bot);
			mTrees++;
			mAiAgents++;
		}

		if (!ReadSetting("TALLOW_BENCH_AI_PROFILE", text..Clear()) || text != "1")
			return;
		Profiler.ComponentSamples = false;
		Profiler.Enabled = true;
		mBehaviourId = Profiler.Marker("Behaviour.Trees", .AI);
		mNavigationId = Profiler.Marker("Navigation.Agents", .AI);
		mNavigationTickId = Profiler.Marker("Navigation.Tick", .AI);
		mPathsId = Profiler.Marker("Navigation Paths", .AI);
		mAvoidId = Profiler.Marker("Navigation.Avoid", .AI);
		mAiFrame = new => AIFrame;
		Profiler.OnFrame.Add(mAiFrame);
	}

	void AIFrame(ProfilerFrame frame)
	{
		if (mFrame <= WarmupFrames)
			return;
		for (let sample in frame.samples)
		{
			let ms = sample.duration / 1e6;
			if (sample.marker == mBehaviourId)
				mBehaviourMs += ms;
			else if (sample.marker == mNavigationId)
				mNavigationMs += ms;
			else if (sample.marker == mNavigationTickId)
				mNavigationTickMs += ms;
			else if (sample.marker == mPathsId)
				mPathsMs += ms;
			else if (sample.marker == mAvoidId && sample.thread == 0)
				mAvoidMs += ms;
		}
	}

	/// Moves the obstacles round small circles.
	void MoveAIObstacles(float deltaTime)
	{
		mAiTime += deltaTime;
		for (int i < mAiMovingObstacles.Count)
		{
			let obstacle = mAiMovingObstacles[i];
			let phase = mAiTime * 0.8f + i;
			obstacle.Transform.Position += Vector3(Math.Cos(phase), 0, Math.Sin(phase)) * (1.5f * deltaTime);
		}
	}

	void FinishAI(String line)
	{
		if (mAiFrame != null)
		{
			Profiler.OnFrame.Remove(mAiFrame);
			Profiler.Enabled = false;
		}
		let frames = Math.Max(mFrameTimes.Count, 1);
		line.AppendF("\"ai_agents\": {}, \"ai_targets\": {}, \"ai_obstacles\": {}, \"nav_bake_ms\": {:F1}, ", mAiAgents, mAiTargets, mAiObstacles, mNavBakeMs);
		line.AppendF("\"behaviour_ms\": {:F3}, \"navigation_frame_ms\": {:F3}, \"navigation_tick_ms\": {:F3}, \"paths_ms\": {:F3}, \"avoid_main_ms\": {:F3}, ",
			mBehaviourMs / frames, mNavigationMs / frames, mNavigationTickMs / frames, mPathsMs / frames, mAvoidMs / frames);
	}
}
