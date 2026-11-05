using System;
using System.Collections;

namespace Tallow;

/// How an agent crosses a Navigation Link.
[Reflect(.All)]
enum NavigationLinkKind
{
	/// Jumps across in an arc (a gap, a ledge up or down).
	Jump,
	/// Goes straight there at a steady pace (a ladder, a rope, a vent).
	Climb,
	/// Is there at once (a teleporter, a door to another room).
	Teleport,
	/// Walks there along the ground (a door the grid treats as shut, a narrow plank).
	Walk
}

/// A way across that the baked grid does not have: a gap to jump, a ledge to drop off, a ladder, a teleporter. It
/// runs from this object to End (relative to the object). Agents use it when it is the shorter way, and the game
/// hears when they start and finish crossing (NavigationAgent.OnLinkStarted / OnLinkFinished), to play a jump or climb
/// animation. See docs/navigation.md.
[Component]
class NavigationLink : Component
{
	/// Where the link ends, relative to this object (turned with it).
	public Vector3 end = .(0, 0, 3);
	/// Agents can cross it both ways. Off: only from this object to End (a drop they cannot climb back up).
	public bool bidirectional = true;
	public NavigationLinkKind kind = .Jump;
	/// Seconds to cross it (Teleport: none).
	[Range(0, 10)]
	public float duration = 0.6f;
	/// How high a Jump arcs above the higher end.
	public float jumpHeight = 1;
	/// What crossing it costs, as a multiple of its length: higher makes agents use it only when the way round is
	/// much longer.
	[Range(0.1f, 20)]
	public float costMultiplier = 1;
	/// How far each end may be from a usable cell.
	public float snapDistance = 1;

	public Vector3 StartPoint => Transform.Position;
	public Vector3 EndPoint => Transform.Position + Transform.Rotation * end;

	/// Where an agent crossing from one end to the other is, t from 0 to 1.
	public Vector3 Along(Vector3 from, Vector3 to, float t)
	{
		var point = Vector3.Lerp(from, to, t);
		if (kind == .Jump)
		{
			// A parabola through both ends that peaks jumpHeight above the higher one.
			let top = Math.Max(from.y, to.y) + Math.Max(jumpHeight, 0);
			let rise = top - from.y;
			let fall = top - to.y;
			// Height at t on a parabola with y(0) = from, y(1) = to and its peak at `top`.
			let peak = (rise + fall) > 0 ? Math.Sqrt(Math.Max(rise, 0)) / (Math.Sqrt(Math.Max(rise, 0)) + Math.Sqrt(Math.Max(fall, 0))) : 0.5f;
			let a = peak > 0 ? rise / (peak * peak) : 0;
			point.y = top - a * (t - peak) * (t - peak);
			if (t <= 0)
				point.y = from.y;
			else if (t >= 1)
				point.y = to.y;
		}
		return point;
	}

	public override void OnDrawGizmos(bool selected)
	{
		let color = selected ? Color(1, 0.8f, 0.2f, 1) : Color(1, 0.6f, 0.1f, 0.7f);
		let from = StartPoint;
		let to = EndPoint;
		var previous = from;
		for (int i = 1; i <= 16; i++)
		{
			let point = Along(from, to, i / 16.0f);
			Gizmos.Lines.Line(previous, point, color);
			previous = point;
		}
		Gizmos.Lines.Circle(from, .Up, 0.25f, color, 16);
		Gizmos.Lines.Circle(to, .Up, 0.25f, color, 16);
		if (!bidirectional)
		{
			// An arrow head at the end it goes to.
			let back = Along(from, to, 0.85f);
			var side = Vector3.Cross(to - back, .Up);
			if (side.LengthSquared > 0.0001f)
				side = side.Normalized * 0.2f;
			Gizmos.Lines.Line(to, back + side, color);
			Gizmos.Lines.Line(to, back - side, color);
		}
	}
}

/// Something that moves around and that agents must keep out of: a crate, a car, a closing door. While it stands
/// still (or always, with Carve Only Stationary off) it cuts its shape out of the grid so agents plan round it;
/// while it moves, agents steer round it instead. See docs/navigation.md.
[Component]
class NavigationObstacle : Component
{
	[Reflect(.All)]
	public enum Shape
	{
		Box,
		Cylinder
	}

	public Shape shape = .Box;
	/// Box: its size in metres (whatever the object's scale). Cylinder: x is its diameter, y its height.
	public Vector3 size = .(1, 1, 1);
	/// Offset of the shape's centre from the object.
	public Vector3 center;
	/// Cuts the shape out of the grid, so agents plan paths round it. Off: agents only steer round it.
	public bool carve = true;
	/// Carves only once it has stood still for Stationary Time, so a moving obstacle does not make every agent plan
	/// again each frame.
	public bool carveOnlyStationary = true;
	public float stationaryTime = 0.5f;
	/// How far it must move to count as moving.
	public float moveThreshold = 0.1f;

	Vector3 mLastPosition;
	Quaternion mLastRotation;
	float mStill;
	bool mStarted;
	/// Where it was when it last carved; the grid is cut there until it carves again.
	public Vector3 CarvedPosition;
	public Quaternion CarvedRotation;
	public bool Carving;
	/// How fast it is moving (for agents steering round it).
	public Vector3 Velocity;

	public Vector3 HalfExtents => shape == .Cylinder ? Vector3(size.x * 0.5f, size.y * 0.5f, size.x * 0.5f) : size * 0.5f;
	/// Its footprint as a circle (for agents steering round it).
	public float Radius => shape == .Cylinder ? size.x * 0.5f : Math.Sqrt(size.x * size.x + size.z * size.z) * 0.5f;

	public override void OnLocalUpdate()
	{
		let position = Transform.Position + Transform.Rotation * center;
		let rotation = Transform.Rotation;
		let dt = Math.Max(Time.DeltaTime, 0.0001f);
		if (!mStarted)
		{
			mStarted = true;
			mLastPosition = position;
			mLastRotation = rotation;
			mStill = stationaryTime;
		}
		Velocity = (position - mLastPosition) / dt;
		let moved = (position - CarvedPosition).Length > moveThreshold || Quaternion.Dot(rotation, CarvedRotation) < 0.9995f;
		if ((position - mLastPosition).Length > 0.0005f || Quaternion.Dot(rotation, mLastRotation) < 0.99999f)
			mStill = 0;
		else
			mStill += Time.DeltaTime;
		mLastPosition = position;
		mLastRotation = rotation;
		if (!carve)
		{
			Carving = false;
			return;
		}
		let settled = !carveOnlyStationary || mStill >= stationaryTime;
		if (settled && (!Carving || moved))
		{
			Carving = true;
			CarvedPosition = position;
			CarvedRotation = rotation;
		}
		else if (!settled && Carving && moved)
			// It has moved away from where it carved: the hole there is filled in while it travels.
			Carving = false;
	}

	public override void OnDisable()
	{
		Carving = false;
		mStarted = false;
	}

	public override void OnDrawGizmos(bool selected)
	{
		let color = selected ? Color(1, 0.35f, 0.3f, 1) : Color(1, 0.35f, 0.3f, 0.5f);
		let c = Transform.Position + Transform.Rotation * center;
		let half = HalfExtents;
		if (shape == .Cylinder)
		{
			let up = Transform.Rotation * Vector3.Up;
			Gizmos.Lines.Circle(c + up * half.y, up, half.x, color, 24);
			Gizmos.Lines.Circle(c - up * half.y, up, half.x, color, 24);
		}
		else
			// Its size is in metres, whatever the object's scale.
			Gizmos.Lines.Box(Bounds(center - half, center + half), Matrix4.TRS(Transform.Position, Transform.Rotation, .(1, 1, 1)), color);
	}
}

/// Part of a surface that costs more to cross (mud, water, a dangerous room) or that agents must not enter: agents
/// go round it when the way round is not too much longer. See docs/navigation.md.
[Component]
class NavigationArea : Component
{
	/// The box's size in metres (whatever the object's scale), centred on the object.
	public Vector3 size = .(4, 2, 4);
	/// How much more crossing it costs than its length: 2 makes agents walk up to twice as far to avoid it.
	[Range(1, 100)]
	public float cost = 3;
	/// Agents never enter it (as if it were not walkable at all).
	public bool blocked = false;

	public override void OnDrawGizmos(bool selected)
	{
		let half = size * 0.5f;
		let color = blocked ? Color(1, 0.2f, 0.2f, selected ? 1 : 0.5f) : Color(0.9f, 0.5f, 1, selected ? 1 : 0.5f);
		Gizmos.Lines.Box(Bounds(-half, half), Matrix4.TRS(Transform.Position, Transform.Rotation, .(1, 1, 1)), color);
	}
}
