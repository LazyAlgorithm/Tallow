using System;
using System.Collections;

namespace Tallow;

/// Baked walking navigation (grid or polygon mesh), or a free-space volume grid for Flying agents.
/// Uses static geometry inside a box. The object's position is the box's minimum corner. See docs/navigation.md.
[Component]
class NavigationSurface : Component
{
	/// The baked navigation data: a .tnav asset in the project, loaded in Awake.
	public String bakedData = new .() ~ delete _;
	/// The bake volume's extent from the object's position.
	public Vector3 size = .(32, 10, 32);
	/// The width of one cell. Smaller cells follow the ground more closely and cost more memory and baking time.
	public float cellSize = 1;
	/// How far the agent reaches out from its centre: cells closer than this to a wall are not walkable.
	public float agentRadius = 0.3f;
	/// How tall the agent is: cells with less headroom are not walkable.
	public float agentHeight = 1.8f;
	/// The highest step the agent can walk up. Lower obstacles do not block a cell.
	public float maxStep = 0.5f;
	/// The steepest ground the agent can walk on, in degrees.
	public float maxSlope = 45;
	/// Cells to a side in each chunk that Rebuild resamples.
	public int32 chunkSize = 16;
	/// A 3D grid of free space for flying agents, rather than one floor height per cell.
	public bool flying;
	/// What walking agents walk over: a polygon mesh (NavMesh) or a grid of cells. Flying always uses a grid. Bake
	/// again after changing it.
	public NavigationBackend backend = .NavMesh;
	/// Bake render meshes (static Mesh Renderers) as well as colliders.
	public bool includeRenderMeshes = true;
	/// Bake again when the game starts: for generated worlds.
	public bool rebuildOnStart;
	/// Show the walkable cells in the Scene view while the surface is selected.
	public bool drawNavigation = true;
	NavigationData mData ~ delete _;
	// The links, obstacles and areas last put on the grid, and a hash of how they were, to notice a change.
	List<NavigationLink> mLinks = new .() ~ delete _;
	int64 mOverlayHash;
	NavigationData mOverlayData;

	/// The baked navigation data, or null before a bake or load.
	public NavigationData Data => mData;

	public override void Awake()
	{
		if (!bakedData.IsEmpty)
			LoadData();
	}

	public override void Start()
	{
		if (rebuildOnStart)
			Bake();
	}

	/// The Navigation Link a path's leg crosses (FindPath's link id), or null.
	public NavigationLink LinkOf(int32 id) => id >= 0 && id < mLinks.Count ? mLinks[id] : null;

	public override void OnLocalUpdate() => RefreshOverlay();

	static void Mix(ref int64 hash, float value)
	{
		var copy = value;
		hash = hash * 1099511628211 + (int64)(*(uint32*)&copy) + 7;
	}

	static void Mix(ref int64 hash, Vector3 value)
	{
		Mix(ref hash, value.x);
		Mix(ref hash, value.y);
		Mix(ref hash, value.z);
	}

	static void Mix(ref int64 hash, Quaternion value)
	{
		Mix(ref hash, value.x);
		Mix(ref hash, value.y);
		Mix(ref hash, value.z);
		Mix(ref hash, value.w);
	}

	/// Puts the scene's Navigation Links, Obstacles and Areas on the grid when any of them changed (called each frame;
	/// in the editor, when the surface is drawn). Agents plan again after a change.
	public void RefreshOverlay()
	{
		let data = mData;
		if (data == null)
			return;
		let playing = Scene.IsPlaying;
		int64 hash = 17;
		let obstacles = Scene.ComponentsOfType(typeof(NavigationObstacle));
		let areas = Scene.ComponentsOfType(typeof(NavigationArea));
		let links = Scene.ComponentsOfType(typeof(NavigationLink));
		for (let component in obstacles)
		{
			let obstacle = (NavigationObstacle)component;
			// In the editor an obstacle is shown carved where it stands.
			let carving = obstacle.IsActiveAndEnabled && OnThisSurface(obstacle.GameObject) && obstacle.carve && (obstacle.Carving || !playing);
			if (!carving)
				continue;
			Mix(ref hash, playing ? obstacle.CarvedPosition : obstacle.Transform.Position + obstacle.Transform.Rotation * obstacle.center);
			Mix(ref hash, playing ? obstacle.CarvedRotation : obstacle.Transform.Rotation);
			Mix(ref hash, obstacle.size);
			Mix(ref hash, (float)obstacle.shape);
		}
		for (let component in areas)
		{
			let area = (NavigationArea)component;
			if (!area.IsActiveAndEnabled || !OnThisSurface(area.GameObject))
				continue;
			Mix(ref hash, area.Transform.Position);
			Mix(ref hash, area.Transform.Rotation);
			Mix(ref hash, area.size);
			Mix(ref hash, area.blocked ? -1 : area.cost);
		}
		for (let component in links)
		{
			let link = (NavigationLink)component;
			if (!link.IsActiveAndEnabled || !OnThisSurface(link.GameObject))
				continue;
			Mix(ref hash, link.StartPoint);
			Mix(ref hash, link.EndPoint);
			Mix(ref hash, link.bidirectional ? 1 : 0);
			Mix(ref hash, link.costMultiplier);
			Mix(ref hash, link.snapDistance);
		}
		// Also after a rebake (a new grid, or the same one rebuilt).
		Mix(ref hash, (float)data.cells.Count);
		if (hash == mOverlayHash && mOverlayData == data)
			return;
		mOverlayHash = hash;
		mOverlayData = data;
		data.ClearOverlay();
		for (let component in areas)
		{
			let area = (NavigationArea)component;
			if (!area.IsActiveAndEnabled || !OnThisSurface(area.GameObject))
				continue;
			if (area.blocked)
				data.Block(area.Transform.Position, area.Transform.Rotation, area.size * 0.5f, false, false);
			else
				data.SetCost(area.Transform.Position, area.Transform.Rotation, area.size * 0.5f, area.cost);
		}
		for (let component in obstacles)
		{
			let obstacle = (NavigationObstacle)component;
			if (!obstacle.IsActiveAndEnabled || !OnThisSurface(obstacle.GameObject) || !obstacle.carve || !(obstacle.Carving || !playing))
				continue;
			let position = playing ? obstacle.CarvedPosition : obstacle.Transform.Position + obstacle.Transform.Rotation * obstacle.center;
			let rotation = playing ? obstacle.CarvedRotation : obstacle.Transform.Rotation;
			data.Block(position, rotation, obstacle.HalfExtents, obstacle.shape == .Cylinder);
		}
		mLinks.Clear();
		let found = scope List<NavigationData.Link>();
		for (let component in links)
		{
			let link = (NavigationLink)component;
			if (!link.IsActiveAndEnabled || !OnThisSurface(link.GameObject))
				continue;
			if (data.Mesh != null)
			{
				data.Mesh.AddLink(link.StartPoint, link.EndPoint, Math.Max(link.snapDistance, 0.05f), Math.Max(link.costMultiplier, 0.1f), link.bidirectional, (int32)mLinks.Count);
				mLinks.Add(link);
				continue;
			}
			let snap = Math.Max(link.snapDistance, data.cellSize);
			let from = data.Nearest(link.StartPoint, snap);
			let to = data.Nearest(link.EndPoint, snap);
			if (from < 0 || to < 0)
			{
				// It may belong to another surface; only one whose ends are both off every grid is a mistake.
				continue;
			}
			NavigationData.Link entry;
			entry.from = from;
			entry.to = to;
			entry.twoWay = link.bidirectional;
			entry.cost = Math.Max((link.EndPoint - link.StartPoint).Length, data.cellSize * 0.5f) * Math.Max(link.costMultiplier, 0.1f);
			entry.id = (int32)mLinks.Count;
			mLinks.Add(link);
			found.Add(entry);
		}
		// The hash is kept on failure, so a change that cannot be built is reported once, not every frame.
		if (data.Mesh == null)
			data.SetLinks(found);
		else if (!data.CommitNavMesh())
			Log.Error(scope $"Navigation Surface '{GameObject.Name}': the obstacles, areas and links could not be put on its mesh (too many different area costs?). It keeps the last mesh.");
	}

	/// Reads the data from its Baked Data asset.
	public bool LoadData()
	{
		let path = scope String();
		Assets.ResolvePath(bakedData, path);
		let candidate = new NavigationData();
		let error = scope String();
		if (!candidate.Load(path, error))
		{
			delete candidate;
			Log.Warning(error);
			return false;
		}
		delete mData;
		mData = candidate;
		return true;
	}

	/// Whether an obstacle, area or link changes this surface: in the scene's active state, or with world states set
	/// apart, in the world state this surface is baked for.
	bool OnThisSurface(GameObject gameObject)
	{
		if (Scene != null && Scene.Physics.SeparatesWorldStates)
			return (gameObject.EffectiveWorldStates & BakeWorlds) != 0;
		return gameObject.InActiveWorld;
	}

	/// The world state this surface is for: the one its object is in when that is only one (give each world state a
	/// surface of its own that way), otherwise the scene's active state. Only objects in it are walked on.
	public uint32 BakeWorlds
	{
		get
		{
			// Only the states the project has count (an object is in all 32 bits' worth by default).
			let count = ProjectConfig.WorldStates.Count;
			let mask = GameObject.EffectiveWorldStates & (count >= 32 ? uint32.MaxValue : (1u << (uint32)count) - 1);
			if (mask != 0 && (mask & (mask - 1)) == 0) return mask;
			return 1u << Scene.WorldState;
		}
	}

	/// The NavMesh bake settings from the fields: voxels a third of a cell across (NavigationMesh.VoxelsPerCell), and
	/// half that high, at most 10 cm.
	NavigationMesh.Config MeshSettings
	{
		get
		{
			let voxel = Math.Max(cellSize / NavigationMesh.VoxelsPerCell, 0.01f);
			return .()
				{
					min = Transform.Position, max = Transform.Position + size, cellSize = voxel, cellHeight = Math.Clamp(voxel * 0.5f, 0.005f, 0.1f),
					radius = agentRadius, height = agentHeight, climb = maxStep, slope = maxSlope
				};
		}
	}

	/// Bakes the surface from the scene's static geometry, replacing its data. False (with a warning) when it fails.
	public bool Bake()
	{
		let candidate = new NavigationData();
		let error = scope String();
		if (backend == .NavMesh && !flying)
		{
			if (!cellSize.IsFinite || cellSize < 0.05f || !size.x.IsFinite || !size.y.IsFinite || !size.z.IsFinite || size.x <= 0 || size.y <= 0 || size.z <= 0)
			{
				delete candidate;
				Log.Warning(scope $"Navigation Surface '{GameObject.Name}': its size and Cell Size must be positive (Cell Size at least 0.05).");
				return false;
			}
			let world = scope PhysicsWorld();
			NavigationBaker.BuildGeometry(Scene, world, includeRenderMeshes, BakeWorlds);
			let mesh = NavigationMesh.Bake(world, MeshSettings);
			if (mesh == null)
			{
				delete candidate;
				Log.Warning(scope $"Navigation Surface '{GameObject.Name}': the NavMesh bake failed. Its size over its Cell Size may be too many voxels (4096 a side), or the agent too large for them.");
				return false;
			}
			candidate.SetMesh(mesh);
			delete mData;
			mData = candidate;
			mOverlayData = null;
			RefreshOverlay();
			return true;
		}
		if (!candidate.Configure(Transform.Position, size, cellSize, flying, chunkSize, error))
		{
			delete candidate;
			Log.Warning(error);
			return false;
		}
		candidate.agentRadius = agentRadius;
		candidate.agentHeight = agentHeight;
		candidate.maxStep = maxStep;
		candidate.maxSlope = maxSlope;
		if (!NavigationBaker.Bake(candidate, Scene, size.y, error, includeRenderMeshes, BakeWorlds))
		{
			delete candidate;
			Log.Warning(error);
			return false;
		}
		delete mData;
		mData = candidate;
		return true;
	}

	/// Writes the data to its Baked Data asset.
	public bool SaveData()
	{
		if (mData == null || bakedData.IsEmpty) return false;
		let path = scope String();
		Assets.ResolvePath(bakedData, path);
		let error = scope String();
		if (!mData.Save(path, error))
		{
			Log.Warning(error);
			return false;
		}
		return true;
	}

	/// Bakes again only round a box whose geometry changed (a door opened, a wall built): the grid's chunks or the
	/// mesh's tiles there.
	public bool Rebuild(Bounds changed)
	{
		if (mData == null) return Bake();
		let world = scope PhysicsWorld();
		let error = scope String();
		if (!changed.IsValid)
		{
			Log.Warning("Invalid navigation rebuild bounds.");
			return false;
		}
		if (mData.IsNavMesh)
		{
			NavigationBaker.BuildGeometry(Scene, world, includeRenderMeshes, BakeWorlds);
			if (!mData.Mesh.Rebuild(world, changed))
			{
				Log.Warning(scope $"Navigation Surface '{GameObject.Name}': rebuilding its NavMesh tiles failed; it keeps the last mesh.");
				return false;
			}
			mData.Touch();
			return true;
		}
		NavigationBaker.BuildGeometry(Scene, world, includeRenderMeshes, true, NavigationBaker.QueryBounds(mData, size.y, changed), BakeWorlds);
		let ok = NavigationBaker.Rebuild(mData, world, size.y, changed, error);
		if (!ok)
			Log.Warning(error);
		return ok;
	}

	/// Selected: the bake volume as a box, walkable floor as a see-through blue overlay with its edges outlined, and for a
	/// flight volume the free cells that touch something solid.
	public override void OnDrawGizmos(bool selected)
	{
		if (!selected) return;
		// The box follows the fields being edited; a bake that used other bounds shows as a second, dimmer box.
		let area = Bounds(Transform.Position, Transform.Position + size);
		Gizmos.Lines.Box(area, .(0.2f, 0.8f, 1, 1));
		let data = mData;
		if (data == null) return;
		let baked = Bounds(data.origin, data.origin + .(data.width * data.cellSize, data.flying ? data.height * data.cellSize : size.y, data.depth * data.cellSize));
		if ((baked.min - area.min).Length > 0.01f || (baked.max - area.max).Length > 0.01f)
			Gizmos.Lines.Box(baked, .(0.2f, 0.8f, 1, 0.35f));
		if (!drawNavigation) return;
		RefreshOverlay();
		if (data.IsNavMesh)
		{
			data.Mesh.DrawGizmos();
			return;
		}
		const int MaxGizmoQuads = 20000;
		// Cells an obstacle or a blocked area cuts out, red; costly areas, purple.
		{
			let h = data.cellSize * 0.45f;
			let lift = Vector3(0, 0.06f, 0);
			int marked = 0;
			for (int32 i < (int32)data.cells.Count)
			{
				let blocked = data.Blocked(i);
				let costly = data.CostScale(i) > 1;
				if ((!blocked && !costly) || !data.cells[i].walkable || marked++ > MaxGizmoQuads)
					continue;
				let p = data.cells[i].position + lift;
				let color = blocked ? Color(1, 0.2f, 0.15f, 0.6f) : Color(0.7f, 0.3f, 1, 0.5f);
				if (data.flying)
					Gizmos.Lines.Box(Bounds(p - .(h, h, h), p + .(h, h, h)), color);
				else
					Gizmos.Triangles.Quad(p + .(-h, 0, -h), p + .(h, 0, -h), p + .(h, 0, h), p + .(-h, 0, h), color);
			}
		}
		let edge = Color(0.05f, 0.35f, 0.75f, 1);
		if (!data.flying)
		{
			let h = data.cellSize * 0.5f;
			let lift = Vector3(0, 0.04f, 0);
			int quads = 0;
			for (int32 z = 0; z < data.depth; z++)
			{
				for (int32 x = 0; x < data.width; x++)
				{
					let cell = data.cells[data.Index(x, 0, z)];
					if (!cell.walkable) continue;
					// A row of cells at one height is a single quad, so a large flat floor stays cheap to draw.
					var end = x;
					while (end + 1 < data.width && data.cells[data.Index(end + 1, 0, z)].walkable && Math.Abs(data.cells[data.Index(end + 1, 0, z)].position.y - cell.position.y) < 0.005f)
						end++;
					if (quads++ < MaxGizmoQuads)
					{
						let a = cell.position + lift;
						let b = data.cells[data.Index(end, 0, z)].position + lift;
						Gizmos.Triangles.Quad(a + .(-h, 0, -h), b + .(h, 0, -h), b + .(h, 0, h), a + .(-h, 0, h), .(0.05f, 0.4f, 1, 0.5f));
					}
					for (var run = x; run <= end; run++)
					{
						// Outline every side an agent cannot cross.
						let links = data.cells[data.Index(run, 0, z)].links;
						let p = data.cells[data.Index(run, 0, z)].position + lift;
						if (quads > MaxGizmoQuads) break;
						if ((links & 1) == 0)
							Gizmos.Lines.Line(p + .(h, 0, -h), p + .(h, 0, h), edge);
						if ((links & 2) == 0)
							Gizmos.Lines.Line(p + .(-h, 0, -h), p + .(-h, 0, h), edge);
						if ((links & 4) == 0)
							Gizmos.Lines.Line(p + .(-h, 0, h), p + .(h, 0, h), edge);
						if ((links & 8) == 0)
							Gizmos.Lines.Line(p + .(-h, 0, -h), p + .(h, 0, -h), edge);
					}
					x = end;
				}
			}
			return;
		}
		// A flight volume is mostly open space, so only cells beside something solid are drawn; they outline the obstacles.
		// When there are still too many, every Nth is drawn so the whole volume stays covered.
		bool Shown(NavigationData.Cell cell)
		{
			if (!cell.walkable) return false;
			for (int32 direction = 0; direction < 6; direction++)
			{
				if ((cell.links & (1u << direction)) == 0)
					return true;
			}
			return false;
		}
		int total = 0;
		for (let cell in data.cells)
		{
			if (Shown(cell))
				total++;
		}
		let stride = Math.Max((total + MaxGizmoQuads - 1) / MaxGizmoQuads, 1);
		int index = 0;
		let s = Math.Min(0.15f, data.cellSize * 0.3f);
		for (let cell in data.cells)
		{
			if (Shown(cell) && index++ % stride == 0)
			{
				let p = cell.position;
				Gizmos.Lines.Line(p - .(s, 0, 0), p + .(s, 0, 0), edge);
				Gizmos.Lines.Line(p - .(0, 0, s), p + .(0, 0, s), edge);
				Gizmos.Lines.Line(p - .(0, s, 0), p + .(0, s, 0), edge);
			}
		}
	}
}
