using System;
using System.Collections;

namespace Tallow;

/// The shapes a model starts from, and the blocks maps are roughed out with. Each stands on its base at the origin,
/// centred across it, with its faces pointing outwards and Auto texture coordinates.
static class MeshShapes
{
	public enum Kind
	{
		Box,
		Wedge,
		Stairs,
		Cylinder,
		Cone,
		Sphere,
		Torus,
		Arch,
		Plane,
		Prism,
		Pipe,
		Corner
	}

	public static readonly StringView[?] Names = .("Box", "Ramp", "Stairs", "Cylinder", "Cone", "Sphere", "Torus", "Arch", "Plane", "Prism", "Pipe", "Corner Wall");

	/// The settings a shape takes. Size is its width (X), height (Y) and depth (Z); the rest apply to some shapes.
	public struct Settings
	{
		public Vector3 size = .(1, 1, 1);
		/// Sides round a cylinder, cone, sphere, torus, pipe or arch.
		public int32 sides = 12;
		/// Steps of a staircase, rings of a sphere or torus.
		public int32 steps = 6;
		/// Wall thickness of a pipe, arch or corner wall; tube thickness of a torus.
		public float thickness = 0.2f;
		/// Smooth faces (round shapes only).
		public bool smooth = false;

		public this()
		{
		}
	}

	public static EditMesh Create(Kind kind, Settings settings)
	{
		let mesh = new EditMesh();
		let s = settings.size;
		switch (kind)
		{
		case .Box: AddBox(mesh, .(-s.x / 2, 0, -s.z / 2), .(s.x / 2, s.y, s.z / 2));
		case .Wedge: Wedge(mesh, s);
		case .Stairs: Stairs(mesh, s, Math.Max(settings.steps, 1));
		case .Cylinder: Cylinder(mesh, s, Math.Max(settings.sides, 3), 1, settings.smooth);
		case .Cone: Cylinder(mesh, s, Math.Max(settings.sides, 3), 0, settings.smooth);
		case .Sphere: Sphere(mesh, s, Math.Max(settings.sides, 3), Math.Max(settings.steps, 2), settings.smooth);
		case .Torus: Torus(mesh, s, Math.Max(settings.sides, 3), Math.Max(settings.steps, 3), settings.thickness, settings.smooth);
		case .Arch: Arch(mesh, s, Math.Max(settings.sides, 2), settings.thickness);
		case .Plane: Plane(mesh, s);
		case .Prism: Cylinder(mesh, s, 3, 1, false);
		case .Pipe: Pipe(mesh, s, Math.Max(settings.sides, 3), settings.thickness, settings.smooth);
		case .Corner: Corner(mesh, s, settings.thickness);
		}
		MeshOps.ConformNormals(mesh);
		return mesh;
	}

	/// Adds a closed box between two corners.
	public static void AddBox(EditMesh mesh, Vector3 min, Vector3 max)
	{
		let b = (int32)mesh.positions.Count;
		for (int i < 8)
			mesh.AddVertex(.((i & 1) != 0 ? max.x : min.x, (i & 2) != 0 ? max.y : min.y, (i & 4) != 0 ? max.z : min.z));
		mesh.AddFace(b + 0, b + 2, b + 3, b + 1); // -Z
		mesh.AddFace(b + 4, b + 5, b + 7, b + 6); // +Z
		mesh.AddFace(b + 0, b + 4, b + 6, b + 2); // -X
		mesh.AddFace(b + 1, b + 3, b + 7, b + 5); // +X
		mesh.AddFace(b + 2, b + 6, b + 7, b + 3); // +Y
		mesh.AddFace(b + 0, b + 1, b + 5, b + 4); // -Y
	}

	/// A ramp rising from the front (-Z) to full height at the back (+Z).
	static void Wedge(EditMesh mesh, Vector3 s)
	{
		let x = s.x / 2, z = s.z / 2;
		let a = mesh.AddVertex(.(-x, 0, -z)), b = mesh.AddVertex(.(x, 0, -z));
		let c = mesh.AddVertex(.(-x, 0, z)), d = mesh.AddVertex(.(x, 0, z));
		let e = mesh.AddVertex(.(-x, s.y, z)), f = mesh.AddVertex(.(x, s.y, z));
		mesh.AddFace(a, b, d, c);
		mesh.AddFace(c, d, f, e);
		mesh.AddFace(a, e, f, b);
		mesh.AddFace(a, c, e);
		mesh.AddFace(b, f, d);
	}

	/// Steps climbing from the front (-Z) to the back, each a solid block down to the ground, joined into one solid.
	static void Stairs(EditMesh mesh, Vector3 s, int steps)
	{
		let x = s.x / 2;
		let rise = s.y / steps, run = s.z / steps;
		// The side outline, as a polygon in (z, y): up and along each step, then down the back and along the ground.
		let outline = scope List<Vector2>();
		outline.Add(.(-s.z / 2, 0));
		for (int i < steps)
		{
			let z0 = -s.z / 2 + i * run;
			outline.Add(.(z0, (i + 1) * rise));
			outline.Add(.(z0 + run, (i + 1) * rise));
		}
		outline.Add(.(s.z / 2, 0));
		Extrude2D(mesh, outline, -x, x);
	}

	/// A prism from a side outline in (z, y), stretched across x from x0 to x1: the two ends and a face for each side.
	static void Extrude2D(EditMesh mesh, List<Vector2> outline, float x0, float x1)
	{
		let n = (int32)outline.Count;
		let b = (int32)mesh.positions.Count;
		for (let p in outline)
			mesh.AddVertex(.(x0, p.y, p.x));
		for (let p in outline)
			mesh.AddVertex(.(x1, p.y, p.x));
		let left = new EditFace();
		let right = new EditFace();
		for (int32 i < n)
		{
			left.Add(b + i);
			right.Add(b + n + (n - 1 - i));
		}
		mesh.faces.Add(left);
		mesh.faces.Add(right);
		for (int32 i < n)
		{
			let j = (i + 1) % n;
			mesh.AddFace(b + i, b + j, b + n + j, b + n + i);
		}
	}

	/// A cylinder (top 1) or cone (top 0) of the given number of sides.
	static void Cylinder(EditMesh mesh, Vector3 s, int sides, float top, bool smooth)
	{
		let b = (int32)mesh.positions.Count;
		for (int i < sides)
		{
			let angle = Math.PI_f * 2 * i / sides;
			mesh.AddVertex(.(Math.Cos(angle) * s.x / 2, 0, Math.Sin(angle) * s.z / 2));
		}
		if (top > 0)
		{
			for (int i < sides)
			{
				let angle = Math.PI_f * 2 * i / sides;
				mesh.AddVertex(.(Math.Cos(angle) * s.x / 2 * top, s.y, Math.Sin(angle) * s.z / 2 * top));
			}
			for (int32 i < (int32)sides)
			{
				let j = (i + 1) % (int32)sides;
				let face = mesh.AddFace(b + i, b + j, b + (int32)sides + j, b + (int32)sides + i);
				face.smooth = smooth;
			}
			let cap = new EditFace();
			for (int32 i < (int32)sides)
				cap.Add(b + (int32)sides + i);
			mesh.faces.Add(cap);
		}
		else
		{
			let apex = mesh.AddVertex(.(0, s.y, 0));
			for (int32 i < (int32)sides)
			{
				let face = mesh.AddFace(b + i, b + (i + 1) % (int32)sides, apex);
				face.smooth = smooth;
			}
		}
		let bottom = new EditFace();
		for (int32 i < (int32)sides)
			bottom.Add(b + i);
		mesh.faces.Add(bottom);
	}

	static void Sphere(EditMesh mesh, Vector3 s, int sides, int rings, bool smooth)
	{
		let b = (int32)mesh.positions.Count;
		let bottom = mesh.AddVertex(.(0, 0, 0));
		for (int r = 1; r < rings; r++)
		{
			let phi = Math.PI_f * r / rings;
			let y = (1 - Math.Cos(phi)) * 0.5f * s.y;
			let radius = Math.Sin(phi) * 0.5f;
			for (int i < sides)
			{
				let angle = Math.PI_f * 2 * i / sides;
				mesh.AddVertex(.(Math.Cos(angle) * radius * s.x, y, Math.Sin(angle) * radius * s.z));
			}
		}
		let top = mesh.AddVertex(.(0, s.y, 0));
		int32 Ring(int r, int i) => b + 1 + (int32)((r - 1) * sides + (i % sides));
		for (int i < sides)
		{
			mesh.AddFace(bottom, Ring(1, i + 1), Ring(1, i)).smooth = smooth;
			mesh.AddFace(top, Ring(rings - 1, i), Ring(rings - 1, i + 1)).smooth = smooth;
		}
		for (int r = 1; r + 1 < rings; r++)
		{
			for (int i < sides)
				mesh.AddFace(Ring(r, i), Ring(r, i + 1), Ring(r + 1, i + 1), Ring(r + 1, i)).smooth = smooth;
		}
	}

	static void Torus(EditMesh mesh, Vector3 s, int sides, int rings, float thickness, bool smooth)
	{
		let b = (int32)mesh.positions.Count;
		let tube = Math.Clamp(thickness, 0.01f, 0.49f) * Math.Min(s.x, s.z) * 0.5f;
		let major = Math.Min(s.x, s.z) * 0.5f - tube;
		let lift = s.y * 0.5f;
		for (int i < sides)
		{
			let around = Math.PI_f * 2 * i / sides;
			for (int j < rings)
			{
				let angle = Math.PI_f * 2 * j / rings;
				let r = major + Math.Cos(angle) * tube;
				mesh.AddVertex(.(Math.Cos(around) * r * s.x / Math.Min(s.x, s.z), lift + Math.Sin(angle) * s.y * 0.5f, Math.Sin(around) * r * s.z / Math.Min(s.x, s.z)));
			}
		}
		int32 At(int i, int j) => b + (int32)((i % sides) * rings + (j % rings));
		for (int i < sides)
		{
			for (int j < rings)
				mesh.AddFace(At(i, j), At(i + 1, j), At(i + 1, j + 1), At(i, j + 1)).smooth = smooth;
		}
	}

	/// A wall with a round-topped opening through it (along Z), the posts and the wall above it the thickness given.
	static void Arch(EditMesh mesh, Vector3 s, int sides, float thickness)
	{
		let wall = Math.Clamp(thickness, 0.01f, s.x * 0.45f);
		let inner = s.x / 2 - wall;
		// The opening: straight up to the springing line, then a half circle (squashed if the wall is low).
		let radius = Math.Min(inner, Math.Max(s.y - wall, 0.01f) * 0.5f);
		let springing = Math.Max(s.y - wall - radius, 0);
		let curve = scope List<Vector2>();
		for (int k <= sides)
		{
			let angle = Math.PI_f - Math.PI_f * k / sides;
			curve.Add(.(Math.Cos(angle) * inner, springing + Math.Sin(angle) * radius));
		}
		// The outline, all the way round, with a point on the top edge above each point of the curve.
		let outline = scope List<Vector2>();
		outline.Add(.(-s.x / 2, 0));
		outline.Add(.(-s.x / 2, s.y));
		for (let c in curve)
			outline.Add(.(c.x, s.y));
		outline.Add(.(s.x / 2, s.y));
		outline.Add(.(s.x / 2, 0));
		outline.Add(.(inner, 0));
		for (int k = curve.Count - 1; k >= 0; k--)
			outline.Add(curve[k]);
		outline.Add(.(-inner, 0));
		let n = (int32)outline.Count;
		let b = (int32)mesh.positions.Count;
		for (let p in outline)
			mesh.AddVertex(.(p.x, p.y, -s.z / 2));
		for (let p in outline)
			mesh.AddVertex(.(p.x, p.y, s.z / 2));
		int32 At(Vector2 point, int32 side)
		{
			for (int32 i < n)
			{
				if ((outline[i] - point).LengthSquared < 1.0e-10f)
					return b + side * n + i;
			}
			return b;
		}
		for (int32 side < 2)
		{
			// The two posts, then a strip above each step of the curve.
			mesh.AddFace(At(.(-s.x / 2, 0), side), At(.(-s.x / 2, s.y), side), At(.(curve[0].x, s.y), side), At(curve[0], side), At(.(-inner, 0), side));
			mesh.AddFace(At(.(inner, 0), side), At(curve.Back, side), At(.(curve.Back.x, s.y), side), At(.(s.x / 2, s.y), side), At(.(s.x / 2, 0), side));
			for (int k < sides)
				mesh.AddFace(At(curve[k], side), At(.(curve[k].x, s.y), side), At(.(curve[k + 1].x, s.y), side), At(curve[k + 1], side));
		}
		for (int32 i < n)
		{
			let j = (i + 1) % n;
			mesh.AddFace(b + i, b + n + i, b + n + j, b + j);
		}
		mesh.Weld();
		MeshOps.ConformNormals(mesh);
		mesh.MergeFlatNeighbours();
	}

	static void Plane(EditMesh mesh, Vector3 s)
	{
		let x = s.x / 2, z = s.z / 2;
		let a = mesh.AddVertex(.(-x, 0, -z)), b = mesh.AddVertex(.(-x, 0, z)), c = mesh.AddVertex(.(x, 0, z)), d = mesh.AddVertex(.(x, 0, -z));
		mesh.AddFace(a, b, c, d);
	}

	/// A tube open along Y, its wall the thickness given.
	static void Pipe(EditMesh mesh, Vector3 s, int sides, float thickness, bool smooth)
	{
		let b = (int32)mesh.positions.Count;
		let wall = Math.Clamp(thickness, 0.01f, Math.Min(s.x, s.z) * 0.49f);
		for (int ring < 4)
		{
			let outer = ring < 2;
			let y = (ring == 0 || ring == 3) ? 0 : s.y;
			for (int i < sides)
			{
				let angle = Math.PI_f * 2 * i / sides;
				let rx = outer ? s.x / 2 : s.x / 2 - wall, rz = outer ? s.z / 2 : s.z / 2 - wall;
				mesh.AddVertex(.(Math.Cos(angle) * rx, y, Math.Sin(angle) * rz));
			}
		}
		int32 At(int ring, int i) => b + (int32)(ring * sides + i % sides);
		for (int i < sides)
		{
			mesh.AddFace(At(0, i), At(0, i + 1), At(1, i + 1), At(1, i)).smooth = smooth;
			mesh.AddFace(At(1, i), At(1, i + 1), At(2, i + 1), At(2, i));
			mesh.AddFace(At(2, i), At(2, i + 1), At(3, i + 1), At(3, i)).smooth = smooth;
			mesh.AddFace(At(3, i), At(3, i + 1), At(0, i + 1), At(0, i));
		}
	}

	/// Two walls meeting at a right angle in the back-left corner (an L seen from above).
	static void Corner(EditMesh mesh, Vector3 s, float thickness)
	{
		let wall = Math.Clamp(thickness, 0.01f, Math.Min(s.x, s.z) * 0.95f);
		let x0 = -s.x / 2, x1 = s.x / 2, z0 = -s.z / 2, z1 = s.z / 2;
		// The L outline seen from above, in (x, z), as a prism up Y.
		let outline = scope List<Vector2>();
		outline.Add(.(x0, z0));
		outline.Add(.(x0, z1));
		outline.Add(.(x1, z1));
		outline.Add(.(x1, z1 - wall));
		outline.Add(.(x0 + wall, z1 - wall));
		outline.Add(.(x0 + wall, z0));
		let n = (int32)outline.Count;
		let b = (int32)mesh.positions.Count;
		for (let p in outline)
			mesh.AddVertex(.(p.x, 0, p.y));
		for (let p in outline)
			mesh.AddVertex(.(p.x, s.y, p.y));
		let bottom = new EditFace();
		let top = new EditFace();
		for (int32 i < n)
		{
			bottom.Add(b + i);
			top.Add(b + n + (n - 1 - i));
		}
		mesh.faces.Add(bottom);
		mesh.faces.Add(top);
		for (int32 i < n)
		{
			let j = (i + 1) % n;
			mesh.AddFace(b + i, b + j, b + n + j, b + n + i);
		}
	}
}
