using System;
using Tallow;

namespace Gameplay;

/// <summary>
/// Unity-style GetComponent<T> and TryGetComponent<T> share one API for native
/// ECS-backed physics handles, Transform, and a separate managed Script.
/// </summary>
[Component]
public sealed class UnifiedComponentLookupSmoke : Script
{
    public override void Awake()
    {
        if (!ReferenceEquals(GetComponent<UnifiedComponentLookupSmoke>(), this))
            throw new InvalidOperationException("Managed GetComponent lost its own script.");

        MoveRight? mover = GetComponent<MoveRight>();
        if (mover is null || !ReferenceEquals(GameObject.GetComponent<MoveRight>(), mover))
            throw new InvalidOperationException("Unified lookup lost a sibling managed script.");

        // A native Rigidbody can be accessed exactly like a managed script.
        Rigidbody rigidbody = GetComponent<Rigidbody>();
        if (!rigidbody.IsValid || rigidbody.GameObject != GameObject ||
            !TryGetComponent(out Rigidbody same) || same != rigidbody)
            throw new InvalidOperationException("Unified native Rigidbody lookup failed.");

        if (!TryGetComponent(out SoftBody soft) || !soft.IsValid ||
            !TryGetComponent(out CharacterController character) || !character.IsValid ||
            !TryGetComponent(out Joint joint) || !joint.IsValid)
            throw new InvalidOperationException("ECS-backed native component lookup failed.");

        if (!TryGetComponent(out ColliderHandle collider) ||
            collider.Index != 0 || collider.Kind != ColliderKind.Box)
            throw new InvalidOperationException("Native collider did not resolve the first shape.");

        if (GetComponent<Transform>() is not { } transform ||
            transform.Position != GameObject.Transform.Position)
            throw new InvalidOperationException("Native Transform lookup failed.");

        // Lookup must not fabricate a value-type handle for an object that
        // is absent from the native scene. The default handle stays invalid.
        GameObject missing = new(1, 98765);
        if (missing.TryGetComponent<Rigidbody>(out Rigidbody absent) || absent.IsValid ||
            missing.GetComponent<Rigidbody>().IsValid ||
            missing.GetComponent<MoveRight>() is not null ||
            missing.TryGetComponent<MoveRight>(out _))
            throw new InvalidOperationException("Missing component was fabricated.");
    }
}
