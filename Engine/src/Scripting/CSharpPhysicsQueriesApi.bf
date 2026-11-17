using System;
using System.Collections;

namespace Tallow;

/// Physics queries with many results for C# (Managed/Tallow.API/PhysicsQueries.cs): every hit of a ray or a sweep,
/// overlaps with their contacts, and many rays or sweeps in one call. Results are PhysicsQueryHit records written
/// into a byte buffer, one after another; each call returns how many there are (more than fit when the buffer is
/// short: call again with a bigger one).
[CSharpExpose]
static class CSharpPhysicsQueries
{
	static Scene LiveScene(uint64 session) => CSharpRuntime.PhysicsScene(session);

	static bool Finite(Vector3 v) => v.x.IsFinite && v.y.IsFinite && v.z.IsFinite;

	static int32 Put(Span<uint8> buffer, int index, PhysicsQueryHit hit)
	{
		let size = sizeof(PhysicsQueryHit);
		if ((index + 1) * size <= buffer.Length)
			*(PhysicsQueryHit*)(buffer.Ptr + index * size) = hit;
		return 1;
	}

	/// Every body a query passes through, nearest first: kind 0 a ray, 1 a sphere (radius), 2 a capsule (point2,
	/// radius), 3 a box (size, orientation as x, y, z, w), from point1 along direction for maxDistance.
	[CSharpExpose]
	public static int32 CastAll(uint64 session, int32 kind, Vector3 point1, Vector3 point2, float radius, Vector3 size,
		Vector4 orientation, Vector3 direction, float maxDistance, uint32 layerMask, uint32 ignoreBody, Span<uint8> buffer)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !Finite(point1) || !Finite(direction) || !maxDistance.IsFinite || maxDistance <= 0)
			return 0;
		int32 count = 0;
		if (kind == 0)
		{
			let hits = scope List<RaycastHit>();
			scene.Physics.RaycastAll(point1, direction, maxDistance, hits, layerMask, ignoreBody);
			for (let hit in hits)
				count += Put(buffer, count, Physics.RayHit(hit));
			return count;
		}
		let hits = scope List<ShapeCastHit>();
		let turn = Quaternion(orientation.x, orientation.y, orientation.z, orientation.w);
		switch (kind)
		{
		case 1:
			if (!radius.IsFinite || radius <= 0) return 0;
			scene.Physics.SphereCastAll(point1, radius, direction, maxDistance, hits, ignoreBody, layerMask);
		case 2:
			if (!radius.IsFinite || radius <= 0 || !Finite(point2)) return 0;
			scene.Physics.CapsuleCastAll(point1, point2, radius, direction, maxDistance, hits, ignoreBody, layerMask);
		case 3:
			if (!Finite(size) || size.x <= 0 || size.y <= 0 || size.z <= 0) return 0;
			scene.Physics.BoxCastAll(point1, size, turn, direction, maxDistance, hits, ignoreBody, layerMask);
		default:
			return 0;
		}
		for (let hit in hits)
			count += Put(buffer, count, Physics.ShapeHit(hit));
		return count;
	}

	/// Every contact of a sphere (0), capsule (1, point2) or box (2, size and orientation) placed at point1: the
	/// point, the surface's normal, how deep it goes, the body, part and triangle. A body touched in several places
	/// gives several contacts.
	[CSharpExpose]
	public static int32 OverlapContacts(uint64 session, int32 shape, Vector3 point1, Vector3 point2, float radius, Vector3 size,
		Vector4 orientation, uint32 layerMask, uint32 ignoreBody, Span<uint8> buffer)
	{
		let scene = LiveScene(session);
		if (scene == null || scene.Physics == null || !Finite(point1))
			return 0;
		let hits = scope List<ShapeCastHit>();
		let turn = Quaternion(orientation.x, orientation.y, orientation.z, orientation.w);
		switch (shape)
		{
		case 0:
			if (!radius.IsFinite || radius <= 0) return 0;
			scene.Physics.OverlapSphere(point1, radius, hits, ignoreBody, layerMask);
		case 1:
			if (!radius.IsFinite || radius <= 0 || !Finite(point2)) return 0;
			scene.Physics.OverlapCapsule(point1, point2, radius, hits, ignoreBody, layerMask);
		case 2:
			if (!Finite(size) || size.x <= 0 || size.y <= 0 || size.z <= 0) return 0;
			scene.Physics.OverlapBox(point1, size, turn, hits, ignoreBody, layerMask);
		default:
			return 0;
		}
		int32 count = 0;
		for (let hit in hits)
		{
			var record = Physics.ShapeHit(hit);
			record.distance = 0;
			count += Put(buffer, count, record);
		}
		return count;
	}

	/// Many closest-hit queries in one call. Rays (kind 0): 7 floats each (origin, direction, maxDistance); spheres
	/// (kind 1): 8 (origin, radius, direction, maxDistance). One record per query, in order; a miss has flags 0.
	[CSharpExpose]
	public static int32 CastBatch(uint64 session, int32 kind, Span<float> queries, uint32 layerMask, uint32 ignoreBody, Span<uint8> buffer)
	{
		let scene = LiveScene(session);
		let stride = kind == 0 ? 7 : 8;
		let total = (int32)(queries.Length / stride);
		if (scene == null || scene.Physics == null)
			return 0;
		for (int i < total)
		{
			let q = queries.Ptr + i * stride;
			PhysicsQueryHit record = default;
			if (kind == 0)
			{
				Vector3 origin = .(q[0], q[1], q[2]), direction = .(q[3], q[4], q[5]);
				RaycastHit hit = default;
				if (Finite(origin) && Finite(direction) && q[6].IsFinite && q[6] > 0 &&
					scene.Physics.Raycast(origin, direction, q[6], out hit, layerMask))
					record = Physics.RayHit(hit);
			}
			else
			{
				Vector3 origin = .(q[0], q[1], q[2]), direction = .(q[4], q[5], q[6]);
				ShapeCastHit hit = default;
				if (Finite(origin) && Finite(direction) && q[3].IsFinite && q[3] > 0 && q[7].IsFinite && q[7] > 0 &&
					scene.Physics.SphereCast(origin, q[3], direction, q[7], out hit, ignoreBody, layerMask))
					record = Physics.ShapeHit(hit);
			}
			Put(buffer, i, record);
		}
		return total;
	}

	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		for (int i < Math.Min(text.Length, buffer.Length))
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	/// The surface an object's colliders name (Collider.surface; empty for none).
	[CSharpExpose]
	public static int32 Surface(uint64 session, uint64 entity, Span<uint8> buffer) =>
		Copy(Collider.SurfaceOf(CSharpRuntime.PhysicsObject(session, entity)), buffer);

	/// Builds an object's collision again after its shape changed (a Mesh Collider's mesh was edited or replaced):
	/// its colliders' static bodies, or its Rigidbody's body. False without a collider.
	[CSharpExpose]
	public static bool RefreshColliders(uint64 session, uint64 entity)
	{
		let obj = CSharpRuntime.PhysicsObject(session, entity);
		if (obj == null)
			return false;
		bool any = false;
		for (let component in obj.Components)
		{
			if (let collider = component as Collider)
			{
				collider.Refresh();
				any = true;
			}
		}
		if (any && obj.HasComponent<Rigidbody>())
			obj.GetComponent<Rigidbody>().RebuildBody();
		return any;
	}
}
