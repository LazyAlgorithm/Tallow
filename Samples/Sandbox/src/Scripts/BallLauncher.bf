using System;
using System.Collections;
using Tallow;

namespace Sandbox;

/// Shoots heavy balls where the screen's middle points (press F): for knocking things over and denting shells. The
/// default ball (10 kg at 30 m/s) dents a 100 kg shell cube a good way in; lighter or slower ones barely mark it.
[Component]
class BallLauncher : Script
{
	public KeyCode fireKey = .F;
	/// How fast a ball leaves, in metres a second.
	public float speed = 30;
	/// Each ball's weight in kilograms.
	public float mass = 10;
	/// Each ball's diameter in metres.
	public float size = 0.3f;
	/// How many balls stay in the world before the oldest goes.
	[Range(1, 100)]
	public int32 keep = 20;

	// The balls out, by id (one deleted by something else is simply no longer found).
	List<uint32> mBalls = new .() ~ delete _;

	public override void Update(TickInput input, float deltaTime)
	{
		let identity = GetComponent<NetworkIdentity>();
		if (identity != null && Scene.Network != null && !identity.IsOwner)
			return;
		if (Input.GetKeyDown(fireKey))
			Fire();
	}

	/// Shoots one ball from just in front of this object towards what the middle of the screen points at.
	public void Fire()
	{
		let camera = Scene.FindComponent<Camera>();
		if (camera == null)
			return;
		// What the screen's middle (straight ahead of the camera) points at, or far away along it, aimed at from in
		// front of the shooter.
		let eye = camera.Transform.Position;
		let ahead = camera.Transform.Forward;
		var target = eye + ahead * 200;
		RaycastHit hit;
		if (Scene.Physics.Raycast(eye, ahead, 200, out hit) && hit.gameObject != GameObject)
			target = hit.point;
		var from = Transform.Position + Vector3(0, 0.5f, 0);
		let aim = (target - from).Normalized;
		from = from + aim * 1.2f;

		mBalls.RemoveAll(scope (id) => Scene.FindById(id) == null);
		while (mBalls.Count >= keep)
		{
			Scene.Destroy(Scene.FindById(mBalls[0]));
			mBalls.RemoveAt(0);
		}
		let ball = Scene.CreateGameObject("Ball");
		ball.Transform.Position = from;
		ball.Transform.LocalScale = .(size, size, size);
		let renderer = ball.AddComponent<MeshRenderer>();
		renderer.mesh.Set("builtin:sphere");
		renderer.color = .FromBytes(230, 70, 50);
		renderer.flatShading = false;
		ball.AddComponent<SphereCollider>();
		let body = ball.AddComponent<Rigidbody>();
		body.mass = mass;
		// Fast and small: checked along its path each step, so it does not pass through thin things.
		body.continuousCollision = true;
		body.EnsureBody();
		body.Velocity = aim * speed;
		mBalls.Add(ball.Id);
	}
}
