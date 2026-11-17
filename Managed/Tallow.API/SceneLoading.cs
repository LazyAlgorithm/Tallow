namespace Tallow;

/// <summary>Where a background load is (<see cref="SceneLoad.Stage"/>).</summary>
public enum SceneLoadStage
{
    /// <summary>Reading the scene file and finding what it names.</summary>
    Reading,
    /// <summary>Loading the models and textures it names.</summary>
    Loading,
    /// <summary>Everything is loaded; waiting for <see cref="SceneLoad.Activate"/>.</summary>
    Ready,
    /// <summary>Switched to, or added.</summary>
    Done,
    /// <summary>The file could not be read.</summary>
    Failed,
}

/// <summary>
/// A scene loading in the background (<see cref="SceneManager.LoadAsync"/>, <see cref="Scene.LoadAdditiveAsync"/>):
/// show <see cref="Progress"/> on a loading screen, or <c>await load.Completion</c>.
/// </summary>
public sealed class SceneLoad
{
    private static readonly List<SceneLoad> sWaiting = [];
    private readonly int id;
    private readonly ulong session;
    private readonly TaskCompletionSource<bool> completion = new();
    private bool allowActivation = true;
    private SceneLoadStage stage;
    private float progress;
    private int assetCount, assetsLoaded;

    internal SceneLoad(int id, ulong session, string path, bool additive)
    {
        this.id = id;
        this.session = session;
        Path = path;
        IsAdditive = additive;
        lock (sWaiting)
            sWaiting.Add(this);
        // GameThread.Stop clears the hook, so it is put back with each load.
        GameThread.EachFrame -= PollAll;
        GameThread.EachFrame += PollAll;
        Refresh();
    }

    /// <summary>The scene file.</summary>
    public string Path { get; }
    /// <summary>Whether it adds to the running scene (rather than changing to it).</summary>
    public bool IsAdditive { get; }

    /// <summary>Where it is.</summary>
    public SceneLoadStage Stage => Refresh().stage;
    /// <summary>A tenth for reading, up to 0.9 for loading, 1 when done.</summary>
    public float Progress => Refresh().progress;
    /// <summary>How many models and textures it names.</summary>
    public int AssetCount => Refresh().assetCount;
    /// <summary>How many of them are in.</summary>
    public int AssetsLoaded => Refresh().assetsLoaded;
    /// <summary>Done or failed.</summary>
    public bool IsDone => Stage is SceneLoadStage.Done or SceneLoadStage.Failed;
    /// <summary>The file could not be read.</summary>
    public bool Failed => Stage == SceneLoadStage.Failed;

    /// <summary>Finishes when the load is done (true) or failed (false), on the game thread.</summary>
    public Task<bool> Completion => completion.Task;

    /// <summary>False holds a finished load at Ready (Progress 0.9) until <see cref="Activate"/>: for "press any key
    /// to continue". True by default.</summary>
    public bool AllowActivation
    {
        get => allowActivation;
        set
        {
            allowActivation = value;
            CSharpScenes.AllowActivation(id, value);
        }
    }

    /// <summary>Lets a load held at Ready finish.</summary>
    public void Activate() => AllowActivation = true;

    /// <summary>An additive load's object holding what it added, once done (null before, and for a change of scene).
    /// <see cref="Scene.Unload"/> takes it out again.</summary>
    public GameObject? Group
    {
        get
        {
            ulong group = CSharpScenes.Group(id);
            return group == 0 ? null : new GameObject(session, group);
        }
    }

    private SceneLoad Refresh()
    {
        Span<float> values = stackalloc float[3];
        int now = CSharpScenes.State(id, values);
        if (now >= 0)
        {
            stage = (SceneLoadStage)now;
            progress = values[0];
            assetCount = (int)values[1];
            assetsLoaded = (int)values[2];
        }
        else if (stage is not (SceneLoadStage.Done or SceneLoadStage.Failed))
            // Not known any more (the game's code was reloaded meanwhile).
            stage = SceneLoadStage.Failed;
        if (stage is SceneLoadStage.Done)
            progress = 1;
        return this;
    }

    private static void PollAll()
    {
        SceneLoad[] waiting;
        lock (sWaiting)
            waiting = [.. sWaiting];
        foreach (SceneLoad load in waiting)
        {
            if (!load.IsDone)
                continue;
            lock (sWaiting)
                sWaiting.Remove(load);
            load.completion.TrySetResult(load.stage == SceneLoadStage.Done);
        }
    }
}

public static partial class SceneManager
{
    /// <summary>
    /// Changes to another scene without stopping the game while it loads: the file and the models and textures it
    /// names are read in the background while this scene plays on, then the scene is switched to as
    /// <see cref="Load"/> does. Show a loading screen meanwhile from the returned load's Progress.
    /// </summary>
    public static SceneLoad LoadAsync(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        int id = CSharpScenes.Start(0, path, false, false);
        return new SceneLoad(id, 0, path, false);
    }
}

public readonly partial record struct Scene
{
    /// <summary>
    /// <see cref="LoadAdditive"/> without stopping the game while it loads: when everything the file names is ready,
    /// its contents are added and the load's Group holds them. Every machine loads it for itself.
    /// </summary>
    public SceneLoad LoadAdditiveAsync(string path, bool applyEnvironment = false)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        int id = CSharpScenes.Start(SessionId, path, true, applyEnvironment);
        if (id == 0)
            throw new InvalidOperationException("This scene is not running.");
        return new SceneLoad(id, SessionId, path, true);
    }
}

/// <summary>Getting models and textures ready before they are needed (a weapon about to be picked up).</summary>
public static class AssetLoader
{
    /// <summary>Starts loading files in the background; follow it with the returned preload's Progress. What it loads
    /// stays loaded.</summary>
    public static Preload Preload(params string[] paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        return new Preload(CSharpScenes.Preload(string.Join('\n', paths.Where(p => !string.IsNullOrEmpty(p)))));
    }
}

/// <summary>Files loading in the background (<see cref="AssetLoader.Preload"/>). Dispose it when done with it.</summary>
public sealed class Preload : IDisposable
{
    private int id;

    internal Preload(int id) => this.id = id;

    /// <summary>0 to 1.</summary>
    public float Progress => id == 0 ? 1 : Math.Max(0, CSharpScenes.PreloadState(id, Span<float>.Empty));
    /// <summary>Every file is in.</summary>
    public bool IsDone => Progress >= 1;
    /// <summary>How many files it loads.</summary>
    public int Total => Counts().Total;
    /// <summary>How many are in.</summary>
    public int Loaded => Counts().Loaded;

    private (int Total, int Loaded) Counts()
    {
        Span<float> values = stackalloc float[2];
        return id != 0 && CSharpScenes.PreloadState(id, values) >= 0 ? ((int)values[0], (int)values[1]) : (0, 0);
    }

    /// <summary>Stops following it (what it loaded stays loaded).</summary>
    public void Dispose()
    {
        if (id != 0)
            CSharpScenes.ReleasePreload(id);
        id = 0;
    }
}
