using System;
using Tallow;

namespace Gameplay;

/// <summary>
/// The native scene can attach multiple C# scripts of the same type without
/// returning the first script for every AddComponent call.
/// </summary>
[Component]
public sealed class AddComponentSmoke : Script
{
    public override void Awake()
    {
        var a = AddComponent<MoveRight>();
        var b = GameObject.AddComponent<MoveRight>();
        if (a is null || b is null || ReferenceEquals(a, b) ||
            !ReferenceEquals(GetComponent<MoveRight>(), a) ||
            !ReferenceEquals(GameObject.GetComponent<MoveRight>(), a))
            throw new InvalidOperationException("New C# component handles were not distinct.");
    }
}
