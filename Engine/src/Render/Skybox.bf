using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

extension Native
{
	[CLink] public static extern int32 tn_skybox_import(char8** paths, int32 count, int32 maxSize, char8* outPath, char8* err, int32 errLength);
	[CLink] public static extern bool tn_skybox_write_test_picture(char8* path, int32 kind, int32 width, int32 height, float* rgba);
	[CLink] public static extern int32 stbi_info(char8* path, int32* width, int32* height, int32* channels);
}

/// Custom skyboxes (SkyMode.Custom): a picture the sky is drawn from. A skybox is one
/// file (an equirectangular 2:1 panorama in .hdr, .exr, .png or .jpg, or a .ktx / .dds cubemap) or a folder of six
/// face pictures named px/nx/py/ny/pz/nz or right/left/up/down/front/back. Cross layouts are not read. The first use
/// turns it into a linear RGBA16F cube with every mip level, cached as <project>/.cache/sky/<key>.ktx (made again when
/// the source changes), then drawn by fs_sky_custom with the scene's rotation, exposure and tint.
static class Skybox
{
	/// The largest face size an import makes (a .tmeta "maxSize N" line on the asset can lower it).
	public const int32 DefaultMaxSize = 2048;

	/// The picture types a skybox file can be.
	public static readonly StringView[?] Extensions = .(".hdr", ".exr", ".png", ".jpg", ".jpeg", ".ktx", ".dds");
	/// Face names, +X -X +Y -Y +Z -Z, in the two naming styles.
	public static readonly StringView[12] FaceNames = .("px", "right", "nx", "left", "py", "up", "ny", "down", "pz", "front", "nz", "back");

	class Entry
	{
		public bgfx.TextureHandle texture = .() { idx = uint16.MaxValue };
		public String key = new .() ~ delete _;
		public int32 faceSize;
		public bool failed;
	}

	static Dictionary<String, Entry> sEntries = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static bgfx.UniformHandle uSkybox = .() { idx = uint16.MaxValue }, uSkyboxTint = .() { idx = uint16.MaxValue }, sSkyboxCube = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sProgram = .() { idx = uint16.MaxValue };

	/// Imports made since start (for tests: a cached skybox is not imported again).
	public static int Imports { get; private set; }

	static bool HasExtension(StringView path, StringView ext) => path.EndsWith(ext, .OrdinalIgnoreCase);

	/// Whether a project file is a skybox file type (.hdr, .exr, .ktx, .dds always; .png / .jpg are pictures too, see
	/// IsSkyboxAsset).
	public static bool IsSkyboxFile(StringView path)
	{
		for (let ext in Extensions)
			if (HasExtension(path, ext))
				return true;
		return false;
	}

	/// What a dropped asset counts as a skybox: an .hdr / .exr / .ktx / .dds file, a .png / .jpg twice as wide as
	/// high, or a folder holding six faces.
	public static bool IsSkyboxAsset(StringView relative)
	{
		let full = Assets.ResolvePath(relative, .. scope .());
		if (Directory.Exists(full))
			return FindFaces(full, scope .());
		if (HasExtension(full, ".hdr") || HasExtension(full, ".exr") || HasExtension(full, ".ktx") || HasExtension(full, ".dds"))
			return true;
		if (HasExtension(full, ".png") || HasExtension(full, ".jpg") || HasExtension(full, ".jpeg"))
		{
			int32 w = 0, h = 0, channels = 0;
			if (Native.stbi_info(scope String(full).CStr(), &w, &h, &channels) != 0 && h > 0)
				return Math.Abs((float)w / h - 2) < 0.05f;
		}
		return false;
	}

	/// The six face files of a folder skybox (+X -X +Y -Y +Z -Z), or false when one is missing.
	public static bool FindFaces(StringView folder, List<String> outFaces)
	{
		for (int face < 6)
		{
			String found = null;
			for (int k < 2)
			{
				for (let ext in Extensions)
				{
					if (ext == ".ktx" || ext == ".dds")
						continue;
					let candidate = scope $"{folder}/{FaceNames[face * 2 + k]}{ext}";
					if (File.Exists(candidate))
					{
						found = new String(candidate);
						break;
					}
				}
				if (found != null)
					break;
			}
			if (found == null)
			{
				ClearAndDeleteItems(outFaces);
				return false;
			}
			outFaces.Add(found);
		}
		return true;
	}

	/// Notes in the asset's .tmeta that it is a skybox ("kind skybox"), when it has a .tmeta without a kind yet.
	public static void MarkMeta(StringView relative)
	{
		let meta = scope $"{Assets.ResolvePath(relative, .. scope .())}.tmeta";
		let text = scope String();
		if (File.ReadAllText(meta, text) case .Err || text.Contains("\nkind ") || text.StartsWith("kind "))
			return;
		if (!text.IsEmpty && !text.EndsWith('\n'))
			text.Append('\n');
		text.Append("kind skybox\n");
		File.WriteAllText(meta, text).IgnoreError();
	}

	/// The import's face size limit: "maxSize N" in the asset's .tmeta, else DefaultMaxSize.
	static int32 MaxSizeFor(StringView full)
	{
		let text = scope String();
		if (File.ReadAllText(scope $"{full}.tmeta", text) case .Ok)
		{
			for (var line in text.Split('\n'))
			{
				line.Trim();
				if (line.StartsWith("maxSize ") && int32.Parse(line.Substring(8)) case .Ok(let size))
					return Math.Clamp(size, 16, 8192);
			}
		}
		return DefaultMaxSize;
	}

	static void Stamp(StringView file, ref uint64 hash)
	{
		void Mix(ref uint64 h, uint64 v) { h = (h ^ v) * 1099511628211; }
		if (File.GetLastWriteTime(file) case .Ok(let time))
			Mix(ref hash, (uint64)time.Ticks);
		for (let c in file.RawChars)
			Mix(ref hash, (uint8)c);
	}

	/// The cache file for a skybox: its path, its sources' times and the size limit make the key.
	static bool CacheKey(StringView full, List<String> sources, int32 maxSize, String outKey)
	{
		uint64 hash = 14695981039346656037;
		for (let source in sources)
			Stamp(source, ref hash);
		hash = (hash ^ (uint64)maxSize) * 1099511628211;
		outKey.AppendF("{:x16}", hash);
		return true;
	}

	/// Where the cache files live: <project>/.cache/sky (next to the Assets folder), or the temp folder without a project.
	public static void CacheFolder(String outPath)
	{
		if (Assets.ProjectPath.IsEmpty)
		{
			outPath.AppendF("{}tallow-sky-cache", Path.GetTempPath(.. scope .()));
			return;
		}
		let parent = scope String();
		Path.GetDirectoryPath(Assets.ProjectPath, parent).IgnoreError();
		outPath.AppendF("{}/.cache/sky", parent);
	}

	/// The skybox's cube texture (imported now if its cache is missing or old), or Invalid when it can't be read.
	public static bgfx.TextureHandle Get(StringView relative)
	{
		if (relative.IsEmpty)
			return .() { idx = uint16.MaxValue };
		Entry entry;
		if (!sEntries.TryGetValueAlt(relative, out entry))
		{
			entry = new Entry();
			sEntries[new String(relative)] = entry;
		}
		else if (entry.failed || (entry.texture.Valid && Time.FrameCount % 120 != 0))
			return entry.failed ? .() { idx = uint16.MaxValue } : entry.texture;

		let full = Assets.ResolvePath(relative, .. scope .());
		let sources = scope List<String>();
		defer ClearAndDeleteItems(sources);
		if (Directory.Exists(full))
		{
			if (!FindFaces(full, sources))
				return Fail(entry, relative, "the folder needs six faces named px/nx/py/ny/pz/nz or right/left/up/down/front/back");
		}
		else if (File.Exists(full))
			sources.Add(new String(full));
		else
			return Fail(entry, relative, "the file is missing");

		let maxSize = MaxSizeFor(full);
		let key = CacheKey(full, sources, maxSize, .. scope .());
		if (entry.texture.Valid && entry.key == key)
			return entry.texture;

		let folder = CacheFolder(.. scope .());
		Directory.CreateDirectory(folder).IgnoreError();
		let cache = scope $"{folder}/{key}.ktx";
		if (!File.Exists(cache))
		{
			char8*[6] paths = default;
			for (int i < sources.Count)
				paths[i] = sources[i].CStr();
			char8[512] error = default;
			let started = Internal.GetTickCountMicro();
			let size = Native.tn_skybox_import(&paths[0], (int32)sources.Count, maxSize, scope String(cache).CStr(), &error[0], 512);
			if (size <= 0)
				return Fail(entry, relative, StringView(&error[0]));
			Imports++;
			Log.Info(scope $"Skybox {relative}: imported as a {size} px cube in {(Internal.GetTickCountMicro() - started) / 1000} ms");
		}
		let bytes = scope List<uint8>();
		if (File.ReadAll(cache, bytes) case .Err || bytes.Count == 0)
			return Fail(entry, relative, "can't read its cache file");
		bgfx.TextureInfo info = default;
		let texture = bgfx.create_texture(bgfx.copy(bytes.Ptr, (uint32)bytes.Count), 0, 0, &info);
		if (!texture.Valid || info.cubeMap == 0)
		{
			if (texture.Valid)
				bgfx.destroy_texture(texture);
			return Fail(entry, relative, "its cache file is not a cube");
		}
		bgfx.set_texture_name(texture, "Skybox", 6);
		if (entry.texture.Valid)
			bgfx.destroy_texture(entry.texture);
		entry.texture = texture;
		entry.key.Set(key);
		entry.faceSize = info.width;
		return texture;
	}

	static bgfx.TextureHandle Fail(Entry entry, StringView relative, StringView why)
	{
		entry.failed = true;
		Log.Error(scope $"Skybox {relative}: {why}. The physical sky is drawn instead.");
		return .() { idx = uint16.MaxValue };
	}

	/// Forgets every loaded skybox, and the ones that failed (they are tried again on next use).
	public static void Forget()
	{
		for (let entry in sEntries)
		{
			if (entry.value.texture.Valid)
				bgfx.destroy_texture(entry.value.texture);
			delete entry.key;
			delete entry.value;
		}
		sEntries.Clear();
	}

	/// The face size of a loaded skybox, or 0.
	public static int32 FaceSize(StringView relative) => sEntries.TryGetValueAlt(relative, let entry) ? entry.faceSize : 0;

	/// Whether the scene's sky is drawn from its skybox now (Custom with a skybox that loads).
	public static bool Active(SceneEnvironment env) => env.skyMode == .Custom && !env.skybox.IsEmpty && Get(env.skybox).Valid;

	/// The skybox program, with its texture and settings set for the next submit; Invalid when the skybox isn't usable.
	public static bgfx.ProgramHandle Bind(SceneEnvironment env)
	{
		if (env.skyMode != .Custom || env.skybox.IsEmpty)
			return .() { idx = uint16.MaxValue };
		let texture = Get(env.skybox);
		if (!texture.Valid)
			return .() { idx = uint16.MaxValue };
		if (!sProgram.Valid)
		{
			sProgram = Gfx.LoadProgram("vs_fullscreen", "fs_sky_custom");
			uSkybox = bgfx.create_uniform("u_skybox", .Vec4, 1);
			uSkyboxTint = bgfx.create_uniform("u_skyboxTint", .Vec4, 1);
			sSkyboxCube = bgfx.create_uniform("s_skybox", .Sampler, 1);
		}
		let angle = env.skyboxRotation * Mathf.Deg2Rad;
		Vector4 settings = .(Math.Sin(angle), Math.Cos(angle), Math.Pow(2.0f, env.skyboxExposure), 0);
		let tint = env.skyboxTint;
		Vector4 tintLinear = .(Math.Pow(tint.r, 2.2f), Math.Pow(tint.g, 2.2f), Math.Pow(tint.b, 2.2f), 1);
		bgfx.set_uniform(uSkybox, &settings, 1);
		bgfx.set_uniform(uSkyboxTint, &tintLinear, 1);
		bgfx.set_texture(0, sSkyboxCube, texture, uint32.MaxValue);
		return sProgram;
	}

	public static void Shutdown()
	{
		Forget();
		if (sProgram.Valid)
		{
			bgfx.destroy_program(sProgram);
			for (let uniform in bgfx.UniformHandle[?](uSkybox, uSkyboxTint, sSkyboxCube))
				bgfx.destroy_uniform(uniform);
			sProgram = .() { idx = uint16.MaxValue };
		}
	}
}
