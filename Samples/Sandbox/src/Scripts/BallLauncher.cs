using System.Collections.Generic;
using System.Numerics;
using Tallow;

namespace Sandbox;

/// <summary>
/// Shoots heavy balls where the screen's middle points (press F): for knocking things over and denting shells. The
/// default ball (10 kg at 30 m/s) dents a 100 kg shell cube a good way in; lighter or slower ones barely mark it.
/// </summary>
public class BallLauncher : Script
{
    public KeyCode FireKey = KeyCode.F;
    /// <summary>How fast a ball leaves, in metres a second.</summary>
    public float Speed = 30;
    /// <summary>Each ball's weight in kilograms.</summary>
    public float Mass = 10;
    /// <summary>Each ball's diameter in metres.</summary>
    public float Size = 0.3f;
    /// <summary>How many balls stay in the world before the oldest goes.</summary>
    [Range(1, 100)]
    public int Keep = 20;
    public string CameraName = "Main Camera";

    // The balls out (one deleted by something else is no longer valid).
    private readonly List<GameObject> _balls = new();

    public override void LocalUpdate(float deltaTime)
    {
        if (IsMine && Input.GetKeyDown(FireKey))
            Fire();
    }

    /// <summary>Shoots one ball from just in front of this object towards what the middle of the screen points at.</summary>
    public void Fire()
    {
        if (Scene.Find(CameraName) is not { } camera)
            return;
        // What the screen's middle (straight ahead of the camera) points at, or far away along it, aimed at from in
        // front of the shooter.
        Vector3 eye = camera.Transform.Position, ahead = camera.Transform.Forward;
        Vector3 target = eye + ahead * 200;
        if (Scene.RaycastHit(eye, ahead, 200) is { } hit && hit.HitObject != GameObject)
            target = hit.Point;
        Vector3 from = Transform.Position + new Vector3(0, 0.5f, 0);
        Vector3 aim = Vector3.Normalize(target - from);
        from += aim * 1.2f;

        _balls.RemoveAll(ball => !ball.IsValid);
        while (_balls.Count >= Keep)
        {
            _balls[0].Destroy();
            _balls.RemoveAt(0);
        }
        GameObject made = Scene.CreateGameObject("Ball");
        made.Transform.Position = from;
        made.Transform.LocalScale = new Vector3(Size);
        MeshRenderer renderer = made.AddComponent<MeshRenderer>();
        renderer.Mesh = "builtin:sphere";
        renderer.Color = new Color(230 / 255f, 70 / 255f, 50 / 255f);
        renderer.FlatShading = false;
        made.AddComponent<SphereCollider>();
        Rigidbody body = made.AddComponent<Rigidbody>();
        body.Mass = Mass;
        // Fast and small: checked along its path each step, so it does not pass through thin things.
        body.ContinuousCollision = true;
        body.Velocity = aim * Speed;
        _balls.Add(made);
    }
}
