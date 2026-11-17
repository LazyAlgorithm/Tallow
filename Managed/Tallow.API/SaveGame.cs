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
