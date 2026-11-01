using System;
using System.Collections;
using System.IO;
using Tallow;

namespace AudioTests;

/// Listens to the engine's own mix with no sound card: sounds are rendered into a buffer and measured.
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	const String cFolder = "/tmp/tallow-audio-test";

	/// Writes a mono 16-bit WAV: a tone, or noise when frequency is 0.
	static void WriteWav(StringView name, float seconds, float frequency)
	{
		let rate = 48000;
		let count = (int)(seconds * rate);
		List<uint8> bytes = scope .();
		void U32(uint32 v)
		{
			for (int s = 0; s < 32; s += 8)
				bytes.Add((uint8)(v >> s));
		}
		void U16(uint16 v)
		{
			bytes.Add((uint8)v);
			bytes.Add((uint8)(v >> 8));
		}
		void Tag(StringView t)
		{
			for (let c in t.RawChars)
				bytes.Add((uint8)c);
		}
		Tag("RIFF");
		U32((uint32)(36 + count * 2));
		Tag("WAVE");
		Tag("fmt ");
		U32(16);
		U16(1);
		U16(1);
		U32((uint32)rate);
		U32((uint32)rate * 2);
		U16(2);
		U16(16);
		Tag("data");
		U32((uint32)count * 2);
		uint32 seed = 12345;
		for (int i < count)
		{
			float sample;
			if (frequency > 0)
				sample = Math.Sin(i * frequency * Math.PI_f * 2 / rate);
			else
			{
				seed = seed * 1664525 + 1013904223;
				sample = ((seed >> 8) & 0xFFFF) / 32768.0f - 1;
			}
			U16((uint16)(int16)(sample * 20000));
		}
		File.WriteAll(scope $"{cFolder}/{name}" , bytes).IgnoreError();
	}

	static Scene sScene;
	/// Advances the scene and listens for a while; returns loudness (RMS) of the left and right channels.
	static void Listen(float seconds, out float left, out float right, out float bright)
	{
		double l = 0, r = 0, high = 0;
		int frames = 0;
		float previous = 0;
		float[] buffer = scope .[4800 * 2];
		for (int block = 0; block < (int)Math.Ceiling(seconds * 10); block++)
		{
			Time.UnscaledDeltaTime = 0.1f;
			Time.DeltaTime = 0.1f;
			sScene.Update();
			let got = Audio.Render(buffer);
			for (int i < got)
			{
				l += buffer[i * 2] * buffer[i * 2];
				r += buffer[i * 2 + 1] * buffer[i * 2 + 1];
				// Sample-to-sample change is a simple measure of how much treble there is.
				let mono = (buffer[i * 2] + buffer[i * 2 + 1]) * 0.5f;
				high += (mono - previous) * (mono - previous);
				previous = mono;
			}
			frames += got;
		}
		left = frames > 0 ? (float)Math.Sqrt(l / frames) : 0;
		right = frames > 0 ? (float)Math.Sqrt(r / frames) : 0;
		bright = frames > 0 ? (float)Math.Sqrt(high / frames) : 0;
	}

	static float Loudness(float seconds)
	{
		Listen(seconds, let l, let r, let b);
		return (l + r) * 0.5f;
	}

	/// Listens for a moment and reports, besides loudness and treble, how many samples later the sound reaches the
	/// left ear than the right (negative when the left ear hears it first).
	static void Hear(out float left, out float right, out float treble, out int leftLag)
	{
		Listen(0.2f, out left, out right, out treble); // let the direction settle
		float[] buffer = scope .[4800 * 2];
		Time.UnscaledDeltaTime = 0.1f;
		sScene.Update();
		let got = Audio.Render(buffer);
		double l = 0, r = 0, high = 0;
		float previous = 0;
		for (int i < got)
		{
			l += buffer[i * 2] * buffer[i * 2];
			r += buffer[i * 2 + 1] * buffer[i * 2 + 1];
			let mono = (buffer[i * 2] + buffer[i * 2 + 1]) * 0.5f;
			high += (mono - previous) * (mono - previous);
			previous = mono;
		}
		left = (float)Math.Sqrt(l / got);
		right = (float)Math.Sqrt(r / got);
		// Treble as a share of loudness, so that it describes colour, not level.
		treble = (float)Math.Sqrt(high / got) / Math.Max((left + right) * 0.5f, 0.00001f);
		double best = -1;
		leftLag = 0;
		for (int lag = -60; lag <= 60; lag++)
		{
			double sum = 0;
			for (int i = 60; i < got - 60; i++)
				sum += (double)buffer[(i + lag) * 2] * buffer[i * 2 + 1];
			if (sum > best)
			{
				best = sum;
				leftLag = lag;
			}
		}
	}

	static AudioSource Source(StringView clip, Vector3 position, bool loop = true)
	{
		let go = sScene.CreateGameObject("Source");
		go.Transform.Position = position;
		let source = go.AddComponent<AudioSource>();
		source.audioClip.Set(clip);
		source.loop = loop;
		source.playOnStart = false;
		source.doppler = 0;
		source.airAbsorption = false;
		source.occlusion = false;
		return source;
	}

	public static int Main(String[] args)
	{
		Directory.CreateDirectory(cFolder).IgnoreError();
		Assets.ProjectPath.Set(cFolder);
		WriteWav("tone.wav", 1.0f, 440);
		WriteWav("noise.wav", 1.0f, 0);
		WriteWav("blip.wav", 0.2f, 880);
		Audio.NoDevice = true;
		bool ok = true;
		ok &= Check(!Audio.Hrtf && Audio.HrtfStrength == 1 && Audio.HrtfHeadSize == 1 && Audio.HrtfTreble == 0, "HRTF is off until the game turns it on");
		let scene = scope Scene();
		sScene = scene;
		Scene.Active = scene;
		scene.CreateGameObject("Ears").AddComponent<AudioListener>(); // at the origin, facing +Z
		scene.StartPlay();

		ok &= Check(!Audio.Ready && Loudness(0.2f) == 0, "nothing is opened and nothing is heard before the first sound");
		let right = Source("tone.wav", .(4, 0, 0));
		right.Play();
		ok &= Check(Audio.Ready && right.IsPlaying && Math.Abs(right.Length - 1.0f) < 0.02f, "playing a source starts the engine and loads the clip");
		float l, r, b;
		Listen(0.5f, out l, out r, out b);
		ok &= Check(r > 0.01f && r > l * 2, scope $"a source on the right is louder in the right ear (left {l:0.000}, right {r:0.000})");
		right.Transform.Position = .(-4, 0, 0);
		Listen(0.5f, out l, out r, out b);
		ok &= Check(l > 0.01f && l > r * 2, scope $"moved to the left, it is louder in the left ear (left {l:0.000}, right {r:0.000})");
		right.Transform.Position = .(0, 0, 4);
		Listen(0.3f, out l, out r, out b);
		let near = (l + r) * 0.5f;
		ok &= Check(Math.Abs(l - r) < near * 0.1f, "straight ahead it is the same in both ears");
		right.Transform.Position = .(0, 0, 30);
		let far = Loudness(0.3f);
		ok &= Check(far > 0 && far < near * 0.4f, scope $"further away it is quieter (near {near:0.000}, far {far:0.000})");
		right.rolloff = .Linear;
		right.maxDistance = 20;
		Loudness(0.1f); // changes are eased in over a few milliseconds; listen once they have settled
		ok &= Check(Loudness(0.3f) < 0.0005f, "with linear rolloff it is silent beyond the max distance");
		right.rolloff = .Inverse;
		right.maxDistance = 40;
		right.spatial = false;
		right.Transform.Position = .(50, 0, 0);
		Listen(0.3f, out l, out r, out b);
		ok &= Check(l > 0.05f && Math.Abs(l - r) < 0.001f, "a source that is not spatial is the same in both ears wherever it is");
		right.spatial = true;
		right.Transform.Position = .(0, 0, 4);

		// Volumes.
		let reference = Loudness(0.3f);
		right.volume = 0.5f;
		let half = Loudness(0.3f);
		right.volume = 1;
		Audio.SetGroupVolume(.Effects, 0);
		let groupMuted = Loudness(0.3f);
		Audio.SetGroupVolume(.Effects, 1);
		Audio.MasterVolume = 0;
		let masterMuted = Loudness(0.3f);
		Audio.MasterVolume = 1;
		ok &= Check(Math.Abs(half - reference * 0.5f) < reference * 0.1f && groupMuted < 0.0005f && masterMuted < 0.0005f && Loudness(0.3f) > reference * 0.9f, "source, group and master volume each scale what is heard");
		let music = Source("tone.wav", .(0, 0, 4));
		music.group = .Music;
		right.Stop();
		music.Play();
		Audio.SetGroupVolume(.Effects, 0);
		ok &= Check(Loudness(0.3f) > reference * 0.8f, "muting one group leaves another playing");
		Audio.SetGroupVolume(.Effects, 1);
		music.Stop();
		ok &= Check(!music.IsPlaying && !right.IsPlaying && Loudness(0.3f) < 0.0005f, "stopped sources are silent");

		// Looping and finishing.
		let once = Source("blip.wav", .(0, 0, 2), false);
		once.Play();
		let during = Loudness(0.1f);
		Loudness(0.4f);
		ok &= Check(during > 0.01f && !once.IsPlaying, "a sound that does not loop plays once and stops");
		once.loop = true;
		once.Play();
		Loudness(0.6f);
		ok &= Check(once.IsPlaying && Loudness(0.2f) > 0.01f, "a looping sound keeps going past its length");
		once.Stop();

		// One-off sounds overlap and clean up after themselves.
		once.PlayOneShot("blip.wav");
		Audio.PlayOneShot("blip.wav", .(1, 0, 2));
		Audio.PlayOneShot2D("blip.wav");
		let burst = Loudness(0.1f);
		ok &= Check(Audio.ActiveOneShots == 3 && burst > during, "one-off sounds play on top of each other");
		Loudness(0.5f);
		ok &= Check(Audio.ActiveOneShots == 0, "and are freed when they finish");
		let missing = Source("nope.wav", .(0, 0, 2));
		missing.Play();
		ok &= Check(!missing.IsPlaying && Loudness(0.1f) < 0.0005f, "a missing file is reported and nothing breaks");

		// Occlusion: a wall between the listener and the source muffles and quietens it.
		let hiss = Source("noise.wav", .(0, 0, 6));
		hiss.occlusion = true;
		hiss.Play();
		Listen(0.5f, out l, out r, out b);
		let openLoud = (l + r) * 0.5f;
		let openBright = b;
		let wall = scene.CreateGameObject("Wall");
		wall.Transform.Position = .(0, 0, 3);
		ShapeDesc slab = default;
		slab.kind = .Box;
		slab.halfExtents = .(4, 4, 0.2f);
		scene.Physics.CreateBody(wall.Transform, slab, null);
		scene.Physics.Step(1 / 60f);
		Listen(0.6f, out l, out r, out b);
		Listen(0.5f, out l, out r, out b);
		ok &= Check(hiss.Occlusion > 0.95f && (l + r) * 0.5f < openLoud * 0.7f && b < openBright * 0.5f, scope $"behind a wall a sound is quieter and duller (loudness {openLoud:0.000} to {(l + r) * 0.5f:0.000}, treble {openBright:0.000} to {b:0.000})");
		hiss.occlusion = false;
		Listen(0.3f, out l, out r, out b);
		ok &= Check(hiss.Occlusion == 0 && b > openBright * 0.8f, "with occlusion off the wall is ignored");
		hiss.Stop();

		// Air absorption: the same noise far away has less treble relative to its loudness.
		let distant = Source("noise.wav", .(0, 0, 2));
		distant.minDistance = 1;
		distant.maxDistance = 30;
		distant.Play();
		Listen(0.3f, out l, out r, out b);
		let closeRatio = b / Math.Max((l + r) * 0.5f, 0.00001f);
		distant.airAbsorption = true;
		distant.Transform.Position = .(0, 0, 28);
		wall.Transform.Position = .(0, -50, 0);
		scene.Physics.Step(1 / 60f);
		Listen(0.3f, out l, out r, out b);
		let farRatio = b / Math.Max((l + r) * 0.5f, 0.00001f);
		ok &= Check(farRatio < closeRatio * 0.8f, scope $"a distant sound is duller with air absorption on (treble share {closeRatio:0.00} to {farRatio:0.00})");
		distant.Stop();

		// Reverb zone: inside it, a short sound leaves a tail.
		let clap = Source("blip.wav", .(0, 0, 2), false);
		clap.Play();
		Loudness(0.3f);
		let dryTail = Loudness(0.3f);
		let zone = scene.CreateGameObject("Hall").AddComponent<AudioReverbZone>();
		zone.radius = 10;
		zone.fade = 2;
		zone.amount = 0.8f;
		zone.roomSize = 0.9f;
		Loudness(0.1f);
		clap.Play();
		Loudness(0.3f);
		let wetTail = Loudness(0.3f);
		ok &= Check(Audio.ReverbLevel > 0.7f && dryTail < 0.0005f && wetTail > 0.001f, scope $"inside a reverb zone a sound leaves an echo (tail {dryTail:0.0000} without, {wetTail:0.0000} with)");
		zone.Transform.Position = .(100, 0, 0);
		Loudness(0.1f);
		ok &= Check(Audio.ReverbLevel == 0 && Math.Abs(zone.WeightAt(.(100 + 9, 0, 0)) - 0.5f) < 0.01f && zone.WeightAt(.(100 + 11, 0, 0)) == 0, "the zone fades in across its edge and stops at its radius");

		// ---- headphone 3D (HRTF) ----
		zone.amount = 0;
		Loudness(3); // let the echo from the reverb zone die away
		let voice = Source("noise.wav", .(4, 0, 0));
		voice.Play();
		float t;
		int lag;
		Hear(out l, out r, out t, out lag);
		let panRight = r, panLeft = l;
		voice.Transform.Position = .(-4, 0, 0);
		Hear(out l, out r, out t, out lag);
		let panOtherSide = l;
		voice.Transform.Position = .(3, 0, 3);
		Hear(out l, out r, out t, out lag);
		let panLag = lag;
		voice.Transform.Position = .(0, 0, 4);
		Hear(out l, out r, out t, out lag);
		let panFront = t;
		let panFrontLoud = (l + r) * 0.5f;
		voice.Transform.Position = .(0, 0, -4);
		Hear(out l, out r, out t, out lag);
		let panBack = t;
		ok &= Check(panLeft < panRight * 0.15f && Math.Abs(panOtherSide - panRight) < panRight * 0.1f && panLag == 0 && Math.Abs(panFront - panBack) < panFront * 0.03f, scope $"with plain panning a side is only louder, both sides equally, with no delay between the ears, and front and back identical (right {panRight:0.000}, left {panOtherSide:0.000})");
		Audio.Hrtf = true;
		voice.Transform.Position = .(4, 0, 0);
		Hear(out l, out r, out t, out lag);
		let nearRight = r;
		ok &= Check(r > l * 2 && lag >= 15 && lag <= 45, scope $"with HRTF a sound on the right is louder in the right ear and reaches it first (left {l:0.000}, right {r:0.000}, left ear {lag} samples later)");
		voice.Transform.Position = .(-4, 0, 0);
		Hear(out l, out r, out t, out lag);
		ok &= Check(l > r * 2 && lag <= -15 && lag >= -45 && Math.Abs(l - nearRight) < nearRight * 0.1f, scope $"and the mirror image on the left (left {l:0.000}, right {r:0.000}, left ear {-lag} samples earlier)");
		voice.Transform.Position = .(0, 0, 4);
		Hear(out l, out r, out t, out lag);
		let front = t;
		let frontLoud = (l + r) * 0.5f;
		ok &= Check(Math.Abs(l - r) < frontLoud * 0.15f && Math.Abs(lag) <= 2 && frontLoud > panFrontLoud * 0.5f && frontLoud < panFrontLoud * 2, scope $"straight ahead it is equal in both ears, at about the level panning gives ({panFrontLoud:0.000} panned, {frontLoud:0.000} HRTF)");
		voice.Transform.Position = .(0, 0, -4);
		Hear(out l, out r, out t, out lag);
		let behind = t;
		voice.Transform.Position = .(0, 4, 0.01f);
		Hear(out l, out r, out t, out lag);
		let above = t;
		voice.Transform.Position = .(0, -3, 2.6f);
		Hear(out l, out r, out t, out lag);
		let below = t;
		ok &= Check(Math.Abs(front - behind) > front * 0.08f && Math.Abs(front - above) > front * 0.08f && Math.Abs(above - below) > above * 0.05f, scope $"in front, behind, above and below each have their own colour (treble share {front:0.00}, {behind:0.00}, {above:0.00}, {below:0.00})");
		// ---- tuning, as an options menu would ----
		voice.Transform.Position = .(4, 0, 0);
		Hear(out l, out r, out t, out lag);
		let normalLag = lag;
		let normalTreble = t;
		let normalFar = l / r;
		Audio.HrtfHeadSize = 1.5f;
		Hear(out l, out r, out t, out lag);
		let bigLag = lag;
		Audio.HrtfHeadSize = 0.5f;
		Hear(out l, out r, out t, out lag);
		let smallLag = lag;
		Audio.HrtfHeadSize = 1;
		ok &= Check(bigLag > normalLag + 8 && smallLag < normalLag - 8 && smallLag > 0, scope $"head size stretches and shrinks the delay between the ears ({smallLag}, {normalLag}, {bigLag} samples at 0.5, 1 and 1.5)");
		voice.Transform.Position = .(-4, 0, 0);
		Audio.HrtfHeadSize = 1.5f;
		Hear(out l, out r, out t, out lag);
		Audio.HrtfHeadSize = 1;
		ok &= Check(lag == -bigLag, scope $"and does the same on the other side ({lag})");
		voice.Transform.Position = .(4, 0, 0);
		Audio.HrtfTreble = 6;
		Hear(out l, out r, out t, out lag);
		let bright = t;
		Audio.HrtfTreble = -6;
		Hear(out l, out r, out t, out lag);
		let dull = t;
		Audio.HrtfTreble = 0;
		ok &= Check(bright > normalTreble * 1.03f && dull < normalTreble * 0.95f, scope $"treble brightens or dulls it (treble share {dull:0.00}, {normalTreble:0.00}, {bright:0.00} at -6, 0 and +6 dB)");
		Audio.HrtfStrength = 0.5f;
		Hear(out l, out r, out t, out lag);
		let halfFar = l / r;
		Audio.HrtfStrength = 0;
		Hear(out l, out r, out t, out lag);
		let noneFar = l / r;
		Audio.HrtfStrength = 1;
		ok &= Check(noneFar < 0.15f && halfFar > noneFar && halfFar < normalFar, scope $"strength blends between panning and full HRTF (far ear at {noneFar:0.00}, {halfFar:0.00}, {normalFar:0.00} of the near ear at 0, 0.5 and 1)");
		Audio.HrtfHeadSize = 9;
		Audio.HrtfTreble = 99;
		Audio.HrtfStrength = -3;
		ok &= Check(Audio.HrtfHeadSize == 1.5f && Audio.HrtfTreble == 12 && Audio.HrtfStrength == 0, "settings outside their range are clamped");
		Audio.HrtfHeadSize = 1;
		Audio.HrtfTreble = 0;
		Audio.HrtfStrength = 1;
		// A sound circling the head changes smoothly: no sample jumps far from its neighbours.
		{
			float[] buffer = scope .[480 * 2];
			float worst = 0, previous = 0;
			bool first = true;
			for (int step < 200)
			{
				let angle = step * 0.05f;
				voice.Transform.Position = .(Math.Sin(angle) * 4, 0, Math.Cos(angle) * 4);
				Time.UnscaledDeltaTime = 0.01f;
				sScene.Update();
				let got = Audio.Render(buffer);
				for (int i < got)
				{
					if (!first)
						worst = Math.Max(worst, Math.Abs(buffer[i * 2] - previous));
					previous = buffer[i * 2];
					first = false;
				}
			}
			// ... including while a player drags the sliders.
			for (int step < 100)
			{
				Audio.HrtfHeadSize = 0.5f + step * 0.01f;
				Audio.HrtfStrength = 1 - step * 0.005f;
				Audio.HrtfTreble = step * 0.06f;
				Time.UnscaledDeltaTime = 0.01f;
				sScene.Update();
				let got = Audio.Render(buffer);
				for (int i < got)
				{
					worst = Math.Max(worst, Math.Abs(buffer[i * 2] - previous));
					previous = buffer[i * 2];
				}
			}
			Audio.HrtfHeadSize = 1;
			Audio.HrtfTreble = 0;
			Audio.HrtfStrength = 1;
			ok &= Check(worst < 0.5f && worst > 0, scope $"a sound circling the listener glides between directions without clicks, also while the settings are dragged (largest step {worst:0.000})");
		}
		Audio.Hrtf = false;
		voice.Transform.Position = .(4, 0, 0);
		Hear(out l, out r, out t, out lag);
		ok &= Check(l < r * 0.05f, "HRTF can be switched off while a sound is playing");
		voice.spatial = false;
		Hear(out l, out r, out t, out lag);
		ok &= Check(voice.IsPlaying && Math.Abs(l - r) < 0.001f && l > 0.01f, "and a playing source can be switched from positioned to plain stereo");
		voice.Stop();

		// Without an Audio Listener, the camera is the listener.
		scene.DestroyImmediate(scene.Find("Ears"));
		let camera = scene.CreateGameObject("Camera");
		camera.AddComponent<Camera>();
		camera.Transform.Position = .(200, 0, 0);
		let nearCamera = Source("tone.wav", .(203, 0, 0));
		nearCamera.Play();
		Loudness(0.2f);
		Listen(0.3f, out l, out r, out b);
		ok &= Check((Audio.ListenerPosition - Vector3(200, 0, 0)).Length < 0.01f && r > l * 2, "with no Audio Listener the camera is the listener");

		Audio.Shutdown();
		for (let name in StringView[?]("tone.wav", "noise.wav", "blip.wav"))
			File.Delete(scope $"{cFolder}/{name}").IgnoreError();
		Directory.Delete(cFolder).IgnoreError();
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
