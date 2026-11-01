using System;

namespace Tallow;

/// Moves a first-person viewmodel: put it on the object that holds the arms and weapon (a child of the camera, on the
/// Camera's Viewmodel Layer). It carries the weapon from a hip pose to an aim pose (aiming down the sights: in the
/// middle of the screen, the sights on the crosshair), bobs it as the player walks and lets it lag a little behind
/// when the view turns, worked out from how the camera moves, so the only code a game needs is setting Aiming and,
/// for recoil, calling Kick. See docs/viewmodel.md.
///
/// In the editor, Preview shows the pose part way from hip to aim while not playing, and the Inspector's buttons take
/// the object's current place as the hip or the aim pose: move it until it looks right in the Game view, then press.
[Component]
class ViewmodelPose : Component
{
	/// Where the weapon rests (the object's local position and rotation, in degrees, under the camera).
	public Vector3 hipPosition = .(0.12f, -0.12f, 0.28f);
	public Vector3 hipRotation = .(0, -2, 0);
	/// Where it is when aiming down the sights: in the middle, low enough that the sights meet the crosshair.
	public Vector3 aimPosition = .(0, -0.05f, 0.24f);
	public Vector3 aimRotation = .Zero;
	/// Set by the game while the player aims down the sights.
	public bool aiming;
	/// How quickly the weapon comes up to aim and goes back: the whole way in 1 / Aim Speed seconds.
	[Range(1, 40)]
	public float aimSpeed = 8;

	/// Walk bob at full speed: side to side (x) and up and down (y), in metres.
	public Vector2 bob = .(0.012f, 0.014f);
	/// The camera's speed over the ground, in metres a second, that gives the full bob.
	public float bobFullSpeed = 5;
	/// Metres walked for each bob from side to side and back (two steps).
	public float bobStride = 1.6f;
	/// Sway: degrees the weapon lags behind for each 100 degrees a second the view turns, up to Sway Limit.
	public float sway = 2.5f;
	[Range(0, 30)]
	public float swayLimit = 6;
	/// How much of the bob and sway aiming takes away (1: all of it).
	[Range(0, 1)]
	public float aimSteadiness = 0.8f;

	/// Recoil from Kick: how far one kick pushes the weapon back (metres) and tips its muzzle up (degrees), and how
	/// quickly it recovers (the whole way in 1 / Recoil Recovery seconds).
	public float recoilBack = 0.03f;
	public float recoilPitch = 5;
	[Range(1, 40)]
	public float recoilRecovery = 10;

	/// Edit mode only: shows the pose this far from hip (0) to aim (1), to line the two up in the Game view.
	[Range(0, 1)]
	public float preview;

	/// How far the weapon is raised to aim, 0 (hip) to 1 (aimed), after easing: for a game to narrow its field of
	/// view or show a scope in step with it.
	public float AimBlend => Ease(mAim);

	float mAim, mStride, mSpeed, mKick;
	Vector2 mSway;
	Vector3 mLastPosition;
	Quaternion mLastRotation;
	bool mHasLast;

	static float Ease(float t) => t * t * (3 - 2 * t);

	/// Recoil: the weapon jumps back and its muzzle up by `amount` kicks (1 is one shot of an ordinary weapon), and
	/// settles back by itself.
	public void Kick(float amount = 1)
	{
		mKick = Math.Min(mKick + Math.Max(amount, 0), 3);
	}

	public override void OnValidate()
	{
		// While editing, show the preview pose straight away.
		if (Scene != null && !Scene.IsPlaying)
			Apply(Ease(Mathf.Clamp01(preview)), .Zero, .Zero, 0);
	}

	public override void OnEnable()
	{
		mHasLast = false;
	}

	public override void LateUpdate()
	{
		let camera = Transform.Parent;
		if (camera == null)
			return;
		let dt = Time.DeltaTime;
		if (dt <= 0)
			return;
		mAim = Mathf.MoveTowards(mAim, aiming ? 1 : 0, dt * aimSpeed);
		let aimed = Ease(mAim);
		let steadiness = 1 - Mathf.Clamp01(aimSteadiness) * aimed;

		// How the camera moved since the last frame: over the ground for the bob, around for the sway.
		let position = camera.Position;
		let rotation = camera.Rotation;
		Vector2 turn = .Zero;
		if (mHasLast)
		{
			let moved = position - mLastPosition;
			let ground = Math.Sqrt(moved.x * moved.x + moved.z * moved.z);
			// A teleport (respawning) is not a stride.
			if (ground < 2)
			{
				mSpeed = Mathf.Lerp(mSpeed, ground / dt, Math.Min(dt * 10, 1));
				mStride += ground / Math.Max(bobStride, 0.1f) * Math.PI_f * 2;
			}
			let before = mLastRotation.EulerAngles;
			let after = rotation.EulerAngles;
			turn = .(Mathf.WrapAngle(after.x - before.x) / dt, Mathf.WrapAngle(after.y - before.y) / dt);
		}
		mLastPosition = position;
		mLastRotation = rotation;
		mHasLast = true;

		let walking = Mathf.Clamp01(mSpeed / Math.Max(bobFullSpeed, 0.1f));
		let bobOffset = Vector3(Math.Cos(mStride) * bob.x, -Math.Abs(Math.Sin(mStride)) * bob.y, 0) * walking * steadiness;
		let limit = swayLimit;
		let target = Vector2(Mathf.Clamp(-turn.x * sway / 100, -limit, limit), Mathf.Clamp(-turn.y * sway / 100, -limit, limit));
		let follow = Math.Min(dt * 10, 1);
		mSway = mSway + (target - mSway) * follow;
		mKick = Mathf.MoveTowards(mKick, 0, dt * recoilRecovery * Math.Max(mKick, 0.3f));
		Apply(aimed, bobOffset, Vector3(mSway.x, mSway.y, mSway.y * 0.5f) * steadiness, mKick);
	}

	void Apply(float aimed, Vector3 offset, Vector3 swayDegrees, float kick)
	{
		var position = Vector3.Lerp(hipPosition, aimPosition, aimed) + offset;
		var rotation = Vector3.Lerp(hipRotation, aimRotation, aimed) + swayDegrees;
		position.z -= kick * recoilBack;
		rotation.x -= kick * recoilPitch;
		Transform.LocalPosition = position;
		Transform.LocalRotation = Quaternion.Euler(rotation);
	}

	/// Takes the object's current place under the camera as the hip pose (the Inspector's button).
	public void UseCurrentAsHip()
	{
		hipPosition = Transform.LocalPosition;
		hipRotation = Transform.LocalRotation.EulerAngles;
	}

	/// Takes the object's current place under the camera as the aim pose (the Inspector's button).
	public void UseCurrentAsAim()
	{
		aimPosition = Transform.LocalPosition;
		aimRotation = Transform.LocalRotation.EulerAngles;
	}
}
