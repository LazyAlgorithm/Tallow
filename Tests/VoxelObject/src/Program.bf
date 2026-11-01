using System;
using System.Collections;
using Tallow;

namespace VoxelObjectTests;

class Program
{
	static bool Check(bool condition, StringView name)
	{
		Console.WriteLine(scope $"{condition ? "PASS" : "FAIL"}: {name}");
		return condition;
	}

	static int Solid(VoxelObject voxels)
	{
		int n = 0;
		for (let d in voxels.[Friend]mDensity)
		{
			if (d > 0)
				n++;
		}
		return n;
	}

	static Mesh Built(VoxelObject voxels) => voxels.[Friend]mMesh;

	public static int Main(String[] args)
	{
		Console.WriteLine("Voxel object tests (shapes from models, their surface, carving and pieces; materials need a graphics card to see)");
		bool ok = true;
		let scene = scope Scene();
		Scene.Active = scene;

		// ---- the built-in shapes are as they were ----
		let ball = scene.CreateGameObject("Ball").AddComponent<VoxelObject>();
		let ballSolid = Solid(ball);
		ok &= Check(ballSolid > 2000 && !ball.IsEmpty && ball.GridSize == 4, scope $"a sphere is still a sphere ({ballSolid} solid samples)");

		// ---- a model made destructible: a cube (1 unit, the engine's own) ----
		let crate = scene.CreateGameObject("Crate");
		crate.AddComponent<MeshRenderer>();
		let voxels = crate.AddComponent<VoxelObject>();
		voxels.shape = .Mesh;
		voxels.mesh.Set("builtin:cube");
		voxels.resolution = 24;
		voxels.OnValidate();
		let mesh = Built(voxels);
		ok &= Check(!voxels.IsEmpty && mesh.Vertices.Count > 500, scope $"a model gives a surface ({mesh.Vertices.Count} points)");
		// 24 cells with a cell and a half of air each side hold a model 21 cells across.
		let cell = voxels.GridSize / 24;
		ok &= Check(Math.Abs(voxels.GridSize - 24.0f / 21) < 0.001f, scope $"the grid is fitted round the model, not the other way about ({voxels.GridSize:0.000})");
		let filled = Solid(voxels);
		ok &= Check(filled > 20 * 20 * 20 && filled < 23 * 23 * 23, scope $"the model is filled in solid ({filled} samples for a cube 21 cells across)");
		float furthest = 0;
		var low = Vector3(float.MaxValue), high = Vector3(-float.MaxValue);
		for (let v in mesh.Vertices)
		{
			// How far each point of the re-made surface is from the cube's own surface.
			let p = v.position;
			let outside = Math.Max(Math.Max(Math.Abs(p.x), Math.Abs(p.y)), Math.Abs(p.z)) - 0.5f;
			furthest = Math.Max(furthest, Math.Abs(outside));
			low = Vector3.Min(low, p);
			high = Vector3.Max(high, p);
		}
		ok &= Check(Math.Abs(high.x - 0.5f) < cell * 0.2f && Math.Abs(low.y + 0.5f) < cell * 0.2f && Math.Abs(high.z - 0.5f) < cell * 0.2f, scope $"the surface is at the model's own size ({low.y:0.000} to {high.y:0.000} for a cube of -0.5 to 0.5)");
		ok &= Check(furthest < cell * 0.75f, scope $"and follows it to within a cell even at the corners ({furthest / cell:0.00} cells at worst)");

		// ---- the model's texture coordinates and colours carry over ----
		bool unit = true, white = true;
		float lowU = 1, highU = 0;
		for (let v in mesh.Vertices)
		{
			unit &= v.uv.x >= -0.01f && v.uv.x <= 1.01f && v.uv.y >= -0.01f && v.uv.y <= 1.01f;
			white &= v.color == 0xFFFFFFFF;
			lowU = Math.Min(lowU, v.uv.x);
			highU = Math.Max(highU, v.uv.x);
		}
		ok &= Check(unit && lowU < 0.1f && highU > 0.9f, scope $"the surface has the model's texture coordinates (u from {lowU:0.00} to {highU:0.00})");
		ok &= Check(white, "and its colours, not the Color field");

		// ---- a model off its origin, and one that is not a box ----
		let ballModel = scene.CreateGameObject("Ball Model").AddComponent<VoxelObject>();
		ballModel.shape = .Mesh;
		ballModel.mesh.Set("builtin:sphere");
		ballModel.resolution = 32;
		ballModel.OnValidate();
		float worst = 0;
		for (let v in Built(ballModel).Vertices)
			worst = Math.Max(worst, Math.Abs(v.position.Length - 0.5f));
		ok &= Check(!ballModel.IsEmpty && worst < ballModel.GridSize / 32 * 0.6f, scope $"a round model stays round ({worst / (ballModel.GridSize / 32):0.00} cells from a true sphere at worst)");
		let post = scene.CreateGameObject("Post").AddComponent<VoxelObject>();
		post.shape = .Mesh;
		post.mesh.Set("builtin:pine");
		post.resolution = 40;
		post.OnValidate();
		var postLow = float.MaxValue, postHigh = -float.MaxValue;
		for (let v in Built(post).Vertices)
		{
			postLow = Math.Min(postLow, v.position.y);
			postHigh = Math.Max(postHigh, v.position.y);
		}
		ok &= Check(!post.IsEmpty && postLow > -0.3f && postLow < 0.4f && postHigh > 4.5f && postHigh < 5.3f, scope $"a model whose origin is at its foot stays where it stands ({postLow:0.00} to {postHigh:0.00} for a tree of 0 to 5)");

		// ---- nothing to use ----
		let none = scene.CreateGameObject("None").AddComponent<VoxelObject>();
		none.shape = .Mesh;
		none.OnValidate();
		ok &= Check(none.IsEmpty, "with no model named there is nothing, and no crash");

		// ---- carving ----
		let beforeCarve = Solid(voxels);
		ok &= Check(voxels.Carve(.(0.5f, 0.5f, 0.5f), 0.3f) && Solid(voxels) < beforeCarve, "a corner can be carved off");
		int inside = 0, stillOutside = 0;
		for (let v in Built(voxels).Vertices)
		{
			if ((v.position - Vector3(0.5f, 0.5f, 0.5f)).Length < 0.3f + cell)
				inside++;
			else
				stillOutside++;
		}
		ok &= Check(inside > 20 && stillOutside > 500, scope $"the cut is a new surface where the corner was ({inside} points)");
		crate.Transform.Position = .(10, 0, 0);
		let moved = Solid(voxels);
		ok &= Check(voxels.Carve(.(9.5f, -0.5f, -0.5f), 0.3f) && Solid(voxels) < moved, "carving goes by where the object is in the world");

		// ---- a wall cut in two: the smaller part falls off as a piece made of the same model ----
		let wall = scene.CreateGameObject("Wall");
		wall.AddComponent<MeshRenderer>();
		let wallVoxels = wall.AddComponent<VoxelObject>();
		wallVoxels.shape = .Mesh;
		wallVoxels.mesh.Set("builtin:cube");
		wallVoxels.anchored = true;
		wallVoxels.OnValidate();
		scene.StartPlay();
		let whole = Solid(wallVoxels);
		// A slot right through, a third of the way along.
		for (float y = -0.6f; y <= 0.6f; y += 0.08f)
		{
			for (float z = -0.6f; z <= 0.6f; z += 0.08f)
				wallVoxels.Carve(.(0.2f, y, z), 0.09f);
		}
		GameObject fragment = null;
		for (let object in scene.[Friend]mObjects)
		{
			if (object.Name == "Fragment")
				fragment = object;
		}
		let piece = fragment?.GetComponent<VoxelObject>();
		ok &= Check(piece != null && Solid(piece) > 200 && Solid(wallVoxels) < whole && Solid(wallVoxels) > Solid(piece), scope $"a slot through a wall drops the smaller side as a piece ({piece != null ? Solid(piece) : 0} of {whole} samples)");
		if (piece != null)
		{
			float pieceLow = float.MaxValue;
			bool pieceUvs = true;
			for (let v in Built(piece).Vertices)
			{
				pieceLow = Math.Min(pieceLow, v.position.x);
				pieceUvs &= v.uv.x >= -1.01f && v.uv.x <= 1.01f;
			}
			ok &= Check(piece.shape == .Mesh && piece.mesh == "builtin:cube" && Math.Abs(piece.GridSize - wallVoxels.GridSize) < 0.0001f && pieceLow > 0.2f, scope $"the piece is the same model, in the same place, with the rest taken out (from x = {pieceLow:0.00})");
			ok &= Check(fragment.GetComponent<Rigidbody>() != null && pieceUvs, "and it is a physics body with the model's surface");
		}
		scene.StopPlay();

		Console.WriteLine(ok ? "ALL PASSED" : "SOME FAILED");
		Scene.Active = null;
		return ok ? 0 : 1;
	}
}
