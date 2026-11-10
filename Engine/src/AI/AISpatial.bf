using System;
using System.Collections;

namespace Tallow;

/// Points sorted into square cells on the ground (x and z), rebuilt in one go: what the AI steps use to find what is
/// near something without looking at everything. Build it on the main thread; Query only reads, so any number of job
/// threads can query it at once.
class PointGrid
{
	float mCellSize = 4;
	/// Each cell's first place in mOrder and how many points it has.
	Dictionary<int64, (int32 start, int32 count)> mCells = new .() ~ delete _;
	/// The points' indices, cell by cell.
	List<int32> mOrder = new .() ~ delete _;
	List<int64> mKeys = new .() ~ delete _;
	List<int64> mUsed = new .() ~ delete _;
	int32 mCount;

	public int Count => mCount;
	public float CellSize => mCellSize;

	static int64 Key(int32 x, int32 z) => ((int64)x << 32) | (uint32)z;
	[Inline]
	int32 CellOf(float coordinate) => (int32)Math.Floor(coordinate / mCellSize);

	/// Sorts points into cells of cellSize metres. A point that is not finite is left out.
	public void Build(Span<Vector3> points, float cellSize)
	{
		mCellSize = Math.Max(cellSize, 0.01f);
		mCount = (int32)points.Length;
		mCells.Clear();
		mKeys.Clear();
		mUsed.Clear();
		mOrder.Clear();
		mOrder.Resize(points.Length);
		// Count each cell's points, give each cell its start, then put the indices in place.
		for (int i < points.Length)
		{
			let p = points[i];
			if (!p.x.IsFinite || !p.z.IsFinite)
			{
				mKeys.Add(int64.MinValue);
				continue;
			}
			let key = Key(CellOf(p.x), CellOf(p.z));
			mKeys.Add(key);
			if (mCells.TryAdd(key, ?, let cell))
			{
				*cell = (0, 0);
				mUsed.Add(key);
			}
			cell.count++;
		}
		int32 next = 0;
		for (let key in mUsed)
		{
			ref (int32 start, int32 count) cell = ref mCells[key];
			cell.start = next;
			next += cell.count;
			cell.count = 0;
		}
		mOrder.Count = next;
		for (int32 i < (int32)points.Length)
		{
			let key = mKeys[i];
			if (key == int64.MinValue)
				continue;
			ref (int32 start, int32 count) cell = ref mCells[key];
			mOrder[cell.start + cell.count] = i;
			cell.count++;
		}
	}

	/// Adds the indices of every point that may be within reach of center on the ground (all that are, and some that
	/// are not) to output. The order depends on the cells, so callers must not let it decide anything.
	public void Query(Vector3 center, float reach, List<int32> output)
	{
		if (!(reach >= 0) || !center.x.IsFinite || !center.z.IsFinite)
			return;
		let x0 = CellOf(center.x - reach), x1 = CellOf(center.x + reach);
		let z0 = CellOf(center.z - reach), z1 = CellOf(center.z + reach);
		// A reach wider than all the cells there are is quicker answered by listing everything.
		if ((int64)(x1 - x0 + 1) * (z1 - z0 + 1) > mCells.Count)
		{
			output.AddRange(mOrder);
			return;
		}
		for (int32 z = z0; z <= z1; z++)
		{
			for (int32 x = x0; x <= x1; x++)
			{
				if (!mCells.TryGetValue(Key(x, z), let cell))
					continue;
				for (int i < cell.count)
					output.Add(mOrder[cell.start + i]);
			}
		}
	}
}

/// What behaviour trees look for (Can See, Is Near, Move To Object), by pattern: `#Tag` or a name (a prefix when it
/// ends in '*'). The objects a pattern matches are gathered once per frame or fixed tick, and again only when objects
/// are added, removed or tagged; a pattern that many objects match is also sorted into a PointGrid, so a crowd
/// looking for each other does not compare every pair. Range, view cone, sight and whether an object is active are
/// still checked on each object as it is now (BTSenses.Find). Scene.AIPerception.
class AIPerception
{
	/// Above this many matches a pattern's objects are put in a grid.
	const int GridAbove = 48;
	/// How far an object may have moved since the grid was made in this frame or tick and still be found.
	const float Slack = 1;

	class Set
	{
		public List<GameObject> objects = new .() ~ delete _;
		public List<Vector3> positions = new .() ~ delete _;
		public PointGrid grid ~ delete _;
		public bool gridBuilt;
		public int64 update = -1;
		public int32 tick = -1;
		public int32 revision = -1;
	}

	Scene mScene;
	Dictionary<String, Set> mSets = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	List<int32> mFound = new .() ~ delete _;
	static ProfilerMarker sGatherMarker = .("Behaviour.Perception.Gather", .AI);

	public this(Scene scene)
	{
		mScene = scene;
	}

	/// The objects the pattern matches, in scene order (tagged objects in the order they were tagged), active or not.
	/// Valid until the end of this frame or tick, or until an object is added, removed or tagged.
	public List<GameObject> Matching(StringView pattern) => SetOf(pattern).objects;

	/// Adds the objects pattern matches that may be within range of center (on the ground) to output: every one that
	/// is, perhaps some that are not, in no set order.
	public void Near(StringView pattern, Vector3 center, float range, List<GameObject> output)
	{
		let set = SetOf(pattern);
		if (set.objects.Count <= GridAbove)
		{
			output.AddRange(set.objects);
			return;
		}
		if (!set.gridBuilt)
		{
			set.gridBuilt = true;
			if (set.grid == null)
				set.grid = new .();
			set.positions.Clear();
			for (let object in set.objects)
				set.positions.Add(object.Transform.Position);
			// Cells about the size of a typical look round, so a query reads a few of them.
			set.grid.Build(set.positions, 8);
		}
		mFound.Clear();
		set.grid.Query(center, range + Slack, mFound);
		for (let index in mFound)
			output.Add(set.objects[index]);
	}

	Set SetOf(StringView pattern)
	{
		Set set;
		if (!mSets.TryGetValueAlt(pattern, out set))
		{
			set = new .();
			mSets[new String(pattern)] = set;
		}
		let revision = mScene.[Friend]mObjectsRevision;
		if (set.update == mScene.UpdateCount && set.tick == Time.Tick && set.revision == revision)
			return set;
		using (sGatherMarker.Sample())
		{
			set.update = mScene.UpdateCount;
			set.tick = Time.Tick;
			set.revision = revision;
			set.gridBuilt = false;
			set.objects.Clear();
			if (pattern.StartsWith('#'))
			{
				if (let tagged = mScene.[Friend]TaggedList(pattern.Substring(1)))
				{
					for (let object in tagged)
					{
						if (!object.IsDestroyed)
							set.objects.Add(object);
					}
				}
			}
			else
			{
				for (let object in mScene.Objects)
				{
					if (BTSenses.NameMatches(object.Name, pattern))
						set.objects.Add(object);
				}
			}
		}
		return set;
	}
}
