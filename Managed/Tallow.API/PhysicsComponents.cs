using System.Numerics;

namespace Tallow;

/// <summary>
/// Value handle to the existing native ECS-backed Rigidbody. No managed Jolt
/// simulation or native pointer is stored. Scene sessions are checked in Beef.
/// </summary>
public readonly record struct Rigidbody(GameObject GameObject)
{
    public bool IsValid => Physics.HasRigidbody(GameObject.SceneId, GameObject.Id);
    public bool HasBody => Physics.HasRigidbodyBody(GameObject.SceneId, GameObject.Id);
    public bool IsSleeping => Physics.IsRigidbodySleeping(GameObject.SceneId, GameObject.Id);
    public Vector3 Velocity
    {
        get => Physics.GetRigidbodyVelocity(GameObject.SceneId, GameObject.Id);
        set => Physics.SetRigidbodyVelocity(GameObject.SceneId, GameObject.Id, value);
    }
    public bool AddForce(Vector3 force) =>
        Physics.AddRigidbodyForce(GameObject.SceneId, GameObject.Id, force);
    public bool AddImpulse(Vector3 impulse) =>
        Physics.AddRigidbodyImpulse(GameObject.SceneId, GameObject.Id, impulse);
}

/// <summary>
/// Value handle to native SoftBody, including free cloth/jelly, dentable shells,
/// and rigidbody-driven jelly. No soft-body vertex buffer crosses into .NET.
/// </summary>
/// <summary>Matches the native SoftBodyKind modes, including Jelly Golf.</summary>
public enum SoftBodyKind { Cloth, Jelly, Shell, DrivenJelly }

public readonly record struct SoftBody(GameObject GameObject)
{
    public bool IsValid => Physics.HasSoftBody(GameObject.SceneId, GameObject.Id);
    public bool HasBody => Physics.HasSoftBodySimulation(GameObject.SceneId, GameObject.Id);
    public bool IsSleeping => Physics.IsSoftBodySleeping(GameObject.SceneId, GameObject.Id);
    public SoftBodyKind? Kind
    {
        get
        {
            int value = Physics.GetSoftBodyMode(GameObject.SceneId, GameObject.Id);
            return value is >= 0 and <= 3 ? (SoftBodyKind)value : null;
        }
    }
    public int SimulatedVertexCount =>
        Physics.GetSoftBodyVertexCount(GameObject.SceneId, GameObject.Id);
    public bool CanApplyForces => Physics.CanForceSoftBody(GameObject.SceneId, GameObject.Id);
    public Vector3 Velocity
    {
        get => Physics.GetSoftBodyVelocity(GameObject.SceneId, GameObject.Id);
        set => Physics.SetSoftBodyVelocity(GameObject.SceneId, GameObject.Id, value);
    }
    public float Pressure
    {
        get => Physics.GetSoftBodyPressure(GameObject.SceneId, GameObject.Id);
        set
        {
            if (!Physics.SetSoftBodyPressure(GameObject.SceneId, GameObject.Id, value))
                throw new InvalidOperationException("Cannot set soft-body pressure on this object.");
        }
    }
    public bool AddForce(Vector3 force) =>
        Physics.AddSoftBodyForce(GameObject.SceneId, GameObject.Id, force);
    public bool AddImpulse(Vector3 impulse) =>
        Physics.AddSoftBodyImpulse(GameObject.SceneId, GameObject.Id, impulse);
    public float DeepestDent => Physics.DeepestSoftBodyDent(GameObject.SceneId, GameObject.Id);
    public bool Repair() => Physics.RepairSoftBody(GameObject.SceneId, GameObject.Id);
}
