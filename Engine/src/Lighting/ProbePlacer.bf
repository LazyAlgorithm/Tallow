using System;
using System.Collections;
using System.Threading;

namespace Tallow;

/// What automatic probe placement places (docs/probe-placement.md).
class ProbePlacementSettings
{
	/// Reflection Probes: one per room or covered place, more by doorways and shiny floors, and in open ground.
	public bool reflectionProbes = true;
	/// Leaves out reflection probes where nothing near is shiny (metallic, or smoother than shinyRoughness).
	public bool onlyWhereShiny = true;
	/// A surface rougher than this mirrors too little to need a probe.
	public float shinyRoughness = 0.5f;
	/// A small probe in each doorway and opening, where what a surface mirrors changes most.
	public bool doorways = true;
	/// One open-ground reflection probe for each square this many metres across.
	public float openProbeSize = 40;
	/// Light Probe Volumes: closer probes in rooms and covered places and wherever light changes over a short way.
	public bool lightProbes = true;
	/// How far apart a volume's probes are, in metres.
	public float detailSpacing = 1;
	/// The scene's own grid of probes (Probe Spacing) in open space, in metres.
	public float openSpacing = 4;
	/// How quickly light has to change, per metre, for closer probes (lower: more volumes).
	public float lightChange = 0.25f;
	/// The most probes all volumes may have together; spacing grows to keep under it.
	public int32 maxVolumeProbes = 20000;
	/// The analysis grid's cells, in metres (0: from the scene's size, 0.5 m or more).
	public float cellSize = 0;

	public void CopyFrom(ProbePlacementSettings other)
	{
		reflectionProbes = other.reflectionProbes;
		onlyWhereShiny = other.onlyWhereShiny;
		shinyRoughness = other.shinyRoughness;
		doorways = other.doorways;
		openProbeSize = other.openProbeSize;
		lightProbes = other.lightProbes;
		detailSpacing = other.detailSpacing;
		openSpacing = other.openSpacing;
		lightChange = other.lightChange;
		maxVolumeProbes = other.maxVolumeProbes;
		cellSize = other.cellSize;
	}
}

/// The probes placement would make, before they are made: shown in the editor to keep or discard.
class ProbePlan
{
	public enum Kind
	{
		Room,
		Shelter,
		Doorway,
		Open,
		ShinyFloor,
		Detail
	}

	public struct Reflection
	{
		public Kind kind;
		public Bounds area;
		public Vector3 eye;
		public bool boxProjection;
		public int32 importance;
		public float blendDistance;
	}

	public struct Volume
	{
		public Kind kind;
		public Bounds area;
		public float spacing;
		public float blendDistance;

		public int32 ProbeCount
		{
			get
			{
				let size = area.Size;
				let step = Math.Max(spacing, 0.25f);
				int32 Along(float length) => (int32)Math.Clamp(Math.Round(length / step) + 1, 2, 64);
				return Along(size.x) * Along(size.y) * Along(size.z);
			}
		}
	}

	public List<Reflection> reflections = new .() ~ delete _;
	public List<Volume> volumes = new .() ~ delete _;
	/// The scene's Probe Spacing to set (0: leave it).
	public float openSpacing;
	/// Rooms and other places left without a reflection probe because nothing in them is shiny.
	public int32 skippedPlain;
	/// Probes not placed because a probe of the user's own (not tagged as placed) already covers the place.
	public int32 skippedOwn;
	public float cellSize;
	public double seconds;

	public int32 VolumeProbes
	{
		get
		{
			int32 total = 0;
			for (let volume in volumes)
				total += volume.ProbeCount;
			return total;
		}
	}

	public static StringView KindName(Kind kind)
	{
		switch (kind)
		{
		case .Room: return "Room";
		case .Shelter: return "Under Cover";
		case .Doorway: return "Doorway";
		case .Open: return "Open";
		case .ShinyFloor: return "Shiny Floor";
		case .Detail: return "Detail";
		}
	}

	public void Describe(String output)
	{
		int32[6] counts = default;
		for (let probe in reflections)
			counts[(int)probe.kind]++;
		output.AppendF("{} reflection probe{}", reflections.Count, reflections.Count == 1 ? "" : "s");
		var first = true;
		for (int kind < 6)
		{
			if (counts[kind] == 0)
				continue;
			output.Append(first ? " (" : ", ");
			output.AppendF("{} {}", counts[kind], KindName((Kind)kind));
			first = false;
		}
		if (!first)
			output.Append(")");
		if (skippedPlain > 0)
			output.AppendF(", {} left out (nothing shiny)", skippedPlain);
		if (skippedOwn > 0)
			output.AppendF(", {} left to probes of your own", skippedOwn);
		output.AppendF("; {} light probe volume{} ({} probes)", volumes.Count, volumes.Count == 1 ? "" : "s", VolumeProbes);
		if (openSpacing > 0)
			output.AppendF(", {0:0.##} m apart in open space", openSpacing);
		output.AppendF(". Looked at the scene in {0:0.##} m cells in {1:0.0} s.", cellSize, seconds);
	}
}

/// Places light and reflection probes where they make sense (docs/probe-placement.md). It looks at the scene's
/// still objects on a grid of cells, sending rays from each empty cell to see how enclosed it is, what is above
/// and below it, how much sky it sees and how much light reaches it from the lights round it. From that:
///
/// - Rooms and covered places are found as the parts of covered space between narrowings (a watershed over each
///   cell's distance to the nearest surface: a doorway is where that distance dips). Each gets a reflection probe
///   boxed to its walls with box projection, and a Light Probe Volume.
/// - Doorways and openings get a small reflection probe of their own; shiny floors in the open get one each; open
///   ground gets one probe for each square of openProbeSize. Reflection probes are left out where nothing shiny
///   would mirror them.
/// - Where light changes over a short way (by walls, under cover, at the edge of a lamp's light), Light Probe
///   Volumes with closer probes; the scene's own grid covers open space at openSpacing.
///
/// Make one on the main thread (it copies the scene), Run it on any thread, then Apply the Plan on the main thread.
/// Placed objects are tagged Tag, so placing again replaces them and nothing else.
class ProbePlacer
{
	public const String Tag = "Placed Probe";
	const int32 MaxCells = 400000;
	const float Reach = 60;
	const int32 Directions = 40;

	public ProbePlacementSettings Settings = new .() ~ delete _;
	public ProbePlan Plan = new .() ~ delete _;
	public bool Cancel;
	/// How far through, 0 to 1.
	public float Progress => mWork > 0 ? Math.Min((float)mDone / mWork, 1) : 0;

	struct PlaceLight
	{
		public Vector3 position, direction;
		public float strength, range, cosOuter;
		public bool spot;
	}

	// The still objects' triangles in the world.
	List<float> mPositions = new .() ~ delete _;
	List<uint8> mTriShiny = new .() ~ delete _;
	// Moving shiny things' boxes.
	List<Bounds> mShinyMovers = new .() ~ delete _;
	List<PlaceLight> mLights = new .() ~ delete _;
	// The boxes of probes and volumes the user placed (not tagged as placed).
	List<Bounds> mOwnReflections = new .() ~ delete _;
	List<Bounds> mOwnVolumes = new .() ~ delete _;
	Bounds mBounds = .Empty;
	float mSkyLight;
	void* mBvh;

	// The grid.
	Vector3 mOrigin;
	float mCell;
	int32 mNx, mNy, mNz;
	// 0 empty, 1 a surface passes through, 2 inside something solid.
	uint8[] mState ~ delete _;
	// 1 something shiny, 2 a shiny floor.
	uint8[] mShiny ~ delete _;
	float[] mSky ~ delete _;
	float[] mEnclosed ~ delete _;
	float[] mUp ~ delete _;
	float[] mDown ~ delete _;
	float[] mLight ~ delete _;
	float[] mDistance ~ delete _;
	int32[] mRegion ~ delete _;
	Vector3[Directions] mDirections;

	int32 mNext, mDone, mWork, mThreadCount;

	[CLink] static extern void* tn_bake_create(float* positions, int32 vertexCount, uint32* indices, int32 triangleCount);
	[CLink] static extern void tn_bake_destroy(void* bvh);
	[CLink] static extern void tn_bake_intersect(void* bvh, float* rays, int32 count, int32* triangles, float* hits);
	[CLink] static extern void tn_bake_occluded(void* bvh, float* rays, int32 count, uint8* blocked);

	public ~this()
	{
		if (mBvh != null)
			tn_bake_destroy(mBvh);
	}

	/// Copies the scene's still objects (with which are shiny) and its lights. The main thread.
	public this(Scene scene, ProbePlacementSettings settings)
	{
		Settings.CopyFrom(settings);
		let env = scene.Environment;
		let sky = Linear(env.ambientSky, env.ambientIntensity);
		mSkyLight = Math.Max((sky.x + sky.y + sky.z) / 3, 0.02f);
		let meshes = scope List<Mesh>();
		// Each part's metallic (x) and roughness (y).
		let materials = scope List<Vector2>();
		for (let renderer in scene.Renderers)
		{
			let gameObject = renderer.GameObject;
			if (!renderer.IsActiveAndEnabled || !gameObject.InActiveWorld || gameObject.HasTag(Tag))
				continue;
			meshes.Clear();
			materials.Clear();
			let parts = renderer.DrawnParts;
			if (parts != null && parts.Count > 0)
			{
				for (let part in parts)
				{
					meshes.Add(part.mesh);
					let material = part.material ?? renderer.ActiveMaterial;
					materials.Add(material != null ? .(material.metallic, material.roughness) : .(renderer.metallic, renderer.roughness));
				}
			}
			else
			{
				meshes.Add(renderer.ActiveMesh);
				let material = renderer.ActiveMaterial;
				materials.Add(material != null ? .(material.metallic, material.roughness) : .(renderer.metallic, renderer.roughness));
			}
			if (Moves(gameObject))
			{
				for (let m in materials)
				{
					if (Shiny(m.x, m.y))
					{
						mShinyMovers.Add(renderer.WorldBounds);
						break;
					}
				}
				continue;
			}
			// Light passes through see-through things: they neither enclose a place nor need a probe of their own.
			if (renderer.color.a < 0.999f || renderer.shadowOnly)
				continue;
			let world = renderer.RenderMatrix;
			for (int p < meshes.Count)
			{
				let mesh = meshes[p];
				if (mesh == null)
					continue;
				let vertices = mesh.VertexSource != null ? mesh.VertexSource.Vertices : mesh.Vertices;
				let shiny = Shiny(materials[p].x, materials[p].y);
				for (int t < mesh.Indices.Count / 3)
				{
					let ia = mesh.Indices[t * 3], ib = mesh.Indices[t * 3 + 1], ic = mesh.Indices[t * 3 + 2];
					if (ia >= vertices.Count || ib >= vertices.Count || ic >= vertices.Count)
						continue;
					for (let index in uint32[?](ia, ib, ic))
					{
						let point = world.TransformPoint(vertices[index].position);
						mPositions.Add(point.x);
						mPositions.Add(point.y);
						mPositions.Add(point.z);
						mBounds.Encapsulate(point);
					}
					mTriShiny.Add(shiny ? 1 : 0);
				}
			}
		}
		for (let probe in scene.FindComponents<ReflectionProbe>(.. scope .()))
		{
			if (probe.IsActiveAndEnabled && !probe.GameObject.HasTag(Tag))
				mOwnReflections.Add(probe.WorldBox);
		}
		for (let volume in scene.FindComponents<LightProbeVolume>(.. scope .()))
		{
			if (volume.IsActiveAndEnabled && !volume.GameObject.HasTag(Tag))
				mOwnVolumes.Add(volume.WorldBox);
		}
		for (let light in scene.Lights)
		{
			if (!light.IsActiveAndEnabled || !light.GameObject.InActiveWorld || light.type == .Directional)
				continue;
			PlaceLight placed = default;
			placed.position = light.Transform.Position;
			placed.direction = light.Transform.Forward;
			let color = Linear(light.color, light.intensity);
			placed.strength = (color.x + color.y + color.z) / 3;
			placed.range = Math.Max(light.range, 0.01f);
			placed.spot = light.type == .Spot;
			placed.cosOuter = Math.Cos(light.spotAngle * 0.5f * Mathf.Deg2Rad);
			mLights.Add(placed);
		}
		Plan.openSpacing = settings.lightProbes ? settings.openSpacing : 0;
	}

	bool Shiny(float metallic, float roughness) => metallic >= 0.5f || roughness <= Settings.shinyRoughness;

	/// Whether an object moves by itself (a Rigidbody that is not kinematic, on it or above it).
	static bool Moves(GameObject gameObject)
	{
		for (var at = gameObject.Transform; at != null; at = at.Parent)
		{
			let body = at.GameObject.GetComponent<Rigidbody>();
			if (body != null && !body.isKinematic)
				return true;
		}
		return false;
	}

	static Vector3 Linear(Color c, float scale = 1) => .(Math.Pow(Math.Max(c.r, 0), 2.2f) * scale, Math.Pow(Math.Max(c.g, 0), 2.2f) * scale, Math.Pow(Math.Max(c.b, 0), 2.2f) * scale);

	// ---- the grid ----

	int Index(int x, int y, int z) => (z * mNy + y) * mNx + x;
	Vector3 Center(int x, int y, int z) => mOrigin + Vector3(x + 0.5f, y + 0.5f, z + 0.5f) * mCell;
	Vector3 CenterOf(int i) => Center(i % mNx, (i / mNx) % mNy, i / (mNx * mNy));
	void CellOf(int i, out int x, out int y, out int z)
	{
		x = i % mNx;
		y = (i / mNx) % mNy;
		z = i / (mNx * mNy);
	}

	/// Whether a cell is somewhere things could be: empty, and with something below it within a few metres.
	bool Used(int i) => mState[i] == 0 && mDown[i] <= 6;
	/// Whether a used cell has something over it.
	bool Covered(int i) => mUp[i] < Reach * 0.66f;

	/// Does the work. Any thread.
	public void Run()
	{
		let start = DateTime.Now;
		mThreadCount = (int32)Math.Max(1, Platform.BfpSystem_GetNumLogicalCPUs(null) - 1);
		let triangles = mTriShiny.Count;
		if (triangles == 0)
		{
			Plan.seconds = (DateTime.Now - start).TotalSeconds;
			return;
		}
		let indices = scope List<uint32>(triangles * 3);
		for (uint32 i < (uint32)triangles * 3)
			indices.Add(i);
		mBvh = tn_bake_create(mPositions.Ptr, (int32)triangles * 3, indices.Ptr, (int32)triangles);
		let golden = Math.PI_f * (3 - Math.Sqrt(5.0f));
		for (int s < Directions)
		{
			let dy = 1 - (s + 0.5f) / Directions * 2;
			let radius = Math.Sqrt(Math.Max(1 - dy * dy, 0));
			mDirections[s] = .(Math.Cos(golden * s) * radius, dy, Math.Sin(golden * s) * radius);
		}
		MakeGrid();
		MarkSurfaces();
		mShinyMovers.Clear();
		if (Cancel)
			return;
		ParallelFor(mNx * mNy * mNz, scope => LookAround);
		if (Cancel)
			return;
		Distances();
		FindRegions();
		if (Settings.reflectionProbes)
			PlaceReflections();
		if (Settings.lightProbes)
			PlaceVolumes();
		Plan.cellSize = mCell;
		Plan.seconds = (DateTime.Now - start).TotalSeconds;
	}

	void MakeGrid()
	{
		let size = mBounds.Size;
		mCell = Settings.cellSize > 0 ? Settings.cellSize : 0.5f;
		while (true)
		{
			mNx = (int32)Math.Ceiling(size.x / mCell) + 2;
			mNy = (int32)Math.Ceiling(size.y / mCell) + 2;
			mNz = (int32)Math.Ceiling(size.z / mCell) + 2;
			if ((int64)mNx * mNy * mNz <= MaxCells)
				break;
			mCell *= 1.2f;
		}
		mOrigin = mBounds.min - .(mCell, mCell * 0.5f, mCell);
		let count = mNx * mNy * mNz;
		mState = new .[count];
		mShiny = new .[count];
		mSky = new .[count];
		mEnclosed = new .[count];
		mUp = new .[count];
		mDown = new .[count];
		mLight = new .[count];
		mDistance = new .[count];
		mRegion = new .[count];
	}

	bool CellAt(Vector3 p, out int index)
	{
		let x = (int)Math.Floor((p.x - mOrigin.x) / mCell), y = (int)Math.Floor((p.y - mOrigin.y) / mCell), z = (int)Math.Floor((p.z - mOrigin.z) / mCell);
		index = 0;
		if (x < 0 || y < 0 || z < 0 || x >= mNx || y >= mNy || z >= mNz)
			return false;
		index = Index(x, y, z);
		return true;
	}

	/// Marks the cells each triangle passes through (points over it, closer than half a cell), and which are shiny.
	void MarkSurfaces()
	{
		for (int t < mTriShiny.Count)
		{
			let a = Vector3(mPositions[t * 9], mPositions[t * 9 + 1], mPositions[t * 9 + 2]);
			let b = Vector3(mPositions[t * 9 + 3], mPositions[t * 9 + 4], mPositions[t * 9 + 5]);
			let c = Vector3(mPositions[t * 9 + 6], mPositions[t * 9 + 7], mPositions[t * 9 + 8]);
			let longest = Math.Max((b - a).Length, Math.Max((c - b).Length, (a - c).Length));
			let steps = (int)Math.Clamp(Math.Ceiling(longest / (mCell * 0.5f)), 1, 4000);
			var normal = Vector3.Cross(b - a, c - a);
			let length = normal.Length;
			normal = length > 0 ? normal / length : .(0, 1, 0);
			uint8 shiny = mTriShiny[t] != 0 ? (normal.y > 0.7f ? 3 : 1) : 0;
			for (int i <= steps)
			{
				for (int j <= steps - i)
				{
					let u = (float)i / steps, v = (float)j / steps;
					if (CellAt(a + (b - a) * u + (c - a) * v, let cell))
					{
						mState[cell] = 1;
						mShiny[cell] |= shiny;
					}
				}
			}
		}
		// Shiny things that move count as shiny where they are.
		for (let area in mShinyMovers)
		{
			for (var z = area.min.z; z <= area.max.z + mCell; z += mCell)
			{
				for (var y = area.min.y; y <= area.max.y + mCell; y += mCell)
				{
					for (var x = area.min.x; x <= area.max.x + mCell; x += mCell)
					{
						if (CellAt(.(Math.Min(x, area.max.x), Math.Min(y, area.max.y), Math.Min(z, area.max.z)), let cell))
							mShiny[cell] |= 1;
					}
				}
			}
		}
	}

	/// One cell: rays all round. Solid if most hit the backs of faces; how much sky it sees; how much of round it
	/// is walled in; how far up and down to the nearest surface; and how much light reaches it from the lights.
	void LookAround(int i)
	{
		mUp[i] = mDown[i] = Reach;
		if (mState[i] != 0)
			return;
		let p = CenterOf(i);
		const int32 Count = Directions + 2;
		float[Count * 7] rays = default;
		int32[Count] hit = default;
		float[Count * 4] hits = default;
		for (int s < Count)
		{
			let d = s < Directions ? mDirections[s] : (s == Directions ? Vector3(0, 1, 0) : Vector3(0, -1, 0));
			rays[s * 7] = p.x;
			rays[s * 7 + 1] = p.y;
			rays[s * 7 + 2] = p.z;
			rays[s * 7 + 3] = d.x;
			rays[s * 7 + 4] = d.y;
			rays[s * 7 + 5] = d.z;
			rays[s * 7 + 6] = 1e30f;
		}
		tn_bake_intersect(mBvh, &rays[0], Count, &hit[0], &hits[0]);
		int backs = 0, upward = 0, open = 0, level = 0, walled = 0;
		for (int s < Directions)
		{
			let d = mDirections[s];
			if (hit[s] >= 0 && hits[s * 4 + 3] > 0.5f)
				backs++;
			if (d.y > 0)
			{
				upward++;
				if (hit[s] < 0)
					open++;
			}
			if (Math.Abs(d.y) < 0.35f)
			{
				level++;
				if (hit[s] >= 0 && hits[s * 4] < 40)
					walled++;
			}
		}
		if (backs > Directions * 0.35f)
		{
			mState[i] = 2;
			return;
		}
		mSky[i] = upward > 0 ? (float)open / upward : 0;
		mEnclosed[i] = level > 0 ? (float)walled / level : 0;
		mUp[i] = hit[Directions] >= 0 ? hits[Directions * 4] : Reach;
		mDown[i] = hit[Directions + 1] >= 0 ? hits[(Directions + 1) * 4] : Reach;
		var light = mSky[i] * mSkyLight;
		for (let lamp in mLights)
		{
			let toLight = lamp.position - p;
			let distance = toLight.Length;
			if (distance >= lamp.range)
				continue;
			let fall = 1 - (distance / lamp.range) * (distance / lamp.range);
			var share = lamp.strength * fall * fall;
			if (lamp.spot && distance > 1e-4f)
			{
				let cos = Vector3.Dot(-toLight / distance, lamp.direction);
				if (cos < lamp.cosOuter)
					continue;
				share *= Math.Clamp((cos - lamp.cosOuter) / Math.Max(1 - lamp.cosOuter, 1e-3f) * 4, 0, 1);
			}
			if (distance > 1e-3f)
			{
				float[7] ray = .(p.x, p.y, p.z, toLight.x / distance, toLight.y / distance, toLight.z / distance, Math.Max(distance - 0.05f, 0));
				uint8 blocked = 0;
				tn_bake_occluded(mBvh, &ray[0], 1, &blocked);
				if (blocked != 0)
					continue;
			}
			light += share;
		}
		mLight[i] = light;
	}

	/// Each empty cell's distance to the nearest surface or solid cell, in metres (two chamfer passes).
	void Distances()
	{
		let count = mNx * mNy * mNz;
		for (int i < count)
			mDistance[i] = mState[i] != 0 ? 0 : 1e6f;
		let straight = mCell, edge = mCell * 1.41421f, corner = mCell * 1.73205f;
		for (int pass < 2)
		{
			let forward = pass == 0;
			for (int step < count)
			{
				let i = forward ? step : count - 1 - step;
				if (mDistance[i] == 0)
					continue;
				CellOf(i, let x, let y, let z);
				var best = mDistance[i];
				for (int dz = -1; dz <= 0; dz++)
				{
					for (int dy = -1; dy <= 1; dy++)
					{
						for (int dx = -1; dx <= 1; dx++)
						{
							// The half of the neighbours already visited in this direction.
							if (dz == 0 && (dy > 0 || (dy == 0 && dx >= 0)))
								continue;
							let sx = forward ? dx : -dx, sy = forward ? dy : -dy, sz = forward ? dz : -dz;
							let nx = x + sx, ny = y + sy, nz = z + sz;
							if (nx < 0 || ny < 0 || nz < 0 || nx >= mNx || ny >= mNy || nz >= mNz)
								continue;
							let n = Math.Abs(dx) + Math.Abs(dy) + Math.Abs(dz);
							let d = mDistance[Index(nx, ny, nz)] + (n == 1 ? straight : (n == 2 ? edge : corner));
							if (d < best)
								best = d;
						}
					}
				}
				mDistance[i] = best;
			}
		}
	}

	// ---- rooms ----

	class Region
	{
		public int32 parent;
		public float peak;
		public int32 cells;
		public int32[3] lo, hi;
		public int32 walled;
		public bool shiny;
		public Bounds area;
		public bool kept;
	}

	List<Region> mRegions = new .() ~ DeleteContainerAndItems!(_);
	// Cells where two places met but stayed apart (a doorway), with the two places.
	struct Narrow
	{
		public int32 cell, a, b;
	}

	List<Narrow> mNarrows = new .() ~ delete _;

	int32 Root(int32 region)
	{
		var r = region;
		while (mRegions[r].parent != r)
			r = mRegions[r].parent;
		var at = region;
		while (mRegions[at].parent != r)
		{
			let next = mRegions[at].parent;
			mRegions[at].parent = r;
			at = next;
		}
		return r;
	}

	static float Fill(Region region) => region.cells / (float)((region.hi[0] - region.lo[0] + 1) * (region.hi[1] - region.lo[1] + 1) * (region.hi[2] - region.lo[2] + 1));

	/// Splits covered space into places: cells from the most open inwards (a watershed over the distance to the
	/// nearest surface). Where two places meet at a narrowing (a doorway), they stay apart; where they meet
	/// broadly and together still fill their box, they are one.
	void FindRegions()
	{
		let count = mNx * mNy * mNz;
		let order = scope List<int32>();
		for (int32 i < count)
		{
			mRegion[i] = -1;
			if (Used(i) && Covered(i))
				order.Add(i);
		}
		order.Sort(scope (a, b) => mDistance[b] <=> mDistance[a]);
		// Level by level, from the most open inwards; within a level, outward from the places already there (so
		// that where two places meet does not depend on the order of cells), then new places from what is left.
		let near = scope List<int32>();
		let pending = scope bool[count];
		let queue = scope List<int32>();
		// Gives out the queued cells of this level, and their neighbours of this level in turn.
		void Flood()
		{
			var head = 0;
			while (head < queue.Count)
			{
				let cell = queue[head++];
				if (!pending[cell])
					continue;
				pending[cell] = false;
				Assign(cell, near);
				CellOf(cell, let x, let y, let z);
				for (int k < 6)
				{
					let nx = x + (k == 0 ? -1 : (k == 1 ? 1 : 0)), ny = y + (k == 2 ? -1 : (k == 3 ? 1 : 0)), nz = z + (k == 4 ? -1 : (k == 5 ? 1 : 0));
					if (nx < 0 || ny < 0 || nz < 0 || nx >= mNx || ny >= mNy || nz >= mNz)
						continue;
					let n = (int32)Index(nx, ny, nz);
					if (pending[n])
						queue.Add(n);
				}
			}
			queue.Clear();
		}
		int first = 0;
		while (first < order.Count)
		{
			let level = mDistance[order[first]];
			var last = first;
			while (last < order.Count && mDistance[order[last]] >= level - 1e-4f)
				pending[order[last++]] = true;
			for (int at = first; at < last; at++)
			{
				if (Touches(order[at]))
					queue.Add(order[at]);
			}
			Flood();
			// What the waves did not reach starts a place of its own.
			for (int at = first; at < last; at++)
			{
				if (!pending[order[at]])
					continue;
				queue.Add(order[at]);
				Flood();
			}
			first = last;
		}
		for (int32 i < count)
		{
			if (mRegion[i] >= 0)
				mRegion[i] = Root(mRegion[i]);
		}
		TrimRegions();
		let cellVolume = mCell * mCell * mCell;
		for (int32 r < (int32)mRegions.Count)
		{
			let region = mRegions[r];
			if (region.parent != r)
				continue;
			region.area = .(mOrigin + Vector3(region.lo[0], region.lo[1], region.lo[2]) * mCell, mOrigin + Vector3(region.hi[0] + 1, region.hi[1] + 1, region.hi[2] + 1) * mCell);
			// Too small to be a place of its own (a gap under a table, a cupboard).
			let size = region.area.Size;
			region.kept = region.cells * cellVolume >= 6 && Math.Min(size.x, size.z) >= 1.0f && size.y >= 1.0f;
			if (region.kept)
				region.area = SnapToWalls(region.area);
			// Its own floor and walls count, not what is beyond them.
			region.shiny = AnyShiny(region.area, 0.25f);
		}
	}

	/// Gives a covered cell to the place round it (or a new one), joining places that meet broadly.
	void Assign(int32 i, List<int32> near)
	{
		CellOf(i, let x, let y, let z);
		near.Clear();
		for (int k < 6)
		{
			let nx = x + (k == 0 ? -1 : (k == 1 ? 1 : 0)), ny = y + (k == 2 ? -1 : (k == 3 ? 1 : 0)), nz = z + (k == 4 ? -1 : (k == 5 ? 1 : 0));
			if (nx < 0 || ny < 0 || nz < 0 || nx >= mNx || ny >= mNy || nz >= mNz)
				continue;
			let label = mRegion[Index(nx, ny, nz)];
			if (label < 0)
				continue;
			let root = Root(label);
			if (!near.Contains(root))
				near.Add(root);
		}
		int32 into;
		if (near.Count == 0)
		{
			let region = new Region();
			into = (int32)mRegions.Count;
			region.parent = into;
			region.peak = mDistance[i];
			region.lo = .((int32)x, (int32)y, (int32)z);
			region.hi = region.lo;
			mRegions.Add(region);
		}
		else
		{
			// The most open of the places it touches takes it; others join that one if the meeting is broad.
			into = near[0];
			for (let r in near)
			{
				if (mRegions[r].peak > mRegions[into].peak)
					into = r;
			}
			for (let r in near)
			{
				if (r == into)
					continue;
				let a = mRegions[into], b = mRegions[r];
				let merged = scope Region();
				merged.cells = a.cells + b.cells;
				for (int axis < 3)
				{
					merged.lo[axis] = Math.Min(a.lo[axis], b.lo[axis]);
					merged.hi[axis] = Math.Max(a.hi[axis], b.hi[axis]);
				}
				// A shallow basin (its deepest little more than where they meet) is part of the other; so is a
				// fragment too small to be a place.
				// Two pieces of one open stretch (both as deep as where they meet) are one whatever their shape.
				let level = Math.Max(a.peak, b.peak) - mDistance[i] < Math.Max(0.15f, mCell * 0.3f);
				let shallow = Math.Min(a.peak, b.peak) - mDistance[i] < 0.35f && Fill(merged) >= 0.5f;
				let fragment = Math.Min(a.cells, b.cells) * mCell * mCell * mCell < 1;
				if (level || shallow || fragment)
				{
					b.parent = into;
					a.cells = merged.cells;
					a.lo = merged.lo;
					a.hi = merged.hi;
					a.walled += b.walled;
				}
				else
					mNarrows.Add(.() { cell = i, a = into, b = r });
			}
		}
		mRegion[i] = into;
		let region = mRegions[into];
		region.cells++;
		if (mEnclosed[i] >= 0.75f)
			region.walled++;
		region.lo = .(Math.Min(region.lo[0], (int32)x), Math.Min(region.lo[1], (int32)y), Math.Min(region.lo[2], (int32)z));
		region.hi = .(Math.Max(region.hi[0], (int32)x), Math.Max(region.hi[1], (int32)y), Math.Max(region.hi[2], (int32)z));
	}

	/// Whether a cell is next to one already given to a place.
	bool Touches(int32 i)
	{
		CellOf(i, let x, let y, let z);
		for (int k < 6)
		{
			let nx = x + (k == 0 ? -1 : (k == 1 ? 1 : 0)), ny = y + (k == 2 ? -1 : (k == 3 ? 1 : 0)), nz = z + (k == 4 ? -1 : (k == 5 ? 1 : 0));
			if (nx < 0 || ny < 0 || nz < 0 || nx >= mNx || ny >= mNy || nz >= mNz)
				continue;
			if (mRegion[Index(nx, ny, nz)] >= 0)
				return true;
		}
		return false;
	}

	/// Each place's box without its outermost few cells on each axis: the cells of a doorway it reached into are
	/// not its walls.
	void TrimRegions()
	{
		let counts = scope Dictionary<int32, int32[]>();
		defer
		{
			for (let value in counts.Values)
				delete value;
		}
		let count = mNx * mNy * mNz;
		let sizes = int32[3](mNx, mNy, mNz);
		for (int32 i < count)
		{
			let r = mRegion[i];
			if (r < 0)
				continue;
			if (!counts.TryGetValue(r, var histogram))
			{
				histogram = new int32[mNx + mNy + mNz];
				counts[r] = histogram;
			}
			CellOf(i, let x, let y, let z);
			histogram[x]++;
			histogram[mNx + y]++;
			histogram[mNx + mNy + z]++;
		}
		for (let pair in counts)
		{
			let region = mRegions[pair.key];
			let histogram = pair.value;
			let cut = (int32)(region.cells * 0.03f);
			var start = 0;
			for (int axis < 3)
			{
				int32 below = 0, lo = region.lo[axis], hi = region.hi[axis];
				for (int32 c = region.lo[axis]; c <= region.hi[axis]; c++)
				{
					below += histogram[start + c];
					if (below > cut)
					{
						lo = c;
						break;
					}
				}
				int32 above = 0;
				for (int32 c = region.hi[axis]; c >= region.lo[axis]; c--)
				{
					above += histogram[start + c];
					if (above > cut)
					{
						hi = c;
						break;
					}
				}
				region.lo[axis] = lo;
				region.hi[axis] = Math.Max(hi, lo);
				start += sizes[axis];
			}
		}
	}

	/// A place's box with each side moved out to the surface just beyond it: its cells stop up to a cell short of
	/// the walls. A side with no surface close beyond it (an opening) goes out half a cell.
	Bounds SnapToWalls(Bounds area)
	{
		var snapped = area;
		let probes = scope List<float>();
		for (int side < 6)
		{
			let axis = side / 2;
			let sign = (side % 2) == 0 ? -1.0f : 1.0f;
			let face = sign < 0 ? area.min[axis] : area.max[axis];
			let u = (axis + 1) % 3, v = (axis + 2) % 3;
			let start = mCell * 0.25f;
			probes.Clear();
			for (int a < 3)
			{
				for (int b < 3)
				{
					var origin = Vector3.Zero;
					origin[axis] = face - sign * start;
					origin[u] = area.min[u] + (area.max[u] - area.min[u]) * (a + 1) / 4;
					origin[v] = area.min[v] + (area.max[v] - area.min[v]) * (b + 1) / 4;
					var direction = Vector3.Zero;
					direction[axis] = sign;
					float[7] ray = .(origin.x, origin.y, origin.z, direction.x, direction.y, direction.z, start + mCell * 1.5f);
					int32 triangle = -1;
					float[4] hit = default;
					tn_bake_intersect(mBvh, &ray[0], 1, &triangle, &hit[0]);
					if (triangle >= 0)
						probes.Add(hit[0] - start);
				}
			}
			var moved = mCell * 0.5f;
			if (probes.Count >= 5)
			{
				probes.Sort();
				moved = Math.Max(probes[probes.Count / 2], 0);
			}
			if (sign < 0)
				snapped.min[axis] = face - moved;
			else
				snapped.max[axis] = face + moved;
		}
		return snapped;
	}

	/// Whether anything shiny is in or beside a box.
	bool AnyShiny(Bounds area, float margin)
	{
		let lo = area.min - Vector3(margin), hi = area.max + Vector3(margin);
		let x0 = Math.Max((int)((lo.x - mOrigin.x) / mCell), 0), x1 = Math.Min((int)((hi.x - mOrigin.x) / mCell), mNx - 1);
		let y0 = Math.Max((int)((lo.y - mOrigin.y) / mCell), 0), y1 = Math.Min((int)((hi.y - mOrigin.y) / mCell), mNy - 1);
		let z0 = Math.Max((int)((lo.z - mOrigin.z) / mCell), 0), z1 = Math.Min((int)((hi.z - mOrigin.z) / mCell), mNz - 1);
		for (int z = z0; z <= z1; z++)
		{
			for (int y = y0; y <= y1; y++)
			{
				for (int x = x0; x <= x1; x++)
				{
					if (mShiny[Index(x, y, z)] != 0)
						return true;
				}
			}
		}
		return false;
	}

	/// Whether something stands up out of the ground in a box (a surface a metre or more over its lowest point).
	bool AnyStanding(Bounds area)
	{
		let x0 = Math.Max((int)((area.min.x - mOrigin.x) / mCell), 0), x1 = Math.Min((int)((area.max.x - mOrigin.x) / mCell), mNx - 1);
		let y0 = Math.Max((int)((area.min.y + 1 - mOrigin.y) / mCell), 0), y1 = Math.Min((int)((area.max.y - mOrigin.y) / mCell), mNy - 1);
		let z0 = Math.Max((int)((area.min.z - mOrigin.z) / mCell), 0), z1 = Math.Min((int)((area.max.z - mOrigin.z) / mCell), mNz - 1);
		for (int z = z0; z <= z1; z++)
		{
			for (int y = y0; y <= y1; y++)
			{
				for (int x = x0; x <= x1; x++)
				{
					if (mState[Index(x, y, z)] != 0)
						return true;
				}
			}
		}
		return false;
	}

	/// The used cell in a place (any, if region is -1) nearest a point.
	Vector3 NearestUsed(Vector3 wanted, Bounds area, int32 region)
	{
		var best = wanted;
		var bestDistance = float.MaxValue;
		let x0 = Math.Max((int)((area.min.x - mOrigin.x) / mCell), 0), x1 = Math.Min((int)((area.max.x - mOrigin.x) / mCell), mNx - 1);
		let y0 = Math.Max((int)((area.min.y - mOrigin.y) / mCell), 0), y1 = Math.Min((int)((area.max.y - mOrigin.y) / mCell), mNy - 1);
		let z0 = Math.Max((int)((area.min.z - mOrigin.z) / mCell), 0), z1 = Math.Min((int)((area.max.z - mOrigin.z) / mCell), mNz - 1);
		for (int z = z0; z <= z1; z++)
		{
			for (int y = y0; y <= y1; y++)
			{
				for (int x = x0; x <= x1; x++)
				{
					let i = Index(x, y, z);
					if (!Used(i) || (region >= 0 && mRegion[i] != region))
						continue;
					let d = (Center(x, y, z) - wanted).LengthSquared;
					if (d < bestDistance)
					{
						bestDistance = d;
						best = Center(x, y, z);
					}
				}
			}
		}
		return best;
	}

	// ---- reflection probes ----

	void PlaceReflections()
	{
		// A probe for each room or covered place, boxed to its walls.
		for (int32 r < (int32)mRegions.Count)
		{
			let region = mRegions[r];
			if (region.parent != r || !region.kept)
				continue;
			if (Settings.onlyWhereShiny && !region.shiny)
			{
				Plan.skippedPlain++;
				continue;
			}
			let indoor = region.walled >= region.cells * 0.6f;
			ProbePlan.Reflection probe = default;
			probe.kind = indoor ? .Room : .Shelter;
			probe.area = region.area;
			let center = region.area.Center;
			probe.eye = NearestUsed(.(center.x, region.area.min.y + Math.Min(1.6f, region.area.Size.y * 0.5f), center.z), region.area, r);
			probe.boxProjection = indoor;
			probe.importance = 1;
			probe.blendDistance = Math.Clamp(mCell * 2, 0.5f, 1.5f);
			Add(probe);
		}
		if (Settings.doorways)
			PlaceDoorways();
		PlaceOpenGround();
		PlaceShinyFloors();
	}

	/// A small probe across each doorway between two places, and each opening from a place to the open.
	void PlaceDoorways()
	{
		// Group the narrowing cells by the places they join, and the opening cells by their place.
		let openings = scope Dictionary<int64, Bounds>();
		void Grow(int64 key, int32 cell)
		{
			let p = CenterOf(cell);
			if (openings.TryGetValue(key, var area))
			{
				area.Encapsulate(p);
				openings[key] = area;
			}
			else
				openings[key] = .(p, p);
		}
		for (let narrow in mNarrows)
		{
			let a = Root(narrow.a), b = Root(narrow.b);
			if (a == b || !mRegions[a].kept || !mRegions[b].kept)
				continue;
			Grow((int64)Math.Min(a, b) << 32 | Math.Max(a, b), narrow.cell);
		}
		let count = mNx * mNy * mNz;
		for (int32 i < count)
		{
			let region = mRegion[i];
			// Only from rooms: under a roof with open sides, every edge is open.
			if (region < 0 || !mRegions[region].kept || mRegions[region].walled < mRegions[region].cells * 0.6f)
				continue;
			CellOf(i, let x, let y, let z);
			// Level neighbours only: the open sky above a courtyard is not a doorway.
			for (int k < 4)
			{
				let nx = x + (k == 0 ? -1 : (k == 1 ? 1 : 0)), nz = z + (k == 2 ? -1 : (k == 3 ? 1 : 0));
				if (nx < 0 || nz < 0 || nx >= mNx || nz >= mNz)
					continue;
				let n = Index(nx, y, nz);
				if (Used(n) && !Covered(n))
				{
					Grow((int64)region << 32 | 0xffffffffL, i);
					break;
				}
			}
		}
		for (let pair in openings)
		{
			var area = pair.value;
			area.min = area.min - Vector3(mCell * 0.5f);
			area.max = area.max + Vector3(mCell * 0.5f);
			let size = area.Size;
			// Narrower than a person or lower than one: a gap, not a way through.
			if (Math.Max(size.x, size.z) < Math.Min(0.6f, mCell) || size.y < 1.2f)
				continue;
			// Reaching into both sides.
			let reach = 1.0f;
			area.min = area.min - Vector3(reach, 0, reach);
			area.max = area.max + Vector3(reach, 0, reach);
			if (Settings.onlyWhereShiny && !AnyShiny(area, mCell))
			{
				Plan.skippedPlain++;
				continue;
			}
			ProbePlan.Reflection probe = default;
			probe.kind = .Doorway;
			probe.area = area;
			let center = area.Center;
			probe.eye = NearestUsed(.(center.x, area.min.y + Math.Min(1.4f, size.y * 0.5f), center.z), area, -1);
			probe.boxProjection = false;
			probe.importance = 2;
			probe.blendDistance = 0.5f;
			Add(probe);
		}
	}

	/// Open ground (used cells with nothing over them): a probe for each square of openProbeSize that has any and
	/// has something standing in it to mirror.
	void PlaceOpenGround()
	{
		let tile = Math.Max(Settings.openProbeSize, 4);
		let tiles = scope Dictionary<int64, Bounds>();
		let corner = mBounds.Center - Vector3(tile * 0.5f, 0, tile * 0.5f);
		let count = mNx * mNy * mNz;
		for (int32 i < count)
		{
			if (!Used(i) || Covered(i) || mDown[i] > 3)
				continue;
			// Squares centred on the scene, so that a small scene is one square.
			let p = CenterOf(i);
			let key = (int64)Math.Floor((p.x - corner.x) / tile) << 32 | (int64)(uint32)(int32)Math.Floor((p.z - corner.z) / tile);
			if (tiles.TryGetValue(key, var area))
			{
				area.Encapsulate(p);
				tiles[key] = area;
			}
			else
				tiles[key] = .(p, p);
		}
		for (let pair in tiles)
		{
			var area = pair.value;
			let size = area.Size;
			if (size.x < 4 && size.z < 4)
				continue;
			area.min = area.min - Vector3(mCell * 0.5f);
			area.max = area.max + Vector3(mCell * 0.5f);
			// From the ground up to well over head height.
			area.max.y = Math.Max(area.max.y, area.min.y + 6);
			area.max.y = Math.Min(area.max.y, area.min.y + 12);
			// Flat ground and sky alone are what the sky's cube shows already.
			if (!AnyStanding(area))
				continue;
			if (Settings.onlyWhereShiny && !AnyShiny(area, mCell))
			{
				Plan.skippedPlain++;
				continue;
			}
			ProbePlan.Reflection probe = default;
			probe.kind = .Open;
			probe.area = area;
			let center = area.Center;
			probe.eye = NearestUsed(.(center.x, area.min.y + 2, center.z), area, -1);
			probe.boxProjection = false;
			probe.importance = 0;
			probe.blendDistance = Math.Clamp(tile * 0.1f, 1, 5);
			Add(probe);
		}
	}

	/// Shiny floors out in the open (each patch of 4 m² or more, and smaller than a quarter of an open ground probe's
	/// square): a probe over each, seeing it from just above.
	void PlaceShinyFloors()
	{
		let count = mNx * mNy * mNz;
		let seen = scope bool[count];
		let stack = scope List<int32>();
		let columns = scope HashSet<int>();
		for (int32 start < count)
		{
			if (seen[start] || !OpenShinyFloor(start))
				continue;
			var area = Bounds(CenterOf(start), CenterOf(start));
			int cells = 0;
			columns.Clear();
			stack.Add(start);
			seen[start] = true;
			while (stack.Count > 0)
			{
				let i = stack.PopBack();
				cells++;
				area.Encapsulate(CenterOf(i));
				CellOf(i, let x, let y, let z);
				columns.Add(z * mNx + x);
				for (int dz = -1; dz <= 1; dz++)
				{
					for (int dy = -1; dy <= 1; dy++)
					{
						for (int dx = -1; dx <= 1; dx++)
						{
							let nx = x + dx, ny = y + dy, nz = z + dz;
							if (nx < 0 || ny < 0 || nz < 0 || nx >= mNx || ny >= mNy || nz >= mNz)
								continue;
							let n = (int32)Index(nx, ny, nz);
							if (!seen[n] && OpenShinyFloor(n))
							{
								seen[n] = true;
								stack.Add(n);
							}
						}
					}
				}
			}
			// Its area seen from above. Too small to matter, so big that it is the open ground (which has its own
			// probes), or not flat (the top of a shiny ball).
			let footprint = columns.Count * mCell * mCell;
			let tile = Math.Max(Settings.openProbeSize, 4) * 0.5f;
			if (footprint < 4 || footprint > tile * tile || columns.Count < cells * 0.6f)
				continue;
			area.min = area.min - Vector3(mCell * 0.5f + 0.5f, mCell * 0.5f, mCell * 0.5f + 0.5f);
			area.max = Vector3(area.max.x + mCell * 0.5f + 0.5f, area.max.y + 4, area.max.z + mCell * 0.5f + 0.5f);
			ProbePlan.Reflection probe = default;
			probe.kind = .ShinyFloor;
			probe.area = area;
			let center = area.Center;
			probe.eye = NearestUsed(.(center.x, area.min.y + 1.2f, center.z), area, -1);
			probe.boxProjection = false;
			probe.importance = 1;
			probe.blendDistance = 1;
			Add(probe);
		}
	}

	/// A cell with a shiny floor in it and open sky over the cell above.
	bool OpenShinyFloor(int i)
	{
		if ((mShiny[i] & 2) == 0)
			return false;
		CellOf(i, let x, let y, let z);
		if (y + 1 >= mNy)
			return false;
		let above = Index(x, y + 1, z);
		return Used(above) && !Covered(above) && mRegion[above] < 0;
	}

	// ---- light probe volumes ----

	void PlaceVolumes()
	{
		let half = mCell * 0.5f;
		let spacing = Math.Max(Settings.detailSpacing, 0.25f);
		// Each room or covered place.
		for (int32 r < (int32)mRegions.Count)
		{
			let region = mRegions[r];
			if (region.parent != r || !region.kept)
				continue;
			ProbePlan.Volume volume = default;
			volume.kind = region.walled >= region.cells * 0.6f ? .Room : .Shelter;
			volume.area = region.area;
			volume.spacing = spacing;
			volume.blendDistance = Math.Min(spacing, Math.Min(volume.area.Size.x, Math.Min(volume.area.Size.y, volume.area.Size.z)) * 0.25f);
			Add(volume);
		}
		// Where light changes quickly (per metre), outside those.
		let count = mNx * mNy * mNz;
		let changing = scope bool[count];
		for (int32 i < count)
		{
			if (!Used(i))
				continue;
			CellOf(i, let x, let y, let z);
			for (int k < 3)
			{
				let nx = x + (k == 0 ? 1 : 0), ny = y + (k == 1 ? 1 : 0), nz = z + (k == 2 ? 1 : 0);
				if (nx >= mNx || ny >= mNy || nz >= mNz)
					continue;
				let n = Index(nx, ny, nz);
				if (!Used(n))
					continue;
				let a = mLight[i], b = mLight[n];
				let change = Math.Abs(a - b) / (Math.Max(a, b) + mSkyLight * 0.05f) / mCell;
				if (change > Settings.lightChange)
				{
					changing[i] = true;
					changing[n] = true;
				}
			}
		}
		let roomCount = Plan.volumes.Count;
		for (int32 i < count)
		{
			if (!changing[i])
				continue;
			let p = CenterOf(i);
			for (int v < roomCount)
			{
				if (Inside(Plan.volumes[v].area, p))
				{
					changing[i] = false;
					break;
				}
			}
			for (let area in mOwnVolumes)
			{
				if (Inside(area, p))
					changing[i] = false;
			}
		}
		// Connected patches of change, as boxes; a patch that fills little of its box (a ring round a building) is
		// split until its pieces fill theirs.
		let seen = scope bool[count];
		let stack = scope List<int32>();
		let cells = scope List<int32>();
		let boxes = scope List<Bounds>();
		for (int32 start < count)
		{
			if (!changing[start] || seen[start])
				continue;
			cells.Clear();
			stack.Add(start);
			seen[start] = true;
			while (stack.Count > 0)
			{
				let i = stack.PopBack();
				cells.Add(i);
				CellOf(i, let x, let y, let z);
				for (int dz = -1; dz <= 1; dz++)
				{
					for (int dy = -1; dy <= 1; dy++)
					{
						for (int dx = -1; dx <= 1; dx++)
						{
							let nx = x + dx, ny = y + dy, nz = z + dz;
							if (nx < 0 || ny < 0 || nz < 0 || nx >= mNx || ny >= mNy || nz >= mNz)
								continue;
							let n = (int32)Index(nx, ny, nz);
							if (changing[n] && !seen[n])
							{
								seen[n] = true;
								stack.Add(n);
							}
						}
					}
				}
			}
			if (cells.Count * mCell * mCell * mCell < 1)
				continue;
			Split(cells, boxes, 0);
		}
		for (var area in boxes)
		{
			area.min = area.min - Vector3(half + spacing * 0.5f);
			area.max = area.max + Vector3(half + spacing * 0.5f);
			ProbePlan.Volume volume = default;
			volume.kind = .Detail;
			volume.area = area;
			volume.spacing = spacing;
			volume.blendDistance = Math.Min(spacing, Math.Min(area.Size.x, Math.Min(area.Size.y, area.Size.z)) * 0.25f);
			Add(volume);
		}
		// Within the budget: spread the probes of the biggest volumes further apart.
		for (int round < 40)
		{
			if (Plan.VolumeProbes <= Settings.maxVolumeProbes)
				break;
			int biggest = 0;
			for (int v < Plan.volumes.Count)
			{
				if (Plan.volumes[v].ProbeCount > Plan.volumes[biggest].ProbeCount)
					biggest = v;
			}
			for (var volume in ref Plan.volumes)
			{
				if (volume.ProbeCount * 2 >= Plan.volumes[biggest].ProbeCount)
					volume.spacing *= 1.25f;
			}
		}
	}

	/// Whether one of these boxes holds the middle of a planned one and half of it or more.
	static bool Covered(List<Bounds> own, Bounds planned)
	{
		let size = planned.Size;
		let volume = Math.Max(size.x * size.y * size.z, 1e-6f);
		for (let area in own)
		{
			if (!Inside(area, planned.Center))
				continue;
			let lo = Vector3(Math.Max(area.min.x, planned.min.x), Math.Max(area.min.y, planned.min.y), Math.Max(area.min.z, planned.min.z));
			let hi = Vector3(Math.Min(area.max.x, planned.max.x), Math.Min(area.max.y, planned.max.y), Math.Min(area.max.z, planned.max.z));
			let overlap = Math.Max(hi.x - lo.x, 0) * Math.Max(hi.y - lo.y, 0) * Math.Max(hi.z - lo.z, 0);
			if (overlap >= volume * 0.5f)
				return true;
		}
		return false;
	}

	/// Adds a reflection probe to the plan, unless one of the user's own covers its place.
	void Add(ProbePlan.Reflection probe)
	{
		if (Covered(mOwnReflections, probe.area))
			Plan.skippedOwn++;
		else
			Plan.reflections.Add(probe);
	}

	void Add(ProbePlan.Volume volume)
	{
		if (Covered(mOwnVolumes, volume.area))
			Plan.skippedOwn++;
		else
			Plan.volumes.Add(volume);
	}

	static bool Inside(Bounds area, Vector3 p) => p.x >= area.min.x && p.y >= area.min.y && p.z >= area.min.z && p.x <= area.max.x && p.y <= area.max.y && p.z <= area.max.z;

	/// Boxes round a patch of cells: one if they fill a good part of it (or it is small), else split in two across
	/// its longest side.
	void Split(List<int32> cells, List<Bounds> boxes, int depth)
	{
		var area = Bounds.Empty;
		for (let i in cells)
			area.Encapsulate(CenterOf(i));
		let size = area.Size + Vector3(mCell);
		let fill = cells.Count * mCell * mCell * mCell / (size.x * size.y * size.z);
		let longest = Math.Max(size.x, Math.Max(size.y, size.z));
		if (fill >= 0.3f || longest <= 6 || depth >= 8 || cells.Count < 8)
		{
			boxes.Add(area);
			return;
		}
		let axis = size.x == longest ? 0 : (size.y == longest ? 1 : 2);
		let middle = area.Center[axis];
		let lower = scope List<int32>(), upper = scope List<int32>();
		for (let i in cells)
			(CenterOf(i)[axis] < middle ? lower : upper).Add(i);
		if (lower.Count > 0)
			Split(lower, boxes, depth + 1);
		if (upper.Count > 0)
			Split(upper, boxes, depth + 1);
	}

	// ---- making them ----

	/// Takes away the probes placed before (objects tagged Tag) and makes the plan's: Reflection Probes and Light
	/// Probe Volumes under a "Placed Probes" object, each tagged. Sets the scene's Probe Spacing to the plan's.
	/// Returns how many it took away. The main thread.
	public static int Apply(Scene scene, ProbePlan plan)
	{
		let removed = Remove(scene);
		if (plan.reflections.Count == 0 && plan.volumes.Count == 0)
			return removed;
		// The object that held them before, if it is still there (holding probes the user kept).
		GameObject root = null;
		for (let held in scene.FindAllWithTag(Tag, .. scope .()))
		{
			if (held.Name == "Placed Probes")
				root = held;
		}
		if (root == null)
		{
			root = scene.CreateGameObject("Placed Probes");
			root.AddTag(Tag);
		}
		int32[6] numbers = default;
		for (let probe in plan.reflections)
		{
			let number = ++numbers[(int)probe.kind];
			let made = scene.CreateGameObject(scope $"Reflection Probe ({ProbePlan.KindName(probe.kind)} {number})" , root.Transform);
			made.AddTag(Tag);
			made.Transform.Position = probe.area.Center;
			let component = made.AddComponent<ReflectionProbe>();
			component.size = probe.area.Size;
			component.captureOffset = probe.eye - probe.area.Center;
			component.boxProjection = probe.boxProjection;
			component.importance = probe.importance;
			component.blendDistance = probe.blendDistance;
		}
		numbers = default;
		for (let volume in plan.volumes)
		{
			let number = ++numbers[(int)volume.kind];
			let made = scene.CreateGameObject(scope $"Light Probe Volume ({ProbePlan.KindName(volume.kind)} {number})" , root.Transform);
			made.AddTag(Tag);
			made.Transform.Position = volume.area.Center;
			let component = made.AddComponent<LightProbeVolume>();
			component.size = volume.area.Size;
			component.spacing = volume.spacing;
			component.blendDistance = volume.blendDistance;
		}
		if (plan.openSpacing > 0)
		{
			scene.Environment.bakeProbeSpacing = plan.openSpacing;
			scene.Environment.bakeProbes = true;
		}
		return removed;
	}

	/// Takes away the placed probes (objects tagged Tag), keeping anything else under them. Returns how many.
	public static int Remove(Scene scene)
	{
		let tagged = scene.FindAllWithTag(Tag, .. scope .());
		int removed = 0;
		// Probes first, then the objects that held them if nothing else is left under them.
		for (int i = tagged.Count - 1; i >= 0; i--)
		{
			let gameObject = tagged[i];
			if (gameObject.GetComponent<ReflectionProbe>() == null && gameObject.GetComponent<LightProbeVolume>() == null)
				continue;
			for (let child in scope List<Transform>(gameObject.Transform.Children))
				child.SetParent(gameObject.Transform.Parent, true);
			tagged.RemoveAt(i);
			scene.DestroyImmediate(gameObject);
			removed++;
		}
		for (let gameObject in tagged)
		{
			if (gameObject.Transform.Children.Count == 0)
				scene.DestroyImmediate(gameObject);
		}
		return removed;
	}

	// ---- threads ----

	void ParallelFor(int count, delegate void(int) body)
	{
		mNext = 0;
		mDone = 0;
		mWork = (int32)count;
#if BF_PLATFORM_WASM
		for (int index < count)
			body(index);
		mDone = (int32)count;
#else
		let threads = scope List<Thread>();
		for (int i < mThreadCount)
		{
			let thread = new Thread(new () =>
				{
					const int32 Chunk = 64;
					while (!Cancel)
					{
						let end = Interlocked.Add(ref mNext, Chunk);
						let first = end - Chunk;
						if (first >= count)
							break;
						for (int index = first; index < Math.Min(end, count); index++)
							body(index);
						Interlocked.Add(ref mDone, Math.Min(end, (int32)count) - first);
					}
				});
			thread.Start(false);
			threads.Add(thread);
		}
		for (let thread in threads)
		{
			thread.Join();
			delete thread;
		}
#endif
	}
}
