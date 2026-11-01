using System;
using System.Collections;
using System.IO;
using Tallow;

namespace SceneTests;

[Component]
class Counter : Component
{
	public static int Awake_, Destroyed;
	public override void Awake()
	{
		Awake_++;
	}

	public override void OnDestroy()
	{
		Destroyed++;
	}
}

class Program
{
	static bool Check(bool pass, StringView label)
	{
		Console.WriteLine(scope $"{pass ? "PASS" : "FAIL"}: {label}");
		return pass;
	}

	public static int Main(String[] args)
	{
		bool ok = true;
		let folder = scope String();
		Path.GetTempPath(folder);
		folder.Append("/tallow-scene-test");
		Directory.CreateDirectory(folder).IgnoreError();
		Assets.ProjectPath.Set(folder);
		// A level: two top-level objects, one with a child and a component, under its own sky.
		{
			let level = scope Scene();
			level.Name.Set("Level");
			level.Environment.fogDensity = 0.25f;
			let wall = level.CreateGameObject("Wall");
			wall.Transform.Position = .(3, 0, 0);
			wall.AddComponent<Counter>();
			level.CreateGameObject("Brick", wall.Transform).Transform.LocalPosition = .(0, 1, 0);
			level.CreateGameObject("Lamp");
			SceneSerializer.SaveToFile(level, scope $"{folder}/Level.tscene");
			let other = scope Scene();
			other.Name.Set("Other");
			other.CreateGameObject("Elsewhere").AddComponent<Counter>();
			SceneSerializer.SaveToFile(other, scope $"{folder}/Other.tscene");
		}
		let scene = scope Scene();
		Scene.Active = scene;
		scene.CreateGameObject("Game");
		scene.StartPlay();
		let fog = scene.Environment.fogDensity;
		Counter.Awake_ = 0;
		let first = SceneManager.LoadAdditive(scene, "Level.tscene");
		ok &= Check(first != null && first.Name == "Level" && first.Transform.Children.Count == 2, "an added scene arrives under one object named after it");
		ok &= Check(scene.Find("Brick") != null && scene.Find("Brick").Transform.Parent.GameObject.Name == "Wall" && scene.Find("Wall").Transform.Position.x == 3, "with its hierarchy and positions");
		ok &= Check(Counter.Awake_ == 1, "its components wake up in a scene that is playing");
		ok &= Check(scene.Environment.fogDensity == fog, "the sky and fog are left alone unless asked for");
		let second = SceneManager.LoadAdditive(scene, "Level.tscene", true);
		ok &= Check(second != null && second != first && scene.Objects.Count == 1 + 4 + 4, "the same scene can be added twice, with fresh ids");
		ok &= Check(scene.Environment.fogDensity == 0.25f, "and can bring its sky and fog with it");
		Counter.Destroyed = 0;
		SceneManager.Unload(first);
		ok &= Check(scene.Objects.Count == 1 + 4 && Counter.Destroyed == 1 && scene.Find("Game") != null, "unloading removes exactly what was added");
		ok &= Check(SceneManager.LoadAdditive(scene, "Missing.tscene") == null, "a scene that is not there gives nothing");
		// Changing scene waits for the gap between frames.
		SceneManager.Load("Other.tscene");
		ok &= Check(scene.Find("Game") != null && SceneManager.Pending == "Other.tscene", "a change of scene is held until the frame is over");
		Counter.Awake_ = 0;
		ok &= Check(SceneManager.ApplyPending(scene) && scene.Find("Game") == null && scene.Find("Elsewhere") != null, "then the old scene is gone and the new one is in its place");
		ok &= Check(scene.IsPlaying && Counter.Awake_ == 1 && SceneManager.Current == "Other.tscene" && SceneManager.Pending.IsEmpty, "and it is playing");
		SceneManager.Load("Missing.tscene");
		ok &= Check(!SceneManager.ApplyPending(scene) && scene.Find("Elsewhere") != null, "asking for a scene that is not there changes nothing");
		scene.StopPlay();

		// The game window's fullscreen setting, with no window open (as on a server, or before the window exists).
		ok &= Check(!GameWindow.Fullscreen && !GameWindow.StartsFullscreen, "a game starts in a window unless its build says otherwise");
		GameWindow.StartsFullscreen = true;
		ok &= Check(GameWindow.Fullscreen && GameWindow.TakeStartState(), "a build set to start fullscreen opens its window fullscreen");
		GameWindow.Fullscreen = false;
		ok &= Check(!GameWindow.Fullscreen && GameWindow.StartsFullscreen && !GameWindow.TakeStartState(), "the game's own choice wins over the build's setting");
		GameWindow.ToggleFullscreen();
		ok &= Check(GameWindow.Fullscreen, "toggling flips it");
		GameWindow.Allowed = false;
		ok &= Check(GameWindow.Fullscreen && !GameWindow.TakeStartState(), "in the editor the choice is remembered but the window stays as it is");
		GameWindow.Allowed = true;
		Console.WriteLine(ok ? "ALL PASSED" : "FAILED");
		return ok ? 0 : 1;
	}
}
