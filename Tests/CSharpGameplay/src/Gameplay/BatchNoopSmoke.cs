using Tallow;

namespace Gameplay;

/// <summary>
/// A no-op lifecycle component for measuring the cost of crossing the
/// native/.NET boundary. Not intended as a game performance benchmark.
/// </summary>
[Component]
public sealed class BatchNoopSmoke : Script
{
    public override void FixedUpdate(float deltaTime) { }
}
