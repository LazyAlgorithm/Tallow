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
        // These helpers use the same names/semantics as the Beef Mathf API.
        Transform.LocalScale = new Vector3(
            Mathf.Clamp(2, 0, 3),
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
