using System;

namespace Tallow;

/// Lightweight Rigidbody-driven jelly visuals. Put this on an uncollided mesh child of a
/// Rigidbody object. Only the child's local scale changes: no Jolt soft-body simulation,
/// gameplay collision change, or additional network synchronization is required.
[Component]
class JellyVisual : Component
{
	/// Stretch added for each metre/second of body movement.
	public float stretchPerSpeed = 0.015f;
	/// Largest movement-based stretch, as a fraction of the rest scale.
	public float maxStretch = 0.3f;
	/// How much sudden velocity changes make the surface wobble.
	public float kickPerSpeedChange = 0.08f;
	/// Maximum scale wobble on the Y axis.
	public float wobbleStrength = 0.18f;
	/// Oscillations per second in radians.
	public float wobbleFrequency = 16;
	/// How quickly the wobble settles.
	public float wobbleDamping = 5;

	[NonSerialized] Vector3 mRestScale;
	[NonSerialized] Vector3 mLastVelocity;
	[NonSerialized] float mWobble;
	[NonSerialized] float mPhase;
	[NonSerialized] bool mReady;

	Rigidbody Driver()
	{
		for (var up = Transform.Parent; up != null; up = up.Parent)
		{
			let body = up.GameObject.GetComponent<Rigidbody>();
			if (body.IsValid)
				return body;
		}
		return default;
	}

	public override void Start()
	{
		mRestScale = Transform.LocalScale;
		mReady = true;
		let driver = Driver();
		mLastVelocity = driver.IsValid && driver.HasBody ? driver.Velocity : .Zero;
		if (!driver.IsValid)
			Log.Warning(scope $"Jelly Visual on '{GameObject.Name}' needs a parent Rigidbody.");
		if (GetComponent<Collider>() != null)
			Log.Warning(scope $"Jelly Visual on '{GameObject.Name}' should be on a mesh child without a Collider.");
	}

	public override void Update(TickInput input, float deltaTime)
	{
		if (!mReady || deltaTime <= 0)
			return;
		let driver = Driver();
		if (!driver.IsValid || !driver.HasBody)
			return;

		let velocity = driver.Velocity;
		let change = (velocity - mLastVelocity).Length;
		mLastVelocity = velocity;
		mWobble = Math.Min(1.0f, mWobble + change * Math.Max(0.0f, kickPerSpeedChange));
		mWobble *= Math.Max(0.0f, 1.0f - Math.Max(0.0f, wobbleDamping) * deltaTime);
		mPhase += deltaTime * Math.Max(0.0f, wobbleFrequency);

		let stretch = Math.Min(Math.Max(0.0f, maxStretch), velocity.Length * Math.Max(0.0f, stretchPerSpeed));
		let wobble = (float)Math.Sin(mPhase) * mWobble * Math.Max(0.0f, wobbleStrength);
		Transform.LocalScale = .(
			mRestScale.x * (1.0f + stretch),
			mRestScale.y * Math.Max(0.2f, 1.0f - stretch * 0.6f - wobble),
			mRestScale.z * Math.Max(0.2f, 1.0f + stretch * 0.5f + wobble * 0.5f));
	}

	public override void OnDisable()
	{
		if (mReady)
			Transform.LocalScale = mRestScale;
		mWobble = 0;
	}

	public override void OnDestroy()
	{
		if (mReady)
			Transform.LocalScale = mRestScale;
	}
}
