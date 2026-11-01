using System;
using System.Collections;

namespace Tallow;

/// Mixer groups: every Audio Source plays into one, and each has its own volume.
[Reflect(.All)]
enum AudioGroup : int32
{
	Effects,
	Music,
	Voice,
	Ambience,
	Interface,
	Other
}

/// How a positioned sound gets quieter with distance, between its Min Distance and Max Distance.
[Reflect(.All)]
enum AudioRolloff : int32
{
	/// Like the real world: halves with each doubling of distance. The usual choice.
	Inverse = 1,
	/// A straight line from full volume to silence at Max Distance.
	Linear = 2,
	/// Falls away faster than Inverse.
	Exponential = 3
}

/// The audio engine. Sounds are played by Audio Source components and heard from the Audio Listener; this class
/// holds what is global: volumes, one-off sounds and start-up.
///
///   Audio.MasterVolume = 0.8f;
///   Audio.SetGroupVolume(.Music, 0.5f);
///   Audio.PlayOneShot("Sounds/explosion.wav", position);
///
/// Nothing is opened until the first sound plays, so a game without audio never touches the sound card.
static class Audio
{
	/// How a playing sound is set: volume, pitch, position and the rest (passed to the native mixer).
	[CRepr] public struct Params
	{
		public Vector3 position;
		public Vector3 velocity;
		public Vector3 direction;
		public float volume;
		public float pitch;
		public float minDistance;
		public float maxDistance;
		public float rolloff;
		public float doppler;
		public float lowpassHz;
		public float reverbSend;
		public float coneInner;
		public float coneOuter;
		public float coneOuterGain;
		public int32 rolloffModel;
		public int32 spatial;
		public int32 looping;
	}

	[CLink] static extern int32 tn_audio_init(int32 noDevice, uint32 sampleRate);
	[CLink] static extern void tn_audio_shutdown();
	[CLink] static extern void tn_audio_listener(Vector3* position, Vector3* forward, Vector3* up, Vector3* velocity);
	[CLink] static extern void tn_audio_master_volume(float volume);
	[CLink] static extern void tn_audio_group_volume(int32 group, float volume);
	[CLink] static extern void tn_audio_reverb(float roomSize, float damping, float width);
	[CLink] public static extern void* tn_audio_source_create(char8* path, int32 group, int32 stream, int32 positioned);
	[CLink] public static extern void tn_audio_source_direction(void* source, float azimuth, float elevation);
	[CLink] static extern void tn_audio_hrtf(int32 enabled, float strength, float headSize, float trebleDb);
	[CLink] public static extern void tn_audio_source_destroy(void* source);
	[CLink] public static extern void tn_audio_source_set(void* source, Params* parameters);
	[CLink] public static extern void tn_audio_source_play(void* source, int32 fromStart);
	[CLink] public static extern void tn_audio_source_stop(void* source);
	[CLink] public static extern int32 tn_audio_source_playing(void* source);
	[CLink] public static extern int32 tn_audio_source_finished(void* source);
	[CLink] public static extern float tn_audio_source_length(void* source);
	[CLink] public static extern float tn_audio_source_time(void* source);
	[CLink] public static extern void tn_audio_source_seek(void* source, float seconds);
	[CLink] static extern uint32 tn_audio_read(float* output, uint32 frames);
	[CLink] static extern uint32 tn_audio_sample_rate();

	static bool sTried, sReady;
	static float sMaster = 1;
	static float[6] sGroupVolumes = .(1, 1, 1, 1, 1, 1);
	static List<(void* source, Vector3 position, bool spatial)> sOneShots = new .() ~ delete _;
	static Vector3 sListenerForward = .(0, 0, 1), sListenerUp = .(0, 1, 0);
	static bool sHrtf = false;
	static float sHrtfStrength = 1, sHrtfHeadSize = 1, sHrtfTreble = 0;
	static Vector3 sListenerPosition, sLastListenerPosition;
	static bool sListenerSet, sHaveLastListener;
	static float sReverbLevel;

	/// Run without a sound card: nothing is heard, but everything else works and Render gives the mix. For tests
	/// and for servers. Set before the first sound.
	public static bool NoDevice;
	/// Turns audio off completely: sounds do nothing. Set for dedicated servers.
	public static bool Disabled;
	/// Set by the editor while it is not playing: the Scene view's camera is the listener then.
	public static bool EditorListening;

	/// True once the engine is running. Starting is automatic; this only reports whether it worked.
	public static bool Ready => sReady;
	/// Where the listener was last placed.
	public static Vector3 ListenerPosition => sListenerPosition;
	/// How strongly the listener is inside a reverb zone, 0 to 1.
	public static float ReverbLevel => sReverbLevel;

	static void ApplyHrtf()
	{
		if (sReady)
			tn_audio_hrtf(sHrtf ? 1 : 0, sHrtfStrength, sHrtfHeadSize, sHrtfTreble);
	}

	/// Headphone 3D, off unless the game turns it on. On, each positioned sound is filtered through the responses
	/// measured at the two ears of a dummy head for its direction, so it can be placed in front, behind, above or
	/// below, not just left and right. It is made for headphones; on speakers it can sound coloured, so offer it
	/// as a choice. Off uses ordinary left-right panning. All four HRTF settings can be changed at any time,
	/// while sounds play, which makes them suitable for an options menu.
	public static bool Hrtf
	{
		get => sHrtf;
		set
		{
			sHrtf = value;
			ApplyHrtf();
		}
	}

	/// How much of the headphone 3D effect is used, from 0 (the same as panning) to 1 (fully binaural, the
	/// default). Lower it for players who find the full effect tiring or too coloured.
	public static float HrtfStrength
	{
		get => sHrtfStrength;
		set
		{
			sHrtfStrength = Mathf.Clamp01(value);
			ApplyHrtf();
		}
	}

	/// Scales the delay between the two ears, from 0.5 to 1.5; 1 is the measured head. Heads differ: a player
	/// whose sounds seem to sit too close to the middle can raise it, one whose sounds jump too far to the side
	/// can lower it.
	public static float HrtfHeadSize
	{
		get => sHrtfHeadSize;
		set
		{
			sHrtfHeadSize = Mathf.Clamp(value, 0.5f, 1.5f);
			ApplyHrtf();
		}
	}

	/// Brightens (above 0) or dulls (below 0) headphone 3D sound, in decibels from -12 to 12. Measured responses
	/// can sound a little muffled on some headphones; a few decibels of treble corrects that.
	public static float HrtfTreble
	{
		get => sHrtfTreble;
		set
		{
			sHrtfTreble = Mathf.Clamp(value, -12, 12);
			ApplyHrtf();
		}
	}

	/// Where a point in the world is as the listener hears it, in radians: azimuth to the right of straight
	/// ahead, elevation upward.
	public static void DirectionTo(Vector3 point, out float azimuth, out float elevation)
	{
		azimuth = 0;
		elevation = 0;
		let offset = point - sListenerPosition;
		let distance = offset.Length;
		if (distance < 0.0001f)
			return;
		let forward = sListenerForward;
		let up = sListenerUp;
		let right = Vector3(up.y * forward.z - up.z * forward.y, up.z * forward.x - up.x * forward.z, up.x * forward.y - up.y * forward.x);
		let x = Vector3.Dot(offset, right), y = Vector3.Dot(offset, up), z = Vector3.Dot(offset, forward);
		azimuth = Math.Atan2(x, z);
		elevation = Math.Asin(Mathf.Clamp(y / distance, -1, 1));
	}

	/// Starts the engine if it is not running. Called by the first sound.
	public static bool Start()
	{
		if (sReady)
			return true;
		if (sTried || Disabled)
			return false;
		sTried = true;
		sReady = tn_audio_init(NoDevice ? 1 : 0, 48000) != 0;
		if (!sReady)
		{
			Log.Warning("Audio could not start: no sound device was found. The game runs without sound.");
			return false;
		}
		tn_audio_master_volume(sMaster);
		ApplyHrtf();
		for (int32 i < 6)
			tn_audio_group_volume(i, sGroupVolumes[i]);
		return true;
	}

	/// Stops every sound and closes the audio device.
	public static void Shutdown()
	{
		for (let entry in sOneShots)
			tn_audio_source_destroy(entry.source);
		sOneShots.Clear();
		if (sReady)
			tn_audio_shutdown();
		sReady = false;
		sTried = false;
	}

	/// The volume of everything, 0 to 1.
	public static float MasterVolume
	{
		get => sMaster;
		set
		{
			sMaster = Math.Max(value, 0);
			if (sReady)
				tn_audio_master_volume(sMaster);
		}
	}

	/// The volume of one group of sounds (music, effects...), 0 to 1.
	public static float GetGroupVolume(AudioGroup group) => sGroupVolumes[(int)group];

	/// Sets the volume of one group of sounds, 0 to 1.
	public static void SetGroupVolume(AudioGroup group, float volume)
	{
		sGroupVolumes[(int)group] = Math.Max(volume, 0);
		if (sReady)
			tn_audio_group_volume((int32)group, sGroupVolumes[(int)group]);
	}

	/// Places the listener: where the player's ears are and which way they face. Audio Listener does this; call it
	/// yourself only for something unusual.
	public static void SetListener(Vector3 positionIn, Vector3 forwardIn, Vector3 upIn)
	{
		sListenerPosition = positionIn;
		if (forwardIn.LengthSquared > 0.0001f)
			sListenerForward = forwardIn.Normalized;
		if (upIn.LengthSquared > 0.0001f)
			sListenerUp = upIn.Normalized;
		sListenerSet = true;
		if (!sReady)
			return;
		var position = positionIn;
		var forward = forwardIn;
		var up = upIn;
		// Speed comes from how far the listener moved since last frame; it is what Doppler is measured against.
		var velocity = Vector3.Zero;
		if (sHaveLastListener && Time.UnscaledDeltaTime > 0.0001f)
		{
			velocity = (position - sLastListenerPosition) / Time.UnscaledDeltaTime;
			if (velocity.LengthSquared > 100 * 100)
				velocity = .Zero; // a teleport, not a movement
		}
		sLastListenerPosition = position;
		sHaveLastListener = true;
		tn_audio_listener(&position, &forward, &up, &velocity);
	}

	/// Plays a sound once at a place in the world and forgets about it. For impacts, shots, pickups.
	public static void PlayOneShot(StringView clip, Vector3 position, float volume = 1, AudioGroup group = .Effects, float minDistance = 1, float maxDistance = 40)
	{
		// In a session the server's are heard on every machine (docs/networking.md).
		if (NetworkSync.SoundPlayed(clip, position, volume, group, minDistance, maxDistance))
			return;
		Params parameters = Defaults();
		parameters.position = position;
		parameters.volume = volume;
		parameters.minDistance = minDistance;
		parameters.maxDistance = maxDistance;
		parameters.spatial = 1;
		parameters.reverbSend = sReverbLevel;
		OneShot(clip, group, parameters);
	}

	/// Plays a sound once with no position: the same in both ears wherever the listener is. For interface sounds.
	public static void PlayOneShot2D(StringView clip, float volume = 1, AudioGroup group = .Interface)
	{
		Params parameters = Defaults();
		parameters.volume = volume;
		parameters.spatial = 0;
		OneShot(clip, group, parameters);
	}

	/// Settings for a sound playing normally.
	public static Params Defaults()
	{
		Params parameters = default;
		parameters.direction = .(0, 0, 1);
		parameters.volume = 1;
		parameters.pitch = 1;
		parameters.minDistance = 1;
		parameters.maxDistance = 40;
		parameters.rolloff = 1;
		parameters.doppler = 1;
		parameters.lowpassHz = 22000;
		parameters.coneInner = Math.PI_f * 2;
		parameters.coneOuter = Math.PI_f * 2;
		parameters.coneOuterGain = 1;
		parameters.rolloffModel = (int32)AudioRolloff.Inverse;
		parameters.spatial = 1;
		return parameters;
	}

	/// Loads a sound file for playing. Returns null (with one warning) if the file is missing or not a sound.
	public static void* Load(StringView clip, AudioGroup group, bool stream, bool spatial)
	{
		if (clip.IsEmpty || !Start())
			return null;
		let path = scope String();
		Assets.ResolvePath(clip, path);
		let source = tn_audio_source_create(path.CStr(), (int32)group, stream ? 1 : 0, spatial ? 1 : 0);
		if (source == null)
			Log.Warning(scope $"Sound not found or not readable: {clip} (WAV, OGG, MP3 and FLAC are supported).");
		return source;
	}

	static void OneShot(StringView clip, AudioGroup group, Params parametersIn)
	{
		let source = Load(clip, group, false, parametersIn.spatial != 0);
		if (source == null)
			return;
		var parameters = parametersIn;
		tn_audio_source_set(source, &parameters);
		if (parameters.spatial != 0)
		{
			DirectionTo(parameters.position, let azimuth, let elevation);
			tn_audio_source_direction(source, azimuth, elevation);
		}
		tn_audio_source_play(source, 1);
		sOneShots.Add((source, parameters.position, parameters.spatial != 0));
	}

	/// How many sounds started with PlayOneShot are playing.
	public static int ActiveOneShots => sOneShots.Count;

	/// Once a frame, from the scene: places the listener at the camera if no Audio Listener did, works out the
	/// reverb from the zones around the listener, and frees one-off sounds that have finished.
	public static void Update(Scene scene)
	{
		if (!sListenerSet && scene != null)
		{
			let camera = scene.ViewCamera;
			if (camera != null)
				SetListener(camera.Transform.Position, camera.Transform.Forward, camera.Transform.Rotation * Vector3.Up);
		}
		sListenerSet = false;
		if (!sReady)
			return;
		// The zone the listener is deepest inside sets the reverb's character and how much of it is heard.
		float level = 0, roomSize = 0.5f, damping = 0.5f;
		if (scene != null)
		{
			for (let component in scene.ComponentsOfType(typeof(AudioReverbZone)))
			{
				let zone = (AudioReverbZone)component;
				if (!zone.IsActiveAndEnabled)
					continue;
				let weight = zone.WeightAt(sListenerPosition) * zone.amount;
				if (weight > level)
				{
					level = weight;
					roomSize = zone.roomSize;
					damping = zone.damping;
				}
			}
		}
		sReverbLevel = level;
		tn_audio_reverb(Mathf.Clamp01(roomSize), Mathf.Clamp01(damping), 1);
		for (int i = sOneShots.Count - 1; i >= 0; i--)
		{
			let entry = sOneShots[i];
			if (tn_audio_source_finished(entry.source) != 0)
			{
				tn_audio_source_destroy(entry.source);
				sOneShots.RemoveAt(i);
			}
			else if (entry.spatial)
			{
				// The listener may have turned since it started.
				DirectionTo(entry.position, let azimuth, let elevation);
				tn_audio_source_direction(entry.source, azimuth, elevation);
			}
		}
	}

	/// With NoDevice set: mixes the next frames into an interleaved stereo buffer (left, right, left, ...) and
	/// returns how many frames were written. This is how tests listen.
	public static int Render(Span<float> stereo)
	{
		if (!sReady || stereo.Length < 2)
			return 0;
		return (int)tn_audio_read(stereo.Ptr, (uint32)(stereo.Length / 2));
	}

	/// The audio device's sample rate (48000 if it is not open).
	public static int SampleRate => sReady ? (int)tn_audio_sample_rate() : 48000;
}
