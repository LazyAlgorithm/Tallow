using System;
using System.Collections;
using System.IO;
using Tallow;

namespace NavigationMeshTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static GameObject Box(Scene scene, Vector3 center, Vector3 size)
	{
		let obj = scene.CreateGameObject("Static geometry");
		obj.Transform.Position = center;
		obj.AddComponent<BoxCollider>().size = size;
		return obj;
	}

	static NavigationSurface Surface(Scene scene, Vector3 size)
	{
		let surface = scene.CreateGameObject("Polygon navigation").AddComponent<NavigationSurface>();
		surface.size = size;
		surface.cellSize = 0.5f;
		surface.includeRenderMeshes = false;
		return surface;
	}

	static float Length(List<Vector3> path)
	{
		float n = 0;
		for (int i = 1; i < path.Count; i++)
			n += (path[i] - path[i - 1]).Length;
		return n;
	}

	static bool Clear(NavigationData data, List<Vector3> path)
	{
		for (int i = 1; i < path.Count; i++)
		{
			if (!data.LineClear(path[i - 1], path[i], let hit))
			{
				Console.WriteLine(scope $"Diagnostic blocked leg {path[i-1]} -> {path[i]}, hit {hit}");
				return false;
			}
		}
		return true;
	}

	static bool Maze()
	{
		let scene = scope Scene();
		Scene.Active = scene;
		Box(scene, .(8, -0.5f, 8), .(16, 1, 16));
		let wall = Box(scene, .(8, 1.5f, 5), .(1, 3, 10));
		let surface = Surface(scene, .(16, 8, 16));
		bool ok = Check(surface.backend == .NavMesh && surface.Bake() && surface.Data.IsNavMesh && surface.Data.Mesh.PolygonCount > 0 && !scene.IsPlaying, "polygon mesh bakes static geometry without Play");
		if (!ok) return false;
		let data = surface.Data;
		let path = scope List<Vector3>();
		let legs = scope List<int32>();
		ok &= Check(data.FindPath(.(2, 0, 2), .(14, 0, 2), path, legs) && path.Count >= 4 && Length(path) > 20, "mesh route goes around a wall");
		ok &= Check(Clear(data, path) && legs.Count == path.Count, "polygon corridor corners retain clearance and per-leg metadata");
		ok &= Check(!data.Raycast(.(2, 0.1f, 2), .(14, 0.1f, 2), let hit) && hit.x > 6 && hit.x < 8, "mesh ray stops at the wall");
		ok &= Check(!data.FindPath(.(2, 0, 2), .(14, 0, 2), path, legs, 2, 0) && data.BudgetExceeded, "mesh query respects an explicit zero visit budget");
		ok &= Check(!data.FindPath(.(2, 0, 2), .(100, 0, 100), path), "mesh query rejects destinations outside snap distance");
		let requests = scope NavigationData.PathRequest[64];
		for (int i < 64)
			requests[i] = .() { from = .(2, 0, 2 + i * 0.01f), to = .(14, 0, 2 + i * 0.01f), path = new .(), legLinks = new .(), snapDistance = 2, withLinks = true, smooth = true };
		data.FindPaths(requests);
		bool same = true;
		for (let request in requests)
		{
			same &= request.found && data.FindPath(request.from, request.to, path, legs) && request.path.Count == path.Count && request.legLinks.Count == legs.Count;
			for (int i < path.Count)
				same &= request.path[i] == path[i];
			delete request.path;
			delete request.legLinks;
		}
		ok &= Check(same, "parallel mesh queries exactly match serial corners");
		bool randomOK = true;
		let random = scope Random(1729);
		for (int i < 20)
			randomOK &= data.RandomPoint(.(2, 0.1f, 2), 5, random, let point) && (point - Vector3(2, 0.1f, 2)).Length <= 5.001f && data.FindPath(.(2, 0, 2), point, path);
		ok &= Check(randomOK, "random mesh points stay within radius and are reachable");
		let bytes = scope List<uint8>();
		data.Mesh.Serialize(bytes);
		let saved = NavigationMesh.Deserialize(bytes);
		ok &= Check(saved != null && saved.PolygonCount == data.Mesh.PolygonCount, "mesh geometry asset round-trips");
		delete saved;
		let file = scope String();
		Path.GetTempPath(file);
		file.Append("tallow-navmesh-regression.tnav");
		let loaded = scope NavigationData();
		let error = scope String();
		ok &= Check(data.Save(file, error) && loaded.Load(file, error) && loaded.IsNavMesh && loaded.FindPath(.(2, 0, 2), .(14, 0, 2), path) && Clear(loaded, path), "NavigationData saves and loads polygon assets through the existing API");
		File.Delete(file);
		ok &= Check(loaded.Configure(.Zero, .(4, 4, 4), 1, true, 4, error) && !loaded.IsNavMesh && loaded.flying, "reconfiguring polygon data as a grid releases its native backend");
		bytes.RemoveAt(bytes.Count - 1);
		ok &= Check(NavigationMesh.Deserialize(bytes) == null, "truncated mesh assets are rejected");
		wall.Transform.Position = .(30, 1.5f, 5);
		let previous = data.Revision;
		ok &= Check(surface.Rebuild(.(.(7, 0, 0), .(9, 4, 10))) && surface.Data.Revision != previous && surface.Data.FindPath(.(2, 0, 2), .(14, 0, 2), path) && Length(path) < 12.1f, "geometry rebuild replaces the mesh and opens the shortcut");
		surface.flying = true;
		ok &= Check(surface.Bake() && surface.Data.flying && !surface.Data.IsNavMesh, "Flying retains the volume grid when NavMesh is selected");
		return ok;
	}

	static bool LayersAndLinks()
	{
		let scene = scope Scene();
		Scene.Active = scene;
		Box(scene, .(8, -0.5f, 8), .(16, 1, 16));
		Box(scene, .(8, 3.5f, 8), .(8, 1, 8));
		let surface = Surface(scene, .(16, 9, 16));
		if (!Check(surface.Bake(), "stacked-floor mesh bakes")) return false;
		let data = surface.Data;
		let path = scope List<Vector3>();
		let legs = scope List<int32>();
		Vector3 low, high;
		let hasLow = data.SamplePosition(.(8, 0.1f, 8), 0.5f, out low);
		let hasHigh = data.SamplePosition(.(8, 4.1f, 8), 0.5f, out high);
		bool ok = Check(hasLow && low.y < 0.3f && hasHigh && high.y > 3.9f, "mesh samples both overlapping floors by height");
		ok &= Check(!data.FindPath(.(3, 0.1f, 8), .(8, 4.1f, 8), path), "separate floors remain disconnected without a link");
		ok &= Check(!data.LineClear(.(8, 0.1f, 8), .(8, 4.1f, 8), ?), "vertical ray does not jump between overlapping floors");
		let link = scene.CreateGameObject("Jump upstairs").AddComponent<NavigationLink>();
		link.Transform.Position = .(3, 0.1f, 8);
		link.end = .(5, 4, 0);
		link.bidirectional = false;
		link.kind = .Teleport;
		surface.RefreshOverlay();
		ok &= Check(data.FindPath(.(2, 0.1f, 8), .(8, 4.1f, 8), path, legs) && legs.Contains(0), "off-mesh connection preserves its gameplay link ID");
		ok &= Check(!data.FindPath(.(2, 0.1f, 8), .(8, 4.1f, 8), path, legs, 2, false), "mesh link permissions are respected");
		ok &= Check(!data.FindPath(.(8, 4.1f, 8), .(2, 0.1f, 8), path), "one-way mesh link rejects reverse travel");
		link.bidirectional = true;
		surface.RefreshOverlay();
		ok &= Check(data.FindPath(.(8, 4.1f, 8), .(2, 0.1f, 8), path, legs) && legs.Contains(0), "bidirectional mesh link permits reverse travel");
		let walker = scene.CreateGameObject("Linked walker");
		walker.Transform.Position = .(2, 0.1f, 8);
		let agent = walker.AddComponent<NavigationAgent>();
		agent.surface = surface;
		agent.avoidOthers = false;
		int started = 0, finished = 0;
		agent.OnLinkStarted.Add(new [&] (crossed) =>
			{
				started++;
			}
			);
		agent.OnLinkFinished.Add(new [&] (crossed) =>
			{
				finished++;
			}
			);
		scene.StartPlay();
		scene.Update();
		Time.DeltaTime = 1 / 60.0f;
		agent.SetDestination(.(8, 4.1f, 8), 4, 0.15f);
		for (int i < 300)
		{
			if (agent.HasArrived) break;
			scene.Update();
		}
		ok &= Check(agent.HasArrived && walker.Transform.Position.y > 3.9f && started == 1 && finished == 1, "existing agent crosses the mesh link and emits both events");
		return ok;
	}

	static bool OverlaysAndAgent()
	{
		let scene = scope Scene();
		Scene.Active = scene;
		Box(scene, .(8, -0.5f, 8), .(16, 1, 16));
		let surface = Surface(scene, .(16, 6, 16));
		if (!surface.Bake()) return Check(false, "overlay surface bakes");
		let data = surface.Data;
		let path = scope List<Vector3>();
		bool ok = Check(data.FindPath(.(2, 0.1f, 8), .(14, 0.1f, 8), path) && Length(path) < 12.1f, "open mesh returns a direct path");
		let obstacle = scene.CreateGameObject("Carved crate").AddComponent<NavigationObstacle>();
		obstacle.Transform.Position = .(8, 0, 8);
		obstacle.size = .(2, 2, 4);
		obstacle.carveOnlyStationary = false;
		surface.RefreshOverlay();
		ok &= Check(!data.SamplePosition(.(8, 0.1f, 8), 0.2f, ?) && data.FindPath(.(2, 0.1f, 8), .(14, 0.1f, 8), path) && Length(path) > 12.5f && Clear(data, path), "carving removes the footprint and mesh routes around it");
		obstacle.carve = false;
		surface.RefreshOverlay();
		ok &= Check(data.FindPath(.(2, 0.1f, 8), .(14, 0.1f, 8), path) && Length(path) < 12.1f, "removing carving restores direct traversal");
		let area = scene.CreateGameObject("Mud").AddComponent<NavigationArea>();
		area.Transform.Position = .(8, 0, 8);
		area.size = .(8, 2, 4);
		area.cost = 20;
		surface.RefreshOverlay();
		ok &= Check(data.FindPath(.(2, 0.1f, 8), .(14, 0.1f, 8), path) && Length(path) > 12.5f, "mesh cost areas change route choice");
		let lowCost = scene.CreateGameObject("Overlapping cheap annotation").AddComponent<NavigationArea>();
		lowCost.Transform.Position = area.Transform.Position;
		lowCost.size = area.size;
		lowCost.cost = 1;
		surface.RefreshOverlay();
		ok &= Check(data.FindPath(.(2, 0.1f, 8), .(14, 0.1f, 8), path) && Length(path) > 12.5f, "higher overlapping mesh costs win regardless of component order");
		lowCost.Enabled = false;
		area.blocked = true;
		surface.RefreshOverlay();
		ok &= Check(!data.SamplePosition(.(8, 0.1f, 8), 0.2f, ?) && data.FindPath(.(2, 0.1f, 8), .(14, 0.1f, 8), path) && Clear(data, path), "blocked mesh areas retain clearance");
		area.Enabled = false;
		surface.RefreshOverlay();
		let walker = scene.CreateGameObject("Walker");
		walker.Transform.Position = .(2, 0.1f, 8);
		let agent = walker.AddComponent<NavigationAgent>();
		agent.surface = surface;
		agent.avoidOthers = false;
		scene.StartPlay();
		scene.Update();
		agent.SetDestination(.(14, 0.1f, 8), 4, 0.15f);
		Time.DeltaTime = 1 / 60.0f;
		for (int i < 300)
		{
			if (agent.HasArrived) break;
			scene.Update();
		}
		ok &= Check(!agent.PathFailed && agent.HasArrived && walker.Transform.Position.x > 13.7f, "existing NavigationAgent follows a polygon route to arrival");
		return ok;
	}

	static bool GeometryInputs()
	{
		let scene = scope Scene();
		Scene.Active = scene;
		let ground = Box(scene, .(8, 0, 8), .(16, 1, 16));
		ground.GetComponent<BoxCollider>().center = .(0, -0.5f, 0);
		let rendered = scene.CreateGameObject("Runtime wall");
		rendered.Transform.Position = .(8, 1.5f, 5);
		rendered.Transform.LocalScale = .(1, 3, 10);
		rendered.AddComponent<MeshRenderer>().RuntimeMesh = Primitives.CreateCube();
		let surface = Surface(scene, .(16, 6, 16));
		surface.includeRenderMeshes = true;
		let path = scope List<Vector3>();
		bool ok = Check(surface.Bake() && surface.Data.FindPath(.(2, 0.1f, 2), .(14, 0.1f, 2), path) && Length(path) > 20, "transformed runtime render meshes contribute to the polygon bake");
		rendered.AddComponent<Rigidbody>();
		ok &= Check(surface.Bake() && surface.Data.FindPath(.(2, 0.1f, 2), .(14, 0.1f, 2), path) && Length(path) < 12.1f, "dynamic actors and their render geometry are excluded from polygon bakes");
		Box(scene, .(8, 1.25f, 8), .(8, 0.5f, 8));
		ok &= Check(surface.Bake() && !surface.Data.SamplePosition(.(8, 0.1f, 8), 0.2f, ?) && surface.Data.FindPath(.(2, 0.1f, 8), .(14, 0.1f, 8), path) && Length(path) > 12.5f, "insufficient headroom removes the lower walking spans");
		return ok;
	}

	static bool TiledUpdates()
	{
		let scene = scope Scene();
		Scene.Active = scene;
		Box(scene, .(64, -0.5f, 64), .(128, 1, 128));
		let surface = Surface(scene, .(128, 6, 128));
		if (!surface.Bake()) return Check(false, "tiled surface bakes");
		let data = surface.Data;
		let mesh = data.Mesh;
		let path = scope List<Vector3>();
		let far = data.Nearest(.(55, 0.1f, 55), 0.5f);
		bool ok = Check(mesh.TileCount > 4 && data.FindPath(.(2, 0.1f, 2), .(62, 0.1f, 62), path) && Clear(data, path), "polygon routes cross connected tile boundaries");
		Box(scene, .(15, 1.5f, 15), .(2, 3, 2));
		ok &= Check(surface.Rebuild(.(.(14, 0, 14), .(16, 3, 16))) && mesh.LastRebuiltTiles > 0 && mesh.LastRebuiltTiles < mesh.TileCount / 2 && data.Nearest(.(55, 0.1f, 55), 0.5f) == far, "geometry edits rebuild nearby tiles and preserve distant references");
		let blocked = !data.SamplePosition(.(15, 0.1f, 15), 0.2f, ?);
		let routed = data.FindPath(.(2, 0.1f, 2), .(62, 0.1f, 62), path);
		let clear = Clear(data, path);
		ok &= Check(blocked && routed && clear, "rebuilt geometry blocks traversal without opening tile seams");
		let obstacle = scene.CreateGameObject("Tile boundary carve").AddComponent<NavigationObstacle>();
		obstacle.Transform.Position = .(128.0f / 3, 0, 128.0f / 3);
		obstacle.size = .(2, 2, 2);
		obstacle.carveOnlyStationary = false;
		surface.RefreshOverlay();
		ok &= Check(mesh.LastRebuiltTiles > 0 && mesh.LastRebuiltTiles < mesh.TileCount && !data.SamplePosition(.(128.0f / 3, 0.1f, 128.0f / 3), 0.2f, ?) && data.FindPath(.(2, 0.1f, 2), .(62, 0.1f, 62), path) && Clear(data, path), "carving at a tile corner updates every affected tile and retains clearance");
		obstacle.Transform.Position = .(55, 0, 55);
		surface.RefreshOverlay();
		ok &= Check(data.SamplePosition(.(128.0f / 3, 0.1f, 128.0f / 3), 0.2f, ?) && !data.SamplePosition(.(55, 0.1f, 55), 0.2f, ?) && mesh.LastRebuiltTiles < mesh.TileCount, "moving carving updates old and new tile footprints");
		return ok;
	}

	static bool LongTileLinks()
	{
		let scene = scope Scene();
		Scene.Active = scene;
		Box(scene, .(4, -0.5f, 4), .(8, 1, 8));
		Box(scene, .(180, -0.5f, 180), .(8, 1, 8));
		let surface = Surface(scene, .(192, 6, 192));
		if (!surface.Bake()) return false;
		let path = scope List<Vector3>();
		let legs = scope List<int32>();
		bool ok = Check(!surface.Data.FindPath(.(3, 0.1f, 3), .(180, 0.1f, 180), path), "empty tiles do not connect distant islands");
		let link = scene.CreateGameObject("Long teleporter").AddComponent<NavigationLink>();
		link.Transform.Position = .(3, 0.1f, 3);
		link.end = .(177, 0, 177);
		surface.RefreshOverlay();
		ok &= Check(surface.Data.FindPath(.(3, 0.1f, 3), .(180, 0.1f, 180), path, legs) && legs.Contains(0) && surface.Data.FindPath(.(180, 0.1f, 180), .(3, 0.1f, 3), path), "off-mesh connections bridge nonadjacent tiles in both directions");
		link.Enabled = false;
		surface.RefreshOverlay();
		ok &= Check(!surface.Data.FindPath(.(3, 0.1f, 3), .(180, 0.1f, 180), path), "tile updates remove long-link connections without stale routes");
		return ok;
	}

	static int BakeScenes(String[] args)
	{
		if (args.Count < 3 || args[0] != "--bake-scenes") return 1;
		Assets.ProjectPath.Set(args[1]);
		for (int i = 2; i < args.Count; i++)
		{
			let scene = scope Scene();
			Scene.Active = scene;
			if (!SceneSerializer.LoadFromFile(scene, scope $"{args[1]}/{args[i]}")) return 1;
			int count = 0;
			for (let component in scene.ComponentsOfType(typeof(NavigationSurface)))
			{
				let surface = (NavigationSurface)component;
				if (surface.flying) continue;
				Console.WriteLine(scope $"Baking {args[i]}: backend={surface.backend}, origin={surface.Transform.Position}, size={surface.size}, components={scene.Components.Count}");
				if (surface.backend != .NavMesh || !surface.Bake())
				{
					Console.WriteLine("FAIL scene bake");
					return 1;
				}
				if (!surface.Data.IsNavMesh || surface.Data.Mesh.PolygonCount <= 0)
				{
					Console.WriteLine(scope $"FAIL empty mesh: native={surface.Data.IsNavMesh}");
					return 1;
				}
				if (!surface.bakedData.IsEmpty && !surface.SaveData()) return 1;
				int agents = 0, sampled = 0;
				for (let candidate in scene.ComponentsOfType(typeof(NavigationAgent)))
				{
					let agent = (NavigationAgent)candidate;
					if (agent.surface != surface) continue;
					agents++;
					if (surface.Data.SamplePosition(agent.Transform.Position + agent.baseOffset, agent.snapDistance, ?))
						sampled++;
				}
				Console.WriteLine(scope $"PASS migrated {args[i]}: {surface.Data.Mesh.PolygonCount} polygons; {sampled}/{agents} agent starts sampled; asset '{surface.bakedData}'");
				if (agents > 0 && sampled == 0) return 1;
				count++;
			}
			if (count == 0) return 1;
		}
		Scene.Active = null;
		return 0;
	}

	public static int Main(String[] args)
	{
		if (args.Count > 0) return BakeScenes(args);
		bool ok = Maze();
		ok &= LayersAndLinks();
		ok &= OverlaysAndAgent();
		ok &= GeometryInputs();
		ok &= TiledUpdates();
		ok &= LongTileLinks();
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
