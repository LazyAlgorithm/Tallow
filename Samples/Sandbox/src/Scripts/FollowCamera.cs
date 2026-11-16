using System.Numerics;
using Tallow;

namespace Sandbox;

/// <summary>Third-person camera behind the player this machine controls.</summary>
public class FollowCamera : Script
{
    public float Distance = 7.0f;
    public float Height = 2.5f;
    public string CameraName = "Main Camera";

    public override void LocalLateUpdate(float deltaTime)
    {
        if (!IsMine || Scene.Find(CameraName) is not { } camera)
            return;
        CharacterMotor motor = GetComponent<CharacterMotor>();
        Quaternion rotation = Quaternion.Euler(motor.Pitch + 15, motor.Yaw, 0);
        Vector3 target = Transform.Position + new Vector3(0, Height * 0.5f, 0);
        camera.Transform.Position = target - rotation * Vector3.Forward * Distance;
        camera.Transform.Rotation = rotation;
    }
}
