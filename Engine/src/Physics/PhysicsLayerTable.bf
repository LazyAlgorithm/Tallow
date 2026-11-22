using System;
using System.Collections;

namespace Tallow;

/// The packed object code both the engine front end and every backend use for a body:
///
///   group (the world-state mask, 0 when all) | motion class (static/moving/debris) | project layer
///
/// Jolt maps it directly to an object layer. A backend with smaller layer groups (Rapier's 16-bit interaction
/// groups, for example) uses the same code with a pair filter or query predicate instead.
static class PhysicsLayerTable
{
	public const uint32 StaticClass = 0;
	public const uint32 MovingClass = 1;
	/// Debris rests on scenery but passes through everything that moves.
	public const uint32 DebrisClass = 2;

	public static uint32 LayersPerClass => (uint32)ProjectConfig.MaxLayers;
	public static uint32 LayersPerGroup => 3 * LayersPerClass;

	public static uint32 ObjectCode(uint32 motionClass, int32 layer, uint32 group = 0)
		=> group * LayersPerGroup + motionClass * LayersPerClass + (uint32)Math.Clamp(layer, 0, ProjectConfig.MaxLayers - 1);

	public static uint32 MotionClass(uint32 code) => (code % LayersPerGroup) / LayersPerClass;
	public static uint32 Layer(uint32 code) => (code % LayersPerGroup) % LayersPerClass;
	public static uint32 Group(uint32 code) => code / LayersPerGroup;
}
