using System;
using Tallow;

namespace Sandbox;

/// Picks the animation for a character from how it is moving: Idle, Walk, Run or Jump.
/// Put it on the object that has the CharacterController (or Rigidbody); the Animator can be on a child (the visual model).
/// It only looks at velocity, so it works the same for the local player and for other players.
[Component]
class CharacterAnimation : Script
{
	public float walkSpeed = 0.4f;
	public float runSpeed = 4.5f;
	public float airSpeed = 1.6f;

	Animator mAnimator;
	float mAirTime;

	public override void Start()
	{
		mAnimator = GameObject.GetComponentInChildren<Animator>();
	}

	public override void Update(TickInput input, float deltaTime)
	{
		// Works with a CharacterController, or with a Rigidbody on characters that still use one.
		let controller = GetComponent<CharacterController>();
		let body = GetComponent<Rigidbody>();
		if (mAnimator == null || (controller == null && (body == null || !body.HasBody)))
			return;
		let velocity = controller != null ? controller.Velocity : body.Velocity;
		let ground = Math.Sqrt(velocity.x * velocity.x + velocity.z * velocity.z);
		// A short delay stops slopes and steps from flickering into the jump pose.
		mAirTime = Math.Abs(velocity.y) > airSpeed ? mAirTime + Time.DeltaTime : 0;
		if (mAirTime > 0.12f)
			mAnimator.Play("Jump", 0.1f);
		else if (ground > runSpeed)
			mAnimator.Play("Run", 0.18f);
		else if (ground > walkSpeed)
			mAnimator.Play("Walk", 0.18f);
		else
			mAnimator.Play("Idle", 0.25f);
		// Match the stride to the actual speed so feet do not slide.
		let clip = mAnimator.CurrentClip;
		if (clip == "Walk")
			mAnimator.speed = Mathf.Clamp(ground / 2.6f, 0.6f, 1.6f);
		else if (clip == "Run")
			mAnimator.speed = Mathf.Clamp(ground / 6.0f, 0.8f, 1.4f);
		else
			mAnimator.speed = 1.0f;
	}
}
