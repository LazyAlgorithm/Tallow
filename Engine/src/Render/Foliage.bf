using System;
using System.Collections;

namespace Tallow;

/// A Foliage's settings and its plants (packed), in its entity (Foliage is the handle). The plants as plants are its
/// FoliageState; the packed text is written from them when the scene is saved (Sync).
[Component, HandleData]
struct FoliageData
{
	/// The plant's model: "builtin:grass", "builtin:bush", "builtin:tree", "builtin:pine", or a model in the project.
	public SharedString mesh = "builtin:grass";
	/// A material (.tmat) for the plants. Empty: the model's own colours, two-sided, smoothly shaded.
	public SharedString material = default;
	public Color color = .White;
	/// How much plants differ in shade from one to the next.
	[Range(0, 1)]
	public float colorVariation = 0.3f;
	/// Each plant's size is somewhere between these.
	public float minScale = 0.8f;
	public float maxScale = 1.3f;
	/// How far plants bend in the wind: 1 for grass, less for stiff bushes and trees, 0 for rocks.
	[Range(0, 2)]
	public float sway = 1;
	/// Worth it for trees; a field of grass is better without.
	public bool castShadows = false;
	/// Plants further than this from the camera are not drawn.
	public float viewDistance = 70;
	/// The brush: plants to each square metre of ground painted.
	public float density = 6;
	/// The brush: no plants on ground steeper than this, in degrees.
	[Range(0, 90)]
	public float maxSlope = 45;
	/// Every plant, packed (16 bytes each, as text). Written when the scene is saved. Owned by the data
	/// (HandleComponents.OwnLists), not interned: it is long and changes with every brush stroke.
	[HideInInspector]
	public String plants = new .();

	public this() { }
}

/// One kind of plant, many times over: grass, flowers, bushes, rocks, trees. Every plant of a Foliage component is the
/// same model, drawn together by the graphics card (instanced), so tens of thousands cost little; each gets its own
/// turn, size and shade so that they do not look stamped out. Add one Foliage for each kind of plant, each on an
/// object of its own (the Terrain Tools' Foliage tool makes a child of the terrain for each), then paint them on with
/// the Foliage brush in the Inspector, or place them from code.
///
/// Mesh is a model whose foot is at its origin: "builtin:grass", "builtin:bush", "builtin:tree", "builtin:pine", or a
/// model of your own. Plants bend in the wind (Wind Zone) by Sway. They are part of the scene, saved with it, and the
/// same on every machine; Paint and Erase from code change only the machine they are called on.
///
/// Plants are scenery: they have no colliders, and nothing is drawn beyond View Distance (they thin out towards it
/// rather than stopping at a line).
///
/// A handle (ComponentHandle): its settings are FoliageData's fields; the plants are its FoliageState.
[Component, HandleFields]
struct Foliage : ComponentHandle<FoliageData>
{
	/// Times every Foliage's View Distance (a quality setting).
	public static float DistanceScale = 1;

	/// The plants, with the settings copied in now (and re-read from the packed text if that was changed, as by
	/// loading or undo).
	public FoliageState State
	{
		get
		{
			CheckValid();
			ref FoliageData data = ref Data;
			if (data.plants == null)
				data.plants = new .();
			let state = ComponentState<FoliageState>.Make(mGameObject.Scene.World, mGameObject.Entity);
			state.[Friend]mGameObject = mGameObject;
			state.data = data;
			state.[Friend]Read();
			return state;
		}
	}

	/// How many plants there are.
	public int32 Count => State.Count;
	public Mesh Mesh => Assets.GetMesh(mesh);
	/// Stands in for a Mesh Renderer when the plants are drawn.
	public RenderProxy Proxy => State.Proxy;
	public Material ActiveMaterial => State.ActiveMaterial;

	/// Packs the plants into the `plants` field if they have changed since it was last written. Saving a scene does
	/// it; so must anything else that takes the scene as text (the editor's undo, and its copy of the scene taken
	/// before play).
	public void Sync() => State.Sync();

	/// Sync for every Foliage of a scene.
	public static void SyncAll(Scene scene)
	{
		for (let foliage in scene.FindComponents<Foliage>(.. scope .()))
			foliage.Sync();
	}

	/// Adds one plant at a place in the world. turn is in degrees about the plant's own up; scale 0 picks a size
	/// between Min Scale and Max Scale.
	public void Add(Vector3 worldPosition, float turn = -1, float scale = 0) => State.Add(worldPosition, turn, scale);
	/// Removes every plant.
	public void Clear() => State.Clear();
	/// The brush (FoliageState.Paint).
	public int32 Paint(Vector3 worldCenter, float radius, float amount = 1) => State.Paint(worldCenter, radius, amount);
	/// Removes the plants inside a circle (measured flat, whatever their height). Returns how many went.
	public int32 Erase(Vector3 worldCenter, float radius) => State.Erase(worldCenter, radius);
	/// Puts plants back on sculpted ground (FoliageState.FollowGround).
	public int32 FollowGround(VoxelTerrain terrain, Vector3 worldCenter, float radius) => State.FollowGround(terrain, worldCenter, radius);
	/// Where a plant is, in the world.
	public Vector3 PositionOf(int index) => State.PositionOf(index);

	/// The terrain a Foliage's plants stand on: one on its own object, else on the nearest parent, else the scene's.
	public static VoxelTerrain GroundOf(GameObject gameObject)
	{
		for (var transform = gameObject.Transform; transform != null; transform = transform.Parent)
		{
			if (let terrain = transform.GameObject.GetComponent<VoxelTerrain>())
				return terrain;
		}
		return gameObject.Scene?.FindComponent<VoxelTerrain>();
	}

	/// Called by a terrain when its ground has been sculpted inside a sphere (radius below 0: anywhere): every
	/// Foliage standing on that terrain follows the ground.
	public static void GroundChanged(VoxelTerrain terrain, Vector3 worldCenter, float radius)
	{
		let scene = terrain.Scene;
		if (scene == null)
			return;
		for (let foliage in scene.FindComponents<Foliage>(.. scope .()))
		{
			let state = foliage.State;
			if (state.Count == 0 || GroundOf(foliage.GameObject) != terrain)
				continue;
			state.FollowGround(terrain, worldCenter, radius);
		}
	}

	static void OnRemove(void* world, uint64 entity)
	{
		ComponentState<FoliageState>.Release(world, entity);
		HandleComponents.FreeLists(world, entity, typeof(Foliage));
	}
}

/// What a Foliage keeps outside its data: its plants, the grid of cells they are found by, and what draws them.
/// `data` is a copy of the settings (its `plants` text is the component's, written here by Sync).
[DataFields(typeof(FoliageData), "data")]
class FoliageState
{
	public FoliageData data;
	GameObject mGameObject;

	public GameObject GameObject => mGameObject;
	Transform Transform => mGameObject.Transform;
	Scene Scene => mGameObject.Scene;

	struct Plant
	{
		public Vector3 position;
		public float yaw;
		public float scale;
	}

	class Cell
	{
		public List<int32> plants = new .() ~ delete _;
		public float minY = float.MaxValue, maxY = float.MinValue;
	}

	const float CellSize = 16;

	List<Plant> mPlants = new .() ~ delete _;
	List<Matrix4> mLocal = new .() ~ delete _;
	Dictionary<int64, Cell> mCells = new .() ~ DeleteDictionaryAndValues!(_);
	bool mCellsStale;
	bool mChanged;
	String mSynced = new .() ~ delete _;
	RenderProxy mProxy = new .() ~ delete _;
	Material mOwnMaterial = new .() ~ delete _;
	// A different run of chances for each component, or two kinds of plant would land in the same places.
	static int32 sSeeds = 1;
	Random mRandom = new .(12345 + 7919 * sSeeds++) ~ delete _;
	float mCarry;

	/// How many plants there are.
	public int32 Count => (int32)mPlants.Count;
	public Mesh Mesh => Assets.GetMesh(mesh);

	/// Stands in for a Mesh Renderer when the plants are drawn: the settings every plant shares.
	public RenderProxy Proxy
	{
		get
		{
			mProxy.color = color;
			mProxy.flatShading = false;
			mProxy.roughness = 0.9f;
			mProxy.castShadows = castShadows;
			mProxy.windSway = sway;
			return mProxy;
		}
	}

	public Material ActiveMaterial
	{
		get
		{
			if (!material.IsEmpty)
			{
				let loaded = Material.Load(material);
				if (loaded != null)
					return loaded;
			}
			mOwnMaterial.doubleSided = true;
			mOwnMaterial.flatShading = false;
			mOwnMaterial.roughness = 0.9f;
			return mOwnMaterial;
		}
	}

	/// Packs the plants into the `plants` field if they have changed since it was last written. Saving a scene does
	/// it; so must anything else that takes the scene as text (the editor's undo, and its copy of the scene taken
	/// before play).
	public void Sync()
	{
		if (!mChanged)
			return;
		Write();
		mChanged = false;
	}

	// ---- placing ----

	static int64 Key(int32 x, int32 z) => ((int64)x << 32) | (uint32)z;
	static int32 CellOf(float v) => (int32)Math.Floor(v / CellSize);

	void Place(Plant plant)
	{
		let index = (int32)mPlants.Count;
		mPlants.Add(plant);
		mLocal.Add(Matrix4.TRS(plant.position, Quaternion.AngleAxis(plant.yaw * Mathf.Rad2Deg, .Up), .(plant.scale)));
		if (mCellsStale)
			return;
		let key = Key(CellOf(plant.position.x), CellOf(plant.position.z));
		if (!mCells.TryGetValue(key, var cell))
		{
			cell = new Cell();
			mCells[key] = cell;
		}
		cell.plants.Add(index);
		cell.minY = Math.Min(cell.minY, plant.position.y);
		cell.maxY = Math.Max(cell.maxY, plant.position.y);
	}

	void RebuildCells()
	{
		mCellsStale = false;
		for (let cell in mCells.Values)
			delete cell;
		mCells.Clear();
		let all = scope List<Plant>();
		all.AddRange(mPlants);
		mPlants.Clear();
		mLocal.Clear();
		for (let plant in all)
			Place(plant);
	}

	/// Adds one plant at a place in the world. turn is in degrees about the plant's own up; scale 0 picks a size
	/// between Min Scale and Max Scale.
	public void Add(Vector3 worldPosition, float turn = -1, float scale = 0)
	{
		Plant plant;
		plant.position = Transform.InverseTransformPoint(worldPosition);
		plant.yaw = (turn >= 0 ? turn * Mathf.Deg2Rad : (float)mRandom.NextDouble() * Mathf.PI * 2);
		plant.scale = scale > 0 ? scale : Mathf.Lerp(minScale, maxScale, (float)mRandom.NextDouble());
		if (mCellsStale)
			RebuildCells();
		Place(plant);
		mChanged = true;
	}

	/// Removes every plant.
	public void Clear()
	{
		mPlants.Clear();
		mLocal.Clear();
		mCellsStale = true;
		mChanged = true;
	}

	/// The ground under a point: a terrain (this object's, else the scene's), else colliders while the game plays,
	/// else level ground at the height given.
	bool Ground(float x, float z, float top, float fallback, out Vector3 point)
	{
		let terrain = Foliage.GroundOf(mGameObject);
		if (terrain != null)
			return terrain.Raycast(Ray(.(x, top, z), .(0, -1, 0)), Math.Max(top - fallback, 1) * 2 + 8, out point);
		if (Scene.IsPlaying)
		{
			RaycastHit hit;
			if (Scene.Physics.Raycast(.(x, top, z), .Down, Math.Max(top - fallback, 1) * 2 + 8, out hit))
			{
				point = hit.point;
				return true;
			}
		}
		point = .(x, fallback, z);
		return true;
	}

	bool Crowded(Vector3 local, float spacing)
	{
		let cx = CellOf(local.x), cz = CellOf(local.z);
		for (int32 dz = -1; dz <= 1; dz++)
		{
			for (int32 dx = -1; dx <= 1; dx++)
			{
				if (!mCells.TryGetValue(Key(cx + dx, cz + dz), let cell))
					continue;
				for (let index in cell.plants)
				{
					let other = mPlants[index].position;
					let ox = other.x - local.x, oz = other.z - local.z;
					if (ox * ox + oz * oz < spacing * spacing)
						return true;
				}
			}
		}
		return false;
	}

	/// The brush: scatters plants over the ground inside a circle, up to Density to the square metre, leaving ground
	/// steeper than Max Slope bare. amount is how much of the full density to try for in this call (1: all of it at
	/// once; a brush held down passes a little each frame). Returns how many were added.
	public int32 Paint(Vector3 worldCenter, float radius, float amount = 1)
	{
		if (mCellsStale)
			RebuildCells();
		let wanted = Math.Max(density, 0) * Mathf.PI * radius * radius * Mathf.Clamp01(amount) + mCarry;
		let tries = (int32)wanted;
		mCarry = wanted - tries;
		if (tries <= 0)
			return 0;
		// Plants keep a little apart, which is also what stops a brush held still from piling them up.
		let spacing = 0.6f / Math.Sqrt(Math.Max(density, 0.0001f));
		let steepest = Math.Cos(Mathf.Clamp(maxSlope, 0, 90) * Mathf.Deg2Rad);
		let top = worldCenter.y + radius + 2;
		int32 added = 0;
		for (int32 i < Math.Min(tries, 4000))
		{
			let angle = (float)mRandom.NextDouble() * Mathf.PI * 2;
			let away = Math.Sqrt((float)mRandom.NextDouble()) * radius;
			let x = worldCenter.x + Math.Cos(angle) * away, z = worldCenter.z + Math.Sin(angle) * away;
			Vector3 point;
			if (!Ground(x, z, top, worldCenter.y, out point))
				continue;
			if (maxSlope < 89.5f)
			{
				// The slope, from two more points close by.
				Vector3 ahead, aside;
				if (Ground(x + 0.3f, z, top, point.y, out ahead) && Ground(x, z + 0.3f, top, point.y, out aside))
				{
					var normal = Vector3.Cross(aside - point, ahead - point).Normalized;
					if (normal.y < 0)
						normal = -normal;
					if (normal.y < steepest)
						continue;
				}
			}
			let local = Transform.InverseTransformPoint(point);
			if (Crowded(local, spacing))
				continue;
			Plant plant;
			plant.position = local;
			plant.yaw = (float)mRandom.NextDouble() * Mathf.PI * 2;
			plant.scale = Mathf.Lerp(minScale, maxScale, (float)mRandom.NextDouble());
			Place(plant);
			added++;
		}
		if (added > 0)
			mChanged = true;
		return added;
	}

	/// Removes the plants inside a circle (measured flat, whatever their height). Returns how many went.
	public int32 Erase(Vector3 worldCenter, float radius)
	{
		let center = Transform.InverseTransformPoint(worldCenter);
		int32 removed = 0;
		for (int i = mPlants.Count - 1; i >= 0; i--)
		{
			let p = mPlants[i].position;
			let dx = p.x - center.x, dz = p.z - center.z;
			if (dx * dx + dz * dz > radius * radius)
				continue;
			mPlants.RemoveAtFast(i);
			mLocal.RemoveAtFast(i);
			removed++;
		}
		if (removed > 0)
		{
			mCellsStale = true;
			mChanged = true;
		}
		return removed;
	}

	/// Puts the plants inside a sphere (radius below 0: all of them) back on the ground after it has been sculpted.
	/// A plant whose ground rose or sank goes with it. One that ends up buried deeper than the sculpting could have
	/// raised the ground, or with nothing under it, is removed, so that none is left where nobody can reach it.
	///
	/// Each plant is judged from where it stands: the ground is looked for straight up or down from its own foot,
	/// not from the sky. So grass on a cave floor stays on the cave floor when the hill above is reshaped, and is
	/// only touched when its own floor moves or the cave is filled in. Returns how many moved or went.
	public int32 FollowGround(VoxelTerrain terrain, Vector3 worldCenter, float radius)
	{
		let everywhere = radius < 0;
		let voxel = Math.Max(terrain.voxelSize, 0.05f);
		let step = voxel * 0.5f;
		// How far ground can have moved: about as far as the brush reaches, and a little.
		let limit = everywhere ? 12.0f : radius + voxel * 2;
		let reach = radius + voxel * 2;
		int32 changed = 0;
		bool Solid(Vector3 at, out bool known)
		{
			float density;
			known = terrain.DensityAt(at, out density);
			return known && density > 0;
		}
		for (int i = mPlants.Count - 1; i >= 0; i--)
		{
			let world = Transform.TransformPoint(mPlants[i].position);
			if (!everywhere)
			{
				let dx = world.x - worldCenter.x, dy = world.y - worldCenter.y, dz = world.z - worldCenter.z;
				if (dx * dx + dz * dz > reach * reach || Math.Abs(dy) > reach + limit)
					continue;
			}
			bool known;
			let buried = Solid(world + Vector3(0, voxel * 0.05f, 0), out known);
			if (!known)
				continue; // that part of the terrain is not loaded: leave the plant be
			float air = 0, ground = 0;
			bool found = false;
			if (buried)
			{
				// The ground has risen over it: up to the surface, if that is near enough.
				for (float up = step; up <= limit; up += step)
				{
					if (!Solid(world + Vector3(0, up, 0), out known))
					{
						if (!known)
							break;
						air = up;
						ground = up - step;
						found = true;
						break;
					}
				}
			}
			else
			{
				// Standing in air: down to the ground, if there is any near enough.
				for (float down = 0; down <= limit; down += step)
				{
					if (Solid(world - Vector3(0, down + step, 0), out known))
					{
						air = -down;
						ground = -(down + step);
						found = true;
						break;
					}
					if (!known)
						break;
				}
			}
			if (!found)
			{
				mPlants.RemoveAtFast(i);
				mLocal.RemoveAtFast(i);
				changed++;
				continue;
			}
			// The surface is between the last air and the first ground: halve the gap a few times.
			for (int pass < 6)
			{
				let middle = (air + ground) * 0.5f;
				if (Solid(world + Vector3(0, middle, 0), out known))
					ground = middle;
				else
					air = middle;
			}
			let moved = (air + ground) * 0.5f;
			if (Math.Abs(moved) < voxel * 0.02f)
				continue;
			var plant = mPlants[i];
			plant.position = Transform.InverseTransformPoint(world + Vector3(0, moved, 0));
			mPlants[i] = plant;
			mLocal[i] = Matrix4.TRS(plant.position, Quaternion.AngleAxis(plant.yaw * Mathf.Rad2Deg, .Up), .(plant.scale));
			changed++;
		}
		if (changed > 0)
		{
			mCellsStale = true;
			mChanged = true;
		}
		return changed;
	}

	/// Where a plant is, in the world.
	public Vector3 PositionOf(int index) => Transform.TransformPoint(mPlants[index].position);

	// ---- drawing ----

	static float Chance(int32 index)
	{
		var h = (uint32)index * 2654435761;
		h ^= h >> 15;
		h *= 2246822519;
		h ^= h >> 13;
		return (float)(h & 0xFFFF) / 65535.0f;
	}

	/// The plants to draw for a camera: those in view and within View Distance, thinning out over its last third.
	public void Visible(Vector3 cameraWorld, Frustum frustum, List<int32> output)
	{
		if (mPlants.Count == 0)
			return;
		if (mCellsStale)
			RebuildCells();
		let toWorld = Transform.LocalToWorld;
		let camera = Transform.InverseTransformPoint(cameraWorld);
		let reach = Math.Max(viewDistance * Foliage.DistanceScale, 1);
		let fadeFrom = reach * 0.66f;
		let height = Mesh != null ? Mesh.Bounds.max.y * maxScale + 0.5f : 2;
		for (int32 cz = CellOf(camera.z - reach); cz <= CellOf(camera.z + reach); cz++)
		{
			for (int32 cx = CellOf(camera.x - reach); cx <= CellOf(camera.x + reach); cx++)
			{
				if (!mCells.TryGetValue(Key(cx, cz), let cell))
					continue;
				let bounds = Bounds(.(cx * CellSize - 2, cell.minY - 0.5f, cz * CellSize - 2), .((cx + 1) * CellSize + 2, cell.maxY + height, (cz + 1) * CellSize + 2)).Transformed(toWorld);
				if (!frustum.Intersects(bounds))
					continue;
				for (let index in cell.plants)
				{
					let p = mPlants[index].position;
					let dx = p.x - camera.x, dy = p.y - camera.y, dz = p.z - camera.z;
					let distance = dx * dx + dy * dy + dz * dz;
					if (distance > reach * reach)
						continue;
					if (distance > fadeFrom * fadeFrom && Chance(index) > 1 - (Math.Sqrt(distance) - fadeFrom) / (reach - fadeFrom))
						continue;
					output.Add(index);
				}
			}
		}
	}

	/// A plant's place in the world as a matrix, its shade and its size.
	public Matrix4 WorldOf(int32 index, out Color tint, out float scale)
	{
		let chance = Chance(index + 7919);
		let dim = 1 - colorVariation * 0.55f * chance;
		// Darker plants are a touch yellower too, as a real field is.
		tint = .(dim * (1 + colorVariation * 0.25f * (Chance(index + 104729) - 0.5f)), dim, dim * (1 - colorVariation * 0.2f * chance), 1);
		scale = mPlants[index].scale;
		return Transform.LocalToWorld * mLocal[index];
	}

	// ---- saving: position (3 floats), turn and size (16 bits each), as base-64 text ----

	const String Digits = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

	void Write()
	{
		let bytes = scope List<uint8>(mPlants.Count * 16);
		for (let plant in mPlants)
		{
			var position = plant.position;
			bytes.AddRange(Span<uint8>((uint8*)&position, 12));
			uint16 turn = (uint16)Math.Clamp(plant.yaw / (Mathf.PI * 2) * 65535.0f, 0, 65535);
			uint16 size = (uint16)Math.Clamp(plant.scale * 1000.0f, 1, 65535);
			bytes.Add((uint8)(turn & 0xFF));
			bytes.Add((uint8)(turn >> 8));
			bytes.Add((uint8)(size & 0xFF));
			bytes.Add((uint8)(size >> 8));
		}
		plants.Clear();
		plants.Reserve(bytes.Count * 4 / 3 + 4);
		for (int i = 0; i < bytes.Count; i += 3)
		{
			let a = (uint32)bytes[i];
			let b = ((i + 1) < bytes.Count) ? (uint32)bytes[i + 1] : (uint32)0;
			let c = ((i + 2) < bytes.Count) ? (uint32)bytes[i + 2] : (uint32)0;
			let group = (a << 16) | (b << 8) | c;
			plants.Append(Digits[(int)((group >> 18) & 63)]);
			plants.Append(Digits[(int)((group >> 12) & 63)]);
			plants.Append(Digits[(int)((group >> 6) & 63)]);
			plants.Append(Digits[(int)(group & 63)]);
		}
		mSynced.Set(plants);
	}

	void Read()
	{
		if (plants == mSynced)
			return;
		mSynced.Set(plants);
		mPlants.Clear();
		mLocal.Clear();
		for (let cell in mCells.Values)
			delete cell;
		mCells.Clear();
		mCellsStale = false;
		let bytes = scope List<uint8>(plants.Length * 3 / 4);
		uint32 group = 0;
		int have = 0;
		for (let c in plants.RawChars)
		{
			int value = -1;
			if (c >= 'A' && c <= 'Z')
				value = c - 'A';
			else if (c >= 'a' && c <= 'z')
				value = c - 'a' + 26;
			else if (c >= '0' && c <= '9')
				value = c - '0' + 52;
			else if (c == '+')
				value = 62;
			else if (c == '/')
				value = 63;
			if (value < 0)
				continue;
			group = (group << 6) | (uint32)value;
			if (++have == 4)
			{
				bytes.Add((uint8)(group >> 16));
				bytes.Add((uint8)(group >> 8));
				bytes.Add((uint8)group);
				group = 0;
				have = 0;
			}
		}
		for (int i = 0; i + 16 <= bytes.Count; i += 16)
		{
			Plant plant;
			plant.position = *(Vector3*)&bytes[i];
			plant.yaw = (float)((uint32)bytes[i + 12] | ((uint32)bytes[i + 13] << 8)) / 65535.0f * Mathf.PI * 2;
			plant.scale = (float)((uint32)bytes[i + 14] | ((uint32)bytes[i + 15] << 8)) / 1000.0f;
			if (!plant.position.x.IsFinite || !plant.position.y.IsFinite || !plant.position.z.IsFinite)
				continue;
			Place(plant);
		}
		mChanged = false;
	}
}
