using System;
using System.Collections;

namespace Tallow;

/// A Steam Workshop item: something a player made and shared.
class WorkshopItem
{
	public uint64 id;
	public String title = new .() ~ delete _;
	public String description = new .() ~ delete _;
	/// Comma-separated.
	public String tags = new .() ~ delete _;
	public String previewUrl = new .() ~ delete _;
	/// Steam ID of whoever published it.
	public uint64 owner;
}

enum WorkshopSort
{
	/// Highest rated of all time.
	Popular,
	Newest,
	/// Rising lately.
	Trending,
	/// Best match for the search text.
	Search
}

enum WorkshopVisibility : int32
{
	Public,
	FriendsOnly,
	Private,
	Unlisted
}

/// Player-made content through the Steam Workshop.
///
/// Using what players subscribed to:
///
///   Workshop.MountInstalled();                         // every installed item's files become loadable assets
///
/// Browsing and subscribing:
///
///   Workshop.Browse(.Popular, 1, "", new (items, ok) => { for (let item in items) Log.Info(item.title); });
///   Workshop.Subscribe(item.id);
///
/// Publishing a folder:
///
///   Workshop.Publish(folder, "My level", "A short description", previewPng, "level,hard", .Public, 0,
///       new (id, ok, message) => Log.Info(ok ? scope $"Published as {id}" : message));
///
/// Everything here needs the game to be running under Steam with an App ID that has the Workshop enabled; without
/// that, Available is false and the calls do nothing (callbacks are told it failed). An item is a folder of files;
/// scenes, prefabs, models, textures and behaviour trees work as content. Scripts do not: code cannot be loaded
/// into a built game.
static class Workshop
{
	public delegate void BrowseDone(List<WorkshopItem> items, bool ok);
	public delegate void PublishDone(uint64 id, bool ok, StringView message);

	static void* sUgc, sUtils;
	static bool sBound;

	static function uint64(void* ugc, uint32 appId, int32 fileType) sCreateItem;
	static function uint64(void* ugc, uint32 appId, uint64 id) sStartItemUpdate;
	static function bool(void* ugc, uint64 update, char8* text) sSetItemTitle, sSetItemDescription, sSetItemContent, sSetItemPreview;
	static function bool(void* ugc, uint64 update, int32 visibility) sSetItemVisibility;
	static function bool(void* ugc, uint64 update, void* tags, bool allowAdminTags) sSetItemTags;
	static function uint64(void* ugc, uint64 update, char8* note) sSubmitItemUpdate;
	static function int32(void* ugc, uint64 update, uint64* processed, uint64* total) sGetItemUpdateProgress;
	static function uint64(void* ugc, uint64 id) sSubscribeItem, sUnsubscribeItem;
	static function uint32(void* ugc, bool includeDisabled) sGetNumSubscribedItems;
	static function uint32(void* ugc, uint64* ids, uint32 max, bool includeDisabled) sGetSubscribedItems;
	static function uint32(void* ugc, uint64 id) sGetItemState;
	static function bool(void* ugc, uint64 id, uint64* size, char8* folder, uint32 folderSize, uint32* timestamp) sGetItemInstallInfo;
	static function bool(void* ugc, uint64 id, bool highPriority) sDownloadItem;
	static function uint64(void* ugc, int32 queryType, int32 matchingType, uint32 creatorApp, uint32 consumerApp, uint32 page) sCreateQueryAll;
	static function uint64(void* ugc, uint32 accountId, int32 listType, int32 matchingType, int32 sortOrder, uint32 creatorApp, uint32 consumerApp, uint32 page) sCreateQueryUser;
	static function bool(void* ugc, uint64 query, char8* text) sSetSearchText;
	static function bool(void* ugc, uint64 query, bool value) sSetReturnLongDescription;
	static function uint64(void* ugc, uint64 query) sSendQuery;
	static function bool(void* ugc, uint64 query, uint32 index, void* details) sGetQueryResult;
	static function bool(void* ugc, uint64 query, uint32 index, char8* url, uint32 size) sGetQueryPreviewUrl;
	static function bool(void* ugc, uint64 query) sReleaseQuery;
	static function bool(void* utils, uint64 call, bool* failed) sIsCallCompleted;
	static function bool(void* utils, uint64 call, void* result, int32 size, int32 expectedId, bool* failed) sGetCallResult;

	// Item state flags from Steam.
	const uint32 ItemSubscribed = 1, ItemInstalled = 4, ItemNeedsUpdate = 8, ItemDownloading = 16;
	// Result structures Steam fills in, by callback id and size.
	const int32 QueryCompletedId = 3401, CreateItemId = 3403, SubmitUpdateId = 3404;

	enum Step { Query, Create, Submit }
	class Pending
	{
		public Step step;
		public uint64 call;
		public uint64 handle;
		public BrowseDone browseDone ~ delete _;
		public PublishDone publishDone ~ delete _;
		// What to publish once the item exists.
		public String folder = new .() ~ delete _;
		public String title = new .() ~ delete _;
		public String description = new .() ~ delete _;
		public String preview = new .() ~ delete _;
		public String tags = new .() ~ delete _;
		public String note = new .() ~ delete _;
		public WorkshopVisibility visibility;
		public uint64 itemId;
	}

	static List<Pending> sPending = new .() ~ DeleteContainerAndItems!(_);
	static uint64 sUpdateHandle;
	static List<String> sMounted = new .() ~ DeleteContainerAndItems!(_);

	static bool Bind()
	{
		if (!Steam.Start())
			return false;
		if (sBound)
			return sUgc != null;
		sBound = true;
		sUgc = Steam.Interface("SteamAPI_SteamUGC_v");
		sUtils = Steam.Interface("SteamAPI_SteamUtils_v");
		sCreateItem = (.)Steam.Symbol("SteamAPI_ISteamUGC_CreateItem");
		sStartItemUpdate = (.)Steam.Symbol("SteamAPI_ISteamUGC_StartItemUpdate");
		sSetItemTitle = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetItemTitle");
		sSetItemDescription = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetItemDescription");
		sSetItemContent = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetItemContent");
		sSetItemPreview = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetItemPreview");
		sSetItemVisibility = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetItemVisibility");
		sSetItemTags = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetItemTags");
		sSubmitItemUpdate = (.)Steam.Symbol("SteamAPI_ISteamUGC_SubmitItemUpdate");
		sGetItemUpdateProgress = (.)Steam.Symbol("SteamAPI_ISteamUGC_GetItemUpdateProgress");
		sSubscribeItem = (.)Steam.Symbol("SteamAPI_ISteamUGC_SubscribeItem");
		sUnsubscribeItem = (.)Steam.Symbol("SteamAPI_ISteamUGC_UnsubscribeItem");
		sGetNumSubscribedItems = (.)Steam.Symbol("SteamAPI_ISteamUGC_GetNumSubscribedItems");
		sGetSubscribedItems = (.)Steam.Symbol("SteamAPI_ISteamUGC_GetSubscribedItems");
		sGetItemState = (.)Steam.Symbol("SteamAPI_ISteamUGC_GetItemState");
		sGetItemInstallInfo = (.)Steam.Symbol("SteamAPI_ISteamUGC_GetItemInstallInfo");
		sDownloadItem = (.)Steam.Symbol("SteamAPI_ISteamUGC_DownloadItem");
		sCreateQueryAll = (.)Steam.Symbol("SteamAPI_ISteamUGC_CreateQueryAllUGCRequestPage");
		sCreateQueryUser = (.)Steam.Symbol("SteamAPI_ISteamUGC_CreateQueryUserUGCRequest");
		sSetSearchText = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetSearchText");
		sSetReturnLongDescription = (.)Steam.Symbol("SteamAPI_ISteamUGC_SetReturnLongDescription");
		sSendQuery = (.)Steam.Symbol("SteamAPI_ISteamUGC_SendQueryUGCRequest");
		sGetQueryResult = (.)Steam.Symbol("SteamAPI_ISteamUGC_GetQueryUGCResult");
		sGetQueryPreviewUrl = (.)Steam.Symbol("SteamAPI_ISteamUGC_GetQueryUGCPreviewURL");
		sReleaseQuery = (.)Steam.Symbol("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest");
		sIsCallCompleted = (.)Steam.Symbol("SteamAPI_ISteamUtils_IsAPICallCompleted");
		sGetCallResult = (.)Steam.Symbol("SteamAPI_ISteamUtils_GetAPICallResult");
		if (sUtils == null || sIsCallCompleted == null || sGetCallResult == null || sGetSubscribedItems == null || sGetItemInstallInfo == null)
			sUgc = null;
		return sUgc != null;
	}

	/// True when the game is running under Steam and the Workshop can be used.
	public static bool Available => Bind();

	static uint32 AppId => Steam.AppId != 0 ? Steam.AppId : 480;

	// ---- what the player has ----

	/// Ids of the items the player is subscribed to.
	public static void GetSubscribed(List<uint64> ids)
	{
		ids.Clear();
		if (!Bind() || sGetNumSubscribedItems == null)
			return;
		let count = sGetNumSubscribedItems(sUgc, false);
		if (count == 0)
			return;
		uint64[] buffer = scope .[count];
		let filled = sGetSubscribedItems(sUgc, &buffer[0], count, false);
		for (uint32 i < Math.Min(filled, count))
			ids.Add(buffer[(int)i]);
	}

	public static bool IsSubscribed(uint64 id) => Bind() && sGetItemState != null && (sGetItemState(sUgc, id) & ItemSubscribed) != 0;
	/// Downloaded and ready to use.
	public static bool IsInstalled(uint64 id) => Bind() && sGetItemState != null && (sGetItemState(sUgc, id) & ItemInstalled) != 0;
	public static bool IsDownloading(uint64 id) => Bind() && sGetItemState != null && (sGetItemState(sUgc, id) & ItemDownloading) != 0;
	public static bool NeedsUpdate(uint64 id) => Bind() && sGetItemState != null && (sGetItemState(sUgc, id) & ItemNeedsUpdate) != 0;

	/// Where an installed item's files are on disk. False if it is not installed.
	public static bool GetFolder(uint64 id, String folder)
	{
		if (!Bind())
			return false;
		char8[1024] path = default;
		uint64 size = 0;
		uint32 timestamp = 0;
		if (!sGetItemInstallInfo(sUgc, id, &size, &path, 1024, &timestamp))
			return false;
		folder.Append(StringView(&path));
		return !folder.IsEmpty;
	}

	/// Steam downloads subscribed items by itself; this asks for one now, ahead of the rest.
	public static bool Download(uint64 id) => Bind() && sDownloadItem != null && sDownloadItem(sUgc, id, true);

	public static void Subscribe(uint64 id)
	{
		if (Bind() && sSubscribeItem != null)
			sSubscribeItem(sUgc, id);
	}

	public static void Unsubscribe(uint64 id)
	{
		if (Bind() && sUnsubscribeItem != null)
			sUnsubscribeItem(sUgc, id);
	}

	/// Folders of every subscribed item that is installed.
	public static void GetInstalledFolders(List<String> folders)
	{
		List<uint64> ids = scope .();
		GetSubscribed(ids);
		for (let id in ids)
		{
			if (!IsInstalled(id))
				continue;
			let folder = new String();
			if (GetFolder(id, folder))
				folders.Add(folder);
			else
				delete folder;
		}
	}

	/// Makes the files of every installed item loadable as assets, by their path inside the item. An item that
	/// contains Scenes/Arena.tscene can then be opened as "Scenes/Arena.tscene", and a file with the same path as
	/// one of the game's replaces it. Call it at start-up, and again after the player subscribes to something.
	/// Returns how many items are mounted.
	public static int MountInstalled()
	{
		for (let folder in sMounted)
			Assets.RemoveSearchPath(folder);
		ClearAndDeleteItems!(sMounted);
		GetInstalledFolders(sMounted);
		for (let folder in sMounted)
			Assets.AddSearchPath(folder);
		return sMounted.Count;
	}

	/// Folders mounted by the last MountInstalled, for games that want to list what each item contains.
	public static List<String> Mounted => sMounted;

	// ---- browsing ----

	static uint32 ReadU32(uint8* p) => *(uint32*)p;
	static uint64 ReadU64(uint8* p) => *(uint64*)p;

	/// Asks Steam for a page of Workshop items (50 to a page, pages start at 1). `done` is called a moment later,
	/// from the main loop, with the items; they are deleted after it returns.
	public static void Browse(WorkshopSort sort, int32 page, StringView searchText, BrowseDone done)
	{
		if (!Bind() || sCreateQueryAll == null || sSendQuery == null || sGetQueryResult == null)
		{
			done(scope .(), false);
			delete done;
			return;
		}
		int32 queryType;
		switch (sort)
		{
		case .Popular: queryType = 0;
		case .Newest: queryType = 1;
		case .Trending: queryType = 3;
		case .Search: queryType = 12;
		}
		if (!searchText.IsEmpty)
			queryType = 12;
		let query = sCreateQueryAll(sUgc, queryType, 0, AppId, AppId, (uint32)Math.Max(page, 1));
		Send(query, searchText, done);
	}

	/// The items the signed-in player has published for this game.
	public static void BrowseMine(int32 page, BrowseDone done)
	{
		if (!Bind() || sCreateQueryUser == null || sSendQuery == null || sGetQueryResult == null)
		{
			done(scope .(), false);
			delete done;
			return;
		}
		// The account id is the low half of the Steam ID.
		let query = sCreateQueryUser(sUgc, (uint32)(Steam.UserId & 0xFFFFFFFF), 0, 0, 0, AppId, AppId, (uint32)Math.Max(page, 1));
		Send(query, "", done);
	}

	static void Send(uint64 query, StringView searchText, BrowseDone done)
	{
		if (!searchText.IsEmpty && sSetSearchText != null)
			sSetSearchText(sUgc, query, scope String(searchText).CStr());
		if (sSetReturnLongDescription != null)
			sSetReturnLongDescription(sUgc, query, true);
		let pending = new Pending();
		pending.step = .Query;
		pending.handle = query;
		pending.call = sSendQuery(sUgc, query);
		pending.browseDone = done;
		sPending.Add(pending);
	}

	static void FinishQuery(Pending pending, bool failed)
	{
		List<WorkshopItem> items = scope .();
		defer
		{
			for (let item in items)
				delete item;
		}
		// SteamUGCQueryCompleted_t: query handle, result, number of results returned...
		uint8[512] completed = default;
		bool callFailed = failed;
		bool ok = !failed && sGetCallResult(sUtils, pending.call, &completed, 280, QueryCompletedId, &callFailed) && !callFailed && *(int32*)&completed[8] == 1;
		if (ok)
		{
			let count = ReadU32(&completed[12]);
			// SteamUGCDetails_t is about 9.8 KB; only the leading, fixed part is read.
			uint8[] details = scope .[16384];
			for (uint32 i < count)
			{
				Internal.MemSet(&details[0], 0, details.Count);
				if (!sGetQueryResult(sUgc, pending.handle, i, &details[0]) || *(int32*)&details[8] != 1)
					continue;
				let item = new WorkshopItem();
				item.id = ReadU64(&details[0]);
				item.title.Append((char8*)&details[24]);
				item.description.Append((char8*)&details[153]);
				item.owner = ReadU64(&details[8156]);
				item.tags.Append((char8*)&details[8183]);
				if (sGetQueryPreviewUrl != null)
				{
					char8[1024] url = default;
					if (sGetQueryPreviewUrl(sUgc, pending.handle, i, &url, 1024))
						item.previewUrl.Append(StringView(&url));
				}
				items.Add(item);
			}
		}
		if (sReleaseQuery != null)
			sReleaseQuery(sUgc, pending.handle);
		pending.browseDone(items, ok);
	}

	// ---- publishing ----

	/// Publishes a folder as a Workshop item, or updates one the player already published when existingId is not 0.
	/// previewImage is a PNG or JPG shown on the Workshop page; tags are comma-separated. `done` is called from the
	/// main loop when Steam has finished; keep the id it gives to update the item later.
	public static void Publish(StringView folder, StringView title, StringView description, StringView previewImage, StringView tags, WorkshopVisibility visibility, uint64 existingId, PublishDone done, StringView changeNote = "")
	{
		if (!Bind() || sCreateItem == null || sStartItemUpdate == null || sSubmitItemUpdate == null)
		{
			done(0, false, "The Steam Workshop is not available. The game must be running under Steam.");
			delete done;
			return;
		}
		if (!System.IO.Directory.Exists(folder))
		{
			done(0, false, scope $"Folder not found: {folder}");
			delete done;
			return;
		}
		let pending = new Pending();
		pending.publishDone = done;
		pending.folder.Set(folder);
		pending.title.Set(title);
		pending.description.Set(description);
		pending.preview.Set(previewImage);
		pending.tags.Set(tags);
		pending.note.Set(changeNote);
		pending.visibility = visibility;
		pending.itemId = existingId;
		sPending.Add(pending);
		if (existingId != 0)
			Submit(pending);
		else
		{
			pending.step = .Create;
			pending.call = sCreateItem(sUgc, AppId, 0);
		}
	}

	static void Submit(Pending pending)
	{
		let update = sStartItemUpdate(sUgc, AppId, pending.itemId);
		sUpdateHandle = update;
		if (!pending.title.IsEmpty && sSetItemTitle != null)
			sSetItemTitle(sUgc, update, pending.title.CStr());
		if (!pending.description.IsEmpty && sSetItemDescription != null)
			sSetItemDescription(sUgc, update, pending.description.CStr());
		if (sSetItemContent != null)
			sSetItemContent(sUgc, update, pending.folder.CStr());
		if (!pending.preview.IsEmpty && sSetItemPreview != null)
			sSetItemPreview(sUgc, update, pending.preview.CStr());
		if (sSetItemVisibility != null)
			sSetItemVisibility(sUgc, update, (int32)pending.visibility);
		if (!pending.tags.IsEmpty && sSetItemTags != null)
		{
			List<String> owned = scope .();
			defer
			{
				for (let tag in owned)
					delete tag;
			}
			List<char8*> pointers = scope .();
			for (let part in pending.tags.Split(','))
			{
				let tag = new String(part);
				tag.Trim();
				owned.Add(tag);
				if (!tag.IsEmpty)
					pointers.Add(tag.CStr());
			}
			// SteamParamStringArray_t: a pointer to the strings and how many there are.
			(char8** strings, int32 count) array = (pointers.Ptr, (int32)pointers.Count);
			sSetItemTags(sUgc, update, &array, false);
		}
		pending.step = .Submit;
		pending.call = sSubmitItemUpdate(sUgc, update, pending.note.CStr());
	}

	/// How far the upload in progress has got, 0 to 1.
	public static float PublishProgress
	{
		get
		{
			if (!Bind() || sUpdateHandle == 0 || sGetItemUpdateProgress == null)
				return 0;
			uint64 processed = 0, total = 0;
			sGetItemUpdateProgress(sUgc, sUpdateHandle, &processed, &total);
			return total > 0 ? (float)((double)processed / total) : 0;
		}
	}

	public static bool IsPublishing
	{
		get
		{
			for (let pending in sPending)
			{
				if (pending.step != .Query)
					return true;
			}
			return false;
		}
	}

	/// Opens an item's Workshop page in the Steam overlay's browser, where players rate and comment.
	public static void GetPageUrl(uint64 id, String url) => url.AppendF("steam://url/CommunityFilePage/{}", id);

	// ---- plumbing ----

	/// Finishes requests Steam has answered. Called by the engine every frame.
	public static void Update()
	{
		if (sPending.IsEmpty || sUgc == null)
			return;
		for (int i = sPending.Count - 1; i >= 0; i--)
		{
			let pending = sPending[i];
			bool failed = false;
			if (!sIsCallCompleted(sUtils, pending.call, &failed))
				continue;
			switch (pending.step)
			{
			case .Query:
				FinishQuery(pending, failed);
			case .Create:
				// CreateItemResult_t: result, then the new item's id.
				uint8[64] created = default;
				bool callFailed = failed;
				if (!failed && sGetCallResult(sUtils, pending.call, &created, 16, CreateItemId, &callFailed) && !callFailed && *(int32*)&created[0] == 1)
				{
					pending.itemId = ReadU64(&created[4]);
					Submit(pending);
					continue;
				}
				pending.publishDone(0, false, scope $"Steam could not create the item (result {*(int32*)&created[0]}). Check that the app has the Workshop enabled.");
			case .Submit:
				// SubmitItemUpdateResult_t: result first.
				uint8[64] submitted = default;
				bool callFailed = failed;
				let ok = !failed && sGetCallResult(sUtils, pending.call, &submitted, 16, SubmitUpdateId, &callFailed) && !callFailed && *(int32*)&submitted[0] == 1;
				sUpdateHandle = 0;
				pending.publishDone(pending.itemId, ok, ok ? "Published." : scope $"Steam refused the upload (result {*(int32*)&submitted[0]}).");
			}
			sPending.RemoveAt(i);
			delete pending;
		}
	}

	/// Forgets everything; called when Steam shuts down.
	public static void Reset()
	{
		ClearAndDeleteItems!(sPending);
		sUgc = null;
		sBound = false;
		sUpdateHandle = 0;
	}
}
