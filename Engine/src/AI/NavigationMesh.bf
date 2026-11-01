using System;
using System.Collections;

namespace Tallow;

/// How a Navigation Surface lets agents walk: over a polygon mesh, or over a grid of cells. Flying always uses a grid.
[Reflect(.All)]
enum NavigationBackend
{
	Grid,
	NavMesh
}

/// A walking navigation mesh built with Recast and searched with Detour (native/tessera_navigation.cpp). Cut into
/// tiles: carving, cost areas, links and geometry changes rebuild only the tiles they touch. NavigationData uses it
/// when its surface's backend is NavMesh; see docs/navigation.md.
class NavigationMesh
{
	/// The bake's bounds and the agent it is for.
	[CRepr]
	public struct Config
	{
		public Vector3 min, max;
		/// The width of one voxel the shapes are rasterized into, and its height (metres).
		public float cellSize, cellHeight;
		/// The agent's radius and height, the highest step it climbs (metres), and the steepest ground it walks (degrees).
		public float radius, height, climb, slope;
	}

	/// The voxels across one Navigation Surface cell: a surface's Cell Size is its voxel size times this.
	public const int VoxelsPerCell = 3;

	[CRepr]
	struct Volume
	{
		public Vector3 center;
		public Quaternion rotation;
		public Vector3 halfExtents;
		/// 0 blocks the floor; above 1 makes it cost that many times its length to cross.
		public float cost;
		public int32 cylinder, obstacle;
	}

	[CRepr]
	struct Link
	{
		public Vector3 start, end;
		public float radius, cost;
		public int32 bidirectional, id;
	}

	[CLink] static extern void* tn_nav_create(void* world, Config* config);
	[CLink] static extern void tn_nav_destroy(void* mesh);
	[CLink] static extern bool tn_nav_rebuild(void* mesh, void* world, Vector3* minimum, Vector3* maximum);
	[CLink] static extern bool tn_nav_overlay(void* mesh, Volume* volumes, int32 count, Link* links, int32 linkCount);
	[CLink] static extern int32 tn_nav_tile_count(void* mesh);
	[CLink] static extern int32 tn_nav_tiles_rebuilt(void* mesh);
	[CLink] static extern int32 tn_nav_polygons(void* mesh);
	[CLink] static extern void tn_nav_config(void* mesh, Config* config);
	[CLink] static extern void* tn_nav_query_create();
	[CLink] static extern void tn_nav_query_destroy(void* query);
	[CLink] static extern uint32 tn_nav_sample(void* mesh, void* query, Vector3* point, float distance, Vector3* found);
	[CLink] static extern bool tn_nav_valid_poly(void* mesh, uint32 polygon);
	[CLink] static extern int32 tn_nav_path(void* mesh, void* query, Vector3* from, Vector3* to, float snap, int32 withLinks, int32 budget, int32* visited, int32* exceeded);
	[CLink] static extern Vector3* tn_nav_points(void* query);
	[CLink] static extern int32* tn_nav_legs(void* query);
	[CLink] static extern bool tn_nav_line(void* mesh, void* query, Vector3* from, Vector3* to, Vector3* reached);
	[CLink] static extern int32 tn_nav_save_size(void* mesh);
	[CLink] static extern bool tn_nav_save(void* mesh, uint8* bytes, int32 count);
	[CLink] static extern void* tn_nav_load(uint8* bytes, int32 count);
	[CLink] static extern int32 tn_nav_debug(void* mesh, Vector3* points, int32 capacity);

	/// The most triangles DrawGizmos draws.
	const int32 MaxGizmoTriangles = 20000;

	void* mHandle;
	// Search scratch for the main thread, and one for each job thread (FindPaths).
	void* mQuery = tn_nav_query_create();
	List<void*> mWorkerQueries = new .() ~ delete _;
	// The overlay being gathered for the next Commit.
	List<Volume> mVolumes = new .() ~ delete _;
	List<Link> mLinks = new .() ~ delete _;
	bool mDirty;

	/// The bounds and agent it was baked for.
	public Config Settings { get; private set; }
	public int32 TileCount => tn_nav_tile_count(mHandle);
	/// How many tiles the last change rebuilt (for tests and profiling).
	public int32 LastRebuiltTiles => tn_nav_tiles_rebuilt(mHandle);
	/// How many floor polygons it has.
	public int32 PolygonCount => tn_nav_polygons(mHandle);

	this(void* handle, Config settings)
	{
		mHandle = handle;
		Settings = settings;
	}

	public ~this()
	{
		tn_nav_query_destroy(mQuery);
		for (let query in mWorkerQueries)
			tn_nav_query_destroy(query);
		tn_nav_destroy(mHandle);
	}

	/// Bakes the static shapes of a physics world (NavigationBaker.BuildGeometry fills one) inside the bounds. Null when
	/// the settings are out of range or the bake fails.
	public static NavigationMesh Bake(PhysicsWorld world, Config config)
	{
		world.[Friend]EnsureCreated();
		var settings = config;
		let handle = tn_nav_create(world.[Friend]mSystem, &settings);
		return handle == null ? null : new .(handle, settings);
	}

	/// Takes the world's shapes again and rebuilds the tiles round a box that changed. The overlay is kept.
	public bool Rebuild(PhysicsWorld world, Bounds changed)
	{
		if (!Commit())
			return false;
		world.[Friend]EnsureCreated();
		var minimum = changed.min, maximum = changed.max;
		return tn_nav_rebuild(mHandle, world.[Friend]mSystem, &minimum, &maximum);
	}

	/// Forgets the gathered overlay (before the surface adds it again).
	public void ClearOverlay()
	{
		mDirty |= !mVolumes.IsEmpty || !mLinks.IsEmpty;
		mVolumes.Clear();
		mLinks.Clear();
	}

	/// Adds a box (or upright cylinder, its radius halfExtents.x) to the overlay: cost 0 blocks the floor in it, above 1
	/// makes it cost more to cross. An obstacle also blocks the floor below it that an agent's head would reach into.
	public void AddVolume(Vector3 center, Quaternion rotation, Vector3 halfExtents, float cost, bool cylinder = false, bool obstacle = false)
	{
		mVolumes.Add(.() { center = center, rotation = rotation, halfExtents = halfExtents, cost = cost, cylinder = cylinder ? 1 : 0, obstacle = obstacle ? 1 : 0 });
		mDirty = true;
	}

	/// Adds a link to the overlay: from start to end, joined to the floor within radius of each, at a cost per metre.
	/// Its id comes back in FindPath's legs.
	public void AddLink(Vector3 start, Vector3 end, float radius, float cost, bool bidirectional, int32 id)
	{
		mLinks.Add(.() { start = start, end = end, radius = radius, cost = cost, bidirectional = bidirectional ? 1 : 0, id = id });
		mDirty = true;
	}

	/// Rebuilds the tiles the gathered overlay changed. When that fails it returns false and the last good mesh (with its
	/// overlay) stays in use; the failed overlay is not tried again until it changes.
	public bool Commit()
	{
		if (!mDirty)
			return true;
		mDirty = false;
		return tn_nav_overlay(mHandle, mVolumes.Ptr, (int32)mVolumes.Count, mLinks.Ptr, (int32)mLinks.Count);
	}

	/// Makes sure each of so many job threads has its own search scratch (before FindPaths).
	public void PrepareWorkers(int count)
	{
		while (mWorkerQueries.Count < count)
			mWorkerQueries.Add(tn_nav_query_create());
	}

	/// A path of corners from near `from` to near `to` (each moved up to snap onto the floor), with each leg's link id
	/// (or -1) in legs. budget caps the polygons searched. worker: the job thread's index, or -1 on the main thread.
	public bool FindPath(Vector3 from, Vector3 to, List<Vector3> path, List<int32> legs, float snap, bool withLinks, int32 budget, out int32 visited, out bool exceeded, int worker = -1)
	{
		path.Clear();
		legs?.Clear();
		let query = worker < 0 ? mQuery : mWorkerQueries[worker];
		var a = from, b = to;
		int32 visits = 0, overBudget = 0;
		let count = tn_nav_path(mHandle, query, &a, &b, snap, withLinks ? 1 : 0, budget, &visits, &overBudget);
		visited = visits;
		exceeded = overBudget != 0;
		if (count <= 0)
			return false;
		let points = tn_nav_points(query);
		for (int32 i < count)
			path.Add(points[i]);
		if (legs != null)
		{
			let links = tn_nav_legs(query);
			for (int32 i < count - 1)
				legs.Add(links[i]);
			// One entry per point, so the last point (no leg after it) has -1.
			legs.Add(-1);
		}
		return true;
	}

	/// The polygon nearest a point within a distance, and the nearest point on it; -1 when there is none. The number
	/// names the polygon's place in the mesh until its tile is rebuilt.
	public int32 Nearest(Vector3 point, float distance, out Vector3 found)
	{
		var at = point;
		var nearest = point;
		let polygon = tn_nav_sample(mHandle, mQuery, &at, distance, &nearest);
		found = nearest;
		return polygon == 0 ? -1 : (int32)polygon;
	}

	/// Whether a number from Nearest names a floor polygon now.
	public bool Usable(int32 polygon) => polygon >= 0 && tn_nav_valid_poly(mHandle, (uint32)polygon);

	/// Whether an agent can walk straight from `from` to `to` over the floor; `reached` is where it stops.
	public bool LineClear(Vector3 from, Vector3 to, out Vector3 reached)
	{
		var a = from, b = to;
		var stop = from;
		let clear = tn_nav_line(mHandle, mQuery, &a, &b, &stop);
		reached = stop;
		return clear;
	}

	/// The floor as see-through blue polygons with their edges outlined (the first MaxGizmoTriangles of them).
	public void DrawGizmos()
	{
		let total = tn_nav_debug(mHandle, null, 0);
		if (total <= 0)
			return;
		let count = Math.Min(total, MaxGizmoTriangles * 3);
		let points = scope List<Vector3>();
		points.Resize(count);
		tn_nav_debug(mHandle, points.Ptr, count);
		let lift = Vector3(0, 0.04f, 0);
		let fill = Color(0.05f, 0.4f, 1, 0.5f);
		let edge = Color(0.05f, 0.35f, 0.75f, 1);
		for (int i = 0; i + 2 < count; i += 3)
		{
			let a = points[i] + lift, b = points[i + 1] + lift, c = points[i + 2] + lift;
			Gizmos.Triangles.Triangle(a, b, c, fill);
			Gizmos.Lines.Line(a, b, edge);
			Gizmos.Lines.Line(b, c, edge);
			Gizmos.Lines.Line(c, a, edge);
		}
	}

	/// Writes the mesh as a .tnav asset ("TNM1": the settings and the static shapes' triangles).
	public bool Serialize(List<uint8> bytes)
	{
		let size = tn_nav_save_size(mHandle);
		if (size <= 0)
			return false;
		bytes.Resize(size);
		return tn_nav_save(mHandle, bytes.Ptr, size);
	}

	/// Builds a mesh from Serialize's bytes, or null when they are not a valid asset.
	public static NavigationMesh Deserialize(List<uint8> bytes)
	{
		let handle = tn_nav_load(bytes.Ptr, (int32)bytes.Count);
		if (handle == null)
			return null;
		Config config = default;
		tn_nav_config(handle, &config);
		return new .(handle, config);
	}
}
