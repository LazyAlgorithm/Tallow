using System;
using Tallow;

namespace EcsBench;

/// The benchmark's shared rules (docs/ecs-plan.md, Phase 1): cubes moving through a box, bouncing off its walls
/// and spinning. The GameObject version (Mover) and the ECS version (MoveSystem) run exactly this.
static class Workload
{
	public const float CubeScale = 0.5f;

	/// Half the box's width for count cubes, so the box is about as crowded at every count.
	public static float HalfSize(int count) => Math.Max(4, Math.Pow((float)count, 1 / 3.0f) * 1.5f);

	/// Moves position by velocity, reflecting the velocity off the box's walls.
	[Inline]
	public static void Step(ref Vector3 position, ref Vector3 velocity, float halfSize, float deltaTime)
	{
		position += velocity * deltaTime;
		if (position.x > halfSize || position.x < -halfSize)
		{
			velocity.x = -velocity.x;
			position.x = Math.Clamp(position.x, -halfSize, halfSize);
		}
		if (position.y > halfSize || position.y < -halfSize)
		{
			velocity.y = -velocity.y;
			position.y = Math.Clamp(position.y, -halfSize, halfSize);
		}
		if (position.z > halfSize || position.z < -halfSize)
		{
			velocity.z = -velocity.z;
			position.z = Math.Clamp(position.z, -halfSize, halfSize);
		}
	}

	/// A starting place, velocity and spin for cube index, the same in both versions.
	public static void Start(int index, float halfSize, out Vector3 position, out Vector3 velocity, out Vector3 spin)
	{
		var seed = (uint32)index * 2654435761U + 12345;
		float Next()
		{
			seed ^= seed << 13;
			seed ^= seed >> 17;
			seed ^= seed << 5;
			return (seed & 0xFFFFFF) / (float)0xFFFFFF * 2 - 1;
		}
		position = .(Next() * halfSize, Next() * halfSize, Next() * halfSize);
		velocity = .(Next() * 4, Next() * 4, Next() * 4);
		spin = .(Next() * 90, Next() * 90, Next() * 90);
	}
}
