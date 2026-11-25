using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// A mesh cut into a hierarchy of clusters for GPU-driven drawing (native/tallow_clusterlod.cpp): clusters of at most
/// 128 triangles and 64 vertices, merged into groups, simplified and cut again, level after level, until one cluster
/// is left (Nanite style). The data is flat arrays laid out to be uploaded to the graphics card as they are.
///
/// A cluster is drawn when its own error is under the screen threshold and its parent group's error is not:
/// SelfError <= threshold < ParentError (errors are in the mesh's own units; for a camera, project them with
/// error / max(distance - radius, near) * cot(fovy / 2) / 2, using the group spheres in Groups). Every level covers the
/// whole surface, so any cut through the levels (finer near the camera, coarser far away) has no cracks.
class ClusterMesh
{
	/// One cluster. 64 bytes: four rows of four 32-bit values.
	[CRepr]
	public struct Cluster
	{
		/// Where its vertex list starts in Vertices (entries, not bytes), and how many entries (at most 64).
		public uint32 vertexOffset, vertexCount;
		/// Where its triangles start in TriangleBytes (a multiple of 4), and how many triangles (at most 128).
		/// Triangle t is the three bytes at triangleOffset + t * 3, each an index into the cluster's vertex list.
		public uint32 triangleOffset, triangleCount;
		/// The sphere round the cluster's own triangles.
		public Vector3 center;
		public float radius;
		/// The normal cone for back-face culling: skip the cluster when dot(normalize(centre - camera), axis) >= cutoff
		/// (a cutoff of 1 never culls).
		public Vector3 coneAxis;
		public float coneCutoff;
		/// This cluster's error (0 for the mesh's own triangles) and the error of the group it is merged into
		/// (float.MaxValue for the top, which never goes coarser).
		public float selfError, parentError;
		/// The group this cluster belongs to, whose Level is the cluster's LOD level, and the finer group it was
		/// simplified from (-1 for the mesh's own triangles). The spheres to project the two errors with are
		/// Groups[refinedGroup] (or none, for error 0) and Groups[groupIndex].
		public int32 groupIndex, refinedGroup;
	}

	/// A set of clusters that are simplified together. 32 bytes.
	[CRepr]
	public struct Group
	{
		/// The sphere round the group's simplified result, and its error: the parentError of the group's clusters and
		/// the selfError of the clusters simplified from it. The spheres only grow towards the top, so projected errors
		/// never go down as the hierarchy gets coarser.
		public Vector3 center;
		public float radius;
		public float error;
		/// The LOD level of the group's clusters: 0 is the mesh's own triangles, higher is coarser.
		public int32 depth;
		/// The group's clusters are Clusters[clusterOffset .. clusterOffset + clusterCount).
		public uint32 clusterOffset, clusterCount;
	}

	/// What one LOD level holds. 16 bytes.
	[CRepr]
	public struct Level
	{
		public uint32 clusterCount, triangleCount, groupCount;
		/// The largest selfError among the level's clusters.
		public float maxError;
	}

	/// How to build. Zero values mean the defaults.
	[CRepr]
	public struct Config
	{
		/// Vertices and triangles per cluster (64 and 128; at most 255 and 256) and the fewest triangles a cluster aims for.
		public uint32 maxVertices, maxTriangles, minTriangles;
		/// About how many clusters are simplified together.
		public uint32 partitionSize;
		/// How much simplification cares about normals and texture coordinates (0.5 each).
		public float normalWeight, uvWeight;
		/// The share of triangles each level keeps (0.5).
		public float simplifyRatio;
		/// Not used yet.
		public uint32 flags;
	}

	[CLink] static extern uint64 tn_clod_hash(void* data, int bytes, uint64 seed);
	[CLink] static extern void* tn_clod_build(float* positions, uint32 positionStride, float* normals, uint32 normalStride, float* uvs, uint32 uvStride,
		uint32 vertexCount, uint32* indices, uint32 indexCount, Config* config);
	[CLink] static extern void tn_clod_counts(void* result, uint32* counts);
	[CLink] static extern void tn_clod_copy(void* result, Cluster* clusters, Group* groups, Level* levels, uint32* vertices, uint8* triangles);
	[CLink] static extern void tn_clod_free(void* result);

	/// The first four bytes of a .tclod file, and its layout's version; a file with another version is rebuilt.
	const uint32 Magic = 0x444C4354; // "TCLD"
	const uint32 Version = 1;
	/// A file starts with this header (48 bytes); the arrays follow in the order of the counts, with no gaps.
	[CRepr]
	struct Header
	{
		public uint32 magic, version;
		public uint64 hash;
		public uint32 sourceVertexCount, sourceTriangleCount;
		public uint32 clusterCount, groupCount, levelCount, vertexCount, triangleByteCount;
		public uint32 pad;
	}
	const int HeaderSize = 48;

	/// Every cluster of every level.
	public Cluster[] Clusters ~ delete _;
	/// Every group, in the order they were made (a group's clusters sit together, see Group.clusterOffset).
	public Group[] Groups ~ delete _;
	/// One entry per LOD level, finest first.
	public Level[] Levels ~ delete _;
	/// For each cluster in turn, the mesh vertex index of each of its vertices.
	public uint32[] Vertices ~ delete _;
	/// For each cluster in turn, its triangles' local vertex indices, three bytes a triangle, each cluster padded to 4 bytes.
	public uint8[] TriangleBytes ~ delete _;
	/// The mesh's vertex and triangle count, for checking a cache against the mesh.
	public uint32 SourceVertexCount, SourceTriangleCount;
	/// A hash of the mesh and the settings it was built with (what a cache is keyed on).
	public uint64 ContentHash;

	/// How many LOD levels there are.
	public int LevelCount => Levels == null ? 0 : Levels.Count;

	/// A hash of a mesh's vertices and triangles with the settings they will be built with.
	public static uint64 HashOf(Mesh mesh, Config config)
	{
		var config;
		var hash = tn_clod_hash(&config, sizeof(Config), Version);
		if (mesh.Vertices.Count > 0)
			hash = tn_clod_hash(mesh.Vertices.Ptr, mesh.Vertices.Count * sizeof(MeshVertex), hash);
		if (mesh.Indices.Count > 0)
			hash = tn_clod_hash(mesh.Indices.Ptr, mesh.Indices.Count * 4, hash);
		return hash;
	}

	/// Builds the hierarchy of a mesh, on the calling thread (run several on several threads). Returns null when the
	/// mesh has no triangles. The mesh's vertices and indices must still be on the CPU.
	public static ClusterMesh Build(Mesh mesh, Config config = default)
	{
		var config;
		if (mesh.Vertices.Count == 0 || mesh.Indices.Count < 3)
			return null;
		let vertices = mesh.Vertices.Ptr;
		let result = tn_clod_build(&vertices[0].position.x, (uint32)sizeof(MeshVertex), &vertices[0].normal.x, (uint32)sizeof(MeshVertex),
			&vertices[0].uv.x, (uint32)sizeof(MeshVertex), (uint32)mesh.Vertices.Count, mesh.Indices.Ptr, (uint32)mesh.Indices.Count, &config);
		if (result == null)
			return null;
		defer tn_clod_free(result);

		uint32[5] counts = default;
		tn_clod_counts(result, &counts[0]);
		let clusterMesh = new ClusterMesh();
		clusterMesh.Allocate(counts);
		tn_clod_copy(result, clusterMesh.Clusters.CArray(), clusterMesh.Groups.CArray(), clusterMesh.Levels.CArray(), clusterMesh.Vertices.CArray(), clusterMesh.TriangleBytes.CArray());
		clusterMesh.SourceVertexCount = (uint32)mesh.Vertices.Count;
		clusterMesh.SourceTriangleCount = (uint32)(mesh.Indices.Count / 3);
		clusterMesh.ContentHash = HashOf(mesh, config);
		return clusterMesh;
	}

	void Allocate(uint32[5] counts)
	{
		Clusters = new Cluster[counts[0]];
		Groups = new Group[counts[1]];
		Levels = new Level[counts[2]];
		Vertices = new uint32[counts[3]];
		TriangleBytes = new uint8[counts[4]];
	}

	/// Where the editor keeps the hierarchy of a model: <project>/.cache/clod/<path>.tclod, beside .cache/models.
	/// Empty (no cache) when no project is open.
	public static void CachePath(StringView meshPath, String outPath)
	{
		if (Assets.ProjectPath.IsEmpty)
			return;
		let parent = scope String();
		Path.GetDirectoryPath(Assets.ProjectPath, parent).IgnoreError();
		outPath.AppendF("{}/.cache/clod/{}.tclod", parent, meshPath);
	}

	/// The hierarchy of a mesh from its cache file when that is there and was made from the same mesh and settings;
	/// otherwise built (and the cache file rewritten when cachePath is not empty). A bad, old or foreign file is
	/// ignored. Returns null when the mesh has no triangles.
	public static ClusterMesh BuildCached(Mesh mesh, StringView cachePath, Config config = default)
	{
		let hash = HashOf(mesh, config);
		if (!cachePath.IsEmpty)
		{
			if (Load(cachePath, hash) case .Ok(let loaded))
				return loaded;
		}
		let built = Build(mesh, config);
		if (built != null && !cachePath.IsEmpty)
			built.Save(cachePath).IgnoreError();
		return built;
	}

	/// Writes the hierarchy to a .tclod file (little endian, in the layout the graphics card reads it in).
	public Result<void> Save(StringView path)
	{
		let folder = scope String();
		Path.GetDirectoryPath(path, folder).IgnoreError();
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();

		let clusterBytes = Clusters.Count * sizeof(Cluster);
		let groupBytes = Groups.Count * sizeof(Group);
		let levelBytes = Levels.Count * sizeof(Level);
		let vertexBytes = Vertices.Count * 4;
		let data = new List<uint8>(HeaderSize + clusterBytes + groupBytes + levelBytes + vertexBytes + TriangleBytes.Count);
		defer delete data;
		Header header = .() { magic = Magic, version = Version, hash = ContentHash, sourceVertexCount = SourceVertexCount,
			sourceTriangleCount = SourceTriangleCount, clusterCount = (uint32)Clusters.Count, groupCount = (uint32)Groups.Count,
			levelCount = (uint32)Levels.Count, vertexCount = (uint32)Vertices.Count, triangleByteCount = (uint32)TriangleBytes.Count };
		data.AddRange(Span<uint8>((uint8*)&header, sizeof(Header)));
		data.AddRange(Span<uint8>((uint8*)Clusters.CArray(), clusterBytes));
		data.AddRange(Span<uint8>((uint8*)Groups.CArray(), groupBytes));
		data.AddRange(Span<uint8>((uint8*)Levels.CArray(), levelBytes));
		data.AddRange(Span<uint8>((uint8*)Vertices.CArray(), vertexBytes));
		data.AddRange(Span<uint8>(TriangleBytes.CArray(), TriangleBytes.Count));
		if (File.WriteAll(path, Span<uint8>(data.Ptr, data.Count)) case .Err)
			return .Err;
		return .Ok;
	}

	/// Reads a .tclod file. Fails (so the caller rebuilds) for a missing, truncated or old file, and, when
	/// expectedHash is not 0, for one made from a different mesh or settings.
	public static Result<ClusterMesh> Load(StringView path, uint64 expectedHash = 0)
	{
		let data = scope List<uint8>();
		if (File.ReadAll(path, data) case .Err)
			return .Err;
		if (data.Count < HeaderSize)
			return .Err;
		let header = (Header*)data.Ptr;
		if (header.magic != Magic || header.version != Version)
			return .Err;
		let hash = header.hash;
		if (expectedHash != 0 && hash != expectedHash)
			return .Err;
		uint32[5] counts = .(header.clusterCount, header.groupCount, header.levelCount, header.vertexCount, header.triangleByteCount);
		let clusterBytes = (int)counts[0] * sizeof(Cluster);
		let groupBytes = (int)counts[1] * sizeof(Group);
		let levelBytes = (int)counts[2] * sizeof(Level);
		let vertexBytes = (int)counts[3] * 4;
		let triangleBytes = (int)counts[4];
		if (counts[0] == 0 || counts[2] == 0 || (int64)data.Count != (int64)HeaderSize + clusterBytes + groupBytes + levelBytes + vertexBytes + triangleBytes)
			return .Err;

		let clusterMesh = new ClusterMesh();
		clusterMesh.Allocate(counts);
		clusterMesh.ContentHash = hash;
		clusterMesh.SourceVertexCount = header.sourceVertexCount;
		clusterMesh.SourceTriangleCount = header.sourceTriangleCount;
		var at = data.Ptr + HeaderSize;
		Internal.MemCpy(clusterMesh.Clusters.CArray(), at, clusterBytes);
		at += clusterBytes;
		Internal.MemCpy(clusterMesh.Groups.CArray(), at, groupBytes);
		at += groupBytes;
		Internal.MemCpy(clusterMesh.Levels.CArray(), at, levelBytes);
		at += levelBytes;
		Internal.MemCpy(clusterMesh.Vertices.CArray(), at, vertexBytes);
		at += vertexBytes;
		Internal.MemCpy(clusterMesh.TriangleBytes.CArray(), at, triangleBytes);
		return .Ok(clusterMesh);
	}

	/// The triangles the clusters drawn at one error threshold add up to (see the class comment), for statistics and tests.
	public int CutTriangleCount(float threshold)
	{
		int total = 0;
		for (let cluster in Clusters)
		{
			if (cluster.selfError <= threshold && threshold < cluster.parentError)
				total += cluster.triangleCount;
		}
		return total;
	}
}
