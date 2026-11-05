using System;
using System.Collections;

namespace Tallow;

/// What a sequence track does to its object.
enum SequenceTrackKind
{
	/// Moves the object along keys (local position, rotation and optionally scale).
	Transform,
	/// Cuts (or blends) the view between shots: objects whose position, facing and field of view the camera takes.
	Camera,
	/// Plays an Animator state (or a clip of the object's model) at each key.
	Animation,
	/// Plays a sound at each key, from the object's Audio Source, at the object, or (no object) in both ears.
	Audio,
	/// Shows or hides the object: each key sets it on or off until the next.
	Active,
	/// Tells the game something happened at each key, with a name and a number.
	Event,
	/// Shows a subtitle at each key.
	Subtitle,
	/// Fades the screen to a colour: each key is how far (0 clear, 1 covered), eased to the next.
	Fade
}

/// How a key's value goes to the next key's.
enum SequenceEase
{
	/// Evenly.
	Linear,
	/// Slowly at both ends.
	Smooth,
	/// Holds until the next key, then jumps.
	Step
}

/// One key on a track. Which fields mean anything depends on the track's kind.
class SequenceKey
{
	public float time;
	/// Transform: where the object goes, its turn (degrees) and size.
	public Vector3 position;
	public Vector3 euler;
	public Vector3 scale = .(1, 1, 1);
	/// Transform: whether this key sets the size too.
	public bool hasScale;
	/// Camera: field of view (0: the shot's own). Audio: volume. Active: 1 on, 0 off. Event: its number. Fade: how
	/// far the screen is covered.
	public float value;
	/// Camera: seconds blending from the shot before. Animation: seconds fading from the state before. Subtitle:
	/// seconds shown (0: a reading time from its length).
	public float length;
	/// Camera: the shot object. Animation: the state or clip. Audio: the sound. Event: its name. Subtitle: speaker.
	public String text = new .() ~ delete _;
	/// Subtitle: the line.
	public String line = new .() ~ delete _;
	public SequenceEase ease = .Smooth;

	public Quaternion Rotation => Quaternion.Euler(euler.x, euler.y, euler.z);

	public void CopyFrom(SequenceKey other)
	{
		time = other.time;
		position = other.position;
		euler = other.euler;
		scale = other.scale;
		hasScale = other.hasScale;
		value = other.value;
		length = other.length;
		text.Set(other.text);
		line.Set(other.line);
		ease = other.ease;
	}
}

/// A row of a sequence: what it does, the object it does it to and its keys, in time order.
class SequenceTrack
{
	public SequenceTrackKind kind;
	/// The object, by name (or a path of names, "Ship/Hatch"), looked for under the Sequence Player's object first,
	/// then in the whole scene. Empty: the Sequence Player's own object (Audio: a sound in both ears).
	public String target = new .() ~ delete _;
	/// Left out when the sequence plays (the editor's eye button).
	public bool muted;
	/// Fade: the colour faded to.
	public Color color = .(0, 0, 0, 1);
	public List<SequenceKey> keys = new .() ~ DeleteContainerAndItems!(_);

	/// Puts the keys back in time order (after one is moved).
	public void Sort() => keys.Sort(scope (a, b) => a.time <=> b.time);

	/// The last key at or before a time, or -1.
	public int KeyAt(float time)
	{
		int found = -1;
		for (int i < keys.Count)
		{
			if (keys[i].time <= time)
				found = i;
			else
				break;
		}
		return found;
	}

	/// Adds a key, keeping time order. Returns it.
	public SequenceKey AddKey(float time)
	{
		let key = new SequenceKey();
		key.time = time;
		int at = keys.Count;
		for (int i < keys.Count)
		{
			if (keys[i].time > time)
			{
				at = i;
				break;
			}
		}
		keys.Insert(at, key);
		return key;
	}

	/// How far between two keys, eased the first key's way (0 at a, 1 at b).
	public static float Blend(SequenceKey a, SequenceKey b, float time)
	{
		if (a.ease == .Step)
			return time >= b.time ? 1 : 0;
		let t = Math.Clamp((time - a.time) / Math.Max(b.time - a.time, 1.0e-5f), 0, 1);
		return a.ease == .Smooth ? t * t * (3 - 2 * t) : t;
	}

	/// A Transform track's pose at a time.
	public void SamplePose(float time, out Vector3 position, out Quaternion rotation, out Vector3 scale, out bool hasScale)
	{
		position = .Zero;
		rotation = .Identity;
		scale = .(1, 1, 1);
		hasScale = false;
		for (let key in keys)
			hasScale |= key.hasScale;
		if (keys.IsEmpty)
			return;
		let at = KeyAt(time);
		if (at < 0 || at == keys.Count - 1)
		{
			let key = keys[at < 0 ? 0 : at];
			position = key.position;
			rotation = key.Rotation;
			scale = key.scale;
			return;
		}
		let a = keys[at];
		let b = keys[at + 1];
		let t = Blend(a, b, time);
		position = Vector3.Lerp(a.position, b.position, t);
		rotation = Quaternion.Slerp(a.Rotation, b.Rotation, t);
		scale = Vector3.Lerp(a.scale, b.scale, t);
	}

	/// A Fade track's cover at a time (0 before its first key).
	public float SampleValue(float time)
	{
		let at = KeyAt(time);
		if (at < 0)
			return keys.IsEmpty ? 0 : (time < keys[0].time ? 0 : keys[0].value);
		if (at == keys.Count - 1)
			return keys[at].value;
		return Math.Lerp(keys[at].value, keys[at + 1].value, Blend(keys[at], keys[at + 1], time));
	}
}

/// A cutscene, or any timed piece of a level: tracks that move objects, cut between cameras, play animations and
/// sounds, show and hide things, fade the screen, show subtitles and tell the game when something happens. Kept in
/// a `.tsequence` file, edited in the editor's Sequencer tab and played by a Sequence Player:
///
///   sequence length 8 framerate 30
///   track camera
///       shot 0 "Shot Wide"
///       shot 3 "Shot Close" blend 1.5 fov 40
///   track transform "Shot Wide"
///       key 0 position 0 3 -10 rotation 10 0 0
///       key 3 position 2 3 -6 rotation 12 -15 0 ease linear
///   track animation "Hero"
///       play 0.5 "Wave" fade 0.2
///   track audio "Hero"
///       sound 0.5 "Voice/hello.ogg" volume 0.9
///   track active "Gate"
///       set 0 on
///       set 6 off
///   track subtitle
///       line 0.5 "Hero" "Over here!" length 2
///   track event
///       event 6 GateOpened 1
///   track fade color 0 0 0
///       key 0 1
///       key 1 0
///       key 7 0
///       key 8 1
///
/// Lines starting with # are comments. A track's object is `track <kind> "<name>"` (no name: the player's own object).
class SequenceAsset
{
	public String path = new .() ~ delete _;
	/// Seconds.
	public float length = 5;
	/// Frames a second the editor places keys on.
	public float frameRate = 30;
	public List<SequenceTrack> tracks = new .() ~ DeleteContainerAndItems!(_);
	/// What was wrong with the file, one problem to a line. Empty when it is fine.
	public String problems = new .() ~ delete _;

	static Dictionary<String, SequenceAsset> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	public static readonly StringView[?] KindNames = .("transform", "camera", "animation", "audio", "active", "event", "subtitle", "fade");
	static readonly StringView[?] KeyWords = .("key", "shot", "play", "sound", "set", "event", "line", "key");

	/// The sequence in a project file, read once and kept (null when it cannot be read).
	public static SequenceAsset Load(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let text = scope String();
		SequenceAsset asset = null;
		if (Assets.ReadText(path, text))
		{
			asset = new SequenceAsset();
			asset.path.Set(path);
			asset.Parse(text);
			for (let problem in asset.problems.Split('\n', .RemoveEmptyEntries))
				Log.Warning(scope $"{path}: {problem}");
		}
		else
			Log.Warning(scope $"Sequence {path} could not be read.");
		sCache[new String(path)] = asset;
		return asset;
	}

	/// Forgets every sequence read so far.
	public static void ClearCache()
	{
		for (let (key, value) in sCache)
		{
			delete key;
			delete value;
		}
		sCache.Clear();
	}

	/// Forgets one sequence, so it is read again from its file (after the editor saves it).
	public static void Forget(StringView path)
	{
		if (sCache.GetAndRemoveAlt(path) case .Ok(let entry))
		{
			delete entry.key;
			delete entry.value;
		}
	}

	public static StringView KindName(SequenceTrackKind kind) => KindNames[(int)kind];

	static float Number(StringView text) => float.Parse(text) case .Ok(let value) ? value : 0;

	/// Reads the file's text, replacing what the sequence held.
	public void Parse(StringView text)
	{
		ClearAndDeleteItems(tracks);
		problems.Clear();
		length = 5;
		frameRate = 30;
		SequenceTrack track = null;
		int32 lineNumber = 0;
		let tokens = scope List<StringView>();
		let storage = scope List<String>();
		for (let rawLine in text.Split('\n'))
		{
			lineNumber++;
			var line = StringView(rawLine)..Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			tokens.Clear();
			ClearAndDeleteItems(storage);
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.IsEmpty)
				continue;
			let word = tokens[0];
			if (word == "sequence")
			{
				for (int i = 1; i + 1 < tokens.Count; i += 2)
				{
					if (tokens[i] == "length")
						length = Math.Max(Number(tokens[i + 1]), 0.01f);
					else if (tokens[i] == "framerate")
						frameRate = Math.Clamp(Number(tokens[i + 1]), 1, 240);
				}
				continue;
			}
			if (word == "track")
			{
				track = ParseTrack(tokens, lineNumber);
				if (track != null)
					tracks.Add(track);
				continue;
			}
			if (track == null)
			{
				problems.AppendF("line {}: '{}' comes before the first track\n", lineNumber, word);
				continue;
			}
			if (word != KeyWords[(int)track.kind] || tokens.Count < 2)
			{
				problems.AppendF("line {}: a {} track's keys are '{} <time> ...'\n", lineNumber, KindName(track.kind), KeyWords[(int)track.kind]);
				continue;
			}
			let key = track.AddKey(Number(tokens[1]));
			ParseKey(track, key, tokens, lineNumber);
		}
		ClearAndDeleteItems(storage);
		for (let each in tracks)
			each.Sort();
	}

	SequenceTrack ParseTrack(List<StringView> tokens, int32 lineNumber)
	{
		if (tokens.Count < 2)
		{
			problems.AppendF("line {}: a track needs a kind\n", lineNumber);
			return null;
		}
		int kind = -1;
		for (int k < KindNames.Count)
		{
			if (tokens[1] == KindNames[k])
				kind = k;
		}
		if (kind < 0)
		{
			problems.AppendF("line {}: there is no '{}' track (transform, camera, animation, audio, active, event, subtitle or fade)\n", lineNumber, tokens[1]);
			return null;
		}
		let track = new SequenceTrack();
		track.kind = (SequenceTrackKind)kind;
		for (int i = 2; i < tokens.Count; i++)
		{
			if (tokens[i] == "muted")
				track.muted = true;
			else if (tokens[i] == "color" && i + 3 < tokens.Count)
			{
				track.color = .(Number(tokens[i + 1]), Number(tokens[i + 2]), Number(tokens[i + 3]), 1);
				i += 3;
			}
			else if (i == 2)
				track.target.Set(tokens[i]);
		}
		return track;
	}

	void ParseKey(SequenceTrack track, SequenceKey key, List<StringView> tokens, int32 lineNumber)
	{
		int i = 2;
		// The words that come straight after the time.
		switch (track.kind)
		{
		case .Camera,.Animation,.Audio:
			if (i < tokens.Count)
				key.text.Set(tokens[i++]);
			if (key.text.IsEmpty)
				problems.AppendF("line {}: the key at {} needs a name\n", lineNumber, key.time);
			if (track.kind == .Audio)
				key.value = 1;
		case .Active:
			if (i < tokens.Count)
			{
				let state = tokens[i++];
				key.value = state == "on" || state == "1" || state == "true" ? 1 : 0;
			}
		case .Event:
			if (i < tokens.Count)
				key.text.Set(tokens[i++]);
			if (i < tokens.Count && (float.Parse(tokens[i]) case .Ok(let number)))
			{
				key.value = number;
				i++;
			}
		case .Subtitle:
			if (i < tokens.Count)
				key.text.Set(tokens[i++]);
			if (i < tokens.Count)
				key.line.Set(tokens[i++]);
		case .Fade:
			if (i < tokens.Count)
				key.value = Number(tokens[i++]);
		case .Transform:
		}
		for (; i < tokens.Count; i++)
		{
			let name = tokens[i];
			let left = tokens.Count - i - 1;
			if (name == "position" && left >= 3)
			{
				key.position = .(Number(tokens[i + 1]), Number(tokens[i + 2]), Number(tokens[i + 3]));
				i += 3;
			}
			else if (name == "rotation" && left >= 3)
			{
				key.euler = .(Number(tokens[i + 1]), Number(tokens[i + 2]), Number(tokens[i + 3]));
				i += 3;
			}
			else if (name == "scale" && left >= 3)
			{
				key.scale = .(Number(tokens[i + 1]), Number(tokens[i + 2]), Number(tokens[i + 3]));
				key.hasScale = true;
				i += 3;
			}
			else if (name == "ease" && left >= 1)
			{
				let ease = tokens[++i];
				key.ease = ease == "linear" ? .Linear : (ease == "step" ? .Step : .Smooth);
			}
			else if ((name == "blend" || name == "fade" || name == "length") && left >= 1)
				key.length = Math.Max(Number(tokens[++i]), 0);
			else if ((name == "fov" || name == "volume") && left >= 1)
				key.value = Number(tokens[++i]);
			else
				problems.AppendF("line {}: '{}' is not something a {} key has\n", lineNumber, name, KindName(track.kind));
		}
	}

	static void AppendNumber(String text, float value)
	{
		text.AppendF("{}", value == 0 ? 0 : value);
	}

	static void AppendVector(String text, StringView name, Vector3 v)
	{
		text.AppendF(" {} ", name);
		AppendNumber(text, v.x);
		text.Append(' ');
		AppendNumber(text, v.y);
		text.Append(' ');
		AppendNumber(text, v.z);
	}

	/// Writes the sequence as file text.
	public void Write(String text)
	{
		text.Append("sequence length ");
		AppendNumber(text, length);
		text.Append(" framerate ");
		AppendNumber(text, frameRate);
		text.Append('\n');
		for (let track in tracks)
		{
			text.AppendF("track {}", KindName(track.kind));
			if (!track.target.IsEmpty)
			{
				text.Append(' ');
				SceneSerializer.Quote(track.target, text);
			}
			if (track.kind == .Fade)
				AppendVector(text, "color", .(track.color.r, track.color.g, track.color.b));
			if (track.muted)
				text.Append(" muted");
			text.Append('\n');
			for (let key in track.keys)
			{
				text.AppendF("\t{} ", KeyWords[(int)track.kind]);
				AppendNumber(text, key.time);
				switch (track.kind)
				{
				case .Transform:
					AppendVector(text, "position", key.position);
					AppendVector(text, "rotation", key.euler);
					if (key.hasScale)
						AppendVector(text, "scale", key.scale);
				case .Camera:
					text.Append(' ');
					SceneSerializer.Quote(key.text, text);
					if (key.length > 0)
					{
						text.Append(" blend ");
						AppendNumber(text, key.length);
					}
					if (key.value > 0)
					{
						text.Append(" fov ");
						AppendNumber(text, key.value);
					}
				case .Animation:
					text.Append(' ');
					SceneSerializer.Quote(key.text, text);
					if (key.length > 0)
					{
						text.Append(" fade ");
						AppendNumber(text, key.length);
					}
				case .Audio:
					text.Append(' ');
					SceneSerializer.Quote(key.text, text);
					if (key.value != 1)
					{
						text.Append(" volume ");
						AppendNumber(text, key.value);
					}
				case .Active:
					text.Append(key.value > 0.5f ? " on" : " off");
				case .Event:
					text.AppendF(" {} ", key.text.IsEmpty ? "Event" : key.text);
					AppendNumber(text, key.value);
				case .Subtitle:
					text.Append(' ');
					SceneSerializer.Quote(key.text, text);
					text.Append(' ');
					SceneSerializer.Quote(key.line, text);
					if (key.length > 0)
					{
						text.Append(" length ");
						AppendNumber(text, key.length);
					}
				case .Fade:
					text.Append(' ');
					AppendNumber(text, key.value);
				}
				if ((track.kind == .Transform || track.kind == .Fade) && key.ease != .Smooth)
					text.Append(key.ease == .Linear ? " ease linear" : " ease step");
				text.Append('\n');
			}
		}
	}

	/// The time the last key is at (or the length, if that is later).
	public float End
	{
		get
		{
			float end = length;
			for (let track in tracks)
			{
				if (!track.keys.IsEmpty)
					end = Math.Max(end, track.keys.Back.time);
			}
			return end;
		}
	}
}

/// Puts a sequence on a scene at a time: finds each track's object, keeps how things were before so they can be put
/// back, and applies the tracks. The Sequence Player uses one; so does the editor's Sequencer preview.
class SequenceEvaluator
{
	public SequenceAsset Asset;
	/// Where names are looked for first (the Sequence Player's object); also a track with no name's object.
	public GameObject Owner;
	public Scene Scene;
	/// The camera shots are shown through, made when the sequence has a camera track.
	public Camera ViewCamera;
	/// The screen fade now, and its colour.
	public float Fade;
	public Color FadeColor;
	/// Called for each Event key passed while playing.
	public Event<delegate void(StringView name, float value)> OnEvent ~ _.Dispose();
	/// False: events are not called here (a shared sequence on a client; events happen on the server).
	public bool FireEvents = true;

	List<GameObject> mTargets = new .() ~ delete _;
	struct Rest
	{
		public GameObject target;
		public Vector3 position;
		public Quaternion rotation;
		public Vector3 scale;
		public bool active;
	}

	List<Rest> mRest = new .() ~ delete _;
	List<int32> mSubtitles = new .() ~ delete _;
	List<AudioSource> mSounds = new .() ~ delete _;

	/// The object a name means: a path of names under the owner first ("Ship/Hatch"), then anywhere in the scene.
	public static GameObject Resolve(Scene scene, GameObject owner, StringView name)
	{
		if (name.IsEmpty)
			return owner;
		if (owner != null)
		{
			var transform = owner.Transform;
			for (let part in name.Split('/'))
			{
				Transform next = null;
				for (let child in transform.Children)
				{
					if (child.GameObject.Name == part)
					{
						next = child;
						break;
					}
				}
				transform = next;
				if (transform == null)
					break;
			}
			if (transform != null)
				return transform.GameObject;
		}
		if (scene == null)
			return null;
		let slash = name.LastIndexOf('/');
		let leaf = slash >= 0 ? name.Substring(slash + 1) : name;
		for (let object in scene.Objects)
		{
			if (object.Name != leaf)
				continue;
			// With a path, the parents' names must match too.
			if (slash >= 0 && !PathMatches(object, name))
				continue;
			return object;
		}
		return null;
	}

	static bool PathMatches(GameObject object, StringView path)
	{
		var current = object.Transform;
		var rest = path;
		while (!rest.IsEmpty && current != null)
		{
			let slash = rest.LastIndexOf('/');
			let name = slash >= 0 ? rest.Substring(slash + 1) : rest;
			if (current.GameObject.Name != name)
				return false;
			rest = slash >= 0 ? rest.Substring(0, slash) : "";
			current = current.Parent;
		}
		return rest.IsEmpty;
	}

	/// Finds the tracks' objects and remembers how they are, so Restore can put them back.
	public void Bind(SequenceAsset asset, Scene scene, GameObject owner)
	{
		Asset = asset;
		Scene = scene;
		Owner = owner;
		mTargets.Clear();
		mRest.Clear();
		if (asset == null)
			return;
		for (let track in asset.tracks)
		{
			let target = Resolve(scene, owner, track.target);
			mTargets.Add(target);
			if (target == null)
			{
				if (track.kind != .Event && track.kind != .Subtitle && track.kind != .Fade && !(track.kind == .Audio && track.target.IsEmpty))
					Log.Warning(scope $"{asset.path}: no object called '{track.target}' for its {SequenceAsset.KindName(track.kind)} track.");
				continue;
			}
			if (track.kind == .Transform || track.kind == .Active)
				Remember(target);
			if (track.kind == .Camera)
			{
				for (let key in track.keys)
				{
					let shot = Resolve(scene, owner, key.text);
					if (shot == null)
						Log.Warning(scope $"{asset.path}: no object called '{key.text}' for a camera shot.");
				}
			}
		}
	}

	void Remember(GameObject target)
	{
		for (let rest in mRest)
		{
			if (rest.target == target)
				return;
		}
		Rest rest;
		rest.target = target;
		rest.position = target.Transform.LocalPosition;
		rest.rotation = target.Transform.LocalRotation;
		rest.scale = target.Transform.LocalScale;
		rest.active = target.ActiveSelf;
		mRest.Add(rest);
	}

	/// Puts every moved, shown or hidden object back as it was when bound.
	public void Restore()
	{
		for (let rest in mRest)
		{
			if (rest.target == null || rest.target.IsDestroyed)
				continue;
			rest.target.Transform.LocalPosition = rest.position;
			rest.target.Transform.LocalRotation = rest.rotation;
			rest.target.Transform.LocalScale = rest.scale;
			if (rest.target.ActiveSelf != rest.active)
				rest.target.SetActive(rest.active);
		}
	}

	/// The object a track (by index) works on, or null.
	public GameObject Target(int track) => track < mTargets.Count ? mTargets[track] : null;

	/// Whether the camera track has a shot at this time (the sequence's camera is the one to look through).
	public bool HasShot(float time)
	{
		if (Asset == null)
			return false;
		for (let track in Asset.tracks)
		{
			if (track.kind == .Camera && !track.muted && track.KeyAt(time) >= 0)
				return true;
		}
		return false;
	}

	/// Puts the tracks at a time. Moments (sounds, animations, subtitles, events) passed since `from` happen when
	/// `moments` is on; scrubbing and jumping leave them out.
	public void Apply(float time, float from, bool moments)
	{
		Fade = 0;
		if (Asset == null)
			return;
		for (int t < Asset.tracks.Count)
		{
			let track = Asset.tracks[t];
			if (track.muted || track.keys.IsEmpty)
				continue;
			let target = Target(t);
			switch (track.kind)
			{
			case .Transform:
				if (target == null)
					continue;
				track.SamplePose(time, let position, let rotation, let scale, let hasScale);
				target.Transform.LocalPosition = position;
				target.Transform.LocalRotation = rotation;
				if (hasScale)
					target.Transform.LocalScale = scale;
			case .Active:
				if (target == null)
					continue;
				let at = track.KeyAt(time);
				if (at < 0)
					continue;
				let on = track.keys[at].value > 0.5f;
				if (target.ActiveSelf != on)
					target.SetActive(on);
			case .Camera:
				ApplyCamera(track, time);
			case .Fade:
				let cover = Math.Clamp(track.SampleValue(time), 0, 1);
				if (cover >= Fade)
				{
					Fade = cover;
					FadeColor = track.color;
				}
			default:
				if (!moments)
					continue;
				for (let key in track.keys)
				{
					if (key.time > from && key.time <= time)
						Moment(track, key, target);
				}
			}
		}
	}

	void ApplyCamera(SequenceTrack track, float time)
	{
		if (!ViewCamera)
			return;
		Vector3 position;
		Quaternion rotation;
		float fov;
		if (!ShotPose(track, time, out position, out rotation, out fov))
			return;
		ViewCamera.Transform.Position = position;
		ViewCamera.Transform.Rotation = rotation;
		ViewCamera.fieldOfView = fov;
	}

	/// Where the camera is at a time: from the first unmuted camera track's shot, blended from the shot before.
	/// False when there is no shot then.
	public bool ShotPose(float time, out Vector3 position, out Quaternion rotation, out float fov)
	{
		position = .Zero;
		rotation = .Identity;
		fov = 60;
		if (Asset == null)
			return false;
		for (let track in Asset.tracks)
		{
			if (track.kind == .Camera && !track.muted && ShotPose(track, time, out position, out rotation, out fov))
				return true;
		}
		return false;
	}

	bool ShotPose(SequenceTrack track, float time, out Vector3 position, out Quaternion rotation, out float fov)
	{
		position = .Zero;
		rotation = .Identity;
		fov = 60;
		let at = track.KeyAt(time);
		if (at < 0)
			return false;
		let key = track.keys[at];
		let shot = Resolve(Scene, Owner, key.text);
		if (shot == null)
			return false;
		position = shot.Transform.Position;
		rotation = shot.Transform.Rotation;
		fov = ShotFov(shot, key);
		// Blending in from the shot before.
		if (at > 0 && key.length > 0 && time < key.time + key.length)
		{
			let before = track.keys[at - 1];
			let previous = Resolve(Scene, Owner, before.text);
			if (previous != null)
			{
				var t = Math.Clamp((time - key.time) / key.length, 0, 1);
				t = t * t * (3 - 2 * t);
				position = Vector3.Lerp(previous.Transform.Position, position, t);
				rotation = Quaternion.Slerp(previous.Transform.Rotation, rotation, t);
				fov = Math.Lerp(ShotFov(previous, before), fov, t);
			}
		}
		return true;
	}

	static float ShotFov(GameObject shot, SequenceKey key)
	{
		if (key.value > 0)
			return key.value;
		let camera = shot.GetComponent<Camera>();
		return camera ? camera.fieldOfView : 60;
	}

	void Moment(SequenceTrack track, SequenceKey key, GameObject target)
	{
		switch (track.kind)
		{
		case .Animation:
			if (target == null)
				return;
			let animator = target.GetComponent<Animator>();
			if (animator.IsValid)
				animator.Play(key.text, key.length);
		case .Audio:
			if (key.text.IsEmpty)
				return;
			// Every machine plays the sequence itself, so the sound is not sent on.
			let wasQuiet = NetworkSync.Quiet;
			NetworkSync.Quiet = true;
			defer
			{
				NetworkSync.Quiet = wasQuiet;
			}
			AudioSource source = target != null ? target.GetComponent<AudioSource>() : default;
			if (source)
			{
				source.volume = key.value;
				source.Play(key.text);
				if (!mSounds.Contains(source))
					mSounds.Add(source);
			}
			else if (target != null && !track.target.IsEmpty)
				Audio.PlayOneShot(key.text, target.Transform.Position, key.value, .Voice);
			else
				Audio.PlayOneShot2D(key.text, key.value, .Voice);
		case .Subtitle:
			let seconds = key.length > 0 ? key.length : Math.Max(1.5f, key.line.Length / 15.0f);
			mSubtitles.Add(Subtitles.Show(key.text, key.line, seconds));
		case .Event:
			if (FireEvents)
				OnEvent(key.text, key.value);
		default:
		}
	}

	/// Events between two times, without the rest: what skipping over them must still tell the game.
	public void FireEventsBetween(float from, float to)
	{
		if (Asset == null || !FireEvents)
			return;
		for (let track in Asset.tracks)
		{
			if (track.kind != .Event || track.muted)
				continue;
			for (let key in track.keys)
			{
				if (key.time > from && key.time <= to)
					OnEvent(key.text, key.value);
			}
		}
	}

	/// Each Animation track's last state up to a time, played at once (after a jump, characters stand as they would).
	public void SettleAnimations(float time)
	{
		if (Asset == null)
			return;
		for (int t < Asset.tracks.Count)
		{
			let track = Asset.tracks[t];
			let target = Target(t);
			if (track.kind != .Animation || track.muted || target == null)
				continue;
			let at = track.KeyAt(time);
			if (at >= 0)
			{
				let animator = target.GetComponent<Animator>();
				if (animator.IsValid)
					animator.Play(track.keys[at].text, 0);
			}
		}
	}

	/// Takes down its subtitles and stops its sounds (stopping or skipping).
	public void Silence()
	{
		for (let id in mSubtitles)
			Subtitles.Hide(id);
		mSubtitles.Clear();
		let wasQuiet = NetworkSync.Quiet;
		NetworkSync.Quiet = true;
		for (let source in mSounds)
		{
			if (!source.GameObject.IsDestroyed && source)
				source.Stop();
		}
		NetworkSync.Quiet = wasQuiet;
		mSounds.Clear();
	}
}
