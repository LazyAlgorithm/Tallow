using System;

namespace Tallow;

/// The controls for one tick, as the engine gathered them on the machine of the player who controls the object.
/// Everything a NetworkScript does must come from here, never from Input directly.
struct TickInput
{
	/// This tick's controls, as sent.
	public NetInput raw;
	/// The previous tick's controls, for telling a new press from a held key.
	public NetInput previous;

	/// Left/right and back/forward, each from -1 to 1 (WASD or the arrow keys).
	public Vector2 Move => .(raw.moveX, raw.moveZ);
	/// Where the player is looking, in degrees: turned with the mouse.
	public float Yaw => raw.yaw;
	/// How far up or down the player looks, in degrees.
	public float Pitch => raw.pitch;
	/// Move turned to face where the player looks: the direction to walk in, on the ground plane.
	public Vector3 MoveDirection
	{
		get
		{
			var direction = Quaternion.Euler(0, raw.yaw, 0) * Vector3(raw.moveX, 0, raw.moveZ);
			if (direction.LengthSquared > 1)
				direction = direction.Normalized;
			return direction;
		}
	}

	/// Which way the player looks.
	public Quaternion LookRotation => Quaternion.Euler(raw.pitch, raw.yaw, 0);

	/// Whether a button is held this tick.
	public bool Held(InputButton button) => raw.GetButton((int)button);
	/// True only on the tick the button went down.
	public bool Pressed(InputButton button) => raw.GetButton((int)button) && !previous.GetButton((int)button);
	/// Whether a button came up this tick.
	public bool Released(InputButton button) => !raw.GetButton((int)button) && previous.GetButton((int)button);

	/// Whether Jump is held.
	public bool Jump => Held(.Jump);
	/// Whether Sprint is held.
	public bool Sprint => Held(.Sprint);
	/// Whether Crouch is held.
	public bool Crouch => Held(.Crouch);
	/// Whether Fire is held.
	public bool Fire => Held(.Fire);
	/// Whether Use is held.
	public bool Use => Held(.Use);
}

/// The buttons every NetworkScript gets without setting anything up. Custom1 to Custom8 are free for the game:
/// set them in ReadInput.
enum InputButton : int32
{
	/// Space
	Jump,
	/// Left Shift
	Sprint,
	/// Left Control
	Crouch,
	/// Left mouse button
	Fire,
	/// E
	Use,
	/// R
	Reload,
	/// Q
	Ability1,
	/// F
	Ability2,
	Custom1, Custom2, Custom3, Custom4, Custom5, Custom6, Custom7, Custom8
}

/// Base class for anything a player controls. Write what happens in one tick and the engine does the networking:
///
///   [Component]
///   class Hover : NetworkScript
///   {
///       public float speed = 5;
///       public override void OnTick(TickInput input, float deltaTime)
///       {
///           Transform.Position += input.MoveDirection * speed * deltaTime;
///           if (input.Pressed(.Jump)) Transform.Position += .(0, 1, 0);
///       }
///   }
///
/// The engine reads the keyboard and mouse on the controlling player's machine, sends the controls to the server,
/// runs OnTick there and on that player's own machine at once (so there is no delay in their own view), and when
/// the two disagree puts the object back to the server's state and runs the missed ticks again. Other players see
/// the result. With no session it simply runs every tick with the local controls.
///
/// Rules that keep that working:
/// - Take controls only from the TickInput, never from Input: OnTick also runs on the server, and is run again
///   after a correction.
/// - Move the object through its Transform, Rigidbody or CharacterController. Their state is what gets corrected.
///   Other fields are not rewound; mark ones clients need to see with [Sync] and change them on the server.
/// - OnTick may run several times for one tick on the controlling machine. Things that must happen once, such as
///   playing a sound or spawning something, belong in an `if (IsServer)` or `if (!IsReplaying)` block.
///
/// The object needs a Network Identity; one is added when a session starts if it is missing.
[Component]
abstract class NetworkScript : NetworkBehaviour
{
	/// Turn the view with the mouse. Off for objects that do not look around.
	public bool mouseLook = true;
	/// Only turn while the right mouse button is held, leaving the cursor free otherwise.
	public bool holdRightMouseToLook = true;
	/// Degrees turned per pixel of mouse movement.
	public float mouseSensitivity = 0.15f;

	float mYaw;
	float mPitch;
	NetInput mPrevious;

	/// The view direction built up from the mouse on this machine.
	public float Yaw { get => mYaw; set => mYaw = value; }
	/// How far up or down this machine's player looks, in degrees (it is sent with the controls).
	public float Pitch { get => mPitch; set => mPitch = value; }
	/// True while a tick is being run again after a correction from the server.
	public bool IsReplaying => Scene.Network != null && Scene.Network.Replaying;

	/// What happens in one tick.
	public abstract void OnTick(TickInput input, float deltaTime);

	/// Add the game's own controls here: input.SetButton((int)InputButton.Custom1, Input.GetKey(.G)).
	/// Runs only on the machine of the player who controls the object.
	protected virtual void ReadInput(ref NetInput input) { }

	public override void GatherInput(ref NetInput input)
	{
		// From the project's input actions (Window > Input Actions): keyboard and mouse, or a controller.
		if (mouseLook && (!holdRightMouseToLook || Input.GetMouseButton(1) || InputActions.FromGamepad("Look")))
		{
			let look = InputActions.Delta("Look");
			mYaw += look.x * mouseSensitivity;
			mPitch = Mathf.Clamp(mPitch - look.y * mouseSensitivity, -85, 85);
		}
		let move = InputActions.Vector("Move");
		input.moveX = move.x;
		input.moveZ = move.y;
		input.yaw = mYaw;
		input.pitch = mPitch;
		input.SetButton((int)InputButton.Jump, InputActions.Held("Jump"));
		input.SetButton((int)InputButton.Sprint, InputActions.Held("Sprint"));
		input.SetButton((int)InputButton.Crouch, InputActions.Held("Crouch"));
		input.SetButton((int)InputButton.Fire, InputActions.Held("Fire"));
		input.SetButton((int)InputButton.Use, InputActions.Held("Use"));
		input.SetButton((int)InputButton.Reload, InputActions.Held("Reload"));
		input.SetButton((int)InputButton.Ability1, InputActions.Held("Ability1"));
		input.SetButton((int)InputButton.Ability2, InputActions.Held("Ability2"));
		ReadInput(ref input);
	}

	public override void FixedUpdate()
	{
		// Without a session nobody calls Simulate, so run it here with the local controls.
		if (Scene.Network == null || Scene.Network.Mode == .Offline)
		{
			NetInput input = default;
			GatherInput(ref input);
			Simulate(input, Time.FixedDeltaTime);
		}
	}

	public override void Simulate(NetInput input, float deltaTime)
	{
		TickInput tickInput;
		tickInput.raw = input;
		tickInput.previous = mPrevious;
		OnTick(tickInput, deltaTime);
		mPrevious = input;
	}
}
