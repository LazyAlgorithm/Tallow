using System;
using System.Collections;

namespace Tallow;

/// Where a scene's Navigation Agents stand, in square cells on the ground, so an agent steering round others
/// (NavigationAgent.Avoid) looks only at the ones near it rather than at every agent. Agents join and leave as they
/// register. Their places are read again once per scene update (and fixed tick), and only for agents whose transform
/// or base offset changed since: an agent that moves during the frame is found by its old place until then, which the
/// metre of slack in the avoidance's reach covers.
class NavigationCrowdIndex
{
	/// The width of a cell, in metres.
	const float CellSize = 4;

	struct Entry
	{
		public NavigationAgent agent;
		public uint32 version;
		public Vector3 offset;
		/// The cell it is listed in (Key), and its place in that cell's list; hasCell is false when its position is
		/// not finite.
		public int64 cell;
		public int32 slot;
		public bool hasCell;
	}

	Scene mScene;
	List<Entry> mEntries = new .() ~ delete _;
	Dictionary<NavigationAgent, int32> mIndex = new .() ~ delete _;
	List<int32> mFree = new .() ~ delete _;
	Dictionary<int64, List<int32>> mCells = new .() ~ DeleteDictionaryAndValues!(_);
	List<NavigationAgent> mResult = new .() ~ delete _;
	float mLargestRadius;
	int64 mRefreshedUpdate = -1;
	int32 mRefreshedTick = -1;

	/// The index of a scene's agents (Scene.NavigationCrowd).
	public this(Scene scene)
	{
		mScene = scene;
	}

	static int64 Key(int32 x, int32 z) => ((int64)x << 32) | (uint32)z;
	static int32 CellOf(float coordinate) => (int32)Math.Floor(coordinate / CellSize);

	public void Register(NavigationAgent agent)
	{
		if (mIndex.ContainsKey(agent)) return;
		int32 id;
		if (mFree.IsEmpty)
		{
			id = (int32)mEntries.Count;
			mEntries.Add(default);
		}
		else
			id = mFree.PopBack();
		ref Entry entry = ref mEntries[id];
		entry = default;
		entry.agent = agent;
		mIndex[agent] = id;
		Place(id);
		// So a query made before the next update finds it too.
		mLargestRadius = Math.Max(mLargestRadius, agent.radius);
	}

	public void Unregister(NavigationAgent agent)
	{
		if (!mIndex.TryGetValue(agent, let id)) return;
		Unlist(id);
		mEntries[id].agent = null;
		mIndex.Remove(agent);
		mFree.Add(id);
	}

	/// The agents that may be within distance of a point on the ground (with their radius): every one that is, and
	/// perhaps a few that are not. The list is reused by the next query.
	public List<NavigationAgent> Query(Vector3 center, float distance)
	{
		Refresh();
		mResult.Clear();
		let reach = distance + mLargestRadius;
		if (!(reach >= 0) || !center.x.IsFinite || !center.z.IsFinite)
			return mResult;
		let x0 = CellOf(center.x - reach), x1 = CellOf(center.x + reach);
		let z0 = CellOf(center.z - reach), z1 = CellOf(center.z + reach);
		// A reach wider than the crowd itself is quicker answered by listing everyone.
		if ((int64)(x1 - x0 + 1) * (z1 - z0 + 1) > mCells.Count)
		{
			for (let (key, ids) in mCells)
			{
				for (let id in ids)
					mResult.Add(mEntries[id].agent);
			}
			return mResult;
		}
		for (int32 z = z0; z <= z1; z++)
		{
			for (int32 x = x0; x <= x1; x++)
			{
				if (!mCells.TryGetValue(Key(x, z), let ids)) continue;
				for (let id in ids)
					mResult.Add(mEntries[id].agent);
			}
		}
		return mResult;
	}

	/// Moves the agents whose place changed to their new cells, once per scene update or fixed tick.
	void Refresh()
	{
		let update = mScene.UpdateCount;
		if (update == mRefreshedUpdate && Time.Tick == mRefreshedTick)
			return;
		mRefreshedUpdate = update;
		mRefreshedTick = Time.Tick;
		mLargestRadius = 0;
		for (int32 id < (int32)mEntries.Count)
		{
			let entry = mEntries[id];
			if (entry.agent == null) continue;
			mLargestRadius = Math.Max(mLargestRadius, entry.agent.radius);
			if (entry.version != entry.agent.Transform.Version || entry.offset != entry.agent.baseOffset)
				Place(id);
		}
	}

	/// Lists an agent in the cell it stands in now.
	void Place(int32 id)
	{
		ref Entry entry = ref mEntries[id];
		let agent = entry.agent;
		entry.version = agent.Transform.Version;
		entry.offset = agent.baseOffset;
		let position = agent.Transform.Position + entry.offset;
		let finite = position.x.IsFinite && position.z.IsFinite;
		let cell = finite ? Key(CellOf(position.x), CellOf(position.z)) : 0;
		if (entry.hasCell && finite && entry.cell == cell)
			return;
		Unlist(id);
		if (!finite)
			return;
		List<int32> ids;
		if (!mCells.TryGetValue(cell, out ids))
		{
			ids = new .();
			mCells[cell] = ids;
		}
		entry.cell = cell;
		entry.slot = (int32)ids.Count;
		entry.hasCell = true;
		ids.Add(id);
	}

	/// Takes an agent out of its cell's list (the last one in the list takes its place).
	void Unlist(int32 id)
	{
		ref Entry entry = ref mEntries[id];
		if (!entry.hasCell)
			return;
		entry.hasCell = false;
		let ids = mCells[entry.cell];
		let last = ids.PopBack();
		if (last != id)
		{
			ids[entry.slot] = last;
			mEntries[last].slot = entry.slot;
		}
		if (ids.IsEmpty)
		{
			mCells.Remove(entry.cell);
			delete ids;
		}
	}
}
