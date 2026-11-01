using System;

namespace Tallow;

/// Ready-made networked character: WASD to move, Shift to sprint, mouse to turn, Space to jump.
/// Put it on an object with a CharacterController and a NetworkIdentity. The controller decides how the shape moves
/// through the world (steps, slopes, capsule or box); this decides what the player wants and keeps it in step over
/// the network. It works offline too, where it simply runs every tick with local input.
///
/// For a different kind of character, change the fields, or derive from this class and override WishVelocity (how
/// input becomes a direction and speed), GatherInput (which keys do what) or Simulate (everything).
/// Objects that still have a Rigidbody and no CharacterController are moved the old way, by setting body velocity.
[Component]
class CharacterMotor : NetworkBehaviour
{
	public float moveSpeed = 6.0f;
	/// Speed while Shift is held; set it to Move Speed to turn sprinting off.
	public float sprintSpeed = 9.0f;
	public float jumpSpeed = 6.5f;
	public float acceleration = 40.0f;
	/// Share of Acceleration available while in the air: 0 keeps the take-off velocity, 1 steers as on the ground.
	[Range(0, 1)] public float airControl = 0.35f;
	public float mouseSensitivity = 0.15f;
	/// Turn the object to face where the player looks. Turn off for characters that should keep their own facing.
	public bool faceLookDirection = true;

	protected float mYaw;
	protected float mPitch;

	public float Yaw => mYaw;
	public float Pitch => mPitch;

	public const int JumpButton = 0;
	public const int SprintButton = 1;

	public override void GatherInput(ref NetInput input)
	{
		// From the project's input actions: keyboard and mouse (hold the right button to turn), or a controller.
		if (Input.GetMouseButton(1) || InputActions.FromGamepad("Look"))
		{
			let look = InputActions.Delta("Look");
			mYaw += look.x * mouseSensitivity;
			mPitch = Mathf.Clamp(mPitch - look.y * mouseSensitivity, -80, 80);
		}
		let move = InputActions.Vector("Move");
		input.moveX = move.x;
		input.moveZ = move.y;
		input.yaw = mYaw;
		input.pitch = mPitch;
		input.SetButton(JumpButton, InputActions.Held("Jump"));
		input.SetButton(SprintButton, InputActions.Held("Sprint"));
	}

	public override void FixedUpdate()
	{
		// Without a network session nobody calls Simulate, so drive it from here.
		if (Scene.Network == null || Scene.Network.Mode == .Offline)
		{
			NetInput input = default;
			GatherInput(ref input);
			Simulate(input, Time.FixedDeltaTime);
		}
	}

	/// The horizontal velocity the player is asking for this tick.
	protected virtual Vector3 WishVelocity(NetInput input)
	{
		var wish = Quaternion.Euler(0, input.yaw, 0) * Vector3(input.moveX, 0, input.moveZ);
		if (wish.LengthSquared > 1)
			wish = wish.Normalized;
		return wish * (input.GetButton(SprintButton) ? Math.Max(sprintSpeed, moveSpeed) : moveSpeed);
	}

	public override void Simulate(NetInput input, float deltaTime)
	{
		let facing = Quaternion.Euler(0, input.yaw, 0);
		let target = WishVelocity(input);
		let controller = GetComponent<CharacterController>();
		if (controller != null)
		{
			// Speed is measured against the floor, so a moving platform carries the character without a fight.
			// CanJump also covers the ticks spent rolling over a step's edge, so control does not dip on stairs.
			let grounded = controller.CanJump;
			let carried = controller.IsGrounded ? controller.GroundVelocity : Vector3.Zero;
			let current = Vector3(controller.Velocity.x - carried.x, 0, controller.Velocity.z - carried.z);
			let horizontal = Vector3.MoveTowards(current, target, acceleration * (grounded ? 1 : airControl) * deltaTime);
			if (faceLookDirection)
				Transform.Rotation = facing;
			controller.SimpleMove(horizontal, deltaTime, input.GetButton(JumpButton) ? jumpSpeed : 0);
			return;
		}

		let body = GetComponent<Rigidbody>();
		if (body == null || !body.HasBody)
			return;
		var velocity = body.Velocity;
		let horizontal = Vector3.MoveTowards(.(velocity.x, 0, velocity.z), target, acceleration * deltaTime);
		velocity.x = horizontal.x;
		velocity.z = horizontal.z;

		if (input.GetButton(JumpButton) && Mathf.Abs(velocity.y) < 0.05f)
		{
			// Only jump when something is close under the feet.
			RaycastHit hit;
			let origin = Transform.Position;
			if (Scene.Physics.Raycast(origin + Vector3(0, -1.01f, 0), .Down, 0.25f, out hit))
				velocity.y = jumpSpeed;
		}
		body.Velocity = velocity;

		var state = body.State;
		if (faceLookDirection)
			state.rotation = facing;
		state.linearVelocity = velocity;
		state.angularVelocity = .Zero;
		body.SetState(state);
	}
}
