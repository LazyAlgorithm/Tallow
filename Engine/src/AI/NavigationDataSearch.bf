using System;
using System.Collections;

namespace Tallow;

/// Finding paths on a NavigationData: A* over the cells (or the nodes, NavigationNodes.bf), many at once on the job
/// threads, with each search's scratch and the routes it remembers.
extension NavigationData
{
	static ProfilerCounter sRouteHits = .("Route Cache Hits", .AI);

	/// The longest route a search remembers (routeCacheCapacity), in points.
	public const int MaxRememberedPoints = 256;
	/// The most routes a search can be asked to remember.
	public const int32 MaxRouteCache = 256;
	/// The visit budget FindPath uses when none is given.
	public const int32 DefaultMaxVisited = 200000;

	class RememberedRoute
	{
		public List<Vector3> points = new .() ~ delete _;
		public List<int32> legs = new .() ~ delete _;
		/// What finding it took, so a smaller budget than that still fails as a search would.
		public int32 visits;
	}

	/// A search's scratch, kept between searches (a stamp marks the entries the current search has written). FindPath
	/// uses the grid's own; searches running at the same time (FindPaths) each have one.
	public class Search
	{
		public List<float> cost = new .() ~ delete _;
		public List<int32> parent = new .() ~ delete _;
		public List<int32> parentLink = new .() ~ delete _;
		public List<int32> seen = new .() ~ delete _;
		public List<int32> closed = new .() ~ delete _;
		/// For the node search (NavigationNodes.bf): each node's cost plus estimate, the cells it was entered by and its
		/// parent left by, and the run of ways out it was entered through.
		public List<float> score = new .() ~ delete _;
		public List<int32> entry = new .() ~ delete _;
		public List<int32> exit = new .() ~ delete _;
		public List<int32> portal = new .() ~ delete _;
		/// The node search's corridor and its portals, while the path is pulled tight.
		public List<int32> corridor = new .() ~ delete _;
		public List<(Vector3 left, Vector3 right)> portals = new .() ~ delete _;
		public List<HeapItem> open = new .() ~ delete _;
		/// For the node search: the nodes one step made cheaper.
		public List<int32> touched = new .() ~ delete _;
		public int32 stamp;
		/// True when the last search stopped at its visit budget instead of proving the goal unreachable.
		public bool budgetExceeded;
		/// How many cells (or nodes) the last search took from its open list.
		public int32 visited;

		// The routes this search remembers, by start, goal and options, oldest replaced first.
		Dictionary<int64, RememberedRoute> mRoutes = new .() ~ DeleteDictionaryAndValues!(_);
		List<int64> mRouteOrder = new .() ~ delete _;
		int32 mRouteRevision = -1, mRouteCapacity;
		int mRouteNext;

		/// Forgets the remembered routes when the grid has changed (or the capacity has).
		public void PrepareRoutes(int32 revision, int32 capacity)
		{
			if (revision == mRouteRevision && capacity == mRouteCapacity) return;
			for (let route in mRoutes.Values)
				delete route;
			mRoutes.Clear();
			mRouteOrder.Clear();
			mRouteNext = 0;
			mRouteRevision = revision;
			mRouteCapacity = capacity;
		}

		/// Copies a remembered route into path and legs; false when there is none (or it took more than maxVisited).
		public bool ReadRoute(int64 key, List<Vector3> path, List<int32> legs, int32 maxVisited)
		{
			if (mRouteCapacity <= 0) return false;
			if (!mRoutes.TryGetValue(key, let route) || route.visits > maxVisited) return false;
			path.AddRange(route.points);
			legs?.AddRange(route.legs);
			return true;
		}

		/// Remembers the route just found, in place of the oldest when full.
		public void RememberRoute(int64 key, List<Vector3> path, List<int32> legs)
		{
			if (mRouteCapacity <= 0 || path.Count > MaxRememberedPoints) return;
			RememberedRoute route;
			if (!mRoutes.TryGetValue(key, out route))
			{
				if (mRouteOrder.Count >= mRouteCapacity)
				{
					let oldest = mRouteOrder[mRouteNext];
					route = mRoutes[oldest];
					mRoutes.Remove(oldest);
					mRouteOrder[mRouteNext] = key;
					mRouteNext = (mRouteNext + 1) % mRouteCapacity;
				}
				else
				{
					route = new .();
					mRouteOrder.Add(key);
				}
				mRoutes[key] = route;
			}
			route.points.Clear();
			route.points.AddRange(path);
			route.legs.Clear();
			if (legs != null)
				route.legs.AddRange(legs);
			route.visits = visited;
		}
	}

	public struct HeapItem
	{
		public int32 id;
		public float priority;
		public this(int32 id, float priority)
		{
			this.id = id;
			this.priority = priority;
		}
	}

	static void Push(List<HeapItem> heap, HeapItem item)
	{
		heap.Add(item);
		int index = heap.Count - 1;
		while (index > 0)
		{
			let parent = (index - 1) / 2;
			if (heap[parent].priority <= item.priority) break;
			heap[index] = heap[parent];
			index = parent;
		}
		heap[index] = item;
	}

	static HeapItem Pop(List<HeapItem> heap)
	{
		let result = heap[0];
		let tail = heap.Back;
		heap.RemoveAt(heap.Count - 1);
		if (heap.Count > 0)
		{
			int index = 0;
			while (index * 2 + 1 < heap.Count)
			{
				var child = index * 2 + 1;
				if (child + 1 < heap.Count && heap[child + 1].priority < heap[child].priority)
					child++;
				if (tail.priority <= heap[child].priority) break;
				heap[index] = heap[child];
				index = child;
			}
			heap[index] = tail;
		}
		return result;
	}

	/// Labels cells so two cells with different labels can never reach each other. Links are treated as two-way here, so
	/// equal labels do not promise a route; they only make the common unreachable case free.
	void EnsureRegions()
	{
		if (Mesh != null) return;
		using (sRegionsProfile.Sample())
		{
			if (mRegionRevision == Revision && mRegions.Count == cells.Count) return;
			mRegions.Clear();
			mRegions.Resize(cells.Count);
			for (int i < cells.Count)
				mRegions[i] = -1;
			List<int32> stack = scope .();
			int32 next = 0;
			for (int32 seed = 0; seed < (int32)cells.Count; seed++)
			{
				if (!cells[seed].walkable || mRegions[seed] >= 0) continue;
				mRegions[seed] = next;
				stack.Add(seed);
				while (stack.Count > 0)
				{
					let id = stack.PopBack();
					for (int32 direction = 0; direction < DirectionCount; direction++)
					{
						if (!Uses(direction)) continue;
						let other = Neighbor(id, direction);
						if (other < 0 || !cells[other].walkable || mRegions[other] >= 0) continue;
						if ((cells[id].links & (1u << direction)) == 0 && (cells[other].links & (1u << Opposite(direction))) == 0) continue;
						mRegions[other] = next;
						stack.Add(other);
					}
				}
				next++;
			}
			// Links join the regions at their ends: relabel each to the smallest it is joined to.
			if (!links.IsEmpty)
			{
				let joined = scope List<int32>();
				for (int32 r < next)
					joined.Add(r);
				int32 Root(int32 r)
				{
					var at = r;
					while (joined[at] != at)
						at = joined[at];
					return at;
				}
				for (let link in links)
				{
					let a = mRegions[link.from], b = mRegions[link.to];
					if (a < 0 || b < 0)
						continue;
					let ra = Root(a), rb = Root(b);
					if (ra != rb)
						joined[Math.Max(ra, rb)] = Math.Min(ra, rb);
				}
				for (int i < mRegions.Count)
				{
					if (mRegions[i] >= 0)
						mRegions[i] = Root(mRegions[i]);
				}
			}
			mRegionRevision = Revision;
		}
	}

	public int32 Region(int32 cell)
	{
		EnsureRegions();
		return cell >= 0 && cell < mRegions.Count ? mRegions[cell] : -1;
	}

	/// A path from the cell nearest `from` to the cell nearest `to`: over the nodes, pulled straight through them (useNodes,
	/// on by default; NavigationNodes.bf), or else one point per cell. The goal snaps to a cell connected to the start
	/// when one is in range, and a goal in another region fails without searching. maxVisited counts nodes, or cells.
	/// With a mesh: Detour's path of corners, and maxVisited counts polygons.
	public bool FindPath(Vector3 from, Vector3 to, List<Vector3> path, float snapDistance = 2, int32 maxVisited = DefaultMaxVisited) => FindPath(from, to, path, null, snapDistance, maxVisited);

	/// FindPath that also says, for each leg (point i to i + 1), which link it crosses (its id), or -1 for a step
	/// across the grid.
	public bool FindPath(Vector3 from, Vector3 to, List<Vector3> path, List<int32> legLinks, float snapDistance = 2, int32 maxVisited = DefaultMaxVisited)
		=> FindPathHere(from, to, path, legLinks, snapDistance, maxVisited, true, false);

	/// FindPath without the links when withLinks is false (for an agent that may not use them).
	public bool FindPath(Vector3 from, Vector3 to, List<Vector3> path, List<int32> legLinks, float snapDistance, bool withLinks)
		=> FindPathHere(from, to, path, legLinks, snapDistance, DefaultMaxVisited, withLinks, false);

	/// FindPath, then Smooth when smooth is true: a remembered route is kept smoothed, so asking again skips both.
	public bool FindPath(Vector3 from, Vector3 to, List<Vector3> path, List<int32> legLinks, float snapDistance, bool withLinks, bool smooth)
		=> FindPathHere(from, to, path, legLinks, snapDistance, DefaultMaxVisited, withLinks, smooth);

	/// FindPath on the calling thread with the data's own scratch, after bringing the overlay, regions and nodes up to date.
	bool FindPathHere(Vector3 from, Vector3 to, List<Vector3> path, List<int32> legLinks, float snapDistance, int32 maxVisited, bool withLinks, bool smooth)
	{
		// A mesh whose new overlay fails to build is searched as it was (the surface reports the failure).
		CommitNavMesh();
		EnsureRegions();
		EnsureNodes();
		let found = FindPath(from, to, path, legLinks, snapDistance, maxVisited, mSearch, withLinks, smooth);
		BudgetExceeded = mSearch.budgetExceeded;
		LastVisited = mSearch.visited;
		return found;
	}

	/// FindPath with its own scratch, and without the links when withLinks is false. It only reads the grid, so
	/// searches with different scratch can run at the same time (FindPaths), once EnsureRegions has run.
	bool FindPath(Vector3 from, Vector3 to, List<Vector3> path, List<int32> legLinks, float snapDistance, int32 maxVisited, Search search, bool withLinks, bool smooth = false)
	{
		path.Clear();
		legLinks?.Clear();
		search.budgetExceeded = false;
		search.visited = 0;
		ProfilerModules.Paths.Add(1);
		defer
		{
			ProfilerModules.PathVisits.Add(search.visited);
		}
		if (Mesh != null)
		{
			using (sSearchProfile.Sample())
				return Mesh.FindPath(from, to, path, legLinks, snapDistance, withLinks, maxVisited, out search.visited, out search.budgetExceeded, search == mSearch ? -1 : Jobs.ThreadIndex);
		}
		if (cells.Count != width * height * depth) return false;
		let start = Nearest(from, snapDistance);
		if (start < 0) return false;
		let goal = Nearest(to, snapDistance, mRegions[start]);
		if (goal < 0) return false;
		search.PrepareRoutes(Revision, Math.Clamp(routeCacheCapacity, 0, MaxRouteCache));
		let routeKey = ((int64)start << 24) | ((int64)goal << 4) | (withLinks ? 1L : 0L) | (useNodes ? 2L : 0L) | (legLinks != null ? 4L : 0L) | (smooth ? 8L : 0L);
		if (search.ReadRoute(routeKey, path, legLinks, maxVisited))
		{
			sRouteHits.Add(1);
			return true;
		}
		if (search.seen.Count != cells.Count)
		{
			search.score.Clear();
			search.score.Resize(cells.Count);
			search.entry.Clear();
			search.entry.Resize(cells.Count);
			search.exit.Clear();
			search.exit.Resize(cells.Count);
			search.portal.Clear();
			search.portal.Resize(cells.Count);
			search.cost.Clear();
			search.cost.Resize(cells.Count);
			search.parent.Clear();
			search.parent.Resize(cells.Count);
			search.seen.Clear();
			search.seen.Resize(cells.Count);
			search.closed.Clear();
			search.closed.Resize(cells.Count);
			search.parentLink.Clear();
			search.parentLink.Resize(cells.Count);
			for (int i < cells.Count)
			{
				search.seen[i] = 0;
				search.closed[i] = 0;
			}
			search.stamp = 0;
		}
		// Nodes number no more than cells, so the same scratch serves.
		if (useNodes && mNodeOf.Count == cells.Count)
		{
			let found = FindNodePath(start, goal, path, legLinks, maxVisited, search, withLinks);
			if (found)
			{
				if (smooth)
					Smooth(path, legLinks);
				search.RememberRoute(routeKey, path, legLinks);
			}
			return found;
		}
		search.stamp++;
		search.open.Clear();
		search.cost[start] = 0;
		search.parent[start] = -1;
		search.parentLink[start] = -1;
		search.seen[start] = search.stamp;
		Push(search.open, .(start, 0));
		int visited = 0;
		// Straight at the lists' memory in the loop below, and the goal's place on the grid once.
		let cellData = cells.Ptr;
		let closed = search.closed.Ptr;
		let seen = search.seen.Ptr;
		let blocked = mBlocked.Count == cells.Count ? mBlocked.Ptr : null;
		let scale = mCostScale.Count == cells.Count ? mCostScale.Ptr : null;
		let used = UsedDirections;
		let gx = goal % width, gz = (goal / width) % depth, gy = goal / (width * depth);
		while (search.open.Count > 0)
		{
			let id = Pop(search.open).id;
			if (search.closed[id] == search.stamp) continue;
			if (visited >= maxVisited)
			{
				search.budgetExceeded = true;
				break;
			}
			search.closed[id] = search.stamp;
			visited++;
			search.visited = (int32)visited;
			if (id == goal)
			{
				var cursor = goal;
				while (cursor >= 0)
				{
					path.Add(cells[cursor].position);
					// The leg into this cell, read backwards: it is put the right way round below.
					if (legLinks != null && search.parent[cursor] >= 0)
						legLinks.Add(search.parentLink[cursor]);
					cursor = search.parent[cursor];
				}
				for (int i = 0; i < path.Count / 2; i++)
				{
					let p = path[i];
					path[i] = path[path.Count - 1 - i];
					path[path.Count - 1 - i] = p;
				}
				if (legLinks != null)
				{
					for (int i = 0; i < legLinks.Count / 2; i++)
						Swap!(legLinks[i], legLinks[legLinks.Count - 1 - i]);
					// One entry per point, so the last point (no leg after it) has -1.
					legLinks.Add(-1);
				}
				if (smooth)
					Smooth(path, legLinks);
				search.RememberRoute(routeKey, path, legLinks);
				return true;
			}
			// The cell's place on the grid, worked out once (not for each neighbour), and only its linked directions.
			let x = id % width;
			let row = id / width;
			let z = row % depth;
			let y = row / depth;
			let position = cellData[id].position;
			let cost = search.cost[id];
			var directions = cellData[id].links & used;
			for (int32 direction = 0; directions != 0; direction++)
			{
				let bit = (uint32)1 << direction;
				if ((directions & bit) == 0) continue;
				directions &= ~bit;
				let nx = x + sStepX[direction], ny = y + sStepY[direction], nz = z + sStepZ[direction];
				if (nx < 0 || nx >= width || ny < 0 || ny >= height || nz < 0 || nz >= depth) continue;
				let next = nx + width * (nz + depth * ny);
				if (closed[next] == search.stamp || !cellData[next].walkable || (blocked != null && blocked[next] > 0)) continue;
				var g = (cellData[next].position - position).Length;
				if (scale != null)
					g *= scale[next];
				g += cost;
				if (seen[next] == search.stamp && g >= search.cost[next]) continue;
				search.cost[next] = g;
				search.parent[next] = id;
				search.parentLink[next] = -1;
				seen[next] = search.stamp;
				// The slight overweight breaks ties toward the goal, so open space is not flooded.
				Push(search.open, .(next, g + Estimate(nx - gx, ny - gy, nz - gz) * 1.001f));
			}
			// Links from this cell.
			if (withLinks && mLinksAt.TryGetValue(id, let here))
			{
				for (let index in here)
				{
					let link = links[index];
					let next = link.from == id ? link.to : link.from;
					if (search.closed[next] == search.stamp || !Usable(next)) continue;
					let g = search.cost[id] + Math.Max(link.cost, 0.01f);
					if (search.seen[next] == search.stamp && g >= search.cost[next]) continue;
					search.cost[next] = g;
					search.parent[next] = id;
					search.parentLink[next] = link.id;
					search.seen[next] = search.stamp;
					Push(search.open, .(next, g + Estimate(next, goal) * 1.001f));
				}
			}
		}
		return false;
	}

	/// One path request for FindPaths.
	public struct PathRequest
	{
		public Vector3 from, to;
		public List<Vector3> path;
		/// Optional: which link each leg crosses, as FindPath's.
		public List<int32> legLinks;
		public float snapDistance;
		public bool withLinks;
		public bool smooth;
		/// Set by FindPaths: whether a path was found.
		public bool found;
	}

	/// Finds many paths at once, spread over the job threads (Jobs), each with its own scratch: for many agents asking
	/// in one frame. Each request's lists are its own; the grid must not change while it runs.
	public void FindPaths(Span<PathRequest> requests, int32 maxVisited = DefaultMaxVisited)
	{
		if (requests.Length == 0)
			return;
		CommitNavMesh();
		EnsureRegions();
		EnsureNodes();
		let threads = Jobs.ThreadCount;
		Mesh?.PrepareWorkers(threads);
		while (mThreadSearches.Count < threads)
			mThreadSearches.Add(new .());
		Jobs.For(requests.Length, scope [&] (index) =>
			{
				ref PathRequest request = ref requests[index];
				let search = mThreadSearches[Jobs.ThreadIndex];
				request.found = FindPath(request.from, request.to, request.path, request.legLinks, request.snapDistance, maxVisited, search, request.withLinks, request.smooth);
			});
	}
}
