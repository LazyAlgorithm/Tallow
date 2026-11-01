using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Filters compiled project components against declarations that still exist on disk.
/// Cached type identities survive registry rebuilds; external-library components remain available.
class ScriptComponentCatalog
{
	HashSet<Type> mKnown = new .() ~ delete _;
	HashSet<Type> mLive = new .() ~ delete _;
	String mNamespace = new .() ~ delete _;
	public void Refresh(StringView root, StringView projectNamespace)
	{
		mNamespace.Set(projectNamespace);
		mLive.Clear();
		Scan(root, 0);
	}

	void Scan(StringView folder, int depth)
	{
		if (depth > 32 || !Directory.Exists(folder)) return;
		List<ComponentRegistry.Info> matches = scope .();
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name.StartsWith('.') || !name.EndsWith(".bf", .OrdinalIgnoreCase)) continue;
			ScriptAssetResolver.Find(scope $"{folder}/{name}" , mNamespace, matches);
			for (let info in matches)
			{
				mKnown.Add(info.type);
				mLive.Add(info.type);
			}
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.StartsWith('.'))
				Scan(scope $"{folder}/{name}" , depth + 1);
		}
	}

	public bool IsVisible(ComponentRegistry.Info info)
	{
		if (mLive.Contains(info.type)) return true;
		if (mKnown.Contains(info.type)) return false;
		// Also hide stale project types if a script was deleted before this editor session.
		if (!mNamespace.IsEmpty && info.fullName.StartsWith(scope $"{mNamespace}.")) return false;
		return true;
	}
}
