using System;
using Tallow;

namespace EcsBench;

/// The benchmark's shared rules (docs/ecs-plan.md, Phase 1): cubes moving through a box, bouncing off its walls
/// and spinning. The GameObject version (Mover) and the ECS version (MoveSystem) run exactly this.
static class Workload
{
	public const float CubeScale = 0.5f;

	public const float DampAbove = 0.5f;
	public const float Damping = 0.2f;

	/// Half the inside width of the physics mode's box (CSharpBench's Workload, line for line).
	public static float PhysicsHalfSize(int count) => Math.Max(3, Math.Sqrt(count / 10f) * 0.6f);

	public static void PhysicsBox(float half, out Vector3 position, out Vector3 size)
	{
		position = .(0, -0.5f, 0);
		size = .(half * 2 + 2, 1, half * 2 + 2);
	}

	/// Wall 0-3: +X, -X, +Z, -Z, tall enough to hold every layer.
	public static void PhysicsWall(float half, int side, out Vector3 position, out Vector3 size)
	{
		let height = 40f;
		let offset = half + 0.5f;
		switch (side)
		{
		case 0: position = .(offset, height / 2, 0);
		case 1: position = .(-offset, height / 2, 0);
		case 2: position = .(0, height / 2, offset);
		default: position = .(0, height / 2, -offset);
		}
		size = side < 2 ? .(1, height, half * 2 + 2) : .(half * 2 + 2, height, 1);
	}

	/// Balls (radius 0.5) in a grid 1.1 m apart, layer above layer, with a small offset per layer.
	public static Vector3 PhysicsStart(int index, float half)
	{
		let side = Math.Max(1, (int)((half * 2 - 1) / 1.1f));
		let x = index % side;
		let z = index / side % side;
		let y = index / (side * side);
		let jitter = (y % 2) * 0.3f;
		return .(-half + 0.55f + x * 1.1f + jitter, 1 + y * 1.1f, -half + 0.55f + z * 1.1f + jitter);
	}

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

	/// The query modes' field (B14): a 102 m floor with 400 boxes of five heights on a 5 m grid.
	public const int QueryObstacles = 400;
	public const float QueryMaxDistance = 40;
	public const float QueryRadius = 0.3f;

	public static void QueryObstacle(int index, out Vector3 position, out Vector3 size)
	{
		let height = 1f + index % 5;
		position = .(-47.5f + (index % 20) * 5, height / 2, -47.5f + (index / 20) * 5);
		size = .(2, height, 2);
	}

	/// Query i: from 12 m up somewhere over the field, down at a slant (not normalised: both languages pass the same
	/// vector to the same physics call).
	public static void QueryRay(int index, out Vector3 origin, out Vector3 direction)
	{
		var seed = (uint32)index * 2654435761U + 777;
		float Next()
		{
			seed ^= seed << 13;
			seed ^= seed >> 17;
			seed ^= seed << 5;
			return (seed & 0xFFFFFF) / (float)0xFFFFFF * 2 - 1;
		}
		origin = .(Next() * 48, 12, Next() * 48);
		direction = .(Next() * 0.5f, -1, Next() * 0.5f);
	}

	/// The character mode: walkers 2 m apart on a floor with room round them.
	public static float WalkerHalfSize(int count) => Math.Ceiling(Math.Sqrt((float)count)) + 4;

	public static Vector3 WalkerStart(int index, int count)
	{
		let side = (int)Math.Ceiling(Math.Sqrt((float)count));
		return .(-side + 1 + (index % side) * 2, 1.2f, -side + 1 + (index / side) * 2);
	}

	/// The tick at which each walker's position goes into the checksum.
	public const int WalkerCheckTick = 300;

	/// Walking in a slowly turning direction, each walker its own phase.
	public static Vector3 WalkerVelocity(int index, int tick)
	{
		let angle = index * 0.7f + tick * 0.05f;
		return .(Math.Cos(angle) * 2, 0, Math.Sin(angle) * 2);
	}
}
