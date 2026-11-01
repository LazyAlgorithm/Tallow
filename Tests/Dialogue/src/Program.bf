using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace DialogueTests;

/// Dialogue and subtitles (docs/dialogue.md): reading and writing `.tdialogue` files and the mistakes reported, a
/// conversation's lines, choices, conditions, variables, events and jumps, subtitle files and the subtitle list,
/// the Dialogue Runner offline (playing, answering, saving), and a shared conversation between a host and a client
/// over loopback.
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

	const String cFolder = "/tmp/tallow-dialogue-test";

	const String cGuard = """
		# The guard at the gate.
		speaker guard "Gate Guard" color 1 0.8 0.3 object "Guard"

		node start
			say guard "Halt! Who goes there?" audio "Voice/halt.ogg"
			choice "A friend." friend
			choice "Let me through, or else." threat if courage >= 2
			choice "Never mind."
			say - "You walk away."
			end
		node friend
			set metGuard 1
			add visits 1
			say guard "Pass, friend." time 2.5
			event OpenGate 3
			say guard "Welcome back." if visits > 1 and metGuard
		node threat
			add courage -1
			say guard "Ha! Try it."
			goto start
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

	static void BuildTalk(Scene scene)
	{
		let guard = scene.CreateGameObject("Guard");
		let runner = guard.AddComponent<DialogueRunner>();
		runner.dialogue.Set("Dialogue/guard.tdialogue");
		runner.shared = true;
		runner.acceptInput = false;
		scene.StartPlay();
	}

	public static int Main(String[] args)
	{
		Directory.CreateDirectory(scope $"{cFolder}/Dialogue").IgnoreError();
		Directory.CreateDirectory(scope $"{cFolder}/Voice").IgnoreError();
		Assets.ProjectPath.Set(cFolder);
		File.WriteAllText(scope $"{cFolder}/Dialogue/guard.tdialogue" , cGuard).IgnoreError();
		Time.DeltaTime = Time.FixedDeltaTime;

		// ---- the file ----
		let asset = scope DialogueAsset();
		asset.Parse(cGuard);
		Check(asset.problems.IsEmpty, scope $"a good dialogue reads with no problems ({asset.problems})");
		let guard = asset.FindSpeaker("guard");
		Check(guard != null && guard.name == "Gate Guard" && guard.color == Color(1, 0.8f, 0.3f, 1) && guard.objectName == "Guard", "a speaker has a shown name, a colour and an object");
		Check(asset.nodes.Count == 3 && asset.FindNode("start").steps.Count == 6 && asset.FindNode("friend").steps.Count == 5, "nodes and their steps are read");
		let first = asset.FindNode("start").steps[0];
		Check(first.kind == .Say && first.speaker == "guard" && first.text == "Halt! Who goes there?" && first.audio == "Voice/halt.ogg", "a line has its speaker, text and recording");
		let threat = asset.FindNode("start").steps[2];
		Check(threat.kind == .Choice && threat.target == "threat" && threat.condition == "courage >= 2", "a choice has its answer, where it goes and its condition");
		Check(asset.FindNode("start").steps[4].speaker.IsEmpty && asset.FindNode("friend").steps[2].time == 2.5f, "'-' is a narrator, and a line can have its own time");
		let written = scope String();
		asset.Write(written);
		let again = scope DialogueAsset();
		again.Parse(written);
		let rewritten = scope String();
		again.Write(rewritten);
		Check(again.problems.IsEmpty && rewritten == written && again.FindNode("friend").steps[3].value == 3, "a dialogue written out reads back the same");
		let broken = scope DialogueAsset();
		broken.Parse("""
			say - "before any node"
			node a
				shout "hello"
				goto nowhere
				say ghost "boo"
				set x
			node a
			""");
		Check(broken.problems.Contains("line 1:") && broken.problems.Contains("line 3: unknown step 'shout'") && broken.problems.Contains("line 4: there is no node called 'nowhere'")
			&& broken.problems.Contains("line 5: speaker 'ghost'") && broken.problems.Contains("line 6:") && broken.problems.Contains("line 7: there is already a node"), "mistakes are reported by line");

		// ---- conditions and variables ----
		DialogueVariables.Clear();
		DialogueVariables.Set("gold", 12);
		DialogueVariables.Set("door", 1);
		Check(DialogueVariables.Evaluate("gold >= 10") && !DialogueVariables.Evaluate("gold < 10") && DialogueVariables.Evaluate("door") && DialogueVariables.Evaluate("!missing") && DialogueVariables.Evaluate(""), "conditions compare, test and negate");
		Check(DialogueVariables.Evaluate("door and gold == 12") && !DialogueVariables.Evaluate("door and missing") && DialogueVariables.Evaluate("missing or door"), "and / or join them");
		let saved = scope String();
		DialogueVariables.ToText(saved);
		DialogueVariables.Clear();
		DialogueVariables.FromText(saved);
		Check(DialogueVariables.Get("gold") == 12 && DialogueVariables.Get("door") == 1 && DialogueVariables.All.Count == 2, "variables are written out and read back");

		// ---- a conversation ----
		DialogueVariables.Clear();
		let talk = scope DialogueConversation();
		let events = scope List<String>();
		defer ClearAndDeleteItems(events);
		talk.OnEvent.Add(new (name, value) => events.Add(new $"{name}={value}"));
		Check(talk.Start(asset, "start") && talk.View == .Line && talk.Line == first, "starting shows the first line");
		talk.Advance();
		Check(talk.View == .Choices && talk.Choices.Count == 2 && talk.Choices[0].text == "A friend." && talk.Choices[1].text == "Never mind.", "answers whose condition fails are left out");
		talk.Choose(1);
		Check(talk.View == .Line && talk.Line.text == "You walk away.", "an answer with nowhere to go carries on after the answers");
		talk.Advance();
		Check(talk.View == .Ended, "'end' finishes the conversation");
		talk.Start(asset, "start");
		talk.Advance();
		talk.Choose(0);
		Check(talk.View == .Line && talk.Line.text == "Pass, friend." && DialogueVariables.Get("metGuard") == 1 && DialogueVariables.Get("visits") == 1, "an answer goes to its node, which sets variables on the way");
		talk.Advance();
		Check(events.Count == 1 && events[0] == "OpenGate=3", "events reach the game with their number");
		Check(talk.View == .Ended, "a line whose condition fails is skipped, and the node running out ends it");
		talk.Start(asset, "friend");
		talk.Advance();
		Check(talk.View == .Line && talk.Line.text == "Welcome back.", "the second visit takes the line the first one skipped");
		DialogueVariables.Set("courage", 2);
		talk.Start(asset, "start");
		talk.Advance();
		Check(talk.Choices.Count == 3, "an answer appears once its condition holds");
		talk.Choose(1);
		talk.Advance();
		Check(talk.View == .Line && talk.Line == first && DialogueVariables.Get("courage") == 1, "goto jumps back to another node");
		Check(!talk.Choose(5) && talk.View == .Line, "choosing with no answers offered does nothing");
		Check(!talk.Start(asset, "nowhere") && talk.View == .Ended, "starting at a node that does not exist fails");
		let looping = scope DialogueAsset();
		looping.Parse("node a\n\tgoto b\nnode b\n\tgoto a\n");
		Check(talk.Start(looping, "a") && talk.View == .Ended, "a loop of jumps with nothing to show ends instead of hanging");
		Check(talk.Restore(asset, 1, 2) && talk.View == .Line && talk.Line.text == "Pass, friend.", "a conversation can be put back at a node and step");

		// ---- subtitle files and the subtitle list ----
		let track = scope SubtitleTrack();
		track.Parse("""
			1
			00:00:00,500 --> 00:00:02,000
			CAPTAIN: Hold the line!

			2
			00:00:02,500 --> 00:00:04,250
			[explosion]

			3
			00:01:00.000 --> 00:01:01.500
			Two lines
			of text
			""");
		Check(track.cues.Count == 3 && track.cues[0].start == 0.5f && track.cues[0].end == 2 && track.cues[0].speaker == "CAPTAIN" && track.cues[0].text == "Hold the line!", "a subtitle file's times, speaker and text are read");
		Check(track.cues[1].caption && !track.cues[0].caption && track.cues[2].start == 60 && track.cues[2].text == "Two lines\nof text", "captions, minutes and lines that wrap");
		Check(track.CueAt(1) == 0 && track.CueAt(2.2f) == -1 && track.CueAt(3) == 1, "the cue showing at a time is found");
		File.WriteAllText(scope $"{cFolder}/Voice/halt.srt" , "1\n00:00:00,000 --> 00:00:01,000\nGUARD: Halt!\n").IgnoreError();
		Check(Subtitles.TrackFor("Voice/halt.ogg")?.cues.Count == 1 && Subtitles.TrackFor("Voice/none.ogg") == null, "a sound's subtitle file is the one beside it with the same name");
		Subtitles.Clear();
		Time.RealTime = 100;
		let line = Subtitles.Show("Radio", "Move in.", 3);
		Subtitles.Caption("[static]");
		Check(Subtitles.Showing.Count == 2 && Subtitles.IsShowing(line) && Subtitles.Showing[1].caption, "lines and captions are shown");
		Time.RealTime = 102.5f;
		Subtitles.Update();
		Check(Subtitles.IsShowing(line) && Subtitles.Showing.Count == 1, "each stays up for its time");
		Time.RealTime = 103.5f;
		Subtitles.Update();
		Check(Subtitles.Showing.IsEmpty, "and then goes");
		for (int i < 5)
			Subtitles.Show("", scope $"line {i}");
		Check(Subtitles.Showing.Count == Subtitles.MaxLines && Subtitles.Showing[0].text == "line 2", "only the newest few are kept");
		Subtitles.Clear();

		// ---- the Dialogue Runner ----
		{
			DialogueVariables.Clear();
			let scene = scope Scene();
			let npc = scene.CreateGameObject("Guard");
			let runner = npc.AddComponent<DialogueRunner>();
			runner.dialogue.Set("Dialogue/guard.tdialogue");
			runner.acceptInput = false;
			let heard = scope List<String>();
			defer ClearAndDeleteItems(heard);
			bool ended = false;
			runner.OnLine.Add(new (step) => heard.Add(new String(step.text)));
			runner.OnEvent.Add(new (name, value) => heard.Add(new $"event {name}"));
			runner.OnEnded.Add(new [&] () =>
				{
					ended = true;
				}
				);
			scene.StartPlay();
			Check(runner.Play() && runner.View == .Line && runner.Speaker?.name == "Gate Guard", "Play starts at Start Node, with the speaker known");
			Check(Subtitles.Showing.Count == 1 && Subtitles.Showing[0].speaker == "Gate Guard" && Subtitles.Showing[0].text == "Halt! Who goes there?", "the line is shown as a subtitle with its speaker");
			Check(npc.GetComponent<AudioSource>() != null, "a line's recording plays from the speaker's object");
			runner.Advance();
			Check(runner.View == .Choices && Subtitles.Showing.IsEmpty, "answers take the line down");
			runner.Choose(0);
			runner.Advance();
			Check(heard.Count == 3 && heard[1] == "Pass, friend." && heard[2] == "event OpenGate" && ended, "the game hears each line, each event and the end");
			runner.Play("friend");
			runner.OnSaving();
			let savedText = scope String(runner.savedVariables);
			DialogueVariables.Clear();
			runner.Stop();
			runner.OnLoaded();
			Check(savedText.Contains("metGuard 1") && DialogueVariables.Get("visits") == 2 && runner.View == .Line && runner.Line.text == "Pass, friend.", "a save keeps the variables and where the conversation was");
			runner.autoAdvance = true;
			runner.Play("threat");
			Time.Time = 0;
			runner.Update();
			Time.Time = 1;
			Time.FrameCount++;
			runner.Update();
			Check(runner.View == .Line && runner.Line.text == "Ha! Try it.", "a line that moves on by itself stays up long enough to read");
			Time.Time = 3;
			Time.FrameCount++;
			runner.Update();
			Check(runner.View == .Line && runner.Line == runner.Conversation.Asset.FindNode("start").steps[0], "and then moves on");
			runner.Stop();
			Check(runner.View == .Ended && Subtitles.Showing.IsEmpty, "Stop ends it and takes the line down");
		}

		// ---- a shared conversation ----
		{
			DialogueVariables.Clear();
			Subtitles.Clear();
			NetworkManager.RegisterPrefab("DialoguePlayer", new => CreatePlayer);
			let port = (uint16)(48000 + (DateTime.Now.Ticks / 10000) % 900);
			let host = scope Scene();
			BuildTalk(host);
			let client = scope Scene();
			BuildTalk(client);
			host.Network = new NetworkManager(host);
			host.Network.PlayerPrefab.Set("DialoguePlayer");
			Check(host.Network.StartServer(port, true), "host starts");
			sScenes.Add(host);
			client.Network = new NetworkManager(client);
			client.Network.PlayerPrefab.Set("DialoguePlayer");
			client.Network.StartClient("127.0.0.1", port);
			sScenes.Add(client);
			Pump(120);
			Check(client.Network.IsConnected, "client connects over loopback");
			let hostTalk = host.Find("Guard").GetComponent<DialogueRunner>();
			let clientTalk = client.Find("Guard").GetComponent<DialogueRunner>();
			Check(host.Find("Guard").GetComponent<NetworkIdentity>() != null && client.Find("Guard").GetComponent<NetworkIdentity>() != null, "a shared conversation's object is shared by itself");
			bool clientEvent = false, hostEvent = false;
			clientTalk.OnEvent.Add(new [&] (name, value) =>
				{
					clientEvent = true;
				}
				);
			hostTalk.OnEvent.Add(new [&] (name, value) =>
				{
					hostEvent = true;
				}
				);
			hostTalk.Play();
			Pump(30);
			Check(clientTalk.View == .Line && clientTalk.Line.text == "Halt! Who goes there?", "the client shows the line the server started");
			clientTalk.Advance();
			Pump(30);
			Check(hostTalk.View == .Choices && clientTalk.View == .Choices && clientTalk.Choices.Count == 2, "the client moves it on through the server, and both show the answers");
			clientTalk.Choose(0);
			Pump(30);
			Check(hostTalk.View == .Line && clientTalk.View == .Line && clientTalk.Line.text == "Pass, friend." && DialogueVariables.Get("metGuard") == 1, "the client's answer is taken by the server");
			hostTalk.Advance();
			Pump(30);
			Check(hostEvent && !clientEvent && hostTalk.View == .Ended && clientTalk.View == .Ended, "events happen on the server; the end reaches the client");
			// A request about a line that has already gone is dropped.
			hostTalk.Play();
			Pump(30);
			let stale = clientTalk.syncSerial;
			hostTalk.Advance();
			NetworkSync.DialogueRequest(clientTalk, 1, stale, "", 1);
			Pump(30);
			Check(hostTalk.View == .Choices && clientTalk.View == .Choices, "a late request about an older line is ignored");
			hostTalk.onlyOwnerChooses = true;
			clientTalk.Choose(0);
			Pump(30);
			Check(hostTalk.View == .Choices, "with Only Owner Chooses, a player who does not own it cannot answer");
			client.Network.Stop();
			host.Network.Stop();
			Pump(5);
		}

		Console.WriteLine(sFailures == 0 ? "All dialogue tests passed." : scope $"{sFailures} dialogue test(s) failed.");
		return sFailures == 0 ? 0 : 1;
	}
}
