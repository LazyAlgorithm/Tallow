using System.Numerics;
using Tallow;

namespace Gameplay;

[Component]
public sealed class MoveRight : Script
{
    [Range(0, 20)]
    public float Speed = 4f;

    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Position += new Vector3(Speed * deltaTime, 0, 0);
    }
}
