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
