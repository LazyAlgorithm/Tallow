using System;

namespace Tallow;

/// Random numbers every machine agrees on, for a networked script's Update or Simulate (System.Random is seeded
/// differently on every machine, so the server and each client would get different numbers and split apart).
/// Seeded from what every machine in step shares: the object's network id, exactly where it is and how it is turned,
/// and a number of your own (`salt`, for more than one draw a tick).
///
///     let spread = NetRandom.Range(this, -0.1f, 0.1f);
///     let jitter = NetRandom.Value(this, 1);
static class NetRandom
{
	/// A number from 0 up to (not including) 1.
	public static float Value(Component component, int salt = 0)
	{
		uint64 hash = 14695981039346656037;
		void Add(void* data, int length)
		{
			let bytes = (uint8*)data;
			for (int i < length)
			{
				hash ^= bytes[i];
				hash *= 1099511628211;
			}
		}
		var id = (uint32)0;
		if (component.GameObject.HasComponent<NetworkIdentity>())
			id = component.GameObject.GetComponent<NetworkIdentity>().NetId;
		var position = component.Transform.Position;
		var rotation = component.Transform.Rotation;
		var s = (int64)salt;
		Add(&id, 4);
		Add(&position, sizeof(Vector3));
		Add(&rotation, sizeof(Quaternion));
		Add(&s, 8);
		// Mix the bits once more (FNV's low bits are weak) and keep 24 of them.
		hash ^= hash >> 33;
		hash *= 0xff51afd7ed558ccd;
		hash ^= hash >> 33;
		return (float)(hash >> 40) / (float)(1 << 24);
	}

	/// A number from min up to max.
	public static float Range(Component component, float min, float max, int salt = 0) => min + (max - min) * Value(component, salt);

	/// A whole number from min up to (not including) max.
	public static int Range(Component component, int min, int max, int salt = 0) => max <= min ? min : min + Math.Min((int)(Value(component, salt) * (max - min)), max - min - 1);
}
