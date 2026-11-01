using System;
using System.Collections;
using System.Threading;
using Tallow;

namespace VoiceTests;

/// Voice chat across a host and two clients in one process, with no microphone and no sound card: speech is
/// handed in as samples, and what would be played is counted and measured.
class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static GameObject CreatePlayer(Scene scene)
	{
		let player = scene.CreateGameObject("Player");
		player.AddComponent<NetworkIdentity>();
		return player;
	}

	static List<Scene> sScenes = new .() ~ delete _;
	static void Pump(int ticks)
	{
		for (int i < ticks)
		{
			Time.UnscaledDeltaTime = 0.02f;
			for (let scene in sScenes)
			{
				scene.FixedUpdate();
				scene.Update();
			}
			Thread.Sleep(1);
		}
	}

	static float sPhase;
	/// Has that machine say a tone for a number of 20 ms frames, at real-time pace.
	static void Speak(Scene scene, int frames, float loudness = 0.3f, float hertz = 440)
	{
		float[VoiceChat.FrameSize] frame = ?;
		for (int f < frames)
		{
			for (int i < VoiceChat.FrameSize)
			{
				frame[i] = Math.Sin(sPhase) * loudness;
				sPhase += hertz * Math.PI_f * 2 / VoiceChat.SampleRate;
			}
			Scene.Active = scene;
			scene.Network.Voice.Capture(frame);
			Pump(1);
		}
		Pump(6);
	}

	static bool TestLeveling()
	{
		bool ok = true;
		let quiet = scope VoiceChat.VoiceLeveler();
		let loud = scope VoiceChat.VoiceLeveler();
		float[VoiceChat.FrameSize] a = ?, b = ?;
		for (int f < 100)
		{
			for (int i < VoiceChat.FrameSize)
			{
				let wave = Math.Sin((float)i * 0.1f);
				a[i] = wave * 0.025f;
				b[i] = wave * 0.6f;
			}
			quiet.Process(a);
			loud.Process(b);
		}
		double energyA = 0, energyB = 0;
		for (int i < VoiceChat.FrameSize)
		{
			energyA += a[i] * a[i];
			energyB += b[i] * b[i];
		}
		ok &= Check(energyA > 10 && Math.Abs(energyA - energyB) < 0.1, "quiet and loud microphones converge to the same audible level");
		for (int i < VoiceChat.FrameSize)
			a[i] = i == 100 ? 1 : 0;
		quiet.Process(a);
		ok &= Check(a[100] <= 0.951f, "a sudden peak after quiet speech stays below the ceiling");
		for (int i < VoiceChat.FrameSize)
			a[i] = 0;
		quiet.Process(a);
		ok &= Check(a[100] == 0, "silence stays silent");
		VoiceChat.AutoLevel = false;
		let raw = scope VoiceChat.VoiceLeveler();
		for (int i < VoiceChat.FrameSize)
			a[i] = 0.04f;
		raw.Process(a);
		ok &= Check(Math.Abs(a[100] - 0.04f) < 0.00001f, "automatic leveling can be disabled");
		VoiceChat.AutoLevel = true;
		return ok;
	}

	public static int Main(String[] args)
	{
		Time.DeltaTime = Time.FixedDeltaTime;
		Audio.NoDevice = true;
		bool ok = TestLeveling();
		NetworkManager.RegisterPrefab("VoicePlayer", new => CreatePlayer);
		let port = (uint16)(48000 + (DateTime.Now.Ticks / 10000) % 900);
		let host = scope Scene();
		let a = scope Scene();
		let b = scope Scene();
		for (let scene in Scene[?](host, a, b))
		{
			scene.StartPlay();
			scene.Network = new NetworkManager(scene);
			scene.Network.PlayerPrefab.Set("VoicePlayer");
			scene.Network.TeamCount = 2;
		}
		ok &= Check(!VoiceChat.Enabled && !VoiceChat.PushToTalk && VoiceChat.PushToTalkKey == .V, "voice chat is off until the game turns it on");
		host.Network.StartServer(port, true);
		sScenes.Add(host);
		a.Network.StartClient("127.0.0.1", port);
		sScenes.Add(a);
		Pump(40);
		b.Network.StartClient("127.0.0.1", port);
		sScenes.Add(b);
		Pump(60);
		let idA = a.Network.LocalClientId, idB = b.Network.LocalClientId;
		let voiceHost = host.Network.Voice, voiceA = a.Network.Voice, voiceB = b.Network.Voice;
		voiceB.SetPlayerVolume(idA, 2);
		ok &= Check(voiceB.GetPlayerVolume(idA) == 2 && voiceHost.GetPlayerVolume(idA) == 1, "individual volume belongs to the listening session");
		voiceB.SetPlayerVolume(idA, 1);
		ok &= Check(idA > 0 && idB > 0 && idA != idB && host.Network.PlayerObject(idA) != null && b.Network.PlayerObject(idA) != null && host.Network.PlayerObject(0) != null, "three machines are in the session, each with a character");

		Speak(a, 25);
		ok &= Check(voiceA.FramesSent == 0 && voiceB.FramesHeard(idA) == 0 && !VoiceChat.MicrophoneOpen, "while it is off nothing is sent and no microphone is opened");

		// ---- open microphone ----
		VoiceChat.Enabled = true;
		int32 started = 0, stopped = 0;
		VoiceChat.SpeakingHandler listener = scope [&] (id, speaking) =>
			{
				if (id == idA)
				{
					if (speaking)
						started++;
					else
						stopped++;
				}
			};
		VoiceChat.OnSpeakingChanged.Add(listener);
		Speak(a, 50);
		ok &= Check(voiceA.FramesSent == 50 && voiceHost.FramesHeard(idA) >= 45 && voiceB.FramesHeard(idA) >= 45, scope $"a client's speech reaches the host and the other client ({voiceA.FramesSent} frames sent, {voiceHost.FramesHeard(idA)} and {voiceB.FramesHeard(idA)} heard)");
		ok &= Check(voiceA.FramesHeard(idA) == 0, "and is not played back to the speaker");
		let perFrame = voiceA.BytesSent / Math.Max(voiceA.FramesSent, 1);
		ok &= Check(perFrame > 10 && perFrame < 90, scope $"compressed to about {perFrame} bytes a frame ({perFrame * 50 / 1024f:0.0} KB/s; uncompressed would be 94 KB/s)");
		{
			Scene.Active = b;
			ok &= Check(VoiceChat.IsSpeaking(idA) && !VoiceChat.IsSpeaking(0), "the listener can tell who is speaking");
			// What comes out of the speakers: a 440 Hz tone again, at a sensible level.
			float[] mix = scope .[2400 * 2];
			let got = Audio.Render(mix);
			double sum = 0;
			int crossings = 0;
			float least = 1;
			for (int block < got / 240)
			{
				float peak = 0;
				for (int i < 240)
					peak = Math.Max(peak, Math.Abs(mix[(block * 240 + i) * 2]));
				least = Math.Min(least, peak);
			}
			for (int i = 1; i < got; i++)
			{
				sum += mix[i * 2] * mix[i * 2];
				if ((mix[i * 2] >= 0) != (mix[(i - 1) * 2] >= 0))
					crossings++;
			}
			let loud = (float)Math.Sqrt(sum / Math.Max(got, 1));
			let pitch = crossings * 0.5f * VoiceChat.SampleRate / Math.Max(got, 1);
			ok &= Check(loud > 0.05f && pitch > 400 && pitch < 480 && least > 0.2f, scope $"what is played is the tone that was spoken, without gaps (level {loud:0.000}, pitch {pitch:0} Hz for 440 spoken)");
		}
		Pump(30);
		ok &= Check(started >= 1 && stopped >= 1 && !voiceB.IsSpeaking(idA), "speaking starts and stops are reported");
		VoiceChat.OnSpeakingChanged.Remove(listener);

		Speak(a, 30, 0.004f); // the tail after the last loud word is still sent; let it run out
		var before = voiceB.FramesHeard(idA);
		var sent = voiceA.FramesSent;
		Speak(a, 30, 0.004f);
		ok &= Check(voiceA.FramesSent == sent && voiceB.FramesHeard(idA) == before && voiceA.Level > 0 && voiceA.Level < VoiceChat.Activation, "an open microphone sends nothing while the room is quieter than the activation level");
		before = voiceA.FramesHeard(0);
		Speak(host, 30);
		ok &= Check(voiceA.FramesHeard(0) - before >= 27 && voiceB.FramesHeard(0) >= 27, "the host's own voice reaches the clients");

		// ---- push to talk ----
		VoiceChat.PushToTalk = true;
		VoiceChat.PushToTalkKey = .T;
		sent = voiceA.FramesSent;
		Speak(a, 30);
		ok &= Check(voiceA.FramesSent == sent && !voiceA.Transmitting, "with push to talk on, speech is not sent until the key is held");
		VoiceChat.Talk = true;
		before = voiceB.FramesHeard(idA);
		Speak(a, 30);
		ok &= Check(voiceA.FramesSent == sent + 30 && voiceB.FramesHeard(idA) - before >= 27, "and is sent while it is held");
		VoiceChat.Talk = false;
		sent = voiceA.FramesSent;
		Speak(a, 10);
		ok &= Check(voiceA.FramesSent == sent, "and stops the moment it is let go");
		VoiceChat.PushToTalk = false;

		// ---- muting ----
		VoiceChat.Muted = true;
		sent = voiceA.FramesSent;
		Speak(a, 20);
		ok &= Check(voiceA.FramesSent == sent, "muting yourself stops your microphone being sent");
		VoiceChat.Muted = false;
		voiceB.Mute(idA, true);
		before = voiceB.FramesHeard(idA);
		var hostBefore = voiceHost.FramesHeard(idA);
		Speak(a, 30);
		ok &= Check(voiceB.FramesHeard(idA) == before && voiceHost.FramesHeard(idA) - hostBefore >= 27 && voiceB.IsMuted(idA), "muting one player silences them on your machine only");
		voiceB.Mute(idA, false);

		// ---- teams ----
		int32 Team(int32 id) => host.Network.PlayerObject(id).GetComponent<NetworkIdentity>().team;
		VoiceChat.TeamOnly = true;
		ok &= Check(Team(0) == Team(idB) && Team(idA) != Team(0) && Team(idA) != 0, scope $"the host and the second client share a team; the first client is on the other (teams {Team(0)}, {Team(idA)}, {Team(idB)})");
		before = voiceB.FramesHeard(idA);
		hostBefore = voiceHost.FramesHeard(idA);
		Speak(a, 30);
		ok &= Check(voiceB.FramesHeard(idA) == before && voiceHost.FramesHeard(idA) == hostBefore, "team only: the other team hears nothing");
		before = voiceHost.FramesHeard(idB);
		let aBefore = voiceA.FramesHeard(idB);
		Speak(b, 30);
		ok &= Check(voiceHost.FramesHeard(idB) - before >= 27 && voiceA.FramesHeard(idB) == aBefore, "and a teammate hears every word");
		VoiceChat.TeamOnly = false;

		// ---- proximity ----
		VoiceChat.Proximity = true;
		VoiceChat.MaxDistance = 30;
		// Characters are placed where the server says, so set them there.
		void PlaceAll(int32 id, Vector3 position)
		{
			for (let scene in sScenes)
			{
				let player = scene.Network.PlayerObject(id);
				if (player != null)
					player.Transform.Position = position;
			}
		}
		float[VoiceChat.FrameSize] tone = ?;
		int32 SpeakAt(Vector3 speakerAt)
		{
			let start = voiceB.FramesHeard(idA);
			for (int f < 30)
			{
				PlaceAll(idA, speakerAt);
				PlaceAll(idB, .(0, 0, 0));
				PlaceAll(0, .(0, 0, 500));
				for (int i < VoiceChat.FrameSize)
				{
					tone[i] = Math.Sin(sPhase) * 0.3f;
					sPhase += 440 * Math.PI_f * 2 / VoiceChat.SampleRate;
				}
				Scene.Active = a;
				voiceA.Capture(tone);
				Pump(1);
			}
			for (int i < 6)
			{
				PlaceAll(idA, speakerAt);
				PlaceAll(idB, .(0, 0, 0));
				PlaceAll(0, .(0, 0, 500));
				Pump(1);
			}
			return voiceB.FramesHeard(idA) - start;
		}
		hostBefore = voiceHost.FramesHeard(idA);
		let near = SpeakAt(.(5, 0, 0));
		ok &= Check(near >= 27 && voiceHost.FramesHeard(idA) == hostBefore, scope $"proximity: a player 5 m away hears ({near} frames), one 500 m away is sent nothing");
		let far = SpeakAt(.(200, 0, 0));
		ok &= Check(far == 0, "and nobody hears a speaker who is out of range");
		VoiceChat.Proximity = false;

		// ---- a bad network and bad clients ----
		NetworkManager.SimulatedLossPercent = 20;
		before = voiceB.FramesHeard(idA);
		Speak(a, 100);
		NetworkManager.SimulatedLossPercent = 0;
		let through = voiceB.FramesHeard(idA) - before;
		ok &= Check(through >= 40 && through < 100, scope $"with a fifth of packets lost each way, speech carries on ({through} of 100 frames arrived, the gaps filled in)");
		Pump(60);
		let relayed = voiceHost.FramesRelayed;
		{
			float[VoiceChat.FrameSize] frame = ?;
			for (int i < VoiceChat.FrameSize)
				frame[i] = Math.Sin(i * 0.06f) * 0.3f;
			Scene.Active = a;
			for (int f < 400)
				voiceA.Capture(frame); // eight seconds of speech in one instant
			Pump(20);
		}
		ok &= Check(voiceHost.FramesRelayed - relayed <= 76, scope $"a client flooding the server is cut off ({voiceHost.FramesRelayed - relayed} of 400 frames passed on)");
		Pump(60);
		{
			let junk = scope NetWriter();
			junk.Write((uint16)1);
			junk.Write((uint16)5000);
			for (int i < 40)
				junk.Write((uint8)i);
			a.Network.SendToServer(VoiceChat.MsgVoice, junk, true);
			let noise = scope NetWriter();
			noise.Write((uint16)2);
			noise.Write((uint16)40);
			for (int i < 40)
				noise.Write((uint8)(i * 37));
			a.Network.SendToServer(VoiceChat.MsgVoice, noise, true);
			Pump(20);
			before = voiceB.FramesHeard(idA);
			Speak(a, 20);
			ok &= Check(voiceB.FramesHeard(idA) - before >= 15, "malformed and garbage packets are survived, and speech continues after them");
		}

		// ---- options and the microphone test ----
		VoiceChat.Deafened = true;
		before = voiceB.FramesHeard(idA);
		Speak(a, 20);
		ok &= Check(voiceB.FramesHeard(idA) == before, "deafen stops other voices being played");
		VoiceChat.Deafened = false;
		VoiceChat.Enabled = false;
		Pump(5);
		sent = voiceA.FramesSent;
		Speak(a, 10);
		ok &= Check(voiceA.FramesSent == sent && voiceB.FramesHeard(idA) == 0, "turning voice chat off mid-game stops it and frees the voices");

		for (let scene in sScenes)
		{
			scene.Network.Stop();
			delete scene.Network;
			scene.Network = null;
		}
		sScenes.Clear();
		{
			let alone = scope Scene();
			alone.StartPlay();
			VoiceChat.Enabled = true;
			VoiceChat.Loopback = true;
			Time.UnscaledDeltaTime = 0.02f;
			alone.Update();
			let local = VoiceChat.Current;
			float[VoiceChat.FrameSize] frame = ?;
			for (int i < VoiceChat.FrameSize)
				frame[i] = Math.Sin(i * 0.06f) * 0.3f;
			if (local != null)
			{
				for (int f < 10)
					local.Capture(frame);
			}
			ok &= Check(local != null && local.FramesHeard(0) == 10 && VoiceChat.MicrophoneLevel > 0.1f, "the microphone test plays your own voice back with no session");
			VoiceChat.Loopback = false;
			VoiceChat.Enabled = false;
			alone.Update();
			ok &= Check(VoiceChat.Current == null, "and ends when it is switched off");
		}
		Console.WriteLine(scope $"INFO: this machine reports a microphone: {VoiceChat.HasMicrophone} (counted, not opened)");
		VoiceChat.Shutdown();
		Audio.Shutdown();
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
