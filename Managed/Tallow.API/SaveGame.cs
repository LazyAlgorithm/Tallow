namespace Tallow;

/// <summary>
/// Save games: <see cref="Save"/> writes every <see cref="SavedAttribute"/> field in the playing scene (and the
/// engine's own saved state) into a slot, and <see cref="Load"/> puts them back. Only the server saves in a
/// network session. Slots are files in the game's save folder.
/// </summary>
public static class SaveGame
{
    /// <summary>Starts saving to a slot (the server only, in a network session).</summary>
    public static SaveTask Save(string slot = "default") => new(CSharpSaves.Save(slot));
    /// <summary>Starts loading a slot.</summary>
    public static SaveTask Load(string slot = "default") => new(CSharpSaves.Load(slot));
    /// <summary>Whether the slot holds a save.</summary>
    public static bool Exists(string slot = "default") => CSharpSaves.Exists(slot);
    /// <summary>Deletes the slot's save.</summary>
    public static void Delete(string slot = "default") => CSharpSaves.Delete(slot);

    /// <summary>The slots that hold saves (where the storage can list them).</summary>
    public static string[] Slots()
    {
        string text = NativeText.Read(CSharpSaves.ListSlots) ?? "";
        return text.Length == 0 ? [] : text.Split('\x1F');
    }

    private static SaveStorage? sStorage;

    /// <summary>
    /// Where saves go: null (the default) keeps them as files in the player's folder; set your own
    /// <see cref="SaveStorage"/> to send them to a server, a cloud service or a platform's saves. Set it in a
    /// <see cref="GameStartAttribute">[GameStart]</see> method so that it is in place before the first scene loads its
    /// save.
    /// </summary>
    public static SaveStorage? Storage
    {
        get => sStorage;
        set
        {
            sStorage = value;
            CSharpSaves.UseStorage(value != null);
        }
    }

    /// <summary>The engine hands the storage a request (see tn_csharp_save_storage for op).</summary>
    internal static int Dispatch(int op, int task, string slot, ReadOnlySpan<byte> data)
    {
        SaveStorage? storage = sStorage;
        if (storage == null)
        {
            if (op <= 1)
                CSharpSaves.FinishTask(task, 0, default, "There is no C# save storage.");
            return 0;
        }
        switch (op)
        {
            case 0: storage.Write(new SaveRequest(task, slot, data.ToArray(), true)); return 0;
            case 1: storage.Read(new SaveRequest(task, slot, null, false)); return 0;
            case 2: return storage.Exists(slot) ? 1 : 0;
            case 3: storage.Delete(slot); return 0;
            default:
                foreach (string listed in storage.List())
                    CSharpSaves.ListSlot(listed ?? "");
                return 0;
        }
    }

    /// <summary>The game's code is going: saves go back to files.</summary>
    internal static void ClearStorage()
    {
        if (sStorage != null)
            Storage = null;
    }
}

/// <summary>
/// Somewhere of your own to keep saves (a server, a cloud service, a platform's saves): derive from this and set
/// <see cref="SaveGame.Storage"/>. The engine makes the bytes and hands them over; a storage only keeps them and gives
/// them back. Write and Read may finish at once or later, from any thread, by calling the request's Finish or Fail.
/// <code>
/// class ServerStorage : SaveStorage
/// {
///     public override async void Write(SaveRequest request)
///     {
///         try { await Upload(request.Slot, request.Data); request.Finish(); }
///         catch (Exception e) { request.Fail(e.Message); }
///     }
///     public override async void Read(SaveRequest request) =>
///         request.Finish(await Download(request.Slot));   // null: the slot is empty
/// }
/// </code>
/// </summary>
public abstract class SaveStorage
{
    /// <summary>Keeps <see cref="SaveRequest.Data"/> under <see cref="SaveRequest.Slot"/>, then calls Finish (or Fail).</summary>
    public abstract void Write(SaveRequest request);
    /// <summary>Fetches the slot's bytes and calls Finish with them (null when the slot is empty), or Fail.</summary>
    public abstract void Read(SaveRequest request);
    /// <summary>Whether a slot holds a save. A storage that cannot tell without waiting answers false.</summary>
    public virtual bool Exists(string slot) => false;
    /// <summary>Deletes a slot's save, if there is one.</summary>
    public virtual void Delete(string slot) { }
    /// <summary>The slots that hold saves, where the storage can list them.</summary>
    public virtual IEnumerable<string> List() => [];
}

/// <summary>One save or load handed to a <see cref="SaveStorage"/>. Finish it once, from any thread.</summary>
public sealed class SaveRequest
{
    private readonly int task;
    private int finished;

    internal SaveRequest(int task, string slot, byte[]? data, bool write)
    {
        this.task = task;
        IsWrite = write;
        Slot = slot;
        Data = data ?? [];
    }

    /// <summary>The save slot.</summary>
    public string Slot { get; }
    /// <summary>Writing: the bytes to keep (compact and checksummed; keep them exactly). Reading: empty.</summary>
    public byte[] Data { get; }
    /// <summary>Whether this request saves (Write) rather than loads (Read).</summary>
    public bool IsWrite { get; }

    /// <summary>Writing: the save is kept.</summary>
    public void Finish() => Complete(1, null, "");

    /// <summary>Reading: the bytes found in the slot, or null when it is empty.</summary>
    public void Finish(byte[]? data) => Complete(data == null ? 2 : 1, data, "");

    /// <summary>Something went wrong: why, for the log or the player.</summary>
    public void Fail(string why) => Complete(0, null, string.IsNullOrEmpty(why) ? "The save storage failed." : why);

    private void Complete(int outcome, byte[]? data, string error)
    {
        if (Interlocked.Exchange(ref finished, 1) != 0)
            throw new InvalidOperationException("This save request was finished already.");
        CSharpSaves.FinishTask(task, outcome, data ?? [], error);
    }
}

/// <summary>
/// Marks a static method with no parameters that runs once when the game's code loads, before the first scene
/// starts (and again after a hot reload): the place to set <see cref="SaveGame.Storage"/> and other game-wide
/// settings.
/// </summary>
[AttributeUsage(AttributeTargets.Method, Inherited = false)]
public sealed class GameStartAttribute : Attribute;

/// <summary>The game's [GameStart] methods. The build registers them; the runtime runs them as the game loads.</summary>
[System.ComponentModel.EditorBrowsable(System.ComponentModel.EditorBrowsableState.Never)]
public static class GameStarts
{
    private static readonly List<(string Name, Action Run)> sMethods = [];

    /// <summary>Called by the generated registry for each [GameStart] method.</summary>
    public static void Register(Action run, string name) => sMethods.Add((name, run));

    /// <summary>Runs each once; a method that throws is reported and the rest still run.</summary>
    internal static List<(string Name, Exception Error)> RunAll()
    {
        var failures = new List<(string, Exception)>();
        foreach ((string name, Action run) in sMethods)
        {
            try { run(); }
            catch (Exception exception) { failures.Add((name, exception)); }
        }
        return failures;
    }

    internal static void Clear() => sMethods.Clear();
}

/// <summary>A save or load on its way. Local saves finish at once; check <see cref="Done"/> for others.</summary>
public readonly record struct SaveTask(int Id)
{
    /// <summary>Finished, well or not.</summary>
    public bool Done => CSharpSaves.Status(Id) != 0;
    /// <summary>Finished and worked.</summary>
    public bool Succeeded => CSharpSaves.Status(Id) > 0;
    /// <summary>Loading: the slot held a save.</summary>
    public bool Found => CSharpSaves.Status(Id) == 1;
}
