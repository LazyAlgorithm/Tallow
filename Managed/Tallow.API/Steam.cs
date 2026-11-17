namespace Tallow;

/// <summary>
/// Steam: the signed-in player, friends, rich presence and invitations. Everything quietly does nothing (and reads
/// zero or empty) when the game is not running under Steam or the project has no App ID. Achievements and stats are
/// <see cref="Achievements"/>, which uses Steam when it is there.
/// </summary>
public static class Steam
{
    /// <summary>Connects to Steam with the project's App ID (once; later calls just answer). False when Steam is not
    /// running or the project has no App ID: <see cref="Error"/> says why.</summary>
    public static bool Start() => CSharpSteam.Start();

    /// <summary>Whether Steam is connected.</summary>
    public static bool IsReady => CSharpSteam.IsReady();

    /// <summary>Lets Steam deliver its events: invitations and Workshop answers. A network session on the Steam
    /// transport does it every tick; otherwise call it once a frame (Workshop.Browse and Publish call it while they
    /// wait).</summary>
    public static void Update() => CSharpSteam.Update();

    /// <summary>Why Start failed, in words (empty when it did not).</summary>
    public static string Error => ActionText.Read(CSharpSteam.Error) ?? "";

    /// <summary>The signed-in player's 64-bit Steam ID, which is also the address friends connect to. 0 without Steam.</summary>
    public static ulong UserId => CSharpSteam.UserId();

    /// <summary>The signed-in player's Steam name.</summary>
    public static string UserName => ActionText.Read(CSharpSteam.UserName) ?? "";

    /// <summary>How many friends the player has.</summary>
    public static int FriendCount => CSharpSteam.FriendCount();

    /// <summary>A friend's Steam ID by place in the list (0 to FriendCount - 1).</summary>
    public static ulong FriendAt(int index) => CSharpSteam.FriendAt(index);

    /// <summary>Every friend's Steam ID.</summary>
    public static ulong[] Friends
    {
        get
        {
            var friends = new ulong[FriendCount];
            for (int i = 0; i < friends.Length; i++)
                friends[i] = FriendAt(i);
            return friends;
        }
    }

    /// <summary>A player's name as this player sees it (their nickname for a friend, else the Steam name).</summary>
    public static string FriendName(ulong id) => ActionText.Read(buffer => CSharpSteam.FriendName(id, buffer)) ?? "";

    /// <summary>Whether a friend is signed in to Steam (online, away, busy: anything but offline).</summary>
    public static bool FriendOnline(ulong id) => CSharpSteam.FriendOnline(id);

    /// <summary>Whether a Steam ID is one of the player's friends.</summary>
    public static bool IsFriend(ulong id) => CSharpSteam.IsFriend(id);

    /// <summary>Publishes a piece of text about what this player is doing, which friends in the same game read
    /// with <see cref="FriendPresence"/>. Steam shows "status" in the friends list and offers a Join button when
    /// "connect" is set. An empty value removes the key.</summary>
    public static bool SetPresence(string key, string value) => CSharpSteam.SetPresence(key ?? "", value ?? "");

    /// <summary>Removes everything SetPresence published.</summary>
    public static void ClearPresence() => CSharpSteam.ClearPresence();

    /// <summary>What a friend published under a key (empty when they are not in this game or never set it).</summary>
    public static string FriendPresence(ulong id, string key) =>
        ActionText.Read(buffer => CSharpSteam.FriendPresence(id, key ?? "", buffer)) ?? "";

    /// <summary>Sends a friend an invitation to join; connect reaches their game when they accept (see
    /// <see cref="TakeJoinRequest"/>). The usual choice is the host's Steam ID.</summary>
    public static bool Invite(ulong friend, string connect) => CSharpSteam.Invite(friend, connect ?? "");

    /// <summary>True once after the player accepted an invitation, or pressed Join in the friends list, while the
    /// game ran; connect is what the inviting game gave. Call it every frame or so.</summary>
    public static bool TakeJoinRequest(out string connect)
    {
        Span<byte> buffer = stackalloc byte[256];
        int length = CSharpSteam.TakeJoinRequest(buffer);
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = CSharpSteam.TakeJoinRequest(buffer);
        }
        connect = length < 0 ? "" : System.Text.Encoding.UTF8.GetString(buffer[..Math.Min(length, buffer.Length)]);
        return length >= 0;
    }
}

/// <summary>The order <see cref="Workshop.Browse"/> lists items in.</summary>
public enum WorkshopSort
{
    /// <summary>Highest rated of all time.</summary>
    Popular,
    /// <summary>Newest first.</summary>
    Newest,
    /// <summary>Rising lately.</summary>
    Trending,
    /// <summary>Best match for the search text.</summary>
    Search,
}

/// <summary>Who can see a published Workshop item.</summary>
public enum WorkshopVisibility
{
    /// <summary>Everyone.</summary>
    Public,
    /// <summary>The publisher's friends.</summary>
    FriendsOnly,
    /// <summary>Only the publisher.</summary>
    Private,
    /// <summary>Anyone with the link; not listed.</summary>
    Unlisted,
}

/// <summary>A Workshop item from <see cref="Workshop.Browse"/>.</summary>
public sealed record WorkshopItem(ulong Id, string Title, string Description, string Tags, string PreviewUrl, ulong Owner);

/// <summary>What <see cref="Workshop.Publish"/> gives when Steam has finished.</summary>
public readonly record struct WorkshopPublishResult(bool Succeeded, ulong Id, string Message);

/// <summary>
/// Player-made content through the Steam Workshop. Subscribed items download by themselves; MountInstalled makes
/// their files loadable as assets by their path inside the item (an item with Scenes/Arena.tscene loads as
/// "Scenes/Arena.tscene"). Browse and Publish are awaited: Steam answers a moment later, on the game thread.
/// </summary>
public static class Workshop
{
    /// <summary>Whether the game runs under Steam and the Workshop can be used.</summary>
    public static bool Available => CSharpSteam.WorkshopAvailable();

    /// <summary>Makes every installed item's files loadable as assets; how many items. Call it at start-up and after
    /// the player subscribes to something.</summary>
    public static int MountInstalled() => CSharpSteam.WorkshopMountInstalled();

    /// <summary>Whether the player is subscribed to the item.</summary>
    public static bool IsSubscribed(ulong id) => (CSharpSteam.WorkshopState(id) & 1) != 0;
    /// <summary>Whether the item is downloaded and ready to use.</summary>
    public static bool IsInstalled(ulong id) => (CSharpSteam.WorkshopState(id) & 2) != 0;
    /// <summary>Whether the item is downloading now.</summary>
    public static bool IsDownloading(ulong id) => (CSharpSteam.WorkshopState(id) & 4) != 0;
    /// <summary>Whether a newer version of the item is waiting to download.</summary>
    public static bool NeedsUpdate(ulong id) => (CSharpSteam.WorkshopState(id) & 8) != 0;

    /// <summary>Subscribes; Steam downloads it in the background.</summary>
    public static void Subscribe(ulong id) => CSharpSteam.WorkshopSubscribe(id, true);
    /// <summary>Unsubscribes; Steam removes it.</summary>
    public static void Unsubscribe(ulong id) => CSharpSteam.WorkshopSubscribe(id, false);
    /// <summary>Asks for a subscribed item now, ahead of the rest.</summary>
    public static bool Download(ulong id) => CSharpSteam.WorkshopDownload(id);

    /// <summary>Where an installed item's files are on disk, or null when it is not installed.</summary>
    public static string? Folder(ulong id)
    {
        Span<byte> buffer = stackalloc byte[512];
        int length = CSharpSteam.WorkshopFolder(id, buffer);
        if (length < 0)
            return null;
        if (length > buffer.Length)
        {
            buffer = new byte[length];
            length = Math.Min(length, CSharpSteam.WorkshopFolder(id, buffer));
        }
        return System.Text.Encoding.UTF8.GetString(buffer[..length]);
    }

    /// <summary>The ids of every item the player is subscribed to.</summary>
    public static ulong[] Subscribed
    {
        get
        {
            Span<ulong> ids = stackalloc ulong[64];
            int count = CSharpSteam.WorkshopSubscribed(ids);
            if (count > ids.Length)
            {
                ids = new ulong[count];
                count = Math.Min(count, CSharpSteam.WorkshopSubscribed(ids));
            }
            return ids[..count].ToArray();
        }
    }

    /// <summary>A page of items (50 to a page, pages from 1); empty when Steam could not answer. Await it on the
    /// game thread: <c>var items = await Workshop.Browse(WorkshopSort.Popular);</c></summary>
    public static Task<WorkshopItem[]> Browse(WorkshopSort sort, int page = 1, string search = "") =>
        BrowseRequest(CSharpSteam.WorkshopBrowse((int)sort, page, search ?? "", false));

    /// <summary>A page of the items the player has published for this game.</summary>
    public static Task<WorkshopItem[]> BrowseMine(int page = 1) => BrowseRequest(CSharpSteam.WorkshopBrowse(0, page, "", true));

    private static async Task<WorkshopItem[]> BrowseRequest(int request)
    {
        try
        {
            int state;
            while ((state = CSharpSteam.WorkshopBrowseState(request)) == 0)
            {
                CSharpSteam.Update();
                await GameThread.Delay(0f, CancellationToken.None);
            }
            if (state != 1)
                return [];
            var items = new WorkshopItem[CSharpSteam.WorkshopBrowseCount(request)];
            for (int i = 0; i < items.Length; i++)
            {
                int index = i;
                string Text(int field) => ActionText.Read(buffer => CSharpSteam.WorkshopBrowseItemText(request, index, field, buffer)) ?? "";
                items[i] = new WorkshopItem(CSharpSteam.WorkshopBrowseItemId(request, i), Text(0), Text(1), Text(2), Text(3),
                    CSharpSteam.WorkshopBrowseItemOwner(request, i));
            }
            return items;
        }
        finally
        {
            CSharpSteam.WorkshopBrowseEnd(request);
        }
    }

    /// <summary>Publishes a folder as an item, or updates one the player published when existingId is not 0.
    /// previewImage is a PNG or JPG; tags are comma-separated. Keep the result's Id to update it later.</summary>
    public static async Task<WorkshopPublishResult> Publish(string folder, string title, string description, string previewImage,
        string tags, WorkshopVisibility visibility = WorkshopVisibility.Public, ulong existingId = 0, string changeNote = "")
    {
        int request = CSharpSteam.WorkshopPublish(folder ?? "", title ?? "", description ?? "", previewImage ?? "", tags ?? "",
            (int)visibility, existingId, changeNote ?? "");
        try
        {
            int state;
            while ((state = CSharpSteam.WorkshopPublishState(request)) == 0)
            {
                CSharpSteam.Update();
                await GameThread.Delay(0f, CancellationToken.None);
            }
            string message = ActionText.Read(buffer => CSharpSteam.WorkshopPublishMessage(request, buffer)) ?? "";
            return new WorkshopPublishResult(state == 1, CSharpSteam.WorkshopPublishId(request), message);
        }
        finally
        {
            CSharpSteam.WorkshopPublishEnd(request);
        }
    }

    /// <summary>How far the upload in progress has got, 0 to 1.</summary>
    public static float PublishProgress => CSharpSteam.WorkshopPublishProgress();

    /// <summary>Whether an upload is in progress.</summary>
    public static bool IsPublishing => CSharpSteam.WorkshopIsPublishing();

    /// <summary>The folders the last MountInstalled made loadable, one per item.</summary>
    public static string[] Mounted =>
        (ActionText.Read(CSharpSteam.WorkshopMounted) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
}
