using System;
using System.Collections;

namespace Tallow;

/// A per-frame list of colored line segments.
class LineBatch
{
	/// Two vertices for each line (three for each triangle in a batch of triangles).
	public List<LineVertex> Vertices = new .() ~ delete _;

	/// Removes everything.
	public void Clear() => Vertices.Clear();

	/// Adds a line, in the world.
	public void Line(Vector3 a, Vector3 b, Color color)
	{
		let packed = color.ToABGR();
		LineVertex va;
		va.position = a;
		va.color = packed;
		LineVertex vb;
		vb.position = b;
		vb.color = packed;
		Vertices.Add(va);
		Vertices.Add(vb);
	}

	/// A filled triangle, for a batch that is drawn as triangles (Gizmos.Triangles).
	public void Triangle(Vector3 a, Vector3 b, Vector3 c, Color color)
	{
		let packed = color.ToABGR();
		LineVertex v;
		v.color = packed;
		v.position = a;
		Vertices.Add(v);
		v.position = b;
		Vertices.Add(v);
		v.position = c;
		Vertices.Add(v);
	}

	/// A filled quad from four corners in order around its edge.
	public void Quad(Vector3 a, Vector3 b, Vector3 c, Vector3 d, Color color)
	{
		Triangle(a, b, c, color);
		Triangle(a, c, d, color);
	}

	/// Wire box around local-space bounds transformed by a matrix.
	public void Box(Bounds bounds, Matrix4 matrix, Color color)
	{
		Vector3[8] c = default;
		for (int i < 8)
		{
			let p = Vector3((i & 1) != 0 ? bounds.max.x : bounds.min.x, (i & 2) != 0 ? bounds.max.y : bounds.min.y, (i & 4) != 0 ? bounds.max.z : bounds.min.z);
			c[i] = matrix.TransformPoint(p);
		}
		Line(c[0], c[1], color);
		Line(c[2], c[3], color);
		Line(c[4], c[5], color);
		Line(c[6], c[7], color);
		Line(c[0], c[2], color);
		Line(c[1], c[3], color);
		Line(c[4], c[6], color);
		Line(c[5], c[7], color);
		Line(c[0], c[4], color);
		Line(c[1], c[5], color);
		Line(c[2], c[6], color);
		Line(c[3], c[7], color);
	}

	/// Adds a box's edges.
	public void Box(Bounds bounds, Color color) => Box(bounds, .Identity, color);

	/// Adds a circle facing a direction.
	public void Circle(Vector3 center, Vector3 normal, float radius, Color color, int segments = 32)
	{
		let n = normal.Normalized;
		var tangent = Vector3.Cross(n, Mathf.Abs(n.y) < 0.99f ? Vector3.Up : Vector3.Right).Normalized;
		let bitangent = Vector3.Cross(n, tangent);
		var previous = center + tangent * radius;
		for (int i = 1; i <= segments; i++)
		{
			let angle = (float)i / segments * Mathf.PI * 2.0f;
			let point = center + (tangent * Math.Cos(angle) + bitangent * Math.Sin(angle)) * radius;
			Line(previous, point, color);
			previous = point;
		}
	}

	/// Adds three circles round a point, one on each axis.
	public void Sphere(Vector3 center, float radius, Color color)
	{
		Circle(center, .(1, 0, 0), radius, color);
		Circle(center, .(0, 1, 0), radius, color);
		Circle(center, .(0, 0, 1), radius, color);
	}

	/// Draws the frustum whose clip-to-world matrix is given.
	public void Frustum(Matrix4 invViewProj, Color color)
	{
		Vector3[8] c = default;
		let zNear = Gfx.HomogeneousDepth ? -1.0f : 0.0f;
		for (int i < 8)
		{
			c[i] = invViewProj.Project(.((i & 1) != 0 ? 1.0f : -1.0f, (i & 2) != 0 ? 1.0f : -1.0f, (i & 4) != 0 ? 1.0f : zNear));
		}
		Line(c[0], c[1], color);
		Line(c[2], c[3], color);
		Line(c[4], c[5], color);
		Line(c[6], c[7], color);
		Line(c[0], c[2], color);
		Line(c[1], c[3], color);
		Line(c[4], c[6], color);
		Line(c[5], c[7], color);
		Line(c[0], c[4], color);
		Line(c[1], c[5], color);
		Line(c[2], c[6], color);
		Line(c[3], c[7], color);
	}

	/// Ground grid on the XZ plane centred near a point.
	public void Grid(Vector3 around, int halfCells, float cellSize, Color minor, Color major)
	{
		let cx = Math.Floor(around.x / (cellSize * 10)) * cellSize * 10;
		let cz = Math.Floor(around.z / (cellSize * 10)) * cellSize * 10;
		let extent = halfCells * cellSize;
		for (int i = -halfCells; i <= halfCells; i++)
		{
			let offset = i * cellSize;
			let color = (i % 10 == 0) ? major : minor;
			Line(.(cx + offset, 0, cz - extent), .(cx + offset, 0, cz + extent), color);
			Line(.(cx - extent, 0, cz + offset), .(cx + extent, 0, cz + offset), color);
		}
	}
}

/// Lines drawn from gameplay code; visible in every view for one frame.
static class DebugDraw
{
	public static LineBatch Lines = new .() ~ delete _;

	/// Draws a line this frame, in the game and the editor.
	public static void Line(Vector3 a, Vector3 b, Color color) => Lines.Line(a, b, color);
	/// Draws a box's edges this frame.
	public static void Box(Bounds bounds, Color color) => Lines.Box(bounds, color);
	/// Draws a sphere's outline this frame.
	public static void Sphere(Vector3 center, float radius, Color color) => Lines.Sphere(center, radius, color);
}

/// Editor-only helpers; drawn in the Scene view and never in the Game view or a built player.
static class Gizmos
{
	/// Lines to draw in the Scene view this frame; cleared after every frame.
	public static LineBatch Lines = new .() ~ delete _;
	/// Filled, usually see-through shapes; add them with Triangle or Quad.
	public static LineBatch Triangles = new .() ~ delete _;
	/// Lines drawn over everything, seen through whatever is in front of them (a character's bones).
	public static LineBatch OnTopLines = new .() ~ delete _;
	/// Filled shapes drawn over everything, under OnTopLines (put their outlines there).
	public static LineBatch OnTopTriangles = new .() ~ delete _;
}
