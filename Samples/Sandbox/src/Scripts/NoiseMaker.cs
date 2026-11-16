using Tallow;

namespace Sandbox;

/// <summary>Makes a noise every few seconds that behaviour trees' Heard Noise nodes pick up (a ringing alarm, a
/// rattling crate).</summary>
public class NoiseMaker : Script
{
    public float Interval = 6;
    /// <summary>How far away it is heard.</summary>
    public float Radius = 14;

    private float _next = 2;

    public override void Update(TickInput input, float deltaTime)
    {
        _next -= deltaTime;
        if (_next > 0)
            return;
        _next = Interval;
        AINoise.Make(Scene, Transform.Position, Radius, GameObject);
    }
}
