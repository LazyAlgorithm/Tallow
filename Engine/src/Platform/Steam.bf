using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// Steamworks, loaded at run time from libsteam_api so the engine and games run without Steam installed.
///
///   if (Steam.Init(480))                       // your App ID; 480 is Valve's public test app
///       Log.Info(scope $"Hello {Steam.UserName}");
///
/// The library is looked for in TALLOW_STEAM_LIB, beside the executable, in the project folder or its Libraries folder, and in a local
/// Steam installation. Ship the libsteam_api file from the Steamworks SDK beside your game. The Steam client must
/// be running and the user must own the app (everyone owns 480).
///
/// Only the parts the engine uses are bound here: start-up, the user's identity and the networking sockets used
/// by the Steam transport. `Library` gives the loaded handle for binding anything else from the SDK's flat API.
static class Steam
{
	static void* sLibrary;
	static bool sTried;
	static bool sReady;
	static String sError = new .() ~ delete _;
	static String sUserName = new .() ~ delete _;

	// Flat API entry points, found by name when the library loads.
	static function int32(char8* error) sInitFlat;
	// Libraries from before 2023 have this instead of SteamAPI_InitFlat.
	static function bool() sInitPlain;
	static function void() sShutdown;
	static function void() sRunCallbacks;
	static function bool() sIsSteamRunning;
	static function uint64(void* user) sGetSteamID;
	static function char8*(void* friends) sGetPersonaName;
	static function void(void* utils) sInitRelay;
	static function bool(void* utils, int32 setting, int32 value) sSetGlobalInt;
	static function void(void* sockets) sSocketsRunCallbacks;
	public static function bool(void* utils, function void(void* info) callback) SetConnectionStatusCallback;
	public static function uint32(void* sockets, int32 virtualPort, int32 optionCount, void* options) CreateListenSocketP2P;
	public static function uint32(void* sockets, void* identity, int32 virtualPort, int32 optionCount, void* options) ConnectP2P;
	public static function int32(void* sockets, uint32 connection) AcceptConnection;
	public static function bool(void* sockets, uint32 connection, int32 reason, char8* debug, bool linger) CloseConnection;
	public static function bool(void* sockets, uint32 listenSocket) CloseListenSocket;
	public static function int32(void* sockets, uint32 connection, void* data, uint32 size, int32 flags, int64* messageNumber) SendMessageToConnection;
	public static function int32(void* sockets, uint32 connection) FlushMessagesOnConnection;
	public static function uint32(void* sockets) CreatePollGroup;
	public static function bool(void* sockets, uint32 pollGroup) DestroyPollGroup;
	public static function bool(void* sockets, uint32 connection, uint32 pollGroup) SetConnectionPollGroup;
	public static function int32(void* sockets, uint32 pollGroup, void** messages, int32 maxMessages) ReceiveMessagesOnPollGroup;
	public static function int32(void* sockets, uint32 connection, void* status, int32 laneCount, void* lanes) GetConnectionRealTimeStatus;
	public static function void(void* message) ReleaseMessage;
	public static function void(void* identity) IdentityClear;
	public static function void(void* identity, uint64 steamId) IdentitySetSteamID64;

	static void* sUser, sFriends, sSockets, sUtils, sStats;

	// Achievements and stats (ISteamUserStats).
	static function bool(void* stats, char8* id) sSetAchievement;
	static function bool(void* stats, char8* id, bool* achieved) sGetAchievement;
	static function bool(void* stats, char8* id) sClearAchievement;
	static function bool(void* stats) sStoreStats;
	static function bool(void* stats, char8* id, uint32 current, uint32 max) sIndicateProgress;
	static function uint32(void* stats) sGetNumAchievements;
	static function char8*(void* stats, uint32 index) sGetAchievementName;
	static function char8*(void* stats, char8* id, char8* key) sGetAchievementAttribute;
	static function bool(void* stats, char8* name, int32 value) sSetStatInt;
	static function bool(void* stats, char8* name, int32* value) sGetStatInt;
	static function bool(void* stats, bool achievementsToo) sResetAllStats;

	/// The project's Steam App ID, from Project Settings. 0 means the game does not use Steam.
	public static uint32 AppId;
	/// The most a Steam connection may send a second, in bytes. Set before Steam starts.
	public static int32 SendRate = 1024 * 1024;

	/// Connects to Steam with the project's App ID, once. Quietly false when the project has none.
	public static bool Start() => sReady || (AppId != 0 && Init(AppId));

	public static bool HasStats => sReady && sStats != null && sSetAchievement != null && sStoreStats != null;

	public static bool UnlockAchievement(StringView id) => HasStats && sSetAchievement(sStats, scope String(id).CStr()) && sStoreStats(sStats);

	public static bool IsAchievementUnlocked(StringView id)
	{
		bool achieved = false;
		return HasStats && sGetAchievement != null && sGetAchievement(sStats, scope String(id).CStr(), &achieved) && achieved;
	}

	public static bool ClearAchievement(StringView id) => HasStats && sClearAchievement != null && sClearAchievement(sStats, scope String(id).CStr()) && sStoreStats(sStats);

	/// Shows Steam's "progress" pop-up for an achievement that is not yet earned.
	public static void ShowAchievementProgress(StringView id, uint32 current, uint32 max)
	{
		if (HasStats && sIndicateProgress != null)
			sIndicateProgress(sStats, scope String(id).CStr(), current, max);
	}

	/// How many achievements the app has on Steam, and the id of each.
	public static int AchievementCount => HasStats && sGetNumAchievements != null ? (int)sGetNumAchievements(sStats) : 0;

	public static void GetAchievementId(int index, String id)
	{
		if (!HasStats || sGetAchievementName == null)
			return;
		let name = sGetAchievementName(sStats, (uint32)index);
		if (name != null)
			id.Append(name);
	}

	/// key is "name", "desc" or "hidden" (which gives "0" or "1"). Empty if Steam does not know the achievement.
	public static void GetAchievementAttribute(StringView id, StringView key, String value)
	{
		if (!HasStats || sGetAchievementAttribute == null)
			return;
		let text = sGetAchievementAttribute(sStats, scope String(id).CStr(), scope String(key).CStr());
		if (text != null)
			value.Append(text);
	}

	public static bool SetStat(StringView name, int32 value) => HasStats && sSetStatInt != null && sSetStatInt(sStats, scope String(name).CStr(), value) && sStoreStats(sStats);

	public static bool GetStat(StringView name, out int32 value)
	{
		value = 0;
		return HasStats && sGetStatInt != null && sGetStatInt(sStats, scope String(name).CStr(), &value);
	}

	/// Wipes this user's stats, and their achievements too if asked. For testing.
	public static bool ResetAllStats(bool achievementsToo) => HasStats && sResetAllStats != null && sResetAllStats(sStats, achievementsToo) && sStoreStats(sStats);

	public static bool IsReady => sReady;
	/// Why Init failed, in words.
	public static StringView Error => sError;
	public static void* Library => sLibrary;
	public static void* Sockets => sSockets;
	public static void* Utils => sUtils;
	/// The signed-in user's 64-bit Steam ID, which is also the address friends connect to.
	// ---- Friends, presence and invitations (ISteamFriends) ----

	static function int32(void* friends, int32 flags) sGetFriendCount;
	static function uint64(void* friends, int32 index, int32 flags) sGetFriendByIndex;
	static function char8*(void* friends, uint64 id) sGetFriendPersonaName;
	static function char8*(void* friends, uint64 id) sGetPlayerNickname;
	static function bool(void* friends, uint64 id, bool nameOnly) sRequestUserInformation;
	static function int32(void* friends, uint64 id) sGetFriendPersonaState;
	// Steamworks FriendGameInfo_t: CGameID, IP, two ports, CSteamID (24 bytes).
	public struct FriendGameInfo
	{
		public uint64 gameId;
		public uint32 ip;
		public uint16 gamePort, queryPort;
		public uint64 lobby;
	}

	static function bool(void* friends, uint64 id, FriendGameInfo* game) sGetFriendGamePlayed;
	static function bool(void* friends, char8* key, char8* value) sSetRichPresence;
	static function void(void* friends) sClearRichPresence;
	static function char8*(void* friends, uint64 id, char8* key) sGetFriendRichPresence;
	static function bool(void* friends, uint64 id, char8* connect) sInviteUserToGame;
	static function bool(void* friends, uint64 id, int32 flags) sHasFriend;
	static function void(void* callback, int32 id) sRegisterCallback;
	const int32 FriendFlagImmediate = 0x04;

	/// How many Steam friends the signed-in user has. 0 without Steam.
	public static int FriendCount => sReady && sFriends != null && sGetFriendCount != null ? (int)sGetFriendCount(sFriends, FriendFlagImmediate) : 0;
	/// The Steam ID of a friend, by position in the list (0 to FriendCount - 1).
	public static uint64 FriendAt(int index) => sReady && sFriends != null && sGetFriendByIndex != null ? sGetFriendByIndex(sFriends, (int32)index, FriendFlagImmediate) : 0;

	public static void FriendName(uint64 id, String name)
	{
		if (!sReady || sFriends == null || sGetFriendPersonaName == null)
			return;
		let text = sGetFriendPersonaName(sFriends, id);
		if (text != null)
			name.Append(text);
	}

	/// Prefer this viewer's private friend nickname, falling back to the Steam display name.
	public static void PlayerName(uint64 id, String name)
	{
		if (!sReady || sFriends == null || id == 0) return;
		if (sGetPlayerNickname != null)
		{
			let nickname = sGetPlayerNickname(sFriends, id);
			if (nickname != null && nickname[0] != 0)
			{
				name.Append(nickname);
				return;
			}
		}
		if (id == UserId)
		{
			name.Append(UserName);
			return;
		}
		if (sRequestUserInformation != null)
			sRequestUserInformation(sFriends, id, true);
		FriendName(id, name);
	}

	/// Whether a Steam ID belongs to one of the signed-in user's friends. False without Steam.
	public static bool IsFriend(uint64 id) => sReady && sFriends != null && sHasFriend != null && sHasFriend(sFriends, id, FriendFlagImmediate);

	/// Whether a friend is signed in to Steam at the moment (online, away, busy and so on: anything but offline).
	public static bool FriendOnline(uint64 id) => sReady && sFriends != null && sGetFriendPersonaState != null && sGetFriendPersonaState(sFriends, id) != 0;

	/// App ID of the game a friend is playing, or 0 when unavailable. Uses Steam's game state, not rich presence.
	public static uint32 FriendAppId(uint64 id)
	{
		if (!sReady || sFriends == null || sGetFriendGamePlayed == null) return 0;
		FriendGameInfo game = default;
		return sGetFriendGamePlayed(sFriends, id, &game) ? (uint32)(game.gameId & 0xFFFFFF) : 0;
	}

	/// Publishes a named piece of text about what this player is doing; friends running the same game can read it
	/// with FriendPresence. An empty value removes the key. Steam itself shows the "status" key in the friends list,
	/// and offers friends a Join button when "connect" is set.
	public static bool SetPresence(StringView key, StringView value) => sReady && sFriends != null && sSetRichPresence != null && sSetRichPresence(sFriends, scope String(key).CStr(), scope String(value).CStr());

	/// Removes everything SetPresence published.
	public static void ClearPresence()
	{
		if (sReady && sFriends != null && sClearRichPresence != null)
			sClearRichPresence(sFriends);
	}

	/// What a friend published under a key with SetPresence. Empty when they are not in this game or never set it.
	public static void FriendPresence(uint64 id, StringView key, String value)
	{
		if (!sReady || sFriends == null || sGetFriendRichPresence == null)
			return;
		let text = sGetFriendRichPresence(sFriends, id, scope String(key).CStr());
		if (text != null)
			value.Append(text);
	}

	/// Sends a friend a Steam invitation to join. connect is handed to their game when they accept (see
	/// TakeJoinRequest); the usual choice is the host's Steam ID.
	public static bool Invite(uint64 friend, StringView connect) => sReady && sFriends != null && sInviteUserToGame != null && sInviteUserToGame(sFriends, friend, scope String(connect).CStr());

	static String sJoinRequest = new .() ~ delete _;
	static bool sJoinPending;

	/// True once after the player accepted a friend's invitation (or pressed Join in the Steam friends list) while
	/// the game was running; connect is the text the inviting game gave. Call it every frame or so.
	public static bool TakeJoinRequest(String connect)
	{
		if (!sJoinPending)
			return false;
		sJoinPending = false;
		connect.Set(sJoinRequest);
		return true;
	}

	// Steam delivers events to C++ objects with three virtual methods. This is one, laid out by hand: a pointer to
	// the method table, then the two fields Steam keeps in it. Microsoft's compiler orders the two Run methods the
	// other way round from everybody else's.
	[CRepr]
	struct CallbackObject
	{
		public void** methods;
		public uint8 flags;
		public int32 callbackId;
	}

	static void*[3] sJoinMethods;
	static CallbackObject sJoinCallback;
	const int32 JoinRequested = 337; // GameRichPresenceJoinRequested_t: the friend's ID (8 bytes), then the text.

	static void OnJoinRequested(void* self, void* data)
	{
		sJoinRequest.Set(StringView((char8*)data + 8));
		sJoinPending = true;
	}

	static void OnJoinResult(void* self, void* data, bool failed, uint64 call) { }
	static int32 JoinRequestSize(void* self) => 264;

	static void ListenForJoinRequests()
	{
		if (sRegisterCallback == null || sJoinCallback.methods != null)
			return;
		function void(void*, void*) run = => OnJoinRequested;
		function void(void*, void*, bool, uint64) result = => OnJoinResult;
		function int32(void*) size = => JoinRequestSize;
#if BF_PLATFORM_WINDOWS
		sJoinMethods = .((void*)result, (void*)run, (void*)size);
#else
		sJoinMethods = .((void*)run, (void*)result, (void*)size);
#endif
		sJoinCallback.methods = (void**)&sJoinMethods;
		sRegisterCallback(&sJoinCallback, JoinRequested);
	}

	public static uint64 UserId => sReady && sUser != null && sGetSteamID != null ? sGetSteamID(sUser) : 0;
	public static StringView UserName => sUserName;

#if BF_PLATFORM_WINDOWS
	[CLink, CallingConvention(.Stdcall)] static extern int32 SetEnvironmentVariableA(char8* name, char8* value);
#else
	[CLink] static extern int32 setenv(char8* name, char8* value, int32 overwrite);
#endif

#if !BF_PLATFORM_WINDOWS
	// The system loader is used directly: it reports a missing file by returning null.
	[CLink] static extern void* dlopen(char8* path, int32 flags);
	[CLink] static extern void* dlsym(void* library, char8* name);
	static void* OpenLibrary(char8* path) => dlopen(path, 2 /* RTLD_NOW */);
	public static void* Symbol(StringView name) => sLibrary != null ? dlsym(sLibrary, scope String(name).CStr()) : null;
#else
	// Windows' own calls rather than Beef's, which stop the program when a function is not in the library; older
	// Steam libraries lack some, and that is allowed for.
	[CLink, CallingConvention(.Stdcall)] static extern void* LoadLibraryA(char8* path);
	[CLink, CallingConvention(.Stdcall)] static extern void* GetProcAddress(void* library, char8* name);
	static void* OpenLibrary(char8* path) => LoadLibraryA(path);
	public static void* Symbol(StringView name) => sLibrary != null ? GetProcAddress(sLibrary, scope String(name).CStr()) : null;
#endif

	/// Interface accessors carry a version in their name that changes between SDK releases: take whichever exists.
	public static void* Interface(StringView prefix)
	{
		for (int version = 40; version >= 1; version--)
		{
			let address = Symbol(scope $"{prefix}{version:000}");
			if (address != null)
			{
				function void*() accessor = (.)address;
				return accessor();
			}
		}
		return null;
	}

	/// Opens the first Steam client library found: where TALLOW_STEAM_LIB says, beside the program, in the project
	/// (or its Libraries folder), or in the Steam runtime. Null if there is none.
	static void* FindLibrary(StringView fileName)
	{
		List<String> candidates = scope .();
		defer
		{
			for (let c in candidates)
				delete c;
		}
		let fromEnvironment = scope String();
		if (Environment.GetEnvironmentVariable("TALLOW_STEAM_LIB", fromEnvironment) case .Ok && !fromEnvironment.IsEmpty)
			candidates.Add(new String(fromEnvironment));
		let basePath = SDL.SDL_GetBasePath();
		if (basePath != null)
			candidates.Add(new $"{StringView(basePath)}{fileName}");
		if (!Assets.ProjectPath.IsEmpty)
		{
			candidates.Add(new $"{Assets.ProjectPath}/{fileName}");
			candidates.Add(new $"{Assets.ProjectPath}/../{fileName}");
			// Editor assets live in <project>/src; game packaging also accepts <project>/Libraries.
			candidates.Add(new $"{Assets.ProjectPath}/Libraries/{fileName}");
			candidates.Add(new $"{Assets.ProjectPath}/../Libraries/{fileName}");
		}
		let home = scope String();
		if (Environment.GetEnvironmentVariable("HOME", home) case .Ok && !home.IsEmpty)
			candidates.Add(new $"{home}/.local/share/Steam/steamrt64/{fileName}");
		for (let candidate in candidates)
		{
			if (!File.Exists(candidate))
				continue;
			let library = OpenLibrary(candidate.CStr());
			if (library != null)
				return library;
		}
		return null;
	}

	/// Looks up every Steam function the engine calls (those the library lacks stay null).
	static void BindFunctions()
	{
		sInitFlat = (.)Symbol("SteamAPI_InitFlat");
		sInitPlain = (.)Symbol("SteamAPI_Init");
		sGetFriendCount = (.)Symbol("SteamAPI_ISteamFriends_GetFriendCount");
		sGetFriendByIndex = (.)Symbol("SteamAPI_ISteamFriends_GetFriendByIndex");
		sGetFriendPersonaName = (.)Symbol("SteamAPI_ISteamFriends_GetFriendPersonaName");
		sGetPlayerNickname = (.)Symbol("SteamAPI_ISteamFriends_GetPlayerNickname");
		sRequestUserInformation = (.)Symbol("SteamAPI_ISteamFriends_RequestUserInformation");
		sGetFriendPersonaState = (.)Symbol("SteamAPI_ISteamFriends_GetFriendPersonaState");
		sGetFriendGamePlayed = (.)Symbol("SteamAPI_ISteamFriends_GetFriendGamePlayed");
		sSetRichPresence = (.)Symbol("SteamAPI_ISteamFriends_SetRichPresence");
		sClearRichPresence = (.)Symbol("SteamAPI_ISteamFriends_ClearRichPresence");
		sGetFriendRichPresence = (.)Symbol("SteamAPI_ISteamFriends_GetFriendRichPresence");
		sInviteUserToGame = (.)Symbol("SteamAPI_ISteamFriends_InviteUserToGame");
		sHasFriend = (.)Symbol("SteamAPI_ISteamFriends_HasFriend");
		sRegisterCallback = (.)Symbol("SteamAPI_RegisterCallback");
		sShutdown = (.)Symbol("SteamAPI_Shutdown");
		sRunCallbacks = (.)Symbol("SteamAPI_RunCallbacks");
		sIsSteamRunning = (.)Symbol("SteamAPI_IsSteamRunning");
		sGetSteamID = (.)Symbol("SteamAPI_ISteamUser_GetSteamID");
		sGetPersonaName = (.)Symbol("SteamAPI_ISteamFriends_GetPersonaName");
		sInitRelay = (.)Symbol("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess");
		sSetGlobalInt = (.)Symbol("SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32");
		sSocketsRunCallbacks = (.)Symbol("SteamAPI_ISteamNetworkingSockets_RunCallbacks");
		SetConnectionStatusCallback = (.)Symbol("SteamAPI_ISteamNetworkingUtils_SetGlobalCallback_SteamNetConnectionStatusChanged");
		CreateListenSocketP2P = (.)Symbol("SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P");
		ConnectP2P = (.)Symbol("SteamAPI_ISteamNetworkingSockets_ConnectP2P");
		AcceptConnection = (.)Symbol("SteamAPI_ISteamNetworkingSockets_AcceptConnection");
		CloseConnection = (.)Symbol("SteamAPI_ISteamNetworkingSockets_CloseConnection");
		CloseListenSocket = (.)Symbol("SteamAPI_ISteamNetworkingSockets_CloseListenSocket");
		SendMessageToConnection = (.)Symbol("SteamAPI_ISteamNetworkingSockets_SendMessageToConnection");
		FlushMessagesOnConnection = (.)Symbol("SteamAPI_ISteamNetworkingSockets_FlushMessagesOnConnection");
		CreatePollGroup = (.)Symbol("SteamAPI_ISteamNetworkingSockets_CreatePollGroup");
		DestroyPollGroup = (.)Symbol("SteamAPI_ISteamNetworkingSockets_DestroyPollGroup");
		SetConnectionPollGroup = (.)Symbol("SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup");
		ReceiveMessagesOnPollGroup = (.)Symbol("SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnPollGroup");
		GetConnectionRealTimeStatus = (.)Symbol("SteamAPI_ISteamNetworkingSockets_GetConnectionRealTimeStatus");
		ReleaseMessage = (.)Symbol("SteamAPI_SteamNetworkingMessage_t_Release");
		IdentityClear = (.)Symbol("SteamAPI_SteamNetworkingIdentity_Clear");
		IdentitySetSteamID64 = (.)Symbol("SteamAPI_SteamNetworkingIdentity_SetSteamID64");
		sSetAchievement = (.)Symbol("SteamAPI_ISteamUserStats_SetAchievement");
		sGetAchievement = (.)Symbol("SteamAPI_ISteamUserStats_GetAchievement");
		sClearAchievement = (.)Symbol("SteamAPI_ISteamUserStats_ClearAchievement");
		sStoreStats = (.)Symbol("SteamAPI_ISteamUserStats_StoreStats");
		sIndicateProgress = (.)Symbol("SteamAPI_ISteamUserStats_IndicateAchievementProgress");
		sGetNumAchievements = (.)Symbol("SteamAPI_ISteamUserStats_GetNumAchievements");
		sGetAchievementName = (.)Symbol("SteamAPI_ISteamUserStats_GetAchievementName");
		sGetAchievementAttribute = (.)Symbol("SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute");
		sSetStatInt = (.)Symbol("SteamAPI_ISteamUserStats_SetStatInt32");
		sGetStatInt = (.)Symbol("SteamAPI_ISteamUserStats_GetStatInt32");
		sResetAllStats = (.)Symbol("SteamAPI_ISteamUserStats_ResetAllStats");
	}

	static bool Load()
	{
		if (sTried)
			return sLibrary != null;
		sTried = true;
#if BF_PLATFORM_WASM
		// A web page cannot load the Steam client library: the game runs as if Steam were not there.
		if (sTried)
			return false;
		let fileName = "";
		#elif BF_PLATFORM_WINDOWS
		let fileName = "steam_api64.dll";
		#elif BF_PLATFORM_MACOS
		let fileName = "libsteam_api.dylib";
		#else
		let fileName = "libsteam_api.so";
#endif
		sLibrary = FindLibrary(fileName);
		if (sLibrary == null)
		{
			sError.Set(scope $"{fileName} was not found. Put the file from the Steamworks SDK in the project Libraries folder or beside the executable.");
			return false;
		}
		BindFunctions();
		if ((sInitFlat == null && sInitPlain == null) || sRunCallbacks == null)
		{
			sError.Set("The Steam library is too old: it has no flat API. Use the one from a current Steamworks SDK.");
			sLibrary = null;
			return false;
		}
		return true;
	}

	/// True if every function the Steam transport needs was found in the library.
	public static bool HasNetworking => sSockets != null && sUtils != null && SetConnectionStatusCallback != null && CreateListenSocketP2P != null
		&& ConnectP2P != null && AcceptConnection != null && CloseConnection != null && SendMessageToConnection != null && CreatePollGroup != null
		&& SetConnectionPollGroup != null && ReceiveMessagesOnPollGroup != null && GetConnectionRealTimeStatus != null && ReleaseMessage != null
		&& IdentityClear != null && IdentitySetSteamID64 != null;

	/// Connects to the running Steam client. Safe to call more than once. Returns false, with Error set, if the
	/// library is missing, Steam is not running or the user does not own the app.
	public static bool Init(uint32 appId)
	{
		if (sReady)
			return true;
		if (!Load())
			return false;
		// A game that was not started from Steam tells it which app it is this way (the same job as steam_appid.txt).
		if (appId != 0)
		{
			let id = scope $"{appId}";
#if BF_PLATFORM_WINDOWS
			SetEnvironmentVariableA("SteamAppId", id.CStr());
			SetEnvironmentVariableA("SteamGameId", id.CStr());
#else
			setenv("SteamAppId", id.CStr(), 1);
			setenv("SteamGameId", id.CStr(), 1);
#endif
		}
		char8[1024] message = default;
		int32 result = 0;
		if (sInitFlat != null)
			result = sInitFlat(&message);
		else if (!sInitPlain())
			result = (sIsSteamRunning != null && !sIsSteamRunning()) ? 2 : 1;
		if (result != 0)
		{
			sError.Set(StringView(&message));
			if (sError.IsEmpty)
				sError.Set(result == 2 ? "Steam is not running." : "Steam could not be initialised.");
			return false;
		}
		sUser = Interface("SteamAPI_SteamUser_v");
		sFriends = Interface("SteamAPI_SteamFriends_v");
		sSockets = Interface("SteamAPI_SteamNetworkingSockets_SteamAPI_v");
		sUtils = Interface("SteamAPI_SteamNetworkingUtils_SteamAPI_v");
		sStats = Interface("SteamAPI_SteamUserStats_v");
		sUserName.Clear();
		if (sFriends != null && sGetPersonaName != null)
		{
			let name = sGetPersonaName(sFriends);
			if (name != null)
				sUserName.Append(name);
		}
		// Finds relay servers ahead of time so the first connection does not wait for it.
		if (sUtils != null && sInitRelay != null)
			sInitRelay(sUtils);
		// Steam holds each connection to 256 KB a second unless told otherwise; a physics-heavy game can go past that
		// for a moment, and everything sent after it then waits in Steam's queue. Allow up to SendRate.
		if (sUtils != null && sSetGlobalInt != null)
		{
			const int32 SendRateMin = 10;
			const int32 SendRateMax = 11;
			sSetGlobalInt(sUtils, SendRateMin, SendRate);
			sSetGlobalInt(sUtils, SendRateMax, SendRate);
		}
		sReady = true;
		ListenForJoinRequests();
		sError.Clear();
		Log.Info(scope $"Steam ready: {sUserName} ({UserId}).");
		return true;
	}

	/// Lets Steam deliver its events. The Steam transport calls this every tick; call it once a frame yourself if
	/// you use Steam without the transport.
	public static void Update()
	{
		if (!sReady)
			return;
		let was = Watchdog.Stage;
		Watchdog.Stage = "running Steam callbacks";
		sRunCallbacks();
		// Connection status changes are delivered by the sockets interface itself.
		if (sSockets != null && sSocketsRunCallbacks != null)
		{
			Watchdog.Stage = "running Steam networking callbacks";
			sSocketsRunCallbacks(sSockets);
		}
		Watchdog.Stage = "checking Steam Workshop";
		Workshop.Update();
		Watchdog.Stage = was;
	}

	public static void Shutdown()
	{
		Workshop.Reset();
		if (sReady)
			ClearPresence();
		if (sReady && sShutdown != null)
			sShutdown();
		sReady = false;
	}
}

/// Carries a network session over Steam's networking sockets. The host listens for peer-to-peer connections on
/// its own Steam ID; clients connect to that ID, given as the address. Traffic goes through Steam's relays.
class SteamTransport : NetTransport
{
	// Connection states reported by Steam.
	const int32 StateConnecting = 1;
	const int32 StateConnected = 3;
	const int32 StateClosedByPeer = 4;
	const int32 StateProblem = 5;
	const int32 SendUnreliable = 0;
	const int32 SendReliable = 8;

	static List<SteamTransport> sLive = new .() ~ delete _;
	/// Print every connection state change, for diagnosing connection problems.
	public static bool Trace;

	uint32 mListen;
	uint32 mPollGroup;
	uint32 mServer;
	bool mOpen;
	List<uint32> mConnections = new .() ~ delete _;
	// Connections already reported as connected; Steam reports the state more than once on the way there.
	List<uint32> mEstablished = new .() ~ delete _;
	List<NetEvent> mQueued = new .() ~ delete _;
	void* mHeld;
	/// Set by the Network Session before it starts; 0 uses the project's App ID, or Valve's test app 480.
	public static uint32 AppId;

	public ~this()
	{
		Close();
	}

	bool Open()
	{
		if (mOpen)
			return true;
		if (!Steam.Init(AppId != 0 ? AppId : (Steam.AppId != 0 ? Steam.AppId : 480)))
		{
			Log.Error(scope $"Steam transport: {Steam.Error}");
			return false;
		}
		if (!Steam.HasNetworking)
		{
			Log.Error("Steam transport: this Steam library has no networking sockets. Use the one from a current Steamworks SDK.");
			return false;
		}
		Steam.SetConnectionStatusCallback(Steam.Utils, => OnStatusChanged);
		mPollGroup = Steam.CreatePollGroup(Steam.Sockets);
		sLive.Add(this);
		mOpen = true;
		return true;
	}

	public override bool Host(uint16 port)
	{
		Close();
		if (!Open())
			return false;
		// The "port" is a virtual one on this user's Steam ID; 0 is the usual choice.
		mListen = Steam.CreateListenSocketP2P(Steam.Sockets, 0, 0, null);
		if (mListen == 0)
		{
			Log.Error("Steam transport: could not open a listen socket.");
			Close();
			return false;
		}
		Log.Info(scope $"Hosting on Steam as {Steam.UserName}. Others join with --connect {Steam.UserId}");
		return true;
	}

	public override bool Connect(StringView address, uint16 port, out void* server)
	{
		server = null;
		Close();
		if (!Open())
			return false;
		uint64 hostId = 0;
		if (uint64.Parse(address) case .Ok(let parsed))
			hostId = parsed;
		if (hostId == 0)
		{
			Log.Error(scope $"Steam transport: '{address}' is not a Steam ID. Use the number the host printed when it started.");
			Close();
			return false;
		}
		// SteamNetworkingIdentity is 136 bytes; the library fills it in.
		uint8[160] identity = default;
		Steam.IdentityClear(&identity);
		Steam.IdentitySetSteamID64(&identity, hostId);
		mServer = Steam.ConnectP2P(Steam.Sockets, &identity, 0, 0, null);
		if (mServer == 0)
		{
			Close();
			return false;
		}
		Steam.SetConnectionPollGroup(Steam.Sockets, mServer, mPollGroup);
		mConnections.Add(mServer);
		server = (void*)(int)mServer;
		return true;
	}

	static int32 StateOf(uint32 connection)
	{
		// SteamNetConnectionRealTimeStatus_t starts with the connection state; the rest is not needed here.
		uint8[512] status = default;
		if (Steam.GetConnectionRealTimeStatus(Steam.Sockets, connection, &status, 0, null) != 1)
			return StateProblem;
		return *(int32*)&status;
	}

	/// Steam calls this, from inside Steam.Update, whenever a connection changes state.
	static void OnStatusChanged(void* info)
	{
		// SteamNetConnectionStatusChangedCallback_t starts with the connection handle.
		let connection = *(uint32*)info;
		let state = StateOf(connection);
		if (Trace)
			Log.Info(scope $"Steam connection {connection} is now in state {state}.");
		for (let transport in sLive)
			transport.Changed(connection, state);
	}

	void Changed(uint32 connection, int32 state)
	{
		let known = mConnections.Contains(connection);
		NetEvent event = default;
		event.peer = (void*)(int)connection;
		switch (state)
		{
		case StateConnecting:
			// Someone is knocking on the listen socket.
			if (mListen != 0 && !known && connection != mServer)
			{
				if (Steam.AcceptConnection(Steam.Sockets, connection) == 1)
				{
					Steam.SetConnectionPollGroup(Steam.Sockets, connection, mPollGroup);
					mConnections.Add(connection);
				}
				else
					Steam.CloseConnection(Steam.Sockets, connection, 0, null, false);
			}
		case StateConnected:
			if (known && !mEstablished.Contains(connection))
			{
				mEstablished.Add(connection);
				event.kind = .Connected;
				mQueued.Add(event);
			}
		case StateClosedByPeer,StateProblem:
			if (known)
			{
				mConnections.Remove(connection);
				mEstablished.Remove(connection);
				Steam.CloseConnection(Steam.Sockets, connection, 0, null, false);
				event.kind = .Disconnected;
				mQueued.Add(event);
			}
		default:
		}
	}

	void Release()
	{
		if (mHeld != null)
			Steam.ReleaseMessage(mHeld);
		mHeld = null;
	}

	public override bool Poll(out NetEvent event)
	{
		event = default;
		Release();
		if (!mOpen)
			return false;
		if (mQueued.IsEmpty)
			Steam.Update();
		if (!mQueued.IsEmpty)
		{
			event = mQueued[0];
			mQueued.RemoveAt(0);
			return true;
		}
		void* message = null;
		if (Steam.ReceiveMessagesOnPollGroup(Steam.Sockets, mPollGroup, &message, 1) != 1 || message == null)
			return false;
		// SteamNetworkingMessage_t begins: void* data, int32 size, uint32 connection.
		event.kind = .Data;
		event.data = *(uint8**)message;
		event.length = *(int32*)((uint8*)message + sizeof(void*));
		let from = *(uint32*)((uint8*)message + sizeof(void*) + 4);
		event.peer = (void*)(int)from;
		mHeld = message;
		return true;
	}

	public override void Send(void* peer, Span<uint8> data, bool reliable)
	{
		if (mOpen && peer != null)
			Steam.SendMessageToConnection(Steam.Sockets, (uint32)(int)peer, data.Ptr, (uint32)data.Length, reliable ? SendReliable : SendUnreliable, null);
	}

	public override void Disconnect(void* peer)
	{
		let connection = (uint32)(int)peer;
		mEstablished.Remove(connection);
		if (mOpen && mConnections.Remove(connection))
			Steam.CloseConnection(Steam.Sockets, connection, 0, null, true);
	}

	public override void Flush()
	{
		if (!mOpen || Steam.FlushMessagesOnConnection == null)
			return;
		for (let connection in mConnections)
			Steam.FlushMessagesOnConnection(Steam.Sockets, connection);
	}

	public override void Close()
	{
		Release();
		if (!mOpen)
			return;
		for (let connection in mConnections)
			Steam.CloseConnection(Steam.Sockets, connection, 0, null, true);
		mConnections.Clear();
		mEstablished.Clear();
		if (mListen != 0)
			Steam.CloseListenSocket(Steam.Sockets, mListen);
		if (mPollGroup != 0 && Steam.DestroyPollGroup != null)
			Steam.DestroyPollGroup(Steam.Sockets, mPollGroup);
		mListen = 0;
		mPollGroup = 0;
		mServer = 0;
		mQueued.Clear();
		sLive.Remove(this);
		mOpen = false;
	}
}
