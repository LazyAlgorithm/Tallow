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

/// Reads this machine's controls into a NetInput: the project's input actions (Window > Input Actions), keyboard
/// and mouse or a controller. Used for every Update that gets local controls, and by NetworkScript.
static class LocalControls
{
	/// The look direction built up from the mouse, for objects with no NetworkScript of their own.
	public static float Yaw;
	public static float Pitch;
	/// Whether the look direction (Update's Yaw, Pitch and Look Rotation) only turns while the right mouse button is
	/// held. Off by default: the mouse always turns it (lock the mouse to keep the cursor in the window).
	public static bool HoldRightMouseToLook = false;

	public static void Read(ref NetInput input)
	{
		Read(ref input, ref Yaw, ref Pitch, true, HoldRightMouseToLook);
	}

	public static void Read(ref NetInput input, ref float yaw, ref float pitch, bool mouseLook = true, bool holdRightMouseToLook = false, float sensitivity = 0.15f)
	{
		if (mouseLook && (!holdRightMouseToLook || Input.GetMouseButton(1) || InputActions.FromGamepad("Look")))
		{
			let look = InputActions.Delta("Look");
			yaw += look.x * sensitivity;
			pitch = Mathf.Clamp(pitch - look.y * sensitivity, -85, 85);
		}
		let move = InputActions.Vector("Move");
		input.moveX = move.x;
		input.moveZ = move.y;
		input.yaw = yaw;
		input.pitch = pitch;
		input.SetButton((int)InputButton.Jump, InputActions.Held("Jump"));
		input.SetButton((int)InputButton.Sprint, InputActions.Held("Sprint"));
		input.SetButton((int)InputButton.Crouch, InputActions.Held("Crouch"));
		input.SetButton((int)InputButton.Fire, InputActions.Held("Fire"));
		input.SetButton((int)InputButton.Use, InputActions.Held("Use"));
		input.SetButton((int)InputButton.Reload, InputActions.Held("Reload"));
		input.SetButton((int)InputButton.Ability1, InputActions.Held("Ability1"));
		input.SetButton((int)InputButton.Ability2, InputActions.Held("Ability2"));
	}
}

/// Base class for anything a player controls, with its own mouse-look settings and extra controls (ReadInput).
/// Write what happens in one step in Update and the engine does the networking:
///
///   [Component]
///   class Hover : NetworkScript
///   {
///       public float speed = 5;
///       public override void Update(TickInput input, float deltaTime)
///       {
///           Transform.Position += input.MoveDirection * speed * deltaTime;
///           if (input.Pressed(.Jump)) Transform.Position += .(0, 1, 0);
///       }
///   }
///
/// Any component's Update works this way on an object with a Network Identity (Component.Update); a Network Script
/// makes sure the object has one. The engine reads the controls on the controlling player's machine, sends them to
/// the server, runs Update there and on that player's own machine at once (so there is no delay in their own
/// view), and when the two disagree puts the object back to the server's state and runs the missed ticks again.
/// Other players see the result. With no session it simply runs every tick with the local controls.
///
/// Rules that keep that working:
/// - Take controls only from the TickInput, never from Input: Update also runs on the server, and is run again
///   after a correction.
/// - Move the object through its Transform, Rigidbody or CharacterController. Their state is what gets corrected.
///   Other fields are not rewound; mark ones clients need to see with [Sync] and change them on the server.
/// - Update may run several times for one tick on the controlling machine. Things that must happen once, such as
///   playing a sound or spawning something, belong in an `if (IsServer)` or `if (!IsReplaying)` block, or in
///   OnLocalUpdate.
[Component]
abstract class NetworkScript : NetworkBehaviour
{
	/// Turn the view with the mouse. Off for objects that do not look around.
	public bool mouseLook = true;
	/// Only turn while the right mouse button is held, leaving the cursor free otherwise (off: the mouse always turns).
	public bool holdRightMouseToLook = false;
	/// Degrees turned per pixel of mouse movement.
	public float mouseSensitivity = 0.15f;

	float mYaw;
	float mPitch;

	/// The view direction built up from the mouse on this machine.
	public float Yaw { get => mYaw; set => mYaw = value; }
	/// How far up or down this machine's player looks, in degrees (it is sent with the controls).
	public float Pitch { get => mPitch; set => mPitch = value; }
	/// True while a tick is being run again after a correction from the server.
	public bool IsReplaying => Scene.Network != null && Scene.Network.Replaying;

	/// Add the game's own controls here: input.SetButton((int)InputButton.Custom1, Input.GetKey(.G)).
	/// Runs only on the machine of the player who controls the object.
	protected virtual void ReadInput(ref NetInput input) { }

	public override void Awake()
	{
		// Update runs per tick, networked, only on objects with an identity.
		if (!GetComponent<NetworkIdentity>().IsValid)
			GameObject.AddComponent<NetworkIdentity>();
	}

	public override void GatherInput(ref NetInput input)
	{
		LocalControls.Read(ref input, ref mYaw, ref mPitch, mouseLook, holdRightMouseToLook, mouseSensitivity);
		ReadInput(ref input);
	}
}
