using System;
using Tallow;

namespace {NAMESPACE};

static class DemoMeshes
{
	public static Mesh Sheet(int cells, float size)
	{
		let mesh = new Mesh();
		for (int z <= cells)
		{
			for (int x <= cells)
				mesh.AddVertex(.((x / (float)cells - 0.5f) * size, 0, (z / (float)cells - 0.5f) * size), .Up, .White, .(x / (float)cells, z / (float)cells));
		}
		for (int z < cells)
		{
			for (int x < cells)
			{
				let a = (uint32)(z * (cells + 1) + x);
				mesh.AddTriangle(a, a + (uint32)cells + 1, a + 1);
				mesh.AddTriangle(a + 1, a + (uint32)cells + 1, a + (uint32)cells + 2);
			}
		}
		return mesh;
	}

	/// A level sheet pinned along its far edge (its last row, z = +size/2): the rest swings down and hangs from it.
	/// A box, half its size each way, each face cut into `cells` squares across (so it can dent and bend).
	public static Mesh Box(Vector3 half, int cells)
	{
		let mesh = new Mesh();
		for (int face < 6)
		{
			let axis = face / 2;
			let sign = (face % 2 == 0) ? 1.0f : -1.0f;
			let start = (uint32)mesh.Vertices.Count;
			for (int j <= cells)
			{
				for (int i <= cells)
				{
					float[3] p = default;
					p[axis] = sign;
					p[(axis + 1) % 3] = i / (float)cells * 2 - 1;
					p[(axis + 2) % 3] = j / (float)cells * 2 - 1;
					float[3] n = default;
					n[axis] = sign;
					mesh.AddVertex(.(p[0] * half.x, p[1] * half.y, p[2] * half.z), .(n[0], n[1], n[2]), .White, .(i / (float)cells, j / (float)cells));
				}
			}
			for (int j < cells)
			{
				for (int i < cells)
				{
					let a = start + (uint32)(j * (cells + 1) + i);
					let c = a + (uint32)cells + 1;
					// Wound to face outward on either side.
					if (sign > 0)
					{
						mesh.AddTriangle(a, a + 1, c);
						mesh.AddTriangle(a + 1, c + 1, c);
					}
					else
					{
						mesh.AddTriangle(a, c, a + 1);
						mesh.AddTriangle(a + 1, c, c + 1);
					}
				}
			}
		}
		return mesh;
	}

}
