using System;
using System.Collections;

namespace Tallow;

/// Which soft characters are near which, for CharacterControllerState.Separation: every character used to look at
/// every other one each tick (O(n²): 1,000 walkers cost 140 ms a tick). Built at most once a tick, from where the
/// characters stand then, in square cells of 2 × the largest push radius plus Margin, so anything a character can
/// overlap is in its own cell or the eight round it, even after both have moved up to Margin / 2. A character that
/// moves further, is teleported (rollback does that) or is found moved from outside by its own next Move marks it to
/// be rebuilt. Left: a Transform written directly mid-tick is seen by others from the next tick or that character's
/// next Move, whichever comes first. Lookups return list indices in Controllers order, so pushes add
/// up in the same order as the full loop: the same result to the bit.
class SoftCharacterGrid
{
	/// How far a character may move from where the grid saw it before the grid is rebuilt.
	public const float Margin = 1.0f;

	Dictionary<int64, List<int32>> mCells = new .() ~ DeleteDictionaryAndValues!(_);
	List<List<int32>> mSpare = new .() ~ DeleteContainerAndItems!(_);
	int32 mBuiltTick = int32.MinValue;
	int mBuiltVersion = -1;
	float mCell = 1;
	public bool Dirty;

	static int64 Key(int x, int z) => ((int64)x << 32) ^ (int64)(uint32)z;

	/// Rebuilds when the tick, the set of characters or their shapes changed, or one moved far.
	public void Prepare(List<CharacterControllerState> controllers, int version)
	{
		if (!Dirty && mBuiltTick == Time.Tick && mBuiltVersion == version)
			return;
		Dirty = false;
		mBuiltTick = Time.Tick;
		mBuiltVersion = version;
		for (let list in mCells.Values)
		{
			list.Clear();
			mSpare.Add(list);
		}
		mCells.Clear();
		float largest = 0;
		for (let controller in controllers)
			largest = Math.Max(largest, controller.[Friend]mPushRadius);
		mCell = Math.Max(largest * 2 + Margin, 0.1f);
		for (int32 i < (int32)controllers.Count)
		{
			let controller = controllers[i];
			if (!controller.[Friend]mSoft || !controller.HasCharacter)
				continue;
			let at = controller.[Friend]Transform.Position + controller.[Friend]mShapeCenter;
			controller.[Friend]mGridAt = at;
			let key = Key((int)Math.Floor(at.x / mCell), (int)Math.Floor(at.z / mCell));
			List<int32> list;
			if (!mCells.TryGetValue(key, out list))
			{
				list = mSpare.IsEmpty ? new .() : mSpare.PopBack();
				mCells[key] = list;
			}
			list.Add(i);
		}
	}

	/// The indices of the soft characters that may overlap one at this position, ascending.
	public void Near(Vector3 at, List<int32> output)
	{
		let cx = (int)Math.Floor(at.x / mCell);
		let cz = (int)Math.Floor(at.z / mCell);
		for (int dz = -1; dz <= 1; dz++)
			for (int dx = -1; dx <= 1; dx++)
				if (mCells.TryGetValue(Key(cx + dx, cz + dz), let list))
					output.AddRange(list);
		output.Sort();
	}
}
