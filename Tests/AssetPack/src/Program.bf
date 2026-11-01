using System;
using System.Collections;
using System.IO;
using Tallow;

namespace AssetPackTests;

/// Reads a game's files out of an asset pack: text, bytes, an image, a model and sounds, and refuses a pack that
/// was changed. run.py builds the packs and the folder of loose files this is given:
///   AssetPackTests <pack> <folder the pack stands in for> <the same pack with one byte changed> <folder of loose files>
class Program
{
	static bool Check(bool condition, StringView what)
	{
		Console.WriteLine(scope $"{(condition ? "PASS" : "FAIL")}: {what}");
		return condition;
	}

	public static int Main(String[] args)
	{
		if (args.Count < 4)
		{
			Console.WriteLine("Run Tests/AssetPack/run.py, which makes the packs this needs.");
			return 1;
		}
		let pack = args[0], root = args[1], damaged = args[2], loose = args[3];
		bool ok = true;
		Audio.NoDevice = true;

		ok &= Check(!AssetPack.Mounted && !AssetPack.Exists(scope $"{root}/Assets/notes.txt"), "before a pack is mounted its files are not there");
		ok &= Check(!AssetPack.Mount(scope $"{root}/nothing.tpak" , root) && !AssetPack.Mount(scope $"{loose}/Assets/notes.txt" , root), "a missing file, or one that is not a pack, does not mount");
		ok &= Check(AssetPack.Mount(pack, root) && AssetPack.Mounted && AssetPack.FileCount == 7, "a pack mounts, and knows how many files it holds");

		let text = scope String();
		ok &= Check(AssetPack.ReadAllText(scope $"{root}/Assets/notes.txt" , text) case .Ok && text == "packed notes\n", "text is read out of it");
		text.Clear();
		ok &= Check(AssetPack.ReadAllText(scope $"{root}//Assets/./Sub/../notes.txt" , text) case .Ok && text == "packed notes\n" && AssetPack.Exists(scope $"{root}\\Assets\\notes.txt"), "however the path is spelled");
		let bytes = scope List<uint8>();
		bool counted = AssetPack.ReadAll(scope $"{root}/Assets/Sub/numbers.bin" , bytes) case .Ok && bytes.Count == 70000;
		for (int i = 0; counted && i < bytes.Count; i++)
			counted = bytes[i] == (uint8)((i * 7) % 251);
		ok &= Check(counted, "a large compressed file comes back byte for byte");
		ok &= Check(AssetPack.FolderExists(scope $"{root}/Assets/Sub") && !AssetPack.FolderExists(scope $"{root}/Assets/Other") && !AssetPack.Exists(scope $"{root}/Assets/missing.txt"), "folders and missing files are told apart");
		let listed = scope List<String>();
		AssetPack.FilesIn(scope $"{root}/Assets" , listed);
		ok &= Check(listed.Count == 6, "the files in a folder can be listed");
		ClearAndDeleteItems!(listed);

		// Through the project's asset paths, as game code would.
		Assets.ProjectPath.Set(scope $"{root}/Assets");
		text.Clear();
		ok &= Check(Assets.ReadText("notes.txt", text) && text == "packed notes\n" && Assets.FileExists("Sub/numbers.bin") && !Assets.FileExists("nope.bin"), "Assets.ReadText and FileExists find packed files by project path");

		// What the native loaders read.
		int32 width = 0, height = 0;
		let pixels = Native.tn_image_load(scope $"{root}/Assets/dot.png" .CStr(), &width, &height);
		ok &= Check(pixels != null && width == 4 && height == 2 && pixels[0] == 255 && pixels[1] == 128 && pixels[2] == 0, "an image is decoded from the pack");
		if (pixels != null)
			Native.tn_image_free(pixels);
		let model = Native.tn_gltf_load(scope $"{root}/Assets/block.glb" .CStr());
		ok &= Check(model != null && Native.tn_gltf_prim_count(model) > 0, "a model is loaded from the pack");
		if (model != null)
			Native.tn_gltf_free(model);
		Audio.Start();
		let sound = Audio.tn_audio_source_create(scope $"{root}/Assets/beep.wav" .CStr(), 0, 0, 0);
		ok &= Check(sound != null && Math.Abs(Audio.tn_audio_source_length(sound) - 0.25f) < 0.01f, "a sound is decoded from the pack");
		let stream = Audio.tn_audio_source_create(scope $"{root}/Assets/beep.wav" .CStr(), 0, 1, 0);
		ok &= Check(stream != null && Math.Abs(Audio.tn_audio_source_length(stream) - 0.25f) < 0.01f, "and streamed from it");
		let missing = Audio.tn_audio_source_create(scope $"{root}/Assets/silence.wav" .CStr(), 0, 0, 0);
		ok &= Check(missing == null, "a sound that is nowhere is not loaded");
		if (sound != null)
			Audio.tn_audio_source_destroy(sound);
		if (stream != null)
			Audio.tn_audio_source_destroy(stream);

		// Loose files still work beside a pack: mods, and everything while developing.
		text.Clear();
		ok &= Check(AssetPack.ReadAllText(scope $"{loose}/Assets/notes.txt" , text) case .Ok && text == "loose notes\n" && !AssetPack.Contains(scope $"{loose}/Assets/notes.txt"), "a file outside the pack is read from disk");

		// A pack that somebody edited.
		AssetPack.UnmountAll();
		ok &= Check(!AssetPack.Mounted && !AssetPack.Exists(scope $"{root}/Assets/notes.txt"), "unmounting takes the files away again");
		ok &= Check(AssetPack.Mount(damaged, loose), "a pack with one byte changed still mounts");
		text.Clear();
		bytes.Clear();
		ok &= Check(AssetPack.ReadAll(scope $"{loose}/Assets/Sub/numbers.bin" , bytes) case .Err && bytes.IsEmpty, "but the changed file is refused");
		ok &= Check(AssetPack.ReadAllText(scope $"{loose}/Assets/notes.txt" , text) case .Ok && text == "packed notes\n", "the others still load, from the pack rather than the loose copy beside it");
		AssetPack.UnmountAll();
		Audio.Shutdown();
		Console.WriteLine(ok ? "ALL PASSED" : "FAILED");
		return ok ? 0 : 1;
	}
}
