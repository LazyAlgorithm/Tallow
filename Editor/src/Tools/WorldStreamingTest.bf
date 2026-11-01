using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// Test switch --world-streaming-test: builds a 5 x 5 cell world, saves it as cells, opens it again with only the
/// cells round a point, takes one out and saves, moves an object into a cell that is not loaded, then plays it with
/// a Streaming Source walking across (loading in the background, taking far cells out, stand-ins, floating origin).
/// Puts the scene back, removes its files and logs WORLD-STREAMING-TEST PASS or FAIL.
extension EditorApp
{
	void RunWorldStreamingTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		let stash = SceneSerializer.Save(mScene, .. scope .());
		let stashPath = scope String(mScene.Path);
		let folder = scope $"{Assets.ProjectPath}/WorldStreamingTest";
		Directory.CreateDirectory(folder).IgnoreError();
		let path = scope $"{folder}/World.tscene";
		let cells = scope $"{folder}/World.cells";

		// The world: a sun and a marker that stay, and a cube in the middle of each of 25 cells (50 m), in a folder.
		SceneSerializer.Load(mScene, "scene \"World\"\n");
		let env = mScene.Environment;
		env.streaming = true;
		env.streamCellSize = 50;
		env.streamLoadRadius = 60;
		env.streamStandInRadius = 400;
		mScene.CreateGameObject("Sun").AddComponent<Light>();
		let rock = mScene.CreateGameObject("Rock");
		rock.Transform.Position = .(80, 0, 20);
		let marker = mScene.CreateGameObject("Marker");
		marker.AlwaysLoaded = true;
		let props = mScene.CreateGameObject("Props");
		props.IsFolder = true;
		let ids = new Dictionary<String, uint32>();
		defer
		{
			DeleteDictionaryAndKeys!(ids);
		}
		for (int x < 5)
		{
			for (int z < 5)
			{
				let cube = mScene.CreateGameObject(scope $"Cube {x} {z}" , props.Transform);
				cube.Transform.Position = .(x * 50 + 25, 0, z * 50 + 25);
				cube.AddComponent<MeshRenderer>();
				ids[new String(cube.Name)] = cube.Id;
			}
		}
		Expect(SceneSerializer.SaveToFile(mScene, path), "a streamed world saves");
		let main = scope String();
		File.ReadAllText(path, main).IgnoreError();
		int count = 0;
		for (let entry in Directory.EnumerateFiles(cells, "*.tcell"))
			count++;
		Expect(count == 25 && main.Contains("streamcell 4 4") && !main.Contains("Cube 2 2") && main.Contains("Marker") && main.Contains("Sun"), scope $"each cell has a file and the scene file only what stays ({count} cells)");
		Expect(File.Exists(scope $"{cells}/2_2.standin.tmesh"), "each cell has a stand-in");

		int CubesLoaded()
		{
			int n = 0;
			for (let child in mScene.Find("Props")?.Transform.Children ?? scope List<Transform>())
				n += child.GameObject.Name.StartsWith("Cube") ? 1 : 0;
			return n;
		}

		// Opened again: nothing but what stays, until the cells round a point are loaded.
		SceneSerializer.LoadFromFile(mScene, path);
		var streamer = mScene.Streamer;
		Expect(streamer != null && streamer.Cells.Count == 25 && CubesLoaded() == 0 && mScene.Find("Marker") != null, "opening it loads no cells");
		streamer.LoadAround(mScene, .(25, 0, 25));
		let cube11 = mScene.Find("Cube 1 1");
		Expect(CubesLoaded() == 4 && streamer.Loaded.Count == 4, scope $"the cells round a point load ({CubesLoaded()})");
		Expect(cube11 != null && cube11.Id == ids["Cube 1 1"] && cube11.Transform.Parent?.GameObject == mScene.Find("Props"), "objects keep their ids and their folder");
		let fresh = mScene.CreateGameObject("New");
		Expect(fresh.Id > ids["Cube 4 4"], "new objects never take the ids of cells not loaded");
		mScene.DestroyImmediate(fresh);

		// Taken out in the editor, then saved: the cell keeps its object.
		streamer.Unload(mScene, WorldStreamer.Key(1, 1), true);
		Expect(CubesLoaded() == 3 && streamer.IsHeld(WorldStreamer.Key(1, 1)), "a cell taken out is held until saved");
		// Moved into a cell that is not loaded: that cell comes in on saving, and the old one is left empty.
		let cube00 = mScene.Find("Cube 0 0");
		cube00.Transform.Position = .(230, 0, 230);
		SceneSerializer.SaveToFile(mScene, path);
		let cell44 = scope String();
		File.ReadAllText(scope $"{cells}/4_4.tcell" , cell44).IgnoreError();
		let cell11 = scope String();
		File.ReadAllText(scope $"{cells}/1_1.tcell" , cell11).IgnoreError();
		Expect(cell44.Contains("Cube 0 0") && cell44.Contains("Cube 4 4"), "an object moved into a cell not loaded is saved with that cell's own");
		Expect(!File.Exists(scope $"{cells}/0_0.tcell") && streamer.Cells.Count == 24, "a cell left empty goes");
		Expect(cell11.Contains("Cube 1 1"), "the held cell is written");

		// Playing: a source walks across the world.
		SceneSerializer.LoadFromFile(mScene, path);
		streamer = mScene.Streamer;
		let walker = mScene.CreateGameObject("Walker");
		walker.AlwaysLoaded = true;
		walker.AddComponent<StreamingSource>();
		walker.Transform.Position = .(25, 0, 75);
		mScene.StartPlay();
		void Run(int frames)
		{
			for (int i < frames)
			{
				SceneManager.Update(mScene);
				Thread.Sleep(2);
			}
		}
		Run(2);
		Expect(streamer.Loaded.Contains(WorldStreamer.Key(0, 1)) && !streamer.Loaded.Contains(WorldStreamer.Key(4, 4)), "the first frame loads round the source at once");
		Expect(streamer.HasStandIn(mScene, WorldStreamer.Key(4, 4)), "cells further out show stand-ins");
		let added = streamer.CellsAdded;
		walker.Transform.Position = .(225, 0, 175);
		int frames = 0;
		while (frames < 600 && (!streamer.Loaded.Contains(WorldStreamer.Key(4, 3)) || streamer.Loaded.Contains(WorldStreamer.Key(0, 1)) || streamer.Loading))
		{
			Run(1);
			frames++;
		}
		Expect(streamer.Loaded.Contains(WorldStreamer.Key(4, 3)) && !streamer.Loaded.Contains(WorldStreamer.Key(0, 1)), scope $"cells come in round the source and far ones go ({frames} frames)");
		Expect(streamer.CellsAdded - added >= 2 && frames >= 2, "cells are added over several frames, not all at once");
		Expect(!streamer.HasStandIn(mScene, WorldStreamer.Key(4, 3)), "a loaded cell shows no stand-in");

		// Floating origin: far from the centre, the world moves back round the source.
		env.floatingOrigin = 100;
		let cube43 = mScene.Find("Cube 4 3");
		Run(1);
		Expect(streamer.Origin != .Zero && Vector3.Distance(walker.Transform.Position, .(225, 0, 175) - streamer.Origin) < 0.01f, scope $"the floating origin moves the world ({streamer.Origin})");
		Expect(cube43 != null && Vector3.Distance(cube43.Transform.Position + streamer.Origin, .(225, 0, 175)) < 0.01f, "objects keep their places in the world");
		walker.Transform.Position = .(-150, 0, -150);
		frames = 0;
		while (frames < 600 && !streamer.Loaded.Contains(WorldStreamer.Key(1, 0)))
		{
			Run(1);
			frames++;
		}
		let cube10 = mScene.Find("Cube 1 0");
		let rockAfter = mScene.Find("Rock");
		Expect(cube10 != null && Vector3.Distance(cube10.Transform.Position + streamer.Origin, .(75, 0, 25)) < 0.01f, "cells loaded after a move come in at their places (in a folder)");
		Expect(rockAfter != null && Vector3.Distance(rockAfter.Transform.Position + streamer.Origin, .(80, 0, 20)) < 0.01f, "cells loaded after a move come in at their places (at the top)");
		mScene.StopPlay();

		// Put everything back.
		SceneSerializer.Load(mScene, stash);
		mScene.Path.Set(stashPath);
		DeleteAndNullify!(mScene.Streamer);
		Directory.DelTree(folder).IgnoreError();
		Log.Info(scope $"WORLD-STREAMING-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}
}
