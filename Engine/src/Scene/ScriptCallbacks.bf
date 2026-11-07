using System;
using System.Collections;
using System.Reflection;

namespace Tallow;

/// The per-frame callbacks a component class overrides. The scene keeps one list per callback and only runs a
/// component from the lists its class is in (docs/ecs-plan.md, "Frame and tick order"), so a big scene of
/// renderers and colliders costs the update loops nothing.
enum ScriptCallbacks : uint8
{
	None = 0,
	FixedUpdate = 1,
	Update = 2,
	LateUpdate = 4,
	OnFrame = 8,
	OnLocalUpdate = 16,
	All = 31,
}

static class ScriptCallbackIndex
{
	/// Found once per class by reflection: a class overrides a callback when it, or a class between it and
	/// Component, declares an instance method of that name and parameter count. A class whose methods reflection
	/// cannot see is put in every list, so nothing is ever skipped by mistake (it only costs the empty calls).
	public static ScriptCallbacks Of(Type type)
	{
		if (sByType.TryGetValue(type, let known))
			return known;
		ScriptCallbacks found = .None;
		var at = type;
		while (at != null && at != typeof(Component))
		{
			int methods = 0;
			for (let method in at.GetMethods(.Instance | .Public | .NonPublic | .DeclaredOnly))
			{
				methods++;
				let name = method.Name;
				let parameters = method.ParamCount;
				if (parameters == 0)
				{
					if (name == "FixedUpdate")
						found |= .FixedUpdate;
					else if (name == "LateUpdate")
						found |= .LateUpdate;
					else if (name == "OnFrame")
						found |= .OnFrame;
					else if (name == "OnLocalUpdate")
						found |= .OnLocalUpdate;
				}
				else if (parameters == 2 && name == "Update")
					found |= .Update;
			}
			// No methods visible at all: reflection was left out for this class, so assume everything.
			if (methods == 0 && at != typeof(Script))
				found = .All;
			at = at.BaseType;
		}
		sByType[type] = found;
		return found;
	}

	static Dictionary<Type, ScriptCallbacks> sByType = new .() ~ delete _;
}
