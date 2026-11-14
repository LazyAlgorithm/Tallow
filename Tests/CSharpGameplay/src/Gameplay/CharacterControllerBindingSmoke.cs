using System;
using System.Numerics;
using Tallow;

namespace Gameplay;

/// Generated-ABI smoke for the existing ECS-backed native Jolt character.
/// The fake host validates argument order; linked Jolt movement is tested separately.
[Component]
public sealed class CharacterControllerBindingSmoke : Script
{
    public override void Awake()
    {
        if (GetCharacterController() is not { } controller ||
            !controller.HasCharacter || !controller.IsGrounded || !controller.CanJump ||
            controller.Velocity != new Vector3(1, 2, 3))
            throw new InvalidOperationException("Native CharacterController state ABI failed.");

        if (!controller.Move(new Vector3(4, 5, 6), 0.02f) ||
            !controller.SimpleMove(new Vector3(7, 8, 9), 0.02f, 3f) ||
            !controller.Teleport(new Vector3(10, 11, 12), Vector3.Zero))
            throw new InvalidOperationException("Native CharacterController movement ABI failed.");

        if (controller.SimpleMove(Vector3.Zero, -1) ||
            controller.Teleport(new Vector3(float.NaN, 0, 0)))
            throw new InvalidOperationException("Invalid character motion should be rejected.");
    }
}
