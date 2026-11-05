using System;

namespace Tallow;

/// Something that makes sound. Each object that should be heard gets its own: a radio, an engine, footsteps.
///
///   let source = GetComponent<AudioSource>();
///   source.Play();                               // the Audio Clip set in the Inspector
///   source.PlayOneShot("Sounds/hit.wav");        // another sound on top, from the same place
///
/// With Spatial on, the sound comes from the object's position: quieter with distance, panned to the side it is
/// on, pitch-shifted as it moves past (Doppler), muffled behind walls (Occlusion) and echoing inside a reverb
/// zone. With Spatial off it is plain stereo, which is right for music and interface sounds.
///
/// A handle (ComponentHandle): its settings are AudioSourceData's fields, in the object's entity; the playing voice
/// is AudioSourceState, kept outside them. An object has at most one Audio Source; give a second sound a child
/// object of its own (or use PlayOneShot).
[Component, HandleFields]
struct AudioSource : ComponentHandle<AudioSourceData>
{
	const float OccludedCutoff = 900;
	const float OccludedVolume = 0.55f;

	/// The voice and what it has loaded; null until it first plays.
	AudioSourceState State
	{
		get
		{
			CheckValid();
			return ComponentState<AudioSourceState>.Get(mGameObject.Scene.World, mGameObject.Entity);
		}
	}

	AudioSourceState MadeState
	{
		get
		{
			CheckValid();
			return ComponentState<AudioSourceState>.Make(mGameObject.Scene.World, mGameObject.Entity);
		}
	}

	/// Whether the sound is playing now.
	public bool IsPlaying
	{
		get
		{
			let state = State;
			return state != null && state.source != null && Audio.tn_audio_source_playing(state.source) != 0;
		}
	}

	/// Length of the loaded sound in seconds; 0 until it has been loaded by playing.
	public float Length
	{
		get
		{
			let state = State;
			return state != null && state.source != null ? Audio.tn_audio_source_length(state.source) : 0;
		}
	}

	/// Playback position in seconds.
	public float Time
	{
		get
		{
			let state = State;
			return state != null && state.source != null ? Audio.tn_audio_source_time(state.source) : 0;
		}
		set
		{
			let state = State;
			if (state != null && state.source != null)
				Audio.tn_audio_source_seek(state.source, value);
		}
	}

	/// How blocked the sound currently is, 0 clear to 1 fully behind something.
	public float Occlusion => State?.occlusion ?? 0;

	bool Load()
	{
		let state = MadeState;
		let settings = Data;
		if (state.source != null && state.loaded == settings.audioClip && state.loadedStream == settings.stream && state.loadedGroup == settings.group && state.loadedSpatial == settings.spatial)
			return true;
		state.Unload();
		state.source = Audio.Load(settings.audioClip, settings.group, settings.stream, settings.spatial);
		if (state.source == null)
			return false;
		state.loaded = settings.audioClip;
		state.loadedStream = settings.stream;
		state.loadedSpatial = settings.spatial;
		state.loadedGroup = settings.group;
		return true;
	}

	/// Plays the Audio Clip from the beginning. In multiplayer, a sound started on the server or by the player
	/// who controls the object is heard by everyone.
	public void Play()
	{
		if (!localOnly)
			NetworkSync.AudioPlayed(this, 0, "", 1);
		if (!Load())
			return;
		let state = State;
		// The first frame must already be in the right place, not at the origin.
		state.occlusion = state.occlusionTarget = occlusion ? ProbeOcclusion() : 0;
		Push(state);
		Audio.tn_audio_source_play(state.source, 1);
		if (subtitles)
			Subtitles.Follow(this, audioClip);
	}

	/// Plays a different clip on this source.
	public void Play(StringView clip)
	{
		audioClip = clip;
		Play();
	}

	/// Stops the sound.
	public void Stop()
	{
		if (!localOnly)
			NetworkSync.AudioPlayed(this, 1, "", 1);
		if (let state = State)
		{
			if (state.source != null)
				Audio.tn_audio_source_stop(state.source);
		}
	}

	/// Stops where it is; Resume carries on from there.
	public void Pause()
	{
		if (let state = State)
		{
			if (state.source != null)
				Audio.tn_audio_source_stop(state.source);
		}
	}

	/// Carries on a paused sound from where it was.
	public void Resume()
	{
		if (let state = State)
		{
			if (state.source != null)
				Audio.tn_audio_source_play(state.source, 0);
		}
	}

	/// Plays another sound once from this object's position with this source's distance settings, without
	/// interrupting what it is already playing. Any number can overlap: footsteps, shots, impacts.
	public void PlayOneShot(StringView clip, float volumeScale = 1)
	{
		if (!localOnly)
			NetworkSync.AudioPlayed(this, 2, clip, volumeScale);
		if (spatial)
			Audio.PlayOneShot(clip, Transform.Position, volume * volumeScale, group, minDistance, maxDistance);
		else
			Audio.PlayOneShot2D(clip, volume * volumeScale, group);
	}

	/// 1 if something solid is between the listener and this source, else 0. Colliders of this object and its
	/// parents and children do not count.
	float ProbeOcclusion()
	{
		if (!spatial || Scene == null)
			return 0;
		let from = Audio.ListenerPosition;
		let delta = Transform.Position - from;
		let distance = delta.Length;
		if (distance < 0.3f || distance > maxDistance * 1.5f)
			return 0;
		RaycastHit hit;
		// Stop a little short so the source's own surface is not what gets hit.
		if (!Scene.Physics.Raycast(from, delta, distance - 0.2f, out hit) || hit.gameObject == null)
			return 0;
		var transform = hit.gameObject.Transform;
		while (transform != null)
		{
			if (transform.GameObject == GameObject)
				return 0;
			transform = transform.Parent;
		}
		transform = Transform.Parent;
		while (transform != null)
		{
			if (transform.GameObject == hit.gameObject)
				return 0;
			transform = transform.Parent;
		}
		return 1;
	}

	void Push(AudioSourceState state)
	{
		if (state.source == null)
			return;
		let settings = Data;
		let position = Transform.Position;
		Audio.Params parameters = Audio.Defaults();
		parameters.position = position;
		if (state.hasLast && Tallow.Time.UnscaledDeltaTime > 0.0001f)
		{
			parameters.velocity = (position - state.lastPosition) / Tallow.Time.UnscaledDeltaTime;
			if (parameters.velocity.LengthSquared > 100 * 100)
				parameters.velocity = .Zero;
		}
		state.lastPosition = position;
		state.hasLast = true;
		parameters.direction = Transform.Forward;
		parameters.pitch = Math.Max(settings.pitch, 0.01f);
		parameters.minDistance = Math.Max(settings.minDistance, 0.01f);
		parameters.maxDistance = Math.Max(settings.maxDistance, parameters.minDistance + 0.01f);
		parameters.rolloffModel = (int32)settings.rolloff;
		parameters.doppler = settings.doppler;
		parameters.spatial = settings.spatial ? 1 : 0;
		parameters.looping = settings.loop ? 1 : 0;
		let cone = Mathf.Clamp(settings.coneAngle, 0, 360) * Mathf.Deg2Rad;
		parameters.coneInner = cone;
		parameters.coneOuter = Math.Min(cone * 1.5f + 0.3f, Math.PI_f * 2);
		parameters.coneOuterGain = settings.coneAngle >= 360 ? 1 : settings.coneOuterVolume;
		float cutoff = 22000;
		float level = settings.volume;
		if (settings.spatial)
		{
			if (settings.airAbsorption)
			{
				// Far sounds lose their top end; by Max Distance about two octaves are gone.
				let far = Mathf.Clamp01(((position - Audio.ListenerPosition).Length - parameters.minDistance) / (parameters.maxDistance - parameters.minDistance));
				cutoff = Mathf.Lerp(22000, 5500, far);
			}
			cutoff = Mathf.Lerp(cutoff, Math.Min(cutoff, OccludedCutoff), state.occlusion);
			level *= Mathf.Lerp(1, OccludedVolume, state.occlusion);
			parameters.reverbSend = Mathf.Clamp01(Math.Max(settings.reverbSend, Audio.ReverbLevel));
		}
		else
			parameters.reverbSend = Mathf.Clamp01(settings.reverbSend);
		cutoff = Math.Min(cutoff, Math.Max(settings.lowpass, 20));
		// Outside the scene's world state it keeps its place, and is heard only as the echo it is given, if any.
		if (!GameObject.InActiveWorld)
		{
			level *= Mathf.Clamp01(settings.otherWorldVolume);
			cutoff = Math.Min(cutoff, Math.Max(settings.otherWorldLowpass, 20));
		}
		parameters.lowpassHz = cutoff;
		parameters.volume = Math.Max(level, 0);
		Audio.tn_audio_source_set(state.source, &parameters);
		if (state.loadedSpatial)
		{
			Audio.DirectionTo(position, let azimuth, let elevation);
			Audio.tn_audio_source_direction(state.source, azimuth, elevation);
		}
	}

	/// A frame of a playing source: follows its object, muffles it behind walls.
	void Frame(AudioSourceState state)
	{
		if (state.source == null)
			return;
		// Switching between positioned and plain stereo changes how the sound is wired, so it is loaded again.
		if (state.loadedSpatial != spatial)
		{
			let wasPlaying = IsPlaying;
			let at = Time;
			if (Load() && wasPlaying)
			{
				Push(state);
				Audio.tn_audio_source_seek(state.source, at);
				Audio.tn_audio_source_play(state.source, 0);
			}
			if (state.source == null)
				return;
		}
		if (occlusion && spatial)
		{
			// A ray ten times a second is plenty; in between, the muffling eases toward the latest answer.
			state.occlusionTimer -= Tallow.Time.UnscaledDeltaTime;
			if (state.occlusionTimer <= 0)
			{
				state.occlusionTimer = 0.1f;
				state.occlusionTarget = ProbeOcclusion();
			}
			let step = Tallow.Time.UnscaledDeltaTime * 6;
			state.occlusion = state.occlusion < state.occlusionTarget ? Math.Min(state.occlusion + step, state.occlusionTarget) : Math.Max(state.occlusion - step, state.occlusionTarget);
		}
		else
			state.occlusion = 0;
		Push(state);
	}

	/// Once a frame, before Audio.Update (the scene's Frame.Audio step): starts the sources that play on start
	/// (once, when the scene is playing), moves the playing ones, and silences any switched off or on an inactive
	/// object, as their OnDisable did when Audio Source was a class.
	public static void FrameAll(Scene scene)
	{
		let world = scene.World;
		for (let source in scene.Components<AudioSource>(.. scope .()))
		{
			if (!source.GameObject.ActiveInHierarchy)
				continue;
			var state = source.State;
			if (scene.IsPlaying && (state == null || !state.started))
			{
				state = source.MadeState;
				state.started = true;
				if (source.playOnStart && !source.audioClip.IsEmpty)
					source.Play();
			}
			if (state != null)
				source.Frame(state);
		}
		// Those that went quiet: switched off, or their object made inactive.
		for (let (entity, state) in ComponentState<AudioSourceState>.In(world, .. scope .()))
		{
			if (state.source == null)
				continue;
			let link = world.Get<ObjectLink>(entity);
			if (link == null || link.gameObject == null)
				continue;
			let source = link.gameObject.GetComponent<AudioSource>();
			if (!source.GameObject.ActiveInHierarchy || !source.enabled)
				state.Unload();
		}
	}

	static void OnRemove(void* world, uint64 entity) => ComponentState<AudioSourceState>.Release(world, entity);

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		let source = gameObject.GetComponent<AudioSource>();
		if (!selected || !source.spatial)
			return;
		let position = gameObject.Transform.Position;
		Gizmos.Lines.Sphere(position, source.minDistance, .(0.35f, 0.85f, 0.95f, 1));
		Gizmos.Lines.Sphere(position, source.maxDistance, .(0.35f, 0.85f, 0.95f, 0.35f));
	}
}

/// An Audio Source's settings.
[Component, HandleData]
struct AudioSourceData
{
	/// Sound file, relative to the project's asset folder: WAV, OGG, MP3 or FLAC.
	public SharedString audioClip = default;
	/// Which volume setting the sound follows (effects, music, voice...).
	public AudioGroup group = .Effects;
	/// Music and other per-player audio can opt out of network playback events.
	public bool localOnly = false;
	/// How loud the sound is, 0 to 1.
	[Range(0, 1)] public float volume = 1;
	/// How fast (and so how high) the sound plays: 1 is as recorded.
	[Range(0.1f, 3)] public float pitch = 1;
	/// Plays the sound over and over.
	public bool loop = false;
	/// Start playing when the scene starts.
	public bool playOnStart = true;
	/// Read the file a little at a time instead of all at once. For music and long ambience.
	public bool stream = false;
	/// Come from the object's position in the world. Off plays it the same in both ears.
	public bool spatial = true;
	/// Full volume inside this distance.
	public float minDistance = 1;
	/// No quieter beyond this distance (silent, with Linear rolloff).
	public float maxDistance = 40;
	/// How the sound gets quieter with distance.
	public AudioRolloff rolloff = .Inverse;
	/// Pitch shift as the source and listener move relative to each other. 0 turns it off.
	[Range(0, 3)] public float doppler = 1;
	/// Muffle and quieten the sound when something solid is between it and the listener.
	public bool occlusion = true;
	/// Dull distant sounds slightly, as air does.
	public bool airAbsorption = true;
	/// Reverb this source always has, on top of any reverb zone the listener is in.
	[Range(0, 1)] public float reverbSend = 0;
	/// Angle in degrees of the cone, around the object's forward direction, inside which the sound is at full
	/// volume. 360 sends it equally in all directions.
	[Range(0, 360)] public float coneAngle = 360;
	/// Volume behind the cone, 0 to 1.
	[Range(0, 1)] public float coneOuterVolume = 0.3f;
	/// Shows the clip's subtitle file while it plays, when it has one: the same name ending .srt
	/// (`Voice/intro.ogg` and `Voice/intro.srt`). See docs/dialogue.md.
	public bool subtitles = true;
	/// Cuts everything above this frequency, in Hz, all the time (a radio, a voice through a door). 22000 leaves the
	/// sound as recorded.
	[Range(200, 22000)] public float lowpass = 22000;
	/// How loud the sound is to a listener in another world state, 0 to 1 of its volume: a faint echo from the other
	/// reality. 0 (the default): not heard there at all.
	[Range(0, 1)] public float otherWorldVolume = 0;
	/// Heard from another world state, everything above this frequency (Hz) is cut, so it comes through muffled.
	[Range(200, 22000)] public float otherWorldLowpass = 800;

	public this() { }
}

/// What an Audio Source keeps outside its data: the voice playing its clip, and how muffled it is.
class AudioSourceState
{
	public void* source;
	public SharedString loaded;
	public bool loadedStream, loadedSpatial;
	public AudioGroup loadedGroup;
	public Vector3 lastPosition;
	public bool hasLast;
	public float occlusion, occlusionTarget, occlusionTimer;
	/// Play On Start has been looked at (once, when the scene first plays with it).
	public bool started;

	public ~this()
	{
		Unload();
	}

	/// Stops and frees the voice, and takes down its subtitles.
	public void Unload()
	{
		Subtitles.Forget(this);
		if (source != null)
			Audio.tn_audio_source_destroy(source);
		source = null;
		loaded = default;
	}
}
