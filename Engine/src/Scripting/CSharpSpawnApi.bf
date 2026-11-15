using System;

namespace Tallow;

/// Spawn points, teams, layers and world states for C# scripts (Tallow.API's SpawnPoints, Layers, WorldStates and
/// the Scene/GameObject members over them). A missing scene or object does nothing and reads as empty.
[CSharpExpose]
static class CSharpSpawning
{
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	static uint64 PointId(SpawnPoint point) => point.IsValid && !point.GameObject.IsDestroyed ? (uint64)point.GameObject.Id : 0;

	[CSharpExpose]
	public static float GetStartWindow() => SpawnPoints.StartWindow;

	[CSharpExpose]
	public static void SetStartWindow(float seconds)
	{
		if (seconds.IsFinite)
			SpawnPoints.StartWindow = Math.Max(seconds, 0);
	}

	/// 0 BeginStart, 1 EndStart.
	[CSharpExpose]
	public static void StartPhase(uint64 session, int32 action)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null)
			return;
		if (action == 0)
			SpawnPoints.BeginStart(scene);
		else if (action == 1)
			SpawnPoints.EndStart(scene);
	}

	[CSharpExpose]
	public static bool IsStartPhase(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		return scene != null && SpawnPoints.IsStartPhase(scene);
	}

	[CSharpExpose]
	public static int32 Count(uint64 session, int32 team)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		return scene != null ? (int32)SpawnPoints.Count(scene, team) : 0;
	}

	/// The object of the next (or a random) point for the team, 0 when the scene has none. Asking uses it.
	[CSharpExpose]
	public static uint64 Pick(uint64 session, int32 team, bool random)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null)
			return 0;
		return PointId(random ? SpawnPoints.Random(scene, team) : SpawnPoints.Next(scene, team));
	}

	/// Moves an object to a point for the team, facing its way; the point's object, or 0 when there were none.
	[CSharpExpose]
	public static uint64 Place(uint64 session, uint64 entity, int32 team, bool random)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		return obj != null ? PointId(SpawnPoints.Place(obj, team, random)) : 0;
	}

	/// The team of the object's Network Identity (set by the server), 0 without one or without teams.
	[CSharpExpose]
	public static int32 Team(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || !obj.HasComponent<NetworkIdentity>())
			return 0;
		return obj.GetComponent<NetworkIdentity>().team;
	}

	[CSharpExpose]
	public static int32 LayerNamed(StringView name) => ProjectConfig.LayerNamed(name);

	[CSharpExpose]
	public static int32 CopyLayerName(int32 layer, Span<uint8> buffer) => Copy(ProjectConfig.LayerName(layer), buffer);

	[CSharpExpose]
	public static int32 WorldStateNamed(StringView name) => ProjectConfig.WorldStateNamed(name);

	[CSharpExpose]
	public static int32 CopyWorldStateName(int32 state, Span<uint8> buffer)
	{
		let states = ProjectConfig.WorldStates;
		return (state >= 0 && state < states.Count) ? Copy(states[state], buffer) : -1;
	}

	[CSharpExpose]
	public static int32 GetWorldState(uint64 session) => CSharpRuntime.PhysicsScene(session)?.WorldState ?? 0;

	[CSharpExpose]
	public static void SetWorldState(uint64 session, int32 state)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene != null && state >= 0 && state < ProjectConfig.MaxWorldStates)
			scene.WorldState = state;
	}
}
