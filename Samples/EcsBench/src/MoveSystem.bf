using System;
using Tallow;

namespace EcsBench;

/// The ECS version's data: plain structs in Flecs tables.
[Component]
struct Pose
{
	public Vector3 position;
	public Quaternion rotation;
}

[Component]
struct Motion
{
	public Vector3 velocity;
	public Vector3 spin;
}

/// The matrix the renderer draws the cube with, written by MoveSystem.
[Component]
struct RenderMatrix
{
	public Matrix4 world;
}

/// Moves and spins every cube, then writes its matrix: one loop over packed columns per table.
static class MoveSystem
{
	public static void Run(Chunk chunk, float halfSize, float deltaTime)
	{
		let poses = chunk.Write<Pose>();
		let motions = chunk.Write<Motion>();
		let matrices = chunk.Write<RenderMatrix>();
		let scale = Vector3(Workload.CubeScale, Workload.CubeScale, Workload.CubeScale);
		for (int i < chunk.Count)
		{
			ref Pose pose = ref poses[i];
			ref Motion motion = ref motions[i];
			Workload.Step(ref pose.position, ref motion.velocity, halfSize, deltaTime);
			pose.rotation = (pose.rotation * Quaternion.Euler(motion.spin * deltaTime)).Normalized;
			matrices[i].world = Matrix4.TRS(pose.position, pose.rotation, scale);
		}
	}
}
