using System;
using System.Collections;

namespace Tallow;

/// The Profiler's markers for components (docs/profiler.md): one per type and method, "Animator.Update()",
/// "PlayerController.FixedUpdate()", so the Profiler shows each script's time with its call count. A component keeps
/// its type's slot, so finding the marker is a list lookup.
static class ProfilerComponents
{
	public enum Method
	{
		FixedUpdate,
		Update,
		LateUpdate,
		OnFrame,
		OnLocalUpdate,
	}

	static StringView[5] sMethodNames = .(".FixedUpdate()", ".Update()", ".LateUpdate()", ".OnFrame()", ".OnLocalUpdate()");
	static Dictionary<Type, int32> sSlots = new .() ~ delete _;
	static List<int32[5]> sMarkers = new .() ~ delete _;

	/// Whether components are being timed one by one now.
	public static bool Timing => Profiler.Enabled && Profiler.ComponentSamples;

	public static int32 MarkerFor(Component component, Method method)
	{
		var slot = component.[Friend]mProfileSlot;
		if (slot < 0)
		{
			let type = component.GetType();
			if (!sSlots.TryGetValue(type, out slot))
			{
				let name = scope String();
				type.GetName(name);
				let category = CategoryOf(type, name);
				int32[5] markers = default;
				for (int i < markers.Count)
					markers[i] = Profiler.Marker(scope String()..AppendF("{}{}", name, sMethodNames[i]), category);
				slot = (int32)sMarkers.Count;
				sMarkers.Add(markers);
				sSlots[type] = slot;
			}
			component.[Friend]mProfileSlot = slot;
		}
		return sMarkers[slot][(int)method];
	}

	/// Which module a component's time is in: the engine's own by what they do, everything else (game code) Scripts.
	static ProfilerCategory CategoryOf(Type type, StringView name)
	{
		let full = scope String();
		type.GetFullName(full);
		if (!full.StartsWith("Tallow.") || full.StartsWith("Tallow.Editor."))
			return .Scripts;
		bool Has(StringView part) => name.Contains(part);
		if (Has("Animat") || Has("Skinned") || Has("IK") || Has("Bone") || Has("Viewmodel"))
			return .Animation;
		if (Has("Audio") || Has("Voice"))
			return .Audio;
		if (Has("Network") || Has("Net") || Has("CharacterMotor"))
			return .Networking;
		if (Has("Navigation") || Has("Behavior") || Has("AI"))
			return .AI;
		if (Has("UI") || Has("Canvas") || Has("Text"))
			return .UI;
		if (Has("Particle"))
			return .Particles;
		if (Has("Rigidbody") || Has("Collider") || Has("Joint") || Has("Character") || Has("Physics"))
			return .Physics;
		if (Has("Renderer") || Has("Camera") || Has("Light") || Has("Decal") || Has("Foliage") || Has("LOD") || Has("Reflection") || Has("Terrain") || Has("Voxel"))
			return .Rendering;
		return .Other;
	}
}
