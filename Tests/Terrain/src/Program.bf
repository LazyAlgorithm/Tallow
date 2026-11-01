using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace TerrainTests;

/// A game's own generator: a plateau 6 m high.
[TerrainGenerator]
class Plateau : TerrainGenerator
{
	public override float Density(float x, float y, float z) => 6 - y;
	public override bool Paints => true;
	public override uint8 Paint(float x, float y, float z) => 3;
}

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

	/// Runs frames until the terrain has stopped loading, or a time limit passes.
	static void Settle(Scene scene, VoxelTerrain terrain)
	{
		int stable = 0, last = -1;
		for (int i = 0; i < 4000 && stable < 40; i++)
		{
			Time.DeltaTime = 0.016f;
			Time.UnscaledDeltaTime = 0.016f;
			scene.Update();
			Thread.Sleep(2);
			let busy = terrain.PendingChunks;
			if (terrain.ChunkCount == last && busy == 0)
				stable++;
			else
				stable = 0;
			last = terrain.ChunkCount;
		}
	}

	static void SaveScene(Scene scene, StringView path)
	{
		SceneSerializer.SaveToFile(scene, path);
	}

	static bool LoadScene(Scene scene, StringView path)
	{
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err)
			return false;
		SceneSerializer.Load(scene, text);
		return true;
	}

	/// The height of the ground under a point, or NaN where there is none.
	static float Ground(VoxelTerrain terrain, float x, float z)
	{
		Vector3 point;
		if (terrain.Raycast(Ray(.(x, 60, z), .(0, -1, 0)), 200, out point))
			return point.y;
		return float.NaN;
	}

	static bool Flat(VoxelTerrain terrain, float x, float z, float height = 0) => Math.Abs(Ground(terrain, x, z) - height) < 0.6f;

	/// Vertices of a chunk's mesh lying on the plane x = planeX, rounded, with their normals.
	static void PlaneVertices(Mesh mesh, float planeX, List<(int32, int32, int32, int32)> list)
	{
		if (mesh == null)
			return;
		for (let v in mesh.Vertices)
		{
			if (Math.Abs(v.position.x - planeX) > 0.001f)
				continue;
			list.Add(((int32)Math.Round(v.position.y * 100), (int32)Math.Round(v.position.z * 100), (int32)Math.Round(v.normal.y * 50), (int32)Math.Round(v.normal.x * 50)));
		}
		list.Sort(scope (a, b) => a.0 != b.0 ? a.0 <=> b.0 : (a.1 != b.1 ? a.1 <=> b.1 : (a.2 != b.2 ? a.2 <=> b.2 : a.3 <=> b.3)));
	}

	static VoxelTerrain MakeTerrain(Scene scene)
	{
		let terrain = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
		terrain.voxelSize = 1;
		terrain.tileSize = 4;
		terrain.sizeX = 4;
		terrain.sizeZ = 4;
		terrain.style = .Smooth;
		terrain.generateColliders = false;
		terrain.lodDistance = 0;
		terrain.OnValidate();
		return terrain;
	}

	public static int Main(String[] args)
	{
		let folder = "/tmp/tallow-terrain-test";
		Directory.CreateDirectory(folder).IgnoreError();
		let edits = scope $"{folder}/Level.terrain";
		for (let entry in Directory.EnumerateFiles(edits))
			File.Delete(entry.GetFilePath(.. scope .())).IgnoreError();
		VoxelTerrain.Viewers.Clear();

		// ---- what a terrain is when nothing has been set ----
		{
			let scene = scope Scene();
			let fresh = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
			fresh.OnValidate();
			Check(fresh.mode == .Fixed && fresh.style == .Contoured && fresh.voxelSize == 0.5f && fresh.TileCount == 1 && fresh.AreaSize.x == 128,
scope $"a new terrain is one flat 128 m tile of half-metre cells, contoured (mode {fresh.mode}, style {fresh.style}, voxel {fresh.voxelSize}, tiles {fresh.TileCount}, tile size {fresh.tileSize}, area {fresh.AreaSize.x})");
		}

		// ---- one tile, placed by hand ----
		{
			let scene = scope Scene();
			let terrain = MakeTerrain(scene);
			Check(terrain.mode == .Fixed && terrain.TileCount == 1 && terrain.tileSize == 4 && terrain.AreaSize.x == 128 && terrain.TileAt(0, 0) != 0,
				"a new terrain is one flat tile of 4 x 4 chunks (128 m), not an endless world");
			scene.StartPlay();
			VoxelTerrain.ViewerPosition = .(5000, 0, 5000); // the camera far away: tiles do not care
			Settle(scene, terrain);
			Check(terrain.ChunkCount == 4 * 4 * 4, scope $"the whole tile is loaded wherever the camera is ({terrain.ChunkCount} chunks)");
			Check(Flat(terrain, 64, 64) && Flat(terrain, 3, 3) && Flat(terrain, 120, 125), "it starts flat at height 0");
			Check(Ground(terrain, -10, 64).IsNaN && Ground(terrain, 64, 140).IsNaN && Ground(terrain, 300, 300).IsNaN, "there is no ground beyond its edge");

			// ---- neighbours in all four directions ----
			let east = terrain.AddTile(1, 0), west = terrain.AddTile(-1, 0), north = terrain.AddTile(0, 1), south = terrain.AddTile(0, -1);
			let twice = terrain.AddTile(1, 0);
			Settle(scene, terrain);
			Check(east != 0 && west != 0 && north != 0 && south != 0 && twice == 0 && terrain.TileCount == 5 && terrain.ChunkCount == 5 * 64,
scope $"tiles added on all four sides line up on the grid, and a taken place is refused ({terrain.TileCount} tiles, {terrain.ChunkCount} chunks)");
			Check(Flat(terrain, 128, 64) && Flat(terrain, 127.5f, 64) && Flat(terrain, 128.5f, 64) && Flat(terrain, -0.3f, 64) && Flat(terrain, 64, 0) && Flat(terrain, 64, 128) && Flat(terrain, 200, 64) && Flat(terrain, -100, 64),
				"the ground runs on across the edges between tiles, with no gap or wall");
			Check(Ground(terrain, 200, 200).IsNaN && Ground(terrain, -100, -100).IsNaN, "corners with no tile have no ground");
			Check(terrain.SeamMismatches() == 0, "every chunk and tile edge starts out matching");

			// ---- sculpting and painting across a tile edge ----
			terrain.BeginEditRecord();
			terrain.ModifySphere(.(128, 0, 64), 9, 6);
			Settle(scene, terrain);
			let record = terrain.EndEditRecord();
			let left = Ground(terrain, 125, 64), right = Ground(terrain, 131, 64), top = Ground(terrain, 128, 64);
			Check(top > 2 && Math.Abs(left - right) < 0.3f, scope $"a hill raised on the edge between two tiles is one hill ({left:0.00} and {right:0.00} either side, {top:0.0} on top)");
			terrain.Brush(.(128, 0, 64), 7, 0.8f, .Smooth);
			terrain.Brush(.(128, 2, 64), 6, 1, .Paint, 4);
			terrain.Brush(.(140, 0, 70), 6, 0.6f, .Flatten, 0, 1.5f);
			terrain.ModifySphere(.(64, 0, 128), 7, -6);
			Settle(scene, terrain);
			Check(terrain.SeamMismatches() == 0, scope $"after raising, smoothing, painting, flattening and digging across edges, both copies of every shared sample agree ({terrain.SeamMismatches()} differ)");
			List<(int32, int32, int32, int32)> fromWest = scope .(), fromEast = scope .();
			PlaneVertices(terrain.ChunkMesh(.(3, 0, 2)), 128, fromWest);
			PlaneVertices(terrain.ChunkMesh(.(4, 0, 2)), 128, fromEast);
			bool same = fromWest.Count > 4 && fromWest.Count == fromEast.Count;
			for (int i < Math.Min(fromWest.Count, fromEast.Count))
				same &= fromWest[i] == fromEast[i];
			if (!same)
			{
				for (let v in fromWest)
					Console.WriteLine(scope $"  W {v.0} {v.1} {v.2} {v.3}");
				for (let v in fromEast)
					Console.WriteLine(scope $"  E {v.0} {v.1} {v.2} {v.3}");
			}
			Check(same, scope $"the meshes on either side of the tile edge meet vertex for vertex, with the same normals ({fromWest.Count} and {fromEast.Count} edge vertices)");

			// ---- undo ----
			Check(record != null && record.Count >= 2, "a stroke's chunks can be recorded for undo");
			terrain.ApplyEditRecord(record, true);
			Settle(scene, terrain);
			let undone = Ground(terrain, 126, 60);
			terrain.ApplyEditRecord(record, false);
			Settle(scene, terrain);
			let redone = Ground(terrain, 126, 60);
			Check(Math.Abs(undone) < 0.6f && redone > 1, scope $"undo takes the hill away and redo brings it back ({undone:0.0}, {redone:0.0})");
			delete record;

			// ---- holes, moving, and taking a tile away ----
			terrain.ModifySphere(.(64, 0, -64), 8, 6); // a hill in the south tile
			Settle(scene, terrain);
			let southHill = Ground(terrain, 64, -64);
			Check(terrain.MoveTile(south, 2, 0) && terrain.TileAt(0, -1) == 0, "a tile can be moved to an empty place");
			Settle(scene, terrain);
			Check(Ground(terrain, 64, -64).IsNaN && Math.Abs(Ground(terrain, 320, 64) - southHill) < 0.3f && Flat(terrain, 64, 120),
scope $"its sculpting goes with it, and where it was is a hole ({Ground(terrain, 320, 64):0.0} where it went)");
			Check(!terrain.MoveTile(east, 0, 0), "it cannot be moved onto another tile");
			List<TerrainTile> before = scope .();
			terrain.GetTiles(before);
			terrain.RemoveTile(south);
			Settle(scene, terrain);
			Check(Ground(terrain, 320, 64).IsNaN && terrain.TileCount == 4 && Flat(terrain, 250, 64), "a removed tile leaves a hole, and the tile beside it ends cleanly");
			terrain.SetTiles(before); // what undo does
			Settle(scene, terrain);
			Check(Math.Abs(Ground(terrain, 320, 64) - southHill) < 0.3f, "putting the tiles back as they were (undo) brings the tile back with its sculpting");

			// ---- saved per tile ----
			terrain.editsFolder.Set(edits);
			SaveScene(scene, scope $"{folder}/tiles.tscene");
			int files = 0;
			for (let entry in Directory.EnumerateFiles(edits))
				files++;
			Check(files >= 3 && !terrain.HasUnsavedEdits, scope $"saving writes one file for each sculpted tile ({files})");
			List<uint8> bytes = scope .();
			terrain.SaveEdits(bytes);
			File.WriteAll(scope $"{folder}/old.voxels" , bytes).IgnoreError();

			// ---- generators ----
			terrain.generator.Set("Plateau");
			terrain.OnValidate();
			Settle(scene, terrain);
			Check(Math.Abs(Ground(terrain, 40, 40) - 6) < 0.6f && Math.Abs(Ground(terrain, -100, 64) - 6) < 0.6f && Math.Abs(Ground(terrain, 128, 64) - top) < 1.0f && Ground(terrain, 200, 200).IsNaN,
scope $"a generator class named on the terrain shapes ground nobody has sculpted, only inside the tiles ({Ground(terrain, 40, 40):0.0}, {Ground(terrain, -100, 64):0.0}, {Ground(terrain, 128, 64):0.0} on the hill)");
			terrain.generator.Clear();
			terrain.OnValidate();
			Settle(scene, terrain);
			let plateau = scope Plateau();
			terrain.BeginEditRecord();
			terrain.ApplyGenerator(plateau, west);
			Settle(scene, terrain);
			let bake = terrain.EndEditRecord();
			Check(Math.Abs(Ground(terrain, -64, 64) - 6) < 0.6f && Flat(terrain, 64, 64) && terrain.SeamMismatches() == 0,
scope $"a generator applied to one tile shapes that tile alone, and the edge it shares still matches ({Ground(terrain, -64, 64):0.0})");
			terrain.ApplyEditRecord(bake, true);
			Settle(scene, terrain);
			Check(Flat(terrain, -64, 64), "and undo puts the tile back");
			delete bake;
			terrain.SetGenerator(new (x, y, z) => (x * 0.1f) - y); // a ramp rising along X
			Settle(scene, terrain);
			Check(Math.Abs(Ground(terrain, 20, 100) - 2) < 0.7f && Math.Abs(Ground(terrain, 100, 100) - 10) < 0.7f && Ground(terrain, 200, 200).IsNaN, "a generator function from code works too");
			terrain.SetGenerator(null);
			Settle(scene, terrain);
			Check(Flat(terrain, 100, 100), "and removing it brings the flat ground back");

			// ---- streaming tiles, level of detail ----
			for (int32 x = 3; x < 9; x++)
				terrain.AddTile(x, 0);
			terrain.streamTiles = true;
			terrain.viewDistance = 3;
			terrain.lodDistance = 1;
			terrain.OnValidate();
			VoxelTerrain.ViewerPosition = .(64, 0, 64);
			Settle(scene, terrain);
			let nearOnly = terrain.ChunkCount;
			Check(nearOnly < 300 && !Ground(terrain, 64, 64).IsNaN && Ground(terrain, 1000, 64).IsNaN, scope $"Stream Tiles loads only the tiles near the camera ({nearOnly} chunks)");
			VoxelTerrain.Viewers.Add(.(1000, 0, 64));
			Settle(scene, terrain);
			Check(!Ground(terrain, 1000, 64).IsNaN && !Ground(terrain, 64, 64).IsNaN, "and near every viewer: a server's players each get the ground around them");
			VoxelTerrain.Viewers.Clear();
			Check(terrain.ChunkLod(.(2, 0, 2)) == 0 && terrain.ChunkLod(.(4, 0, 2)) >= 1, scope $"chunks further away are drawn with less detail (lod {terrain.ChunkLod(.(2, 0, 2))} near, {terrain.ChunkLod(.(4, 0, 2))} further)");
			terrain.streamTiles = false;
			terrain.OnValidate();
			Settle(scene, terrain);
			Check(terrain.ChunkLod(.(30, 0, 2)) == 3, scope $"the furthest at an eighth ({terrain.ChunkLod(.(30, 0, 2))})");
			Check(Flat(terrain, 990, 64) && terrain.SeamMismatches() == 0, "detail does not change the ground itself");
			SaveScene(scene, scope $"{folder}/unused.tscene");
		}

		// ---- level of detail with collision ----
		{
			let scene = scope Scene();
			let terrain = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
			terrain.voxelSize = 1;
			terrain.tileSize = 4;
			terrain.sizeX = 4;
			terrain.sizeZ = 4;
			terrain.style = .Smooth;
			terrain.lodDistance = 1;
			for (int32 x = 1; x < 4; x++)
				terrain.AddTile(x, 0);
			scene.StartPlay();
			VoxelTerrain.ViewerPosition = .(16, 0, 16);
			Settle(scene, terrain);
			let far = Int3(13, 0, 1);
			terrain.ModifySphere(.(far.x * 32 + 16, 0, 48), 10, 6);
			Settle(scene, terrain);
			let drawn = terrain.ChunkMesh(far), solid = terrain.ChunkCollisionMesh(far);
			Check(terrain.ChunkLod(far) == 3 && drawn != null && solid != null && solid.Indices.Count > drawn.Indices.Count * 2,
scope $"a far chunk is drawn coarsely but collides at full detail ({drawn?.Indices.Count / 3} triangles drawn, {solid?.Indices.Count / 3} for collision)");
			RaycastHit hit;
			let landed = scene.Physics.Raycast(.(far.x * 32 + 16, 40, 48), .(0, -1, 0), 100, out hit);
			Check(landed && hit.point.y > 2, scope $"and physics stands on its sculpted ground ({hit.point.y:0.0})");
		}

		// ---- loading ----
		{
			let scene = scope Scene();
			let fine = LoadScene(scene, scope $"{folder}/tiles.tscene");
			let terrain = fine ? scene.FindComponent<VoxelTerrain>() : null;
			if (terrain != null)
			{
				terrain.generateColliders = false;
				scene.StartPlay();
				VoxelTerrain.ViewerPosition = .(64, 0, 64);
				Settle(scene, terrain);
			}
			Check(terrain != null && terrain.TileCount == 5 && Math.Abs(Ground(terrain, 320, 64) - 6) > 0.5f && Ground(terrain, 320, 64) > 2 && Ground(terrain, 128, 64) > 2 && Ground(terrain, 64, 128) < -2,
				"a scene loads its tiles and every tile's sculpting from their files");
			Check(terrain != null && terrain.SeamMismatches() == 0, "and the edges still match");
		}
		{
			// The bytes a game keeps itself (in a map file, say), for a terrain made in code from the old size fields.
			let scene = scope Scene();
			let terrain = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
			terrain.voxelSize = 1;
			terrain.tileSize = 4;
			terrain.sizeX = 4;
			terrain.sizeZ = 4;
			terrain.style = .Smooth;
			terrain.generateColliders = false;
			terrain.sizeX = 8;
			terrain.sizeZ = 4;
			List<uint8> bytes = scope .();
			File.ReadAll(scope $"{folder}/old.voxels" , bytes).IgnoreError();
			terrain.LoadEdits(Span<uint8>(bytes.Ptr, bytes.Count));
			terrain.Regenerate();
			scene.StartPlay();
			Settle(scene, terrain);
			Check(terrain.TileCount == 2 && Ground(terrain, 128, 64) > 2 && Ground(terrain, 64, 124) < -2 && terrain.ChunkCount == 2 * 64,
scope $"sculpting kept as bytes loads into a terrain sized with sizeX and sizeZ, as before tiles ({terrain.TileCount} tiles)");
		}

		// ---- endless, by choice ----
		{
			let scene = scope Scene();
			let terrain = MakeTerrain(scene);
			terrain.mode = .Endless;
			terrain.viewDistance = 2;
			scene.StartPlay();
			VoxelTerrain.ViewerPosition = .(0, 0, 0);
			Settle(scene, terrain);
			let hills = Ground(terrain, 10, 10), hills2 = Ground(terrain, -40, 25);
			Check(terrain.ChunkCount > 20 && !hills.IsNaN && !hills2.IsNaN && Math.Abs(hills - hills2) > 0.05f, scope $"Endless mode generates the sample's rolling ground around the camera ({hills:0.0} and {hills2:0.0})");
			VoxelTerrain.ViewerPosition = .(2000, 0, 0);
			Settle(scene, terrain);
			Check(!Ground(terrain, 2000, 5).IsNaN && Ground(terrain, 10, 10).IsNaN, "and follows the camera, dropping what is left behind");
			terrain.generator.Set("Plateau");
			terrain.OnValidate();
			Settle(scene, terrain);
			Check(Math.Abs(Ground(terrain, 2010, -20) - 6) < 0.6f, "a generator of the game's own works in Endless mode too");
			terrain.ModifySphere(.(2000, 6, 0), 6, 6);
			Settle(scene, terrain);
			Check(terrain.SeamMismatches() == 0, "and sculpting there matches across chunks");
			SaveScene(scene, scope $"{folder}/new.tscene");
		}

		// ---- older scenes ----
		{
			let scene = scope Scene();
			Check(LoadScene(scene, scope $"{folder}/new.tscene") && scene.FindComponent<VoxelTerrain>().mode == .Endless, "a scene remembers a terrain's mode");
		}
		{
			// A scene from before tiles: a rectangle of chunks and one file of sculpting.
			let scene = scope Scene();
			let made = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
			made.voxelSize = 1;
			made.tileSize = 4;
			made.sizeX = 4;
			made.sizeZ = 4;
			made.style = .Smooth;
			made.sizeX = 8;
			made.sizeZ = 4;
			SaveScene(scene, scope $"{folder}/rect.tscene");
			let text = scope String();
			File.ReadAllText(scope $"{folder}/rect.tscene" , text).IgnoreError();
			let old = scope String();
			for (let line in text.Split('\n'))
			{
				if (line.StartsWith("field tiles ") || line.StartsWith("field nextTileId ") || line.StartsWith("field editsFolder ") || line.StartsWith("field editsFile "))
					continue;
				old..Append(line).Append('\n');
				if (line.StartsWith("field sizeZ "))
					old.AppendF("field editsFile \"{}/old.voxels\"\n", folder);
			}
			File.WriteAllText(scope $"{folder}/rect.tscene" , old).IgnoreError();
			let loaded = scope Scene();
			let fine = LoadScene(loaded, scope $"{folder}/rect.tscene");
			let terrain = fine ? loaded.FindComponent<VoxelTerrain>() : null;
			if (terrain != null)
			{
				terrain.generateColliders = false;
				loaded.StartPlay();
				Settle(loaded, terrain);
			}
			Check(terrain != null && terrain.mode == .Fixed && terrain.TileCount == 2 && Ground(terrain, 128, 64) > 2 && Ground(terrain, 64, 124) < -2,
				"an older fixed terrain becomes tiles, keeping its sculpting");
			if (terrain != null)
			{
				terrain.editsFolder.Set(scope $"{folder}/Rect.terrain");
				SaveScene(loaded, scope $"{folder}/rect2.tscene");
				Check(terrain.editsFile.IsEmpty && File.Exists(scope $"{folder}/Rect.terrain/tile_1.voxels") && !terrain.tiles.IsEmpty,
					"and the next save writes its tiles and moves its sculpting into a file per tile");
			}
			// Before terrains had a mode.
			let older = scope String();
			for (let line in old.Split('\n'))
			{
				if (!line.StartsWith("field mode ") && !line.StartsWith("field sizeX ") && !line.StartsWith("field sizeZ ") && !line.StartsWith("field flatHeight "))
					older..Append(line).Append('\n');
			}
			File.WriteAllText(scope $"{folder}/older.tscene" , older).IgnoreError();
			let legacy = scope Scene();
			Check(LoadScene(legacy, scope $"{folder}/older.tscene") && legacy.FindComponent<VoxelTerrain>().mode == .Endless, "a scene saved before terrains had a mode keeps its endless terrain");
		}

		// ---- plants follow sculpted ground ----
		{
			let scene = scope Scene();
			let terrain = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
			terrain.voxelSize = 1;
			terrain.tileSize = 4;
			terrain.sizeX = 4;
			terrain.sizeZ = 4;
			terrain.generateColliders = false;
			terrain.lodDistance = 0;
			terrain.OnValidate();
			let grass = terrain.GameObject.AddComponent<Foliage>();
			scene.StartPlay();
			VoxelTerrain.ViewerPosition = .(64, 0, 64);
			Settle(scene, terrain);
			// A cave under the middle of the tile, with grass on its floor as well as on the hill above it.
			terrain.ModifySphere(.(64, -9, 64), 5, -40);
			Settle(scene, terrain);
			float caveFloor = float.NaN;
			for (float y = -9; y > -16; y -= 0.05f)
			{
				float density;
				if (terrain.DensityAt(.(64, y, 64), out density) && density > 0)
				{
					caveFloor = y;
					break;
				}
			}
			float hollow = 1, roof = 0;
			terrain.DensityAt(.(64, -9, 64), out hollow);
			terrain.DensityAt(.(64, -2, 64), out roof);
			Check(!caveFloor.IsNaN && hollow <= 0 && roof > 0, scope $"there is a cave under the hilltop (floor at {caveFloor:0.0}, solid ground above it)");
			grass.Add(.(64, 0, 64)); // 0: on the surface, over the cave
			grass.Add(.(64, caveFloor, 64)); // 1: on the cave floor
			grass.Add(.(30, 0, 30)); // 2: on the surface, where a pit will be dug
			grass.Add(.(100, 0, 100)); // 3: far from everything
			grass.Add(.(30, 0, 100)); // 4: where a hill will bury it deep
			// Raise the ground over the cave, a little at a time as a held brush does.
			for (int i < 12)
				terrain.Brush(.(64, 0, 64), 6, 0.08f, .Raise);
			let top = Ground(terrain, 64, 64);
			Check(top > 1 && Math.Abs(grass.PositionOf(0).y - top) < 0.15f, scope $"grass on ground that is raised rides up with it ({grass.PositionOf(0).y:0.00} on ground at {top:0.00})");
			Check(Math.Abs(grass.PositionOf(1).y - caveFloor) < 0.1f, scope $"grass on the cave floor below stays on the cave floor ({grass.PositionOf(1).y:0.00})");
			for (int i < 12)
				terrain.Brush(.(30, 0, 30), 6, 0.08f, .Lower);
			let pit = Ground(terrain, 30, 30);
			Check(pit < -1 && Math.Abs(grass.PositionOf(2).y - pit) < 0.15f, scope $"grass on ground that is dug away goes down with it ({grass.PositionOf(2).y:0.00} in a pit at {pit:0.00})");
			Check(grass.Count == 5 && Math.Abs(grass.PositionOf(3).y) < 0.01f, "grass away from the brush is not touched");
			// Painting the ground a colour is not sculpting.
			let beforePaint = grass.PositionOf(0).y;
			terrain.Brush(.(64, top, 64), 6, 1, .Paint, 3);
			Check(grass.PositionOf(0).y == beforePaint, "painting the ground does not move plants");
			// A hill dropped on a plant all at once, far higher than the brush reaches up: the plant is buried and goes.
			terrain.ModifySphere(.(30, 6, 100), 9, 60);
			bool buriedGone = grass.Count == 4;
			for (int i < grass.Count)
				buriedGone &= (Vector3(grass.PositionOf(i).x - 30, 0, grass.PositionOf(i).z - 100)).Length > 1;
			Check(buriedGone, scope $"grass buried under a hill is removed ({grass.Count} left)");
			// The cave filled in: the grass on its floor is buried too.
			terrain.ModifySphere(.(64, -9, 64), 7, 60);
			bool caveGone = true;
			for (int i < grass.Count)
				caveGone &= grass.PositionOf(i).y > -5;
			Check(caveGone && grass.Count == 3, scope $"filling the cave in removes the grass that was in it ({grass.Count} left)");
			// The ground cut from under a plant, leaving it in the air: gone as well.
			terrain.ModifySphere(.(100, -7, 100), 9, -60);
			Check(grass.Count == 3 || grass.Count == 2, "a plant keeps its place while there is ground within reach under it");
			scene.StopPlay();
		}

		Scene.Active = null;
		// ---- contoured ground (dual contouring) ----
		{
			let scene = scope Scene();
			let terrain = scene.CreateGameObject("Terrain").AddComponent<VoxelTerrain>();
			terrain.voxelSize = 1;
			terrain.tileSize = 4;
			terrain.sizeX = 4;
			terrain.sizeZ = 4;
			terrain.generateColliders = false;
			terrain.lodDistance = 0;
			terrain.style = .Contoured;
			terrain.OnValidate();
			scene.StartPlay();
			VoxelTerrain.ViewerPosition = .(64, 0, 64);
			Settle(scene, terrain);
			Check(Flat(terrain, 64, 64) && Flat(terrain, 3, 3) && Flat(terrain, 120, 125), "contoured: flat ground is flat at height 0");
			{
				let flatMesh = terrain.ChunkMesh(.(1, -1, 1));
				bool level = flatMesh != null && flatMesh.Vertices.Count > 900;
				if (flatMesh != null)
				{
					for (let v in flatMesh.Vertices)
						level &= Math.Abs(v.position.y) < 0.01f && v.normal.y > 0.999f;
				}
				Check(level, scope $"contoured: the mesh of flat ground is level, facing up ({flatMesh != null ? flatMesh.Vertices.Count : 0} points in a chunk)");
			}
			// A hill and a pit that both straddle chunk edges (chunks are 32 m), and a flattened shelf.
			terrain.ModifySphere(.(64, 0, 64), 9, 6);
			terrain.ModifySphere(.(32, 0, 96), 7, -6);
			terrain.Brush(.(96, 0, 32), 8, 1, .Flatten, 0, 3);
			Settle(scene, terrain);
			Check(Ground(terrain, 64, 64) > 2 && Ground(terrain, 32, 96) < -1.5f, scope $"contoured: sculpting raises and digs ({Ground(terrain, 64, 64):0.0} and {Ground(terrain, 32, 96):0.0})");
			Check(Math.Abs(Ground(terrain, 61, 64) - Ground(terrain, 67, 64)) < 0.3f, "contoured: a hill on the corner of four chunks is one hill");
			// Every edge of every triangle, over all the chunks together, by the places of its two ends: an edge used
			// only once is a hole, unless it is on the rim of the ground (its sides and its underside).
			Dictionary<uint64, int32> places = scope .();
			List<Vector3> placeAt = scope .();
			Dictionary<uint64, int32> uses = scope .();
			int triangles = 0;
			int32 Place(Vector3 p)
			{
				let key = ((uint64)(int64)(Math.Round(p.x * 200) + 100000) << 42) | ((uint64)(int64)(Math.Round(p.y * 200) + 100000) << 21) | (uint64)(int64)(Math.Round(p.z * 200) + 100000);
				if (places.TryGetValue(key, let id)) return id;
				places[key] = (int32)placeAt.Count;
				placeAt.Add(p);
				return (int32)placeAt.Count - 1;
			}
			for (int32 cz = 0; cz < 4; cz++)
			{
				for (int32 cy = -1; cy <= 2; cy++)
				{
					for (int32 cx = 0; cx < 4; cx++)
					{
						let mesh = terrain.ChunkMesh(.(cx, cy, cz));
						if (mesh == null) continue;
						triangles += mesh.Indices.Count / 3;
						for (int i = 0; i + 2 < mesh.Indices.Count; i += 3)
						{
							for (int e < 3)
							{
								let ia = Place(mesh.Vertices[(int)mesh.Indices[i + e]].position), ib = Place(mesh.Vertices[(int)mesh.Indices[i + (e + 1) % 3]].position);
								let key = ia < ib ? ((uint64)ia << 32) | (uint64)ib : ((uint64)ib << 32) | (uint64)ia;
								if (uses.TryGetValue(key, let count))
									uses[key] = count + 1;
								else
									uses[key] = 1;
							}
						}
					}
				}
			}
			int holes = 0, doubled = 0;
			for (let entry in uses)
			{
				let a = placeAt[(int)(entry.key >> 32)], b = placeAt[(int)(entry.key & 0xFFFFFFFF)];
				let mx = (a.x + b.x) * 0.5f, my = (a.y + b.y) * 0.5f, mz = (a.z + b.z) * 0.5f;
				let inner = mx > 2 && mx < 126 && mz > 2 && mz < 126 && my > -20;
				if (entry.value == 1 && inner)
					holes++;
				if (entry.value > 2)
					doubled++;
			}
			Check(triangles > 20000, scope $"contoured: the ground is built ({triangles} triangles)");
			Check(holes == 0, scope $"contoured: chunks meet with no holes, across faces, edges and corners ({holes} open edges inside the ground)");
			Check(doubled == 0, scope $"contoured: no quad is made twice by neighbouring chunks ({doubled} edges used more than twice)");
			// With detail falling off with distance, each chunk gets a skirt round its rim.
			let before = triangles;
			terrain.lodDistance = 1;
			terrain.OnValidate();
			VoxelTerrain.ViewerPosition = .(16, 0, 16);
			Settle(scene, terrain);
			int far = 0;
			let farMesh = terrain.ChunkMesh(.(3, -1, 3)), nearMesh = terrain.ChunkMesh(.(0, -1, 0));
			if (farMesh != null)
				far = farMesh.Indices.Count / 3;
			Check(farMesh != null && nearMesh != null && far > 0 && far < nearMesh.Indices.Count / 3 && before > 0, scope $"contoured: far chunks are drawn with fewer triangles ({far} against {nearMesh != null ? nearMesh.Indices.Count / 3 : 0})");
			Check(Flat(terrain, 120, 125) && Ground(terrain, 64, 64) > 2, "contoured: the ground is where it was at lower detail");
			// The same ground as marching cubes makes of the same samples, to within part of a voxel, at any sharpness.
			terrain.lodDistance = 0;
			float[5] xs = .(64, 60, 32, 96, 100), zs = .(64, 70, 96, 32, 30);
			float[5] soft = default, sharp = default, marched = default;
			terrain.OnValidate();
			Settle(scene, terrain);
			for (int i < 5)
				soft[i] = Ground(terrain, xs[i], zs[i]);
			terrain.contourSharpness = 1;
			terrain.OnValidate();
			Settle(scene, terrain);
			for (int i < 5)
				sharp[i] = Ground(terrain, xs[i], zs[i]);
			terrain.style = .Smooth;
			terrain.OnValidate();
			Settle(scene, terrain);
			float worst = 0;
			for (int i < 5)
			{
				marched[i] = Ground(terrain, xs[i], zs[i]);
				worst = Math.Max(worst, Math.Max(Math.Abs(soft[i] - marched[i]), Math.Abs(sharp[i] - marched[i])));
			}
			Check(worst < 0.5f, scope $"contoured: the ground is within half a voxel of the marching cubes ground, soft or sharp (furthest {worst:0.00})");
			scene.StopPlay();
		}

		Console.WriteLine(scope $"{sFailures} failed");
		return sFailures == 0 ? 0 : 1;
	}
}
