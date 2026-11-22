using System;
using System.Collections;

namespace Tallow;

/// One rule every system can add: given a component type and its scene, may the type be added? Physics uses this for
/// backend capabilities; another modular system can add its own rule without touching the engine's add paths.
static class ComponentAvailability
{
	public delegate bool Rule(Type type, Scene scene, out StringView reason);

	static List<Rule> sRules = new .() ~ delete _;

	/// Set while a scene, prefab or map is being read. Loading keeps every component (the data is valid); the
	/// component is merely inert if the selected backend cannot run it.
	public static bool Loading;

	public static void AddRule(Rule rule)
	{
		if (rule != null)
			sRules.Add(rule);
	}

	/// Whether a component of this type may be added to an object in this scene. Reason names the missing feature
	/// when it may not. Scene may be null while the editor is still opening a project.
	public static bool CanAdd(Type type, Scene scene, out StringView reason)
	{
		reason = default;
		if (Loading)
			return true;
		for (let rule in sRules)
		{
			if (!rule(type, scene, out reason))
				return false;
		}
		return PhysicsComponentRules.CanAdd(type, scene, out reason);
	}

	/// The same for a component that already exists (a scene loaded from a backend that had the feature).
	public static bool IsAvailable(Component component, out StringView reason)
	{
		if (component == null)
		{
			reason = default;
			return true;
		}
		let scene = component.GameObject?.Scene;
		if (!CanAdd(component.GetType(), scene, out reason))
			return false;
		let features = PhysicsComponentRules.FeaturesFor(scene);
		return PhysicsComponentRules.Validate(component, features, out reason);
	}
}
