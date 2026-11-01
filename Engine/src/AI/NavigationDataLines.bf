using System;
using System.Collections;

namespace Tallow;

/// Straight lines over a NavigationData: whether an agent can go directly from one point to another, and straightening
/// a path where it can.
extension NavigationData
{
	/// True when an agent can go straight from a to b: every cell the line crosses is usable and linked to the one
	/// before it (so the agent's shape fits all the way), and, walking, the floor stays close to the line's height.
	/// The point where the line stops is `reached`.
	public bool LineClear(Vector3 a, Vector3 b, out Vector3 reached)
	{
		if (Mesh != null)
		{
			CommitNavMesh();
			return Mesh.LineClear(a, b, out reached);
		}
		using (sLineClearProfile.Sample())
		{
			if (!flying)
				return WalkingLineClear(a, b, out reached);
			// Flying: points a quarter cell apart along the line.
			reached = a;
			var previous = CellAt(a);
			if (!Usable(previous))
				return false;
			int32 lastSquare = -1;
			let steps = (int)Math.Ceiling((b - a).Length / (cellSize * 0.25f));
			for (int s = 1; s <= steps; s++)
			{
				let t = (float)s / steps;
				let point = Vector3.Lerp(a, b, t);
				// Between cell centres the line can pass nearer a wall than any centre does: it must lie among usable
				// cells that are all linked to each other, whose swept links cover the space between them.
				if (!Among(point, ref lastSquare))
					return false;
				let cell = CellAt(point);
				if (cell == previous)
					continue;
				if (!Usable(cell))
					return false;
				let px = previous % width, pz = (previous / width) % depth, py = previous / (width * depth);
				let cx = cell % width, cz = (cell / width) % depth, cy = cell / (width * depth);
				let dx = cx - px, dy = cy - py, dz = cz - pz;
				if (Math.Abs(dx) > 1 || Math.Abs(dy) > 1 || Math.Abs(dz) > 1)
					return false;
				let direction = DirectionOf(dx, dy, dz);
				if (direction < 0 || !Uses(direction) || (cells[previous].links & (1u << direction)) == 0)
					return false;
				reached = point;
				previous = cell;
			}
			reached = b;
			return true;
		}
	}

	/// LineClear on a walking grid. The line is cut where it crosses a cell's edge or a row of cell centres; inside each
	/// piece the cell it is over and the square of cells round it stay the same, so one check covers the piece (no points
	/// sampled a fixed distance apart, which could step over a thin corner). Over a flat node it crosses the whole node
	/// in one step (useLeafClearance). The floor must stay within a step of the line's height: a long straight leg over a
	/// hill would cut through it, or float over a dip.
	bool WalkingLineClear(Vector3 a, Vector3 b, out Vector3 reached)
	{
		reached = a;
		if (!a.x.IsFinite || !a.y.IsFinite || !a.z.IsFinite || !b.x.IsFinite || !b.y.IsFinite || !b.z.IsFinite) return false;
		var previous = CellAt(a);
		if (!Usable(previous)) return false;
		let delta = b - a;
		if (!delta.x.IsFinite || !delta.y.IsFinite || !delta.z.IsFinite) return false;
		let spacing = (double)cellSize * 0.5;
		double Next(float start, float movement, float minimum)
		{
			if (movement == 0) return double.MaxValue;
			let coordinate = ((double)start - minimum) / spacing;
			let plane = movement > 0 ? Math.Floor(coordinate) + 1 : Math.Ceiling(coordinate) - 1;
			return (plane * spacing + minimum - start) / movement;
		}
		var tx = Next(a.x, delta.x, origin.x), tz = Next(a.z, delta.z, origin.z);
		let stepX = delta.x == 0 ? double.MaxValue : spacing / Math.Abs((double)delta.x);
		let stepZ = delta.z == 0 ? double.MaxValue : spacing / Math.Abs((double)delta.z);
		int32 lastSquare = -1;
		double t = 0;
		let tolerance = Math.Max(maxStep * 0.6f, cellSize * 0.2f);
		let leafClearance = useLeafClearance && useNodes && mNodeRevision == Revision && mNodeOf.Count == cells.Count;
		while (t < 1)
		{
			let end = Math.Min(1.0, Math.Min(tx, tz));
			let middle = (t + end) * 0.5;
			let point = Vector3.Lerp(a, b, (float)middle);
			let x = a.x + (double)delta.x * middle, z = a.z + (double)delta.z * middle;
			if (!WalkingAmong(x, z, delta.x != 0, delta.z != 0, ref lastSquare)) return false;
			let cx = (int32)Math.Floor((x - origin.x) / cellSize), cz = (int32)Math.Floor((z - origin.z) / cellSize);
			let cell = Inside(cx, 0, cz) ? Index(cx, 0, cz) : -1;
			if (!Usable(cell)) return false;
			if (cell != previous)
			{
				let dx = cell % width - previous % width;
				let dz = cell / width - previous / width;
				let direction = DirectionOf(dx, 0, dz);
				if (direction < 0 || !Uses(direction) || (cells[previous].links & (1u << direction)) == 0)
					return false;
			}
			// The floor's height changes evenly across a cell, so checking the piece's ends covers all of it.
			let floor = cells[cell].position.y;
			if (Math.Abs(floor - (a.y + delta.y * (float)t)) > tolerance || Math.Abs(floor - (a.y + delta.y * (float)end)) > tolerance)
				return false;
			var advance = end;
			previous = cell;
			if (leafClearance)
			{
				let id = mNodeOf[cell];
				if (id >= 0)
				{
					let node = mNodes[id];
					if (node.flat && x >= node.safeMin.x && x <= node.safeMax.x && z >= node.safeMin.z && z <= node.safeMax.z)
					{
						double exit = 1;
						if (delta.x != 0)
							exit = Math.Min(exit, ((delta.x > 0 ? node.safeMax.x : node.safeMin.x) - (double)a.x) / delta.x);
						if (delta.z != 0)
							exit = Math.Min(exit, ((delta.z > 0 ? node.safeMax.z : node.safeMin.z) - (double)a.z) / delta.z);
						// Anywhere between the node's outer cell centres is among usable, linked cells, and its floor is
						// level, so only the ends of the stretch need the height check.
						if (exit > end && Math.Abs(node.floor - (a.y + delta.y * (float)exit)) <= tolerance)
						{
							advance = exit;
							let ex = a.x + (double)delta.x * exit, ez = a.z + (double)delta.z * exit;
							previous = Index((int32)Math.Floor((ex - origin.x) / cellSize), 0, (int32)Math.Floor((ez - origin.z) / cellSize));
							lastSquare = -1;
						}
					}
				}
			}
			reached = advance > end ? Vector3.Lerp(a, b, (float)advance) : point;
			t = advance;
			// After crossing a node, the next edge and centre-row crossings are past where it came out.
			if (tx <= advance)
				tx += (Math.Floor((advance - tx) / stepX) + 1) * stepX;
			if (tz <= advance)
				tz += (Math.Floor((advance - tz) / stepZ) + 1) * stepZ;
		}
		// An end exactly on an edge still has a cell of its own, even when the piece before it did not.
		let goal = CellAt(b);
		if (!Usable(goal) || Math.Abs(cells[goal].position.y - b.y) > tolerance || !Among(b, ref lastSquare)) return false;
		if (goal != previous)
		{
			let direction = DirectionOf(goal % width - previous % width, 0, goal / width - previous / width);
			if (direction < 0 || (cells[previous].links & (1u << direction)) == 0) return false;
		}
		reached = b;
		return true;
	}

	bool WalkingSquare(int32 bx, int32 bz, int32 spanX, int32 spanZ)
	{
		// Among for walking grids: at most four corners and six pairs, checked directly (it runs for every piece of
		// every line check).
		let a = Index(bx, 0, bz), b = a + 1, c = a + width, d = c + 1;
		bool Linked(int32 first, int32 second, int32 direction, int32 reverse) =>
			(cells[first].links & (1u << direction)) != 0 || (cells[second].links & (1u << reverse)) != 0;
		if (!Usable(a)) return false;
		if (spanX == 2 && (!Usable(b) || !Linked(a, b, 0, 1))) return false;
		if (spanZ == 2 && (!Usable(c) || !Linked(a, c, 2, 3))) return false;
		if (spanX == 2 && spanZ == 2 && (!Usable(d) || !Linked(b, d, 2, 3) || !Linked(c, d, 0, 1) || !Linked(a, d, 6, 9) || !Linked(b, c, 8, 7))) return false;
		return true;
	}

	bool WalkingAmong(double x, double z, bool movingX, bool movingZ, ref int32 last)
	{
		void Span(double along, bool moving, out int32 first, out int32 span)
		{
			let f = along / cellSize - 0.5;
			first = (int32)Math.Floor(f);
			let part = f - first;
			span = 2;
			// A line that does not move along an axis and lies on a row of centres stays in that row; one that moves
			// along it must cover the whole piece, however close the piece's middle is to the row.
			if (!moving && part < 0.001)
				span = 1;
			else if (!moving && part > 0.999)
			{
				first++;
				span = 1;
			}
		}
		Span(x - origin.x, movingX, let bx, let spanX);
		Span(z - origin.z, movingZ, let bz, let spanZ);
		if (!Inside(bx, 0, bz) || !Inside(bx + spanX - 1, 0, bz + spanZ - 1)) return true;
		let square = Index(bx, 0, bz) * 8 + (spanX - 1) + (spanZ - 1) * 2;
		if (square == last) return true;
		last = square;
		return WalkingSquare(bx, bz, spanX, spanZ);
	}

	/// Whether a point lies in a square (flying: a cube) of usable cells whose centres surround it, each linked to the
	/// others along the square's sides and across it. `last` skips a square already checked.
	bool Among(Vector3 point, ref int32 last)
	{
		// The cells whose centres surround the point on each axis: two, or one when the point lies on their row (a
		// line along the last row of cells beside a wall stays among that row, not the wall's).
		void Span(float along, out int32 first, out int32 span)
		{
			let f = along / cellSize - 0.5f;
			first = (int32)Math.Floor(f);
			let part = f - first;
			span = 2;
			if (part < 0.001f)
				span = 1;
			else if (part > 0.999f)
			{
				first++;
				span = 1;
			}
		}
		Span(point.x - origin.x, var bx, var spanX);
		Span(point.z - origin.z, var bz, var spanZ);
		int32 by = 0, layers = 1;
		if (flying)
			Span(point.y - origin.y, out by, out layers);
		// At the grid's edge there is no full square; the cell itself is checked by the caller.
		if (!Inside(bx, by, bz) || !Inside(bx + spanX - 1, by + layers - 1, bz + spanZ - 1))
			return true;
		let square = Index(bx, by, bz) * 8 + (spanX - 1) + (spanZ - 1) * 2 + (layers - 1) * 4;
		if (square == last)
			return true;
		last = square;
		if (!flying) return WalkingSquare(bx, bz, spanX, spanZ);

		int32[8] corners = default;
		int32[8] cornerX = default, cornerY = default, cornerZ = default;
		int count = 0;
		for (int32 y < layers)
		{
			for (int32 z < spanZ)
			{
				for (int32 x < spanX)
				{
					let index = Index(bx + x, by + y, bz + z);
					if (!Usable(index))
						return false;
					cornerX[count] = x;
					cornerY[count] = y;
					cornerZ[count] = z;
					corners[count++] = index;
				}
			}
		}
		// Every pair of corners that are grid neighbours must be linked (one way is enough: links are symmetric).
		for (int i < count)
		{
			for (int j = i + 1; j < count; j++)
			{
				let a = corners[i], b = corners[j];
				let direction = DirectionOf(cornerX[j] - cornerX[i], cornerY[j] - cornerY[i], cornerZ[j] - cornerZ[i]);
				if (direction < 0 || !Uses(direction))
					continue;
				if ((cells[a].links & (1u << direction)) == 0 && (cells[b].links & (1u << Opposite(direction))) == 0)
					return false;
			}
		}
		return true;
	}

	/// Straightens a path of cell centres where the agent can go directly: each point is joined to the farthest one
	/// after it with a clear line. Points where a link starts or ends are kept (legLinks, from FindPath, says which
	/// legs are links; it is kept in step).
	public void Smooth(List<Vector3> path, List<int32> legLinks = null)
	{
		if (Mesh != null) return; // Detour already funnels the polygon corridor.
		using (sSmoothProfile.Sample())
		{
			if (path.Count < 3)
				return;
			let points = scope List<Vector3>();
			let kept = scope List<int32>();
			points.Add(path[0]);
			kept.Add(-1);
			int i = 0;
			while (i < path.Count - 1)
			{
				// A link is crossed as it is.
				if (legLinks != null && legLinks[i] >= 0)
				{
					kept[kept.Count - 1] = legLinks[i];
					points.Add(path[i + 1]);
					kept.Add(-1);
					i++;
					continue;
				}
				// Not past the start of a link.
				var last = path.Count - 1;
				if (legLinks != null)
				{
					for (int j = i + 1; j < path.Count; j++)
					{
						if (legLinks[j - 1] >= 0)
						{
							last = j - 1;
							break;
						}
					}
				}
				// The farthest point in a clear line: longer and longer jumps until one is blocked, then halving the gap
				// (a few line checks per leg rather than one for every point along it).
				var best = i + 1;
				var step = 1;
				var blocked = last + 1;
				while (best < last)
				{
					let j = Math.Min(best + step, last);
					if (!LineClear(path[i], path[j], ?))
					{
						blocked = j;
						break;
					}
					best = j;
					step *= 2;
				}
				while (blocked - best > 1)
				{
					let j = (best + blocked) / 2;
					if (LineClear(path[i], path[j], ?))
						best = j;
					else
						blocked = j;
				}
				points.Add(path[best]);
				kept.Add(-1);
				i = best;
			}
			path.Clear();
			path.AddRange(points);
			if (legLinks != null)
			{
				legLinks.Clear();
				legLinks.AddRange(kept);
			}
		}
	}
}
