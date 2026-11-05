using System;
using System.Collections;
using System.IO;
using System.Threading;

namespace Tallow;

/// What a sculpting brush does.
[Reflect(.All)]
enum VoxelBrush : int32
{
	Raise,
	Lower,
	Smooth,
	Flatten,
	Paint
}

/// How a terrain decides where it has ground.
[Reflect(.All)]
enum TerrainMode : int32
{
	/// Square tiles placed by hand, flat until sculpted (or shaped by the terrain's generator).
	Fixed,
	/// Generated around the camera without end, by the terrain's generator.
	Endless
}

/// How a terrain's surface is made from its samples.
[Reflect(.All)]
enum VoxelStyle : int32
{
	/// Marching cubes: smooth slopes, faceted by flat shading.
	Smooth,
	/// One cube per solid cell with hidden faces removed.
	Blocky,
	/// Dual contouring: one point in each cell the surface passes through, joined into a regular grid of quads.
	/// Rounder and more even than Smooth (no slivers or stair-steps along gentle slopes), and able to keep hard
	/// edges and corners where Contour Sharpness asks for them.
	Contoured
}

/// One square tile of a terrain's grid.
struct TerrainTile
{
	/// Stays the same for the tile's whole life, wherever it is moved: its sculpting is filed under it.
	public int32 id;
	/// Its place in the grid, counted in tiles from the terrain object's position.
	public int32 x;
	/// The tile's place along Z, in tiles.
	public int32 z;

	/// A tile with an id at a place.
	public this(int32 id, int32 x, int32 z)
	{
		this.id = id;
		this.x = x;
		this.z = z;
	}
}

/// Voxel terrain made of square tiles on one grid, like Unity's terrain, with caves and overhangs. Tiles are placed
/// in the editor (the Tiles tool), sculpted and painted across their edges as one surface, and saved one file per
/// tile. Chunks are generated and meshed on worker threads; the main thread only uploads finished meshes.
/// Call Brush or ModifySphere to dig or build at runtime.
[Component]
class VoxelTerrain : Component
{
	/// Cells along each side of a chunk.
	public const int32 ChunkCells = 32;
	/// Samples along each side of a chunk (one more than its cells).
	public const int32 Samples = ChunkCells + 1;
	const int32 SampleCount = Samples * Samples * Samples;
	const int32 FaceCount = Samples * Samples;
	/// What a sample holds where there is no ground at all: outside the tiles.
	const int8 Air = -127;

	/// Fixed: tiles placed by hand. Endless: generated around the camera for ever.
	public TerrainMode mode = .Fixed;
	/// How many chunks a tile has along each side; every tile of the grid is the same size. The default 8 at voxel
	/// size 0.5 makes tiles 128 m square. Choose it before sculpting: sculpting is kept per tile.
	[Range(1, 16)]
	public int32 tileSize = 8;
	/// How high flat ground starts, above the object's position.
	public float flatHeight = 0.0f;
	/// Fixed mode: load only the tiles near the camera (and near each player, on a server), within View Distance.
	/// Off: every tile is there all the time.
	public bool streamTiles = false;
	/// The class that shapes ground nobody has sculpted, one marked [TerrainGenerator]. Empty: flat ground in Fixed
	/// mode, the sample noise (seed, terrain height, scale, caves) in Endless mode. Set from the game's code.
	[HideInInspector]
	public String generator = new .() ~ delete _;
	/// Smooth (marching cubes), Contoured (keeps ridges and ledges) or Blocky (cubes).
	public VoxelStyle style = .Contoured;
	/// Contoured style only. 0 puts each point in the middle of where the surface crosses its cell, which gives the
	/// softest ground. 1 puts it where the slopes around it meet, which keeps ridges, ledges and the corners of
	/// flattened areas crisp. In between is a blend.
	[Range(0, 1)]
	public float contourSharpness = 0.35f;
	/// Off: the ground is shaded smoothly, as rolling terrain. On: every triangle is shaded flat, for a faceted,
	/// low-poly look. Blocky ground is always flat.
	public bool flatShading = false;
	/// The size of one cell of the ground, in metres. Half a metre makes ground fine enough to pass for ordinary
	/// terrain; 1 is coarser, a quarter of the memory per metre and quicker to sculpt across large areas.
	public float voxelSize = 0.5f;
	/// Streaming radius in chunks: Endless mode, and Fixed mode with Stream Tiles.
	public int32 viewDistance = 6;
	/// The lowest layer of chunks, counting up from the object (each ChunkCells cells high).
	public int32 minChunkY = -1;
	/// The highest layer of chunks.
	public int32 maxChunkY = 2;
	/// Chunks further than this many chunks from the camera are drawn with fewer triangles: half the detail beyond
	/// it, a quarter beyond twice as far, an eighth beyond four times. 0 draws everything in full. Collision always
	/// has the full detail. Smooth and Contoured styles.
	[Range(0, 32)]
	public int32 lodDistance = 4;
	// What the sample noise generator makes of the ground. Generating ground is a game's own business, done from its
	// code (a [TerrainGenerator] class, SetGenerator, Endless mode), so these are saved but not shown in the editor,
	// where a terrain is simply its tiles.
	/// The sample noise's seed: another number makes other ground.
	[HideInInspector]
	public int32 seed = 1337;
	/// Also where the automatic colours put rock and snow: they come in towards this height.
	public float terrainHeight = 28.0f;
	/// How wide the sample noise's hills are: smaller is wider.
	[HideInInspector]
	public float terrainScale = 0.012f;
	/// How much of the sample noise's ground is caves.
	[HideInInspector]
	public float caveAmount = 0.35f;
	/// Below this height the automatic colours put sand.
	public float seaLevel = 0.0f;
	/// The automatic colour of flat ground.
	public Color grassColor = .FromBytes(104, 159, 74);
	/// The automatic colour of slopes and high ground.
	public Color rockColor = .FromBytes(128, 122, 116);
	/// The automatic colour near sea level.
	public Color sandColor = .FromBytes(214, 196, 142);
	/// The automatic colour of the highest ground.
	public Color snowColor = .FromBytes(236, 240, 245);
	/// The colour of ground just dug.
	public Color dirtColor = .FromBytes(124, 92, 62);
	/// Gives the ground collision, so that things can stand on it.
	public bool generateColliders = true;
	/// Finished chunks uploaded to the GPU per frame.
	public int32 uploadsPerFrame = 4;
	/// The tiles, "id x z" each, separated by ';'. Changed with the Tiles tool, or AddTile, RemoveTile and MoveTile.
	[HideInInspector]
	public String tiles = new .() ~ delete _;
	/// The id the next tile added gets.
	[HideInInspector]
	public int32 nextTileId = 1;
	/// From before tiles: a rectangle of sizeX by sizeZ chunks. It is the terrain's shape while `tiles` is empty, so
	/// older scenes, and code that sets these, keep working; the first tile edit or scene save writes the tiles out.
	[HideInInspector]
	public int32 sizeX = 8;
	/// From before tiles: the rectangle's chunks along Z.
	[HideInInspector]
	public int32 sizeZ = 8;
	/// Where sculpting is kept: a folder (relative to the project) with a file for each tile. Set when the scene is saved.
	[HideInInspector]
	public String editsFolder = new .() ~ delete _;
	/// From before tiles, when all the sculpting was in one file. It is read, and moved into editsFolder on the next save.
	[HideInInspector]
	public String editsFile = new .() ~ delete _;

	enum ChunkState { Queued, Working, Ready, Uploaded }

	class Chunk
	{
		public Int3 coord;
		/// The tile it is part of (-1 in Endless mode) and its place in that tile: how its sculpting is filed.
		public int32 tileId;
		public Int3 local;
		public int8[] density ~ delete _;
		/// Painted layer per sample (0 = automatic color), allocated on first paint.
		public uint8[] paint ~ delete _;
		public bool edited;
		public bool generated;
		/// How many of the session's shared brush strokes this chunk has had applied (see mSessionBrushes).
		public int32 appliedBrushes;
		public ChunkState state;
		public bool dirty;
		public bool cancelled;
		/// Its samples were being made when its sculpting changed: made again once that is done.
		public bool stale;
		/// The level of detail wanted (0 full, 1 half, 2 quarter, 3 eighth) and the one the mesh has.
		public int32 lod;
		public int32 builtLod = -1;
		/// The ground changed since the collision mesh was made.
		public bool shapeChanged = true;
		/// Set by the worker: whether this build made collision, and whether that is a mesh of its own.
		public bool builtCollision;
		public bool separateCollision;
		public List<MeshVertex> vertices = new .() ~ delete _;
		public List<uint32> indices = new .() ~ delete _;
		public List<MeshVertex> collisionVertices = new .() ~ delete _;
		public List<uint32> collisionIndices = new .() ~ delete _;
		public Mesh mesh ~ delete _;
		public Mesh collisionMesh ~ delete _;
		public GameObject gameObject;
	}

	class SavedChunk
	{
		public int8[] density ~ delete _;
		public uint8[] paint ~ delete _;
		public int32 appliedBrushes;
	}

	/// What the worker threads read, made on the main thread and never changed afterwards: a new one replaces it.
	class Snapshot
	{
		public TerrainMode mode;
		public int32 tileSize = 4;
		public float voxelSize = 1;
		public float flatHeight;
		public TerrainGenerator generator;
		public Dictionary<int64, int32> tiles = new .() ~ delete _;

		public int32 TileAt(int32 tx, int32 tz) => tiles.TryGetValue(TileKey(tx, tz), let id) ? id : 0;
		public float TileWorld => tileSize * ChunkCells * voxelSize;

		bool Occupied(float x, float z)
		{
			let w = TileWorld;
			return tiles.ContainsKey(TileKey((int32)Math.Floor(x / w), (int32)Math.Floor(z / w)));
		}

		/// True where there may be ground: inside the tiles, ending half a voxel before an edge with no tile beyond.
		public bool Inside(float x, float z)
		{
			if (mode == .Endless)
				return true;
			let inset = voxelSize * 0.5f;
			return Occupied(x - inset, z - inset) && Occupied(x + inset, z - inset) && Occupied(x - inset, z + inset) && Occupied(x + inset, z + inset);
		}

		/// The ground before sculpting, as samples hold it (the edge of the tiles is applied when meshing).
		public float Density(float x, float y, float z) => generator != null ? generator.Density(x, y, z) : flatHeight - y;

		/// Where a chunk's sculpting is filed. False for a chunk outside every tile.
		public bool Locate(Int3 coord, out int32 tileId, out Int3 local)
		{
			if (mode == .Endless)
			{
				tileId = -1;
				local = coord;
				return true;
			}
			let tx = FloorDiv(coord.x, tileSize), tz = FloorDiv(coord.z, tileSize);
			tileId = TileAt(tx, tz);
			local = .(coord.x - tx * tileSize, coord.y, coord.z - tz * tileSize);
			return tileId != 0;
		}
	}

	/// One brush stroke, in the terrain's own space.
	struct BrushStroke
	{
		public Vector3 center;
		public float radius;
		public float strength;
		public VoxelBrush mode;
		public int32 paintLayer;
		public float flattenLocal;
	}

	/// Chunks as they were before and after some sculpting, for undo (BeginEditRecord, EndEditRecord).
	public class EditRecord
	{
		public class State
		{
			/// Null: not sculpted, so generated again.
			public int8[] density ~ delete _;
			public uint8[] paint ~ delete _;
		}
		public Dictionary<Int3, State> before = new .() ~ DeleteDictionaryAndValues!(_);
		public Dictionary<Int3, State> after = new .() ~ DeleteDictionaryAndValues!(_);
		public int32 Count => (int32)before.Count;
	}

	/// Every brush stroke of the current network session, in the order the server passed them on. Chunks stream in
	/// at different times on different machines, so a chunk that was not loaded when a stroke happened has the
	/// strokes it missed applied when it arrives; every machine ends up with the same terrain.
	List<BrushStroke> mSessionBrushes = new .() ~ delete _;

	/// Sculpting by tile id (-1: Endless mode, by chunk), then by chunk within the tile. Holds what is read from the
	/// files and chunks that are not loaded; loaded chunks hold their own. Tiles that are removed keep theirs here
	/// until the scene is saved, so undoing the removal brings the sculpting back.
	Dictionary<int32, Dictionary<Int3, SavedChunk>> mStore = new .() ~ { for (let entry in _) DeleteDictionaryAndValues!(entry.value); delete _; };
	String mLoadedEdits = new .() ~ delete _;
	String mLoadedFolder = new .() ~ delete _;
	/// True when sculpting, painting or tile changes have not been written to the files yet.
	[NonSerialized]
	public bool HasUnsavedEdits;

	List<TerrainTile> mTiles = new .() ~ delete _;
	String mAppliedTiles = new .() ~ delete _;
	int32 mAppliedSizeX, mAppliedSizeZ, mAppliedTileSize;
	Snapshot mSnap ~ delete _;
	/// Snapshots and generators replaced while a worker may still be reading them; freed when no worker is busy.
	List<Object> mRetired = new .() ~ DeleteContainerAndItems!(_);
	TerrainGenerator mNamedGenerator ~ delete _;
	String mNamedGeneratorName = new .() ~ delete _;
	TerrainGenerator mCodeGenerator ~ delete _;
	NoiseTerrainGenerator mSampleGenerator ~ delete _;
	int32 mGeneratorVersion;
	EditRecord mRecording;

	Dictionary<Int3, Chunk> mChunks = new .() ~ delete _;
	List<Chunk> mJobs = new .() ~ delete _;
	List<Chunk> mFinished = new .() ~ delete _;
	List<Chunk> mGraveyard = new .() ~ delete _;
	List<Thread> mThreads = new .() ~ delete _;
	/// Web builds have no worker threads: chunks are built on the main thread, a few milliseconds' worth a frame.
	bool mInline;
	MeshWork mInlineWork ~ delete _;
	/// True once the terrain is registered and building chunks, on workers or inline.
	bool Streaming => mThreads.Count > 0 || mInline;
	Monitor mMonitor = new .() ~ delete _;
	WaitEvent mWake = new .() ~ delete _;
	bool mQuit;
	int32 mBusy;
	// Copies of the settings read by worker threads.
	VoxelStyle mStyle;
	float mSharpness;
	/// Frames to wait, once nothing is being built, before plants are put back on ground that undo or redo moved.
	int32 mFoliageStale;
	bool mFlat;
	float mVoxelSize = 1, mTerrainHeight, mSeaLevel;
	bool mLodOn, mColliders;
	Color mGrass, mRock, mSand, mSnow, mDirt;
	int32 mSettingsHash;
	/// What the chunks wanted depended on when they were last worked out (MakeStreamKey), and frames until they are
	/// worked out again anyway.
	List<int32> mStreamKey = new .() ~ delete _;
	int32 mStreamRecheck;

	/// World position chunks are streamed around. The application sets this from the active camera.
	public static Vector3 ViewerPosition;
	/// More places to stream and give detail around, as well as ViewerPosition: a server fills it with its players.
	public static List<Vector3> Viewers = new .() ~ delete _;

	/// How many chunks are loaded.
	public int32 ChunkCount => (int32)mChunks.Count;
	/// How many chunks are waiting to be made or uploaded.
	public int32 PendingChunks
	{
		get
		{
			using (mMonitor.Enter())
				return (int32)(mJobs.Count + mFinished.Count) + mBusy;
		}
	}

	[Inline]
	static int32 FloorDiv(int32 a, int32 b) => a >= 0 ? a / b : -((-a + b - 1) / b);
	[Inline]
	static int64 TileKey(int32 x, int32 z) => ((int64)x << 32) | (int64)(uint32)z;
	[Inline]
	static int SampleIndex(int x, int y, int z) => x + y * Samples + z * Samples * Samples;
	static T[] Copy<T>(T[] source)
	{
		let copy = new T[source.Count];
		source.CopyTo(copy);
		return copy;
	}

	[Inline]
	static int8 Quantize(float density, float size) => (int8)Mathf.Clamp(density / size * 24.0f, -127, 127);

	public override void OnRegister()
	{
		ApplyTilesText();
		CaptureSettings();
#if BF_PLATFORM_WASM
		mInline = true;
		if (mInlineWork == null)
			mInlineWork = new MeshWork();
		return;
#else
		let workers = Math.Max(1, Math.Min(6, (int)Platform.BfpSystem_GetNumLogicalCPUs(null) - 2));
		for (int i < workers)
		{
			let thread = new Thread(new => WorkerMain);
			thread.SetName("VoxelWorker");
			thread.Start(false);
			mThreads.Add(thread);
		}
#endif
	}

	public override void OnUnregister()
	{
		using (mMonitor.Enter())
		{
			mQuit = true;
			mJobs.Clear();
		}
		for (let thread in mThreads)
			mWake.Set(true);
		for (let thread in mThreads)
		{
			thread.Join();
			delete thread;
		}
		mThreads.Clear();
		mInline = false;
		mQuit = false;
		// Chunk objects are children; when the terrain object itself is being destroyed they are already gone.
		for (let child in Transform.Children)
		{
			if (!child.GameObject.Transient)
				continue;
			let renderer = child.GameObject.GetComponent<MeshRenderer>();
			if (renderer)
				renderer.RuntimeMesh = null;
			let collider = child.GameObject.GetComponent<MeshCollider>();
			if (collider != null)
				collider.CollisionMesh = null;
			Scene.Destroy(child.GameObject);
		}
		for (let chunk in mChunks.Values)
		{
			Stash(chunk);
			delete chunk;
		}
		mChunks.Clear();
		for (let chunk in mGraveyard)
			delete chunk;
		mGraveyard.Clear();
		mFinished.Clear();
		ClearAndDeleteItems!(mRetired);
	}

	void CaptureSettings()
	{
		if (mNamedGeneratorName != generator)
		{
			if (mNamedGenerator != null)
				mRetired.Add(mNamedGenerator);
			mNamedGenerator = TerrainGenerator.Create(generator);
			mNamedGeneratorName.Set(generator);
			if (mNamedGenerator == null && !generator.IsEmpty)
				Log.Warning(scope $"Terrain generator '{generator}' was not found: is the class marked [TerrainGenerator]?");
		}
		TerrainGenerator active = mCodeGenerator ?? mNamedGenerator;
		if (active == null && mode == .Endless)
		{
			if (mSampleGenerator == null)
				mSampleGenerator = new .();
			active = mSampleGenerator;
		}
		active?.Begin(this);

		let snap = new Snapshot();
		snap.mode = mode;
		snap.tileSize = Math.Clamp(tileSize, 1, 64);
		snap.voxelSize = Math.Max(voxelSize, 0.05f);
		snap.flatHeight = flatHeight;
		snap.generator = active;
		for (let tile in mTiles)
			snap.tiles[TileKey(tile.x, tile.z)] = tile.id;
		using (mMonitor.Enter())
		{
			if (mSnap != null)
				mRetired.Add(mSnap);
			mSnap = snap;
		}

		mStyle = style;
		mSharpness = Mathf.Clamp01(contourSharpness);
		let flat = flatShading || style == .Blocky;
		if (flat != mFlat)
		{
			// Shading is the renderer's business, not the mesh's: chunks already built just change over.
			mFlat = flat;
			for (let chunk in mChunks.Values)
			{
				MeshRenderer drawn = chunk.gameObject != null ? chunk.gameObject.GetComponent<MeshRenderer>() : default;
				if (drawn)
					drawn.flatShading = flat;
			}
		}
		mVoxelSize = snap.voxelSize;
		mTerrainHeight = terrainHeight;
		mSeaLevel = seaLevel;
		mColliders = generateColliders;
		mLodOn = lodDistance > 0 && style != .Blocky;
		mGrass = grassColor;
		mRock = rockColor;
		mSand = sandColor;
		mSnow = snowColor;
		mDirt = dirtColor;
		mSettingsHash = (int32)style ^ (int32)(contourSharpness * 1000) * 31 ^ (int32)(voxelSize * 1000) ^ (int32)(terrainHeight * 100) * 7 ^ (int32)(seaLevel * 100) * 19
			^ (int32)grassColor.ToABGR() ^ (int32)rockColor.ToABGR() * 3 ^ (int32)sandColor.ToABGR() * 5
			^ (int32)snowColor.ToABGR() * 7 ^ (int32)dirtColor.ToABGR() * 11 ^ (int32)mode * 104729 ^ snap.tileSize * 7919
			^ (int32)(flatHeight * 100) * 23 ^ mGeneratorVersion * 4001 ^ (int32)generator.GetHashCode() * 13
			^ (generateColliders ? 1 << 20 : 0);
		// The sample generator's settings matter only when it is the one in use.
		if (active == mSampleGenerator && active != null)
			mSettingsHash ^= seed * 31 ^ (int32)(terrainScale * 100000) * 13 ^ (int32)(caveAmount * 1000) * 17 ^ (int32)(terrainHeight * 10) * 29;
	}

	/// A selected terrain shows its tiles.
	public override void OnDrawGizmos(bool selected)
	{
		if (mode != .Fixed || !selected)
			return;
		if (mSnap == null)
			ApplyTilesText();
		let w = TileWorldSize;
		let cell = ChunkCells * Math.Max(voxelSize, 0.05f);
		for (let tile in mTiles)
			Gizmos.Lines.Box(Bounds(.(tile.x * w, minChunkY * cell, tile.z * w), .((tile.x + 1) * w, (maxChunkY + 1) * cell, (tile.z + 1) * w)), Transform.LocalToWorld, .(0.45f, 0.80f, 0.45f, 0.8f));
	}

	/// Inspector edits rebuild what they change.
	public override void OnValidate()
	{
		let wasLod = mLodOn;
		if (mAppliedTiles != tiles || (tiles.IsEmpty && (mAppliedSizeX != sizeX || mAppliedSizeZ != sizeZ || mAppliedTileSize != tileSize)))
			ApplyTilesText();
		let previous = mSettingsHash;
		CaptureSettings();
		bool regenerate = previous != mSettingsHash;
		if (!editsFile.IsEmpty && mLoadedEdits != editsFile)
		{
			mLoadedEdits.Set(editsFile);
			let path = scope String();
			Assets.ResolvePath(editsFile, path);
			regenerate |= LoadEdits(path);
		}
		if (!editsFolder.IsEmpty && mLoadedFolder != editsFolder)
		{
			mLoadedFolder.Set(editsFolder);
			regenerate |= LoadEditFolder();
		}
		if (regenerate && Streaming)
			Regenerate();
		else if (wasLod != mLodOn)
		{
			// Collision has its own mesh only with level of detail on.
			for (let chunk in mChunks.Values)
			{
				if (!mLodOn)
					chunk.lod = 0;
				chunk.shapeChanged = true;
				QueueRemesh(chunk);
			}
		}
	}
}
