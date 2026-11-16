using System;
using System.Collections;

namespace Tallow;

/// A C# EcsSystem<T> (Managed/Tallow.API/EcsSystems.cs), run by NetworkManager like a Beef NativeSystem<T>: on the
/// server (or offline) over every bare entity with its data that no client owns, and one entity at a time for what a
/// client owns (on the server with that client's controls, on the client as prediction, and again on a replay). Its
/// game assembly describes it when it loads (Ecs.DescribeSystem); unloading the assembly removes it.
class CSharpEcsSystem : NativeSystemBase
{
	public int32 index;
	public uint64 schemaId;

	/// Names start with this, so that unloading removes only C# systems.
	const String Prefix = "CSharp:";

	public static void Add(int32 index, StringView name, int32 order, uint64 schemaId)
	{
		let full = scope String()..AppendF("{}{}", Prefix, name);
		NetworkManager.RemoveNativeSystem(full);
		let system = new CSharpEcsSystem();
		system.name.Set(full);
		system.order = order;
		system.index = index;
		system.schemaId = schemaId;
		NetworkManager.[Friend]AddNativeSystemEntry(system);
	}

	/// The game assembly is going: its systems with it.
	public static void RemoveAll()
	{
		NetworkManager.[Friend]RemoveNativeSystemsWhere(scope (system) => system is CSharpEcsSystem);
	}

	void Run(uint64 entity, TickInput input, float deltaTime)
	{
		if (!CSharpRuntime.Ready)
			return;
		CSharpRuntime.RunSystem(index, CSharpRuntime.Session, entity, input, deltaTime);
	}

	public override void RunOne(World world, Entity entity, TickInput input, float deltaTime) =>
		Run(entity.id, input, deltaTime);

	public override void RunServer(World world, NetworkManager network, TickInput input, float deltaTime) =>
		Run(0, input, deltaTime);
}
