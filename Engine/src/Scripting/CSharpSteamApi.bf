using System;
using System.Collections;

namespace Tallow;

/// Steam and the Steam Workshop for C# (Managed/Tallow.API/Steam.cs gives them their C# shape). Workshop browsing
/// and publishing answer later through Beef delegates; C# cannot hand those over, so each request gets an id here,
/// its answer is kept under it, and C# waits for it a frame at a time.
[CSharpExpose]
static class CSharpSteam
{
	class BrowseResult
	{
		public bool done;
		public bool abandoned;
		public bool ok;
		public List<WorkshopItem> items = new .() ~ DeleteContainerAndItems!(_);
	}

	class PublishResult
	{
		public bool done;
		public bool abandoned;
		public bool ok;
		public uint64 id;
		public String message = new .() ~ delete _;
	}

	static Dictionary<int32, BrowseResult> sBrowses = new .() ~ DeleteDictionaryAndValues!(_);
	static Dictionary<int32, PublishResult> sPublishes = new .() ~ DeleteDictionaryAndValues!(_);
	static int32 sNextRequest = 1;

	/// Copies text for C# as UTF-8; the whole length, which may be more than the buffer (call again with more room).
	static int32 Copy(StringView text, Span<uint8> buffer)
	{
		let count = Math.Min(text.Length, buffer.Length);
		for (int i < count)
			buffer[i] = (uint8)text[i];
		return (int32)text.Length;
	}

	// ---- Steam

	[CSharpExpose]
	public static bool Start() => Steam.Start();

	[CSharpExpose]
	public static bool IsReady() => Steam.IsReady;

	/// Lets Steam deliver its events (invitations, Workshop answers). The Steam transport does it every tick.
	[CSharpExpose]
	public static void Update() => Steam.Update();

	[CSharpExpose]
	public static int32 Error(Span<uint8> buffer) => Copy(Steam.Error, buffer);

	[CSharpExpose]
	public static uint64 UserId() => Steam.UserId;

	[CSharpExpose]
	public static int32 UserName(Span<uint8> buffer) => Copy(Steam.UserName, buffer);

	[CSharpExpose]
	public static int32 FriendCount() => (int32)Steam.FriendCount;

	[CSharpExpose]
	public static uint64 FriendAt(int32 index) => index < 0 ? 0 : Steam.FriendAt(index);

	[CSharpExpose]
	public static int32 FriendName(uint64 id, Span<uint8> buffer)
	{
		let name = scope String();
		Steam.PlayerName(id, name);
		return Copy(name, buffer);
	}

	[CSharpExpose]
	public static bool FriendOnline(uint64 id) => Steam.FriendOnline(id);

	[CSharpExpose]
	public static bool IsFriend(uint64 id) => Steam.IsFriend(id);

	[CSharpExpose]
	public static bool SetPresence(StringView key, StringView value) => Steam.SetPresence(key, value);

	[CSharpExpose]
	public static void ClearPresence() => Steam.ClearPresence();

	[CSharpExpose]
	public static int32 FriendPresence(uint64 id, StringView key, Span<uint8> buffer)
	{
		let value = scope String();
		Steam.FriendPresence(id, key, value);
		return Copy(value, buffer);
	}

	[CSharpExpose]
	public static bool Invite(uint64 friend, StringView connect) => Steam.Invite(friend, connect);

	/// The join request waiting (the connect text), or -1 when there is none; it is taken (cleared) once its whole
	/// text fitted in the buffer.
	[CSharpExpose]
	public static int32 TakeJoinRequest(Span<uint8> buffer)
	{
		if (!Steam.[Friend]sJoinPending)
			return -1;
		let length = Copy(Steam.[Friend]sJoinRequest, buffer);
		if (length <= buffer.Length)
			Steam.[Friend]sJoinPending = false;
		return length;
	}

	// ---- Workshop

	[CSharpExpose]
	public static bool WorkshopAvailable() => Workshop.Available;

	[CSharpExpose]
	public static int32 WorkshopMountInstalled() => (int32)Workshop.MountInstalled();

	/// 1 subscribed, 2 installed, 4 downloading, 8 needs an update.
	[CSharpExpose]
	public static int32 WorkshopState(uint64 id) => (Workshop.IsSubscribed(id) ? 1 : 0) | (Workshop.IsInstalled(id) ? 2 : 0) |
		(Workshop.IsDownloading(id) ? 4 : 0) | (Workshop.NeedsUpdate(id) ? 8 : 0);

	[CSharpExpose]
	public static void WorkshopSubscribe(uint64 id, bool subscribe)
	{
		if (subscribe)
			Workshop.Subscribe(id);
		else
			Workshop.Unsubscribe(id);
	}

	[CSharpExpose]
	public static bool WorkshopDownload(uint64 id) => Workshop.Download(id);

	[CSharpExpose]
	public static int32 WorkshopFolder(uint64 id, Span<uint8> buffer)
	{
		let folder = scope String();
		return Workshop.GetFolder(id, folder) ? Copy(folder, buffer) : -1;
	}

	/// The subscribed items' ids; how many there are (more than the span holds: call again with more room).
	[CSharpExpose]
	public static int32 WorkshopSubscribed(Span<uint64> ids)
	{
		let list = scope List<uint64>();
		Workshop.GetSubscribed(list);
		for (int i < Math.Min(list.Count, ids.Length))
			ids[i] = list[i];
		return (int32)list.Count;
	}

	/// Asks for a page of items (sort: 0 Popular, 1 Newest, 2 Trending, 3 Search; mine: the player's own). The
	/// request's id, for WorkshopBrowseState, WorkshopBrowseItem* and WorkshopBrowseEnd.
	[CSharpExpose]
	public static int32 WorkshopBrowse(int32 sort, int32 page, StringView searchText, bool mine)
	{
		let request = sNextRequest++;
		let result = new BrowseResult();
		sBrowses[request] = result;
		Workshop.BrowseDone done = new [=] (items, ok) =>
		{
			if (result.abandoned)
			{
				delete result;
				return;
			}
			result.done = true;
			result.ok = ok;
			for (let item in items)
			{
				let copy = new WorkshopItem();
				copy.id = item.id;
				copy.title.Set(item.title);
				copy.description.Set(item.description);
				copy.tags.Set(item.tags);
				copy.previewUrl.Set(item.previewUrl);
				copy.owner = item.owner;
				result.items.Add(copy);
			}
		};
		if (mine)
			Workshop.BrowseMine(page, done);
		else
			Workshop.Browse((WorkshopSort)Math.Clamp(sort, 0, 3), page, searchText, done);
		return request;
	}

	/// -1 no such request, 0 waiting, 1 done and worked (WorkshopBrowseCount items), 2 done and failed.
	[CSharpExpose]
	public static int32 WorkshopBrowseState(int32 request)
	{
		if (!sBrowses.TryGetValue(request, let result))
			return -1;
		return result.done ? (result.ok ? 1 : 2) : 0;
	}

	[CSharpExpose]
	public static int32 WorkshopBrowseCount(int32 request) => sBrowses.TryGetValue(request, let result) ? (int32)result.items.Count : 0;

	static WorkshopItem BrowseItem(int32 request, int32 index) =>
		sBrowses.TryGetValue(request, let result) && index >= 0 && index < result.items.Count ? result.items[index] : null;

	/// A browsed item's id (0 when there is no such item).
	[CSharpExpose]
	public static uint64 WorkshopBrowseItemId(int32 request, int32 index) => BrowseItem(request, index)?.id ?? 0;

	/// The Steam ID of whoever published a browsed item.
	[CSharpExpose]
	public static uint64 WorkshopBrowseItemOwner(int32 request, int32 index) => BrowseItem(request, index)?.owner ?? 0;

	/// A browsed item's text: field 0 title, 1 description, 2 tags (comma-separated), 3 preview image URL.
	[CSharpExpose]
	public static int32 WorkshopBrowseItemText(int32 request, int32 index, int32 field, Span<uint8> buffer)
	{
		let item = BrowseItem(request, index);
		if (item == null)
			return 0;
		StringView text = field == 0 ? item.title : field == 1 ? item.description : field == 2 ? item.tags : item.previewUrl;
		return Copy(text, buffer);
	}

	/// Forgets a browse once C# has read it (one still waiting for Steam is dropped when it answers).
	[CSharpExpose]
	public static void WorkshopBrowseEnd(int32 request)
	{
		if (sBrowses.GetAndRemove(request) case .Ok(let pair))
		{
			if (pair.value.done)
				delete pair.value;
			else
				pair.value.abandoned = true;
		}
	}

	/// Publishes (or updates, when existingId is not 0) a folder as an item; visibility 0 Public, 1 FriendsOnly,
	/// 2 Private, 3 Unlisted. The request's id, for WorkshopPublishState.
	[CSharpExpose]
	public static int32 WorkshopPublish(StringView folder, StringView title, StringView description, StringView previewImage,
		StringView tags, int32 visibility, uint64 existingId, StringView changeNote)
	{
		let request = sNextRequest++;
		let result = new PublishResult();
		sPublishes[request] = result;
		Workshop.Publish(folder, title, description, previewImage, tags, (WorkshopVisibility)Math.Clamp(visibility, 0, 3), existingId,
			new [=] (id, ok, message) =>
			{
				if (result.abandoned)
				{
					delete result;
					return;
				}
				result.done = true;
				result.ok = ok;
				result.id = id;
				result.message.Set(message);
			}, changeNote);
		return request;
	}

	/// -1 no such request, 0 waiting, 1 published, 2 failed.
	[CSharpExpose]
	public static int32 WorkshopPublishState(int32 request)
	{
		if (!sPublishes.TryGetValue(request, let result))
			return -1;
		return result.done ? (result.ok ? 1 : 2) : 0;
	}

	/// The published item's id (keep it to update the item later).
	[CSharpExpose]
	public static uint64 WorkshopPublishId(int32 request) => sPublishes.TryGetValue(request, let result) ? result.id : 0;

	/// Steam's message about a finished publish (why it failed, or empty).
	[CSharpExpose]
	public static int32 WorkshopPublishMessage(int32 request, Span<uint8> buffer) =>
		sPublishes.TryGetValue(request, let result) ? Copy(result.message, buffer) : 0;

	/// Forgets a publish once C# has read it (one still uploading is dropped when it finishes).
	[CSharpExpose]
	public static void WorkshopPublishEnd(int32 request)
	{
		if (sPublishes.GetAndRemove(request) case .Ok(let pair))
		{
			if (pair.value.done)
				delete pair.value;
			else
				pair.value.abandoned = true;
		}
	}

	[CSharpExpose]
	public static float WorkshopPublishProgress() => Workshop.PublishProgress;

	[CSharpExpose]
	public static bool WorkshopIsPublishing() => Workshop.IsPublishing;

	/// The folders the last MountInstalled mounted, one a line.
	[CSharpExpose]
	public static int32 WorkshopMounted(Span<uint8> buffer)
	{
		let text = scope String();
		for (let folder in Workshop.Mounted)
			text.Append(folder, "\n");
		return Copy(text, buffer);
	}
}
