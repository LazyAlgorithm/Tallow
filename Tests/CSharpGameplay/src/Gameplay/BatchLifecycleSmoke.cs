using System.Numerics;
using Tallow;

namespace Gameplay;

[Component]
public sealed class BatchLifecycleSmoke : Script
{
    public override void FixedUpdate(float deltaTime) =>
        Transform.Position += Vector3.UnitX * deltaTime;

    public override void LateUpdate(float deltaTime) =>
        Transform.Position += Vector3.UnitY * deltaTime;
}
