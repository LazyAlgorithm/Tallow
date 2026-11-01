using System;
using System.Collections;

namespace Tallow;

/// The nodes paths are found over: blocks of cells an agent can cross in a straight line. A walking chunk is split
/// like a quadtree, but at the first place its cells change (a wall, a ledge, a costly area) rather than at its middle,
/// until each block is usable, at one cost and linked inside; a flying grid grows boxes cell by cell. A search crosses
/// each node in a straight line, and the walking path is then pulled tight through the edges between them (a funnel).
///
/// The nodes are rebuilt only in chunks whose cells changed (a rebake, an obstacle moving, an area or link changing):
/// each cell's state at the last build is kept to compare with. A node's ways out name the cell beyond, not its node, so
/// rebuilding one chunk leaves its neighbours' nodes as they are.
extension NavigationData
{
	/// The edge a run of ways out crosses, worked out once per rebuild: its ends on this node's side and on the next
	/// node's (see Portal). Not valid where the run is not a straight walking edge.
	struct CrossingPortal
	{
		public bool valid;
		public Vector3 leftNear, rightNear, leftFar, rightFar;
	}

	class Node
	{
		public int32 x, y, z, sizeX, sizeY, sizeZ;
		/// The cost multiplier of all its cells.
		public float scale;
		public bool live;
		/// All its cells are at one height (floor): a straight line anywhere between its outer cell centres (safeMin to
		/// safeMax) stays among usable, linked cells, so line checks cross it in one step.
		public bool flat;
		public float floor;
		public Vector3 safeMin, safeMax;
		/// Ways out, in pairs: a cell of the node, then the cell a grid step beyond it (outside the node).
		public List<int32> exits = new .() ~ delete _;
		/// Each way out's step length (from its cell to the one beyond).
		public List<float> steps = new .() ~ delete _;
		/// The ways out in runs, side by side in one direction into one node: where each run ends (its last way out),
		/// the node it leads to, and the edge it crosses. Worked out after every rebuild, so searches share them.
		public List<int32> runEnds = new .() ~ delete _;
		public List<int32> runNeighbors = new .() ~ delete _;
		public List<CrossingPortal> runPortals = new .() ~ delete _;
		/// Its cells where off-grid links start.
		public List<int32> linkCells = new .() ~ delete _;
	}

	List<Node> mNodes = new .() ~ DeleteContainerAndItems!(_);
	List<int32> mFreeNodes = new .() ~ delete _;
	/// The node each cell is in (-1: not usable now).
	List<int32> mNodeOf = new .() ~ delete _;
	/// Each cell's links, walkability and blocking, and its cost, when the nodes were last built.
	List<uint32> mNodeCellState = new .() ~ delete _;
	List<float> mNodeCellScale = new .() ~ delete _;
	/// The nodes of each chunk (column of chunks, X then Z).
	List<List<int32>> mChunkNodes = new .() ~ DeleteContainerAndItems!(_);
	List<float> mNodeCellHeight = new .() ~ delete _;
	Vector3 mNodeOrigin;
	float mNodeCellSize;
	int32 mNodeRevision = -1;
	int32 mNodeWidth, mNodeHeight, mNodeDepth, mNodeChunk;
	bool mNodeFlying;

	/// Paths are found over the nodes (true), or cell by cell (false: a point per cell, for Smooth to straighten). Off,
	/// the nodes are never built. A search's budget (maxVisited) counts nodes when this is on.
	public bool useNodes = true;
	/// How many nodes the grid is in now.
	public int32 NodeCount
	{
		get
		{
			EnsureNodes(true);
			return (int32)(mNodes.Count - mFreeNodes.Count);
		}
	}

	/// How many chunks the last update of the nodes rebuilt (for tests and profiling).
	public int32 LastRebuiltChunks;

	/// A cell's state, as far as the nodes care: its links, whether it is walkable and whether something blocks it.
	uint32 NodeState(int32 index)
	{
		let cell = cells[index];
		if (!cell.walkable)
			return 0;
		var state = (cell.links & ((1u << DirectionCount) - 1)) | (1u << 30);
		if (mBlocked.Count == cells.Count && mBlocked[index] > 0)
			state |= 1u << 31;
		return state;
	}

	/// Brings the nodes up to date with the grid (when useNodes is on, or always): only the chunks that changed are
	/// rebuilt. Runs before searching, on the calling thread (FindPath, FindPaths).
	void EnsureNodes(bool always = false)
	{
		if (Mesh != null) return;
		using (sNodesProfile.Sample())
		{
			if (!useNodes && !always)
				return;
			if (mNodeRevision == Revision && mNodeOf.Count == cells.Count)
				return;
			mNodeRevision = Revision;
			LastRebuiltChunks = 0;
			if (cells.Count != width * height * depth)
				return;
			let chunk = Math.Max(chunkSize, 1);
			let chunksX = (width + chunk - 1) / chunk, chunksZ = (depth + chunk - 1) / chunk;
			let all = mNodeOf.Count != cells.Count || mNodeWidth != width || mNodeHeight != height || mNodeDepth != depth || mNodeChunk != chunk || mNodeFlying != flying || mNodeOrigin != origin || mNodeCellSize != cellSize;
			if (all)
			{
				ClearAndDeleteItems!(mNodes);
				mFreeNodes.Clear();
				ClearAndDeleteItems!(mChunkNodes);
				for (int i < chunksX * chunksZ)
					mChunkNodes.Add(new .());
				mNodeOf.Clear();
				mNodeOf.Resize(cells.Count);
				mNodeCellState.Clear();
				mNodeCellState.Resize(cells.Count);
				mNodeCellScale.Clear();
				mNodeCellScale.Resize(cells.Count);
				mNodeCellHeight.Clear();
				mNodeCellHeight.Resize(cells.Count);
				mNodeOrigin = origin;
				mNodeCellSize = cellSize;
				mNodeWidth = width;
				mNodeHeight = height;
				mNodeDepth = depth;
				mNodeChunk = chunk;
				mNodeFlying = flying;
			}
			for (int32 cz < chunksZ)
			{
				for (int32 cx < chunksX)
				{
					// Compared cell by cell with the last build (and the record brought up to date as it goes).
					var changed = all;
					let x0 = cx * chunk, z0 = cz * chunk;
					let x1 = Math.Min(x0 + chunk, width), z1 = Math.Min(z0 + chunk, depth);
					for (int32 y < height)
					{
						for (int32 z = z0; z < z1; z++)
						{
							for (int32 x = x0; x < x1; x++)
							{
								let index = Index(x, y, z);
								let state = NodeState(index);
								let scale = CostScale(index);
								if (state != mNodeCellState[index] || scale != mNodeCellScale[index] || cells[index].position.y != mNodeCellHeight[index])
								{
									changed = true;
									mNodeCellState[index] = state;
									mNodeCellScale[index] = scale;
									mNodeCellHeight[index] = cells[index].position.y;
								}
							}
						}
					}
					if (changed)
					{
						RebuildChunk(cx, cz, x0, z0, x1, z1);
						LastRebuiltChunks++;
					}
				}
			}
			// The runs depend on which node each cell beyond is in, so they are worked out once every changed chunk has
			// its nodes. Searches then read them rather than walking each node's edge cells every time.
			let portalScratch = scope List<(Vector3 left, Vector3 right)>();
			for (int32 nodeId < (int32)mNodes.Count)
			{
				let node = mNodes[nodeId];
				node.runEnds.Clear();
				node.runNeighbors.Clear();
				node.runPortals.Clear();
				let exits = node.exits;
				for (int e = 0; e < exits.Count / 2;)
				{
					let from = exits[e * 2], to = exits[e * 2 + 1];
					let next = mNodeOf[to];
					var last = e;
					while (last + 1 < exits.Count / 2 && exits[last * 2 + 3] - exits[last * 2 + 2] == to - from && mNodeOf[exits[last * 2 + 3]] == next && Beside(exits[last * 2], exits[last * 2 + 2]))
						last++;
					node.runEnds.Add((int32)last);
					node.runNeighbors.Add(next);
					CrossingPortal portal = default;
					let step = to - from;
					if (!flying && next >= 0 && next != nodeId && (Math.Abs(step) == 1 || Math.Abs(step) == width))
					{
						portalScratch.Clear();
						Portal(nodeId, next, from, to, portalScratch);
						if (portalScratch.Count == 2)
						{
							portal.valid = true;
							portal.leftNear = portalScratch[0].left;
							portal.rightNear = portalScratch[0].right;
							portal.leftFar = portalScratch[1].left;
							portal.rightFar = portalScratch[1].right;
						}
					}
					node.runPortals.Add(portal);
					e = last + 1;
				}
			}
			// Where links start, for every node (links are few, and change on their own).
			for (let node in mNodes)
				node.linkCells.Clear();
			for (let cell in mLinksAt.Keys)
			{
				let node = cell >= 0 && cell < mNodeOf.Count ? mNodeOf[cell] : -1;
				if (node >= 0)
					mNodes[node].linkCells.Add(cell);
			}
		}
	}

	void RebuildChunk(int32 cx, int32 cz, int32 x0, int32 z0, int32 x1, int32 z1)
	{
		let list = mChunkNodes[cx + cz * ((width + mNodeChunk - 1) / mNodeChunk)];
		for (let id in list)
		{
			let node = mNodes[id];
			node.live = false;
			node.exits.Clear();
			node.steps.Clear();
			node.linkCells.Clear();
			mFreeNodes.Add(id);
		}
		list.Clear();
		for (int32 y < height)
		{
			for (int32 z = z0; z < z1; z++)
			{
				for (int32 x = x0; x < x1; x++)
					mNodeOf[Index(x, y, z)] = -1;
			}
		}
		if (!flying)
		{
			SplitQuad(list, x0, z0, x1 - x0, z1 - z0);
			return;
		}
		// Each cell not yet in a node starts one, grown along X, then Z, then (flying) Y while the block stays open.
		for (int32 y < height)
		{
			for (int32 z = z0; z < z1; z++)
			{
				for (int32 x = x0; x < x1; x++)
				{
					let index = Index(x, y, z);
					if (mNodeOf[index] >= 0 || !Usable(index))
						continue;
					let scale = CostScale(index);
					int32 sizeX = 1, sizeY = 1, sizeZ = 1;
					while (x + sizeX < x1 && Open(x + sizeX - 1, y, z, 2, 1, 1, scale))
						sizeX++;
					// Each row (layer) added is checked with the one before it, which covers every link between them.
					while (z + sizeZ < z1 && Open(x, y, z + sizeZ - 1, sizeX, 1, 2, scale))
						sizeZ++;
					while (flying && y + sizeY < height && Open(x, y + sizeY - 1, z, sizeX, 2, sizeZ, scale))
						sizeY++;
					MakeNode(list, x, y, z, sizeX, sizeY, sizeZ, scale);
				}
			}
		}
	}

	void SplitQuad(List<int32> list, int32 x, int32 z, int32 sizeX, int32 sizeZ, int32 level = 0)
	{
		if (sizeX <= 0 || sizeZ <= 0)
			return;
		let index = Index(x, 0, z);
		let scale = CostScale(index);
		if (Open(x, 0, z, sizeX, 1, sizeZ, scale))
		{
			MakeNode(list, x, 0, z, sizeX, 1, sizeZ, scale);
			return;
		}
		// Split where the cells first change rather than at the middle, so a wall off the middle does not cut a long open
		// corridor into a staircase of single cells.
		var splitX = sizeX / 2, splitZ = sizeZ / 2;
		bool boundary = false, anyUsable = false;
		let firstUsable = Usable(index);
		for (int32 cz = z; cz < z + sizeZ; cz++)
		{
			for (int32 cx = x; cx < x + sizeX; cx++)
			{
				let cell = Index(cx, 0, cz);
				let usable = Usable(cell);
				anyUsable |= usable;
				if (boundary || level >= 16)
					continue;
				let different = usable != firstUsable || (usable && CostScale(cell) != scale);
				let brokenX = usable && cx > x && (cells[cell].links & (1u << 1)) == 0;
				let brokenZ = usable && cz > z && (cells[cell].links & (1u << 3)) == 0;
				if (!different && !brokenX && !brokenZ)
					continue;
				splitX = (cx > x && (different || brokenX)) ? cx - x : sizeX;
				splitZ = (cz > z && (different || brokenZ)) ? cz - z : sizeZ;
				boundary = true;
			}
		}
		if (!anyUsable || (sizeX == 1 && sizeZ == 1))
			return;
		SplitQuad(list, x, z, splitX, splitZ, level + 1);
		SplitQuad(list, x + splitX, z, sizeX - splitX, splitZ, level + 1);
		SplitQuad(list, x, z + splitZ, splitX, sizeZ - splitZ, level + 1);
		SplitQuad(list, x + splitX, z + splitZ, sizeX - splitX, sizeZ - splitZ, level + 1);
	}

	/// Whether a block of cells can be in one node: none in a node yet, every cell usable and at this cost, and each
	/// linked to every neighbour inside the block in every direction the grid uses.
	bool Open(int32 x, int32 y, int32 z, int32 sizeX, int32 sizeY, int32 sizeZ, float scale)
	{
		let used = UsedDirections;
		for (int32 cy = y; cy < y + sizeY; cy++)
		{
			for (int32 cz = z; cz < z + sizeZ; cz++)
			{
				for (int32 cx = x; cx < x + sizeX; cx++)
				{
					let index = Index(cx, cy, cz);
					if (mNodeOf[index] >= 0 || !Usable(index) || CostScale(index) != scale)
						return false;
					let links = cells[index].links;
					for (int32 direction < DirectionCount)
					{
						if ((used & ((uint32)1 << direction)) == 0)
							continue;
						let nx = cx + sStepX[direction], ny = cy + sStepY[direction], nz = cz + sStepZ[direction];
						if (nx < x || nx >= x + sizeX || ny < y || ny >= y + sizeY || nz < z || nz >= z + sizeZ)
							continue;
						if ((links & ((uint32)1 << direction)) == 0)
							return false;
					}
				}
			}
		}
		return true;
	}

	void MakeNode(List<int32> list, int32 x, int32 y, int32 z, int32 sizeX, int32 sizeY, int32 sizeZ, float scale)
	{
		int32 id;
		Node node;
		if (!mFreeNodes.IsEmpty)
		{
			id = mFreeNodes.PopBack();
			node = mNodes[id];
		}
		else
		{
			id = (int32)mNodes.Count;
			node = new Node();
			mNodes.Add(node);
		}
		node.x = x;
		node.y = y;
		node.z = z;
		node.sizeX = sizeX;
		node.sizeY = sizeY;
		node.sizeZ = sizeZ;
		node.scale = scale;
		node.live = true;
		node.flat = !flying;
		node.floor = cells[Index(x, y, z)].position.y;
		node.safeMin = origin + .((x + 0.5f) * cellSize, 0, (z + 0.5f) * cellSize);
		node.safeMax = origin + .((x + sizeX - 0.5f) * cellSize, 0, (z + sizeZ - 0.5f) * cellSize);
		list.Add(id);
		for (int32 cy = y; cy < y + sizeY; cy++)
		{
			for (int32 cz = z; cz < z + sizeZ; cz++)
			{
				for (int32 cx = x; cx < x + sizeX; cx++)
				{
					let cell = Index(cx, cy, cz);
					mNodeOf[cell] = id;
					if (cells[cell].position.y != node.floor)
						node.flat = false;
				}
			}
		}
		// The ways out direction by direction, each face's cells in order, so the search finds runs of them side by side
		// (FindNodePath). Only the cells on its faces lead out.
		let used = UsedDirections;
		for (int32 direction < DirectionCount)
		{
			if ((used & ((uint32)1 << direction)) == 0)
				continue;
			let sx = sStepX[direction], sy = sStepY[direction], sz = sStepZ[direction];
			for (int32 cy = y; cy < y + sizeY; cy++)
			{
				for (int32 cz = z; cz < z + sizeZ; cz++)
				{
					for (int32 cx = x; cx < x + sizeX; cx++)
					{
						let nx = cx + sx, ny = cy + sy, nz = cz + sz;
						if (nx >= x && nx < x + sizeX && ny >= y && ny < y + sizeY && nz >= z && nz < z + sizeZ)
							continue;
						let index = Index(cx, cy, cz);
						if ((cells[index].links & ((uint32)1 << direction)) == 0 || !Inside(nx, ny, nz))
							continue;
						node.exits.Add(index);
						node.exits.Add(Index(nx, ny, nz));
						node.steps.Add((cells[Index(nx, ny, nz)].position - cells[index].position).Length);
					}
				}
			}
		}
	}

	/// A* over the nodes, from cell start to cell goal: each node is entered at a cell and crossed in a straight line to
	/// the cell it leaves by. The path is the cells it goes in and out by, with the start and goal.
	bool FindNodePath(int32 start, int32 goal, List<Vector3> path, List<int32> legLinks, int32 maxVisited, Search search, bool withLinks)
	{
		using (sSearchProfile.Sample())
		{
			let startNode = mNodeOf[start], goalNode = mNodeOf[goal];
			if (startNode < 0 || goalNode < 0)
				return false;
			search.stamp++;
			search.open.Clear();
			let goalPosition = cells[goal].position;
			let cellData = cells.Ptr;
			let nodeOf = mNodeOf.Ptr;
			let closed = search.closed.Ptr;
			let seen = search.seen.Ptr;
			let cost = search.cost.Ptr;
			let score = search.score.Ptr;
			search.cost[startNode] = 0;
			search.parent[startNode] = -1;
			search.entry[startNode] = start;
			search.seen[startNode] = search.stamp;
			let first = startNode == goalNode ? (goalPosition - cellData[start].position).Length * mNodes[startNode].scale : (goalPosition - cellData[start].position).Length;
			search.score[startNode] = first;
			Push(search.open, .(startNode, first));
			int visited = 0;
			// The nodes a pop made cheaper, pushed once each when it is done (not once for every cheaper way in).
			let touched = search.touched;
			// Considers going from this node into the next by a step from cell `from` to cell `to`, at a cost.
			void Reach(int32 node, int32 next, int32 from, int32 to, float g, int32 link, int32 portal = -1)
			{
				let h = next == goalNode ? (goalPosition - cellData[to].position).Length * mNodes[next].scale : (goalPosition - cellData[to].position).Length * 1.001f;
				let f = g + h;
				if (seen[next] == search.stamp && f >= score[next])
					return;
				// Each node is taken from the open list once per search, so a node whose parent is already this one was
				// touched in this step: no need to look through the touched list.
				let firstTouch = seen[next] != search.stamp || search.parent[next] != node;
				cost[next] = g;
				score[next] = f;
				search.parent[next] = node;
				search.entry[next] = to;
				search.exit[next] = from;
				search.parentLink[next] = link;
				search.portal[next] = portal;
				if (firstTouch)
					touched.Add(next);
				seen[next] = search.stamp;
			}
			while (search.open.Count > 0)
			{
				let id = Pop(search.open).id;
				if (closed[id] == search.stamp)
					continue;
				if (visited >= maxVisited)
				{
					search.budgetExceeded = true;
					break;
				}
				closed[id] = search.stamp;
				visited++;
				search.visited = (int32)visited;
				if (id == goalNode)
				{
					NodePath(search, start, goal, goalNode, path, legLinks);
					return true;
				}
				let node = mNodes[id];
				let here = cellData[search.entry[id]].position;
				let g0 = cost[id];
				let exits = node.exits.Ptr;
				let steps = node.steps.Ptr;
				touched.Clear();
				let count = node.exits.Count / 2;
				for (int e = 0, run = 0; e < count; run++)
				{
					let next = node.runNeighbors[run];
					// The run of ways out beside this one in the same direction into the same node.
					let last = (int)node.runEnds[run];
					let runFirst = e;
					e = last + 1;
					if (next < 0 || next == id || closed[next] == search.stamp)
						continue;
					let nextScale = mNodes[next].scale;
					let toGoal = next == goalNode ? nextScale : 1.001f;
					// Along a straight run the cost in by each (straight to it, the step, then the estimate on) only falls
					// and then rises, so the cheapest is found by halving, not by trying each.
					float Total(int index) => (cellData[exits[index * 2]].position - here).Length * node.scale + steps[index] * nextScale + (goalPosition - cellData[exits[index * 2 + 1]].position).Length * toGoal;
					var low = runFirst, high = last;
					// Between two flat nodes at the same cost the cheapest crossing is close to where the straight line from
					// here to the goal crosses the edge: try that first, then halve towards the cheapest on whichever side
					// is cheaper. It finds a crossing as cheap as halving from the run's ends would, sooner.
					if (high - low >= 3 && node.flat && mNodes[next].flat && node.runPortals[run].valid && Math.Abs(node.scale - toGoal) <= node.scale * 0.002f)
					{
						let firstFrom = cellData[exits[runFirst * 2]].position;
						let firstTo = cellData[exits[runFirst * 2 + 1]].position;
						let varyX = cellData[exits[last * 2]].position.x != firstFrom.x;
						let nearDistance = Math.Abs(varyX ? here.z - firstFrom.z : here.x - firstFrom.x);
						let farOffset = varyX ? goalPosition.z - firstTo.z : goalPosition.x - firstTo.x;
						let farHeight = goalPosition.y - firstTo.y;
						let farDistance = Math.Sqrt(farOffset * farOffset + farHeight * farHeight);
						let denominator = nearDistance + farDistance;
						if (denominator > 0.000001f)
						{
							let along = ((varyX ? here.x : here.z) * farDistance + (varyX ? goalPosition.x : goalPosition.z) * nearDistance) / denominator;
							let guess = Math.Clamp(runFirst + (int)Math.Floor((along - (varyX ? firstFrom.x : firstFrom.z)) / cellSize + 0.5f), low, high);
							let value = Total(guess);
							if (guess > low && Total(guess - 1) <= value)
								high = guess - 1;
							else if (guess < high && Total(guess + 1) < value)
								low = guess + 1;
							else
							{
								low = guess;
								high = guess;
							}
						}
					}

					while (low < high)
					{
						let middle = (low + high) / 2;
						if (Total(middle + 1) < Total(middle))
							low = middle + 1;
						else
							high = middle;
					}
					let g = g0 + (cellData[exits[low * 2]].position - here).Length * node.scale + steps[low] * nextScale;
					Reach(id, next, exits[low * 2], exits[low * 2 + 1], g, -1, (int32)run);
				}
				if (withLinks)
				{
					for (let cell in node.linkCells)
					{
						if (!mLinksAt.TryGetValue(cell, let starting))
							continue;
						for (let index in starting)
						{
							let link = links[index];
							let to = link.from == cell ? link.to : link.from;
							let next = nodeOf[to];
							if (next < 0 || next == id || closed[next] == search.stamp)
								continue;
							let g = g0 + (cellData[cell].position - here).Length * node.scale + Math.Max(link.cost, 0.01f);
							Reach(id, next, cell, to, g, link.id);
						}
					}
				}
				for (let next in touched)
					Push(search.open, .(next, score[next]));
			}
			return false;
		}
	}

	/// Whether two cells are a single step apart along one axis.
	bool Beside(int32 a, int32 b)
	{
		let difference = Math.Abs(b - a);
		return difference == 1 || difference == width || difference == width * depth;
	}

	/// The path a node search found. Walking: pulled tight through the edges the nodes share (a funnel), so it is as
	/// straight as the corridor allows (Smooth may still cut corners outside it); a link's leg is kept as it is, and each
	/// stretch between links pulled on its own. Flying: the start, each crossing's cells (out of one node, into the next), and the goal.
	void NodePath(Search search, int32 start, int32 goal, int32 goalNode, List<Vector3> path, List<int32> legLinks)
	{
		using (sCorridorProfile.Sample())
		{
			// The nodes in order, and how each was entered (the crossing from the one before).
			let corridor = search.corridor;
			corridor.Clear();
			var cursor = goalNode;
			while (cursor >= 0)
			{
				corridor.Add(cursor);
				cursor = search.parent[cursor];
			}
			for (int i < corridor.Count / 2)
				Swap!(corridor[i], corridor[corridor.Count - 1 - i]);
			if (flying)
			{
				var last = start;
				path.Add(cells[start].position);
				for (int i = 1; i < corridor.Count; i++)
				{
					let node = corridor[i];
					let from = search.exit[node], to = search.entry[node];
					if (from != last)
					{
						legLinks?.Add(-1);
						path.Add(cells[from].position);
					}
					legLinks?.Add(search.parentLink[node]);
					path.Add(cells[to].position);
					last = to;
				}
				if (goal != last)
				{
					legLinks?.Add(-1);
					path.Add(cells[goal].position);
				}
				legLinks?.Add(-1);
				return;
			}
			let portals = search.portals;
			var runStart = cells[start].position;
			var first = 0;
			for (int i = 1; i <= corridor.Count; i++)
			{
				let link = i < corridor.Count ? search.parentLink[corridor[i]] : -1;
				if (i < corridor.Count && link < 0)
					continue;
				// A stretch of nodes first ..< i with no link between them: from runStart to where it is left.
				let runEnd = i < corridor.Count ? cells[search.exit[corridor[i]]].position : cells[goal].position;
				portals.Clear();
				portals.Add((runStart, runStart));
				for (int k = first + 1; k < i; k++)
					Portal(corridor[k - 1], corridor[k], search.exit[corridor[k]], search.entry[corridor[k]], portals, search.portal[corridor[k]]);
				portals.Add((runEnd, runEnd));
				let before = path.Count;
				Funnel(portals, path);
				// The funnel's first point is where the stretch starts, already in the path after a link.
				if (before > 0 && path.Count > before)
					path.RemoveAt(before);
				// A one-step edge on a straight line leaves a corner that is not one: drop points in line with their
				// neighbours (never the stretch's own ends, where links start and land).
				for (int p = Math.Max(before, 1); p + 1 < path.Count;)
				{
					let a = path[p - 1], b = path[p], c = path[p + 1];
					let across = Vector3(c.x - a.x, 0, c.z - a.z);
					let length = across.Length;
					let along = (b.x - a.x) * across.x + (b.z - a.z) * across.z;
					if (length > 0 && Math.Abs(Area2(a, b, c)) <= length * cellSize * 0.01f && along >= 0 && along <= length * length)
						path.RemoveAt(p);
					else
						p++;
				}
				for (int p = before; p < path.Count; p++)
					legLinks?.Add(-1);
				if (i < corridor.Count)
				{
					// The link's leg: from its start (the end of this stretch) to where it lands.
					if (legLinks != null && legLinks.Count > 0)
						legLinks[legLinks.Count - 1] = link;
					runStart = cells[search.entry[corridor[i]]].position;
					legLinks?.Add(-1);
					path.Add(runStart);
					first = i;
				}
			}
			// Where the nodes meet can bend a path that has a clear straight way. With no costly areas or links to keep
			// to, the straight line is the shortest route.
			if (path.Count == 3 && mCostScale.IsEmpty && links.IsEmpty && LineClear(path.Front, path.Back, ?))
			{
				let end = path.Back;
				path.RemoveRange(1, path.Count - 1);
				path.Add(end);
				if (legLinks != null)
				{
					legLinks.Clear();
					legLinks.Add(-1);
					legLinks.Add(-1);
				}
			}
			// The last point has no leg after it: its entry is already -1.
		}
	}

	/// The edge two neighbouring nodes share, going from a into b, as two portals (left and right ends): the row of
	/// cell centres on a's side, then the row on b's, across the unbroken run of linked steps that holds the search's
	/// crossing (from -> to). A line between the rows stays among linked cells only inside the run: where the grid does
	/// not link a step (a ledge, a wall's end, a blocked cell) the edge is broken, and a line clipping past the run's end
	/// would cross the square beside it. Nodes that touch only at a corner cross by the diagonal's two cells, as a cell
	/// path would. Walking grids only.
	void Portal(int32 a, int32 b, int32 from, int32 to, List<(Vector3 left, Vector3 right)> portals, int32 run = -1)
	{
		if (run >= 0 && mNodes[a].runPortals[run].valid)
		{
			let portal = mNodes[a].runPortals[run];
			portals.Add((portal.leftNear, portal.rightNear));
			portals.Add((portal.leftFar, portal.rightFar));
			return;
		}
		let na = mNodes[a], nb = mNodes[b];
		// Which side of a the edge is on: the step across it, and the cells either side at a place along it.
		int32 stepX = 0, stepZ = 0;
		if (nb.x == na.x + na.sizeX)
			stepX = 1;
		else if (nb.x + nb.sizeX == na.x)
			stepX = -1;
		else if (nb.z == na.z + na.sizeZ)
			stepZ = 1;
		else if (nb.z + nb.sizeZ == na.z)
			stepZ = -1;
		// Along the edge: X for a step in Z, Z for a step in X.
		let low = stepX != 0 ? Math.Max(na.z, nb.z) : Math.Max(na.x, nb.x);
		let high = stepX != 0 ? Math.Min(na.z + na.sizeZ, nb.z + nb.sizeZ) : Math.Min(na.x + na.sizeX, nb.x + nb.sizeX);
		let direction = DirectionOf(stepX, 0, stepZ);
		int32 Near(int32 along) => stepX > 0 ? Index(na.x + na.sizeX - 1, 0, along) : stepX < 0 ? Index(na.x, 0, along) : stepZ > 0 ? Index(along, 0, na.z + na.sizeZ - 1) : Index(along, 0, na.z);
		bool Linked(int32 along)
		{
			let near = Near(along), far = near + stepX + stepZ * width;
			return (cells[near].links & (1u << direction)) != 0 || (cells[far].links & (1u << Opposite(direction))) != 0;
		}
		if ((stepX == 0 && stepZ == 0) || low >= high)
		{
			portals.Add((cells[from].position, cells[from].position));
			portals.Add((cells[to].position, cells[to].position));
			return;
		}
		// The linked step nearest where the search crossed, then the run of them round it.
		let crossed = Math.Clamp(stepX != 0 ? (from / width) % depth : from % width, low, high - 1);
		var first = -1;
		for (int32 offset = 0; first < 0 && offset < high - low; offset++)
		{
			if (crossed - offset >= low && Linked(crossed - offset))
				first = crossed - offset;
			else if (crossed + offset < high && Linked(crossed + offset))
				first = crossed + offset;
		}
		if (first < 0)
		{
			portals.Add((cells[from].position, cells[from].position));
			portals.Add((cells[to].position, cells[to].position));
			return;
		}
		var start = (int32)first, end = (int32)first;
		while (start > low && Linked(start - 1))
			start--;
		while (end + 1 < high && Linked(end + 1))
			end++;
		// The left end going across: higher Z stepping +X, lower Z stepping -X, lower X stepping +Z, higher X stepping -Z.
		let leftIsEnd = stepX > 0 || stepZ < 0;
		let left = leftIsEnd ? end : start, right = leftIsEnd ? start : end;
		let step = stepX + stepZ * width;
		portals.Add((cells[Near(left)].position, cells[Near(right)].position));
		portals.Add((cells[Near(left) + step].position, cells[Near(right) + step].position));
	}

	/// Twice the signed area of the triangle a, b, c on the ground (X and Z).
	static float Area2(Vector3 a, Vector3 b, Vector3 c)
	{
		let abx = b.x - a.x, abz = b.z - a.z;
		let acx = c.x - a.x, acz = c.z - a.z;
		return acx * abz - abx * acz;
	}

	/// The shortest line through a row of portals (the first and last are the start and end points), corner by
	/// corner: the simple stupid funnel.
	static void Funnel(List<(Vector3 left, Vector3 right)> portals, List<Vector3> path)
	{
		var apex = portals[0].left;
		var left = apex, right = apex;
		int apexIndex = 0, leftIndex = 0, rightIndex = 0;
		path.Add(apex);
		bool Same(Vector3 a, Vector3 b) => Math.Abs(a.x - b.x) < 0.0001f && Math.Abs(a.z - b.z) < 0.0001f;
		for (int i = 1; i < portals.Count; i++)
		{
			let nextLeft = portals[i].left, nextRight = portals[i].right;
			// The right side closes in.
			if (Area2(apex, right, nextRight) <= 0)
			{
				if (Same(apex, right) || Area2(apex, left, nextRight) > 0)
				{
					right = nextRight;
					rightIndex = i;
				}
				else
				{
					// It crossed the left side: the left corner is on the path, and the funnel starts again there.
					apex = left;
					apexIndex = leftIndex;
					if (!Same(path.Back, apex))
						path.Add(apex);
					right = left = apex;
					rightIndex = leftIndex = apexIndex;
					i = apexIndex;
					continue;
				}
			}
			// The left side closes in.
			if (Area2(apex, left, nextLeft) >= 0)
			{
				if (Same(apex, left) || Area2(apex, right, nextLeft) < 0)
				{
					left = nextLeft;
					leftIndex = i;
				}
				else
				{
					apex = right;
					apexIndex = rightIndex;
					if (!Same(path.Back, apex))
						path.Add(apex);
					right = left = apex;
					rightIndex = leftIndex = apexIndex;
					i = apexIndex;
					continue;
				}
			}
		}
		let end = portals.Back.left;
		if (!Same(path.Back, end))
			path.Add(end);
	}
}
