using System;
using System.Collections;
using Tallow;

namespace SpawnPointTests;

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	static SpawnPoint Add(Scene scene, StringView name, Vector3 position, int32 team = 0, bool startOnly = false)
	{
		let go = scene.CreateGameObject(name);
		go.Transform.Position = position;
		let point = go.AddComponent<SpawnPoint>();
		point.team = team;
		point.startOnly = startOnly;
		return point;
	}

	static void Names(Scene scene, int32 team, int count, String text, bool random = false)
	{
		for (int i < count)
		{
			let p = random ? SpawnPoints.Random(scene, team) : SpawnPoints.Next(scene, team);
			text.Append(p != null ? (StringView)p.GameObject.Name : "-");
			text.Append(' ');
		}
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		{
			let scene = scope Scene();
			Scene.Active = scene;
			Vector3 position;
			Quaternion rotation;
			ok &= Check(SpawnPoints.Next(scene) == null && !SpawnPoints.TryGet(scene, 0, false, out position, out rotation), "a scene with no spawn points gives none");
			Add(scene, "A", .(0, 0, 0));
			Add(scene, "B", .(5, 0, 0));
			let c = Add(scene, "C", .(10, 0, 0));
			c.Transform.Rotation = Quaternion.Euler(0, 90, 0);
			let order = scope String();
			Names(scene, 0, 7, order);
			ok &= Check(order == "A B C A B C A ", scope $"next goes round the points in turn ({order})");
			let seen = scope String();
			Names(scene, 0, 60, seen, true);
			ok &= Check(seen.Contains("A ") && seen.Contains("B ") && seen.Contains("C ") && SpawnPoints.Count(scene) == 3, "random reaches every point");
			// A point with someone standing on it is passed over while others are free.
			let blocker = scene.CreateGameObject("Blocker");
			blocker.Transform.Position = .(5.3f, 0, 0);
			blocker.AddComponent<CharacterController>();
			let avoiding = scope String();
			Names(scene, 0, 6, avoiding);
			ok &= Check(!avoiding.Contains("B"), scope $"an occupied point is skipped while others are free ({avoiding})");
			scene.DestroyImmediate(scene.Find("A"));
			scene.DestroyImmediate(scene.Find("C"));
			ok &= Check(SpawnPoints.Next(scene)?.GameObject.Name == "B", "but is still used when it is the only one");
			// Place moves a character and turns it.
			scene.StartPlay();
			let mover = scene.CreateGameObject("Mover");
			mover.Transform.Position = .(50, 3, 50);
			let controller = mover.AddComponent<CharacterController>();
			controller.Start();
			scene.DestroyImmediate(blocker);
			let turned = Add(scene, "Turned", .(20, 1, 20));
			turned.Transform.Rotation = Quaternion.Euler(0, 90, 0);
			scene.DestroyImmediate(scene.Find("B"));
			let used = SpawnPoints.Place(mover);
			controller.Move(.Zero, 1 / 60f);
			ok &= Check(used == turned && (mover.Transform.Position - Vector3(20, 1, 20)).Length < 0.05f && Math.Abs(mover.Transform.Forward.x - 1) < 0.01f && turned.UseCount == 1, "place moves a character to the point and faces it the point's way");
		}
		{
			// Teams: red has two points, blue one, and one is shared.
			let scene = scope Scene();
			Scene.Active = scene;
			Add(scene, "Red1", .(0, 0, 0), 1);
			Add(scene, "Red2", .(4, 0, 0), 1);
			Add(scene, "Blue", .(0, 0, 20), 2);
			Add(scene, "Shared", .(0, 0, 10), 0);
			let red = scope String();
			Names(scene, 1, 5, red);
			ok &= Check(red == "Red1 Red2 Red1 Red2 Red1 ", scope $"a team goes round its own points ({red})");
			let blue = scope String();
			Names(scene, 2, 3, blue);
			ok &= Check(blue == "Blue Blue Blue ", "and never gets another team's");
			ok &= Check(SpawnPoints.Next(scene, 3)?.GameObject.Name == "Shared" && SpawnPoints.Count(scene, 3) == 1 && SpawnPoints.Count(scene, 1) == 3, "a team with no points of its own uses the shared one");
			let anyone = scope String();
			Names(scene, 0, 8, anyone);
			ok &= Check(anyone.Contains("Red1") && anyone.Contains("Blue") && anyone.Contains("Shared"), "with no team asked for, every point is available");
			let camper = scene.CreateGameObject("Camper");
			camper.Transform.Position = .(0, 0, 20);
			camper.AddComponent<CharacterController>();
			ok &= Check(SpawnPoints.Next(scene, 2)?.GameObject.Name == "Shared", "a team whose point is occupied is sent to a free shared one");
			scene.DestroyImmediate(scene.Find("Shared"));
			ok &= Check(SpawnPoints.Next(scene, 2)?.GameObject.Name == "Blue", "or to its own occupied point when nothing else is free");
			scene.DestroyImmediate(scene.Find("Blue"));
			let last = SpawnPoints.Next(scene, 2);
			ok &= Check(last != null && last.team == 1, "and only as a last resort to any point at all");
		}
		{
			// Start-only points: a line-up used once each at the start, then the ordinary points take over.
			let scene = scope Scene();
			Scene.Active = scene;
			Add(scene, "Start1", .(0, 0, 0), 0, true);
			Add(scene, "Start2", .(2, 0, 0), 0, true);
			Add(scene, "Respawn", .(0, 0, 30));
			Add(scene, "RedStart", .(9, 0, 0), 1, true);
			ok &= Check(SpawnPoints.IsStartPhase(scene) && SpawnPoints.Count(scene) == 1, "the start phase is open when a scene begins; start-only points are not counted as ordinary ones");
			ok &= Check(SpawnPoints.Next(scene, 1)?.GameObject.Name == "RedStart", "a team's own start point comes first");
			let line = scope String();
			Names(scene, 0, 4, line);
			ok &= Check(line == "Start1 Start2 Respawn Respawn ", scope $"start points are used once each, then ordinary points ({line})");
			SpawnPoints.BeginStart(scene);
			let again = SpawnPoints.Next(scene);
			ok &= Check(again != null && again.startOnly, "a new round opens the start points again");
			SpawnPoints.EndStart(scene);
			ok &= Check(!SpawnPoints.IsStartPhase(scene) && SpawnPoints.Next(scene)?.GameObject.Name == "Respawn" && SpawnPoints.Random(scene)?.GameObject.Name == "Respawn", "after the start phase is closed only ordinary points are given");
			SpawnPoints.BeginStart(scene);
			scene.StartPlay();
			Time.DeltaTime = Time.FixedDeltaTime;
			for (int i < (int)(SpawnPoints.StartWindow * 60) + 5)
				scene.FixedUpdate();
			ok &= Check(!SpawnPoints.IsStartPhase(scene) && SpawnPoints.Next(scene)?.GameObject.Name == "Respawn", "the start phase also closes by itself after the start window");
			SpawnPoints.StartWindow = 0;
			ok &= Check(SpawnPoints.IsStartPhase(scene), "a start window of 0 keeps it open until it is closed by hand");
			SpawnPoints.StartWindow = 5;
		}
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
