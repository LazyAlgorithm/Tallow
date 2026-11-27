using System;
using System.Collections;
using System.Diagnostics;
using System.IO;

namespace Tallow;

/// --clod-test <mesh>: builds the cluster hierarchy of a mesh with no window, prints the levels and checks them.
/// The mesh is "builtin:sphere_smooth" (or any other builtin), "sphere:<segments>x<rings>" for a bigger generated
/// sphere (sphere:512x300 is about 300 000 triangles), or a model file. Exit code 0 when every check passed.
static class ClusterMeshTest
{
	public static int Run(StringView meshPath)
	{
		Mesh mesh = null;
		if (meshPath.StartsWith("sphere:"))
		{
			let dims = meshPath.Substring(7);
			let x = dims.IndexOf('x');
			if (x > 0 && int32.Parse(dims.Substring(0, x)) case .Ok(let segments) && int32.Parse(dims.Substring(x + 1)) case .Ok(let rings))
				mesh = Primitives.CreateSphere(segments, rings);
		}
		else if (meshPath.StartsWith("builtin:"))
			mesh = Assets.GetMesh(meshPath);
		else
			mesh = Assets.BuildModel(meshPath);
		if (mesh == null || mesh.Indices.Count < 3)
		{
			Console.WriteLine(scope $"clod-test: no mesh to build from '{meshPath}'");
			return 1;
		}
		defer { if (!meshPath.StartsWith("builtin:")) delete mesh; }

		let sourceTriangles = mesh.Indices.Count / 3;
		Console.WriteLine(scope $"clod-test: {meshPath}: {mesh.Vertices.Count} vertices, {sourceTriangles} triangles");
		let watch = scope Stopwatch(true);
		let clusterMesh = ClusterMesh.Build(mesh);
		watch.Stop();
		if (clusterMesh == null)
		{
			Console.WriteLine("clod-test: FAIL: build returned nothing");
			return 1;
		}
		defer delete clusterMesh;
		Console.WriteLine(scope $"clod-test: built in {watch.ElapsedMilliseconds} ms: {clusterMesh.Clusters.Count} clusters, {clusterMesh.Groups.Count} groups, {clusterMesh.Levels.Count} levels");
		for (int l = 0; l < clusterMesh.Levels.Count; l++)
		{
			let level = clusterMesh.Levels[l];
			Console.WriteLine(scope $"  level {l}: {level.clusterCount} clusters, {level.triangleCount} triangles, {level.groupCount} groups, max error {level.maxError}");
		}

		var failures = 0;
		void Fail(StringView text)
		{
			if (failures++ < 10)
				Console.WriteLine(scope $"clod-test: FAIL: {text}");
		}

		Check(clusterMesh, mesh, ref failures);

		// A cut through the levels at growing error thresholds only gets coarser, and never comes up empty.
		let radius = Math.Max(0.0001f, (mesh.Bounds.max - mesh.Bounds.min).Length * 0.5f);
		var previous = int.MaxValue;
		for (let factor in float[?](0, 0.0001f, 0.001f, 0.01f, 0.1f, 1))
		{
			let count = clusterMesh.CutTriangleCount(factor * radius);
			Console.WriteLine(scope $"  cut at error {factor * radius}: {count} triangles");
			if (count == 0 || count > previous)
				Fail(scope $"the cut at {factor * radius} has {count} triangles (previous {previous})");
			previous = count;
		}
		if (clusterMesh.CutTriangleCount(float.MaxValue * 0.5f) == 0)
			Fail("the coarsest cut is empty");

		// The cache: save, load and compare; a changed or damaged file is refused.
		let cachePath = scope $"{Path.GetTempPath(.. scope .())}/tallow-clod-test.tclod";
		let hash = ClusterMesh.HashOf(mesh, default);
		if (hash != clusterMesh.ContentHash)
			Fail("the hash of the mesh differs from the built hierarchy's");
		if (clusterMesh.Save(cachePath) case .Err)
			Fail("could not write the cache file");
		else if (ClusterMesh.Load(cachePath, hash) case .Ok(let loaded))
		{
			if (!Same(clusterMesh, loaded))
				Fail("the loaded cache differs from the built hierarchy");
			delete loaded;
			if (ClusterMesh.Load(cachePath, hash + 1) case .Ok(let wrong))
			{
				delete wrong;
				Fail("a cache of another mesh was accepted");
			}
			let bytes = scope List<uint8>();
			File.ReadAll(cachePath, bytes).IgnoreError();
			bytes.Count = bytes.Count / 2;
			File.WriteAll(cachePath, Span<uint8>(bytes.Ptr, bytes.Count)).IgnoreError();
			if (ClusterMesh.Load(cachePath, hash) case .Ok(let truncated))
			{
				delete truncated;
				Fail("a truncated cache was accepted");
			}
			// BuildCached then replaces the damaged file with a fresh one.
			let again = ClusterMesh.BuildCached(mesh, cachePath);
			if (again == null || !Same(clusterMesh, again))
				Fail("BuildCached did not rebuild a damaged cache");
			if (ClusterMesh.Load(cachePath, hash) case .Ok(let reloaded))
				delete reloaded;
			else
				Fail("BuildCached did not rewrite a damaged cache");
			delete again;
		}
		else
			Fail("could not read the cache file back");
		File.Delete(cachePath).IgnoreError();

		if (failures == 0)
			Console.WriteLine("clod-test: PASS");
		else
			Console.WriteLine(scope $"clod-test: {failures} checks failed");
		return failures == 0 ? 0 : 1;
	}

	/// The size, index and error rules every hierarchy must keep.
	static void Check(ClusterMesh cm, Mesh mesh, ref int failures)
	{
		var failures;
		var bad = 0;
		void Fail(StringView text)
		{
			if (bad++ < 10)
				Console.WriteLine(scope $"clod-test: FAIL: {text}");
		}

		for (int i = 0; i < cm.Clusters.Count; i++)
		{
			let c = cm.Clusters[i];
			if (c.triangleCount == 0 || c.triangleCount > 128)
				Fail(scope $"cluster {i} has {c.triangleCount} triangles");
			if (c.vertexCount == 0 || c.vertexCount > 64)
				Fail(scope $"cluster {i} has {c.vertexCount} vertices");
			if (c.triangleOffset % 4 != 0 || c.triangleOffset + c.triangleCount * 3 > (uint32)cm.TriangleBytes.Count)
				Fail(scope $"cluster {i} triangle bytes out of range");
			else
			{
				for (uint32 b = 0; b < c.triangleCount * 3; b++)
				{
					if (cm.TriangleBytes[(int)(c.triangleOffset + b)] >= c.vertexCount)
					{
						Fail(scope $"cluster {i} has a local index out of range");
						break;
					}
				}
			}
			if ((uint64)c.vertexOffset + c.vertexCount > (uint64)cm.Vertices.Count)
				Fail(scope $"cluster {i} vertex list out of range");
			else
			{
				for (uint32 v = 0; v < c.vertexCount; v++)
				{
					if (cm.Vertices[(int)(c.vertexOffset + v)] >= (uint32)mesh.Vertices.Count)
					{
						Fail(scope $"cluster {i} refers to a vertex that is not in the mesh");
						break;
					}
				}
			}
			if (c.selfError > c.parentError)
				Fail(scope $"cluster {i} error {c.selfError} is over its parent's {c.parentError}");
			if (c.groupIndex < 0 || c.groupIndex >= cm.Groups.Count || c.refinedGroup >= cm.Groups.Count)
				Fail(scope $"cluster {i} group out of range");
			else
			{
				let group = cm.Groups[c.groupIndex];
				if (group.error != c.parentError || (uint32)i < group.clusterOffset || (uint32)i >= group.clusterOffset + group.clusterCount)
					Fail(scope $"cluster {i} does not match its group");
				if (c.refinedGroup >= 0)
				{
					let refined = cm.Groups[c.refinedGroup];
					if (refined.error != c.selfError || refined.depth + 1 != group.depth)
						Fail(scope $"cluster {i} does not match the group it was simplified from");
				}
				else if (c.selfError != 0 || group.depth != 0)
					Fail(scope $"cluster {i} has no source group but is not level 0 with error 0");
			}
		}
		if (cm.Levels[0].triangleCount != (uint32)(mesh.Indices.Count / 3))
			Fail(scope $"level 0 holds {cm.Levels[0].triangleCount} triangles, the mesh has {mesh.Indices.Count / 3}");
		for (int l = 1; l < cm.Levels.Count; l++)
		{
			if (cm.Levels[l].triangleCount > cm.Levels[l - 1].triangleCount)
				Fail(scope $"level {l} has more triangles than level {l - 1}");
			if (cm.Levels[l].maxError < cm.Levels[l - 1].maxError)
				Fail(scope $"level {l} has a lower error than level {l - 1}");
		}
		let top = cm.Levels[cm.Levels.Count - 1];
		if (cm.Levels.Count > 1 && top.clusterCount > 8)
			Fail(scope $"the coarsest level still has {top.clusterCount} clusters");
		failures += bad;
	}

	static bool Same(ClusterMesh a, ClusterMesh b)
	{
		return a.ContentHash == b.ContentHash && a.SourceVertexCount == b.SourceVertexCount && a.SourceTriangleCount == b.SourceTriangleCount
			&& a.Clusters.Count == b.Clusters.Count && a.Groups.Count == b.Groups.Count && a.Levels.Count == b.Levels.Count
			&& a.Vertices.Count == b.Vertices.Count && a.TriangleBytes.Count == b.TriangleBytes.Count
			&& Internal.MemCmp(a.Clusters.CArray(), b.Clusters.CArray(), a.Clusters.Count * sizeof(ClusterMesh.Cluster)) == 0
			&& Internal.MemCmp(a.Groups.CArray(), b.Groups.CArray(), a.Groups.Count * sizeof(ClusterMesh.Group)) == 0
			&& Internal.MemCmp(a.Levels.CArray(), b.Levels.CArray(), a.Levels.Count * sizeof(ClusterMesh.Level)) == 0
			&& Internal.MemCmp(a.Vertices.CArray(), b.Vertices.CArray(), a.Vertices.Count * 4) == 0
			&& Internal.MemCmp(a.TriangleBytes.CArray(), b.TriangleBytes.CArray(), a.TriangleBytes.Count) == 0;
	}
}
