using System;
using Tallow;

namespace Gameplay;

/// The native GameObject owns active hierarchy state; C# does not maintain
/// a duplicate shadow flag or bypass the Flecs/network notifications.
[Component]
public sealed class GameObjectActiveSmoke : Script
{
    private int _enables;
    private int _disables;

    public override void Awake()
    {
        if (!GameObject.ActiveSelf || !GameObject.ActiveInHierarchy)
            throw new InvalidOperationException("Native GameObject should start active.");
    }

    public override void OnEnable() => _enables++;
    public override void OnDisable() => _disables++;

    public override void Start()
    {
        if (_enables != 1)
            throw new InvalidOperationException("GameObject initial OnEnable count mismatch.");

        GameObject.SetActive(false);
        if (GameObject.ActiveSelf || GameObject.ActiveInHierarchy ||
            !GameObject.IsValid || _disables != 1)
            throw new InvalidOperationException("SetActive(false) skipped native disable.");

        GameObject.SetActive(false);
        if (_disables != 1)
            throw new InvalidOperationException("Repeated SetActive(false) fired duplicate disable.");

        GameObject.SetActive(true);
        if (!GameObject.ActiveSelf || !GameObject.ActiveInHierarchy || _enables != 2)
            throw new InvalidOperationException("SetActive(true) skipped native enable.");
    }
}
