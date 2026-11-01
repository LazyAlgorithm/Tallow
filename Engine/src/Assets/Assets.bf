using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// Mesh and texture cache keyed by path. "builtin:cube" style names give primitives,
/// anything else is a file relative to the project folder ("models/tree.glb", optionally "#2" for a sub-mesh).
static class Assets
{
	public static String ProjectPath = new .() ~ delete _;

	static Dictionary<String, Mesh> sMeshes = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static Dictionary<String, uint16> sTextures = new .() ~ DeleteDictionaryAndKeys!(_);
	/// Meshes that could not be loaded, with when to try again: things that ask every frame (particles, foliage)
	/// would otherwise read the disk and log a warning every frame.
	static Dictionary<String, int64> sMissingMeshes = new .() ~ DeleteDictionaryAndKeys!(_);
	const int64 MissingRetryMicroseconds = 2000000;

	public static readonly StringView[?] BuiltinMeshes = .("builtin:cube", "builtin:sphere", "builtin:capsule", "builtin:cylinder", "builtin:cone", "builtin:plane", "builtin:quad", "builtin:grass", "builtin:bush", "builtin:tree", "builtin:pine");

	public static void Clear()
	{
		for (let entry in sMeshes)
		{
			delete entry.key;
			delete entry.value;
		}
		sMeshes.Clear();
		for (let (key, parts) in sModelParts)
		{
			delete key;
			DeleteModelParts(parts);
		}
		sModelParts.Clear();
		MeshVersion++;
		for (let key in sMissingMeshes.Keys)
			delete key;
		sMissingMeshes.Clear();
		for (let entry in sTextures)
		{
			if (Gfx.Initialized && entry.value != Gfx.WhiteTexture.idx)
			{
				bgfx.TextureHandle handle;
				handle.idx = entry.value;
				bgfx.destroy_texture(handle);
			}
			delete entry.key;
		}
		sTextures.Clear();
	}

	/// Drops the meshes and textures loaded from paths that start with prefix ("" + a mounted map's folder), so a
	/// changed file of the same name is read again. Nothing may still be drawing them.
	public static void Forget(StringView prefix)
	{
		let meshes = scope List<String>();
		for (let key in sMeshes.Keys)
		{
			if (key.StartsWith(prefix))
				meshes.Add(key);
		}
		for (let key in meshes)
		{
			if (sMeshes.GetAndRemove(key) case .Ok(let pair))
			{
				delete pair.key;
				delete pair.value;
			}
		}
		let modelParts = scope List<String>();
		for (let key in sModelParts.Keys)
		{
			if (key.StartsWith(prefix))
				modelParts.Add(key);
		}
		for (let key in modelParts)
		{
			if (sModelParts.GetAndRemove(key) case .Ok(let pair))
			{
				delete pair.key;
				DeleteModelParts(pair.value);
			}
		}
		if (!meshes.IsEmpty || !modelParts.IsEmpty)
			MeshVersion++;
		let missing = scope List<String>();
		for (let key in sMissingMeshes.Keys)
		{
			if (key.StartsWith(prefix))
				missing.Add(key);
		}
		for (let key in missing)
		{
			sMissingMeshes.Remove(key);
			delete key;
		}
		let textures = scope List<String>();
		for (let key in sTextures.Keys)
		{
			if (key.StartsWith(prefix))
				textures.Add(key);
		}
		for (let key in textures)
		{
			if (sTextures.GetAndRemove(key) case .Ok(let pair))
			{
				if (Gfx.Initialized && pair.value != Gfx.WhiteTexture.idx)
				{
					bgfx.TextureHandle handle;
					handle.idx = pair.value;
					bgfx.destroy_texture(handle);
				}
				delete pair.key;
			}
		}
	}

	/// Extra folders searched before the project's own, newest first: mods and Workshop items. A file a mod provides
	/// under the same relative path replaces the project's.
	static List<String> sSearchPaths = new .() ~ DeleteContainerAndItems!(_);
	public static List<String> SearchPaths => sSearchPaths;

	/// Makes a folder's files available by their path relative to it, taking priority over the project's files.
	public static void AddSearchPath(StringView folder)
	{
		for (let existing in sSearchPaths)
		{
			if (existing == folder)
				return;
		}
		sSearchPaths.Add(new String(folder));
	}

	public static void RemoveSearchPath(StringView folder)
	{
		for (let existing in sSearchPaths)
		{
			if (existing == folder)
			{
				sSearchPaths.Remove(existing);
				delete existing;
				return;
			}
		}
	}

	/// The reverse of ResolvePath: a file on disk as a path relative to the project (or to a search path).
	/// A path outside all of them is returned unchanged.
	public static void MakeRelative(StringView fullPath, String outPath)
	{
		for (int i = sSearchPaths.Count - 1; i >= 0; i--)
		{
			if (fullPath.StartsWith(sSearchPaths[i]) && fullPath.Length > sSearchPaths[i].Length && fullPath[sSearchPaths[i].Length] == '/')
			{
				outPath.Append(fullPath.Substring(sSearchPaths[i].Length + 1));
				return;
			}
		}
		if (!ProjectPath.IsEmpty && fullPath.StartsWith(ProjectPath) && fullPath.Length > ProjectPath.Length && fullPath[ProjectPath.Length] == '/')
		{
			outPath.Append(fullPath.Substring(ProjectPath.Length + 1));
			return;
		}
		outPath.Append(fullPath);
	}

	/// Whether a path names a place by itself: /folder on Linux and macOS, C:/folder or \\\\server on Windows.
	public static bool IsAbsolute(StringView path) => path.StartsWith('/') || path.StartsWith('\\') || (path.Length > 2 && path[1] == ':');

	/// Reads one of the project's files as text: from the game's asset pack in a built game, from disk otherwise.
	/// path is relative to the project, like every asset path. False if there is no such file.
	public static bool ReadText(StringView path, String text) => AssetPack.ReadAllText(ResolvePath(path, .. scope .()), text) case .Ok;

	/// Reads one of the project's files as bytes; see ReadText.
	public static bool ReadBytes(StringView path, List<uint8> data) => AssetPack.ReadAll(ResolvePath(path, .. scope .()), data) case .Ok;

	/// Whether the project has this file, packed or loose.
	public static bool FileExists(StringView path) => AssetPack.Exists(ResolvePath(path, .. scope .()));

	/// Model files the editor converts to glTF behind the scenes (docs/model-import.md). Scenes name the file itself;
	/// everything that reads models is handed the converted .glb.
	public static readonly StringView[?] ConvertedModelExtensions = .(".fbx", ".obj", ".dae", ".stl", ".ply", ".3ds", ".blend");

	public static bool IsConvertedModel(StringView path)
	{
		var path;
		let hash = path.IndexOf('#');
		if (hash >= 0)
			path = path.Substring(0, hash);
		for (let fileType in ConvertedModelExtensions)
		{
			if (path.EndsWith(fileType, .OrdinalIgnoreCase))
				return true;
		}
		return false;
	}

	/// True for every file a Mesh Renderer can show: glTF, the modeller's .tmesh, and the converted formats.
	public static bool IsModelPath(StringView path)
	{
		var path;
		let hash = path.IndexOf('#');
		if (hash >= 0)
			path = path.Substring(0, hash);
		return path.EndsWith(".glb", .OrdinalIgnoreCase) || path.EndsWith(".gltf", .OrdinalIgnoreCase) || path.EndsWith(".tmesh", .OrdinalIgnoreCase) || IsConvertedModel(path);
	}

	/// Where the editor keeps a converted model: <project>/.cache/models/<path>.glb. A built game has it in its pack
	/// as <path>.glb instead.
	public static void ConvertedModelCache(StringView path, String outPath)
	{
		let parent = scope String();
		System.IO.Path.GetDirectoryPath(ProjectPath, parent).IgnoreError();
		outPath.AppendF("{}/.cache/models/{}.glb", parent, path);
	}

	public static void ResolvePath(StringView path, String outPath)
	{
		if (IsAbsolute(path) || ProjectPath.IsEmpty)
		{
			outPath.Append(path);
			return;
		}
		if (IsConvertedModel(path))
		{
			let cached = ConvertedModelCache(path, .. scope .());
			if (System.IO.File.Exists(cached))
			{
				outPath.Append(cached);
				return;
			}
			ResolvePath(scope $"{path}.glb" , outPath);
			return;
		}
		for (int i = sSearchPaths.Count - 1; i >= 0; i--)
		{
			let candidate = scope $"{sSearchPaths[i]}/{path}";
			if (System.IO.File.Exists(candidate))
			{
				outPath.Append(candidate);
				return;
			}
		}
		outPath.AppendF("{}/{}", ProjectPath, path);
	}

	public static Mesh GetMesh(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sMeshes.TryGetValueAlt(path, let cached))
			return cached;
		if (sMissingMeshes.TryGetValueAlt(path, let retryAt) && Internal.GetTickCountMicro() < retryAt)
			return null;

		Mesh mesh = null;
		if (path.StartsWith("builtin:"))
		{
			switch (path)
			{
			case "builtin:cube": mesh = Primitives.CreateCube();
			case "builtin:sphere": mesh = Primitives.CreateSphere();
			case "builtin:capsule": mesh = Primitives.CreateCapsule();
			case "builtin:cylinder": mesh = Primitives.CreateCylinder();
			case "builtin:cone": mesh = Primitives.CreateCylinder(16, 0);
			case "builtin:plane": mesh = Primitives.CreatePlane();
			case "builtin:quad": mesh = Primitives.CreateQuad();
			case "builtin:grass": mesh = Primitives.CreateGrass();
			case "builtin:bush": mesh = Primitives.CreateBush();
			case "builtin:tree": mesh = Primitives.CreateTree(false);
			case "builtin:pine": mesh = Primitives.CreateTree(true);
			default:
			}
		}
		else
		{
			mesh = LoadModel(path);
		}
		if (mesh == null)
		{
			if (sMissingMeshes.TryAddAlt(path, let keyPtr, let valuePtr))
			{
				*keyPtr = new String(path);
				Log.Warning(scope $"Mesh not found: {path}");
			}
			*valuePtr = Internal.GetTickCountMicro() + MissingRetryMicroseconds;
			return null;
		}
		if (sMissingMeshes.GetAndRemoveAlt(path) case .Ok(let missing))
			delete missing.key;
		sMeshes[new String(path)] = mesh;
		return mesh;
	}

	/// True when a mesh or texture is loaded already (GetMesh / GetTexture return it at once).
	/// Every cached mesh and texture by path (for the Profiler's memory snapshots).
	public static void ForEachMesh(delegate void(StringView path, Mesh mesh) each)
	{
		for (let (path, mesh) in sMeshes)
			each(path, mesh);
	}

	public static void ForEachTexture(delegate void(StringView path, uint16 handle) each)
	{
		for (let (path, handle) in sTextures)
			each(path, handle);
	}

	public static int MeshCount => sMeshes.Count;
	public static int TextureCount => sTextures.Count;

	public static bool HasMesh(StringView path) => path.StartsWith("builtin:") || sMeshes.ContainsKeyAlt(path);
	public static bool HasTexture(StringView path) => path.IsEmpty || sTextures.ContainsKeyAlt(path);

	/// Takes a mesh read on a loading thread (BuildModel) into the cache, sending it to the graphics card. Returns
	/// the mesh now cached under that path (an earlier one if it was loaded meanwhile; the new one is then deleted).
	public static Mesh AdoptMesh(StringView path, Mesh mesh)
	{
		if (sMeshes.TryGetValueAlt(path, let cached))
		{
			delete mesh;
			return cached;
		}
		if (mesh == null)
			return null;
		mesh.Upload();
		sMeshes[new String(path)] = mesh;
		return mesh;
	}

	/// Loads a glTF / GLB file. Without a "#index" suffix every primitive is merged into one mesh.
	static Mesh LoadModel(StringView path)
	{
		let mesh = BuildModel(path);
		if (mesh != null)
			mesh.Upload();
		return mesh;
	}

	/// Reads a glTF / GLB file into a mesh without sending it to the graphics card, so that it can run on a loading
	/// thread. Null when the file cannot be read.
	public static Mesh BuildModel(StringView path)
	{
		var filePart = path;
		int32 only = -1;
		let hash = path.LastIndexOf('#');
		if (hash >= 0)
		{
			filePart = path.Substring(0, hash);
			only = SceneSerializer.ParseInt(path.Substring(hash + 1));
		}
		let full = scope String();
		ResolvePath(filePart, full);
		// A model saved from the editor's modeller (docs/modeling.md); "#n" picks the faces of material slot n.
		if (filePart.EndsWith(".tmesh", .OrdinalIgnoreCase))
		{
			let text = scope String();
			if (AssetPack.ReadAllText(full, text) case .Err)
				return null;
			let edit = scope EditMesh();
			if (!edit.Read(text))
				return null;
			let mesh = new Mesh();
			mesh.Name.Set(path);
			edit.Build(mesh, .One, only);
			return mesh;
		}
		let scene = Native.tn_gltf_load(full.CStr());
		if (scene == null)
			return null;
		defer Native.tn_gltf_free(scene);

		let mesh = new Mesh();
		mesh.Name.Set(path);
		let count = Native.tn_gltf_prim_count(scene);
		// Second coordinates on every part: the model brought its own lightmap layout.
		var allUV2 = count > 0;
		for (uint32 p = 0; p < count; p++)
		{
			if (only >= 0 && (uint32)only != p)
				continue;
			let prim = Native.tn_gltf_get_prim(scene, p);
			allUV2 &= prim.uv2s != null;
			AddGltfPrimitive(mesh, prim);
		}
		mesh.RecalculateBounds();
		if (allUV2 && mesh.Indices.Count > 0)
		{
			mesh.LightmapUVs = true;
			mesh.LightmapUVsFromModel = true;
			mesh.LightmapUVScale = LightmapUV.MeasureScale(mesh);
		}
		return mesh;
	}

	/// Adds a glTF primitive's vertices and triangles to a mesh, in Tallow's space.
	static void AddGltfPrimitive(Mesh mesh, Native.GltfPrim* prim)
	{
		Matrix4 world = default;
		for (int i < 16)
			world.m[i] = prim.world[i];
		// glTF is right-handed with +Z towards the viewer; flip Z into Tallow's left-handed space.
		let flip = Matrix4.Scale(.(1, 1, -1));
		world = flip * world;
		let baseColor = Color(prim.baseColor[0], prim.baseColor[1], prim.baseColor[2], prim.baseColor[3]);
		let baseVertex = (uint32)mesh.Vertices.Count;
		for (uint32 v = 0; v < prim.vertexCount; v++)
		{
			let position = Vector3(prim.positions[v * 3], prim.positions[v * 3 + 1], prim.positions[v * 3 + 2]);
			var normal = Vector3.Up;
			if (prim.normals != null)
				normal = .(prim.normals[v * 3], prim.normals[v * 3 + 1], prim.normals[v * 3 + 2]);
			var color = baseColor;
			if (prim.colors != null)
			{
				color.r *= prim.colors[v * 4];
				color.g *= prim.colors[v * 4 + 1];
				color.b *= prim.colors[v * 4 + 2];
				color.a *= prim.colors[v * 4 + 3];
			}
			// glTF stores linear color; the shader expects sRGB-encoded vertex colors.
			color = .(Math.Pow(color.r, 1.0f / 2.2f), Math.Pow(color.g, 1.0f / 2.2f), Math.Pow(color.b, 1.0f / 2.2f), color.a);
			Vector2 uv = default;
			if (prim.uvs != null)
				uv = .(prim.uvs[v * 2], prim.uvs[v * 2 + 1]); // glTF and Tallow both put V = 0 at the top of the image
			mesh.AddVertex(world.TransformPoint(position), world.TransformDirection(normal).Normalized, color, uv);
			if (prim.uv2s != null)
				mesh.Vertices.Back.uv2 = .(prim.uv2s[v * 2], prim.uv2s[v * 2 + 1]);
		}
		// Mirroring Z turns every triangle inside out, so swap two corners to face it outwards again.
		for (uint32 i = 0; i + 2 < prim.indexCount; i += 3)
			mesh.AddTriangle(baseVertex + prim.indices[i], baseVertex + prim.indices[i + 2], baseVertex + prim.indices[i + 1]);
		if (prim.normals == null)
			mesh.RecalculateNormals();
	}

	static Dictionary<String, List<MeshRenderer.Part>> sModelParts = new .() ~
		{
			for (let (key, parts) in _)
			{
				delete key;
				DeleteModelParts(parts);
			}
			delete _;
		};

	static void DeleteModelParts(List<MeshRenderer.Part> parts)
	{
		if (parts == null)
			return;
		for (let part in parts)
		{
			delete part.mesh;
			delete part.material;
			delete part;
		}
		delete parts;
	}

	/// A model's own materials for a Mesh Renderer (MeshRenderer.useModelMaterials): a mesh for each material in the
	/// file, with that material and its textures (the file's images, "<file>#image<n>"). Null when the model has one
	/// plain material, so the renderer draws it as one mesh with its own fields, as before.
	public static List<MeshRenderer.Part> GetModelParts(StringView path)
	{
		if (sModelParts.TryGetValueAlt(path, let cached))
			return cached;
		List<MeshRenderer.Part> parts = null;
		if (Gfx.Initialized && (path.EndsWith(".glb", .OrdinalIgnoreCase) || path.EndsWith(".gltf", .OrdinalIgnoreCase) || IsConvertedModel(path)) && !path.Contains('#'))
			parts = BuildModelParts(path);
		sModelParts[new String(path)] = parts;
		return parts;
	}

	static List<MeshRenderer.Part> BuildModelParts(StringView path)
	{
		let full = scope String();
		ResolvePath(path, full);
		let scene = Native.tn_gltf_load(full.CStr());
		if (scene == null)
			return null;
		defer Native.tn_gltf_free(scene);
		let imageNames = scope List<String>();
		defer
		{
			ClearAndDeleteItems!(imageNames);
		}
		SkinnedModel.ReadImages(scene, path, null, imageNames);
		let count = Native.tn_gltf_prim_count(scene);
		let fileMaterials = scope List<int32>();
		let materials = scope List<Material>();
		bool anyTexture = false;
		for (uint32 p < count)
		{
			let prim = Native.tn_gltf_get_prim(scene, p);
			if (!fileMaterials.Contains(prim.material))
			{
				fileMaterials.Add(prim.material);
				materials.Add(SkinnedModel.MaterialFrom(prim, imageNames, ref anyTexture));
			}
		}
		if (fileMaterials.Count <= 1 && !anyTexture)
		{
			for (let material in materials)
				delete material;
			return null;
		}
		let parts = new List<MeshRenderer.Part>();
		for (int m < fileMaterials.Count)
		{
			let mesh = new Mesh();
			mesh.Name.AppendF("{}#material{}", path, m);
			for (uint32 p < count)
			{
				let prim = Native.tn_gltf_get_prim(scene, p);
				if (prim.material == fileMaterials[m])
					AddGltfPrimitive(mesh, prim);
			}
			mesh.RecalculateBounds();
			mesh.Upload();
			let part = new MeshRenderer.Part();
			part.mesh = mesh;
			part.material = materials[m];
			parts.Add(part);
		}
		return parts;
	}

	/// Makes a texture from RGBA pixels (4 bytes a pixel) under a name of its own, such as an image found inside a
	/// model ("Models/hero.glb#image2"), so that GetTexture, and every Material naming it, finds it. Does nothing if
	/// a texture of that name is already there. Returns it.
	public static bgfx.TextureHandle AddTexture(StringView path, uint8* pixels, int32 width, int32 height, TextureKind kind = .Color)
	{
		if (sTextures.TryGetValueAlt(path, let cached))
		{
			bgfx.TextureHandle handle;
			handle.idx = cached;
			return handle;
		}
		if (pixels == null || width <= 0 || height <= 0 || !Gfx.Initialized)
			return Gfx.WhiteTexture;
		let texture = Textures.Create(pixels, width, height, kind == .Color ? Textures.KindOf(path) : kind);
		sTextures[new String(path)] = texture.idx;
		return texture;
	}

	/// Goes up each time ReplaceTexture changes a texture, so renderers and materials holding one look it up again.
	public static int32 TextureVersion;
	/// Goes up whenever meshes are forgotten (Forget), so renderers holding one look it up again.
	public static int32 MeshVersion;

	/// Puts new RGBA pixels under a texture's name (painting a texture in the editor): every renderer and material
	/// naming it draws the new pixels from the next frame. The old texture is released.
	public static bgfx.TextureHandle ReplaceTexture(StringView path, uint8* pixels, int32 width, int32 height)
	{
		if (pixels == null || width <= 0 || height <= 0 || !Gfx.Initialized)
			return Gfx.WhiteTexture;
		let texture = Textures.Create(pixels, width, height, Textures.KindOf(path));
		if (sTextures.GetAndRemoveAlt(path) case .Ok(let pair))
		{
			if (pair.value != Gfx.WhiteTexture.idx)
			{
				bgfx.TextureHandle old;
				old.idx = pair.value;
				bgfx.destroy_texture(old);
			}
			delete pair.key;
		}
		sTextures[new String(path)] = texture.idx;
		TextureVersion++;
		return texture;
	}

	/// The texture of an image file (loaded the first time). kind says what it holds, for its mip levels, when the
	/// caller knows (a normal map slot); otherwise it is worked out (Textures.KindOf).
	public static bgfx.TextureHandle GetTexture(StringView path, TextureKind kind = .Color)
	{
		if (path.IsEmpty)
			return Gfx.WhiteTexture;
		if (sTextures.TryGetValueAlt(path, let cached))
		{
			bgfx.TextureHandle handle;
			handle.idx = cached;
			return handle;
		}
		// An image inside a model ("Models/hero.glb#image2"): every image of that file is made into a texture.
		let image = path.IndexOf("#image");
		if (image > 0 && Gfx.Initialized && AddModelImages(path.Substring(0, image)) && sTextures.TryGetValueAlt(path, let found))
		{
			bgfx.TextureHandle handle;
			handle.idx = found;
			return handle;
		}
		let full = scope String();
		ResolvePath(path, full);
		let texture = Gfx.LoadTexture(full, kind == .Color ? Textures.KindOf(path) : kind);
		sTextures[new String(path)] = texture.idx;
		return texture;
	}

	/// Makes each image in a glTF / GLB file a texture named "<file>#image<n>". False if the file cannot be read.
	static bool AddModelImages(StringView model)
	{
		if (!model.EndsWith(".glb", .OrdinalIgnoreCase) && !model.EndsWith(".gltf", .OrdinalIgnoreCase) && !IsConvertedModel(model))
			return false;
		let full = scope String();
		ResolvePath(model, full);
		let scene = Native.tn_gltf_load(full.CStr());
		if (scene == null)
			return false;
		defer Native.tn_gltf_free(scene);
		for (int32 i < Native.tn_gltf_image_count(scene))
		{
			int32 width = 0, height = 0;
			let pixels = Native.tn_gltf_get_image(scene, i, &width, &height);
			if (pixels != null)
				AddTexture(scope $"{model}#image{i}" , pixels, width, height, Textures.GltfImageKind(scene, i));
		}
		return true;
	}
}
