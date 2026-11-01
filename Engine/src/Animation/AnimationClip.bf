using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// A keyframed animation for a skeleton of named bones (.tanim file).
///
///   clip Walk duration 0.9 loop 1
///   track UpperLeg.L
///   key 0.0   0 0 0   -30 0 0      time, position offset, rotation in euler degrees
///
/// Keys are offsets from the bone's rest pose, so one clip works on any skeleton with the same bone names.
class AnimationClip
{
	public struct Key
	{
		public float time;
		public Vector3 position;
		public Quaternion rotation;
		/// The rotation as it was typed, in degrees, which is what the Animation window edits and what is saved.
		public Vector3 euler;
		public Vector3 scale;
	}

	public class Track
	{
		public String bone = new .() ~ delete _;
		public List<Key> keys = new .() ~ delete _;

		/// Position, rotation and scale at a time. Scale multiplies the object's own; (1, 1, 1) leaves it alone.
		public void Sample(float time, out Vector3 position, out Quaternion rotation, out Vector3 scale)
		{
			position = .Zero;
			rotation = .Identity;
			scale = .(1, 1, 1);
			if (keys.Count == 0)
				return;
			let i = After(time);
			if (i == 0 || i == keys.Count)
			{
				let key = keys[i == 0 ? 0 : keys.Count - 1];
				position = key.position;
				rotation = key.rotation;
				scale = key.scale;
				return;
			}
			let a = keys[i - 1];
			let b = keys[i];
			let t = (time - a.time) / Math.Max(b.time - a.time, 1.0e-5f);
			position = Vector3.Lerp(a.position, b.position, t);
			rotation = Quaternion.Slerp(a.rotation, b.rotation, t);
			scale = Vector3.Lerp(a.scale, b.scale, t);
		}

		/// The first key at or after a time (0 when the time is at or before the first key, Count when it is past the
		/// last), found by halving.
		int After(float time)
		{
			if (time <= keys[0].time || keys.Count == 1)
				return 0;
			int low = 1, high = keys.Count;
			while (low < high)
			{
				let middle = (low + high) >> 1;
				if (time <= keys[middle].time)
					high = middle;
				else
					low = middle + 1;
			}
			return low;
		}

		/// Sets the key at a time, or adds one there, keeping keys in time order. Returns its index.
		public int SetKey(float time, Vector3 position, Vector3 euler, Vector3 scale)
		{
			Key key;
			key.time = time;
			key.position = position;
			key.euler = euler;
			key.rotation = Quaternion.Euler(euler.x, euler.y, euler.z);
			key.scale = scale;
			for (int i < keys.Count)
			{
				if (Math.Abs(keys[i].time - time) < 0.0005f)
				{
					keys[i] = key;
					return i;
				}
				if (keys[i].time > time)
				{
					keys.Insert(i, key);
					return i;
				}
			}
			keys.Add(key);
			return keys.Count - 1;
		}

		public void Sample(float time, out Vector3 position, out Quaternion rotation)
		{
			Sample(time, out position, out rotation, let scale);
		}
	}

	public String name = new .() ~ delete _;
	public float duration = 1.0f;
	public bool loop = true;
	/// Frames per second the clip is edited at: the Animation window places keys on these frames.
	public float frameRate = 60;
	public List<Track> tracks = new .() ~ DeleteContainerAndItems!(_);
	/// Goes up whenever a track is added or removed (code that removes one calls TracksChanged), so lookups kept by
	/// track (the Animator's) know to look again.
	public int32 TrackRevision { get; private set; }

	public void TracksChanged()
	{
		TrackRevision++;
	}

	static Dictionary<String, AnimationClip> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	public Track FindTrack(StringView bone)
	{
		for (let track in tracks)
		{
			if (track.bone == bone)
				return track;
		}
		return null;
	}

	public Track AddTrack(StringView bone)
	{
		let existing = FindTrack(bone);
		if (existing != null)
			return existing;
		let track = new Track();
		track.bone.Set(bone);
		tracks.Add(track);
		TrackRevision++;
		return track;
	}

	/// Keys a child at a time, as recording does. A child the clip did not move before gets a row, and, when the
	/// key is not at the start, a key at time 0 holding its untouched pose, so that it moves from where it was to
	/// the new key instead of sitting at the new pose for the whole clip. A key past the end lengthens the clip.
	/// Returns the track and the index of the key in it.
	public Track AutoKey(StringView bone, float time, Vector3 position, Vector3 euler, Vector3 scale, out int keyIndex)
	{
		var track = FindTrack(bone);
		if (track == null)
		{
			track = AddTrack(bone);
			if (time > 0.0005f)
				track.SetKey(0, .Zero, .Zero, .(1, 1, 1));
		}
		if (time > duration)
			duration = time;
		keyIndex = track.SetKey(Math.Max(time, 0), position, euler, scale);
		return track;
	}

	/// Writes the clip in the format Load reads. fullPath is a path on disk.
	public void Save(StringView fullPath)
	{
		let text = scope String();
		text.Append("clip ");
		SceneSerializer.Quote(name, text);
		text.AppendF(" duration {} loop {} samples {}\n", duration, loop ? 1 : 0, frameRate);
		for (let track in tracks)
		{
			text.Append("track ");
			SceneSerializer.Quote(track.bone, text);
			text.Append('\n');
			for (let key in track.keys)
				text.AppendF("key {} {} {} {} {} {} {} {} {} {}\n", key.time, key.position.x, key.position.y, key.position.z, key.euler.x, key.euler.y, key.euler.z, key.scale.x, key.scale.y, key.scale.z);
		}
		if (File.WriteAllText(fullPath, text) case .Err)
			Log.Error(scope $"Could not save {fullPath}");
	}

	/// Makes an empty clip and registers it under a project path, as if it had been loaded from there.
	public static AnimationClip Create(StringView path, StringView name)
	{
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let clip = new AnimationClip();
		clip.name.Set(name);
		sCache[new String(path)] = clip;
		return clip;
	}

	/// Loads (and caches) a clip. The path is relative to the project's asset folder.
	public static AnimationClip Load(StringView path)
	{
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let full = scope String();
		Assets.ResolvePath(path, full);
		let text = scope String();
		if (AssetPack.ReadAllText(full, text) case .Err)
		{
			Log.Warning(scope $"Animation clip not found: {path}");
			return null;
		}
		let clip = new AnimationClip();
		Track track = null;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count == 0)
				continue;
			if (tokens[0] == "clip" && tokens.Count >= 6)
			{
				clip.name.Set(tokens[1]);
				clip.duration = Math.Max(SceneSerializer.ParseFloat(tokens[3]), 0.01f);
				clip.loop = tokens[5] == "1";
				if (tokens.Count >= 8)
					clip.frameRate = Mathf.Clamp(SceneSerializer.ParseFloat(tokens[7]), 1, 240);
			}
			else if (tokens[0] == "track" && tokens.Count >= 2)
			{
				track = new Track();
				track.bone.Set(tokens[1]);
				clip.tracks.Add(track);
			}
			else if (tokens[0] == "key" && track != null && tokens.Count >= 8)
			{
				Key key;
				key.time = SceneSerializer.ParseFloat(tokens[1]);
				key.position = .(SceneSerializer.ParseFloat(tokens[2]), SceneSerializer.ParseFloat(tokens[3]), SceneSerializer.ParseFloat(tokens[4]));
				key.euler = .(SceneSerializer.ParseFloat(tokens[5]), SceneSerializer.ParseFloat(tokens[6]), SceneSerializer.ParseFloat(tokens[7]));
				key.rotation = Quaternion.Euler(key.euler.x, key.euler.y, key.euler.z);
				// Scale was added later; clips without it leave scale alone.
				key.scale = tokens.Count >= 11 ? Vector3(SceneSerializer.ParseFloat(tokens[8]), SceneSerializer.ParseFloat(tokens[9]), SceneSerializer.ParseFloat(tokens[10])) : .(1, 1, 1);
				track.keys.Add(key);
			}
		}
		sCache[new String(path)] = clip;
		return clip;
	}
}
