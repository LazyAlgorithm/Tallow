using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace SequencerTests;

/// The sequencer (docs/sequencer.md): reading and writing `.tsequence` files and the mistakes reported, easing,
/// finding a track's object, the Sequence Player offline (moving objects, camera shots and blends, showing and
/// hiding, sounds, subtitles, events, fades, pausing, skipping, looping, putting things back, saving), and a shared
/// sequence between a host and a client over loopback.
class Program
{
	static int sFailures;
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		if (!pass)
			sFailures++;
		return pass;
	}

	const String cFolder = "/tmp/tallow-sequencer-test";

	const String cIntro = """
		# The gate opens.
		sequence length 4 framerate 30
		track transform "Gate"
			key 0 position 0 0 0 rotation 0 0 0 ease linear
			key 2 position 0 4 0 rotation 0 90 0 scale 2 2 2
		track camera
			shot 0 "Shot Wide"
			shot 2 "Shot Close" blend 1 fov 40
		track active "Sparks"
			set 0 on
			set 3 off
		track subtitle
			line 0.5 "Guard" "Open the gate!" length 2
		track event
			event 2 GateOpened 3
			event 3.5 Done
		track audio
			sound 1 "Sounds/creak.wav" volume 0.5
		track fade color 0 0 0
			key 0 1 ease linear
			key 1 0
		""";

	static List<Scene> sScenes = new .() ~ delete _;
	static void Pump(int ticks)
	{
		for (int i < ticks)
		{
			Time.FrameCount++;
			for (let scene in sScenes)
			{
				scene.FixedUpdate();
				scene.Update();
			}
			Thread.Sleep(1);
		}
	}

	static GameObject CreatePlayer(Scene scene)
	{
		let player = scene.CreateGameObject("Player");
		player.AddComponent<NetworkIdentity>();
		return player;
	}

	/// A gate, two shots, sparks and a cutscene object, and the scene's own camera.
	static SequencePlayer BuildScene(Scene scene, bool shared)
	{
		scene.CreateGameObject("Main Camera").AddComponent<Camera>();
		scene.CreateGameObject("Gate");
		let wide = scene.CreateGameObject("Shot Wide");
		wide.Transform.Position = .(0, 5, -10);
		wide.AddComponent<Camera>().fieldOfView = 70;
		wide.GetComponent<Camera>().Enabled = false;
		let close = scene.CreateGameObject("Shot Close");
		close.Transform.Position = .(0, 2, -4);
		let sparks = scene.CreateGameObject("Sparks");
		sparks.SetActive(false);
		let cutscene = scene.CreateGameObject("Intro");
		let player = cutscene.AddComponent<SequencePlayer>();
		player.sequence.Set("Sequences/intro.tsequence");
		player.skippable = false;
		player.shared = shared;
		scene.StartPlay();
		return player;
	}

	static void Run(SequencePlayer player, float seconds)
	{
		let steps = (int)Math.Round(seconds / Time.DeltaTime);
		for (int i < steps)
		{
			Time.FrameCount++;
			player.Update();
		}
	}

	public static int Main(String[] args)
	{
		Directory.CreateDirectory(scope $"{cFolder}/Sequences").IgnoreError();
		Assets.ProjectPath.Set(cFolder);
		File.WriteAllText(scope $"{cFolder}/Sequences/intro.tsequence" , cIntro).IgnoreError();
		Time.DeltaTime = 0.05f;

		// ---- the file ----
		let asset = scope SequenceAsset();
		asset.Parse(cIntro);
		Check(asset.problems.IsEmpty, scope $"a good sequence reads with no problems ({asset.problems})");
		Check(asset.length == 4 && asset.frameRate == 30 && asset.tracks.Count == 7, "its length, frame rate and tracks are read");
		let gate = asset.tracks[0];
		Check(gate.kind == .Transform && gate.target == "Gate" && gate.keys.Count == 2 && gate.keys[1].position == Vector3(0, 4, 0) && gate.keys[1].euler.y == 90 && gate.keys[1].hasScale && !gate.keys[0].hasScale, "a transform track's keys have position, rotation and scale");
		let shots = asset.tracks[1];
		Check(shots.kind == .Camera && shots.target.IsEmpty && shots.keys[1].text == "Shot Close" && shots.keys[1].length == 1 && shots.keys[1].value == 40, "a camera shot has its object, blend and field of view");
		Check(asset.tracks[2].keys[1].value == 0 && asset.tracks[3].keys[0].line == "Open the gate!" && asset.tracks[4].keys[0].value == 3 && asset.tracks[5].keys[0].value == 0.5f, "show/hide, subtitle, event and sound keys are read");
		Check(asset.tracks[6].color == Color(0, 0, 0, 1) && asset.tracks[6].keys[0].ease == .Linear, "a fade track has its colour and each key its ease");
		let written = scope String();
		asset.Write(written);
		let again = scope SequenceAsset();
		again.Parse(written);
		let rewritten = scope String();
		again.Write(rewritten);
		Check(again.problems.IsEmpty && rewritten == written && again.tracks.Count == 7, "a sequence written out reads back the same");
		let broken = scope SequenceAsset();
		broken.Parse("""
			key 0
			track wobble "X"
			track transform "X"
			shot 1 "Y"
			track event
			event 1 Go colour 3
			""");
		Check(broken.problems.Contains("line 1") && broken.problems.Contains("line 2") && broken.problems.Contains("line 4") && broken.problems.Contains("line 6"), scope $"mistakes are reported by line:\n{broken.problems}");

		// ---- sampling ----
		Vector3 position, scale;
		Quaternion rotation;
		bool hasScale;
		gate.SamplePose(1, out position, out rotation, out scale, out hasScale);
		Check(Math.Abs(position.y - 2) < 0.001f && hasScale, "linear keys go evenly");
		gate.keys[0].ease = .Smooth;
		gate.SamplePose(0.5f, out position, out rotation, out scale, out hasScale);
		Check(Math.Abs(position.y - 4 * 0.15625f) < 0.001f, "smooth keys start slowly");
		gate.keys[0].ease = .Step;
		gate.SamplePose(1.9f, out position, out rotation, out scale, out hasScale);
		Check(position.y == 0, "step keys hold until the next");
		gate.SamplePose(-1, out position, out rotation, out scale, out hasScale);
		let before = position;
		gate.SamplePose(10, out position, out rotation, out scale, out hasScale);
		Check(before == Vector3.Zero && position == Vector3(0, 4, 0), "before the first key and after the last, the end keys hold");
		Check(Math.Abs(asset.tracks[6].SampleValue(0.5f) - 0.5f) < 0.001f && asset.tracks[6].SampleValue(3) == 0, "a fade eases between its keys");
		Check(asset.End == 4, "a sequence lasts its length, or to its last key if later");

		// ---- finding objects ----
		{
			let scene = scope Scene();
			let ship = scene.CreateGameObject("Ship");
			let hatch = scene.CreateGameObject("Hatch");
			hatch.Transform.SetParent(ship.Transform, false);
			let other = scene.CreateGameObject("Hatch");
			let owner = scene.CreateGameObject("Owner");
			let mine = scene.CreateGameObject("Hatch");
			mine.Transform.SetParent(owner.Transform, false);
			Check(SequenceEvaluator.Resolve(scene, owner, "Hatch") == mine && SequenceEvaluator.Resolve(scene, null, "Ship/Hatch") == hatch && SequenceEvaluator.Resolve(scene, owner, "") == owner, "a name is looked for under the player first, then by path in the scene");
			Check(SequenceEvaluator.Resolve(scene, null, "Hatch") != null && SequenceEvaluator.Resolve(scene, null, "Boat/Hatch") == null && other != null, "a path's parents must match");
		}

		// ---- the Sequence Player ----
		{
			Subtitles.Clear();
			let scene = scope Scene();
			let player = BuildScene(scene, false);
			let gateObject = scene.Find("Gate");
			let sparks = scene.Find("Sparks");
			let events = scope List<String>();
			defer ClearAndDeleteItems(events);
			int finished = 0;
			player.OnEvent.Add(new (name, value) => events.Add(new $"{name} {value}"));
			player.OnFinished.Add(new [&] () =>
				{
					finished++;
				}
				);
			Check(scene.ViewCamera == scene.Find("Main Camera").GetComponent<Camera>(), "before it plays, the game is seen through its own camera");
			Check(player.Play() && player.IsPlaying && SequencePlayer.PlayingCount == 1, "Play starts it");
			Check(scene.ViewCamera != null && scene.ViewCamera.GameObject.Name == "Sequence Camera" && scene.ViewCamera.Transform.Position == Vector3(0, 5, -10) && scene.ViewCamera.fieldOfView == 70, "the first shot is shown, with the shot camera's field of view");
			Check(sparks.ActiveSelf && player.Time == 0, "a show key at the start shows its object at once");
			Run(player, 1);
			Check(Math.Abs(gateObject.Transform.LocalPosition.y - 2) < 0.01f, "the gate moves along its keys");
			Check(Subtitles.Showing.Count == 1 && Subtitles.Showing[0].text == "Open the gate!" && Subtitles.Showing[0].speaker == "Guard", "a subtitle key shows its line");
			Run(player, 1.5f);
			let blended = scene.ViewCamera.Transform.Position;
			Check(events.Count == 1 && events[0] == "GateOpened 3", "an event key tells the game, with its number");
			Check(blended.z > -10 && blended.z < -4 && scene.ViewCamera.fieldOfView < 70 && scene.ViewCamera.fieldOfView > 40, "a shot with a blend moves the camera there from the shot before");
			Check(gateObject.Transform.LocalScale == Vector3(2, 2, 2) && Math.Abs(gateObject.Transform.LocalRotation.EulerAngles.y - 90) < 0.5f, "and the gate ends turned and grown");
			player.Pause();
			let paused = player.Time;
			Run(player, 1);
			Check(player.State == .Paused && player.Time == paused && SequencePlayer.PlayingCount == 0, "Pause holds it");
			player.Resume();
			Run(player, 0.6f);
			Check(!sparks.ActiveSelf, "a hide key hides its object");
			Run(player, 1);
			Check(player.State == .Finished && finished == 1 && events.Count == 2 && scene.ViewCamera.GameObject.Name == "Main Camera", "at the end it finishes, and the game is seen through its own camera again");
			Check(gateObject.Transform.LocalPosition.y == 4, "what it moved stays where it ended");

			// Skipping: events passed over still happen, everything ends where it would.
			ClearAndDeleteItems(events);
			player.Play();
			Run(player, 0.6f);
			Check(Subtitles.Showing.Count == 1, "(the subtitle is up again)");
			player.Skip();
			Check(player.State == .Finished && finished == 2 && events.Count == 2 && Subtitles.Showing.IsEmpty && gateObject.Transform.LocalPosition.y == 4 && !sparks.ActiveSelf, "Skip jumps to the end: events still happen, subtitles go, objects end in place");

			// Seeking: nothing in between happens.
			ClearAndDeleteItems(events);
			player.Seek(2.5f);
			Check(player.State == .Paused && events.IsEmpty && sparks.ActiveSelf && Math.Abs(player.Time - 2.5f) < 0.001f, "Seek moves it to a time without its events");
			player.Stop();
			Check(player.State == .Stopped && scene.ViewCamera.GameObject.Name == "Main Camera", "Stop ends it and gives the camera back");

			// Putting things back.
			player.restoreWhenDone = true;
			gateObject.Transform.LocalPosition = .(7, 0, 0);
			sparks.SetActive(false);
			let fresh = scope Scene();
			let restoring = BuildScene(fresh, false);
			restoring.restoreWhenDone = true;
			let freshGate = fresh.Find("Gate");
			freshGate.Transform.LocalPosition = .(7, 0, 0);
			restoring.Play();
			Run(restoring, 1);
			Check(freshGate.Transform.LocalPosition.x == 0, "(it moves the gate)");
			restoring.Stop();
			Check(freshGate.Transform.LocalPosition == Vector3(7, 0, 0) && !fresh.Find("Sparks").ActiveSelf, "with Restore When Done, what it moved and showed goes back");

			// Looping.
			let looping = scope Scene();
			let loops = BuildScene(looping, false);
			loops.loop = true;
			int loopEvents = 0;
			loops.OnEvent.Add(new [&] (name, value) =>
				{
					loopEvents++;
				}
				);
			loops.Play();
			Run(loops, 9);
			Check(loops.IsPlaying && loops.Time < 4 && loopEvents == 4, "a looping sequence starts again, with its events each time");
			loops.Stop();

			// The fade.
			let fading = scope Scene();
			let fades = BuildScene(fading, false);
			fades.Play();
			Run(fades, 0.25f);
			Check(Math.Abs(fades.ScreenFade - 0.75f) < 0.01f, "a fade track covers the screen as far as its keys say");
			Run(fades, 1);
			Check(fades.ScreenFade == 0, "and clears it");
			fades.Stop();

			// Saving.
			player.Play();
			Run(player, 1.5f);
			player.OnSaving();
			player.Stop();
			ClearAndDeleteItems(events);
			player.OnLoaded();
			Check(player.IsPlaying && Math.Abs(player.Time - 1.5f) < 0.01f && events.IsEmpty, "a save keeps where it was and carries on from there");
			player.Stop();
			Check(SequencePlayer.PlayingCount == 0, "no sequence is left counted as playing");
		}

		// ---- a shared sequence ----
		{
			Subtitles.Clear();
			NetworkManager.RegisterPrefab("SequencePlayerObject", new => CreatePlayer);
			let port = (uint16)(49000 + (DateTime.Now.Ticks / 10000) % 900);
			let host = scope Scene();
			let hostPlayer = BuildScene(host, true);
			let client = scope Scene();
			let clientPlayer = BuildScene(client, true);
			host.Network = new NetworkManager(host);
			host.Network.PlayerPrefab.Set("SequencePlayerObject");
			Check(host.Network.StartServer(port, true), "host starts");
			sScenes.Add(host);
			client.Network = new NetworkManager(client);
			client.Network.PlayerPrefab.Set("SequencePlayerObject");
			client.Network.StartClient("127.0.0.1", port);
			sScenes.Add(client);
			Time.DeltaTime = Time.FixedDeltaTime;
			Pump(120);
			Check(client.Network.IsConnected, "client connects over loopback");
			Check(host.Find("Intro").GetComponent<NetworkIdentity>() != null && client.Find("Intro").GetComponent<NetworkIdentity>() != null, "a shared sequence's object is shared by itself");
			int hostEvents = 0, clientEvents = 0;
			hostPlayer.OnEvent.Add(new [&] (name, value) =>
				{
					hostEvents++;
				}
				);
			clientPlayer.OnEvent.Add(new [&] (name, value) =>
				{
					clientEvents++;
				}
				);
			hostPlayer.Play();
			Pump(60);
			Check(clientPlayer.IsPlaying && Math.Abs(clientPlayer.Time - hostPlayer.Time) < 0.2f, scope $"the client plays it in time with the server ({clientPlayer.Time:0.00} / {hostPlayer.Time:0.00})");
			Check(client.ViewCamera?.GameObject.Name == "Sequence Camera", "and sees its shots");
			clientPlayer.Pause();
			Pump(30);
			Check(hostPlayer.State == .Paused && clientPlayer.State == .Paused, "the client pauses it through the server");
			clientPlayer.Resume();
			Pump(10);
			clientPlayer.Skip();
			Pump(30);
			Check(hostPlayer.State == .Finished && clientPlayer.State == .Finished && client.Find("Gate").Transform.LocalPosition.y == 4, "and skips it, for everyone");
			Check(hostEvents == 2 && clientEvents == 0, "events happen on the server only");
			hostPlayer.onlyOwnerControls = true;
			clientPlayer.Play();
			Pump(30);
			Check(hostPlayer.State == .Finished, "with Only Owner Controls, a player who does not own it cannot start it");
			client.Network.Stop();
			host.Network.Stop();
			Pump(5);
		}

		Console.WriteLine(sFailures == 0 ? "All sequencer tests passed." : scope $"{sFailures} sequencer test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
