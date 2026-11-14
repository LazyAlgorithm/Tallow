using Tallow;

namespace Gameplay;

/// <summary>
/// Verify Unity-like GetComponent works for attached C# gameplay behaviours.
/// The native engine keeps ownership and determines component lifetimes.
/// </summary>
[Component]
public sealed class ComponentLookup : Script
{
    public override void Awake()
    {
        if (GetComponent<MoveRight>() is not null &&
            GameObject.GetComponent<MoveRight>() is not null)
            Transform.Position += Vector3.UnitY * 3;
    }
}
