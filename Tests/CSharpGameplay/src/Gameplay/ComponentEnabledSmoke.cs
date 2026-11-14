using System;
using Tallow;

namespace Gameplay;

/// Tests that a C# Script's Enabled/IsActiveAndEnabled properties are backed
/// by its specific native adapter and that native lifecycle calls are routed
/// to the managed instance exactly once.
[Component]
public sealed class ComponentEnabledSmoke : Script
{
    private int _enables;
    private int _disables;

    public override void Awake()
    {
        if (!Enabled || !IsActiveAndEnabled)
            throw new InvalidOperationException("C# native component did not start enabled.");
    }

    public override void OnEnable() => _enables++;
    public override void OnDisable() => _disables++;

    public override void Start()
    {
        if (!Enabled || !IsActiveAndEnabled || _enables != 1 || _disables != 0)
            throw new InvalidOperationException("Expected one initial native OnEnable.");

        Enabled = false;
        if (Enabled || IsActiveAndEnabled || _disables != 1)
            throw new InvalidOperationException("Disabling native component skipped OnDisable.");

        Enabled = false;
        if (_disables != 1)
            throw new InvalidOperationException("Repeated disable invoked OnDisable twice.");

        Enabled = true;
        if (!Enabled || !IsActiveAndEnabled || _enables != 2)
            throw new InvalidOperationException("Re-enable skipped native OnEnable.");
    }
}
