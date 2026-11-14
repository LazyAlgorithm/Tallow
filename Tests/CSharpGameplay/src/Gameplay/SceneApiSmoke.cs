using Tallow;

namespace Gameplay;

/// <summary>Integration probe for the scene/session bridge; runs with native callbacks.</summary>
[Component]
public sealed class SceneApiSmoke : Script
{
    public override void Awake()
    {
        GameObject created = Scene.CreateGameObject("From C#");
        if (created.SceneId != GameObject.SceneId || created.Id != 42)
            throw new InvalidOperationException("Created object did not keep the native scene handle.");

        GameObject? found = Scene.Find("From C#");
        if (found != created || Scene.Find("Not here") != null)
            throw new InvalidOperationException("Native scene lookup returned an incorrect object.");

        GameObject? prefab = Prefab.Instantiate(Scene, "Prefabs/Box.tprefab");
        if (prefab is not { Id: 77 } || prefab.Value.SceneId != GameObject.SceneId)
            throw new InvalidOperationException("Native prefab instantiation did not return its object ID.");
    }
}
