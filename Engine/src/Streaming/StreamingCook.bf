using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// `--cook-streaming <staging> [--cook-kinds <file>]`: the export's cooking step, with no window. <staging> holds the
/// game's `Assets/` folder as it will be packed. Writes, beside each file, what the game streams from its pack:
///   - `<picture>.tmips` / `<picture>.tvt` for the big pictures materials use (`--cook-kinds` lists them, one
///     `path<TAB>color|data|normal` per line; the picture's kind decides how its mip levels are averaged),
///   - `<staging>/.cache/clod/<name>.<triangles>.tclod` (+ `.tclodp` for big meshes) for every model with a mesh
///     of GpuDriven.MinTriangles or more, under the names the engine looks them up by (GpuDriven.CacheFileOf).
/// The files are never written by a packed game itself. Prints one summary line; exit code 0 unless nothing could be read.
static class StreamingCook
{
	public static int Run(StringView staging, StringView kindsFile)
	{
		let assets = scope String(staging)..Append("/Assets");
		if (!Directory.Exists(assets))
		{
			Console.WriteLine(scope $"cook-streaming: no Assets folder in '{staging}'");
			return 1;
		}
		Assets.ProjectPath.Set(assets);
		var mips = 0, tiles = 0, meshes = 0, failed = 0;

		// Pictures.
		let kinds = scope List<(String path, TextureKind kind)>();
		defer { for (let k in kinds) delete k.path; }
		let text = scope String();
		if (!kindsFile.IsEmpty && File.ReadAllText(kindsFile, text) case .Ok)
		{
			for (let line in text.Split('\n'))
			{
				var parts = line.Split('\t');
				let path = parts.GetNext();
				let kind = parts.GetNext();
				if (path case .Err || kind case .Err)
					continue;
				var textureKind = TextureKind.Color;
				let name = scope String(kind.Value)..Trim();
				if (name == "data")
					textureKind = .Data;
				else if (name == "normal")
					textureKind = .Normal;
				kinds.Add((new String(path.Value)..Trim(), textureKind));
			}
		}
		for (let (path, kind) in kinds)
		{
			let full = scope $"{assets}/{path}";
			if (!File.Exists(full))
				continue;
			let options = TextureOptionsFor.Of(full);
			int32 w = 0, h = 0;
			let known = VirtualTextures.PngSize(full, out w, out h);
			if (kind == .Color && (options.Virtual || (known && Math.Max(w, h) >= VirtualTextures.AutoSize)))
			{
				if (VirtualTextures.Cook(full, scope $"{full}.tvt"))
					tiles++;
				else
					failed++;
			}
			else if (options.Mipmaps)
			{
				// False for a picture that is too small to stream: it loads whole, nothing to ship.
				if (StreamedTextures.Cook(full, scope $"{full}.tmips", kind, options.FullResolution))
					mips++;
			}
		}

		// Models.
		let models = scope List<String>();
		defer { for (let m in models) delete m; }
		ListModels(assets, assets, models);
		for (let model in models)
		{
			let all = scope List<Mesh>();
			defer { for (let m in all) delete m; }
			let whole = Assets.BuildModel(model);
			if (whole != null)
				all.Add(whole);
			Assets.BuildMaterialMeshes(model, all);
			for (let mesh in all)
			{
				if (mesh.Indices.Count / 3 < GpuDriven.MinTriangles)
					continue;
				let cache = scope String();
				GpuDriven.CacheFileOf(mesh.Name, mesh.Indices.Count / 3, cache);
				if (cache.IsEmpty)
					continue;
				if (GpuDriven.CookFiles(mesh, cache))
					meshes++;
				else
					failed++;
			}
		}
		Console.WriteLine(scope $"cook-streaming: {mips} .tmips, {tiles} .tvt, {meshes} cluster meshes, {failed} failed");
		return failed > 0 && mips + tiles + meshes == 0 ? 1 : 0;
	}

	static void ListModels(StringView root, StringView folder, List<String> models)
	{
		for (let entry in Directory.Enumerate(folder))
		{
			let path = entry.GetFilePath(.. scope .());
			let name = entry.GetFileName(.. scope .());
			if (name.StartsWith('.'))
				continue;
			if (entry.IsDirectory)
				ListModels(root, path, models);
			else if (name.EndsWith(".glb", .OrdinalIgnoreCase) || name.EndsWith(".gltf", .OrdinalIgnoreCase))
				models.Add(new String(path.Substring(root.Length + 1)));
		}
	}
}
