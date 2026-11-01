using System;
using System.Collections;

namespace Tessera;

/// Voice chat between the players of a network session. It is off until the game turns it on (here, or with the
/// Voice Chat box in Project Settings); after that nothing else is needed: the microphone is opened, speech is
/// compressed with Opus, sent through the server and played on every other player's machine.
///
/// Everything here can be changed while the game runs, so it can be wired straight to an options menu.
static class VoiceChat
{
	[CLink] static extern void* tn_audio_stream_create(int32 group, int32 positioned);
	[CLink] static extern int32 tn_audio_stream_push(void* source, float* samples, int32 count);
	[CLink] static extern int32 tn_audio_stream_queued(void* source);
	[CLink] static extern void* tn_voice_encoder_create(int32 bitsPerSecond);
	[CLink] static extern void tn_voice_encoder_destroy(void* encoder);
	[CLink] static extern void tn_voice_encoder_bitrate(void* encoder, int32 bitsPerSecond);
	[CLink] static extern int32 tn_voice_encode(void* encoder, float* samples, uint8* output, int32 capacity);
	[CLink] static extern void* tn_voice_decoder_create();
	[CLink] static extern void tn_voice_decoder_destroy(void* decoder);
	[CLink] static extern int32 tn_voice_decode(void* decoder, uint8* packet, int32 length, float* output, int32 recover);
	[CLink] static extern int32 tn_voice_capture_start();
	[CLink] static extern void tn_voice_capture_stop();
	[CLink] static extern int32 tn_voice_capturing();
	[CLink] static extern int32 tn_voice_capture_read(float* output, int32 count);
	[CLink] static extern int32 tn_voice_capture_devices();

	public const uint8 MsgVoice = 248;
	/// Samples in one frame of speech: 20 milliseconds at 48 kHz.
	public const int FrameSize = 960;
	public const int SampleRate = 48000;
	const int MaxPacket = 400;

	// ---- settings ----

	/// Master switch. Off, the microphone is never opened and nothing is sent or played.
	public static bool Enabled;
	/// On: you are heard only while the push-to-talk key is held. Off: you are heard whenever you speak louder
	/// than Activation.
	public static bool PushToTalk;
	/// The key held to talk when PushToTalk is on.
	public static KeyCode PushToTalkKey = .V;
	/// An input action that is held to talk as well (see InputActions): the project's "Talk" action unless changed,
	/// which the standard actions bind to V and to d-pad down on a controller. Empty for none.
	public static String PushToTalkAction = new .("Talk") ~ delete _;
	/// Set this from your own code to talk without the key, for example from a gamepad button or a touch button.
	/// With PushToTalk on, you are heard while either this or the key is held.
	public static bool Talk;
	/// How loud the microphone has to be before an open microphone starts sending, from 0 to 1. Compare it with
	/// MicrophoneLevel to show the player where to set it.
	public static float Activation = 0.02f;
	/// Seconds an open microphone keeps sending after you fall quiet, so the ends of words are not cut off.
	public static float ReleaseTime = 0.5f;
	/// Gain applied to your microphone before it is sent.
	public static float MicrophoneVolume = 1;
	/// Loudness of other players' voices. The Voice mixer group (Audio.SetGroupVolume(.Voice, ...)) applies as well.
	public static float Volume = 1;
	/// Levels each received voice before distance attenuation. Disable to hear the original microphone levels.
	public static bool AutoLevel = true;
	/// Stops your microphone being sent without turning voice chat off: you still hear the others. The microphone
	/// is not even opened while muted, so a browser does not ask for permission to use it.
	public static bool Muted;
	/// Stops other players' voices being played.
	public static bool Deafened;
	/// On: a voice comes from the speaker's character, gets quieter with distance and cannot be heard beyond
	/// MaxDistance. Off: everyone hears everyone equally, like a radio.
	public static bool Proximity;
	/// With Proximity on, the distance within which a voice is at full volume, and the distance at which it is gone.
	public static float MinDistance = 2, MaxDistance = 30;
	/// On: players hear only their own team. Decided by the server, so it cannot be bypassed by a client.
	public static bool TeamOnly;
	/// Plays your own voice back to you, for a "test microphone" button. Works without a network session.
	public static bool Loopback;
	/// Bits per second of speech. 24000 is clear speech at about 3 KB/s per talker; 12000 to 64000 are sensible.
	public static int32 Bitrate = 24000;

	public delegate void SpeakingHandler(int32 clientId, bool speaking);
	/// Called when a player starts or stops being heard on this machine.
	public static Event<SpeakingHandler> OnSpeakingChanged ~ _.Dispose();

	static bool sRegistered;
	static bool sMicTried, sMicFailed;
	// Used for the microphone test when there is no network session.
	static VoiceSession sLocal ~ delete _;

	/// The voice state of the running session, or null when there is none.
	public static VoiceSession Session
	{
		get
		{
			let network = Scene.Active?.Network;
			return network != null && network.Mode != .Offline ? network.Voice : null;
		}
	}

	/// The session in use: the network session's, or the local one used for a microphone test, or null.
	public static VoiceSession Current => Session ?? sLocal;

	/// True when the system has a microphone. Does not open it.
	public static bool HasMicrophone => !Audio.Disabled && tn_voice_capture_devices() > 0;
	/// True while the microphone is open.
	public static bool MicrophoneOpen => tn_voice_capturing() != 0;
	/// How loud the microphone is right now, from 0 to about 1, after MicrophoneVolume. For a level meter.
	public static float MicrophoneLevel => (Session ?? sLocal)?.Level ?? 0;
	/// True while your voice is being sent.
	public static bool IsTransmitting => (Session ?? sLocal)?.Transmitting ?? false;
	/// True while that player is being heard on this machine. Your own id reports whether you are transmitting.
	public static bool IsSpeaking(int32 clientId) => Session?.IsSpeaking(clientId) ?? false;
	/// Stops or resumes playing one player's voice on this machine only.
	public static void Mute(int32 clientId, bool muted) => Session?.Mute(clientId, muted);
	public static bool IsMuted(int32 clientId) => Session?.IsMuted(clientId) ?? false;
	/// Local volume for a player (1 = normal, 2 = twice the amplitude). Lasts for this session.
	public static void SetPlayerVolume(int32 clientId, float volume) => Current?.SetPlayerVolume(clientId, volume);
	public static float GetPlayerVolume(int32 clientId) => Current?.GetPlayerVolume(clientId) ?? 1;

	/// Stateful level control for one decoded voice. Never share this between speakers.
	public class VoiceLeveler
	{
		float mGain = 1;
		public void Process(Span<float> samples)
		{
			if (samples.Length == 0)
				return;
			double sum = 0;
			float peak = 0;
			for (let sample in samples)
			{
				sum += sample * sample;
				peak = Math.Max(peak, Math.Abs(sample));
			}
			let rms = (float)Math.Sqrt(sum / samples.Length);
			// Hold gain during silence: do not chase the noise floor between words.
			float target = AutoLevel && rms >= 0.003f ? Math.Clamp(0.12f / rms, 0.25f, 8.0f) : mGain;
			if (!AutoLevel)
				target = 1;
			let previous = mGain;
			// Reduce loud voices quickly; bring quiet ones up over about 200 ms.
			mGain += (target - mGain) * (target < mGain ? 0.6f : 0.1f);
			// Limit the whole frame, including its gain ramp, before sending to the mixer.
			let ceiling = peak > 0 ? 0.95f / peak : 8.0f;
			for (int i < samples.Length)
			{
				let gain = previous + (mGain - previous) * (float)(i + 1) / samples.Length;
				samples[i] *= Math.Min(gain, ceiling);
			}
		}
	}
	/// True while the push-to-talk key, or Talk, is held.
	public static bool TalkHeld => Talk || (PushToTalkKey != .None && Input.GetKey(PushToTalkKey)) || (!PushToTalkAction.IsEmpty && InputActions.Held(PushToTalkAction));

	public static void EnsureRegistered()
	{
		if (sRegistered)
			return;
		sRegistered = true;
		NetworkManager.RegisterMessage(MsgVoice, new => OnVoice);
	}

	static void OnVoice(int32 sender, ref NetReader reader)
	{
		let network = Scene.Active?.Network;
		if (network == null || network.Mode == .Offline)
			return;
		int32 speaker = sender;
		if (!network.IsServer)
			speaker = reader.Read<int32>();
		let sequence = reader.Read<uint16>();
		let length = (int)reader.Read<uint16>();
		if (!reader.Ok || length <= 0 || length > MaxPacket)
			return;
		uint8[MaxPacket] packet = ?;
		for (int i < length)
			packet[i] = reader.Read<uint8>();
		if (!reader.Ok)
			return;
		if (network.IsServer)
			network.Voice.Relay(speaker, sequence, .(&packet, length));
		else
			network.Voice.Receive(speaker, sequence, .(&packet, length));
	}

	/// Called once a frame by the scene.
	public static void Update(Scene scene)
	{
		let network = scene.Network;
		VoiceSession session = network != null && network.Mode != .Offline ? network.Voice : null;
		if (session == null && Enabled && Loopback)
		{
			if (sLocal == null)
				sLocal = new VoiceSession(null);
			session = sLocal;
		}
		if (session == null && sLocal != null && !(Enabled && Loopback))
			DeleteAndNullify!(sLocal);
		// The microphone is open only while voice chat is on and there is someone to send to (or a test running).
		let wantMic = Enabled && !Muted && session != null && !Audio.Disabled && !Audio.NoDevice && (session.CanSend || Loopback);
		if (wantMic && tn_voice_capturing() == 0 && !sMicFailed)
		{
			if (tn_voice_capture_start() == 0)
			{
				sMicFailed = true;
				Log.Warning("Voice chat: no microphone could be opened. You can hear others but cannot be heard.");
			}
		}
		else if (!wantMic)
		{
			if (tn_voice_capturing() != 0)
				tn_voice_capture_stop();
			sMicFailed = false;
		}
		if (session == null)
			return;
		if (wantMic && tn_voice_capturing() != 0)
		{
			float[FrameSize] frame = ?;
			int guard = 0;
			while (guard++ < 25 && tn_voice_capture_read(&frame, FrameSize) != 0)
				session.Capture(.(&frame, FrameSize));
		}
		session.Update(scene, Time.UnscaledDeltaTime);
	}

	public static void Shutdown()
	{
		if (tn_voice_capturing() != 0)
			tn_voice_capture_stop();
		DeleteAndNullify!(sLocal);
	}

	/// One network session's voices: this machine's encoder, and a decoder and a sound for each player being heard.
	public class VoiceSession
	{
		class Speaker
		{
			public VoiceLeveler leveler = new .() ~ delete _;
			public void* decoder;
			public void* stream;
			public bool positioned;
			public uint16 lastSequence;
			public bool heard;
			public float silence = 100;
			public bool speaking;
			public int32 frames;
		}

		NetworkManager mNetwork;
		void* mEncoder;
		int32 mEncoderBitrate;
		uint16 mSequence;
		List<float> mPending = new .() ~ delete _;
		Dictionary<int32, Speaker> mSpeakers = new .() ~ delete _;
		HashSet<int32> mMuted = new .() ~ delete _;
		Dictionary<int32, float> mVolumes = new .() ~ delete _;
		// Server: packets seen from each client in the current second, to turn away floods.
		Dictionary<int32, int32> mRate = new .() ~ delete _;
		float mRateWindow;
		float mHold;
		bool mTransmitting, mSaidTransmitting;
		float mLevel;
		NetWriter mPayload = new .() ~ delete _;

		public float Level => mLevel;
		public bool Transmitting => mTransmitting;
		/// Frames of speech sent from this machine, and relayed by it as the server. For tests and statistics.
		public int32 FramesSent, FramesRelayed, BytesSent;

		public this(NetworkManager network)
		{
			mNetwork = network;
		}

		public ~this()
		{
			for (let speaker in mSpeakers.Values)
				Free(speaker);
			if (mEncoder != null)
				tn_voice_encoder_destroy(mEncoder);
		}

		void Free(Speaker speaker)
		{
			if (speaker.stream != null)
				Audio.tn_audio_source_destroy(speaker.stream);
			if (speaker.decoder != null)
				tn_voice_decoder_destroy(speaker.decoder);
			delete speaker;
		}

		int32 LocalId => mNetwork != null ? Math.Max(mNetwork.LocalClientId, 0) : 0;
		/// True when this machine has a player in a session that others can hear.
		public bool CanSend => mNetwork != null && mNetwork.LocalClientId >= 0 && (mNetwork.IsServer || mNetwork.IsConnected);

		public bool IsSpeaking(int32 clientId)
		{
			if (mNetwork != null && clientId == mNetwork.LocalClientId)
				return mTransmitting;
			return mSpeakers.TryGetValue(clientId, let speaker) && speaker.speaking;
		}

		/// How many frames of that player's speech have been played here.
		public int32 FramesHeard(int32 clientId) => mSpeakers.TryGetValue(clientId, let speaker) ? speaker.frames : 0;

		/// Samples of that player's speech waiting to be played.
		public int32 Queued(int32 clientId) => mSpeakers.TryGetValue(clientId, let speaker) && speaker.stream != null ? tn_audio_stream_queued(speaker.stream) : 0;

		public void Mute(int32 clientId, bool muted)
		{
			if (muted)
				mMuted.Add(clientId);
			else
				mMuted.Remove(clientId);
		}

		public bool IsMuted(int32 clientId) => mMuted.Contains(clientId);
		public float GetPlayerVolume(int32 clientId) => mVolumes.TryGetValue(clientId, let volume) ? volume : 1;
		public void SetPlayerVolume(int32 clientId, float volume)
		{
			mVolumes[clientId] = Math.Clamp(volume, 0, 4);
			if (mSpeakers.TryGetValue(clientId, let speaker) && speaker.stream != null)
				Place(clientId, speaker);
		}

		/// Takes microphone samples (mono, 48 kHz, -1 to 1). The engine calls this with what the microphone
		/// records; a game can call it too, to send sound of its own as this player's voice.
		public void Capture(Span<float> samples)
		{
			mPending.AddRange(samples);
			int start = 0;
			while (mPending.Count - start >= FrameSize)
			{
				Frame(.(mPending.Ptr + start, FrameSize));
				start += FrameSize;
			}
			if (start > 0)
				mPending.RemoveRange(0, start);
		}

		void Frame(Span<float> frame)
		{
			const float frameSeconds = (float)FrameSize / SampleRate;
			double sum = 0;
			let gain = Math.Max(MicrophoneVolume, 0);
			for (var sample in ref frame)
			{
				sample = Math.Clamp(sample * gain, -1, 1);
				sum += sample * sample;
			}
			mLevel = (float)Math.Sqrt(sum / FrameSize);
			bool send;
			if (!Enabled || Muted)
				send = false;
			else if (PushToTalk)
				send = TalkHeld;
			else
			{
				if (mLevel >= Activation)
					mHold = Math.Max(ReleaseTime, 0);
				send = mHold > 0;
				mHold = Math.Max(mHold - frameSeconds, 0);
			}
			if (!(CanSend || (mNetwork == null && Loopback)))
				send = false;
			mTransmitting = send;
			if (!send)
				return;
			let bitrate = Math.Clamp(Bitrate, 6000, 128000);
			if (mEncoder == null)
			{
				mEncoder = tn_voice_encoder_create(bitrate);
				mEncoderBitrate = bitrate;
			}
			else if (mEncoderBitrate != bitrate)
			{
				tn_voice_encoder_bitrate(mEncoder, bitrate);
				mEncoderBitrate = bitrate;
			}
			uint8[MaxPacket] packet = ?;
			let length = tn_voice_encode(mEncoder, frame.Ptr, &packet, MaxPacket);
			if (length <= 0)
				return;
			mSequence++;
			FramesSent++;
			BytesSent += length;
			let data = Span<uint8>(&packet, length);
			if (Loopback)
				Play(LocalId, mSequence, data, true);
			if (mNetwork == null)
				return;
			if (mNetwork.IsServer)
				Relay(LocalId, mSequence, data);
			else
			{
				mPayload.Clear();
				mPayload.Write(mSequence);
				mPayload.Write((uint16)length);
				mPayload.Data.AddRange(data);
				mNetwork.SendToServer(MsgVoice, mPayload, false);
			}
		}

		/// Server: whether listener should hear speaker under the team and distance rules.
		public bool Allowed(int32 speaker, int32 listener)
		{
			if (speaker == listener)
				return false;
			if (!TeamOnly && !Proximity)
				return true;
			let from = mNetwork.PlayerObject(speaker);
			let to = mNetwork.PlayerObject(listener);
			if (from == null || to == null)
				return true;
			if (TeamOnly)
			{
				let a = from.GetComponent<NetworkIdentity>().team, b = to.GetComponent<NetworkIdentity>().team;
				if (a != 0 && b != 0 && a != b)
					return false;
			}
			// A little beyond the audible range, so a voice fades out rather than cutting off.
			if (Proximity && MaxDistance > 0 && Vector3.Distance(from.Transform.Position, to.Transform.Position) > MaxDistance * 1.1f)
				return false;
			return true;
		}

		/// Server: passes one player's speech on to the players who should hear it.
		public void Relay(int32 speaker, uint16 sequence, Span<uint8> data)
		{
			if (mNetwork == null || !mNetwork.IsServer || !Enabled)
				return;
			// 50 frames a second is normal; anything far beyond that is not a microphone.
			mRate.TryGetValue(speaker, var count);
			if (++count > 75)
				return;
			mRate[speaker] = count;
			mPayload.Clear();
			mPayload.Write(speaker);
			mPayload.Write(sequence);
			mPayload.Write((uint16)data.Length);
			mPayload.Data.AddRange(data);
			List<int32> clients = scope .();
			mNetwork.GetClientIds(clients);
			for (let client in clients)
			{
				if (Allowed(speaker, client))
					mNetwork.SendToClient(client, MsgVoice, mPayload, false);
			}
			FramesRelayed++;
			if (mNetwork.LocalClientId == 0 && speaker != 0 && Allowed(speaker, 0))
				Receive(speaker, sequence, data);
		}

		/// Plays a frame of another player's speech.
		public void Receive(int32 speaker, uint16 sequence, Span<uint8> data)
		{
			if (speaker == LocalId && mNetwork != null && mNetwork.LocalClientId >= 0)
				return;
			Play(speaker, sequence, data, false);
		}

		void Play(int32 id, uint16 sequence, Span<uint8> data, bool own)
		{
			if (!Enabled || Audio.Disabled || data.Length <= 0 || data.Length > MaxPacket)
				return;
			if (!own && (Deafened || mMuted.Contains(id)))
				return;
			if (!mSpeakers.TryGetValue(id, var speaker))
			{
				if (mSpeakers.Count >= 64)
					return;
				speaker = new Speaker();
				mSpeakers[id] = speaker;
			}
			if (speaker.heard)
			{
				// Late or repeated packets are dropped; the gap they left has already been filled in.
				let ahead = (int16)(sequence - speaker.lastSequence);
				if (ahead <= 0)
					return;
				if (speaker.decoder != null && speaker.stream != null && ahead > 1 && ahead <= 4)
				{
					float[FrameSize] fill = ?;
					// Frames that never arrived: guessed from what came before, except the one just before this
					// packet, which this packet carries a low-quality copy of.
					for (int missing = ahead - 1; missing >= 1; missing--)
					{
						int32 got;
						if (missing == 1)
							got = tn_voice_decode(speaker.decoder, data.Ptr, (int32)data.Length, &fill, 1);
						else
							got = tn_voice_decode(speaker.decoder, null, 0, &fill, 0);
						if (got > 0)
						{
							speaker.leveler.Process(.(&fill, got));
							tn_audio_stream_push(speaker.stream, &fill, got);
						}
					}
				}
			}
			speaker.lastSequence = sequence;
			speaker.heard = true;
			if (speaker.decoder == null)
				speaker.decoder = tn_voice_decoder_create();
			let positioned = Proximity && !own;
			if (speaker.stream != null && speaker.positioned != positioned)
			{
				Audio.tn_audio_source_destroy(speaker.stream);
				speaker.stream = null;
			}
			if (speaker.stream == null)
			{
				if (!Audio.Start())
					return;
				speaker.stream = tn_audio_stream_create((int32)AudioGroup.Voice, positioned ? 1 : 0);
				speaker.positioned = positioned;
				if (speaker.stream != null)
				{
					Place(id, speaker);
					Audio.tn_audio_source_play(speaker.stream, 0);
				}
			}
			if (speaker.decoder == null || speaker.stream == null)
				return;
			float[FrameSize] samples = ?;
			let got = tn_voice_decode(speaker.decoder, data.Ptr, (int32)data.Length, &samples, 0);
			if (got <= 0)
				return;
			speaker.leveler.Process(.(&samples, got));
			tn_audio_stream_push(speaker.stream, &samples, got);
			speaker.frames++;
			speaker.silence = 0;
		}

		void Place(int32 id, Speaker speaker)
		{
			var parameters = Audio.Defaults();
			parameters.volume = Math.Max(Volume, 0) * GetPlayerVolume(id);
			parameters.spatial = speaker.positioned ? 1 : 0;
			parameters.doppler = 0;
			if (speaker.positioned)
			{
				parameters.minDistance = Math.Max(MinDistance, 0.01f);
				parameters.maxDistance = Math.Max(MaxDistance, parameters.minDistance + 0.01f);
				parameters.rolloffModel = (int32)AudioRolloff.Linear;
				parameters.reverbSend = Audio.ReverbLevel;
				let player = mNetwork?.PlayerObject(id);
				parameters.position = player != null ? player.Transform.Position + Vector3(0, 0.6f, 0) : Audio.ListenerPosition;
			}
			Audio.tn_audio_source_set(speaker.stream, &parameters);
			if (speaker.positioned)
			{
				Audio.DirectionTo(parameters.position, let azimuth, let elevation);
				Audio.tn_audio_source_direction(speaker.stream, azimuth, elevation);
			}
		}

		public void Update(Scene scene, float deltaTime)
		{
			mRateWindow += deltaTime;
			if (mRateWindow >= 1)
			{
				mRateWindow = 0;
				mRate.Clear();
			}
			if (!Enabled)
				mTransmitting = false;
			if (mTransmitting != mSaidTransmitting && mNetwork != null && mNetwork.LocalClientId >= 0)
			{
				mSaidTransmitting = mTransmitting;
				OnSpeakingChanged(mNetwork.LocalClientId, mTransmitting);
			}
			List<int32> gone = scope .();
			for (let (id, speaker) in mSpeakers)
			{
				speaker.silence += deltaTime;
				let speaking = speaker.silence < 0.3f;
				if (speaking != speaker.speaking)
				{
					speaker.speaking = speaking;
					OnSpeakingChanged(id, speaking);
				}
				if (speaker.stream != null)
					Place(id, speaker);
				// Someone who has said nothing for a while gives their decoder and sound back.
				if (speaker.silence > 20 || !Enabled)
					gone.Add(id);
			}
			for (let id in gone)
			{
				if (mSpeakers.GetAndRemove(id) case .Ok(let pair))
				{
					if (pair.value.speaking)
						OnSpeakingChanged(id, false);
					Free(pair.value);
				}
			}
		}
	}
}
