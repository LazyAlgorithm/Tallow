using System;

namespace Tallow;

/// The base class for game scripts: behaviour attached to a GameObject. It is a Component with nothing added, kept
/// as its own name because engine components (renderers, colliders, lights) move to data in the ECS while scripts
/// stay classes (docs/ecs-plan.md). Write Update for gameplay; the engine runs it per frame or, on an object with a
/// Network Identity, per network tick (Component.Update).
///
///   [Component]
///   class Spinner : Script
///   {
///       public float degreesPerSecond = 90;
///       public override void Update(TickInput input, float deltaTime)
///       {
///           Transform.Rotate(.(0, degreesPerSecond * deltaTime, 0));
///       }
///   }
[Component]
abstract class Script : Component
{
}
