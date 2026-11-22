using System;
using System.Collections;

namespace Tallow;

/// What kind of engine system a module provides.
[Reflect(.All)]
enum ModuleKind : uint8
{
	Physics3D,
	/// Reserved for the 2D physics front end.
	Physics2D,
	Audio,
	NetworkTransport,
	Navigation,
	Renderer,
	Platform
}

/// Metadata every swappable engine system shares. The typed registry for a system (PhysicsBackends, for example)
/// is what code calls; this is for discovery, the editor's Modules page and diagnostics.
abstract class EngineModule
{
	/// Stable id written in project files ("Jolt", "Rapier3D", "ENet"). Do not rename it once projects use it.
	public abstract StringView Id { get; }
	public abstract StringView DisplayName { get; }
	public abstract ModuleKind Kind { get; }
	/// The integration's own version, for diagnostics.
	public abstract int32 IntegrationVersion { get; }
	/// The library version this integration was built against ("vendored Jolt", "Rapier 0.36.1+c.0").
	public abstract StringView LibraryVersion { get; }
	/// Whether this build contains the module and can use it on this platform.
	public abstract bool Available { get; }
	/// Per-kind feature bits. Physics interprets them as PhysicsFeatures.
	public abstract uint64 Capabilities { get; }

	/// Checks that the module really works. Development builds and CI call it; a game start does not.
	public virtual bool Probe(out String reason)
	{
		reason = default;
		return true;
	}
}

/// A thin facade over the typed registries, for the editor's Modules page and headless diagnostics.
static class EngineModules
{
	static List<EngineModule> sModules = new .() ~ delete _;

	public static List<EngineModule> All => sModules;

	public static void Register(EngineModule module)
	{
		if (module == null)
			return;
		for (let existing in sModules)
		{
			if (existing.Kind == module.Kind && existing.Id == module.Id)
				return;
		}
		sModules.Add(module);
	}

	public static EngineModule Find(ModuleKind kind, StringView id)
	{
		for (let module in sModules)
		{
			if (module.Kind == kind && module.Id == id)
				return module;
		}
		return null;
	}

	public static void ForKind(ModuleKind kind, List<EngineModule> into)
	{
		into.Clear();
		for (let module in sModules)
		{
			if (module.Kind == kind)
				into.Add(module);
		}
	}
}
