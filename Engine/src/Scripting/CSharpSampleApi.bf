using System;

namespace Tallow;

/// Immediate-mode GUI drawing for C# OnGUI (Tallow.API's GUI class adds Color overloads). Colors are RGBA 0..1.
[CSharpExpose]
static class CSharpGUI
{
	static Color ToColor(Vector4 color) => .(color.x, color.y, color.z, color.w);

	[CSharpExpose]
	public static void Label(float x, float y, StringView text, Vector4 color) => GUI.Label(x, y, text, ToColor(color));

	[CSharpExpose]
	public static void Box(float x, float y, float width, float height, Vector4 color) => GUI.Box(x, y, width, height, ToColor(color));

	[CSharpExpose]
	public static void Bar(float x, float y, float width, float height, float fraction, Vector4 color) =>
		GUI.Bar(x, y, width, height, fraction, ToColor(color));

	/// A checkbox; returns the value after this frame's click.
	[CSharpExpose]
	public static bool Toggle(float x, float y, StringView label, bool value)
	{
		var result = value;
		GUI.Toggle(x, y, label, ref result);
		return result;
	}

	/// A slider; returns the value after this frame's drag.
	[CSharpExpose]
	public static float Slider(float x, float y, float width, StringView label, float value, float min, float max)
	{
		var result = value;
		GUI.Slider(x, y, width, label, ref result, min, max);
		return result;
	}

	[CSharpExpose]
	public static bool MouseOverControl() => GUI.MouseOverControl;
}

/// Voxel editing and the character motor for C# scripts. A missing object or component does nothing.
[CSharpExpose]
static class CSharpWorld
{
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// The player's folder for this game (GamePaths.PlayerData), ending in a slash.
	[CSharpExpose]
	public static int32 CopyPlayerDataPath(Span<uint8> buffer) => Copy(GamePaths.PlayerData, buffer);

	/// Adds a scene file's contents to the playing scene under one new object (SceneManager.LoadAdditive); 0 when
	/// the file cannot be read.
	[CSharpExpose]
	public static uint64 LoadAdditive(uint64 session, StringView path, bool applyEnvironment)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		if (scene == null)
			return 0;
		let group = SceneManager.LoadAdditive(scene, path, applyEnvironment);
		return group != null ? group.Id : 0;
	}

	/// Removes what LoadAdditive added (that object and everything under it), at once.
	[CSharpExpose]
	public static bool UnloadAdditive(uint64 session, uint64 group)
	{
		let gameObject = CSharpRuntime.PhysicsObject(session, group);
		if (gameObject == null)
			return false;
		SceneManager.Unload(gameObject);
		return true;
	}

	/// Cuts a sphere out of an object's VoxelObject (shared in a network session). False without one.
	[CSharpExpose]
	public static bool CarveVoxels(uint64 session, uint64 entity, Vector3 point, float radius)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || !obj.HasComponent<VoxelObject>() || !radius.IsFinite || radius <= 0 ||
			!point.x.IsFinite || !point.y.IsFinite || !point.z.IsFinite)
			return false;
		return obj.GetComponent<VoxelObject>().Carve(point, radius);
	}

	[CSharpExpose]
	public static bool HasVoxelObject(uint64 session, uint64 entity) =>
		CSharpRuntime.PhysicsObject(session, entity)?.HasComponent<VoxelObject>() ?? false;

	/// The object with the scene's first VoxelTerrain, 0 without one.
	[CSharpExpose]
	public static uint64 FindVoxelTerrain(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		let terrain = scene?.FindComponent<VoxelTerrain>();
		return (terrain != null && !terrain.GameObject.IsDestroyed) ? (uint64)terrain.GameObject.Id : 0;
	}

	/// Raises (amount > 0) or digs (amount < 0) the terrain in a sphere.
	[CSharpExpose]
	public static bool ModifyTerrain(uint64 session, uint64 entity, Vector3 center, float radius, float amount)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		let terrain = obj?.GetComponent<VoxelTerrain>();
		if (terrain == null || !radius.IsFinite || radius <= 0 || !amount.IsFinite ||
			!center.x.IsFinite || !center.y.IsFinite || !center.z.IsFinite)
			return false;
		terrain.ModifySphere(center, radius, amount);
		return true;
	}

	/// The terrain's chunks made so far, and those still being made (streamed in).
	[CSharpExpose]
	public static int32 TerrainChunkCount(uint64 session, uint64 entity) =>
		CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>()?.ChunkCount ?? 0;

	[CSharpExpose]
	public static int32 TerrainPendingChunks(uint64 session, uint64 entity) =>
		CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<VoxelTerrain>()?.PendingChunks ?? 0;

	[CSharpExpose]
	public static bool HasCharacterMotor(uint64 session, uint64 entity) => CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<CharacterMotor>() != null;

	/// The motor's look direction in degrees (0 without one).
	[CSharpExpose]
	public static float MotorYaw(uint64 session, uint64 entity) => CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<CharacterMotor>()?.Yaw ?? 0;

	[CSharpExpose]
	public static float MotorPitch(uint64 session, uint64 entity) => CSharpRuntime.PhysicsObject(session, entity)?.GetComponent<CharacterMotor>()?.Pitch ?? 0;

	/// The network session's tick (0 offline).
	[CSharpExpose]
	public static int64 NetworkTick(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		return (scene?.Network != null && scene.Network.Mode != .Offline) ? (int64)scene.Network.Tick : 0;
	}
}

/// NavigationAgent for C# scripts. A missing object or agent does nothing and reads as zero.
[CSharpExpose]
static class CSharpNavigation
{
	static bool Find(uint64 session, uint64 entity, out NavigationAgent agent)
	{
		agent = default;
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null || !obj.HasComponent<NavigationAgent>())
			return false;
		agent = obj.GetComponent<NavigationAgent>();
		return true;
	}

	[CSharpExpose]
	public static bool HasAgent(uint64 session, uint64 entity) => Find(session, entity, ?);

	[CSharpExpose]
	public static void SetDestination(uint64 session, uint64 entity, Vector3 point, float speed, float stoppingDistance)
	{
		if (point.x.IsFinite && point.y.IsFinite && point.z.IsFinite && speed.IsFinite && stoppingDistance.IsFinite &&
			Find(session, entity, let agent))
			agent.SetDestination(point, speed, stoppingDistance);
	}

	[CSharpExpose]
	public static void StopMovement(uint64 session, uint64 entity)
	{
		if (Find(session, entity, let agent))
			agent.StopMovement();
	}

	[CSharpExpose]
	public static bool PathPending(uint64 session, uint64 entity) => Find(session, entity, let agent) && agent.PathPending;

	[CSharpExpose]
	public static bool PathFailed(uint64 session, uint64 entity) => Find(session, entity, let agent) && agent.PathFailed;

	[CSharpExpose]
	public static bool HasArrived(uint64 session, uint64 entity) => Find(session, entity, let agent) && agent.HasArrived;

	[CSharpExpose]
	public static int32 PathCount(uint64 session, uint64 entity) =>
		(Find(session, entity, let agent) && agent.Path != null) ? (int32)agent.Path.Count : 0;

	[CSharpExpose]
	public static float RemainingDistance(uint64 session, uint64 entity) => Find(session, entity, let agent) ? agent.RemainingDistance : 0;

	static NavigationData Surface(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		let surface = obj?.GetComponent<NavigationSurface>();
		return surface?.Data;
	}

	static bool Finite(Vector3 v) => v.x.IsFinite && v.y.IsFinite && v.z.IsFinite;

	[CSharpExpose]
	public static bool HasSurface(uint64 session, uint64 entity) => Surface(session, entity) != null;

	/// The object with the scene's first Navigation Surface, 0 without one.
	[CSharpExpose]
	public static uint64 FindSurface(uint64 session)
	{
		let scene = CSharpRuntime.PhysicsScene(session);
		let surface = scene?.FindComponent<NavigationSurface>();
		return (surface != null && !surface.GameObject.IsDestroyed) ? (uint64)surface.GameObject.Id : 0;
	}

	/// 0 SamplePosition(a, distance), 1 RandomPoint(a, distance, seed), 2 Raycast(a to b): xyz the point found
	/// (Raycast: where it is blocked), w 1 when SamplePosition/RandomPoint found one or the Raycast was clear.
	[CSharpExpose]
	public static Vector4 SurfaceQuery(uint64 session, uint64 entity, int32 kind, Vector3 a, Vector3 b, float distance, int32 seed)
	{
		let data = Surface(session, entity);
		if (data == null || !Finite(a) || !Finite(b) || !distance.IsFinite)
			return .(0, 0, 0, 0);
		Vector3 found = default;
		bool ok = false;
		switch (kind)
		{
		case 0: ok = data.SamplePosition(a, distance, out found);
		case 1:
			let random = scope Random(seed);
			ok = data.RandomPoint(a, distance, random, out found);
		case 2: ok = data.Raycast(a, b, out found);
		default:
		}
		return .(found.x, found.y, found.z, ok ? 1 : 0);
	}

	/// Rebuilds the part of the surface inside the box after geometry changed there.
	[CSharpExpose]
	public static bool SurfaceRebuild(uint64 session, uint64 entity, Vector3 min, Vector3 max)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		let surface = obj?.GetComponent<NavigationSurface>();
		if (surface == null || !Finite(min) || !Finite(max))
			return false;
		return surface.Rebuild(.(min, max));
	}
}

/// The game's command line for C# scripts (test switches such as --view 3).
[CSharpExpose]
static class CSharpCommandLine
{
	[CSharpExpose]
	public static bool HasArg(StringView name) => Application.Instance != null && Application.Instance.HasArg(name);

	/// The value after a switch (UTF-8 into buffer); returns its full length, -1 when the switch is not there.
	[CSharpExpose]
	public static int32 CopyArg(StringView name, Span<uint8> buffer)
	{
		let value = scope String();
		if (Application.Instance == null || !Application.Instance.GetArg(name, value))
			return -1;
		let count = Math.Min(value.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)value[i];
		return (int32)value.Length;
	}
}
