using System;
using System.Numerics;
using Tallow;

namespace Gameplay;

/// In-process ABI test for generated ECS JointData and Jolt joint calls.
/// No managed physics solver or fake network replication is involved.
[Component]
public sealed class JointBindingSmoke : Script
{
    public override void Awake()
    {
        if (GetJoint() is not { } joint || !joint.IsConnected ||
            MathF.Abs(joint.SwingLimit - 30f) > 0.0001f ||
            joint.ConnectedTo is not { GameObject.Id: 42 })
            throw new InvalidOperationException("Native ECS joint handle information failed.");

        joint.SwingLimit = 45f;
        if (MathF.Abs(joint.SwingLimit - 45f) > 0.0001f)
            throw new InvalidOperationException("Native JointData swing limit change failed.");

        if (GetRigidbody() is not { } first)
            throw new InvalidOperationException("Expected a native Rigidbody handle.");

        Rigidbody second = new(new GameObject(GameObject.SceneId, 42));
        Joint? connected = Joint.Connect(first, second,
            new Vector3(1, 2, 3), Vector3.UnitY, 15f);
        if (connected is not { })
            throw new InvalidOperationException("Native Joint.Connect ABI marshalling failed.");

        if (Joint.Connect(first, first, Vector3.Zero, Vector3.UnitY) is not null)
            throw new InvalidOperationException("Self-joint should be rejected.");

        try
        {
            joint.SwingLimit = 200f;
            throw new InvalidOperationException("Invalid native joint swing limit was accepted.");
        }
        catch (ArgumentOutOfRangeException)
        {
            // Expected from the native setter.
        }
    }
}
