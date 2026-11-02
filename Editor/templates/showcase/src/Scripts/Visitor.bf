using System;
using Tallow;

namespace {NAMESPACE};

/// Walking round the gallery: WASD, the mouse to look, Shift to hurry, Space to jump, Escape to free the mouse.
[Component]
class Visitor : Component
{
	public Camera view;
	public float walkSpeed = 4.5f;
	public float runSpeed = 8;
	public float jumpSpeed = 5.5f;
	public float yaw;
	public float pitch;

	CharacterController mBody;

	public override void Start()
	{
		mBody = GetComponent<CharacterController>();
		Input.LockCursor = true;
	}

	public override void Update()
	{
		if (Input.GetKeyDown(.Escape))
			Input.LockCursor = !Input.LockCursor;
		if (Input.LockCursor)
		{
			let turn = Input.MouseDelta * 0.12f;
			yaw += turn.x;
			pitch = Math.Clamp(pitch + turn.y, -85, 85);
		}
		var move = Vector3.Zero;
		if (Input.LockCursor)
		{
			let flat = Quaternion.Euler(0, yaw, 0);
			let forward = (Input.GetKey(.W) ? 1.0f : 0) - (Input.GetKey(.S) ? 1.0f : 0);
			let right = (Input.GetKey(.D) ? 1.0f : 0) - (Input.GetKey(.A) ? 1.0f : 0);
			move = flat * Vector3(right, 0, forward);
			if (move.LengthSquared > 1)
				move = move.Normalized;
			move *= Input.GetKey(.LeftShift) ? runSpeed : walkSpeed;
		}
		mBody.SimpleMove(move, Time.DeltaTime, Input.GetKey(.Space) ? jumpSpeed : 0);
	}

	public override void LateUpdate()
	{
		view.Transform.Position = Transform.Position + Vector3(0, 0.7f, 0);
		view.Transform.Rotation = Quaternion.Euler(pitch, yaw, 0);
	}
}
