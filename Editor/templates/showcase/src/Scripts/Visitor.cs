using System.Numerics;
using Tallow;

namespace {NAMESPACE};

/// <summary>Walks and looks around the gallery with the keyboard and mouse. Esc frees the mouse.</summary>
public class Visitor : Script
{
    /// <summary>The camera that shows what the visitor sees.</summary>
    public GameObject? View { get; set; }
    public float WalkSpeed = 4.5f;
    public float RunSpeed = 8;
    public float JumpSpeed = 5.5f;
    public float Yaw;
    public float Pitch;

    public override void Start() => Cursor.Locked = true;

    public override void Update(TickInput input, float deltaTime)
    {
        if (Input.GetKeyDown(KeyCode.Escape))
            Cursor.Locked = !Cursor.Locked;
        Vector3 move = Vector3.Zero;
        if (Cursor.Locked)
        {
            Vector2 turn = Input.MouseDelta * 0.12f;
            Yaw += turn.X;
            Pitch = Math.Clamp(Pitch + turn.Y, -85, 85);
            float forward = (Input.GetKey(KeyCode.W) ? 1f : 0) - (Input.GetKey(KeyCode.S) ? 1f : 0);
            float right = (Input.GetKey(KeyCode.D) ? 1f : 0) - (Input.GetKey(KeyCode.A) ? 1f : 0);
            move = Quaternion.Euler(0, Yaw, 0) * new Vector3(right, 0, forward);
            if (move.LengthSquared() > 1)
                move = Vector3.Normalize(move);
            move *= Input.GetKey(KeyCode.LeftShift) ? RunSpeed : WalkSpeed;
        }
        GetComponent<CharacterController>().SimpleMove(move, Time.DeltaTime, Input.GetKey(KeyCode.Space) ? JumpSpeed : 0);
    }

    public override void LocalLateUpdate(float deltaTime)
    {
        if (View is not { } view)
            return;
        view.Transform.Position = Transform.Position + new Vector3(0, 0.7f, 0);
        view.Transform.Rotation = Quaternion.Euler(Pitch, Yaw, 0);
    }
}
