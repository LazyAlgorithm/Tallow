using System.Numerics;
using Tallow;

namespace Sandbox;

/// <summary>
/// Picks the animation for a character from how it is moving: Idle, Walk, Run or Jump. Put it on the character
/// (the Animator can be on a child, the visual model). It only looks at how far the object moved each update, so
/// it works the same whether a Character Controller, a Rigidbody or the network moves it: for the local player and
/// for other players alike.
/// </summary>
public class CharacterAnimation : Script
{
    public float WalkSpeed = 0.4f;
    public float RunSpeed = 4.5f;
    public float AirSpeed = 1.6f;

    private Animator _animator;
    private Vector3 _lastPosition;
    private bool _moved;
    private float _airTime;

    public override void Start()
    {
        _animator = GameObject.GetComponentInChildren<Animator>();
        _lastPosition = Transform.Position;
    }

    public override void Update(TickInput input, float deltaTime)
    {
        if (!_animator.IsValid || deltaTime <= 0)
            return;
        Vector3 position = Transform.Position;
        Vector3 velocity = (position - _lastPosition) / deltaTime;
        _lastPosition = position;
        // The first update has nothing to compare with.
        if (!_moved)
        {
            _moved = true;
            return;
        }
        float ground = MathF.Sqrt(velocity.X * velocity.X + velocity.Z * velocity.Z);
        // A short delay stops slopes and steps from flickering into the jump pose.
        _airTime = MathF.Abs(velocity.Y) > AirSpeed ? _airTime + deltaTime : 0;
        if (_airTime > 0.12f)
            _animator.Play("Jump", 0.1f);
        else if (ground > RunSpeed)
            _animator.Play("Run", 0.18f);
        else if (ground > WalkSpeed)
            _animator.Play("Walk", 0.18f);
        else
            _animator.Play("Idle", 0.25f);
        // Match the stride to the actual speed so feet do not slide.
        _animator.Speed = _animator.CurrentClip switch
        {
            "Walk" => Math.Clamp(ground / 2.6f, 0.6f, 1.6f),
            "Run" => Math.Clamp(ground / 6.0f, 0.8f, 1.4f),
            _ => 1.0f,
        };
    }
}
