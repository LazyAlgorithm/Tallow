using System;
using System.Collections;
using System.IO;
using Tallow;

namespace NavigationTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	/// A path's length.
	static float Length(List<Vector3> path)
	{
		float length = 0;
		for (int i = 1; i < path.Count; i++)
			length += (path[i] - path[i - 1]).Length;
		return length;
	}

	/// Whether every leg of a path can be walked straight (LineClear).
	static bool LegsClear(NavigationData data, List<Vector3> path)
	{
		for (int i = 1; i < path.Count; i++)
		{
			if (!data.LineClear(path[i - 1], path[i], ?))
				return false;
		}
		return true;
	}

	/// Whether every leg of a path keeps to the grid: each point along it over a usable cell, each cell it passes into
	/// linked to the last. Laxer than LineClear, which also wants the cells round each point linked, and so refuses the
	/// diagonal steps the baker links round a wall's end.
	static bool LegsOnGrid(NavigationData data, List<Vector3> path)
	{
		for (int i = 1; i < path.Count; i++)
		{
			var previous = data.CellAt(path[i - 1]);
			let steps = (int)Math.Ceiling((path[i] - path[i - 1]).Length / (data.cellSize * 0.1f));
			for (int s = 1; s <= steps; s++)
			{
				let cell = data.CellAt(Vector3.Lerp(path[i - 1], path[i], (float)s / steps));
				if (!data.Usable(cell))
					return false;
				if (cell == previous)
					continue;
				let dx = cell % data.width - previous % data.width, dz = cell / data.width - previous / data.width;
				let direction = NavigationData.DirectionOf(dx, 0, dz);
				if (direction < 0 || ((data.cells[previous].links & (1u << direction)) == 0 && (data.cells[cell].links & (1u << NavigationData.Opposite(direction))) == 0))
					return false;
				previous = cell;
			}
		}
		return true;
	}

	static NavigationSurface Floor(Scene scene, Vector3 at, Vector3 size, String name)
	{
		let floor = scene.CreateGameObject(name);
		floor.Transform.Position = at + Vector3(size.x * 0.5f, -0.5f, size.z * 0.5f);
		floor.AddComponent<BoxCollider>().size = .(size.x, 1, size.z);
		return null;
	}

	/// Paths found together on the job threads, straightening along walls, and the job threads themselves.
	static bool Batches()
	{
		bool ok = true;
		var total = 0;
		let seen = scope int32[1000];
		Jobs.For(1000, scope [&] (index) =>
			{
				seen[index]++;
			}
			, 7);
		for (let count in seen)
			total += count == 1 ? 1 : 0;
		ok &= Check(total == 1000, scope $"Jobs.For runs every item once ({total} of 1000, {Jobs.ThreadCount} threads)");

		let scene = scope Scene();
		Scene.Active = scene;
		// The benchmark's maze: three walls across a 32 m floor, so paths wind round them.
		let floor = scene.CreateGameObject("Floor");
		floor.Transform.Position = .(16, -0.5f, 16);
		floor.AddComponent<BoxCollider>().size = .(32, 1, 32);
		for (int i < 3)
		{
			let wall = scene.CreateGameObject("Wall");
			wall.Transform.Position = .(8 + i * 8, 1.5f, (i % 2) == 0 ? 10 : 22);
			wall.AddComponent<BoxCollider>().size = .(1, 3, 20);
		}
		let surface = scene.CreateGameObject("Navigation").AddComponent<NavigationSurface>();
		surface.backend = .Grid;
		surface.size = .(32, 5, 32);
		surface.cellSize = 0.5f;
		ok &= Check(surface.Bake(), "the maze bakes");
		let data = surface.Data;
		let alone = scope List<Vector3>();
		ok &= Check(data.FindPath(.(2, 0, 2), .(30, 0, 30), alone), "a path through the maze");
		data.Smooth(alone);
		// Along a wall the line runs over the last row of cells beside it: one leg, not one per cell.
		ok &= Check(alone.Count <= 20, scope $"smoothing straightens the legs along the walls ({alone.Count} points)");
		let requests = scope NavigationData.PathRequest[64];
		let paths = scope List<List<Vector3>>();
		defer
		{
			ClearAndDeleteItems!(paths);
		}
		for (int i < requests.Count)
		{
			let path = new List<Vector3>();
			paths.Add(path);
			requests[i] = .() { from = .(2, 0, 2 + (i % 10) * 0.1f), to = .(30, 0, 30 - (i % 10) * 0.1f), path = path, snapDistance = 2, withLinks = true, smooth = true };
		}
		data.FindPaths(requests);
		bool same = true;
		for (int i < requests.Count)
		{
			let single = scope List<Vector3>();
			data.FindPath(requests[i].from, requests[i].to, single);
			data.Smooth(single);
			same &= requests[i].found && single.Count == requests[i].path.Count;
			for (int p < Math.Min(single.Count, requests[i].path.Count))
				same &= (single[p] - requests[i].path[p]).Length < 0.0001f;
		}
		ok &= Check(same, "64 paths found together match the same paths found one at a time");
		return ok;
	}

	/// The quadtree: paths over nodes keep to the grid, follow its changes, and match cell searches' lengths.
	static bool Nodes()
	{
		bool ok = true;
		let scene = scope Scene();
		Scene.Active = scene;
		Floor(scene, .(0, 0, 0), .(16, 1, 8), "Floor");
		let surface = scene.CreateGameObject("Navigation").AddComponent<NavigationSurface>();
		surface.backend = .Grid;
		surface.size = .(16, 5, 8);
		surface.cellSize = 0.5f;
		ok &= Check(surface.Bake(), "the ledge floor bakes");
		let data = surface.Data;
		// A ledge: the steps across z = 4 are cut (both ways, as the baker links) everywhere but at the two ends, so the
		// nodes either side share a broken edge.
		for (int32 x = 1; x < data.width - 1; x++)
		{
			for (int32 side < 2)
			{
				let cell = data.Index(x, 0, 7 + side);
				for (int32 direction < NavigationData.DirectionCount)
				{
					NavigationData.Offset(direction, let dx, let dy, let dz);
					if (dz == (side == 0 ? 1 : -1) && x + dx >= 1 && x + dx < data.width - 1)
						data.cells[cell].links &= ~(1u << direction);
				}
			}
		}
		data.Touch();
		List<Vector3> path = scope .();
		ok &= Check(data.FindPath(.(8, 0, 3), .(8, 0, 5), path) && LegsClear(data, path) && Length(path) > 8, scope $"a path over the nodes goes round a ledge, not across it ({Length(path):F1} m)");
		data.useNodes = false;
		let cells = scope List<Vector3>();
		data.FindPath(.(8, 0, 3), .(8, 0, 5), cells);
		data.Smooth(cells);
		data.useNodes = true;
		data.Smooth(path);
		// The cell path may cut past the ledge's end on a diagonal; the nodes cross by a straight step, a little longer.
		ok &= Check(LegsClear(data, path) && Length(path) <= Length(cells) * 1.03f, scope $"smoothed, it is within 3% of the cell search's ({Length(path):F2} m, {Length(cells):F2} m)");
		// Blocking straight through the data (not through an obstacle component) is seen by the next search.
		let before = data.NodeCount;
		data.Block(.(4, 0, 1), .Identity, .(0.5f, 1, 1), false);
		ok &= Check(data.FindPath(.(2, 0, 1), .(6, 0, 1), path) && LegsClear(data, path) && Length(path) > 4.1f && data.NodeCount != before && data.LastRebuiltChunks > 0 && data.LastRebuiltChunks < 8, scope $"a block splits only its chunks' nodes ({data.LastRebuiltChunks} chunks) and is walked round ({Length(path):F1} m)");
		data.ClearOverlay();
		ok &= Check(data.FindPath(.(2, 0, 1), .(6, 0, 1), path) && Length(path) < 4.01f && data.NodeCount == before, "and clearing it puts the nodes back");

		// The maze: every leg of a node path keeps to the grid, as the cell search's do, at about its length once smoothed.
		let maze = scope Scene();
		Scene.Active = maze;
		let floor = maze.CreateGameObject("Floor");
		floor.Transform.Position = .(16, -0.5f, 16);
		floor.AddComponent<BoxCollider>().size = .(32, 1, 32);
		for (int i < 3)
		{
			let wall = maze.CreateGameObject("Wall");
			wall.Transform.Position = .(8 + i * 8, 1.5f, (i % 2) == 0 ? 10 : 22);
			wall.AddComponent<BoxCollider>().size = .(1, 3, 20);
		}
		let mazeSurface = maze.CreateGameObject("Navigation").AddComponent<NavigationSurface>();
		mazeSurface.backend = .Grid;
		mazeSurface.size = .(32, 5, 32);
		mazeSurface.cellSize = 0.5f;
		mazeSurface.Bake();
		let mazeData = mazeSurface.Data;
		bool clear = true, cellsClear = true, short = true;
		float worst = 0;
		for (int i < 20)
		{
			let from = Vector3(1 + (i * 7) % 30, 0, 1 + (i * 13) % 30), to = Vector3(31 - (i * 11) % 30, 0, 31 - (i * 5) % 30);
			if (!mazeData.FindPath(from, to, path))
				continue;
			clear &= LegsOnGrid(mazeData, path);
			mazeData.Smooth(path);
			clear &= LegsOnGrid(mazeData, path);
			mazeData.useNodes = false;
			mazeData.FindPath(from, to, cells);
			cellsClear &= LegsOnGrid(mazeData, cells);
			mazeData.Smooth(cells);
			mazeData.useNodes = true;
			worst = Math.Max(worst, Length(path) / Math.Max(Length(cells), 0.01f));
			short &= Length(path) <= Length(cells) * 1.05f;
		}
		ok &= Check(cellsClear, "every leg of 20 maze paths cell by cell keeps to the grid");
		ok &= Check(clear, "and so does every leg over the nodes, before and after smoothing");
		ok &= Check(short, scope $"and none is more than 5% longer than the smoothed cell path (worst {worst:F3})");
		return ok;
	}

	/// Partial chunks and thin regions exercise quadtree splits at non-power-of-two bounds.
	static bool QuadBounds()
	{
		bool ok = true;
		for (let size in scope (int32 x, int32 z)[]((13, 7), (1, 19), (19, 1)))
		{
			let data = scope NavigationData();
			let error = scope String();
			data.Configure(.Zero, .(size.x, 1, size.z), 1, false, 5, error);
			for (int32 z < data.depth)
			{
				for (int32 x < data.width)
				{
					uint32 links = 0;
					for (int32 d < NavigationData.DirectionCount)
					{
						if (!data.Uses(d)) continue;
						NavigationData.Offset(d, let dx, let dy, let dz);
						if (data.Inside(x + dx, 0, z + dz))
							links |= 1u << d;
					}
					data.cells[data.Index(x, 0, z)] = .() { walkable = true, position = data.Center(x, 0, z), links = links };
				}
			}
			data.Touch();
			let path = scope List<Vector3>();
			let from = data.Center(0, 0, 0), to = data.Center(size.x - 1, 0, size.z - 1);
			ok &= Check(data.FindPath(from, to, path) && LegsClear(data, path), scope $"quadtree covers partial and thin chunks ({size.x} x {size.z})");
			let count = data.NodeCount;
			data.SetCost(data.Center(size.x / 2, 0, size.z / 2), .Identity, .(0.1f, 1, 0.1f), 4);
			ok &= Check(data.FindPath(from, to, path) && LegsOnGrid(data, path), "cost changes refresh quadtree leaves and exit runs");
			data.ClearOverlay();
			ok &= Check(data.FindPath(from, to, path) && LegsClear(data, path) && data.NodeCount == count, "clearing costs restores the quadtree");
		}
		return ok;
	}

	static bool LineTraversal()
	{
		let data = scope NavigationData();
		let error = scope String();
		data.Configure(.Zero, .(12, 1, 12), 1, false, 5, error);
		for (int32 z < 12)
		{
			for (int32 x < 12)
				data.cells[data.Index(x, 0, z)] = .() { walkable = true, position = .(x + 0.5f, 0, z + 0.5f), links = 0x3CFu };
		}
		bool ok = Check(data.LineClear(.(0.5f, 0, 0.5f), .(11.5f, 0, 11.5f), ?) && data.LineClear(.(11.5f, 0, 11.5f), .(0.5f, 0, 0.5f), ?), "diagonal traversal works both ways at simultaneous grid crossings");
		ok &= Check(data.LineClear(.(0.5f, 0, 0.5f), .(11.5f, 0, 0.5f), ?) && !data.LineClear(.(0.5f, 0, 0.5f), .(12, 0, 0.5f), ?), "centre-line traversal keeps to its row and rejects an outside endpoint");
		ok &= Check(!data.LineClear(.(0.5f, 0, 0.5f), .(0.5f, 2, 0.5f), ?), "height clearance is checked even within one cell");
		let flatNodes = data.NodeCount;
		data.cells[data.Index(3, 0, 3)].position.y = 1;
		data.Touch();
		let raisedNodes = data.NodeCount;
		ok &= Check(data.LastRebuiltChunks == 1, "a height-only change rebuilds the affected leaf metadata");
		ok &= Check(!data.LineClear(.(2.5f, 0, 3.5f), .(3, 0, 3.5f), ?), "endpoint height is checked when it lands on a new cell edge");
		data.cells[data.Index(3, 0, 3)].position.y = 0;
		for (int32 z = 3; z < 9; z++)
			data.cells[data.Index(5, 0, z)].walkable = false;
		data.Touch();
		let wallNodes = data.NodeCount;
		// A dense reference checks intervals far more often than either the old sampler or new traversal.
		// Any accepted line must remain valid; include near-centre offsets and both signs of travel.
		bool safe = true;
		int accepted = 0;
		for (int i < 500)
		{
			let a = Vector3(0.5f + (i * 7) % 11, 0, 0.5f + (i * 13) % 11);
			let b = Vector3(0.5f + (i * 17) % 11 + (i % 3) * 0.0002f, 0, 0.5f + (i * 19) % 11);
			let fast = data.LineClear(a, b, ?);
			data.useLeafClearance = false;
			let reference = data.LineClear(a, b, ?);
			data.useLeafClearance = true;
			safe &= fast == reference;
			if (!fast) continue;
			accepted++;
			let steps = (int)Math.Ceiling((b - a).Length * 200) + 1;
			int32 last = -1;
			for (int j = 0; j <= steps; j++)
			{
				let point = Vector3.Lerp(a, b, (float)j / steps);
				safe &= data.Usable(data.CellAt(point)) && data.[Friend]Among(point, ref last);
			}
		}
		ok &= Check(safe && accepted > 50, scope $"dense clearance reference validates {accepted} accepted rays across a wall");
		// Missing diagonal links must not be bypassed at an exact corner.
		data.cells[data.Index(1, 0, 1)].links &= ~(1u << 6);
		data.cells[data.Index(2, 0, 2)].links &= ~(1u << 9);
		data.Touch();
		let brokenNodes = data.NodeCount;
		ok &= Check(!data.LineClear(.(1.5f, 0, 1.5f), .(2.5f, 0, 2.5f), ?), "corner traversal checks diagonal connectivity");
		data.origin = .(100, 0, -50);
		data.cellSize = 2;
		for (int32 z < 12)
		{
			for (int32 x < 12)
				data.cells[data.Index(x, 0, z)].position = data.origin + .((x + 0.5f) * 2, 0, (z + 0.5f) * 2);
		}
		data.Touch();
		let shiftedNodes = data.NodeCount;
		let path = scope List<Vector3>();
		ok &= Check(data.LastRebuiltChunks == 9 && data.FindPath(.(101, 0, -49), .(123, 0, -49), path) && LegsClear(data, path), "origin and spacing changes refresh bounds and cached corridor portals");
		return ok;
	}

	static bool RouteReuse()
	{
		let data = scope NavigationData();
		let error = scope String();
		data.Configure(.Zero, .(16, 1, 8), 1, false, 4, error);
		data.routeCacheCapacity = 4;
		for (int32 z < 8)
		{
			for (int32 x < 16)
				data.cells[data.Index(x, 0, z)] = .() { walkable = true, position = .(x + 0.5f, 0, z + 0.5f), links = 0x3CFu };
		}
		data.Touch();
		let from = Vector3(0.5f, 0, 0.5f), to = Vector3(15.5f, 0, 7.5f);
		let path = scope List<Vector3>();
		let legs = scope List<int32>();
		bool ok = Check(data.FindPath(from, to, path, legs) && data.LastVisited > 0, "the first exact route performs a search");
		path[0] = .(999, 999, 999);
		legs[0] = 123;
		ok &= Check(data.FindPath(from, to, path, legs) && data.LastVisited == 0 && path[0] == from && legs[0] == -1, "reused routes copy points and link metadata without aliasing caller lists");
		ok &= Check(data.FindPath(from, to, path, legs, 2, true, true) && data.LastVisited > 0 && LegsClear(data, path), "smoothed routes have a separate cache entry");
		let smoothCount = path.Count;
		path[0] = .(999, 999, 999);
		ok &= Check(data.FindPath(from, to, path, legs, 2, true, true) && data.LastVisited == 0 && path.Count == smoothCount && path[0] == from && LegsClear(data, path), "combined smoothed route reuse returns an independent valid path");
		ok &= Check(!data.FindPath(from, to, path, legs, 2, 0) && data.BudgetExceeded, "a cached route does not bypass an explicit visit budget");
		data.Block(.(8, 0, 4), .Identity, .(1, 1, 2), false);
		ok &= Check(data.FindPath(from, to, path, legs) && data.LastVisited > 0 && LegsClear(data, path), "carving invalidates route reuse and the replacement path avoids the obstacle");
		data.ClearOverlay();
		for (int i < 6)
			data.FindPath(.(i + 0.5f, 0, 0.5f), to, path, legs);
		ok &= Check(data.FindPath(from, to, path, legs) && data.LastVisited > 0, "bounded route reuse evicts old endpoints");
		NavigationData.Link[1] links = default;
		links[0] = .() { from = data.CellAt(from), to = data.CellAt(to), cost = 0.1f, twoWay = true, id = 7 };
		data.SetLinks(links);
		ok &= Check(data.FindPath(from, to, path, legs) && legs.Contains(7), "routes retain off-grid link IDs");
		ok &= Check(data.FindPath(from, to, path, legs, 2, false) && !legs.Contains(7), "link permissions have independent route entries");
		links[0].id = 8;
		data.SetLinks(links);
		ok &= Check(data.FindPath(from, to, path, legs) && legs.Contains(8) && !legs.Contains(7), "changed link metadata invalidates cached routes");
		data.routeCacheCapacity = 0;
		ok &= Check(data.FindPath(from, to, path, legs) && data.LastVisited > 0 && data.FindPath(from, to, path, legs) && data.LastVisited > 0, "route reuse can be disabled for fresh-search measurements");
		return ok;
	}

	static bool CrowdIndex()
	{
		let scene = scope Scene();
		Scene.Active = scene;
		Floor(scene, .Zero, .(128, 1, 128), "Crowd floor");
		let surface = scene.CreateGameObject("Crowd surface").AddComponent<NavigationSurface>();
		surface.backend = .Grid;
		surface.size = .(128, 5, 128);
		surface.cellSize = 2;
		surface.Bake();
		let parent = scene.CreateGameObject("Moving crowd parent");
		let agents = scope List<NavigationAgent>();
		for (int i < 80)
		{
			let go = scene.CreateGameObject("Crowd probe");
			go.Transform.Position = .(5 + (i % 10) * 10, 0, 5 + (i / 10) * 10);
			if (i % 2 == 0)
				go.Transform.SetParent(parent.Transform, true);
			let agent = go.AddComponent<NavigationAgent>();
			agent.surface = surface;
			agent.radius = 0.3f;
			agents.Add(agent);
		}
		bool Covered(Vector3 center, float distance)
		{
			let candidates = scene.NavigationCrowd.Query(center, distance);
			for (let agent in agents)
			{
				var delta = agent.Transform.Position + agent.baseOffset - center;
				delta.y = 0;
				if (delta.Length <= distance + agent.radius && !candidates.Contains(agent)) return false;
			}
			return true;
		}
		// The index reads the agents' places once per scene update.
		bool ok = Check(Covered(.(5, 0, 5), 2), "the crowd index finds every agent in range");
		agents[79].Transform.Position = .(5.5f, 0, 5.5f);
		scene.Update();
		ok &= Check(Covered(.(5, 0, 5), 2), "a teleported agent is found at its new place after an update");
		parent.Transform.Position = .(1000, 0, -500);
		scene.Update();
		ok &= Check(Covered(.(1005, 0, -495), 2), "moving a parent moves the agents under it in the index");
		agents[77].baseOffset = .(1000, 0, -500);
		agents[75].radius = 1200;
		scene.Update();
		ok &= Check(Covered(.(1005, 0, -495), 2), "base offset and radius changes are taken into account");
		let removed = agents[79];
		agents.Remove(removed);
		scene.DestroyImmediate(removed.GameObject);
		let fresh = scene.CreateGameObject("Replacement crowd probe").AddComponent<NavigationAgent>();
		fresh.surface = surface;
		fresh.Transform.Position = .(1005, 0, -495);
		agents.Add(fresh);
		scene.Update();
		ok &= Check(Covered(.(1005, 0, -495), 2), "a destroyed agent leaves the index and a new one can take its entry");
		parent.Transform.Position = .Zero;
		for (let agent in agents)
		{
			agent.baseOffset = .Zero;
			agent.radius = 0.3f;
		}
		agents[0].Transform.Position = .(5, 0, 5);
		agents[1].Transform.Position = .(6, 0, 5);
		scene.Update();
		NavigationAgent.UseSpatialAvoidance = false;
		let reference = agents[0].[Friend]Avoid(.(2, 0, 0), .(5, 0, 5));
		NavigationAgent.UseSpatialAvoidance = true;
		let accelerated = agents[0].[Friend]Avoid(.(2, 0, 0), .(5, 0, 5));
		ok &= Check((reference - accelerated).Length < 0.00001f, "avoidance steers the same with the index as with every agent");
		return ok;
	}

	/// E14: smoothing, queries, obstacles, areas, links and avoidance.
	static bool Upgrades()
	{
		bool ok = true;
		let scene = scope Scene();
		Scene.Active = scene;
		// Two islands: a 20 x 12 floor with a wall part way across it, and a small one beyond a 3 metre gap.
		Floor(scene, .(0, 0, 0), .(20, 1, 12), "Main Floor");
		Floor(scene, .(23, 0, 0), .(5, 1, 5), "Island");
		let wall = scene.CreateGameObject("Wall");
		wall.Transform.Position = .(10, 1.5f, 4);
		wall.AddComponent<BoxCollider>().size = .(1, 3, 8);
		let surface = scene.CreateGameObject("Navigation").AddComponent<NavigationSurface>();
		surface.backend = .Grid;
		surface.size = .(28, 5, 12);
		surface.cellSize = 0.5f;
		ok &= Check(surface.Bake(), "the islands bake");
		let data = surface.Data;
		List<Vector3> path = scope .();
		List<int32> legs = scope .();

		// ---- any-angle paths (cell by cell here: the nodes' paths come out straight already) ----
		data.useNodes = false;
		ok &= Check(data.FindPath(.(1, 0, 11), .(18, 0, 9.5f), path, legs, 2) && path.Count > 10 && legs.Count == path.Count, "a grid path has a point per cell, and a leg entry per point");
		data.Smooth(path, legs);
		ok &= Check(path.Count == 2 && legs.Count == 2, scope $"in the open, smoothing leaves one straight leg ({path.Count} points)");
		data.useNodes = true;
		ok &= Check(data.FindPath(.(1, 0, 11), .(18, 0, 9.5f), path, legs, 2) && path.Count == 2 && legs.Count == 2, scope $"over the nodes the same path comes out straight ({path.Count} points)");
		data.FindPath(.(1, 0, 1), .(18, 0, 1), path, legs, 2);
		data.Smooth(path, legs);
		// No leg comes within the agent's radius of the wall (x 9.5 to 10.5, z up to 8).
		bool clear = path.Count >= 3 && path.Count < 12;
		for (int i = 0; i + 1 < path.Count; i++)
		{
			for (int k <= 20)
			{
				let p = Vector3.Lerp(path[i], path[i + 1], k / 20.0f);
				let dx = Math.Max(Math.Max(9.5f - p.x, p.x - 10.5f), 0);
				let dz = Math.Max(p.z - 8, 0);
				clear &= dx * dx + dz * dz >= 0.29f * 0.29f;
			}
		}
		let shown = scope String();
		for (let p in path)
			shown.AppendF(" ({:0.00} {:0.00})", p.x, p.z);
		ok &= Check(clear, scope $"round the wall it keeps the corners it needs, and no leg cuts through:{shown}");
		ok &= Check(!data.Raycast(.(8, 0, 2), .(12, 0, 2), let hit) && hit.x < 10 - 0.5f && hit.x > 8, scope $"a raycast stops before the wall ({hit.x})");
		ok &= Check(data.Raycast(.(2, 0, 10), .(18, 0, 10), ?), "and goes through where there is none");
		ok &= Check(data.SamplePosition(.(3.1f, 2, 3.1f), 3, let sampled) && Math.Abs(sampled.y) < 0.1f && !data.SamplePosition(.(50, 0, 50), 2, ?), "SamplePosition finds the floor near a point");
		let random = scope Random(7);
		bool wander = true;
		for (int i < 20)
		{
			wander &= data.RandomPoint(.(4, 0, 4), 3, random, let point) && (Vector3(point.x, 0, point.z) - Vector3(4, 0, 4)).Length <= 3.6f && data.Usable(data.CellAt(point));
		}
		ok &= Check(wander, "RandomPoint picks usable spots within the radius");
		ok &= Check(data.RandomPoint(.(25, 0, 2), 6, random, let onIsland) && onIsland.x > 23, "and only ones reachable from the centre");

		// An agent with smoothing walks straight across open floor.
		let walker = scene.CreateGameObject("Walker");
		walker.Transform.Position = .(1, 0.02f, 11);
		let agent = walker.AddComponent<NavigationAgent>();
		agent.surface = surface;
		agent.SetDestination(.(18, 0.02f, 9.5f), 4, 0.1f);
		Time.DeltaTime = 0.05f;
		float off = 0;
		for (int i = 0; i < 200 && !agent.HasArrived; i++)
		{
			agent.Update();
			// Distance from the straight line between start and goal, on the ground.
			let p = walker.Transform.Position;
			let a = Vector3(1, 0, 11);
			let d = Vector3(17, 0, -1.5f).Normalized;
			let rel = Vector3(p.x, 0, p.z) - a;
			off = Math.Max(off, (rel - d * Vector3.Dot(rel, d)).Length);
		}
		ok &= Check(agent.HasArrived && off < 0.3f && agent.Path.Count == 2, scope $"a smoothing agent goes straight there (strays {off:0.00})");

		// ---- obstacles ----
		let crate = scene.CreateGameObject("Crate");
		crate.Transform.Position = .(5, 0.5f, 6);
		let obstacle = crate.AddComponent<NavigationObstacle>();
		obstacle.size = .(1, 1, 12);
		surface.RefreshOverlay();
		ok &= Check(data.Blocked(data.CellAt(.(5, 0, 6))) && !data.Usable(data.CellAt(.(5, 0, 3))) && data.Usable(data.CellAt(.(7, 0, 6))), "a carving obstacle blocks the cells under it and its agent's radius around it");
		ok &= Check(!data.FindPath(.(1, 0, 6), .(8, 0, 6), path, 2), "a path across the blocked strip fails");
		obstacle.size = .(1, 1, 4);
		surface.RefreshOverlay();
		float Length(List<Vector3> points)
		{
			float total = 0;
			for (int i = 0; i + 1 < points.Count; i++)
				total += (points[i + 1] - points[i]).Length;
			return total;
		}
		ok &= Check(data.FindPath(.(1, 0, 6), .(8, 0, 6), path, 2) && Length(path) > 7.6f, scope $"a smaller one is walked round, once the surface sees the change ({Length(path):0.0} m)");
		obstacle.Enabled = false;
		surface.RefreshOverlay();
		ok &= Check(!data.Blocked(data.CellAt(.(5, 0, 6))) && data.FindPath(.(1, 0, 6), .(8, 0, 6), path, 2) && path.Count <= 16, "and when it goes the cells are free again");
		obstacle.Enabled = true;
		// Moving and standing still.
		Time.DeltaTime = 0.1f;
		obstacle.Update();
		crate.Transform.Position = .(5, 0.5f, 7);
		obstacle.Update();
		ok &= Check(!obstacle.Carving && obstacle.Velocity.z > 5, "a moving obstacle does not carve, and knows how fast it goes");
		for (int i < 6)
			obstacle.Update();
		ok &= Check(obstacle.Carving && obstacle.CarvedPosition.z == 7, "once it has stood still for Stationary Time it carves where it stands");
		obstacle.Enabled = false;
		surface.RefreshOverlay();

		// ---- areas ----
		let mud = scene.CreateGameObject("Mud");
		mud.Transform.Position = .(4, 0, 6);
		let area = mud.AddComponent<NavigationArea>();
		area.size = .(2, 2, 4);
		area.cost = 10;
		surface.RefreshOverlay();
		ok &= Check(data.CostScale(data.CellAt(.(4, 0, 6))) == 10 && data.CostScale(data.CellAt(.(4, 0, 1))) == 1, "an area makes its cells cost more");
		data.FindPath(.(1, 0, 6), .(7, 0, 6), path, 2);
		bool avoided = true;
		for (let point in path)
			avoided &= !(Math.Abs(point.x - 4) < 1 && Math.Abs(point.z - 6) < 2);
		ok &= Check(avoided, "paths go round a costly area");
		area.cost = 1.05f;
		surface.RefreshOverlay();
		data.FindPath(.(1, 0, 6), .(7, 0, 6), path, 2);
		ok &= Check(path.Count <= 14, "but through a cheap one");
		area.blocked = true;
		surface.RefreshOverlay();
		ok &= Check(!data.Usable(data.CellAt(.(4, 0, 6))), "a blocked area is not walkable at all");
		area.Enabled = false;
		surface.RefreshOverlay();

		// ---- links ----
		ok &= Check(!data.FindPath(.(18, 0, 2), .(25, 0, 2), path, 2), "the island is out of reach without a link");
		let gap = scene.CreateGameObject("Gap Jump");
		gap.Transform.Position = .(19.6f, 0, 2.2f);
		let link = gap.AddComponent<NavigationLink>();
		link.end = .(3.8f, 0, 0);
		link.kind = .Jump;
		link.duration = 0.5f;
		surface.RefreshOverlay();
		ok &= Check(data.links.Count == 1 && data.FindPath(.(18, 0, 2), .(25, 0, 2), path, legs, 2) && legs.Contains(0) && surface.LinkOf(0) == link, "a link joins the island, and the path says which leg crosses it");
		ok &= Check(data.FindPath(.(25, 0, 2), .(18, 0, 2), path, 2), "both ways");
		let mid = link.Along(link.StartPoint, link.EndPoint, 0.5f);
		ok &= Check(mid.y > 0.9f && Math.Abs(link.Along(link.StartPoint, link.EndPoint, 1).y) < 0.001f, "a jump arcs above its ends");
		link.bidirectional = false;
		surface.RefreshOverlay();
		ok &= Check(data.FindPath(.(18, 0, 2), .(25, 0, 2), path, 2) && !data.FindPath(.(25, 0, 2), .(18, 0, 2), path, 2), "a one-way link goes only from its object to its end");
		let jumper = scene.CreateGameObject("Jumper");
		jumper.Transform.Position = .(17, 0.02f, 2);
		let jumps = jumper.AddComponent<NavigationAgent>();
		jumps.surface = surface;
		int started = 0, finished = 0;
		float highest = 0;
		jumps.OnLinkStarted.Add(new [&] (crossed) =>
			{
				started++;
			});
		jumps.OnLinkFinished.Add(new [&] (crossed) =>
			{
				finished++;
			});
		jumps.SetDestination(.(26, 0.02f, 2), 4, 0.1f);
		Time.DeltaTime = 0.05f;
		for (int i = 0; i < 300 && !jumps.HasArrived; i++)
		{
			jumps.Update();
			if (jumps.IsCrossingLink)
				highest = Math.Max(highest, jumper.Transform.Position.y);
		}
		ok &= Check(jumps.HasArrived && started == 1 && finished == 1 && highest > 0.8f && jumper.Transform.Position.x > 25, scope $"an agent jumps the gap and arrives, telling the game as it goes (top {highest:0.00})");
		jumps.useLinks = false;
		jumps.SetDestination(.(17, 0.02f, 2), 4, 0.1f);
		ok &= Check(jumps.PathFailed, "an agent that may not use links cannot leave the island");

		// ---- avoidance ----
		let left = scene.CreateGameObject("Left");
		left.Transform.Position = .(2, 0.02f, 9);
		let leftAgent = left.AddComponent<NavigationAgent>();
		leftAgent.surface = surface;
		let right = scene.CreateGameObject("Right");
		right.Transform.Position = .(8, 0.02f, 9);
		let rightAgent = right.AddComponent<NavigationAgent>();
		rightAgent.surface = surface;
		float Closest(bool avoid)
		{
			leftAgent.StopMovement();
			rightAgent.StopMovement();
			left.Transform.Position = .(2, 0.02f, 9);
			right.Transform.Position = .(8, 0.02f, 9);
			leftAgent.avoidOthers = rightAgent.avoidOthers = avoid;
			leftAgent.SetDestination(.(8, 0.02f, 9), 2, 0.1f);
			rightAgent.SetDestination(.(2, 0.02f, 9), 2, 0.1f);
			var closest = float.MaxValue;
			for (int i = 0; i < 300 && !(leftAgent.HasArrived && rightAgent.HasArrived); i++)
			{
				leftAgent.Update();
				rightAgent.Update();
				var gapBetween = left.Transform.Position - right.Transform.Position;
				gapBetween.y = 0;
				closest = Math.Min(closest, gapBetween.Length);
			}
			return leftAgent.HasArrived && rightAgent.HasArrived ? closest : -1;
		}
		let without = Closest(false);
		let with = Closest(true);
		ok &= Check(without >= 0 && without < 0.2f, scope $"without avoidance two agents walk through each other ({without:0.00})");
		ok &= Check(with >= 0.65f, scope $"with it they pass each other and both arrive ({with:0.00} apart at closest)");
		Scene.Active = null;
		return ok;
	}

	public static int Main(String[] args)
	{
		if (args.Count == 1)
		{
			Assets.ProjectPath.Set(args[0]);
			let sample = scope Scene();
			if (!SceneSerializer.LoadFromFile(sample, scope $"{args[0]}/Scenes/AIExample.tscene")) return 1;
			let surface = sample.Find("Navigation Surface").GetComponent<NavigationSurface>();
			if (!surface.Bake() || !surface.SaveData()) return 1;
			Console.WriteLine(scope $"PASS: example {surface.Data.cells.Count}-cell navigation baked without Play.");
			return 0;
		}
		bool ok = true;
		let error = scope String();
		let scene = scope Scene();
		Scene.Active = scene;
		let floor = scene.CreateGameObject("Floor");
		floor.Transform.Position = .(4, -0.5f, 4);
		floor.AddComponent<BoxCollider>().size = .(8, 1, 8);
		let wall = scene.CreateGameObject("Wall");
		wall.Transform.Position = .(4, 1.5f, 3);
		wall.AddComponent<BoxCollider>().size = .(1, 3, 6);
		let surface = scene.CreateGameObject("Navigation").AddComponent<NavigationSurface>();
		surface.backend = .Grid;
		surface.size = .(8, 5, 8);
		surface.chunkSize = 2;
		ok &= Check(surface.Bake(), "editor bake works without entering play mode");
		ok &= Check(!scene.IsPlaying && scene.Physics.BodyCount == 0, "private bake world leaves scene physics untouched");
		List<Vector3> path = scope .();
		ok &= Check(surface.Data.FindPath(.(1.5f, 0, 1.5f), .(6.5f, 0, 1.5f), path) && Length(path) > 10, scope $"A star routes around wall on walking surface ({Length(path):F1} m)");
		bool around = false;
		for (let point in path)
		{
			if (point.z > 6)
				around = true;
		}
		ok &= Check(around, "route avoids blocked wall cells");
		surface.bakedData.Set("/tmp/tallow-navigation-test.tnav");
		defer
		{
			File.Delete(surface.bakedData);
		}
		ok &= Check(surface.SaveData(), "baked navigation saves to asset");
		let loaded = scope NavigationData();
		ok &= Check(loaded.Load(surface.bakedData, error) && loaded.FindPath(.(1.5f, 0, 1.5f), .(6.5f, 0, 1.5f), path), "saved data routes without runtime baking");
		let before = surface.Data.cells[surface.Data.Index(0, 0, 0)];
		let revision = surface.Data.Revision;
		wall.GetComponent<BoxCollider>().Enabled = false;
		ok &= Check(surface.Rebuild(.(.(3, 0, 0), .(5, 5, 6))) && surface.Data.Revision > revision, "dirty bounds rebuild affected chunks");
		ok &= Check(surface.Data.cells[0].position == before.position && surface.Data.cells[0].walkable == before.walkable, "distant cell survives chunk rebuild");
		ok &= Check(surface.Data.FindPath(.(1.5f, 0, 1.5f), .(6.5f, 0, 1.5f), path) && Length(path) < 5.05f, scope $"rebuilt path uses newly opened shortcut ({Length(path):F1} m)");
		let generated = scene.CreateGameObject("Generated Mesh");
		generated.Transform.Position = .(4, 1.5f, 3);
		generated.Transform.LocalScale = .(1, 3, 6);
		let mesh = Primitives.CreateCube();
		defer
		{
			delete mesh;
		}
		generated.AddComponent<MeshRenderer>().RuntimeMesh = mesh;
		surface.Rebuild(.(.(3, 0, 0), .(5, 5, 6)));
		ok &= Check(surface.Data.FindPath(.(1.5f, 0, 1.5f), .(6.5f, 0, 1.5f), path) && Length(path) > 10, scope $"runtime mesh geometry blocks navigation without a collider ({Length(path):F1} m)");
		for (int i < mesh.Vertices.Count)
			mesh.Vertices[i].position.x += 20;
		mesh.RecalculateBounds();
		surface.Rebuild(.(.(3, 0, 0), .(5, 5, 6)));
		ok &= Check(surface.Data.FindPath(.(1.5f, 0, 1.5f), .(6.5f, 0, 1.5f), path) && Length(path) < 5.05f, scope $"editable mesh geometry updates changed navigation chunks ({Length(path):F1} m)");
		let actor = scene.CreateGameObject("Actor Visual");
		actor.Transform.Position = .(2.5f, 0.5f, 1.5f);
		actor.AddComponent<NavigationAgent>();
		actor.AddComponent<MeshRenderer>();
		surface.Rebuild(.(.(2, 0, 1), .(3, 3, 2)));
		ok &= Check(Math.Abs(surface.Data.cells[surface.Data.Index(2, 0, 1)].position.y - 0.02f) < 0.01f, "actor visuals are excluded from static bake geometry");
		let flying = scope NavigationData();
		ok &= Check(flying.Configure(.(0, 0, 0), .(6, 6, 6), 1, true, 2, error), "flying volume configures 3D cells");
		let world = scope PhysicsWorld();
		ok &= Check(NavigationBaker.Rebuild(flying, world, 6, .(.Zero, .(6, 6, 6)), error) && flying.FindPath(.(0.5f, 0.5f, 0.5f), .(4.5f, 4.5f, 4.5f), path) && path.Count == 5, "flying route takes the 3D diagonal");
		let barrier = scene.CreateGameObject("Volume Barrier");
		barrier.Transform.Position = .(3, 3, 3);
		ShapeDesc shape = default;
		shape.kind = .Box;
		shape.halfExtents = .(0.3f, 4, 4);
		world.CreateBody(barrier.Transform, shape, null);
		NavigationBaker.Rebuild(flying, world, 6, .(.Zero, .(6, 6, 6)), error);
		ok &= Check(!flying.FindPath(.(0.5f, 0.5f, 0.5f), .(4.5f, 4.5f, 4.5f), path), "flight volume rejects route through sealed barrier");
		ok &= Check(!flying.Configure(.Zero, .(10000, 10000, 10000), 0.1f, true, 16, error), "oversized navigation allocation rejected");
		let mover = scene.CreateGameObject("Mover");
		mover.Transform.Position = .(1.5f, 0.02f, 1.5f);
		let nav = mover.AddComponent<NavigationAgent>();
		nav.surface = surface;
		nav.SetDestination(.(6.5f, 0.02f, 1.5f), 1, 0.1f);
		Time.DeltaTime = 0.1f;
		for (int i = 0; i < 80; i++)
			nav.Update();
		ok &= Check(nav.HasArrived && (mover.Transform.Position - Vector3(6.5f, 0.02f, 1.5f)).Length < 0.15f, "slow agent reaches destination despite repeated replanning");
		nav.SetDestination(.(6.7f, 0.02f, 1.7f), 1, 0.05f);
		for (int i = 0; i < 20; i++)
			nav.Update();
		ok &= Check(nav.HasArrived && !nav.PathFailed, "navigation arrives at snapped destination");
		bool opposite = true;
		for (int32 d = 0; d < NavigationData.DirectionCount; d++)
		{
			NavigationData.Offset(d, let ax, let ay, let az);
			NavigationData.Offset(NavigationData.Opposite(d), let bx, let by, let bz);
			opposite &= ax + bx == 0 && ay + by == 0 && az + bz == 0 && (ax != 0 || ay != 0 || az != 0) && NavigationData.Opposite(NavigationData.Opposite(d)) == d;
		}
		ok &= Check(opposite, "26 link directions pair up with their opposites");
		// Open volume: a long diagonal must cost about its own length, not the whole box.
		let open = scope NavigationData();
		open.Configure(.Zero, .(64, 64, 64), 1, true, 16, error);
		open.agentHeight = 0.6f;
		let emptyWorld = scope PhysicsWorld();
		NavigationBaker.Rebuild(open, emptyWorld, 64, .(.Zero, .(64, 64, 64)), error);
		ok &= Check(open.FindPath(.(0.5f, 0.5f, 0.5f), .(63.5f, 63.5f, 63.5f), path, 2, 500) && Length(path) < 63 * Math.Sqrt(3) + 0.01f && !open.BudgetExceeded, scope $"corner-to-corner flight found within a 500-visit budget ({Length(path):F2} m, {open.LastVisited} visited)");
		// The grid's own steps make that 20 * sqrt 3 + 20 * sqrt 2 + 23 = 85.9 m; over the nodes it is nearer the straight 77.3.
		ok &= Check(open.FindPath(.(0.5f, 0.5f, 0.5f), .(63.5f, 20.5f, 40.5f), path, 2, 500) && Length(path) < 85.92f, scope $"off-axis flight is as short as the grid allows ({Length(path):F2} m)");
		ok &= Check(!open.FindPath(.(0.5f, 0.5f, 0.5f), .(63.5f, 63.5f, 63.5f), path, 2, 2) && open.BudgetExceeded, "an exhausted budget is reported as such");
		open.useNodes = false;
		ok &= Check(open.FindPath(.(0.5f, 0.5f, 0.5f), .(63.5f, 63.5f, 63.5f), path, 2, 500) && path.Count == 64 && !open.BudgetExceeded, "cell by cell, the same flight is a point per cell within 500 visits");
		ok &= Check(!open.FindPath(.(0.5f, 0.5f, 0.5f), .(63.5f, 63.5f, 63.5f), path, 2, 10) && open.BudgetExceeded, "and its exhausted budget is reported too");
		let flightFile = "/tmp/tallow-navigation-flight.tnav";
		defer
		{
			File.Delete(flightFile);
		}
		let reloaded = scope NavigationData();
		ok &= Check(flying.Save(flightFile, error) && reloaded.Load(flightFile, error) && reloaded.cells.Count == flying.cells.Count, "flight volume saves and loads in the binary format");
		bool same = reloaded.flying && reloaded.width == flying.width && reloaded.agentHeight == flying.agentHeight;
		for (int i < reloaded.cells.Count)
			same &= reloaded.cells[i].walkable == flying.cells[i].walkable && reloaded.cells[i].links == flying.cells[i].links && (reloaded.cells[i].position - flying.cells[i].position).Length < 0.0001f;
		ok &= Check(same, "binary flight data matches what was baked");
		let walkFile = "/tmp/tallow-navigation-walk.tnav";
		defer
		{
			File.Delete(walkFile);
		}
		let walk = scope NavigationData();
		same = surface.Data.Save(walkFile, error) && walk.Load(walkFile, error) && walk.cells.Count == surface.Data.cells.Count;
		if (same)
		{
			for (int i < walk.cells.Count)
				same &= walk.cells[i].walkable == surface.Data.cells[i].walkable && walk.cells[i].links == surface.Data.cells[i].links && (walk.cells[i].position - surface.Data.cells[i].position).Length < 0.0001f;
		}
		ok &= Check(same, "binary walking data keeps floor heights and links");
		File.WriteAllText(walkFile, "navigation 1\ngrid 0 0 0 1 2 1 1 16 0 0.3 1.8 0.5 45 2\ncell 1 0.5 0.02 0.5 1\ncell 1 1.5 0.02 0.5 2\n");
		ok &= Check(walk.Load(walkFile, error) && walk.FindPath(.(0.5f, 0, 0.5f), .(1.5f, 0, 0.5f), path) && Math.Abs(Length(path) - 1) < 0.001f && path.Count == 2, scope $"version 1 text assets still load ({path.Count} points)");
		File.WriteAllText(walkFile, "TNAV garbage");
		ok &= Check(!walk.Load(walkFile, error), "truncated binary asset rejected");
		// The sealed barrier from above splits the volume in two; the far side is rejected before any search.
		ok &= Check(flying.Region(flying.Nearest(.(0.5f, 0.5f, 0.5f), 1)) != flying.Region(flying.Nearest(.(4.5f, 4.5f, 4.5f), 1)) && !flying.FindPath(.(0.5f, 0.5f, 0.5f), .(4.5f, 4.5f, 4.5f), path, 2, 0) && !flying.BudgetExceeded, "unreachable region rejected without searching");
		ok &= Check(flying.FindPath(.(1.5f, 2.5f, 2.5f), .(3.4f, 2.5f, 2.5f), path, 2) && path.Back.x < 3, "goal beside the barrier snaps to the reachable side");
		let first = scope NavigationData();
		let second = scope NavigationData();
		first.Configure(.Zero, .(2, 2, 2), 1, true, 2, error);
		second.Configure(.Zero, .(2, 2, 2), 1, true, 2, error);
		NavigationBaker.Rebuild(first, emptyWorld, 2, .(.Zero, .(2, 2, 2)), error);
		NavigationBaker.Rebuild(second, emptyWorld, 2, .(.Zero, .(2, 2, 2)), error);
		ok &= Check(first.Revision != second.Revision, "a fresh bake never repeats another bake's revision");

		// Flying agent: follows a baked volume loaded from disk, on all three axes.
		let sky = scene.CreateGameObject("Sky").AddComponent<NavigationSurface>();
		sky.backend = .Grid;
		sky.Transform.Position = .(100, 0, 0);
		sky.size = .(12, 12, 12);
		sky.flying = true;
		sky.agentHeight = 0.6f;
		let pillar = scene.CreateGameObject("Pillar");
		pillar.Transform.Position = .(106, 6, 106 - 100);
		pillar.AddComponent<BoxCollider>().size = .(2, 12, 2);
		ok &= Check(sky.Bake() && sky.Data.flying, "flight surface bakes from scene colliders");
		let flyer = scene.CreateGameObject("Flyer");
		flyer.Transform.Position = .(101.5f, 1.5f, 6.5f);
		let wings = flyer.AddComponent<NavigationAgent>();
		wings.surface = sky;
		wings.SetDestination(.(110.5f, 9.5f, 6.5f), 4, 0.1f);
		float clearance = float.MaxValue;
		for (int i = 0; i < 200 && !wings.HasArrived; i++)
		{
			wings.Update();
			let p = flyer.Transform.Position;
			clearance = Math.Min(clearance, Math.Max(Math.Abs(p.x - 106), Math.Abs(p.z - 6)) - 1);
		}
		ok &= Check(wings.HasArrived && (flyer.Transform.Position - Vector3(110.5f, 9.5f, 6.5f)).Length < 0.15f && clearance >= 0.3f, "flying agent climbs around a pillar and arrives");
		let searches = sky.Data.Revision;
		wings.SetDestination(.(101.5f, 1.5f, 1.5f), 4, 0.1f);
		let legs = wings.Path.Count;
		for (int i = 0; i < 10; i++)
			wings.Update();
		ok &= Check(legs >= 2 && wings.Path.Count == legs && sky.Data.Revision == searches, "an agent on course keeps its path between searches");
		pillar.GetComponent<BoxCollider>().Enabled = false;
		sky.Rebuild(.(.(105, 0, 5), .(107, 12, 7)));
		wings.SetDestination(.(110.5f, 6.5f, 6.5f), 4, 0.1f);
		for (int i = 0; i < 10; i++)
			wings.Update();
		wings.SetDestination(.(110.5f, 6.5f, 6.5f), 4, 0.1f);
		ok &= Check(!wings.PathFailed && wings.Path.Count >= 2, "agent replans after its surface is rebuilt");

		// Dynamic bodies: steering only while following, and walking arrival that ignores a pivot height mismatch.
		let ball = scene.CreateGameObject("Ball");
		ball.Transform.Position = .(1.5f, 0.6f, 6.5f);
		ball.AddComponent<SphereCollider>().radius = 0.3f;
		let body = ball.AddComponent<Rigidbody>();
		body.useGravity = false;
		body.linearDamping = 0;
		body.EnsureBody();
		let roller = ball.AddComponent<NavigationAgent>();
		roller.surface = surface;
		body.Velocity = .(0, 0, -2);
		roller.FixedUpdate();
		ok &= Check(body.HasBody && Math.Abs(body.Velocity.z + 2) < 0.001f, "idle agent leaves its body's velocity alone");
		roller.SetDestination(.(6.5f, 0.6f, 6.5f), 3, 0.1f);
		for (int i = 0; i < 400 && !roller.HasArrived; i++)
		{
			roller.FixedUpdate();
			scene.Physics.Step(Time.FixedDeltaTime);
		}
		ok &= Check(roller.HasArrived && Math.Abs(ball.Transform.Position.x - 6.5f) < 0.15f && Math.Abs(ball.Transform.Position.z - 6.5f) < 0.15f, "dynamic walking agent arrives with its pivot 0.6 above the floor");
		roller.FixedUpdate();
		body.Velocity = .(0, 0, -2);
		roller.FixedUpdate();
		ok &= Check(Math.Abs(body.Velocity.z + 2) < 0.001f, "arrived agent can be pushed");
		ok &= Upgrades();
		ok &= Batches();
		ok &= Nodes();
		ok &= QuadBounds();
		ok &= LineTraversal();
		ok &= RouteReuse();
		ok &= CrowdIndex();
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
