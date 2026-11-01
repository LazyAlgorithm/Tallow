using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Prefabs are saved object trees (.tprefab files) that can be stamped into any scene.
static class Prefab
{
	static Dictionary<String, String> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	/// Writes an object and its children to a prefab file.
	public static bool Save(GameObject root, StringView path)
	{
		let text = scope String();
		SceneSerializer.SaveObjectTree(root, text);
		sCache.Clear();
		return File.WriteAllText(path, text) case .Ok;
	}

	/// Creates a copy of a prefab. The path is relative to the project folder (or absolute).
	///
	/// In multiplayer a prefab whose root has a Network Identity is a shared object: created on the server it appears
	/// on every machine, and on a client this returns null because the server's copy is the one that will arrive.
	public static GameObject Instantiate(Scene scene, StringView path) => Share(scene, Create(scene, path), path);

	static GameObject Share(Scene scene, GameObject root, StringView path)
	{
		let network = scene.Network;
		if (root == null || network == null || network.Mode == .Offline || root.GetComponent<NetworkIdentity>() == null)
			return root;
		if (network.IsServer)
		{
			network.Adopt(root, path);
			return root;
		}
		scene.DestroyImmediate(root);
		return null;
	}

	/// Creates a copy on this machine only, whatever the prefab contains.
	public static GameObject Create(Scene scene, StringView path)
	{
		String text;
		if (!sCache.TryGetValueAlt(path, out text))
		{
			text = new String();
			let full = scope String();
			Assets.ResolvePath(path, full);
			if (AssetPack.ReadAllText(full, text) case .Err)
			{
				Log.Error(scope $"Prefab not found: {path}");
				delete text;
				return null;
			}
			sCache[new String(path)] = text;
		}
		let root = SceneSerializer.Instantiate(scene, text);
		// A prefab is saved wherever its source object stood; callers position the copy.
		if (root != null && root.Transform.Parent != null)
			root.Transform.SetParent(null, false);
		if (root != null)
			String.NewOrSet!(root.SpawnedFrom, path);
		return root;
	}

	public static GameObject Instantiate(Scene scene, StringView path, Vector3 position, Quaternion rotation)
	{
		let root = Create(scene, path);
		if (root != null)
			root.Transform.SetPositionAndRotation(position, rotation);
		return Share(scene, root, path);
	}

	/// Forget cached prefab text (the editor calls this when files change).
	public static void ClearCache()
	{
		for (let entry in sCache)
		{
			delete entry.key;
			delete entry.value;
		}
		sCache.Clear();
	}
}
