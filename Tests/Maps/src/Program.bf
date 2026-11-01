using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace MapTests;

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

	/// Runs frames until the terrain has stopped loading.
	static void Settle(Scene scene, VoxelTerrain terrain)
	{
		int stable = 0, last = -1;
		for (int i = 0; i < 4000 && stable < 40; i++)
		{
			Time.DeltaTime = 0.016f;
			Time.UnscaledDeltaTime = 0.016f;
			scene.Update();
			Thread.Sleep(2);
			if (terrain.ChunkCount == last && terrain.PendingChunks == 0)
				stable++;
			else
				stable = 0;
			last = terrain.ChunkCount;
		}
	}

	static float Ground(VoxelTerrain terrain, float x, float z)
	{
		Vector3 point;
		if (terrain.Raycast(Ray(.(x, 60, z), .(0, -1, 0)), 200, out point))
			return point.y;
		return float.NaN;
	}

	static VoxelTerrain MakeTerrain(Scene scene)
	{
		let terrain = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
		terrain.voxelSize = 1;
		terrain.tileSize = 2;
		terrain.style = .Smooth;
		terrain.generateColliders = false;
		terrain.lodDistance = 0;
		terrain.OnValidate();
		return terrain;
	}

	static bool HasProblem(MapFileInfo map, StringView words)
	{
		for (let problem in map.Problems)
		{
			if (problem.Contains(words))
				return true;
		}
		return false;
	}

	static MapFileInfo Named(List<MapFileInfo> maps, StringView fileName)
	{
		for (let map in maps)
		{
			if (map.File.EndsWith(fileName))
				return map;
		}
		return null;
	}

	static void Empty(StringView folder)
	{
		if (!Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
			File.Delete(entry.GetFilePath(.. scope .())).IgnoreError();
	}

	public static int Main(String[] args)
	{
		let folder = scope String();
		Path.GetTempPath(folder);
		folder.Append("/tallow-map-test");
		let maps = scope $"{folder}/Maps";
		Directory.CreateDirectory(scope $"{folder}/Textures").IgnoreError();
		Directory.CreateDirectory(maps).IgnoreError();
		Empty(maps);
		Empty(scope $"{folder}/Scenes/Level.terrain");
		Assets.ProjectPath.Set(folder);
		GamePaths.Game.Set("Map Test");
		GamePaths.SetGameFolder(folder);
		File.WriteAllText(scope $"{folder}/Textures/stone.png" , "not really a picture").IgnoreError();
		VoxelTerrain.Viewers.Clear();

		// ---- a level, sculpted and saved, exported as a map ----
		float hill;
		{
			let level = scope Scene();
			level.Name.Set("Level");
			Scene.Active = level;
			let floor = level.CreateGameObject("Floor");
			let renderer = floor.AddComponent<MeshRenderer>();
			renderer.mesh.Set("builtin:cube");
			renderer.texture.Set("Textures/stone.png");
			level.CreateGameObject("Start").AddComponent<SpawnPoint>();
			let terrain = MakeTerrain(level);
			Settle(level, terrain);
			for (int i < 30)
				terrain.Brush(.(16, 0, 16), 5, 0.1f, .Raise);
			Settle(level, terrain);
			hill = Ground(terrain, 16, 16);
			Directory.CreateDirectory(scope $"{folder}/Scenes").IgnoreError();
			terrain.editsFolder.Set("Scenes/Level.terrain");
			SceneSerializer.SaveToFile(level, scope $"{folder}/Scenes/Level.tscene");
			Check(hill > 1, scope $"the level has a sculpted hill ({hill:0.0} m)");
			let problems = scope List<String>();
			defer
			{
				ClearAndDeleteItems!(problems);
			}
			let exported = MapFiles.Export(level, scope $"{maps}/Level.tmap" , "Harbour Hill", "A tester", "A hill by the sea.", problems) case .Ok;
			Check(exported && problems.Count == 0, scope $"a scene exports as a map file with nothing missing ({problems.Count} problems)");
			let pack = scope PackFile();
			Check(pack.Open(scope $"{maps}/Level.tmap") case .Ok && pack.Has("map.txt") && pack.Has("map.tscene") && pack.Has("terrain1/tile_1.voxels"),
				"it holds its description, its scene and the terrain's sculpting");
			Directory.DelTree(scope $"{folder}/Scenes/Level.terrain").IgnoreError();
		}

		// ---- found and checked ----
		{
			let found = scope List<MapFileInfo>();
			defer
			{
				ClearAndDeleteItems!(found);
			}
			let playable = MapFiles.Find(maps, found);
			let map = found.Count > 0 ? found[0] : null;
			Check(playable == 1 && map != null && map.Ok, "Find lists the map, with no problems");
			Check(map != null && map.Name == "Harbour Hill" && map.Author == "A tester" && map.Description == "A hill by the sea." && map.Game == "Map Test",
				"with the name, author, description and game it was exported with");
			Check(map != null && map.CountComponents("Tallow.SpawnPoint") == 1 && map.CountComponents("Tallow.VoxelTerrain") == 1,
				"a game can count what is in it (one spawn point, one terrain)");
			Check(MapFiles.Find(scope $"{folder}/NoSuchFolder" , found) == 0, "a missing Maps folder finds nothing");

			// ---- played: mounted and added to a running scene, sculpting and all ----
			let game = scope Scene();
			Scene.Active = game;
			game.CreateGameObject("Game");
			game.StartPlay();
			let scenePath = map.ScenePath(.. scope .());
			Check(!AssetPack.Exists(Assets.ResolvePath(scenePath, .. scope .())), "before it is mounted its scene cannot be read");
			Check(MapFiles.Mount(map) && map.Mounted && AssetPack.Exists(Assets.ResolvePath(scenePath, .. scope .())), "mounting it makes its scene readable");
			let group = SceneManager.LoadAdditive(game, scenePath, true);
			let terrain = game.FindComponent<VoxelTerrain>();
			Check(group != null && terrain != null && game.FindComponent<SpawnPoint>() != null, "its scene loads into the game like any other");
			if (terrain != null)
			{
				Settle(game, terrain);
				let height = Ground(terrain, 16, 16);
				Check(Math.Abs(height - hill) < 0.3f, scope $"and its terrain has the sculpting from the map ({height:0.0} m, {hill:0.0} m when exported)");
			}
			SceneManager.Unload(group);
			MapFiles.Unmount(map);
			Check(!map.Mounted && !AssetPack.Exists(Assets.ResolvePath(scenePath, .. scope .())), "unmounting it frees its files");
			game.StopPlay();
		}

		// ---- maps with something wrong ----
		{
			File.Copy(scope $"{maps}/Level.tmap" , scope $"{maps}/Copy of Level.tmap").IgnoreError();
			File.WriteAllText(scope $"{maps}/Junk.tmap" , "this is not a map").IgnoreError();
			// A copy with one byte of its scene changed.
			let bytes = scope List<uint8>();
			File.ReadAll(scope $"{maps}/Level.tmap" , bytes).IgnoreError();
			bytes[bytes.Count / 2] ^= 0x5A;
			File.WriteAll(scope $"{maps}/Damaged.tmap" , bytes).IgnoreError();
			// Made by another game, and one that names a file and a component the game does not have.
			let other = scope Scene();
			other.Name.Set("Other");
			other.CreateGameObject("Thing").AddComponent<MeshRenderer>().mesh.Set("Models/missing.glb");
			let problems = scope List<String>();
			defer
			{
				ClearAndDeleteItems!(problems);
			}
			MapFiles.Export(other, scope $"{maps}/Missing.tmap" , "Missing Things", "", "", problems).IgnoreError();
			Check(problems.Count == 1 && problems[0].Contains("Models/missing.glb"), "Export says when the scene names a file the project does not have");
			GamePaths.Game.Set("Another Game");
			MapFiles.Export(other, scope $"{maps}/Foreign.tmap" , "Foreign", "", "", problems).IgnoreError();
			GamePaths.Game.Set("Map Test");
			let scene = "scene \"Odd\"\nobject 1 parent 0 active 1 name \"Odd\"\ntransform 0 0 0 0 0 0 1 1 1 1\ncomponent Nowhere.Gizmo enabled 1\n";
			let info = "tmap 1\nid odd-1\nname Odd\ngame Map Test\n";
			let newer = "tmap 99\nid newer-1\nname Newer\ngame Map Test\n";
			(StringView name, Span<uint8> data)[2] oddFiles = .(("map.txt", .((uint8*)info.Ptr, info.Length)), ("map.tscene", .((uint8*)scene.Ptr, scene.Length)));
			PackFile.Write(scope $"{maps}/Odd.tmap" , oddFiles).IgnoreError();
			(StringView name, Span<uint8> data)[2] newerFiles = .(("map.txt", .((uint8*)newer.Ptr, newer.Length)), ("map.tscene", .((uint8*)scene.Ptr, scene.Length)));
			PackFile.Write(scope $"{maps}/Newer.tmap" , newerFiles).IgnoreError();

			let found = scope List<MapFileInfo>();
			defer
			{
				ClearAndDeleteItems!(found);
			}
			let playable = MapFiles.Find(maps, found);
			Check(playable == 1 && found.Count == 8, scope $"of eight map files only the good one can be played ({playable} of {found.Count})");
			let junk = Named(found, "/Junk.tmap");
			Check(junk != null && HasProblem(junk, "not a map file"), "a file that is not a map says so");
			let damaged = Named(found, "/Damaged.tmap");
			Check(damaged != null && HasProblem(damaged, "damaged"), "a changed map file is caught by its checksums");
			let foreign = Named(found, "/Foreign.tmap");
			Check(foreign != null && HasProblem(foreign, "made for Another Game"), "a map for another game is refused");
			let missing = Named(found, "/Missing.tmap");
			Check(missing != null && HasProblem(missing, "needs Models/missing.glb"), "a map that needs a file the game lacks is refused");
			let odd = Named(found, "/Odd.tmap");
			Check(odd != null && HasProblem(odd, "uses Nowhere.Gizmo"), "a map with a component the game lacks is refused");
			let newerMap = Named(found, "/Newer.tmap");
			Check(newerMap != null && HasProblem(newerMap, "newer version"), "a map from a newer engine is refused");
			let original = Named(found, "/Level.tmap");
			let copy = Named(found, "/Copy of Level.tmap");
			Check(copy != null && original != null && copy.Id == original.Id && (copy.Ok != original.Ok), "a renamed copy is the same map, and only one of the two is listed as playable");
			Check(junk != null && !MapFiles.Mount(junk), "a map with problems cannot be mounted");
		}

		// ---- a game's MapRules.txt: what a map needs ----
		{
			let rulesFile = scope $"{folder}/{MapRules.FileName}";
			File.WriteAllText(rulesFile, "# test rules\nneed 3 Tallow.SpawnPoint \"spawn points\"\nneed 2 Tallow.SpawnPoint team = 1 \"blue spawn points\"\nneed 3 Tallow.SpawnPoint clearRadius >= 1 \"roomy spawn points\"\nignore Scenes/Menu.tscene\n").IgnoreError();
			let rules = scope List<MapRule>();
			let ignored = scope List<String>();
			defer
			{
				ClearAndDeleteItems!(rules);
				ClearAndDeleteItems!(ignored);
			}
			MapRules.Load(rules, ignored);
			Check(MapRules.Exists && rules.Count == 3 && ignored.Count == 1 && rules[1].Field == "team" && rules[1].What == "blue spawn points", "MapRules.txt is read: three rules and a scene that is not a map");
			let text = "object 1 parent 0 active 1 name \"A\"\ncomponent Tallow.SpawnPoint enabled 1\nfield team 1\nfield clearRadius 0.5\nobject 2 parent 0 active 1 name \"B\"\ncomponent Tallow.SpawnPoint enabled 1\ncomponent Tallow.MeshRenderer enabled 1\nfield team 1\nobject 3 parent 0 active 1 name \"C\"\ncomponent Tallow.SpawnPoint enabled 1\nfield team 1\n";
			Check(MapRules.Count(text, rules[0]) == 3, "a rule counts the components of its type");
			Check(MapRules.Count(text, rules[1]) == 2, "a field test counts only components that pass it, not another component's field");
			Check(MapRules.Count(text, rules[2]) == 2, "a component that leaves a field out has the field's default (clearRadius 1)");
			let problems = scope List<String>();
			defer
			{
				ClearAndDeleteItems!(problems);
			}
			MapRules.Check(text, problems);
			Check(problems.Count == 1 && problems[0] == "It needs at least 3 roomy spawn points and has 2.", scope $"Check says what is missing ({(problems.Count > 0 ? problems[0] : "")})");
			let found = scope List<MapFileInfo>();
			defer
			{
				ClearAndDeleteItems!(found);
			}
			MapFiles.Find(maps, found);
			let level = Named(found, "/Level.tmap");
			Check(level != null && !level.Ok && HasProblem(level, "needs at least 3 spawn points and has 1"), "Find refuses a map that breaks the game's rules");
			Check(MapRules.Ignores(scope $"{folder}/Scenes/Menu.tscene") && !MapRules.Ignores("Scenes/Level.tscene"), "ignore names scenes that are not maps");
			Check(MapRules.Ignore("Scenes/Level.tscene") case .Ok && MapRules.Ignores("Scenes/Level.tscene"), "Ignore adds a scene to the rules file");
			File.Delete(rulesFile).IgnoreError();
		}

		// ---- a map's hash, a "most" rule, a map saved from a running game with a model of its own ----
		let ownModel = scope String();
		{
			let found = scope List<MapFileInfo>();
			defer
			{
				ClearAndDeleteItems!(found);
			}
			MapFiles.Find(maps, found);
			let level = Named(found, "/Level.tmap");
			let bytes = scope List<uint8>();
			File.ReadAll(scope $"{maps}/Level.tmap" , bytes).IgnoreError();
			Check(level != null && level.Hash.Length == 16 && level.Hash == MapFiles.Hash(bytes, .. scope .()) && level.Bytes == bytes.Count,
				"each map has its file's hash and size");
			let damaged = Named(found, "/Damaged.tmap");
			Check(damaged != null && damaged.Hash != level.Hash, "a changed copy has another hash");

			let rulesFile = scope $"{folder}/{MapRules.FileName}";
			File.WriteAllText(rulesFile, "most 2 Tallow.Rigidbody \"physics items\"\n").IgnoreError();
			let three = "object 1 parent 0 active 1 name \"A\"\ncomponent Tallow.Rigidbody enabled 1\nobject 2 parent 0 active 1 name \"B\"\ncomponent Tallow.Rigidbody enabled 1\nobject 3 parent 0 active 1 name \"C\"\ncomponent Tallow.Rigidbody enabled 1\n";
			let problems = scope List<String>();
			defer
			{
				ClearAndDeleteItems!(problems);
			}
			MapRules.Check(three, problems);
			Check(problems.Count == 1 && problems[0] == "It can have at most 2 physics items and has 3.", scope $"a most rule limits how many a map has ({(problems.Count > 0 ? problems[0] : "")})");
			ClearAndDeleteItems!(problems);
			MapRules.Check(StringView(three, 0, three.IndexOf("object 3")), problems);
			Check(problems.Count == 0, "and passes a map within the limit");
			File.Delete(rulesFile).IgnoreError();

			// A level loaded into a running game, as a map editor holds it, with a model brought in from outside.
			let game = scope Scene();
			Scene.Active = game;
			game.Name.Set("Game");
			game.CreateGameObject("Game logic").AddComponent<SpawnPoint>();
			let group = game.CreateGameObject("Built");
			group.Transient = true;
			let model = scope List<uint8>();
			// The test runs in its own folder (Tests/Maps).
			File.ReadAll("../SkinnedMaterials/assets/plain.glb", model).IgnoreError();
			AssetPack.AddMemoryFile(scope $"{folder}/.maps/editing-1/models/plain.glb" , model);
			let piece = game.CreateGameObject("My model");
			piece.Transform.SetParent(group.Transform, false);
			piece.AddComponent<MeshRenderer>().mesh.Set(".maps/editing-1/models/plain.glb");
			for (int i < 2)
			{
				let spawn = game.CreateGameObject("Spawn");
				spawn.Transform.SetParent(group.Transform, false);
				spawn.AddComponent<SpawnPoint>();
			}
			let file = scope $"{maps}/Built.tmap";
			let exported = MapFiles.Export(game, group, file, "built-keep", "Built in game", "A player", "", problems) case .Ok;
			Check(exported && problems.Count == 0 && model.Count > 0, scope $"a level loaded into a game saves as a map, with its own model ({problems.Count} problems)");
			let pack = scope PackFile();
			let scene = scope List<uint8>();
			Check(pack.Open(file) case .Ok && pack.Has("models/plain.glb") && pack.Read("map.tscene", scene) case .Ok, "the model travels inside the map");
			let text = StringView((char8*)scene.Ptr, scene.Count);
			Check(text.Contains("\".maps/built-keep/models/plain.glb\"") && !text.Contains("editing-1") && !text.Contains("Game logic") && !text.Contains("\"Built\""),
				"only what is under the level is saved, and the model's path is the map's");
			AssetPack.RemoveMemoryFiles(scope $"{folder}/.maps/editing-1");

			ClearAndDeleteItems!(found);
			MapFiles.Find(maps, found);
			let built = Named(found, "/Built.tmap");
			Check(built != null && built.Ok && built.Id == "built-keep" && built.CountComponents("Tallow.SpawnPoint") == 2, "it keeps the Id it was saved with, and is playable");
			let path = ".maps/built-keep/models/plain.glb";
			ownModel.Set(path);
			Check(built != null && MapFiles.Mount(built) && Assets.FileExists(path), "mounted, its model can be read");
			let mesh = Assets.BuildModel(path);
			Check(mesh != null && mesh.Vertices.Count > 0, scope $"and the model loads from inside the map ({mesh?.Vertices.Count ?? 0} vertices)");
			delete mesh;
			if (built != null)
				MapFiles.Unmount(built);
			Check(!Assets.FileExists(path), "unmounted, it is gone");
		}

		// ---- a player who lacks the host's map downloads it ----
		{
			let found = scope List<MapFileInfo>();
			defer
			{
				ClearAndDeleteItems!(found);
			}
			MapFiles.Find(maps, found);
			let built = Named(found, "/Built.tmap");
			let downloads = scope $"{folder}/Downloads";
			Directory.CreateDirectory(downloads).IgnoreError();
			Empty(downloads);
			MapSharing.Folder = downloads;
			Check(!MapSharing.Have(built.Id, built.Hash), "the player does not have the map");

			Time.DeltaTime = Time.FixedDeltaTime;
			let port = (uint16)(47000 + (DateTime.Now.Ticks / 10000) % 900);
			let host = scope Scene();
			let player = scope Scene();
			let scenes = scope List<Scene>() { host, player };
			for (let scene in scenes)
			{
				scene.StartPlay();
				scene.Network = new NetworkManager(scene);
			}
			MapSharing.Offer(built);
			host.Network.StartServer(port, true);
			player.Network.StartClient("127.0.0.1", port);
			for (int i = 0; i < 100 && player.Network.LocalClientId <= 0; i++)
			{
				for (let scene in scenes)
				{
					Scene.Active = scene;
					scene.FixedUpdate();
				}
				Thread.Sleep(2);
			}
			Check(player.Network.LocalClientId > 0, "the player joins the host");

			// Downloads a map, pumping both machines until it is done or has failed.
			int Download(StringView id, StringView hash)
			{
				Scene.Active = player;
				MapSharing.Request(player.Network, id, hash);
				int ticks = 0;
				while (ticks < 3000 && (MapSharing.State == .Asking || MapSharing.State == .Downloading))
				{
					for (let scene in scenes)
					{
						Scene.Active = scene;
						scene.FixedUpdate();
					}
					Thread.Sleep(1);
					ticks++;
				}
				return ticks;
			}
			let ticks = Download(built.Id, built.Hash);
			let copy = scope List<uint8>();
			File.ReadAll(MapSharing.DownloadedFile, copy).IgnoreError();
			let arrived = scope $"the map comes from the host, whole, into the player's Maps folder ({ticks} ticks, {MapSharing.Error})";
			Check(MapSharing.State == .Done && MapFiles.Hash(copy, .. scope .()) == built.Hash && MapSharing.DownloadedFile.EndsWith("/Built in game.tmap"), arrived);
			Check(MapSharing.Have(built.Id, built.Hash), "after which the player has it");

			// An older version of the same map, under another name: replaced by the host's.
			if (copy.IsEmpty)
				copy.Add(0);
			copy[copy.Count - 1] ^= 1;
			File.Delete(MapSharing.DownloadedFile).IgnoreError();
			File.WriteAll(scope $"{downloads}/My old copy.tmap" , copy).IgnoreError();
			Check(!MapSharing.Have(built.Id, built.Hash), "a player with another version of the map does not have the host's");
			Download(built.Id, built.Hash);
			Check(MapSharing.State == .Done && MapSharing.DownloadedFile.EndsWith("/My old copy.tmap") && MapSharing.Have(built.Id, built.Hash),
				"downloading it replaces the old version");

			// A bigger map (3 MB) comes in many pieces, a few at a time.
			{
				let blob = scope List<uint8>();
				let random = scope Random(7);
				for (int i < 3 * 1024 * 1024)
					blob.Add((uint8)random.Next(256));
				let info = "tmap 1\nid big-1\nname Big\ngame Map Test\n";
				let scene = "scene \"Big\"\nobject 1 parent 0 active 1 name \"Big\"\ntransform 0 0 0 0 0 0 1 1 1 1\n";
				(StringView name, Span<uint8> data)[3] bigFiles = .(("map.txt", .((uint8*)info.Ptr, info.Length)), ("map.tscene", .((uint8*)scene.Ptr, scene.Length)), ("models/big.bin", blob));
				PackFile.Write(scope $"{maps}/Big.tmap" , bigFiles).IgnoreError();
				let big = MapFiles.Check(scope $"{maps}/Big.tmap");
				defer delete big;
				MapSharing.Offer(big);
				let bigTicks = Download(big.Id, big.Hash);
				let label = scope $"a 3 MB map arrives whole, in pieces ({bigTicks} ticks, {MapSharing.Error})";
				Check(MapSharing.State == .Done && MapSharing.Have(big.Id, big.Hash) && bigTicks > 10, label);
			}

			Download("no-such-map", "0123456789abcdef");
			Check(MapSharing.State == .Failed && MapSharing.Error.Contains("does not have"), "a map the host does not have fails, saying why");
			MapSharing.Reset();
			for (let scene in scenes)
			{
				scene.Network.Stop();
				scene.StopPlay();
			}
		}

		Console.WriteLine(sFailures == 0 ? "ALL MAP TESTS PASSED" : scope $"{sFailures} MAP TESTS FAILED");
		return sFailures == 0 ? 0 : 1;
	}
}
