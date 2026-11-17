using System;

namespace Tallow;

/// C# behaviour tree nodes (Managed/Tallow.API/BehaviorNodes.cs): registering each BehaviorNode class as a node kind
/// that BTManagedNode runs, and the Behavior Tree Runner's blackboard for scripts and nodes.
[CSharpExpose]
static class CSharpBehaviorNodes
{
	/// Registers (or updates) a C# node kind. settings: one per setting, separated by 0x1E, each name 0x1F type
	/// (Number, Bool, Text, Vector) 0x1F default.
	[CSharpExpose]
	public static void Register(StringView key, StringView category, StringView title, int32 condition, StringView description,
		StringView className, StringView settings)
	{
		let def = BehaviorLibrary.Add(key, category, title, condition != 0 ? .Condition : .Action, new () => new BTManagedNode());
		def.Describe(description);
		if (def.managedClass == null)
			def.managedClass = new String();
		def.managedClass.Set(className);
		for (let setting in settings.Split('\x1e', .RemoveEmptyEntries))
		{
			var parts = setting.Split('\x1f');
			let name = parts.GetNext().GetValueOrDefault();
			let type = parts.GetNext().GetValueOrDefault();
			let fallback = parts.GetNext().GetValueOrDefault();
			def.With(name, type == "Bool" ? .Bool : type == "Text" ? .Text : type == "Vector" ? .Vector : .Number, fallback);
		}
	}

	static Blackboard Board(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null)
			return null;
		let runner = obj.GetComponent<BehaviorTreeRunner>();
		return runner ? runner.Blackboard : null;
	}

	[CSharpExpose]
	public static bool BlackboardHas(uint64 session, uint64 entity, StringView key) => Board(session, entity)?.Has(key) ?? false;

	[CSharpExpose]
	public static bool BlackboardClear(uint64 session, uint64 entity, StringView key)
	{
		let board = Board(session, entity);
		board?.Clear(key);
		return board != null;
	}

	[CSharpExpose]
	public static float BlackboardNumber(uint64 session, uint64 entity, StringView key, float fallback) =>
		Board(session, entity)?.GetNumber(key, fallback) ?? fallback;

	[CSharpExpose]
	public static bool BlackboardSetNumber(uint64 session, uint64 entity, StringView key, float value)
	{
		let board = Board(session, entity);
		board?.SetNumber(key, value);
		return board != null;
	}

	[CSharpExpose]
	public static bool BlackboardSetFlag(uint64 session, uint64 entity, StringView key, bool value)
	{
		let board = Board(session, entity);
		board?.SetFlag(key, value);
		return board != null;
	}

	[CSharpExpose]
	public static bool BlackboardSetVector(uint64 session, uint64 entity, StringView key, Vector3 value)
	{
		let board = Board(session, entity);
		board?.SetVector(key, value);
		return board != null;
	}

	/// A stored vector, or where a stored object is now, into values (x, y, z); false when there is neither.
	[CSharpExpose]
	public static bool BlackboardPosition(uint64 session, uint64 entity, StringView key, Span<float> values)
	{
		let board = Board(session, entity);
		let scene = CSharpRuntime.PhysicsScene(session);
		if (board == null || scene == null || values.Length < 3)
			return false;
		Vector3 position;
		if (!board.TryGetPosition(key, scene, out position))
			return false;
		values[0] = position.x;
		values[1] = position.y;
		values[2] = position.z;
		return true;
	}

	/// A stored object's id, 0 when there is none or it has gone.
	[CSharpExpose]
	public static uint64 BlackboardObject(uint64 session, uint64 entity, StringView key)
	{
		let board = Board(session, entity);
		let scene = CSharpRuntime.PhysicsScene(session);
		return board != null && scene != null ? (board.GetObject(key, scene)?.Id ?? 0) : 0;
	}

	[CSharpExpose]
	public static bool BlackboardSetObject(uint64 session, uint64 entity, StringView key, uint64 objectId)
	{
		let board = Board(session, entity);
		if (board == null)
			return false;
		let target = objectId != 0 ? CSharpRuntime.PhysicsObject(session, objectId) : null;
		if (target != null)
			board.SetObject(key, target);
		else
			board.Clear(key);
		return true;
	}
}
