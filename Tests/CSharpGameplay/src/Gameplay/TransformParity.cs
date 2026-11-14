using Tallow;

namespace Gameplay;

/// <summary>
/// Exercises the same Transform member names as Beef gameplay scripts.
/// All parent/local/world calculations are handled by the native engine.
/// </summary>
[Component]
public sealed class TransformParity : Script
{
    public override void Awake()
    {
        Transform.LocalPosition = new Vector3(4, 5, 6);
        // Standard clamp uses .NET; the Tallow-specific helpers are generated from Beef.
        Transform.LocalScale = new Vector3(
            Math.Clamp(2f, 0f, 3f),
            Mathf.Lerp(2, 4, 0.5f),
            Mathf.MoveTowards(5, 4, 1));
        Transform.LocalEulerAngles = new Vector3(10, 20, 30);
        Transform.Rotation = Quaternion.Identity;
    }

    public override void Update(TickInput input, float deltaTime)
    {
        Transform.Translate(Transform.Right * 2f * deltaTime);
        Transform.LookAt(new Vector3(0, 0, 5));
    }
}
