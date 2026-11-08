using System;
using System.Collections;

namespace Tallow;

/// Shared broadphase for behavior-tree target searches and navigation obstacles.
/// Rebuilt once for the scene's current update/tick, rather than scanned once
/// per AI agent. The exact range, tags, visibility and obstacle semantics are
/// still checked by the caller. Not a gameplay-visible component or new API.
class AISpatialIndex
{
	/// A moderately large cell keeps inserts cheap for scenes with thousands
	/// of objects and still bounds the nearby candidate set for perception.
	const float CellSize = 8;

	Scene mScene;
	Dictionary<int64, List<GameObject>> mObjects = new .() ~ DeleteDictionaryAndValues!(_);
	Dictionary<int64, List<NavigationObstacle>> mObstacles = new .() ~ DeleteDictionaryAndValues!(_);
	List<int64> mEmpty = new .() ~ delete _;
	int64 mUpdate = -1;
	int32 mTick = -1;
	int mCount = -1;

	/// Largest active, uncarved obstacle's radius in this snapshot. Caller
	/// adds this to its query reach so the edge of a large obstacle is included.
	public float MaxObstacleRadius { get; private set; }

	public this(Scene scene)
	{
		mScene = scene;
	}

	static int64 Key(int32 x, int32 z) => ((int64)x << 32) | (uint32)z;
	static int32 Cell(float value) => (int32)Math.Floor(value / CellSize);

	static void Insert<T>(Dictionary<int64, List<T>> cells, Vector3 position, T value) where T : class
	{
		if (!position.x.IsFinite || !position.z.IsFinite)
			return;
		let key = Key(Cell(position.x), Cell(position.z));
		List<T> entries;
		if (!cells.TryGetValue(key, out entries))
		{
			entries = new .();
			cells[key] = entries;
		}
		entries.Add(value);
	}

	/// Reuse live buckets, but discard empty cells when streamed objects move
	/// into other parts of the world so the index cannot grow indefinitely.
	void Prune<T>(Dictionary<int64, List<T>> cells) where T : class
	{
		mEmpty.Clear();
		for (let (key, entries) in cells)
		{
			if (entries.IsEmpty)
				mEmpty.Add(key);
		}
		for (let key in mEmpty)
		{
			if (cells.GetAndRemove(key) case .Ok(let removed))
				delete removed.value;
		}
	}

	void Refresh()
	{
		if (mUpdate == mScene.UpdateCount && mTick == Time.Tick && mCount == mScene.Objects.Count)
			return;

		mUpdate = mScene.UpdateCount;
		mTick = Time.Tick;
		mCount = mScene.Objects.Count;
		for (let entries in mObjects.Values)
			entries.Clear();
		for (let entries in mObstacles.Values)
			entries.Clear();
		MaxObstacleRadius = 0;

		// Insert even disabled objects; their active state is checked at use,
		// so enabling one in the same frame cannot cause a false negative.
		for (let gameObject in mScene.Objects)
		{
			if (!gameObject.IsDestroyed)
				Insert(mObjects, gameObject.Transform.Position, gameObject);
		}

		// Navigational obstacles are class components, unlike the Flecs-backed
		// NavigationAgent. Enumerating the per-type registry once per frame is
		// much cheaper than scanning it once for each steering agent.
		for (let component in mScene.ComponentsOfType(typeof(NavigationObstacle)))
		{
			let obstacle = (NavigationObstacle)component;
			if (!obstacle.IsActiveAndEnabled || obstacle.Carving)
				continue;
			let center = obstacle.Transform.Position + obstacle.Transform.Rotation * obstacle.center;
			Insert(mObstacles, center, obstacle);
			MaxObstacleRadius = Math.Max(MaxObstacleRadius, obstacle.Radius);
		}

		Prune(mObjects);
		Prune(mObstacles);
	}

	static void Gather<T>(Dictionary<int64, List<T>> cells, Vector3 center, float reach, List<T> output) where T : class
	{
		output.Clear();
		if (reach < 0 || !center.x.IsFinite || !center.z.IsFinite)
			return;

		// Huge searches are uncommon but need to avoid loop overflow and
		// checking millions of empty spatial cells.
		if (!reach.IsFinite || reach > 8192)
		{
			for (let entries in cells.Values)
				output.AddRange(entries);
			return;
		}

		let x0 = Cell(center.x - reach), x1 = Cell(center.x + reach);
		let z0 = Cell(center.z - reach), z1 = Cell(center.z + reach);
		let cellsNeeded = (int64)(x1 - x0 + 1) * (z1 - z0 + 1);
		if (cellsNeeded > cells.Count)
		{
			// More empty cells than occupied ones: walk buckets directly.
			for (let (key, entries) in cells)
			{
				let x = (int32)(key >> 32);
				let z = (int32)key;
				if (x >= x0 && x <= x1 && z >= z0 && z <= z1)
					output.AddRange(entries);
			}
			return;
		}
		for (int32 z = z0; z <= z1; z++)
		{
			for (int32 x = x0; x <= x1; x++)
			{
				if (cells.TryGetValue(Key(x, z), let entries))
					output.AddRange(entries);
			}
		}
	}

	/// Nearby *candidates* for a behavior-tree name/tag/range/sight test.
	/// Rechecks of exact distance and visibility are still required.
	public void QueryObjects(Vector3 center, float reach, List<GameObject> output)
	{
		Refresh();
		Gather(mObjects, center, reach, output);
	}

	/// Nearby *candidates* for navigation avoidance. Carved or disabled
	/// obstacles must still be rechecked at use.
	public void QueryObstacles(Vector3 center, float reach, List<NavigationObstacle> output)
	{
		Refresh();
		Gather(mObstacles, center, reach + MaxObstacleRadius, output);
	}
}
