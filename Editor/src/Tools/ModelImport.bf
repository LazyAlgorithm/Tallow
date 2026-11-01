using System;
using System.Collections;
using System.IO;
using System.Threading;
using Tallow;

namespace Tallow.Editor;

/// How a converted model is brought in (docs/model-import.md), kept beside it as "<file>.import".
class ModelImportSettings
{
	public float scale = 1;
	/// The file was made with Z up (3ds Max, many STL / PLY / 3DS files): it is turned a quarter about X to stand up.
	public bool zUp;
	public bool animations = true;
	/// The clips kept, separated by commas; empty keeps them all.
	public String clips = new .() ~ delete _;
	public bool materials = true;

	public static void PathFor(StringView sourceFull, String outPath) => outPath.AppendF("{}.import", sourceFull);

	public void Read(StringView sourceFull)
	{
		let text = scope String();
		if (File.ReadAllText(PathFor(sourceFull, .. scope .()), text) case .Err)
			return;
		for (var line in text.Split('\n'))
		{
			let equals = line.IndexOf('=');
			if (equals < 0)
				continue;
			var key = line.Substring(0, equals);
			var value = line.Substring(equals + 1);
			key.Trim();
			value.Trim();
			switch (key)
			{
			case "scale": scale = Math.Max(float.Parse(value) case .Ok(let parsed) ? parsed : 1, 0.0001f);
			case "zUp": zUp = value == "1";
			case "animations": animations = value != "0";
			case "clips": clips.Set(value);
			case "materials": materials = value != "0";
			}
		}
	}

	public void Write(StringView sourceFull)
	{
		let text = scope String();
		text.AppendF("scale = {}\nzUp = {}\nanimations = {}\nclips = {}\nmaterials = {}\n", scale, zUp ? 1 : 0, animations ? 1 : 0, clips, materials ? 1 : 0);
		File.WriteAllText(PathFor(sourceFull, .. scope .()), text).IgnoreError();
	}
}

/// FBX, OBJ, DAE, STL, PLY, 3DS and .blend files in the project, converted to glTF behind the scenes: once when they
/// are first seen and again when they or their import settings change. Scenes name the file itself; the engine reads
/// the converted copy (Assets.ResolvePath). See docs/model-import.md.
static class ModelImport
{
	[CLink] static extern int32 tn_model_import_settings(char8* source, char8* output, float scale, int32 upZ, int32 animations, char8* clips, int32 materials);

	static Monitor sLock = new .() ~ delete _;
	static List<String> sQueue = new .() ~ DeleteContainerAndItems!(_);
	static List<String> sDone = new .() ~ DeleteContainerAndItems!(_);
	static Dictionary<String, String> sErrors = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	static Thread sWorker;
	/// What the importer is doing, for the status bar ("" when idle).
	public static String Status = new .() ~ delete _;

	/// The converter's own output, before the import settings: kept so that changing a setting needs no second
	/// conversion. "<cache>/<path>.source.glb".
	static void RawPath(StringView relative, String outPath)
	{
		Assets.ConvertedModelCache(relative, outPath);
		outPath.RemoveFromEnd(4);
		outPath.Append(".source.glb");
	}

	static DateTime Modified(StringView path) => File.GetLastWriteTimeUtc(path) case .Ok(let time) ? time : default;

	/// What a conversion was made from: the file's time and size, and its settings. Kept beside the converted copy
	/// ("<cache>/<path>.glb.from"), as file times alone cannot tell apart changes made in the same second.
	static void Stamp(StringView relative, String outStamp)
	{
		let full = scope $"{Assets.ProjectPath}/{relative}";
		SourceStamp(full, outStamp);
		File.ReadAllText(ModelImportSettings.PathFor(full, .. scope .()), outStamp).IgnoreError();
	}

	static void SourceStamp(StringView full, String outStamp)
	{
		int64 size = -1;
		let stream = scope FileStream();
		if (stream.Open(full, .Read, .ReadWrite) case .Ok)
			size = stream.Length;
		outStamp.AppendF("{}|{}\n", Modified(full).Ticks, size);
	}

	/// True when the converted copy was made from the file and settings as they are now.
	public static bool UpToDate(StringView relative)
	{
		let converted = Assets.ConvertedModelCache(relative, .. scope .());
		if (!File.Exists(converted))
			return false;
		let kept = scope String();
		if (File.ReadAllText(scope $"{converted}.from" , kept) case .Err)
			return false;
		return kept == Stamp(relative, .. scope .());
	}

	/// Why the last conversion of a file failed, or null.
	public static StringView? Error(StringView relative)
	{
		using (sLock.Enter())
		{
			if (sErrors.TryGetValueAlt(relative, let message))
				return message;
		}
		return null;
	}

	/// Queues every model in the project whose converted copy is missing or older than it.
	public static void Scan()
	{
		let found = scope List<String>();
		defer
		{
			ClearAndDeleteItems!(found);
		}
		Walk(Assets.ProjectPath, "", found, 0);
		for (let relative in found)
		{
			if (!UpToDate(relative))
				Request(relative);
		}
	}

	static void Walk(StringView folder, StringView relative, List<String> found, int depth)
	{
		if (depth > 32)
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (!name.StartsWith('.') && Assets.IsConvertedModel(name))
				found.Add(new $"{relative}{name}");
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = entry.GetFileName(.. scope .());
			if (!name.StartsWith('.'))
				Walk(scope $"{folder}/{name}" , scope $"{relative}{name}/" , found, depth + 1);
		}
	}

	/// Converts a model on the importer's thread (no-op if it is waiting already).
	public static void Request(StringView relative)
	{
		using (sLock.Enter())
		{
			for (let waiting in sQueue)
			{
				if (waiting == relative)
					return;
			}
			sQueue.Add(new String(relative));
			if (sWorker == null)
			{
				sWorker = new Thread(new => WorkerMain);
				sWorker.SetName("Model import");
				// It deletes itself when the queue is empty.
				sWorker.Start(true);
			}
		}
	}

	static void WorkerMain()
	{
		while (true)
		{
			String relative = null;
			using (sLock.Enter())
			{
				if (sQueue.IsEmpty)
				{
					sWorker = null;
					Status.Clear();
					return;
				}
				relative = sQueue.PopFront();
				Status.Set(scope $"Importing {relative}");
			}
			let error = scope String();
			let ok = Convert(relative, error);
			using (sLock.Enter())
			{
				if (sErrors.GetAndRemoveAlt(relative) case .Ok(let old))
				{
					delete old.key;
					delete old.value;
				}
				if (!ok)
					sErrors[new String(relative)] = new String(error);
				sDone.Add(relative);
			}
		}
	}

	/// Each frame, on the main thread: models converted since are read again wherever they are used.
	public static void Update()
	{
		using (sLock.Enter())
		{
			for (let relative in sDone)
			{
				if (sErrors.TryGetValueAlt(relative, let error))
					Log.Warning(scope $"Could not import {relative}: {error}");
				SkinnedModel.Forget(relative);
				Assets.Forget(relative);
				AssetPreviews.Invalidate(scope $"{Assets.ProjectPath}/{relative}");
				delete relative;
			}
			sDone.Clear();
		}
	}

	/// True while models are waiting or being converted.
	public static bool Busy
	{
		get
		{
			using (sLock.Enter())
				return sWorker != null;
		}
	}

	/// Converts a model now, on this thread: the converter (when the file is newer than its last conversion), then the
	/// import settings. False with the reason when it could not.
	public static bool Convert(StringView relative, String error)
	{
		let full = scope $"{Assets.ProjectPath}/{relative}";
		let stamp = Stamp(relative, .. scope .());
		let converted = Assets.ConvertedModelCache(relative, .. scope .());
		let raw = RawPath(relative, .. scope .());
		Directory.CreateDirectory(Path.GetDirectoryPath(converted, .. scope .())).IgnoreError();
		// The converter runs only when the file itself changed (its stamp is kept as "<raw>.from").
		let source = SourceStamp(full, .. scope .());
		let rawFrom = scope String();
		if (!File.Exists(raw) || File.ReadAllText(scope $"{raw}.from" , rawFrom) case .Err || rawFrom != source)
		{
			let made = scope $"{raw}.part.glb";
			File.Delete(made).IgnoreError();
			if (!RunConverter(full, made, error))
				return false;
			File.Delete(raw).IgnoreError();
			if (File.Move(made, raw) case .Err)
			{
				error.Set("the converted file could not be kept");
				return false;
			}
			File.WriteAllText(scope $"{raw}.from" , source).IgnoreError();
		}
		let settings = scope ModelImportSettings();
		settings.Read(full);
		let part = scope $"{converted}.part";
		if (tn_model_import_settings(raw.CStr(), part.CStr(), settings.scale, settings.zUp ? 1 : 0, settings.animations ? 1 : 0, settings.clips.CStr(), settings.materials ? 1 : 0) == 0)
		{
			error.Set("the converted file could not be read");
			return false;
		}
		File.Delete(converted).IgnoreError();
		if (File.Move(part, converted) case .Err)
		{
			error.Set("the converted file could not be written");
			return false;
		}
		File.WriteAllText(scope $"{converted}.from" , stamp).IgnoreError();
		return true;
	}

	/// The clips the converter found in a model (before the import settings leave any out).
	public static void ClipNames(StringView relative, List<String> names)
	{
		let raw = RawPath(relative, .. scope .());
		let scene = Native.tn_gltf_load(raw.CStr());
		if (scene == null)
			return;
		for (int32 i < Native.tn_gltf_anim_count(scene))
		{
			let clip = Native.tn_gltf_get_anim(scene, i);
			names.Add(new String(&clip.name[0]));
		}
		Native.tn_gltf_free(scene);
	}

	// ---- Converters ----

	static String sTool ~ delete _;
	static String sBlender ~ delete _;

	/// Tallow's own converter, built with the engine's native libraries, or else Assimp's command line tool when it is
	/// installed. "" when there is neither.
	static StringView Tool
	{
		get
		{
			if (sTool != null)
				return sTool;
			sTool = new .();
			let root = scope String(Project.Current?.EngineRoot ?? "");
#if BF_PLATFORM_WINDOWS
			let own = scope $"{root}/build/native-win/tallow_modelconv.exe";
#else
			let own = scope $"{root}/build/native/tallow_modelconv";
#endif
			if (!root.IsEmpty && File.Exists(own))
				sTool.Set(own);
			else if (Terminal.Run(scope $"assimp version > {Terminal.Null} 2>&1") == 0)
				sTool.Set("assimp");
			return sTool;
		}
	}

	/// Blender, if it is installed: it converts .blend files (and FBX, OBJ, STL or PLY when there is no other tool).
	public static StringView Blender
	{
		get
		{
			if (sBlender != null)
				return sBlender;
			sBlender = new .();
			let env = scope String();
			Environment.GetEnvironmentVariable("TALLOW_BLENDER", env).IgnoreError();
			if (!env.IsEmpty && File.Exists(env))
				sBlender.Set(env);
			else if (Terminal.Run(scope $"blender --version > {Terminal.Null} 2>&1") == 0)
				sBlender.Set("blender");
			else
			{
#if BF_PLATFORM_WINDOWS
				let folder = "C:/Program Files/Blender Foundation";
				if (Directory.Exists(folder))
				{
					for (let entry in Directory.EnumerateDirectories(folder))
					{
						let candidate = scope $"{entry.GetFilePath(.. scope .())}/blender.exe";
						if (File.Exists(candidate))
							sBlender.Set(candidate);
					}
				}
			#elif BF_PLATFORM_MACOS
				if (File.Exists("/Applications/Blender.app/Contents/MacOS/Blender"))
					sBlender.Set("/Applications/Blender.app/Contents/MacOS/Blender");
#endif
			}
			return sBlender;
		}
	}

	/// The script Blender runs: reads the file (a .blend opens as it is) and writes a .glb.
	const String BlenderScript =
		"""
		import bpy, sys
		args = sys.argv[sys.argv.index('--') + 1:]
		source, out = args[0], args[1]
		kind = source.lower().rsplit('.', 1)[-1]
		if kind == 'fbx': bpy.ops.import_scene.fbx(filepath=source)
		elif kind == 'obj': bpy.ops.wm.obj_import(filepath=source)
		elif kind == 'stl': bpy.ops.wm.stl_import(filepath=source)
		elif kind == 'ply': bpy.ops.wm.ply_import(filepath=source)
		bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_apply=True, export_animations=True)
		""";

	static bool RunConverter(StringView source, StringView output, String error)
	{
		let log = scope $"{output}.log";
		let command = scope String();
		let blend = source.EndsWith(".blend", .OrdinalIgnoreCase);
		let assimpOnly = source.EndsWith(".dae", .OrdinalIgnoreCase) || source.EndsWith(".3ds", .OrdinalIgnoreCase);
		// Assimp's command line tool cannot be told to bring FBX units to metres, and Blender reads FBX rigs best, so an
		// FBX goes to Blender unless Tallow's own converter is there.
		let fbxToBlender = source.EndsWith(".fbx", .OrdinalIgnoreCase) && Tool == "assimp" && !Blender.IsEmpty;
		if (!blend && !fbxToBlender && !Tool.IsEmpty)
		{
			Terminal.Quote(Tool, command);
			if (Tool == "assimp")
			{
				command.Append(" export ");
				Terminal.Quote(source, command);
				command.Append(' ');
				Terminal.Quote(output, command);
				command.Append(" -fglb2 -tri -jiv -gsn -lbw -embtex");
			}
			else
			{
				command.Append(' ');
				Terminal.Quote(source, command);
				command.Append(' ');
				Terminal.Quote(output, command);
			}
		}
		else if (!Blender.IsEmpty && !assimpOnly)
		{
			let script = scope $"{Path.GetDirectoryPath(output, .. scope .())}/tallow_blender_import.py";
			File.WriteAllText(script, BlenderScript).IgnoreError();
			Terminal.Quote(Blender, command);
			command.Append(" -b ");
			if (blend)
				Terminal.Quote(source, command);
			else
				command.Append("--factory-startup");
			command.Append(" --python ");
			Terminal.Quote(script, command);
			command.Append(" -- ");
			Terminal.Quote(source, command);
			command.Append(' ');
			Terminal.Quote(output, command);
		}
		else
		{
			error.Set(blend ? "Blender is needed for .blend files and was not found (install it, or set TALLOW_BLENDER to blender's path)" : "no model converter was found (Tallow's tallow_modelconv, Assimp's assimp tool, or Blender)");
			return false;
		}
		command.AppendF(" > {} 2>&1", log);
		let status = Terminal.Run(command);
		if (status == 0 && File.Exists(output))
		{
			File.Delete(log).IgnoreError();
			return true;
		}
		// The last line the converter printed says why.
		let text = scope String();
		File.ReadAllText(log, text).IgnoreError();
		text.Trim();
		let last = text.LastIndexOf('\n');
		error.Set(last >= 0 ? text.Substring(last + 1) : text);
		if (error.IsEmpty)
			error.Set(scope $"the converter stopped with status {status}");
		File.Delete(log).IgnoreError();
		return false;
	}
}
