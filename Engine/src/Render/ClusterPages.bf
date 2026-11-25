using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// How a ClusterMesh is cut into pages for virtual geometry (M4b). Groups are packed, coarsest level first, into pages of
/// about 64 KB; page 0 holds the top of the hierarchy and is always resident. What stays on the graphics card for the whole
/// mesh is the table of clusters and groups (the LOD cut is judged from it); a page holds the vertices, vertex lists and
/// triangles of its groups' clusters and is streamed (StreamKind.GeoPage) into the pool when asked for.
///
/// A group may be resident only when every group that holds a cluster simplified from it is (its "parents"): then, when a
/// finer group is missing, the coarser clusters that stand in for it are all there. Pages are in coarse-to-fine order, so a
/// page's parent pages all come before it, and ParentPages lists what must be resident first.
///
/// Page layout (32-bit words, little endian): 8 header words { groupCount, clusterCount, vertexCount, refCount,
/// triangleBytes, 0, 0, 0 }, then per cluster 4 words { cluster index, first vertex-list word, first triangle byte, 0 },
/// then the group indices (padded to four words), the vertices (11 words each, a MeshVertex), the vertex lists (a page-local
/// vertex number per entry, padded to four words) and the triangle bytes (each cluster padded to four bytes).
class ClusterPages
{
	/// The size a page is filled to (a group is never split, so a page may go over).
	public const int PageBytes = 65536;
	/// Meshes of this many pages or fewer are loaded whole, as they always were: every page resident, none evicted.
	public const int WholeMeshPages = 8;
	public const int HeaderWords = 8;

	/// The page of each group, and the groups of each page.
	public int32[] PageOfGroup ~ delete _;
	public List<int32>[] GroupsOfPage ~ DeleteContainerAndItems!(_);
	/// For each page, the pages that must be resident before it can be (other than itself), and the inverse.
	public List<int32>[] ParentPages ~ DeleteContainerAndItems!(_);
	public List<int32>[] ChildPages ~ DeleteContainerAndItems!(_);
	/// The bytes of each page as cooked (what a streamed page costs the pool).
	public int32[] PageBytesOf ~ delete _;

	public int PageCount => GroupsOfPage == null ? 0 : GroupsOfPage.Count;

	/// Cuts a hierarchy into pages. Deterministic: the same hierarchy always gives the same pages.
	public static ClusterPages Layout(ClusterMesh clusters)
	{
		let pages = new ClusterPages();
		let groupCount = clusters.Groups.Count;
		pages.PageOfGroup = new int32[groupCount];
		// Coarse first, then in the order the groups were made (neighbours in the surface were made together).
		let order = scope List<int32>();
		for (int32 g < (int32)groupCount)
			order.Add(g);
		order.Sort(scope (a, b) =>
		{
			let da = clusters.Groups[a].depth;
			let db = clusters.Groups[b].depth;
			if (da != db)
				return db <=> da;
			return a <=> b;
		});
		let lists = new List<List<int32>>();
		defer delete lists;
		List<int32> current = null;
		var bytes = 0;
		for (let g in order)
		{
			let size = GroupBytes(clusters, g);
			if (current == null || (bytes + size > PageBytes && current.Count > 0))
			{
				current = new List<int32>();
				lists.Add(current);
				bytes = 0;
			}
			current.Add(g);
			bytes += size;
			pages.PageOfGroup[g] = (int32)lists.Count - 1;
		}
		pages.GroupsOfPage = new List<int32>[lists.Count];
		pages.ParentPages = new List<int32>[lists.Count];
		pages.ChildPages = new List<int32>[lists.Count];
		pages.PageBytesOf = new int32[lists.Count];
		for (int i < lists.Count)
		{
			pages.GroupsOfPage[i] = lists[i];
			pages.ParentPages[i] = new .();
			pages.ChildPages[i] = new .();
		}
		// A cluster simplified from group R belongs to a group P: P is a parent of R.
		for (let cluster in clusters.Clusters)
		{
			if (cluster.refinedGroup < 0)
				continue;
			let child = pages.PageOfGroup[cluster.refinedGroup];
			let parent = pages.PageOfGroup[cluster.groupIndex];
			if (child != parent && !pages.ParentPages[child].Contains(parent))
			{
				pages.ParentPages[child].Add(parent);
				pages.ChildPages[parent].Add(child);
			}
		}
		for (int i < lists.Count)
		{
			pages.PageBytesOf[i] = (int32)PageSize(clusters, lists[i]);
		}
		return pages;
	}

	/// What a group's clusters take in a page, a little over (vertices are counted once per cluster).
	static int GroupBytes(ClusterMesh clusters, int group)
	{
		let g = clusters.Groups[group];
		var bytes = 0;
		for (uint32 i < g.clusterCount)
		{
			let c = clusters.Clusters[(int)(g.clusterOffset + i)];
			bytes += (int)c.vertexCount * (44 + 4) + (int)((c.triangleCount * 3 + 3) / 4 * 4) + 16;
		}
		return bytes;
	}

	static int PageSize(ClusterMesh clusters, List<int32> groups)
	{
		let vertices = scope HashSet<uint32>();
		var refs = 0;
		var tris = 0;
		var clusterCount = 0;
		for (let group in groups)
		{
			let g = clusters.Groups[group];
			for (uint32 i < g.clusterCount)
			{
				let c = clusters.Clusters[(int)(g.clusterOffset + i)];
				clusterCount++;
				for (uint32 k < c.vertexCount)
					vertices.Add(clusters.Vertices[(int)(c.vertexOffset + k)]);
				refs += (int)c.vertexCount;
				tris += (int)((c.triangleCount * 3 + 3) / 4 * 4);
			}
		}
		return (HeaderWords + clusterCount * 4 + (groups.Count + 3) / 4 * 4 + (vertices.Count * 11 + 3) / 4 * 4 + (refs + 3) / 4 * 4) * 4 + tris;
	}

	/// Builds the bytes of page `page`: the vertices come from the mesh the hierarchy was built from.
	public List<uint8> Build(ClusterMesh clusters, Mesh mesh, int page)
	{
		let groups = GroupsOfPage[page];
		let words = new List<uint32>();
		defer delete words;
		let unique = scope Dictionary<uint32, uint32>();
		let uniqueList = scope List<uint32>();
		let refs = scope List<uint32>();
		let triangles = scope List<uint8>();
		let descriptors = scope List<uint32>();
		for (let group in groups)
		{
			let g = clusters.Groups[group];
			for (uint32 i < g.clusterCount)
			{
				let index = g.clusterOffset + i;
				let c = clusters.Clusters[(int)index];
				descriptors.Add(index);
				descriptors.Add((uint32)refs.Count);
				descriptors.Add((uint32)triangles.Count);
				descriptors.Add(0);
				for (uint32 k < c.vertexCount)
				{
					let v = clusters.Vertices[(int)(c.vertexOffset + k)];
					if (!unique.TryGetValue(v, var local))
					{
						local = (uint32)uniqueList.Count;
						unique[v] = local;
						uniqueList.Add(v);
					}
					refs.Add(local);
				}
				let triBytes = (int)((c.triangleCount * 3 + 3) / 4 * 4);
				for (int b < triBytes)
				{
					let at = (int)c.triangleOffset + b;
					triangles.Add(at < clusters.TriangleBytes.Count ? clusters.TriangleBytes[at] : 0);
				}
			}
		}
		words.Add((uint32)groups.Count);
		words.Add((uint32)(descriptors.Count / 4));
		words.Add((uint32)uniqueList.Count);
		words.Add((uint32)refs.Count);
		words.Add((uint32)triangles.Count);
		words.Add(0); words.Add(0); words.Add(0);
		words.AddRange(descriptors);
		for (let group in groups)
			words.Add((uint32)group);
		while (words.Count % 4 != 0)
			words.Add(0);
		for (let v in uniqueList)
		{
			let source = (uint32*)&mesh.Vertices[(int)v];
			for (int w < 11)
				words.Add(source[w]);
		}
		while (words.Count % 4 != 0)
			words.Add(0);
		for (let r in refs)
			words.Add(r);
		while (words.Count % 4 != 0)
			words.Add(0);
		let bytes = new List<uint8>(words.Count * 4 + triangles.Count);
		bytes.AddRange(Span<uint8>((uint8*)words.Ptr, words.Count * 4));
		bytes.AddRange(triangles);
		return bytes;
	}

	/// Cooks every page into a page file (`.tclodp`).
	public Result<void> Cook(ClusterMesh clusters, Mesh mesh, StringView file)
	{
		let folder = scope String();
		Path.GetDirectoryPath(file, folder).IgnoreError();
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		let all = scope List<List<uint8>>();
		defer { for (let p in all) delete p; }
		for (int page < PageCount)
			all.Add(Build(clusters, mesh, page));
		return PageFile.Write(file, .GeoPage, all);
	}

	/// What a page's header says (for checking a cooked file).
	public static bool ReadHeader(Span<uint8> page, out uint32 groupCount, out uint32 clusterCount, out uint32 vertexCount, out uint32 refCount, out uint32 triangleBytes)
	{
		groupCount = clusterCount = vertexCount = refCount = triangleBytes = 0;
		if (page.Length < HeaderWords * 4)
			return false;
		let w = (uint32*)page.Ptr;
		groupCount = w[0];
		clusterCount = w[1];
		vertexCount = w[2];
		refCount = w[3];
		triangleBytes = w[4];
		let expected = (HeaderWords + (int)clusterCount * 4 + ((int)groupCount + 3) / 4 * 4 + ((int)vertexCount * 11 + 3) / 4 * 4 + ((int)refCount + 3) / 4 * 4) * 4 + (int)triangleBytes;
		return expected == page.Length;
	}
}
