using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace AsyncLoadingTests;

class Program
{
	static bool Check(bool condition, StringView name)
	{
		Console.WriteLine(scope $"{condition ? "PASS" : "FAIL"}: {name}");
		return condition;
	}

	/// One frame of a game: the background loading's main-thread share, then the scene.
	static void Frame(Scene scene)
	{
		Time.DeltaTime = 1.0f / 60;
		SceneManager.Update(scene);
		scene.Update();
		Thread.Sleep(2);
	}

	public static int Main(String[] args)
	{
		Console.WriteLine("Loading in the background (models, rigged models, textures, scenes; drawing needs a graphics card)");
		bool ok = true;
		// A small project: two models, a picture, a material naming the picture, a prefab, and scenes naming them.
		let root = "/tmp/tallow-async-test";
		for (let dir in StringView[?]("", "/Models", "/Textures", "/Materials", "/Prefabs", "/Scenes"))
			Directory.CreateDirectory(scope $"{root}{dir}").IgnoreError();
		let engine = scope String();
		Path.GetDirectoryPath(scope String(Environment.GetExecutableFilePath(.. scope .())), engine);
		// The engine's checkout, from this fixture's folder (BeefBuild runs it in Tests/AsyncLoading).
		let checkout = scope String();
		Directory.GetCurrentDirectory(checkout);
		checkout.Append("/../..");
		let sample = scope $"{checkout}/Samples/Sandbox/src";
		File.Copy(scope $"{sample}/Models/rigged_sample.glb" , scope $"{root}/Models/tentacle.glb" , true).IgnoreError();
		File.Copy(scope $"{sample}/Models/rigged_sample.glb" , scope $"{root}/Models/statue.glb" , true).IgnoreError();
		File.Copy(scope $"{sample}/Textures/hammered_normal.png" , scope $"{root}/Textures/bumps.png" , true).IgnoreError();
		File.Copy(scope $"{checkout}/icon.png" , scope $"{root}/Textures/logo.png" , true).IgnoreError();
		File.WriteAllText(scope $"{root}/Materials/stone.tmat" , "material 1\ncolor 1 1 1 1\nnormalMap \"Textures/bumps.png\"\n").IgnoreError();
		File.WriteAllText(scope $"{root}/Prefabs/crate.tprefab" , "object 1 parent 0 active 1 name \"Crate\"\ntransform 0 0 0 0 0 0 1 1 1 1\ncomponent Tallow.MeshRenderer enabled 1\nfield mesh \"Models/statue.glb\"\nfield texture \"Textures/logo.png\"\n").IgnoreError();
		let level = """
			scene "Level"
			object 1 parent 0 active 1 name "Statue"
			transform 0 0 0 0 0 0 1 1 1 1
			component Tallow.MeshRenderer enabled 1
			field mesh "Models/statue.glb"
			field material "Materials/stone.tmat"
			object 2 parent 0 active 1 name "Creature"
			transform 3 0 0 0 0 0 1 1 1 1
			component Tallow.SkinnedMeshRenderer enabled 1
			field model "Models/tentacle.glb"
			object 3 parent 0 active 1 name "Spawner"
			transform 0 0 0 0 0 0 1 1 1 1
			component Tallow.SceneLoader enabled 0
			field scene "Prefabs/crate.tprefab"

			""";
		File.WriteAllText(scope $"{root}/Scenes/Level.tscene" , level).IgnoreError();
		File.WriteAllText(scope $"{root}/Scenes/Menu.tscene" , "scene \"Menu\"\nobject 1 parent 0 active 1 name \"Title\"\ntransform 0 0 0 0 0 0 1 1 1 1\n").IgnoreError();
		Assets.ProjectPath.Set(root);

		// ---- what a scene names ----
		List<(String path, AssetLoader.Kind kind)> found = scope .();
		defer
		{
			for (let entry in found)
				delete entry.path;
		}
		SceneManager.References(level, found);
		bool Has(StringView path, AssetLoader.Kind kind)
		{
			for (let entry in found)
			{
				if (entry.path == path && entry.kind == kind) return true;
			}
			return false;
		}
		ok &= Check(found.Count == 4 && Has("Models/statue.glb", .Mesh) && Has("Models/tentacle.glb", .SkinnedModel) && Has("Textures/bumps.png", .Texture) && Has("Textures/logo.png", .Texture),
scope $"a scene's models and textures are found, through its materials and prefabs, rigged ones told apart ({found.Count})");

		// ---- an additive load, in the background ----
		let scene = scope Scene();
		Scene.Active = scene;
		scene.StartPlay();
		let load = SceneManager.LoadAdditiveAsync(scene, "Scenes/Level.tscene");
		ok &= Check(!load.IsDone && scene.Roots.Count == 0, "LoadAdditiveAsync returns at once, before anything is added");
		float last = 0;
		bool rising = true, sawLoading = false;
		int frames = 0;
		let backgroundBefore = AssetLoader.LoadedInBackground;
		while (!load.IsDone && frames < 3000)
		{
			Frame(scene);
			rising &= load.Progress >= last;
			last = load.Progress;
			sawLoading |= load.CurrentStage == .Loading;
			frames++;
		}
		ok &= Check(load.CurrentStage == .Done && load.Group != null && scene.Find("Statue") != null && scene.Find("Creature") != null, scope $"it finishes and the scene's objects are added ({frames} frames)");
		ok &= Check(rising && sawLoading && load.Progress == 1, "progress only goes up, through the loading stage, to 1");
		ok &= Check(load.AssetCount == 4 && load.AssetsLoaded == 4 && AssetLoader.LoadedInBackground - backgroundBefore == 4, scope $"its four models and textures were loaded on loading threads ({AssetLoader.LoadedInBackground - backgroundBefore})");
		ok &= Check(Assets.HasMesh("Models/statue.glb") && SkinnedModel.IsLoaded("Models/tentacle.glb"), "and are in the caches the ordinary calls use (textures too, with a graphics card)");
		let statueMesh = Assets.GetMesh("Models/statue.glb");
		ok &= Check(statueMesh != null && statueMesh.Vertices.Count > 100, "a model loaded in the background is a whole mesh");
		Frame(scene);
		Frame(scene);
		ok &= Check(!SceneManager.Loads.Contains(load), "a finished load is let go a frame later");

		// ---- held until it is allowed ----
		let second = SceneManager.LoadAdditiveAsync(scene, "Scenes/Level.tscene");
		second.allowActivation = false;
		for (int i < 200)
			Frame(scene);
		ok &= Check(second.CurrentStage == .Ready && second.Progress == 0.9f && scene.Roots.Count == 1, "with allowActivation off it waits, ready, at 0.9");
		second.Activate();
		Frame(scene);
		ok &= Check(second.IsDone && scene.Roots.Count == 2, "and Activate finishes it");
		ok &= Check(second.AssetCount == 4 && second.AssetsLoaded == 4, "things loaded already count as loaded at once");

		// ---- a file that is not there ----
		// Read as soon as it is done: a finished load is let go a frame later.
		let missing = SceneManager.LoadAdditiveAsync(scene, "Scenes/Nowhere.tscene");
		for (int i = 0; i < 50 && !missing.IsDone; i++)
			Frame(scene);
		ok &= Check(missing.Failed && missing.IsDone, "a scene that is not there fails, and says so");

		// ---- changing scene ----
		let change = SceneManager.LoadAsync("Scenes/Menu.tscene");
		frames = 0;
		while (!change.IsDone && frames < 3000)
		{
			Frame(scene);
			frames++;
		}
		ok &= Check(change.CurrentStage == .Done && scene.Find("Title") != null && scene.Find("Statue") == null && SceneManager.Current == "Scenes/Menu.tscene" && scene.IsPlaying, "LoadAsync changes the running scene once it is ready, and play goes on");

		// ---- preloading by hand ----
		let batch = AssetLoader.Preload("Textures/logo.png", "Models/statue.glb", "Sounds/not-a-model.wav");
		ok &= Check(batch.Total == 2, "Preload takes the models and textures it is given, and leaves other files");
		for (int i = 0; i < 500 && !batch.IsDone; i++)
			Frame(scene);
		ok &= Check(batch.IsDone && batch.Progress == 1, "and is done once they are loaded");
		delete batch;

		// ---- the component ----
		let loaderObject = scene.CreateGameObject("Loader");
		let loader = loaderObject.AddComponent<SceneLoader>();
		loader.scene.Set("Scenes/Level.tscene");
		loader.additive = true;
		loader.activateWhenReady = false;
		frames = 0;
		while (frames < 400)
		{
			Frame(scene);
			frames++;
		}
		ok &= Check(Math.Abs(loader.progress - 0.9f) < 0.001f && !loader.Finished, scope $"a Scene Loader loads on start and, told to wait, waits at 0.9 ({loader.progress:0.00})");
		loader.Activate();
		for (int i < 5)
			Frame(scene);
		ok &= Check(loader.Finished && loader.progress == 1 && scene.Find("Creature") != null, "Activate lets it finish");

		scene.StopPlay();
		Scene.Active = null;
		Console.WriteLine(ok ? "ALL PASSED" : "SOME FAILED");
		AssetLoader.Shutdown();
		return ok ? 0 : 1;
	}
}
