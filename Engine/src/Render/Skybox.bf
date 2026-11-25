using System;
using System.Collections;
using System.IO;
using Bgfx;

namespace Tallow;

extension Native
{
	[CLink] public static extern int32 tn_skybox_import(char8** paths, int32 count, int32 maxSize, char8* outPath, char8* err, int32 errLength);
	[CLink] public static extern bool tn_skybox_write_test_picture(char8* path, int32 kind, int32 width, int32 height, float* rgba);
	[CLink] public static extern bool tn_skybox_face_averages(void* data, uint32 size, float* averages);
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
		public int32 generation;
		// The average linear light from above and from below (before exposure and tint), for what can't read the cube.
		public Vector3 up, down;
	}

	static Dictionary<String, Entry> sEntries = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static bgfx.UniformHandle uSkybox = .() { idx = uint16.MaxValue }, uSkyboxTint = .() { idx = uint16.MaxValue }, sSkyboxCube = .() { idx = uint16.MaxValue };
	static bgfx.ProgramHandle sProgram = .() { idx = uint16.MaxValue }, sReflectionProgram = .() { idx = uint16.MaxValue };

	/// Imports made since start (for tests: a cached skybox is not imported again).
	public static int Imports { get; private set; }
	static int32 sGeneration;

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

		// An exported game: the cube the export cooked (`<skybox>.sky.ktx`, BC6H with mips), read from its pack; the
		// source picture is not shipped.
		let cooked = scope $"{relative}{CookedSuffix}";
		if (Assets.FileExists(cooked))
		{
			if (entry.texture.Valid)
				return entry.texture;
			let data = scope List<uint8>();
			if (!Assets.ReadBytes(cooked, data) || data.Count == 0)
				return Fail(entry, relative, "can't read its cooked cube");
			return Load(entry, relative, data, cooked);
		}

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
		return Load(entry, relative, bytes, key);
	}

	/// Makes the entry's texture from a KTX cube's bytes; key tells a new import from the one loaded.
	static bgfx.TextureHandle Load(Entry entry, StringView relative, List<uint8> bytes, StringView key)
	{
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
		entry.generation = ++sGeneration;
		float[18] faces = default;
		if (Native.tn_skybox_face_averages(bytes.Ptr, (uint32)bytes.Count, &faces[0]))
		{
			// A hemisphere's light: its pole's face whole, the four side faces half each.
			Vector3 Face(int i) => .(faces[i * 3], faces[i * 3 + 1], faces[i * 3 + 2]);
			let sides = (Face(0) + Face(1) + Face(4) + Face(5)) * 0.5f;
			entry.up = (Face(2) + sides) / 3;
			entry.down = (Face(3) + sides) / 3;
		}
		return texture;
	}

	/// The suffix of the cube an export cooks beside a skybox (Managed/Tallow.Build/Export/SkyboxCook.cs).
	public const StringView CookedSuffix = ".sky.ktx";

	/// `--cook-skyboxes <staging> --cook-list <file>`: the export's skybox step, with no window. For each skybox the
	/// list names (one project path per line), writes `<staging>/Assets/<skybox>.sky16.ktx`: the RGBA16F cube with
	/// mips the editor would import, which the export then compresses. Prints one summary line; exit code 0 unless
	/// one failed.
	public static int Cook(StringView staging, StringView listFile)
	{
		let text = scope String();
		if (File.ReadAllText(listFile, text) case .Err)
		{
			Console.WriteLine(scope $"cook-skyboxes: can't read '{listFile}'");
			return 1;
		}
		Assets.ProjectPath.Set(scope $"{staging}/Assets");
		int made = 0, failed = 0;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty)
				continue;
			let full = scope $"{staging}/Assets/{line}";
			let sources = scope List<String>();
			defer ClearAndDeleteItems(sources);
			if (Directory.Exists(full))
				FindFaces(full, sources);
			else if (File.Exists(full))
				sources.Add(new String(full));
			if (sources.Count != 1 && sources.Count != 6)
			{
				Console.WriteLine(scope $"cook-skyboxes: {line}: not found or not six faces");
				failed++;
				continue;
			}
			char8*[6] paths = default;
			for (int i < sources.Count)
				paths[i] = sources[i].CStr();
			char8[512] error = default;
			let output = scope $"{full}.sky16.ktx";
			if (Native.tn_skybox_import(&paths[0], (int32)sources.Count, MaxSizeFor(full), output.CStr(), &error[0], 512) <= 0)
			{
				Console.WriteLine(scope $"cook-skyboxes: {line}: {StringView(&error[0])}");
				failed++;
				continue;
			}
			made++;
		}
		Console.WriteLine(scope $"cook-skyboxes: {made} cooked, {failed} failed");
		return failed > 0 ? 1 : 0;
	}

	/// The scene's skybox as two ambient colours (linear, exposure and tint applied, before Ambient Intensity): the
	/// light from the sky above and from below. False when the sky is not drawn from a skybox. For lighting that
	/// can't read the sky's cube (DynamicGI's probe grid).
	public static bool AmbientColors(SceneEnvironment env, out Vector3 sky, out Vector3 ground)
	{
		sky = ground = .Zero;
		if (!Active(env))
			return false;
		Entry entry;
		if (!sEntries.TryGetValueAlt(env.skybox, out entry))
			return false;
		let tint = env.skyboxTint;
		let scale = Vector3(Math.Pow(tint.r, 2.2f), Math.Pow(tint.g, 2.2f), Math.Pow(tint.b, 2.2f)) * Math.Pow(2.0f, env.skyboxExposure);
		sky = entry.up * scale;
		ground = entry.down * scale;
		return true;
	}

	/// What the reflection cube made from the scene's skybox depends on (0 when the sky is not drawn from one): the
	/// skybox, the import loaded and its settings.
	public static int64 State(SceneEnvironment env)
	{
		if (!Active(env))
			return 0;
		Entry entry;
		if (!sEntries.TryGetValueAlt(env.skybox, out entry))
			return 0;
		int64 hash = entry.generation;
		for (var number in float[?](env.skyboxRotation, env.skyboxExposure, env.skyboxTint.r, env.skyboxTint.g, env.skyboxTint.b))
			hash = hash * 1099511628211 ^ (int64) * (uint32*)&number;
		return hash;
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
		SetUniforms(env, texture, 0);
		return sProgram;
	}

	/// The program for a face of the sky's reflection cube (size texels a side) drawn from the skybox, with its
	/// texture and settings set; Invalid when the skybox isn't usable.
	public static bgfx.ProgramHandle BindReflection(SceneEnvironment env, int32 size)
	{
		if (env.skyMode != .Custom || env.skybox.IsEmpty)
			return .() { idx = uint16.MaxValue };
		let texture = Get(env.skybox);
		if (!texture.Valid)
			return .() { idx = uint16.MaxValue };
		let faceSize = Math.Max(FaceSize(env.skybox), 1);
		// The level whose texels are about the reflection cube's: each then averages what it covers.
		SetUniforms(env, texture, Math.Max(Math.Log((float)faceSize / size) / Math.Log(2.0f), 0));
		return sReflectionProgram;
	}

	static void SetUniforms(SceneEnvironment env, bgfx.TextureHandle texture, float level)
	{
		if (!sProgram.Valid)
		{
			sProgram = Gfx.LoadProgram("vs_fullscreen", "fs_sky_custom");
			sReflectionProgram = Gfx.LoadProgram("vs_fullscreen", "fs_env_sky_custom");
			uSkybox = bgfx.create_uniform("u_skybox", .Vec4, 1);
			uSkyboxTint = bgfx.create_uniform("u_skyboxTint", .Vec4, 1);
			sSkyboxCube = bgfx.create_uniform("s_skybox", .Sampler, 1);
		}
		let angle = env.skyboxRotation * Mathf.Deg2Rad;
		Vector4 settings = .(Math.Sin(angle), Math.Cos(angle), Math.Pow(2.0f, env.skyboxExposure), level);
		let tint = env.skyboxTint;
		Vector4 tintLinear = .(Math.Pow(tint.r, 2.2f), Math.Pow(tint.g, 2.2f), Math.Pow(tint.b, 2.2f), 1);
		bgfx.set_uniform(uSkybox, &settings, 1);
		bgfx.set_uniform(uSkyboxTint, &tintLinear, 1);
		bgfx.set_texture(0, sSkyboxCube, texture, uint32.MaxValue);
	}

	public static void Shutdown()
	{
		Forget();
		if (sProgram.Valid)
		{
			bgfx.destroy_program(sProgram);
			bgfx.destroy_program(sReflectionProgram);
			for (let uniform in bgfx.UniformHandle[?](uSkybox, uSkyboxTint, sSkyboxCube))
				bgfx.destroy_uniform(uniform);
			sProgram = .() { idx = uint16.MaxValue };
		}
	}
}
