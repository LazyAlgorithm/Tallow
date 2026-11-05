using System;
using System.Collections;

namespace Tallow;

/// Bakes a Navigation Surface's grid from the scene's static geometry, in a physics world of its own so that
/// nothing in the game runs while it does.
static class NavigationBaker
{
	static bool IsStaticGeometry(GameObject obj)
	{
		var transform = obj.Transform;
		while (transform != null)
		{
			let go = transform.GameObject;
			if (go.HasComponent<Rigidbody>() || go.HasComponent<NavigationAgent>() || go.GetComponent<NavigationObstacle>() != null) return false;
			transform = transform.Parent;
		}
		return true;
	}

	/// A private query world avoids entering play mode or invoking gameplay scripts.
	public static void BuildGeometry(Scene scene, PhysicsWorld world, bool includeRenderMeshes = true, uint32 worlds = uint32.MaxValue) => BuildGeometry(scene, world, includeRenderMeshes, false, default, worlds);
	static bool Overlaps(Bounds a, Bounds b) => a.min.x <= b.max.x && a.max.x >= b.min.x && a.min.y <= b.max.y && a.max.y >= b.min.y && a.min.z <= b.max.z && a.max.z >= b.min.z;
	/// False only when the shape certainly lies outside the region; shapes that cannot be bounded cheaply are kept.
	static bool MayTouch(Transform transform, ShapeDesc desc, Bounds region)
	{
		float reach;
		switch (desc.kind)
		{
		case .Box: reach = desc.halfExtents.Length;
		case .Sphere: reach = desc.radius;
		case .Capsule: reach = desc.halfHeight + desc.radius;
		case .Mesh,.ConvexHull: return desc.mesh == null || Overlaps(desc.mesh.Bounds.Transformed(transform.LocalToWorld), region);
		default: return true;
		}
		reach += desc.center.Length;
		if (!reach.IsFinite) return true;
		let p = transform.Position;
		return Overlaps(.(p - .(reach, reach, reach), p + .(reach, reach, reach)), region);
	}

	/// With limit set, only geometry that can reach the region is copied, so a small rebuild does not rebuild every mesh shape.
	/// worlds: only objects in one of these world states (bits, as GameObject.WorldStates) are walked on or in the way.
	public static void BuildGeometry(Scene scene, PhysicsWorld world, bool includeRenderMeshes, bool limit, Bounds region, uint32 worlds = uint32.MaxValue)
	{
		// The objects are chosen here by worlds, not by the state the scene happens to be in.
		world.FollowsWorldStates = false;
		for (let component in scene.Components)
		{
			if (let collider = component as Collider)
			{
				if (!collider.IsActiveAndEnabled || !IsStaticGeometry(collider.GameObject) || (collider.GameObject.EffectiveWorldStates & worlds) == 0) continue;
				let shape = collider.GetShape();
				if (limit && !MayTouch(collider.Transform, shape, region)) continue;
				world.CreateBody(collider.Transform, shape, null);
			}
		}
		if (includeRenderMeshes)
		{
			for (let renderer in scene.Renderers)
			{
				if (!renderer.IsActiveAndEnabled || renderer.GameObject.GetComponent<Collider>() != null || !IsStaticGeometry(renderer.GameObject) || (renderer.GameObject.EffectiveWorldStates & worlds) == 0) continue;
				let mesh = renderer.ActiveMesh;
				if (mesh == null || mesh.Indices.Count == 0 || (limit && !Overlaps(renderer.WorldBounds, region))) continue;
				Vector3 position, scale;
				Quaternion rotation;
				renderer.Transform.LocalToWorld.Decompose(out position, out rotation, out scale);
				ShapeDesc desc = default;
				desc.kind = .Mesh;
				desc.mesh = mesh;
				desc.meshScale = Vector3.Abs(scale);
				world.CreateBody(renderer.Transform, desc, null);
			}
		}
	}

	public static bool Bake(NavigationData data, Scene scene, float verticalSize, String error, bool renderMeshes = true, uint32 worlds = uint32.MaxValue)
	{
		let world = scope PhysicsWorld();
		BuildGeometry(scene, world, renderMeshes, worlds);
		return Rebuild(data, world, verticalSize, .(data.origin, data.origin + .(data.width * data.cellSize, verticalSize, data.depth * data.cellSize)), error);
	}

	/// Cell range of the chunks that intersect dirty bounds.
	static void Range(NavigationData data, Bounds dirty, out int32 x0, out int32 x1, out int32 y0, out int32 y1, out int32 z0, out int32 z1)
	{
		let chunk = data.chunkSize;
		int32 Start(float p, float origin, int32 limit) => (int32)Mathf.Clamp(Math.Floor((p - origin) / data.cellSize / chunk) * chunk, 0, limit);
		int32 End(float p, float origin, int32 limit) => (int32)Mathf.Clamp((Math.Floor((p - origin) / data.cellSize / chunk) + 1) * chunk, 0, limit);
		x0 = Start(dirty.min.x - data.agentRadius, data.origin.x, data.width);
		x1 = End(dirty.max.x + data.agentRadius, data.origin.x, data.width);
		z0 = Start(dirty.min.z - data.agentRadius, data.origin.z, data.depth);
		z1 = End(dirty.max.z + data.agentRadius, data.origin.z, data.depth);
		y0 = data.flying ? Start(dirty.min.y - data.agentRadius, data.origin.y, data.height) : 0;
		y1 = data.flying ? End(dirty.max.y + data.agentRadius, data.origin.y, data.height) : 1;
	}

	/// World bounds that hold every query Rebuild makes for these dirty bounds: the sampled chunks, the ring of
	/// neighbours whose links are refreshed, and the agent's clearance around them.
	public static Bounds QueryBounds(NavigationData data, float verticalSize, Bounds dirty)
	{
		Range(data, dirty, let x0, let x1, let y0, let y1, let z0, let z1);
		let margin = data.cellSize + data.agentRadius + data.agentHeight + data.maxStep + 0.5f;
		var min = data.origin + Vector3(x0 * data.cellSize, y0 * data.cellSize, z0 * data.cellSize);
		var max = data.origin + Vector3(x1 * data.cellSize, y1 * data.cellSize, z1 * data.cellSize);
		if (!data.flying)
		{
			min.y = data.origin.y;
			max.y = data.origin.y + verticalSize;
		}
		return .(min - .(margin, margin, margin), max + .(margin, margin, margin));
	}

	/// Only chunks intersecting dirty bounds are sampled; adjacent cells have their links refreshed.
	public static bool Rebuild(NavigationData data, PhysicsWorld world, float verticalSize, Bounds dirty, String error)
	{
		if (data.cells.Count != data.width * data.height * data.depth || !data.agentRadius.IsFinite || !data.agentHeight.IsFinite || !data.maxStep.IsFinite || !data.maxSlope.IsFinite || data.maxStep < 0 || data.maxSlope < 0 || data.maxSlope >= 90 || data.agentRadius <= 0 || data.agentHeight < 2 * data.agentRadius || !verticalSize.IsFinite || verticalSize <= 0 || !dirty.IsValid || !dirty.min.x.IsFinite || !dirty.min.y.IsFinite || !dirty.min.z.IsFinite || !dirty.max.x.IsFinite || !dirty.max.y.IsFinite || !dirty.max.z.IsFinite)
		{
			error.Set("Invalid navigation grid or agent clearance settings.");
			return false;
		}
		Range(data, dirty, let x0, let x1, let y0, let y1, let z0, let z1);
		ShapeCastHit hit;
		// A flying agent is an upright capsule of the agent height around the cell center (a sphere when height is 2 x radius).
		let half = Math.Max(data.agentHeight * 0.5f - data.agentRadius, 0);
		for (int32 y = y0; y < y1; y++)
		{
			for (int32 z = z0; z < z1; z++)
			{
				for (int32 x = x0; x < x1; x++)
				{
					NavigationData.Cell cell = default;
					cell.position = data.Center(x, y, z);
					if (data.flying)
						cell.walkable = !world.CheckCapsule(cell.position - .(0, half, 0), cell.position + .(0, half, 0), data.agentRadius);
					else
					{
						let top = Vector3(cell.position.x, data.origin.y + verticalSize, cell.position.z);
						if (world.SphereCast(top, 0.01f, .(0, -1, 0), verticalSize, out hit) && hit.normal.y >= Math.Cos(data.maxSlope * Mathf.Deg2Rad))
						{
							cell.position.y = hit.point.y + 0.02f;
							// Clearance is checked from the step height up: anything lower can be stepped onto, so it must not block the
							// cell beside it, or the cells at the foot of every stair would be missing and no path could cross.
							let high = cell.position + .(0, data.agentHeight - data.agentRadius, 0);
							let low = cell.position + .(0, Math.Min(Math.Max(data.maxStep, 0) + data.agentRadius + 0.03f, data.agentHeight - data.agentRadius), 0);
							cell.walkable = !world.CheckCapsule(low, high, data.agentRadius);
						}
					}
					data.cells[data.Index(x, y, z)] = cell;
				}
			}
		}
		for (int32 y = Math.Max(0, y0 - 1); y < Math.Min(data.height, y1 + 1); y++)
		{
			for (int32 z = Math.Max(0, z0 - 1); z < Math.Min(data.depth, z1 + 1); z++)
			{
				for (int32 x = Math.Max(0, x0 - 1); x < Math.Min(data.width, x1 + 1); x++)
				{
					let id = data.Index(x, y, z);
					var cell = data.cells[id];
					cell.links = 0;
					if (cell.walkable)
					{
						for (int32 dir = 0; dir < NavigationData.DirectionCount; dir++)
						{
							if (!data.Uses(dir)) continue;
							let next = data.Neighbor(id, dir);
							if (next < 0 || !data.cells[next].walkable) continue;
							let target = data.cells[next].position;
							let delta = target - cell.position;
							if (!data.flying && Math.Abs(delta.y) > data.maxStep) continue;
							bool blocked;
							if (data.flying)
								blocked = world.CapsuleCast(cell.position - .(0, half, 0), cell.position + .(0, half, 0), data.agentRadius, delta, delta.Length, out hit);
							else
							{
								// Sweep above the permitted step height to allow stairs, while cell clearance rejects low ceilings.
								let baseY = Math.Max(cell.position.y, target.y) + Math.Max(data.maxStep, 0) + data.agentRadius + 0.03f;
								let a = Vector3(cell.position.x, baseY, cell.position.z);
								let b = Vector3(cell.position.x, Math.Max(baseY, cell.position.y + data.agentHeight - data.agentRadius), cell.position.z);
								blocked = world.CapsuleCast(a, b, data.agentRadius, .(delta.x, 0, delta.z), Math.Sqrt(delta.x * delta.x + delta.z * delta.z), out hit);
							}
							if (!blocked)
								cell.links |= 1u << dir;
						}
					}
					data.cells[id] = cell;
				}
			}
		}
		data.Touch();
		return true;
	}
}
