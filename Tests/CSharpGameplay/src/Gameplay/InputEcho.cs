using System.Numerics;
using Tallow;

namespace Gameplay;

/// <summary>Verifies that native tick input and button edges survive managed interop.</summary>
[Component]
public sealed class InputEcho : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Position += input.MoveDirection * deltaTime;
        if (input.Pressed(InputButton.Jump))
            Transform.Position += new Vector3(0, 5, 0);
    }
}
