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
[Component]
class AudioSource : Component
{
	/// Sound file, relative to the project's asset folder: WAV, OGG, MP3 or FLAC.
	public String audioClip = new .() ~ delete _;
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

	void* mSource;
	String mLoaded = new .() ~ delete _;
	bool mLoadedStream, mLoadedSpatial;
	AudioGroup mLoadedGroup;
	Vector3 mLastPosition;
	bool mHasLast;
	float mOcclusion, mOcclusionTarget, mOcclusionTimer;
	bool mWantsPlay;

	const float OccludedCutoff = 900;
	const float OccludedVolume = 0.55f;

	/// Whether the sound is playing now.
	public bool IsPlaying => mSource != null && Audio.tn_audio_source_playing(mSource) != 0;
	/// Length of the loaded sound in seconds; 0 until it has been loaded by playing.
	public float Length => mSource != null ? Audio.tn_audio_source_length(mSource) : 0;
	/// Playback position in seconds.
	public float Time
	{
		get => mSource != null ? Audio.tn_audio_source_time(mSource) : 0;
		set
		{
			if (mSource != null)
				Audio.tn_audio_source_seek(mSource, value);
		}
	}

	/// How blocked the sound currently is, 0 clear to 1 fully behind something.
	public float Occlusion => mOcclusion;

	public override void Start()
	{
		if (playOnStart && !audioClip.IsEmpty)
			Play();
	}

	public override void OnDisable()
	{
		Subtitles.Forget(this);
		Unload();
	}

	public override void OnDestroy()
	{
		Subtitles.Forget(this);
		Unload();
	}

	void Unload()
	{
		if (mSource != null)
			Audio.tn_audio_source_destroy(mSource);
		mSource = null;
		mLoaded.Clear();
	}

	bool Load()
	{
		if (mSource != null && mLoaded == audioClip && mLoadedStream == stream && mLoadedGroup == group && mLoadedSpatial == spatial)
			return true;
		Unload();
		mSource = Audio.Load(audioClip, group, stream, spatial);
		if (mSource == null)
			return false;
		mLoaded.Set(audioClip);
		mLoadedStream = stream;
		mLoadedSpatial = spatial;
		mLoadedGroup = group;
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
		// The first frame must already be in the right place, not at the origin.
		mOcclusion = mOcclusionTarget = occlusion ? ProbeOcclusion() : 0;
		Push();
		Audio.tn_audio_source_play(mSource, 1);
		if (subtitles)
			Subtitles.Follow(this, audioClip);
	}

	/// Plays a different clip on this source.
	public void Play(StringView clip)
	{
		audioClip.Set(clip);
		Play();
	}

	/// Stops the sound.
	public void Stop()
	{
		if (!localOnly)
			NetworkSync.AudioPlayed(this, 1, "", 1);
		if (mSource != null)
			Audio.tn_audio_source_stop(mSource);
	}

	/// Stops where it is; Resume carries on from there.
	public void Pause()
	{
		if (mSource != null)
			Audio.tn_audio_source_stop(mSource);
	}

	/// Carries on a paused sound from where it was.
	public void Resume()
	{
		if (mSource != null)
			Audio.tn_audio_source_play(mSource, 0);
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

	void Push()
	{
		if (mSource == null)
			return;
		let position = Transform.Position;
		Audio.Params parameters = Audio.Defaults();
		parameters.position = position;
		if (mHasLast && Tallow.Time.UnscaledDeltaTime > 0.0001f)
		{
			parameters.velocity = (position - mLastPosition) / Tallow.Time.UnscaledDeltaTime;
			if (parameters.velocity.LengthSquared > 100 * 100)
				parameters.velocity = .Zero;
		}
		mLastPosition = position;
		mHasLast = true;
		parameters.direction = Transform.Forward;
		parameters.pitch = Math.Max(pitch, 0.01f);
		parameters.minDistance = Math.Max(minDistance, 0.01f);
		parameters.maxDistance = Math.Max(maxDistance, parameters.minDistance + 0.01f);
		parameters.rolloffModel = (int32)rolloff;
		parameters.doppler = doppler;
		parameters.spatial = spatial ? 1 : 0;
		parameters.looping = loop ? 1 : 0;
		let cone = Mathf.Clamp(coneAngle, 0, 360) * Mathf.Deg2Rad;
		parameters.coneInner = cone;
		parameters.coneOuter = Math.Min(cone * 1.5f + 0.3f, Math.PI_f * 2);
		parameters.coneOuterGain = coneAngle >= 360 ? 1 : coneOuterVolume;
		float cutoff = 22000;
		float level = volume;
		if (spatial)
		{
			if (airAbsorption)
			{
				// Far sounds lose their top end; by Max Distance about two octaves are gone.
				let far = Mathf.Clamp01(((position - Audio.ListenerPosition).Length - parameters.minDistance) / (parameters.maxDistance - parameters.minDistance));
				cutoff = Mathf.Lerp(22000, 5500, far);
			}
			cutoff = Mathf.Lerp(cutoff, Math.Min(cutoff, OccludedCutoff), mOcclusion);
			level *= Mathf.Lerp(1, OccludedVolume, mOcclusion);
			parameters.reverbSend = Mathf.Clamp01(Math.Max(reverbSend, Audio.ReverbLevel));
		}
		else
			parameters.reverbSend = Mathf.Clamp01(reverbSend);
		parameters.lowpassHz = cutoff;
		// Outside the scene's world state it keeps its place but is not heard.
		if (!GameObject.InActiveWorld)
			level = 0;
		parameters.volume = Math.Max(level, 0);
		Audio.tn_audio_source_set(mSource, &parameters);
		if (mLoadedSpatial)
		{
			Audio.DirectionTo(position, let azimuth, let elevation);
			Audio.tn_audio_source_direction(mSource, azimuth, elevation);
		}
	}

	public override void OnFrame()
	{
		if (mSource == null)
			return;
		// Switching between positioned and plain stereo changes how the sound is wired, so it is loaded again.
		if (mLoadedSpatial != spatial)
		{
			let wasPlaying = IsPlaying;
			let at = Time;
			if (Load() && wasPlaying)
			{
				Push();
				Audio.tn_audio_source_seek(mSource, at);
				Audio.tn_audio_source_play(mSource, 0);
			}
			if (mSource == null)
				return;
		}
		if (occlusion && spatial)
		{
			// A ray ten times a second is plenty; in between, the muffling eases toward the latest answer.
			mOcclusionTimer -= Tallow.Time.UnscaledDeltaTime;
			if (mOcclusionTimer <= 0)
			{
				mOcclusionTimer = 0.1f;
				mOcclusionTarget = ProbeOcclusion();
			}
			let step = Tallow.Time.UnscaledDeltaTime * 6;
			mOcclusion = mOcclusion < mOcclusionTarget ? Math.Min(mOcclusion + step, mOcclusionTarget) : Math.Max(mOcclusion - step, mOcclusionTarget);
		}
		else
			mOcclusion = 0;
		Push();
	}

	public override void OnDrawGizmos(bool selected)
	{
		if (!selected || !spatial)
			return;
		Gizmos.Lines.Sphere(Transform.Position, minDistance, .(0.35f, 0.85f, 0.95f, 1));
		Gizmos.Lines.Sphere(Transform.Position, maxDistance, .(0.35f, 0.85f, 0.95f, 0.35f));
	}
}
