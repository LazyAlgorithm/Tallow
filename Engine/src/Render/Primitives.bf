using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Built-in primitive meshes, all centred on the origin with unit size.
static class Primitives
{
	public static Mesh CreateCube()
	{
		let mesh = new Mesh();
		mesh.Name.Set("Cube");
		let h = 0.5f;
		let c = Color.White;
		mesh.AddQuad(.(-h, -h, -h), .(-h, h, -h), .(h, h, -h), .(h, -h, -h), c); // back (-Z)
		mesh.AddQuad(.(h, -h, h), .(h, h, h), .(-h, h, h), .(-h, -h, h), c); // front (+Z)
		mesh.AddQuad(.(-h, -h, h), .(-h, h, h), .(-h, h, -h), .(-h, -h, -h), c); // left
		mesh.AddQuad(.(h, -h, -h), .(h, h, -h), .(h, h, h), .(h, -h, h), c); // right
		mesh.AddQuad(.(-h, h, -h), .(-h, h, h), .(h, h, h), .(h, h, -h), c); // top
		mesh.AddQuad(.(-h, -h, h), .(-h, -h, -h), .(h, -h, -h), .(h, -h, h), c); // bottom
		mesh.Upload();
		return mesh;
	}

	/// 10x10 unit plane facing +Y, like Unity's built-in plane.
	public static Mesh CreatePlane()
	{
		let mesh = new Mesh();
		mesh.Name.Set("Plane");
		let h = 5.0f;
		mesh.AddQuad(.(-h, 0, -h), .(-h, 0, h), .(h, 0, h), .(h, 0, -h), .White);
		mesh.Upload();
		return mesh;
	}

	public static Mesh CreateQuad()
	{
		let mesh = new Mesh();
		mesh.Name.Set("Quad");
		let h = 0.5f;
		mesh.AddQuad(.(-h, -h, 0), .(-h, h, 0), .(h, h, 0), .(h, -h, 0), .White);
		mesh.Upload();
		return mesh;
	}

	/// Low-poly UV sphere of diameter 1.
	public static Mesh CreateSphere(int segments = 16, int rings = 10)
	{
		let mesh = new Mesh();
		mesh.Name.Set("Sphere");
		for (int r = 0; r <= rings; r++)
		{
			let v = (float)r / rings;
			let phi = v * Mathf.PI;
			for (int s = 0; s <= segments; s++)
			{
				let u = (float)s / segments;
				let theta = u * Mathf.PI * 2.0f;
				let n = Vector3(Math.Sin(phi) * Math.Cos(theta), Math.Cos(phi), Math.Sin(phi) * Math.Sin(theta));
				mesh.AddVertex(n * 0.5f, n, .White, .(u, v));
			}
		}
		let stride = (uint32)segments + 1;
		for (uint32 r = 0; r < (uint32)rings; r++)
		{
			for (uint32 s = 0; s < (uint32)segments; s++)
			{
				let a = r * stride + s;
				let b = a + stride;
				mesh.AddTriangle(a, a + 1, b);
				mesh.AddTriangle(a + 1, b + 1, b);
			}
		}
		mesh.Upload();
		return mesh;
	}

	/// Cylinder of diameter 1 and height 2 (Unity proportions). topRadius 0 makes a cone.
	public static Mesh CreateCylinder(int segments = 16, float topRadius = 0.5f)
	{
		let mesh = new Mesh();
		mesh.Name.Set(topRadius > 0 ? "Cylinder" : "Cone");
		let bottomRadius = 0.5f;
		let slope = (bottomRadius - topRadius) / 2.0f;
		for (int s = 0; s <= segments; s++)
		{
			let u = (float)s / segments;
			let theta = u * Mathf.PI * 2.0f;
			let dir = Vector3(Math.Cos(theta), 0, Math.Sin(theta));
			let n = Vector3(dir.x, slope, dir.z).Normalized;
			mesh.AddVertex(.(dir.x * bottomRadius, -1, dir.z * bottomRadius), n, .White, .(u, 1));
			mesh.AddVertex(.(dir.x * topRadius, 1, dir.z * topRadius), n, .White, .(u, 0));
		}
		for (uint32 s = 0; s < (uint32)segments; s++)
		{
			let a = s * 2;
			mesh.AddTriangle(a, a + 1, a + 2);
			mesh.AddTriangle(a + 1, a + 3, a + 2);
		}
		AddCap(mesh, segments, -1, bottomRadius, false);
		if (topRadius > 0)
			AddCap(mesh, segments, 1, topRadius, true);
		mesh.Upload();
		return mesh;
	}

	static void AddCap(Mesh mesh, int segments, float y, float radius, bool top)
	{
		let n = Vector3(0, top ? 1 : -1, 0);
		let center = mesh.AddVertex(.(0, y, 0), n, .White, .(0.5f, 0.5f));
		for (int s = 0; s <= segments; s++)
		{
			let theta = (float)s / segments * Mathf.PI * 2.0f;
			mesh.AddVertex(.(Math.Cos(theta) * radius, y, Math.Sin(theta) * radius), n, .White, .(0.5f, 0.5f));
		}
		for (uint32 s = 0; s < (uint32)segments; s++)
		{
			if (top)
				mesh.AddTriangle(center, center + 2 + s, center + 1 + s);
			else
				mesh.AddTriangle(center, center + 1 + s, center + 2 + s);
		}
	}

	/// Capsule of diameter 1 and total height 2.
	public static Mesh CreateCapsule(int segments = 16, int rings = 6)
	{
		let mesh = new Mesh();
		mesh.Name.Set("Capsule");
		let radius = 0.5f;
		let halfHeight = 0.5f;
		let total = rings * 2 + 1;
		for (int r = 0; r <= total; r++)
		{
			// The top hemisphere uses the first rings + 1 rows, the bottom the rest.
			let upper = r <= rings;
			let ringIndex = upper ? r : r - 1;
			let phi = (float)ringIndex / (rings * 2) * Mathf.PI;
			let offset = upper ? halfHeight : -halfHeight;
			for (int s = 0; s <= segments; s++)
			{
				let u = (float)s / segments;
				let theta = u * Mathf.PI * 2.0f;
				let n = Vector3(Math.Sin(phi) * Math.Cos(theta), Math.Cos(phi), Math.Sin(phi) * Math.Sin(theta));
				mesh.AddVertex(n * radius + Vector3(0, offset, 0), n, .White, .(u, (float)r / total));
			}
		}
		let stride = (uint32)segments + 1;
		for (uint32 r = 0; r < (uint32)total; r++)
		{
			for (uint32 s = 0; s < (uint32)segments; s++)
			{
				let a = r * stride + s;
				let b = a + stride;
				mesh.AddTriangle(a, a + 1, b);
				mesh.AddTriangle(a + 1, b + 1, b);
			}
		}
		mesh.Upload();
		return mesh;
	}

	// ---- plants for Foliage: their foot is at the origin, so that they bend in the wind from the ground up ----

	/// A ring of triangles between two heights: a trunk, or with a point at the top a cone of needles.
	static void AddTaper(Mesh mesh, float y0, float r0, Color c0, float y1, float r1, Color c1, int segments, float turn = 0)
	{
		let first = (uint32)mesh.Vertices.Count;
		let slope = (r0 - r1) / Math.Max(y1 - y0, 0.001f);
		for (int s = 0; s <= segments; s++)
		{
			let theta = (float)s / segments * Mathf.PI * 2.0f + turn;
			let dir = Vector3(Math.Cos(theta), 0, Math.Sin(theta));
			let n = Vector3(dir.x, slope, dir.z).Normalized;
			mesh.AddVertex(.(dir.x * r0, y0, dir.z * r0), n, c0, .((float)s / segments, 1));
			mesh.AddVertex(.(dir.x * r1, y1, dir.z * r1), n, c1, .((float)s / segments, 0));
		}
		for (uint32 s = 0; s < (uint32)segments; s++)
		{
			let a = first + s * 2;
			mesh.AddTriangle(a, a + 1, a + 2);
			mesh.AddTriangle(a + 1, a + 3, a + 2);
		}
	}

	/// A rough ball of leaves, darker underneath.
	static void AddLeaves(Mesh mesh, Vector3 center, Vector3 radius, Color dark, Color light, int segments = 7, int rings = 4, float turn = 0)
	{
		let first = (uint32)mesh.Vertices.Count;
		for (int r = 0; r <= rings; r++)
		{
			let phi = (float)r / rings * Mathf.PI;
			for (int s = 0; s <= segments; s++)
			{
				let theta = (float)s / segments * Mathf.PI * 2.0f + turn;
				// Pushed in and out a little from row to row, so that it is a clump and not a ball.
				let lump = 1.0f + (((r * 7 + (s % segments) * 13) % 5) - 2) * 0.05f;
				let n = Vector3(Math.Sin(phi) * Math.Cos(theta), Math.Cos(phi), Math.Sin(phi) * Math.Sin(theta));
				let shade = Mathf.Clamp01(n.y * 0.5f + 0.5f);
				let color = Color(Mathf.Lerp(dark.r, light.r, shade), Mathf.Lerp(dark.g, light.g, shade), Mathf.Lerp(dark.b, light.b, shade), 1);
				mesh.AddVertex(center + Vector3(n.x * radius.x, n.y * radius.y, n.z * radius.z) * lump, n, color, .((float)s / segments, (float)r / rings));
			}
		}
		let row = (uint32)segments + 1;
		for (uint32 r = 0; r < (uint32)rings; r++)
		{
			for (uint32 s = 0; s < (uint32)segments; s++)
			{
				let a = first + r * row + s;
				mesh.AddTriangle(a, a + 1, a + row);
				mesh.AddTriangle(a + 1, a + row + 1, a + row);
			}
		}
	}

	/// A tuft of grass about 45 cm high: nine blades leaning outwards, dark at the root and light at the tip.
	public static Mesh CreateGrass()
	{
		let mesh = new Mesh();
		mesh.Name.Set("Grass");
		let root = Color(0.13f, 0.27f, 0.08f, 1), middle = Color(0.26f, 0.48f, 0.14f, 1), tip = Color(0.50f, 0.74f, 0.27f, 1);
		for (int blade < 9)
		{
			let theta = blade * 2.39996f; // the golden angle: no two blades in line
			let ring = blade == 0 ? 0.0f : 0.035f + (blade % 3) * 0.03f;
			let height = 0.32f + ((blade * 5) % 4) * 0.055f;
			let lean = 0.06f + ((blade * 3) % 5) * 0.03f;
			let dir = Vector3(Math.Cos(theta), 0, Math.Sin(theta));
			let side = Vector3(-dir.z, 0, dir.x);
			let foot = dir * ring;
			let half = 0.022f;
			// Blades are lit as the ground under them is, which keeps a field of them from flickering.
			let n = (Vector3.Up + dir * 0.35f).Normalized;
			let a = mesh.AddVertex(foot - side * half, n, root, .(0, 1));
			mesh.AddVertex(foot + side * half, n, root, .(1, 1));
			mesh.AddVertex(foot + dir * lean * 0.45f + side * half * 0.7f + Vector3(0, height * 0.55f, 0), n, middle, .(1, 0.45f));
			mesh.AddVertex(foot + dir * lean * 0.45f - side * half * 0.7f + Vector3(0, height * 0.55f, 0), n, middle, .(0, 0.45f));
			mesh.AddVertex(foot + dir * lean + Vector3(0, height, 0), n, tip, .(0.5f, 0));
			mesh.AddTriangle(a, a + 1, a + 2);
			mesh.AddTriangle(a, a + 2, a + 3);
			mesh.AddTriangle(a + 3, a + 2, a + 4);
		}
		mesh.RecalculateBounds();
		mesh.Upload();
		return mesh;
	}

	/// A low bush about a metre across.
	public static Mesh CreateBush()
	{
		let mesh = new Mesh();
		mesh.Name.Set("Bush");
		let dark = Color(0.10f, 0.24f, 0.08f, 1), light = Color(0.33f, 0.56f, 0.20f, 1);
		AddLeaves(mesh, .(0, 0.32f, 0), .(0.5f, 0.36f, 0.5f), dark, light, 7, 4);
		AddLeaves(mesh, .(0.3f, 0.26f, 0.12f), .(0.34f, 0.28f, 0.34f), dark, light, 6, 3, 0.7f);
		AddLeaves(mesh, .(-0.22f, 0.24f, -0.26f), .(0.32f, 0.26f, 0.32f), dark, light, 6, 3, 1.9f);
		mesh.RecalculateBounds();
		mesh.Upload();
		return mesh;
	}

	/// A tree about five metres high: a pine (stacked cones of needles) or a broadleaf (a trunk under clumps of leaves).
	public static Mesh CreateTree(bool pine)
	{
		let mesh = new Mesh();
		mesh.Name.Set(pine ? "Pine" : "Tree");
		let bark = Color(0.27f, 0.19f, 0.12f, 1), barkTop = Color(0.36f, 0.26f, 0.17f, 1);
		if (pine)
		{
			let dark = Color(0.06f, 0.20f, 0.10f, 1), light = Color(0.18f, 0.40f, 0.20f, 1);
			AddTaper(mesh, 0, 0.16f, bark, 1.6f, 0.11f, barkTop, 6);
			AddTaper(mesh, 1.0f, 1.25f, dark, 2.9f, 0.0f, light, 8);
			AddTaper(mesh, 2.0f, 1.0f, dark, 3.9f, 0.0f, light, 8, 0.4f);
			AddTaper(mesh, 3.0f, 0.72f, dark, 5.0f, 0.0f, light, 8, 0.8f);
		}
		else
		{
			let dark = Color(0.11f, 0.26f, 0.09f, 1), light = Color(0.36f, 0.60f, 0.22f, 1);
			AddTaper(mesh, 0, 0.2f, bark, 2.6f, 0.12f, barkTop, 6);
			AddLeaves(mesh, .(0, 3.5f, 0), .(1.5f, 1.25f, 1.5f), dark, light, 8, 5);
			AddLeaves(mesh, .(0.9f, 3.0f, 0.35f), .(0.95f, 0.8f, 0.95f), dark, light, 7, 4, 0.9f);
			AddLeaves(mesh, .(-0.75f, 3.1f, -0.6f), .(1.0f, 0.85f, 1.0f), dark, light, 7, 4, 2.2f);
			AddLeaves(mesh, .(-0.15f, 4.35f, 0.3f), .(0.95f, 0.75f, 0.95f), dark, light, 7, 4, 3.4f);
		}
		mesh.RecalculateBounds();
		mesh.Upload();
		return mesh;
	}
}
