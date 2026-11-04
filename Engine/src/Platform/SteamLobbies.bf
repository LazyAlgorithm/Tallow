using System;
using System.Collections;

namespace Tallow;

/// Steam lobbies used as a notice board, for a list of games anyone can join (a server browser).
///
///   // Host: make a public lobby and say what the game is.
///   SteamLobbies.Create(.Public, 16);
///   SteamLobbies.Set("game", "mygame-1");
///   SteamLobbies.Set("host", scope $"{Steam.UserId}");
///
///   // Anyone: ask for the lobbies whose "game" is "mygame-1", then read them when Searching is false.
///   SteamLobbies.Search("game", "mygame-1");
///   for (let lobby in SteamLobbies.Results) SteamLobbies.Get(lobby, "host", host);
///
/// Nobody joins the lobby itself: the players connect to the host the usual way (with the Steam transport, to its
/// Steam ID). Values set before the lobby exists are kept and written as soon as Steam has made it. Call
/// Steam.Update every frame (the Steam transport does) so results arrive.
static class SteamLobbies
{
	public enum LobbyType : int32
	{
		Private = 0,
		FriendsOnly = 1,
		Public = 2,
		Invisible = 3
	}

	/// The lobby this program made, or 0.
	public static uint64 Current { get; private set; }
	/// True while Steam is still making the lobby asked for with Create.
	public static bool Creating => sCreateCall != 0;
	/// True from Search until its results are in Results.
	public static bool Searching => sSearchCall != 0;
	/// Lobbies the last search found.
	public static List<uint64> Results = new .() ~ delete _;
	/// Goes up by one each time a search finishes (whether or not it found anything).
	public static int32 SearchCount { get; private set; }
	/// Why the last Create or Search failed, or empty.
	public static String Error = new .() ~ delete _;

	static void* sMatchmaking;
	static void* sUtils;
	static uint64 sCreateCall, sSearchCall;
	static bool sBound;
	static Dictionary<String, String> sData = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	static function uint64(void* self, LobbyType type, int32 maxMembers) sCreateLobby;
	static function bool(void* self, uint64 lobby, char8* key, char8* value) sSetLobbyData;
	static function char8*(void* self, uint64 lobby, char8* key) sGetLobbyData;
	static function void(void* self, uint64 lobby) sLeaveLobby;
	static function void(void* self, char8* key, char8* value, int32 comparison) sAddStringFilter;
	static function void(void* self, int32 distance) sAddDistanceFilter;
	static function void(void* self, int32 count) sAddResultCountFilter;
	static function uint64(void* self) sRequestLobbyList;
	static function uint64(void* self, int32 index) sGetLobbyByIndex;
	static function bool(void* utils, uint64 call, bool* failed) sIsCallCompleted;
	static function bool(void* utils, uint64 call, void* result, int32 size, int32 expectedId, bool* failed) sGetCallResult;

	const int32 LobbyMatchListId = 510;
	const int32 LobbyCreatedId = 513;
	// LobbyCreated_t is an EResult then a 64-bit lobby ID. Steam packs its callback structures to 8 bytes on Windows
	// and 4 elsewhere, so the size differs.
#if BF_PLATFORM_WINDOWS
	const int32 LobbyCreatedSize = 16;
#else
	const int32 LobbyCreatedSize = 12;
#endif

	static bool Bind()
	{
		if (!Steam.IsReady)
			return false;
		if (sBound)
			return sMatchmaking != null;
		sBound = true;
		sMatchmaking = Steam.Interface("SteamAPI_SteamMatchmaking_v");
		sUtils = Steam.Interface("SteamAPI_SteamUtils_v");
		sCreateLobby = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_CreateLobby");
		sSetLobbyData = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_SetLobbyData");
		sGetLobbyData = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_GetLobbyData");
		sLeaveLobby = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_LeaveLobby");
		sAddStringFilter = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter");
		sAddDistanceFilter = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter");
		sAddResultCountFilter = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter");
		sRequestLobbyList = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_RequestLobbyList");
		sGetLobbyByIndex = (.)Steam.Symbol("SteamAPI_ISteamMatchmaking_GetLobbyByIndex");
		sIsCallCompleted = (.)Steam.Symbol("SteamAPI_ISteamUtils_IsAPICallCompleted");
		sGetCallResult = (.)Steam.Symbol("SteamAPI_ISteamUtils_GetAPICallResult");
		if (sMatchmaking == null || sUtils == null || sCreateLobby == null || sSetLobbyData == null || sGetLobbyData == null || sLeaveLobby == null
			|| sAddStringFilter == null || sRequestLobbyList == null || sGetLobbyByIndex == null || sIsCallCompleted == null || sGetCallResult == null)
		{
			sMatchmaking = null;
			return false;
		}
		return true;
	}

	/// True when Steam is running and its library has the lobby functions.
	public static bool Available => Bind();

	/// Asks Steam for a lobby of this type; Current is set when it has been made. Leaves any lobby made before.
	public static bool Create(LobbyType type, int32 maxMembers)
	{
		Error.Clear();
		if (!Bind())
		{
			Error.Set("Steam lobbies are not available.");
			return false;
		}
		Leave();
		sCreateCall = sCreateLobby(sMatchmaking, type, Math.Max(maxMembers, 1));
		if (sCreateCall == 0)
		{
			Error.Set("Steam would not make a lobby.");
			return false;
		}
		return true;
	}

	/// Writes a value into this program's lobby (now, or once Steam has made it).
	public static void Set(StringView key, StringView value)
	{
		if (sData.TryGetAlt(key, let oldKey, let oldValue))
		{
			if (oldValue == value && Current != 0)
				return;
			oldValue.Set(value);
		}
		else
			sData[new String(key)] = new String(value);
		if (Current != 0 && Bind())
			sSetLobbyData(sMatchmaking, Current, scope String(key).CStr(), scope String(value).CStr());
	}

	/// Takes this program's lobby down (and forgets its values).
	public static void Leave()
	{
		if (Current != 0 && Bind())
			sLeaveLobby(sMatchmaking, Current);
		Current = 0;
		sCreateCall = 0;
		for (let pair in sData)
		{
			delete pair.key;
			delete pair.value;
		}
		sData.Clear();
	}

	/// Asks for the lobbies, anywhere in the world, whose `key` is `value` (at most `limit` of them).
	public static bool Search(StringView key, StringView value, int32 limit = 50)
	{
		Error.Clear();
		if (!Bind())
		{
			Error.Set("Steam lobbies are not available.");
			return false;
		}
		sAddStringFilter(sMatchmaking, scope String(key).CStr(), scope String(value).CStr(), 0);
		if (sAddDistanceFilter != null)
			sAddDistanceFilter(sMatchmaking, 3); // worldwide
		if (sAddResultCountFilter != null)
			sAddResultCountFilter(sMatchmaking, limit);
		sSearchCall = sRequestLobbyList(sMatchmaking);
		if (sSearchCall == 0)
		{
			Error.Set("Steam would not search for lobbies.");
			return false;
		}
		return true;
	}

	/// A value from any lobby a search found (or this program's own), or empty.
	public static void Get(uint64 lobby, StringView key, String value)
	{
		if (!Bind())
			return;
		let text = sGetLobbyData(sMatchmaking, lobby, scope String(key).CStr());
		if (text != null)
			value.Append(text);
	}

	/// Picks up finished requests. Called by Steam.Update.
	public static void Update()
	{
		if (!sBound || sMatchmaking == null)
			return;
		bool failed = false;
		if (sCreateCall != 0 && sIsCallCompleted(sUtils, sCreateCall, &failed))
		{
			uint8[16] created = default;
			bool callFailed = failed;
			let call = sCreateCall;
			sCreateCall = 0;
			if (!failed && sGetCallResult(sUtils, call, &created, LobbyCreatedSize, LobbyCreatedId, &callFailed) && !callFailed && *(int32*)&created[0] == 1)
			{
				Current = *(uint64*)&created[4];
				for (let pair in sData)
					sSetLobbyData(sMatchmaking, Current, pair.key.CStr(), pair.value.CStr());
			}
			else
				Error.Set(scope $"Steam could not make the lobby (result {*(int32*)&created[0]}).");
		}
		failed = false;
		if (sSearchCall != 0 && sIsCallCompleted(sUtils, sSearchCall, &failed))
		{
			uint32 count = 0;
			bool callFailed = failed;
			let call = sSearchCall;
			sSearchCall = 0;
			Results.Clear();
			if (!failed && sGetCallResult(sUtils, call, &count, 4, LobbyMatchListId, &callFailed) && !callFailed)
			{
				for (int32 i < (int32)count)
				{
					let lobby = sGetLobbyByIndex(sMatchmaking, i);
					if (lobby != 0)
						Results.Add(lobby);
				}
			}
			else
				Error.Set("The lobby search failed.");
			SearchCount++;
		}
	}

	/// Forgets everything (Steam is shutting down).
	public static void Reset()
	{
		Leave();
		sSearchCall = 0;
		Results.Clear();
		sBound = false;
		sMatchmaking = null;
	}
}
