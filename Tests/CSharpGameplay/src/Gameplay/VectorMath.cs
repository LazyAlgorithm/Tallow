using Tallow;

namespace Gameplay;

// No System.Numerics import: Tallow's managed game projects provide it globally.
[Component]
public sealed class VectorMath : Script
{
    public override void Update(TickInput input, float deltaTime)
    {
        Vector3 a = new(2, 4, 6);
        Vector3 b = new(3, 5, 7);
        Vector3 sum = a + b;
        Vector3 scaled = sum * 0.5f;
        Vector3 componentwise = a * b;
        Vector3 offset = scaled + componentwise - a;
        Transform.Position += offset * deltaTime;
    }
}
