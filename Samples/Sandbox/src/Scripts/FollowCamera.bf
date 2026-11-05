using System;
using Tallow;

namespace Sandbox;

/// Third-person camera for the object this client controls.
[Component]
class FollowCamera : Script
{
	public float distance = 7.0f;
	public float height = 2.5f;

	public override void LateUpdate()
	{
		let identity = GetComponent<NetworkIdentity>();
		if (identity != null && Scene.Network != null && !identity.IsOwner)
			return;
		let camera = Scene.FindComponent<Camera>();
		let motor = GetComponent<CharacterMotor>();
		if (camera == null)
			return;
		let yaw = motor != null ? motor.Yaw : 0;
		let pitch = motor != null ? motor.Pitch : 0;
		let rotation = Quaternion.Euler(pitch + 15, yaw, 0);
		let target = Transform.Position + Vector3(0, height * 0.5f, 0);
		camera.Transform.Position = target - rotation * Vector3.Forward * distance;
		camera.Transform.Rotation = rotation;
	}
}
