using System;
using System.Collections;

namespace Tallow;

/// Soft body vertices and dents, and ropes, for C# (Managed/Tallow.API/PhysicsComponents.cs). Points travel as
/// floats, x, y, z after one another; a call that fills a buffer returns how many floats it has (call again with a
/// bigger buffer when that is more than it was given).
[CSharpExpose]
static class CSharpRopes
{
	static GameObject Object(uint64 session, uint64 entity) => CSharpRuntime.PhysicsObject(session, entity);
	static SoftBody Soft(uint64 session, uint64 entity) => Object(session, entity)?.GetComponent<SoftBody>();
	static Rope RopeOf(uint64 session, uint64 entity) => Object(session, entity)?.GetComponent<Rope>();

	static int32 Write(Span<Vector3> points, Span<float> buffer)
	{
		for (int i < Math.Min(points.Length, buffer.Length / 3))
		{
			buffer[i * 3] = points[i].x;
			buffer[i * 3 + 1] = points[i].y;
			buffer[i * 3 + 2] = points[i].z;
		}
		return (int32)points.Length * 3;
	}

	static void Read(Span<float> values, List<Vector3> points)
	{
		for (int i < values.Length / 3)
			points.Add(.(values[i * 3], values[i * 3 + 1], values[i * 3 + 2]));
	}

	/// What: 0 dents (object space), 1 vertex positions (world). -1 without a soft body.
	[CSharpExpose]
	public static int32 SoftPoints(uint64 session, uint64 entity, int32 what, Span<float> buffer)
	{
		let soft = Soft(session, entity);
		if (soft == null)
			return -1;
		if (what == 0)
		{
			let dents = scope List<Vector3>();
			soft.GetDents(dents);
			return Write(dents, buffer);
		}
		return Write(soft.Positions, buffer);
	}

	/// What: 0 SetDents (empty repairs), 1 SetPositions.
	[CSharpExpose]
	public static bool SetSoftPoints(uint64 session, uint64 entity, int32 what, Span<float> values)
	{
		let soft = Soft(session, entity);
		if (soft == null)
			return false;
		let points = scope List<Vector3>();
		Read(values, points);
		if (what == 0)
			soft.SetDents(points);
		else
			soft.SetPositions(points);
		return true;
	}

	/// Builds the soft body (0) or the rope (1) again after its fields changed while playing.
	[CSharpExpose]
	public static bool Rebuild(uint64 session, uint64 entity, int32 kind)
	{
		if (kind == 0)
		{
			let soft = Soft(session, entity);
			if (soft == null)
				return false;
			soft.Rebuild();
			return true;
		}
		let rope = RopeOf(session, entity);
		if (rope == null)
			return false;
		rope.Rebuild();
		return true;
	}

	/// The physics body ids its vertices touched since this was last asked (-1 without a soft body).
	[CSharpExpose]
	public static int32 Touching(uint64 session, uint64 entity, Span<uint64> buffer)
	{
		let soft = Soft(session, entity);
		if (soft == null)
			return -1;
		let bodies = scope List<uint32>();
		soft.TouchingBodies(bodies);
		for (int i < Math.Min(bodies.Count, buffer.Length))
			buffer[i] = bodies[i];
		return (int32)bodies.Count;
	}

	/// Ties a new rope between two objects; the rope object's id, or 0 (on a client the server ties it).
	[CSharpExpose]
	public static uint64 Attach(uint64 session, uint64 from, uint64 to, Vector3 fromOffset, Vector3 toOffset, float length, float thickness)
	{
		let a = Object(session, from);
		let b = Object(session, to);
		if (a == null || b == null)
			return 0;
		let rope = Rope.Attach(a, b, fromOffset, toOffset, length, thickness);
		return rope?.GameObject?.Id ?? 0;
	}

	/// 0 IsTaut (1 or 0), 1 Pull in newtons. NaN without a rope.
	[CSharpExpose]
	public static float RopeState(uint64 session, uint64 entity, int32 what)
	{
		let rope = RopeOf(session, entity);
		if (rope == null)
			return float.NaN;
		return what == 0 ? (rope.IsTaut ? 1 : 0) : rope.Pull;
	}

	/// Ties the rope's start (end 0) or other end (1) to an object (0: lets it go).
	[CSharpExpose]
	public static bool RopeTie(uint64 session, uint64 entity, int32 end, uint64 target, Vector3 offset)
	{
		let rope = RopeOf(session, entity);
		if (rope == null)
			return false;
		let to = target == 0 ? null : Object(session, target)?.Transform;
		if (end == 0)
			rope.AttachStart(to, offset);
		else
			rope.AttachEnd(to, offset);
		return true;
	}

	[CSharpExpose]
	public static bool RopeLayAlong(uint64 session, uint64 entity, Span<float> path)
	{
		let rope = RopeOf(session, entity);
		if (rope == null || path.Length < 6)
			return false;
		let points = scope List<Vector3>();
		Read(path, points);
		rope.LayAlong(points);
		return true;
	}

	/// Snaps it in two; the other half's object id, or 0.
	[CSharpExpose]
	public static uint64 RopeSnap(uint64 session, uint64 entity)
	{
		let rope = RopeOf(session, entity);
		return rope?.Snap()?.GameObject?.Id ?? 0;
	}
}
