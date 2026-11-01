using System;
using System.Collections;

namespace Tallow;

/// A Navigation Surface's baked data: a walking grid (one floor height per cell), a volume grid for flying agents, or a
/// walking polygon mesh (Mesh, when the surface's backend is NavMesh). Positions are agent feet for walking, and centres
/// for flying. Searching is in NavigationDataSearch.bf, straight lines in NavigationDataLines.bf, assets in
/// NavigationDataFiles.bf and the grid's nodes in NavigationNodes.bf.
class NavigationData
{
	static ProfilerMarker sRegionsProfile = .("Navigation.Regions", .AI);
	static ProfilerMarker sNodesProfile = .("Navigation.Nodes", .AI);
	static ProfilerMarker sNearestProfile = .("Navigation.Nearest", .AI);
	static ProfilerMarker sSearchProfile = .("Navigation.Search", .AI);
	static ProfilerMarker sCorridorProfile = .("Navigation.Corridor", .AI);
	static ProfilerMarker sLineClearProfile = .("Navigation.LineClear", .AI);
	static ProfilerMarker sSmoothProfile = .("Navigation.Smooth", .AI);

	public struct Cell { public bool walkable; public Vector3 position; public uint32 links; }
	/// Link directions: 0-5 are the axes, 6-9 the horizontal diagonals, 10-25 every offset that also moves up or down.
	public const int32 DirectionCount = 26;
	public Vector3 origin;
	public float cellSize = 1, agentRadius = 0.3f, agentHeight = 1.8f, maxStep = 0.5f, maxSlope = 45;
	public int32 width = 32, height = 1, depth = 32, chunkSize = 16;
	public bool flying;
	/// Line checks over a walking grid cross a whole flat node in one step (on by default; off checks cell by cell,
	/// for comparing).
	public bool useLeafClearance = true;
	/// How many routes each search remembers, to answer the same request again without searching (0: none). Routes
	/// longer than MaxRememberedPoints are not kept, and a change to the grid forgets them all.
	public int32 routeCacheCapacity = 64;

	/// The polygon mesh, when walking uses one (null for a grid). The cell-index calls (cells, Index, Neighbor...) are
	/// for grids; use the world-space ones (FindPath, SamplePosition, LineClear) with a mesh.
	public NavigationMesh Mesh ~ delete _;
	public bool IsNavMesh => Mesh != null;

	/// Makes this data a polygon mesh (which it then owns), dropping any grid. The grid fields describe the mesh's
	/// bounds, with cellSize the surface's cell (NavigationMesh.VoxelsPerCell voxels across).
	public void SetMesh(NavigationMesh mesh)
	{
		delete Mesh;
		Mesh = mesh;
		cells.Clear();
		flying = false;
		let config = mesh.Settings;
		origin = config.min;
		cellSize = config.cellSize * NavigationMesh.VoxelsPerCell;
		width = (int32)Math.Ceiling((config.max.x - origin.x) / cellSize);
		height = 1;
		depth = (int32)Math.Ceiling((config.max.z - origin.z) / cellSize);
		agentRadius = config.radius;
		agentHeight = config.height;
		maxStep = config.climb;
		maxSlope = config.slope;
		Touch();
	}

	/// Puts the mesh's gathered overlay into effect (true for a grid, which takes it at once). False when the rebuild
	/// failed; the last good mesh stays in use.
	public bool CommitNavMesh() => Mesh == null || Mesh.Commit();

	/// Unique across every NavigationData, so an agent notices a rebake that replaced the object as well as an in-place rebuild.
	public int32 Revision;
	static int32 sRevisions;
	public void Touch()
	{
		Revision = ++sRevisions;
	}

	/// True when the last FindPath stopped at its visit budget instead of proving the goal unreachable.
	public bool BudgetExceeded;
	/// How many nodes (or cells, with useNodes off) the last FindPath took from its open list (for profiling).
	public int32 LastVisited;

	Search mSearch = new .() ~ delete _;
	List<Search> mThreadSearches = new .() ~ DeleteContainerAndItems!(_);
	// Connected-region label per cell, rebuilt lazily after the grid changes.
	List<int32> mRegions = new .() ~ delete _;
	int32 mRegionRevision = -1;
	public List<Cell> cells = new .() ~ delete _;

	/// A way across that the grid does not have (a jump, a ladder, a teleporter): from one cell to another, at a
	/// cost. Set from Navigation Link components by the surface; not saved with the grid.
	public struct Link
	{
		public int32 from, to;
		public float cost;
		public bool twoWay;
		/// Which link it is, for the agent crossing it (the surface's index of its Navigation Link).
		public int32 id;
	}

	public List<Link> links = new .() ~ delete _;
	// Cell -> the links that start (or, two-way, end) there, rebuilt with SetLinks.
	Dictionary<int32, List<int32>> mLinksAt = new .() ~ DeleteDictionaryAndValues!(_);
	// Runtime overlays, not saved: how many obstacles block each cell, and each cell's cost multiplier (areas).
	// Empty until something uses them.
	List<uint16> mBlocked = new .() ~ delete _;
	List<float> mCostScale = new .() ~ delete _;

	void TouchOverlay()
	{
		let regionsCurrent = mRegionRevision == Revision && mRegions.Count == cells.Count;
		Touch();
		if (regionsCurrent)
			mRegionRevision = Revision;
	}

	/// A cell an agent may use now: walkable in the bake and not blocked by an obstacle. With a mesh: a polygon number from
	/// Nearest that names a floor polygon now.
	public bool Usable(int32 index) => Mesh != null ? Mesh.Usable(index) : index >= 0 && index < cells.Count && cells[index].walkable && (mBlocked.Count != cells.Count || mBlocked[index] == 0);
	public bool Blocked(int32 index) => mBlocked.Count == cells.Count && index >= 0 && index < cells.Count && mBlocked[index] > 0;
	/// How much more a step into a cell costs than its length (1 normally; more in a costly area).
	public float CostScale(int32 index) => mCostScale.Count == cells.Count && index >= 0 && index < cells.Count ? mCostScale[index] : 1;

	/// Forgets every obstacle and area (before the surface marks them again).
	public void ClearOverlay()
	{
		if (Mesh != null)
		{
			Mesh.ClearOverlay();
			Touch();
			return;
		}
		mBlocked.Clear();
		mCostScale.Clear();
		// The quadtree (NavigationNodes.bf) rebuilds what changed when the revision moves.
		TouchOverlay();
	}

	/// The cells whose floor (or centre, flying) lies inside a box, turned by a rotation about its centre, with the
	/// agent's radius added around it. Calls the function with each one's index.
	public void CellsInBox(Vector3 center, Quaternion rotation, Vector3 halfExtents, bool cylinder, delegate void(int32) each)
	{
		if (cells.Count != width * height * depth)
			return;
		let grow = agentRadius;
		let inverse = rotation.Normalized.Conjugate;
		// The box's reach in the world, to know which cells to look at.
		var reach = Vector3.Zero;
		for (int corner < 8)
		{
			let local = Vector3((corner & 1) != 0 ? halfExtents.x : -halfExtents.x, (corner & 2) != 0 ? halfExtents.y : -halfExtents.y, (corner & 4) != 0 ? halfExtents.z : -halfExtents.z);
			let world = rotation * local;
			reach = .(Math.Max(reach.x, Math.Abs(world.x)), Math.Max(reach.y, Math.Abs(world.y)), Math.Max(reach.z, Math.Abs(world.z)));
		}
		reach += .(grow, grow, grow);
		// Nothing to do for a box wholly outside the grid.
		let extent = Vector3(width * cellSize, flying ? height * cellSize : float.MaxValue, depth * cellSize);
		if (center.x + reach.x < origin.x || center.x - reach.x > origin.x + extent.x || center.z + reach.z < origin.z || center.z - reach.z > origin.z + extent.z)
			return;
		if (flying && (center.y + reach.y < origin.y || center.y - reach.y > origin.y + extent.y))
			return;
		int32 Bound(float p, int32 limit) => (int32)Mathf.Clamp(Math.Floor(p / cellSize), 0, limit - 1);
		let x0 = Bound(center.x - reach.x - origin.x, width);
		let x1 = Bound(center.x + reach.x - origin.x, width);
		let z0 = Bound(center.z - reach.z - origin.z, depth);
		let z1 = Bound(center.z + reach.z - origin.z, depth);
		let y0 = flying ? Bound(center.y - reach.y - origin.y, height) : 0;
		let y1 = flying ? Bound(center.y + reach.y - origin.y, height) : 0;
		// Walking: an agent standing on the cell is in the box when its body (feet to head) overlaps it.
		let headroom = flying ? 0 : agentHeight;
		for (int32 y = y0; y <= y1; y++)
		{
			for (int32 z = z0; z <= z1; z++)
			{
				for (int32 x = x0; x <= x1; x++)
				{
					let index = Index(x, y, z);
					if (!cells[index].walkable)
						continue;
					let local = inverse * (cells[index].position - center);
					if (flying)
					{
						if (Math.Abs(local.y) > halfExtents.y + grow)
							continue;
					}
					// Walking: the agent standing there (feet up to head) overlaps the box.
					else if (local.y > halfExtents.y || local.y + headroom < -halfExtents.y)
						continue;
					if (cylinder)
					{
						if (local.x * local.x + local.z * local.z > (halfExtents.x + grow) * (halfExtents.x + grow))
							continue;
					}
					else if (Math.Abs(local.x) > halfExtents.x + grow || Math.Abs(local.z) > halfExtents.z + grow)
						continue;
					each(index);
				}
			}
		}
	}

	/// Blocks the cells a box covers: a carving Navigation Obstacle, or a blocked Navigation Area (obstacle false: on a
	/// mesh, only the floor inside it, not below it as well). Undone by ClearOverlay.
	public void Block(Vector3 center, Quaternion rotation, Vector3 halfExtents, bool cylinder, bool obstacle = true)
	{
		if (Mesh != null)
		{
			Mesh.AddVolume(center, rotation, halfExtents, 0, cylinder, obstacle);
			Touch();
			return;
		}
		if (mBlocked.Count != cells.Count)
		{
			mBlocked.Clear();
			mBlocked.Resize(cells.Count);
		}
		CellsInBox(center, rotation, halfExtents, cylinder, scope [&] (index) =>
			{
				if (mBlocked[index] < uint16.MaxValue)
					mBlocked[index]++;
			});
		TouchOverlay();
	}

	/// The most a Navigation Area can multiply a step's cost by.
	public const float MaxCostScale = 1000;

	/// Makes the cells in a box cost more to cross (a Navigation Area): agents go round unless the way round is
	/// longer than the extra. The highest multiplier of the areas over a cell counts.
	public void SetCost(Vector3 center, Quaternion rotation, Vector3 halfExtents, float multiplier)
	{
		if (Mesh != null)
		{
			Mesh.AddVolume(center, rotation, halfExtents, Math.Clamp(multiplier, 1, MaxCostScale));
			Touch();
			return;
		}
		if (mCostScale.Count != cells.Count)
		{
			mCostScale.Clear();
			mCostScale.Resize(cells.Count);
			for (int i < mCostScale.Count)
				mCostScale[i] = 1;
		}
		let scale = Math.Clamp(multiplier, 1, MaxCostScale);
		// Areas mark where agents stand, not their whole body.
		let radius = agentRadius;
		agentRadius = 0;
		CellsInBox(center, rotation, halfExtents, false, scope [&] (index) =>
			{
				mCostScale[index] = Math.Max(mCostScale[index], scale);
			});
		agentRadius = radius;
		TouchOverlay();
	}

	/// Sets the off-grid links (replacing those before). Their ends are cell indices.
	public void SetLinks(Span<Link> newLinks)
	{
		int valid = 0;
		bool same = true;
		for (let link in newLinks)
		{
			if (link.from < 0 || link.to < 0 || link.from >= cells.Count || link.to >= cells.Count || link.from == link.to || !link.cost.IsFinite) continue;
			if (valid >= links.Count)
				same = false;
			else
			{
				let old = links[valid];
				if (old.from != link.from || old.to != link.to || old.cost != link.cost || old.twoWay != link.twoWay || old.id != link.id)
					same = false;
			}
			valid++;
		}
		if (same && valid == links.Count) return;

		links.Clear();
		for (let link in newLinks)
		{
			if (link.from >= 0 && link.to >= 0 && link.from < cells.Count && link.to < cells.Count && link.from != link.to && link.cost.IsFinite)
				links.Add(link);
		}
		for (let (key, value) in mLinksAt)
			delete value;
		mLinksAt.Clear();
		for (int32 i < (int32)links.Count)
		{
			void At(int32 cell, int32 link)
			{
				List<int32> list;
				if (!mLinksAt.TryGetValue(cell, out list))
				{
					list = new .();
					mLinksAt[cell] = list;
				}
				list.Add(link);
			}
			At(links[i].from, i);
			if (links[i].twoWay)
				At(links[i].to, i);
		}
		// Regions are joined across links, and nodes list where links start.
		mRegionRevision = -1;
		Touch();
	}

	/// The cell a point is in (walking: the column it stands over), or -1 outside the grid.
	public int32 CellAt(Vector3 point)
	{
		if (Mesh != null) return Nearest(point, Math.Max(maxStep, cellSize));
		let x = (int32)Math.Floor((point.x - origin.x) / cellSize);
		let z = (int32)Math.Floor((point.z - origin.z) / cellSize);
		let y = flying ? (int32)Math.Floor((point.y - origin.y) / cellSize) : 0;
		return Inside(x, y, z) ? Index(x, y, z) : -1;
	}

	/// Each direction's step on each axis, and the direction of each step ((dx + 1) + (dy + 1) * 3 + (dz + 1) * 9), worked
	/// out once: searches look them up for every cell instead of working them out.
	static int32[DirectionCount] sStepX, sStepY, sStepZ;
	static int32[27] sDirectionOf;

	static this()
	{
		for (int i < 27)
			sDirectionOf[i] = -1;
		for (int32 direction < DirectionCount)
		{
			Offset(direction, let x, let y, let z);
			sStepX[direction] = x;
			sStepY[direction] = y;
			sStepZ[direction] = z;
			sDirectionOf[(x + 1) + (y + 1) * 3 + (z + 1) * 9] = direction;
		}
	}

	/// The link direction for a step of (-1..1) cells on each axis, or -1.
	public static int32 DirectionOf(int32 dx, int32 dy, int32 dz)
	{
		if (dx < -1 || dx > 1 || dy < -1 || dy > 1 || dz < -1 || dz > 1)
			return -1;
		return sDirectionOf[(dx + 1) + (dy + 1) * 3 + (dz + 1) * 9];
	}

	/// The directions a search may step in, as bits.
	uint32 UsedDirections => flying ? (1u << DirectionCount) - 1 : 0x3CFu;

	public int32 Index(int32 x, int32 y, int32 z) => x + width * (z + depth * y);
	public bool Inside(int32 x, int32 y, int32 z) => x >= 0 && x < width && y >= 0 && y < height && z >= 0 && z < depth;
	public Vector3 Center(int32 x, int32 y, int32 z) => origin + .((x + 0.5f) * cellSize, (y + 0.5f) * cellSize, (z + 0.5f) * cellSize);
	public static void Offset(int32 direction, out int32 x, out int32 y, out int32 z)
	{
		x = 0;
		y = 0;
		z = 0;
		switch (direction)
		{
		case 0:
			x = 1;
		case 1: x = -1;
		case 2: z = 1;
		case 3: z = -1;
		case 4: y = 1;
		case 5: y = -1;
		case 6,7,8,9:
			x = direction < 8 ? 1 : -1;
			z = (direction & 1) == 0 ? 1 : -1;
		default:
			// Eight horizontal offsets one layer up, then the same eight one layer down.
			let k = (direction - 10) % 8;
			Offset(k < 4 ? k : k + 2, out x, out y, out z);
			y = direction < 18 ? 1 : -1;
		}
	}

	public static int32 Opposite(int32 direction)
	{
		if (direction < 6) return direction ^ 1;
		if (direction < 10) return 15 - direction;
		let k = (direction - 10) % 8;
		return 10 + (direction < 18 ? 8 : 0) + (k < 4 ? k ^ 1 : 11 - k);
	}

	/// Walking surfaces link along X/Z only, diagonals included.
	public bool Uses(int32 direction) => flying || direction < 4 || (direction >= 6 && direction < 10);
	/// Shortest possible travel between two cells over this grid's link directions; never more than the real cost.
	float Estimate(int32 a, int32 b) => Estimate(a % width - b % width, a / (width * depth) - b / (width * depth), (a / width) % depth - (b / width) % depth);

	/// The same for a step of so many cells on each axis.
	float Estimate(int32 stepX, int32 stepY, int32 stepZ)
	{
		var dx = (float)Math.Abs(stepX);
		var dz = (float)Math.Abs(stepZ);
		var dy = (float)Math.Abs(stepY);
		if (dx < dy)
			Swap!(dx, dy);
		if (dx < dz)
			Swap!(dx, dz);
		if (dy < dz)
			Swap!(dy, dz);
		return (dx + 0.41421356f * dy + 0.31783725f * dz) * cellSize;
	}

	public int32 Neighbor(int32 index, int32 direction)
	{
		let x = index % width;
		let z = (index / width) % depth;
		let y = index / (width * depth);
		Offset(direction, let dx, let dy, let dz);
		return Inside(x + dx, y + dy, z + dz) ? Index(x + dx, y + dy, z + dz) : -1;
	}

	public bool Configure(Vector3 minimum, Vector3 size, float spacing, bool flight, int32 chunk, String error)
	{
		if (!minimum.x.IsFinite || !minimum.y.IsFinite || !minimum.z.IsFinite || !spacing.IsFinite || spacing < 0.05f || !size.x.IsFinite || !size.y.IsFinite || !size.z.IsFinite || size.x <= 0 || size.y <= 0 || size.z <= 0)
		{
			error.Set("Navigation size and cell spacing must be finite and positive.");
			return false;
		}
		let w = Math.Ceiling(size.x / spacing);
		let h = flight ? Math.Ceiling(size.y / spacing) : 1;
		let d = Math.Ceiling(size.z / spacing);
		if (w * h * d > MaxCells || w > MaxSide || h > MaxSide || d > MaxSide)
		{
			error.Set("Navigation grid exceeds one million cells. Increase cell size or reduce bounds.");
			return false;
		}
		delete Mesh;
		Mesh = null;
		origin = minimum;
		cellSize = spacing;
		flying = flight;
		chunkSize = Math.Max(chunk, 1);
		width = (int32)w;
		height = (int32)h;
		depth = (int32)d;
		cells.Clear();
		cells.Resize(width * height * depth);
		return true;
	}

	/// Closest usable cell within maxDistance. The cell the point is in wins when it is usable, so a point beside a thin
	/// wall is not moved across it. A region limits the answer to cells connected to that region. With a mesh: the
	/// nearest polygon's number (see NavigationMesh.Nearest); region is not used.
	public int32 Nearest(Vector3 point, float maxDistance, int32 region = -1)
	{
		if (Mesh != null)
		{
			CommitNavMesh();
			return Mesh.Nearest(point, maxDistance, ?);
		}
		using (sNearestProfile.Sample())
		{
			if (!maxDistance.IsFinite || maxDistance < 0 || !point.x.IsFinite || !point.y.IsFinite || !point.z.IsFinite || cells.Count != width * height * depth) return -1;
			if (region >= 0)
				EnsureRegions();
			int32 best = -1;
			float distance = maxDistance * maxDistance;
			int32 Bound(float p, int32 limit) => (int32)Mathf.Clamp(Math.Floor(p / cellSize), 0, limit - 1);
			let cx = (int32)Math.Floor((point.x - origin.x) / cellSize);
			let cz = (int32)Math.Floor((point.z - origin.z) / cellSize);
			let cy = flying ? (int32)Math.Floor((point.y - origin.y) / cellSize) : 0;
			if (Inside(cx, cy, cz))
			{
				let i = Index(cx, cy, cz);
				if (Usable(i) && (region < 0 || mRegions[i] == region) && (cells[i].position - point).LengthSquared <= distance) return i;
			}
			let x0 = Bound(point.x - origin.x - maxDistance, width);
			let x1 = Bound(point.x - origin.x + maxDistance, width);
			let z0 = Bound(point.z - origin.z - maxDistance, depth);
			let z1 = Bound(point.z - origin.z + maxDistance, depth);
			let y0 = flying ? Bound(point.y - origin.y - maxDistance, height) : 0;
			let y1 = flying ? Bound(point.y - origin.y + maxDistance, height) : 0;
			for (int32 y = y0; y <= y1; y++)
			{
				for (int32 z = z0; z <= z1; z++)
				{
					for (int32 x = x0; x <= x1; x++)
					{
						let i = Index(x, y, z);
						if (!Usable(i) || (region >= 0 && mRegions[i] != region)) continue;
						let d = (cells[i].position - point).LengthSquared;
						if (d <= distance)
						{
							distance = d;
							best = i;
						}
					}
				}
			}
			return best;
		}
	}

	/// The nearest usable point within maxDistance (a cell's floor, or centre flying). False when there is none.
	public bool SamplePosition(Vector3 point, float maxDistance, out Vector3 found)
	{
		if (Mesh != null)
		{
			CommitNavMesh();
			return Mesh.Nearest(point, maxDistance, out found) >= 0;
		}
		let cell = Nearest(point, maxDistance);
		found = cell >= 0 ? cells[cell].position : point;
		return cell >= 0;
	}

	/// A random usable point within radius of a centre, reachable from it (for wandering). False when there is none.
	public bool RandomPoint(Vector3 center, float radius, Random random, out Vector3 found)
	{
		if (Mesh != null)
			return RandomMeshPoint(center, radius, random, out found);
		found = center;
		let start = Nearest(center, Math.Max(radius, cellSize * 2));
		if (start < 0)
			return false;
		let region = Region(start);
		// Picks a few spots and takes the first that lands on a usable, connected cell.
		for (int attempt < 32)
		{
			let angle = (float)random.NextDouble() * Math.PI_f * 2;
			let distance = Math.Sqrt((float)random.NextDouble()) * radius;
			var point = center + .(Math.Cos(angle) * distance, 0, Math.Sin(angle) * distance);
			if (flying)
				point.y += ((float)random.NextDouble() * 2 - 1) * radius;
			let cell = CellAt(point);
			if (Usable(cell) && Region(cell) == region)
			{
				found = cells[cell].position;
				return true;
			}
		}
		found = cells[start].position;
		return true;
	}

	/// RandomPoint on a mesh: a sampled point is taken when a path reaches it.
	bool RandomMeshPoint(Vector3 center, float radius, Random random, out Vector3 found)
	{
		found = center;
		if (!radius.IsFinite || radius < 0)
			return false;
		if (!SamplePosition(center, Math.Max(radius, cellSize * 2), let start))
			return false;
		let route = scope List<Vector3>();
		for (int attempt < 32)
		{
			let angle = (float)random.NextDouble() * Math.PI_f * 2;
			let distance = Math.Sqrt((float)random.NextDouble()) * radius;
			let point = center + Vector3(Math.Cos(angle) * distance, 0, Math.Sin(angle) * distance);
			if (SamplePosition(point, cellSize, let candidate) && (candidate - center).Length <= radius && FindPath(start, candidate, route))
			{
				found = candidate;
				return true;
			}
		}
		found = start;
		return (found - center).Length <= radius;
	}

	/// How far an agent can go straight from a towards b before something stops it: true when nothing does.
	public bool Raycast(Vector3 from, Vector3 to, out Vector3 hit) => LineClear(from, to, out hit);
}
