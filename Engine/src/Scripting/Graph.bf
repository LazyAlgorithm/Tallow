using System;

namespace Tallow;

/// Marks a public static method as a node for the visual scripting graph editor.
/// Parameters become inputs and the return value becomes the output. Supported types are
/// float, int32, bool, Vector3 and String. An optional first Component parameter
/// receives the graph component itself and does not create a pin. A void method is an action node with flow pins.
///
///   static class MyNodes
///   {
///       [GraphNode] public static float Pulse(float time, float speed) => Math.Sin(time * speed) * 0.5f + 0.5f;
///   }
[AttributeUsage(.Method, .ReflectAttribute | .AlwaysIncludeTarget, ReflectUser = .All)]
struct GraphNodeAttribute : Attribute
{
}

/// Put on a class that contains [GraphNode] methods so its methods stay visible to the editor.
[AttributeUsage(.Class, .ReflectAttribute | .AlwaysIncludeTarget, ReflectUser = .All, AlwaysIncludeUser = .IncludeAllMethods | .AssumeInstantiated)]
struct GraphLibraryAttribute : Attribute
{
}

/// A few ready-made code nodes; they also show how to write your own.
[GraphLibrary]
static class GraphNodes
{
	[GraphNode] public static float Wave(float time, float speed, float amplitude) => Math.Sin(time * speed) * amplitude;
	[GraphNode] public static float Distance(Vector3 a, Vector3 b) => (a - b).Length;
	[GraphNode] public static Vector3 Scale(Vector3 value, float factor) => value * factor;
	[GraphNode] public static float Clamp(float value, float min, float max) => Mathf.Clamp(value, min, max);
	[GraphNode] public static void Print(String text) => Log.Info(text);
	[GraphNode] public static void PrintNumber(float value) => Log.Info(scope $"{value}");
}

/// What code compiled from visual scripts calls for the nodes that take any kind of value (Print, To String, Is Valid).
static class GraphRuntime
{
	/// Makes a character's capsule this tall, keeping it as standingHeight capsule's feet are (crouching), when that
	/// is not already its height. On the ground the head comes down; in the air the feet come up instead and the head
	/// stays where it is (lifting the character), as in Halo, so crouching mid-jump clears a ledge the feet would
	/// have caught on. Standing up is refused while something is in the way, so the character stays crouched.
	public static void SetCharacterHeight(GameObject target, float height, float standingHeight)
	{
		if (target == null || !target.HasComponent<CharacterController>())
			return;
		let controller = target.GetComponent<CharacterController>();
		let shrink = controller.height - height;
		if (Math.Abs(shrink) < 0.001f)
			return;
		let airborne = controller.HasCharacter && !controller.IsGrounded;
		let velocity = controller.Velocity;
		let airTime = controller.AirTime;
		if (!controller.SetCapsule(controller.radius, height, .(0, (height - standingHeight) / 2, 0)))
			return;
		if (airborne && shrink > 0)
		{
			// The capsule shrank from the top; moving it up by as much puts the top back and lifts the feet.
			controller.Teleport(target.Transform.Position + Vector3(0, shrink, 0), velocity, airTime);
			sLiftObject = target;
			sLiftFrame = Time.FrameCount;
			sLift = shrink;
		}
	}

	static GameObject sLiftObject;
	static int64 sLiftFrame = -1;
	static float sLift;

	/// How far Set Character Height lifted this character this frame to keep its head still while crouching in the
	/// air (0 otherwise). Take it off a smoothed camera height so the view does not jump.
	public static float CrouchLift(GameObject target)
	{
		return target != null && target == sLiftObject && sLiftFrame == Time.FrameCount ? sLift : 0;
	}

	/// A character's capsule height now (0 without a Character Controller).
	public static float CharacterHeight(GameObject target)
	{
		if (target == null || !target.HasComponent<CharacterController>())
			return 0;
		return target.GetComponent<CharacterController>().height;
	}

	/// Whether an object reference is set (and, for a component handle, its object still has that component).
	public static bool IsValid(Object value) => value != null;

	public static bool IsValid<T>(T handle) where T : struct, IComponentHandle
	{
		// A handle starts with its object.
		var copy = handle;
		let gameObject = *(GameObject*)(void*)&copy;
		return gameObject != null && gameObject.Scene != null && gameObject.HasComponent<T>();
	}

	public static void Text(float value, String text) => text.AppendF("{}", value);
	public static void Text(int value, String text) => text.AppendF("{}", value);
	public static void Text(int32 value, String text) => text.AppendF("{}", value);
	public static void Text(bool value, String text) => text.Append(value ? "true" : "false");
	public static void Text(Vector2 value, String text) => text.AppendF("X={:0.###} Y={:0.###}", value.x, value.y);
	public static void Text(Vector3 value, String text) => text.AppendF("X={:0.###} Y={:0.###} Z={:0.###}", value.x, value.y, value.z);
	public static void Text(Color value, String text) => text.AppendF("R={:0.###} G={:0.###} B={:0.###} A={:0.###}", value.r, value.g, value.b, value.a);

	/// A rotation as its Euler angles in degrees.
	public static void Text(Quaternion value, String text)
	{
		let euler = value.EulerAngles;
		text.AppendF("X={:0.#} Y={:0.#} Z={:0.#}", euler.x, euler.y, euler.z);
	}

	/// An object by name; a component as its type and its object's name.
	public static void Text(Object value, String text)
	{
		if (value == null)
			text.Append("None");
		else if (let gameObject = value as GameObject)
			text.Append(gameObject.Name);
		else if (let component = value as Component)
			text.AppendF("{} ({})", component.GetType().GetName(.. scope .()), component.GameObject?.Name ?? "");
		else if (let transform = value as Transform)
			text.AppendF("Transform ({})", transform.GameObject?.Name ?? "");
		else
			value.ToString(text);
	}

	public static void Text<T>(T handle, String text) where T : struct, IComponentHandle
	{
		var copy = handle;
		let gameObject = *(GameObject*)(void*)&copy;
		text.AppendF("{} ({})", typeof(T).GetName(.. scope .()), gameObject?.Name ?? "None");
	}
}
