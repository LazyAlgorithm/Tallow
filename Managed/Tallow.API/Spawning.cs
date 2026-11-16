using System.Numerics;

namespace Tallow;

/// <summary>
/// The scene's Spawn Points: places where players and other things appear. Asking for a point counts as using it.
/// In multiplayer, ask on the server.
/// </summary>
public static class SpawnPoints
{
    /// <summary>Seconds from the start of play during which start-only points can be used. 0 keeps the start
    /// phase open until <see cref="EndStart"/>.</summary>
    public static float StartWindow
    {
        get => CSharpSpawning.GetStartWindow();
        set => CSharpSpawning.SetStartWindow(value);
    }

    /// <summary>A new start phase: start-only points can be used again, once each.</summary>
    public static void BeginStart(Scene scene) => CSharpSpawning.StartPhase(scene.SessionId, 0);

    /// <summary>Closes the start phase now; from here only ordinary points are given out.</summary>
    public static void EndStart(Scene scene) => CSharpSpawning.StartPhase(scene.SessionId, 1);

    public static bool IsStartPhase(Scene scene) => CSharpSpawning.IsStartPhase(scene.SessionId);

    /// <summary>How many points a team could be given (its own and any-team ones), not counting start-only ones.</summary>
    public static int Count(Scene scene, int team = 0) => CSharpSpawning.Count(scene.SessionId, team);

    /// <summary>The point used longest ago that suits the team (0: no team), or null with no spawn points.</summary>
    public static GameObject? Next(Scene scene, int team = 0) => Point(scene.SessionId, CSharpSpawning.Pick(scene.SessionId, team, false));

    /// <summary>A random point that suits the team, or null with no spawn points.</summary>
    public static GameObject? Random(Scene scene, int team = 0) => Point(scene.SessionId, CSharpSpawning.Pick(scene.SessionId, team, true));

    /// <summary>
    /// Moves an object to the next (or a random) point for the team, facing the point's way. Works for a
    /// character controller, a rigidbody or a plain object. Returns the point, or null when there were none.
    /// </summary>
    public static GameObject? Place(GameObject gameObject, int team = 0, bool random = false) =>
        Point(gameObject.SceneId, CSharpSpawning.Place(gameObject.SceneId, gameObject.Id, team, random));

    /// <summary>Position and facing of the next (or a random) point. False when there are no points.</summary>
    public static bool TryGet(Scene scene, int team, bool random, out Vector3 position, out Quaternion rotation)
    {
        if (Point(scene.SessionId, CSharpSpawning.Pick(scene.SessionId, team, random)) is GameObject point)
        {
            position = point.Transform.Position;
            rotation = point.Transform.Rotation;
            return true;
        }
        position = default;
        rotation = Quaternion.Identity;
        return false;
    }

    private static GameObject? Point(ulong session, ulong id) => id == 0 ? null : new GameObject(session, id);
}

/// <summary>The project's layers (Project Settings > Layers), for the layer masks of ray and shape queries.</summary>
public static class Layers
{
    /// <summary>The layer of that name, or -1.</summary>
    public static int Named(string name) => CSharpSpawning.LayerNamed(name);

    /// <summary>A layer's name ("" for an unnamed one).</summary>
    public static string Name(int layer) => NativeText.Read(buffer => CSharpSpawning.CopyLayerName(layer, buffer)) ?? "";

    /// <summary>A mask of the named layers: <c>Scene.RaycastHit(eye, forward, 100, Layers.Mask("Default", "Enemies"))</c>.
    /// Unknown names are left out.</summary>
    public static uint Mask(params string[] names)
    {
        uint mask = 0;
        foreach (var name in names)
        {
            int layer = Named(name);
            if (layer >= 0)
                mask |= 1u << layer;
        }
        return mask;
    }
}

/// <summary>The project's world states (Project Settings > World States): versions of one level, one active at a time.</summary>
public static class WorldStates
{
    /// <summary>The world state of that name, or -1.</summary>
    public static int Named(string name) => CSharpSpawning.WorldStateNamed(name);

    /// <summary>A world state's name, or null past the last one.</summary>
    public static string? Name(int state) => NativeText.Read(buffer => CSharpSpawning.CopyWorldStateName(state, buffer));
}

public readonly partial record struct Scene
{
    /// <summary>
    /// The active world state (<see cref="WorldStates"/>). Objects outside it are not drawn, do not collide, are not
    /// heard and are not walked on. Change it with <see cref="SetWorldState(int)"/> (a script's <c>Scene</c> is a
    /// value, so it has no setter: <c>Scene.WorldState = 1</c> would not compile).
    /// </summary>
    public int WorldState => CSharpSpawning.GetWorldState(SessionId);

    /// <summary>Switches the world state (an index, 0 to 31): everything outside it hides, stops colliding and goes
    /// quiet at once. Scripts' <see cref="Script.OnWorldStateChanged"/> hear it.</summary>
    public void SetWorldState(int state) => CSharpSpawning.SetWorldState(SessionId, state);

    /// <summary>The same by name; false when the project has no world state of that name.</summary>
    public bool SetWorldState(string name)
    {
        int state = WorldStates.Named(name);
        if (state < 0)
            return false;
        SetWorldState(state);
        return true;
    }
}

public readonly partial record struct GameObject
{
    /// <summary>The team of its Network Identity, set by the server: 1, 2, ... or 0 without teams.</summary>
    public int Team => CSharpSpawning.Team(SceneId, Id);
}
