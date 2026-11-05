using System;
using System.Collections;

namespace Tallow;

/// Second texture coordinates (MeshVertex.uv2) for baked lighting (docs/baked-lighting.md): every triangle a place of
/// its own in a square, none overlapping, so a lightmap can hold a colour for each point of the surface.
///
/// Triangles that touch and face within 60 degrees of each other are laid flat together as one chart, the charts are
/// packed into the square with a gap round each, and vertices on the seams between charts are split. Only + - * / and
/// square roots are used, in a fixed order, so the same mesh gets the same coordinates on every machine: the game
/// makes them again when it loads, and they match the lightmaps the editor baked.
static class LightmapUV
{
	/// The gap round each chart, as a share of the square (two texels at 64 texels across).
	public const float Margin = 1.0f / 32.0f;
	/// Triangles join a chart while they face within this of its first one (cos 60 degrees).
	const float JoinCosine = 0.5f;

	/// Makes sure a renderer's meshes have lightmap coordinates, all of its parts laid out in one square together.
	/// False when they cannot have them (a mesh rewritten every frame, or one drawing another's vertices).
	public static bool Ensure(Span<Mesh> meshes)
	{
		var ready = true;
		for (let mesh in meshes)
		{
			if (mesh == null || mesh.IsDynamic || mesh.VertexSource != null || mesh.Indices.Count < 3)
				return false;
			ready &= mesh.LightmapUVs;
		}
		if (ready)
			return true;
		Generate(meshes, .(1, 1, 1));
		for (let mesh in meshes)
		{
			if (mesh.HasGpuData)
				mesh.Upload();
		}
		return true;
	}

	public static bool Ensure(Mesh mesh)
	{
		var one = mesh;
		return Ensure(Span<Mesh>(&one, 1));
	}

	/// Copies of a mesh (and the other parts of its model) laid out for one stretch.
	public class Copies
	{
		public Vector3 scale;
		public int sourceVertices, sourceIndices;
		public List<Mesh> meshes = new .() ~ DeleteContainerAndItems!(_);
	}

	/// How an object stretches its mesh, as shares of its longest axis in steps of 1/256 (so that the game gets
	/// exactly what the editor did from the same transform).
	public static Vector3 Stretch(Matrix4 world)
	{
		let x = world.TransformDirection(.(1, 0, 0)).Length, y = world.TransformDirection(.(0, 1, 0)).Length, z = world.TransformDirection(.(0, 0, 1)).Length;
		let longest = Math.Max(x, Math.Max(y, z));
		if (longest <= 0)
			return .(1, 1, 1);
		float Step(float v) => Math.Max(Math.Round(v / longest * 256), 1) / 256;
		return .(Step(x), Step(y), Step(z));
	}

	/// The meshes a lightmapped renderer is drawn and baked with, one for each of its parts: its own meshes given
	/// lightmap coordinates, or, when the object stretches them unevenly (a cube made into a wall), copies laid out
	/// for that stretch, so that a wall's broad faces get the texels rather than its thin edges. Coordinates that
	/// came with a model are used as they are. False when it cannot have a lightmap (a mesh rewritten every frame, or
	/// one drawing another's vertices).
	public static bool MeshesFor(MeshRenderer renderer, List<Mesh> output) => MeshesFor(renderer.Proxy, output);

	public static bool MeshesFor(RenderProxy renderer, List<Mesh> output)
	{
		output.Clear();
		let parts = renderer.DrawnParts;
		if (parts != null && parts.Count > 0)
		{
			for (let part in parts)
				output.Add(part.mesh);
		}
		else
			output.Add(renderer.ActiveMesh);
		for (let mesh in output)
		{
			if (mesh == null || mesh.IsDynamic || mesh.VertexSource != null || mesh.Indices.Count < 3)
				return false;
		}
		let stretch = Stretch(renderer.RenderMatrix);
		if (output[0].LightmapUVsFromModel || Math.Min(stretch.x, Math.Min(stretch.y, stretch.z)) > 0.8f)
			return Ensure(output);
		let source = output[0];
		var total = 0;
		for (let mesh in output)
			total += mesh.Indices.Count;
		if (source.LightmapCopies == null)
			source.LightmapCopies = new .();
		Copies found = null;
		for (let copies in source.LightmapCopies)
		{
			if (copies.scale == stretch && copies.meshes.Count == output.Count)
				found = copies;
		}
		// The model was changed since: lay it out again.
		if (found != null && (found.sourceVertices != source.Vertices.Count || found.sourceIndices != total))
		{
			source.LightmapCopies.Remove(found);
			DeleteAndNullify!(found);
		}
		if (found == null)
		{
			found = new Copies();
			found.scale = stretch;
			found.sourceVertices = source.Vertices.Count;
			found.sourceIndices = total;
			for (let mesh in output)
			{
				let copy = new Mesh();
				copy.Name.Set(mesh.Name);
				copy.Vertices.AddRange(mesh.Vertices);
				copy.Indices.AddRange(mesh.Indices);
				copy.Bounds = mesh.Bounds;
				found.meshes.Add(copy);
			}
			Generate(found.meshes, stretch);
			for (int i < found.meshes.Count)
			{
				if (output[i].HasGpuData)
					found.meshes[i].Upload();
			}
			source.LightmapCopies.Add(found);
		}
		output.Clear();
		output.AddRange(found.meshes);
		return true;
	}

	/// How far uv2 goes for one unit of the mesh's size, on average (for coordinates that came with a model).
	public static float MeasureScale(Mesh mesh)
	{
		var surface = 0.0f, flat = 0.0f;
		for (int t < mesh.Indices.Count / 3)
		{
			let a = mesh.Vertices[(int)mesh.Indices[t * 3]];
			let b = mesh.Vertices[(int)mesh.Indices[t * 3 + 1]];
			let c = mesh.Vertices[(int)mesh.Indices[t * 3 + 2]];
			let cross = Vector3.Cross(b.position - a.position, c.position - a.position);
			surface += Math.Sqrt(Vector3.Dot(cross, cross)) * 0.5f;
			let du = b.uv2 - a.uv2, dv = c.uv2 - a.uv2;
			flat += Math.Abs(du.x * dv.y - du.y * dv.x) * 0.5f;
		}
		return surface > 0 && flat > 0 ? Math.Sqrt(flat / surface) : 1;
	}

	/// A position as a dictionary key, by its exact bits (-0 and 0 the same).
	struct PositionKey : IHashable
	{
		uint32 x, y, z;

		public this(Vector3 p)
		{
			var p;
			p.x += 0;
			p.y += 0;
			p.z += 0;
			x = *(uint32*)&p.x;
			y = *(uint32*)&p.y;
			z = *(uint32*)&p.z;
		}

		public int GetHashCode() => (int)(x * 73856093 ^ y * 19349663 ^ z * 83492791);
		public static bool operator ==(PositionKey a, PositionKey b) => a.x == b.x && a.y == b.y && a.z == b.z;
	}

	struct Chart
	{
		public int32 mesh;
		public int32 first; // into the list of chart triangles
		public int32 count;
		public Vector3 axisU, axisV;
		public float minU, minV, width, height;
		public float x, y; // where it went in the square, in mesh units
	}

	/// Lays out the meshes' second coordinates (whatever they had), splitting vertices where charts meet, for the
	/// meshes stretched by `scale`. Sets Mesh.LightmapUVs and Mesh.LightmapUVScale. Does not upload.
	public static void Generate(Span<Mesh> meshes, Vector3 scale)
	{
		let charts = scope List<Chart>();
		let chartTriangles = scope List<int32>();
		let triangleChart = scope List<int32>[meshes.Length];
		defer
		{
			for (let list in triangleChart)
				delete list;
		}

		for (int32 m < (int32)meshes.Length)
		{
			let mesh = meshes[m];
			let triangleCount = mesh.Indices.Count / 3;
			let chartOf = new List<int32>(triangleCount);
			triangleChart[m] = chartOf;
			for (int i < triangleCount)
				chartOf.Add(-1);

			// Corners welded by position, so triangles whose vertices were split (flat shading) still touch.
			let weld = scope Dictionary<PositionKey, int32>();
			let corner = scope List<int32>(mesh.Indices.Count);
			for (let index in mesh.Indices)
			{
				let p = PositionKey(mesh.Vertices[(int)index].position);
				if (!weld.TryGetValue(p, var id))
				{
					id = (int32)weld.Count;
					weld[p] = id;
				}
				corner.Add(id);
			}
			// Triangles on each edge (welded corners, smaller first).
			let edges = scope Dictionary<int64, List<int32>>();
			defer
			{
				for (let list in edges.Values)
					delete list;
			}
			int64 EdgeKey(int32 a, int32 b) => a < b ? ((int64)a << 32) | b : ((int64)b << 32) | a;
			for (int32 t < (int32)triangleCount)
			{
				for (int k < 3)
				{
					let key = EdgeKey(corner[t * 3 + k], corner[t * 3 + (k + 1) % 3]);
					if (!edges.TryGetValue(key, var list))
					{
						list = new List<int32>();
						edges[key] = list;
					}
					list.Add(t);
				}
			}

			let queue = scope List<int32>();
			for (int32 seed < (int32)triangleCount)
			{
				if (chartOf[seed] >= 0)
					continue;
				let seedNormal = TriangleNormal(mesh, seed, scale, let seedArea);
				Chart chart = default;
				chart.mesh = m;
				chart.first = (int32)chartTriangles.Count;
				let chartIndex = (int32)charts.Count;
				chartOf[seed] = chartIndex;
				queue.Clear();
				queue.Add(seed);
				// Degenerate triangles stay alone (a chart of no size).
				var grow = seedArea > 1e-12f;
				for (int q = 0; q < queue.Count; q++)
				{
					let t = queue[q];
					chartTriangles.Add(t);
					if (!grow)
						continue;
					for (int k < 3)
					{
						let list = edges[EdgeKey(corner[t * 3 + k], corner[t * 3 + (k + 1) % 3])];
						for (let other in list)
						{
							if (chartOf[other] >= 0)
								continue;
							let normal = TriangleNormal(mesh, other, scale, let area);
							if (area <= 1e-12f || Vector3.Dot(normal, seedNormal) < JoinCosine)
								continue;
							chartOf[other] = chartIndex;
							queue.Add(other);
						}
					}
				}
				chart.count = (int32)chartTriangles.Count - chart.first;
				Flatten(mesh, chartTriangles, ref chart, seedNormal, seed, scale);
				charts.Add(chart);
			}
		}

		let side = Pack(charts);
		let toSquare = side > 0 ? 1.0f / side : 1.0f;

		// New vertices: one for each vertex in each chart that uses it.
		for (int32 m < (int32)meshes.Length)
		{
			let mesh = meshes[m];
			let chartOf = triangleChart[m];
			let oldVertices = scope List<MeshVertex>(mesh.Vertices.GetEnumerator());
			let made = scope Dictionary<int64, uint32>();
			mesh.Vertices.Clear();
			for (int i < mesh.Indices.Count)
			{
				let old = mesh.Indices[i];
				let chartIndex = chartOf[i / 3];
				let key = ((int64)chartIndex << 32) | old;
				if (!made.TryGetValue(key, var index))
				{
					let chart = charts[chartIndex];
					var vertex = oldVertices[(int)old];
					let u = Vector3.Dot(vertex.position * scale, chart.axisU) - chart.minU;
					let v = Vector3.Dot(vertex.position * scale, chart.axisV) - chart.minV;
					vertex.uv2 = .((chart.x + u) * toSquare, (chart.y + v) * toSquare);
					index = (uint32)mesh.Vertices.Count;
					mesh.Vertices.Add(vertex);
					made[key] = index;
				}
				mesh.Indices[i] = index;
			}
			mesh.LightmapUVs = true;
			mesh.LightmapUVScale = toSquare;
		}
	}

	static Vector3 TriangleNormal(Mesh mesh, int32 t, Vector3 scale, out float area)
	{
		let a = mesh.Vertices[(int)mesh.Indices[t * 3]].position * scale;
		let b = mesh.Vertices[(int)mesh.Indices[t * 3 + 1]].position * scale;
		let c = mesh.Vertices[(int)mesh.Indices[t * 3 + 2]].position * scale;
		// Clockwise front faces: (b - a) x (c - a) points out of the front in Tallow's left-handed space.
		let cross = Vector3.Cross(b - a, c - a);
		let length = Math.Sqrt(Vector3.Dot(cross, cross));
		area = length * 0.5f;
		return length > 0 ? cross / length : .(0, 1, 0);
	}

	/// The chart's flat axes (its first triangle's plane, along whichever of that triangle's edges boxes the chart in
	/// tightest) and its size on them.
	static void Flatten(Mesh mesh, List<int32> triangles, ref Chart chart, Vector3 normal, int32 seed, Vector3 scale)
	{
		var bestArea = float.MaxValue;
		for (int k < 3)
		{
			let p = mesh.Vertices[(int)mesh.Indices[seed * 3 + k]].position * scale;
			let q = mesh.Vertices[(int)mesh.Indices[seed * 3 + (k + 1) % 3]].position * scale;
			let edge = q - p;
			var u = edge - normal * Vector3.Dot(edge, normal);
			var lengthSq = Vector3.Dot(u, u);
			if (lengthSq < 1e-20f)
			{
				if (k < 2 || bestArea < float.MaxValue)
					continue;
				// No size: any axis across the normal.
				u = Math.Abs(normal.x) < 0.9f ? Vector3.Cross(normal, .(1, 0, 0)) : Vector3.Cross(normal, .(0, 1, 0));
				lengthSq = Vector3.Dot(u, u);
			}
			u = u / Math.Sqrt(lengthSq);
			let v = Vector3.Cross(normal, u);
			var minU = float.MaxValue, minV = float.MaxValue, maxU = -float.MaxValue, maxV = -float.MaxValue;
			for (int i = chart.first; i < chart.first + chart.count; i++)
			{
				let t = triangles[i];
				for (int c < 3)
				{
					let point = mesh.Vertices[(int)mesh.Indices[t * 3 + c]].position * scale;
					let pu = Vector3.Dot(point, u);
					let pv = Vector3.Dot(point, v);
					minU = Math.Min(minU, pu);
					maxU = Math.Max(maxU, pu);
					minV = Math.Min(minV, pv);
					maxV = Math.Max(maxV, pv);
				}
			}
			let area = (maxU - minU) * (maxV - minV);
			// Only clearly better: the same choice on every machine.
			if (area < bestArea * 0.999f)
			{
				bestArea = area;
				chart.axisU = u;
				chart.axisV = v;
				chart.minU = minU;
				chart.minV = minV;
				chart.width = maxU - minU;
				chart.height = maxV - minV;
			}
		}
	}

	/// Shelves the charts into a square, tallest first, each with Margin of the square round it. Returns the
	/// square's side in mesh units.
	static float Pack(List<Chart> charts)
	{
		if (charts.Count == 0)
			return 1;
		let order = scope List<int32>();
		var area = 0.0f;
		var widest = 0.0f;
		for (int32 i < (int32)charts.Count)
		{
			order.Add(i);
			area += charts[i].width * charts[i].height;
			widest = Math.Max(widest, Math.Max(charts[i].width, charts[i].height));
		}
		order.Sort(scope (a, b) =>
			{
				let ha = charts[a].height, hb = charts[b].height;
				if (ha != hb)
					return ha > hb ? -1 : 1;
				return a <=> b;
			});
		// Mostly-empty charts (all degenerate): any size will do.
		if (widest <= 0)
		{
			for (var chart in ref charts)
			{
				chart.x = 0.5f;
				chart.y = 0.5f;
			}
			return 1;
		}
		var side = Math.Max(Math.Sqrt(area) * 1.15f, widest * 1.1f);
		for (int attempt < 200)
		{
			let margin = side * Margin;
			var x = margin, y = margin, shelf = 0.0f;
			var fits = true;
			for (let i in order)
			{
				var chart = ref charts[i];
				if (x + chart.width + margin > side && x > margin)
				{
					x = margin;
					y += shelf + margin;
					shelf = 0;
				}
				if (x + chart.width + margin > side || y + chart.height + margin > side)
				{
					fits = false;
					break;
				}
				chart.x = x;
				chart.y = y;
				x += chart.width + margin;
				shelf = Math.Max(shelf, chart.height);
			}
			if (fits)
				return side;
			side *= 1.05f;
		}
		return side;
	}
}
