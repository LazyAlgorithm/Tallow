using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// One achievement as listed in the project's Achievements.tach file.
class AchievementInfo
{
	/// The API name: what code passes to Unlock, and what the achievement is called on the Steamworks site.
	public String id = new .() ~ delete _;
	public String name = new .() ~ delete _;
	public String description = new .() ~ delete _;
	/// Not shown to players until it is earned.
	public bool hidden;
	/// Keep this achievement local even when Steam is connected; never calls Steam for this ID.
	public bool localOnly;
}

/// Achievements and simple counters, with one call each:
///
///   Achievements.Unlock("FIRST_WIN");
///   Achievements.AddStat("kills", 1);
///   Achievements.SetProgress("COLLECTOR", found, 50);     // unlocks when found reaches 50
///
/// When the game is running under Steam they go to Steam, which shows its own pop-up. Without Steam they are kept
/// in a small file on the player's machine and a pop-up is drawn in the game, so the same code works in the
/// editor, in a build without Steam and in a Steam build.
///
/// The list of achievements is edited in the editor (Window > Achievements) and saved as Achievements.tach in the
/// project. Steam-backed entries also need a Steamworks ID; local-only entries never do.
static class Achievements
{
	static List<AchievementInfo> sDefinitions = new .() ~ DeleteContainerAndItems!(_);
	static bool sLoaded;
	static bool sStateLoaded;
	static List<String> sUnlocked = new .() ~ DeleteContainerAndItems!(_);
	static Dictionary<String, int32> sStats = new .() ~ DeleteDictionaryAndKeys!(_);
	static List<(String title, String text, float left)> sToasts = new .() ~
		{
			for (let t in _)
			{
				delete t.title;
				delete t.text;
			}
			delete _;
		};

	/// Names the folder the local progress file is kept in; set from the project's name at start-up.
	public static String SaveName = new .("Game") ~ delete _;
	/// Called when an achievement is unlocked for the first time, with its id.
	public static Event<delegate void(StringView id)> OnUnlocked ~ _.Dispose();
	/// Draw the in-game pop-up when Steam is not handling it.
	public static bool ShowToasts = true;

	public const String FileName = "Achievements.tach";

	public static List<AchievementInfo> Definitions
	{
		get
		{
			if (!sLoaded)
				Reload();
			return sDefinitions;
		}
	}

	public static AchievementInfo Find(StringView id)
	{
		for (let info in Definitions)
		{
			if (info.id == id)
				return info;
		}
		return null;
	}

	/// Reads the project's list again.
	public static void Reload()
	{
		sLoaded = true;
		ClearAndDeleteItems!(sDefinitions);
		let path = scope String();
		Assets.ResolvePath(FileName, path);
		let text = scope String();
		if (AssetPack.ReadAllText(path, text) case .Err)
			return;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count < 2 || tokens[0] != "achievement")
				continue;
			let info = new AchievementInfo();
			info.id.Set(tokens[1]);
			info.name.Set(tokens.Count > 2 ? tokens[2] : tokens[1]);
			if (tokens.Count > 3)
				info.description.Set(tokens[3]);
			for (int i = 4; i < tokens.Count; i++)
			{
				if (tokens[i] == "hidden")
					info.hidden = true;
				if (tokens[i] == "local-only")
					info.localOnly = true;
			}
			sDefinitions.Add(info);
		}
	}

	/// Writes the list to the project. Used by the editor.
	public static bool SaveDefinitions()
	{
		let text = scope String();
		for (let info in Definitions)
			text.AppendF("achievement {} {} {}{}{}\n", SceneSerializer.Quote(info.id, .. scope .()), SceneSerializer.Quote(info.name, .. scope .()), SceneSerializer.Quote(info.description, .. scope .()), info.hidden ? " hidden" : "", info.localOnly ? " local-only" : "");
		let path = scope String();
		Assets.ResolvePath(FileName, path);
		return File.WriteAllText(path, text) case .Ok;
	}

	// ---- local progress, used when Steam is not ----

	static void StatePath(String path)
	{
		let folder = SDL.SDL_GetPrefPath("Tallow", SaveName.CStr());
		if (folder != null)
			path.Append(folder);
		path.Append("achievements.sav");
	}

	static void LoadState()
	{
		if (sStateLoaded)
			return;
		sStateLoaded = true;
		let path = scope String();
		StatePath(path);
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err)
			return;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count >= 2 && tokens[0] == "unlocked" && !HasLocal(tokens[1]))
				sUnlocked.Add(new String(tokens[1]));
			else if (tokens.Count >= 3 && tokens[0] == "stat")
				StoreLocalStat(tokens[1], SceneSerializer.ParseInt(tokens[2]));
		}
	}

	static void SaveState()
	{
		let text = scope String();
		for (let id in sUnlocked)
			text.AppendF("unlocked {}\n", SceneSerializer.Quote(id, .. scope .()));
		for (let entry in sStats)
			text.AppendF("stat {} {}\n", SceneSerializer.Quote(entry.key, .. scope .()), entry.value);
		let path = scope String();
		StatePath(path);
		File.WriteAllText(path, text).IgnoreError();
	}

	static bool HasLocal(StringView id)
	{
		for (let entry in sUnlocked)
		{
			if (entry == id)
				return true;
		}
		return false;
	}

	static void StoreLocalStat(StringView name, int32 value)
	{
		if (sStats.TryGetAlt(name, let key, let old))
			sStats[key] = value;
		else
			sStats[new String(name)] = value;
	}

	/// True when Steam is keeping the achievements, false when they are kept locally.
	public static bool OnSteam => Steam.Start() && Steam.HasStats;

	/// Backend for one achievement. A local-only ID does not even start Steam.
	public static bool UsesSteam(StringView id) => Find(id)?.localOnly != true && OnSteam;

	// ---- the API ----

	public static bool IsUnlocked(StringView id)
	{
		if (UsesSteam(id))
			return Steam.IsAchievementUnlocked(id);
		LoadState();
		return HasLocal(id);
	}

	/// Unlocks an achievement. Returns true the first time, false if the player already had it.
	public static bool Unlock(StringView id)
	{
		if (IsUnlocked(id))
			return false;
		let info = Find(id);
		if (info == null)
			Log.Warning(scope $"Achievement '{id}' is not in the project's list (Window > Achievements).");
		if (UsesSteam(id))
		{
			if (!Steam.UnlockAchievement(id))
			{
				Log.Warning(scope $"Steam refused achievement '{id}'. It must exist on the Steamworks site with exactly this id.");
				return false;
			}
		}
		else
		{
			sUnlocked.Add(new String(id));
			SaveState();
			if (ShowToasts)
				sToasts.Add((new String(info != null ? (StringView)info.name : id), new String(info != null ? (StringView)info.description : ""), 4.0f));
		}
		Log.Info(scope $"Achievement unlocked: {(info != null ? (StringView)info.name : id)}");
		OnUnlocked(id);
		return true;
	}

	/// Reports progress toward an achievement and unlocks it when current reaches max.
	public static void SetProgress(StringView id, int32 current, int32 max)
	{
		if (current >= max)
			Unlock(id);
		else if (UsesSteam(id) && !IsUnlocked(id))
			Steam.ShowAchievementProgress(id, (uint32)Math.Max(current, 0), (uint32)Math.Max(max, 1));
	}

	/// Takes an achievement away again. For testing.
	public static void Clear(StringView id)
	{
		if (UsesSteam(id))
		{
			Steam.ClearAchievement(id);
			return;
		}
		LoadState();
		for (let entry in sUnlocked)
		{
			if (entry == id)
			{
				sUnlocked.Remove(entry);
				delete entry;
				break;
			}
		}
		SaveState();
	}

	/// Takes every achievement and stat away. For testing.
	public static void ClearAll()
	{
		if (OnSteam)
		{
			Steam.ResetAllStats(true);
		}
		LoadState();
		ClearAndDeleteItems!(sUnlocked);
		for (let key in sStats.Keys)
			delete key;
		sStats.Clear();
		SaveState();
	}

	/// A whole-number counter kept with the player's progress, such as kills or games played. On Steam the stat
	/// must exist on the Steamworks site with the same name.
	public static int32 GetStat(StringView name, bool localOnly = false)
	{
		if (!localOnly && OnSteam)
		{
			Steam.GetStat(name, let value);
			return value;
		}
		LoadState();
		return sStats.TryGetValueAlt(name, let local) ? local : 0;
	}

	public static void SetStat(StringView name, int32 value, bool localOnly = false)
	{
		if (!localOnly && OnSteam)
		{
			Steam.SetStat(name, value);
			return;
		}
		LoadState();
		StoreLocalStat(name, value);
		SaveState();
	}

	/// Adds to a counter and returns the new value.
	public static int32 AddStat(StringView name, int32 amount = 1, bool localOnly = false)
	{
		let value = GetStat(name, localOnly) + amount;
		SetStat(name, value, localOnly);
		return value;
	}

	/// Draws the "achievement unlocked" pop-ups over the game. Called by the engine after every OnGUI.
	public static void DrawToasts()
	{
		if (sToasts.IsEmpty)
			return;
		float y = 16;
		for (int i = sToasts.Count - 1; i >= 0; i--)
		{
			var toast = ref sToasts[i];
			toast.left -= Time.UnscaledDeltaTime;
			if (toast.left <= 0)
			{
				delete toast.title;
				delete toast.text;
				sToasts.RemoveAt(i);
				continue;
			}
			let alpha = Math.Min(toast.left, 1.0f);
			let width = 320.0f;
			let x = GUI.Width - width - 16;
			GUI.Box(x, y, width, toast.text.IsEmpty ? 50 : 70, .(0.07f, 0.09f, 0.12f, 0.92f * alpha));
			GUI.Box(x, y, 5, toast.text.IsEmpty ? 50 : 70, .(0.36f, 0.78f, 0.95f, alpha));
			GUI.Label(x + 16, y + 8, "Achievement unlocked", .(0.55f, 0.82f, 0.95f, alpha));
			GUI.Label(x + 16, y + 27, toast.title, .(1, 1, 1, alpha));
			if (!toast.text.IsEmpty)
				GUI.Label(x + 16, y + 46, toast.text, .(0.75f, 0.78f, 0.82f, alpha));
			y += (toast.text.IsEmpty ? 50 : 70) + 8;
		}
	}
}
