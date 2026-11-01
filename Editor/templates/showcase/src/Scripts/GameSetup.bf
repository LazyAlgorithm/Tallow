using System;
using Tallow;

namespace {NAMESPACE};

static class GameSetup
{
	public static void Register()
	{
		NetworkManager.RegisterPrefab("Visitor", new => CreateVisitor);
		NetworkManager.RegisterPrefab("ShowcaseImpactor", new => CreateImpactor);
		NetworkManager.RegisterMessage(230, new => Exhibition.OnTourRequest);
	}

	public static GameObject CreateVisitor(Scene scene)
	{
		let o = scene.CreateGameObject("Visitor");
		let spawn = scene.FindComponent<SpawnPoint>();
		o.Transform.Position = spawn != null ? spawn.Position : Vector3(0, 1, -31);
		let c = o.AddComponent<CharacterController>();
		c.radius = 0.34f;
		c.height = 1.8f;
		c.pushStrength = 180;
		c.canSwim = true;
		o.AddComponent<NetworkIdentity>();
		o.AddComponent<VisitorMotor>();
		let avatar = Prefab.Instantiate(scene, "Prefabs/character.tprefab");
		if (avatar != null)
		{
			avatar.Name.Set("Visitor character model");
			avatar.Transform.SetParent(o.Transform, false);
			avatar.Transform.LocalPosition = .(0, -0.9f, 0);
			let anim = avatar.GetComponent<Animator>();
			anim.controller.Set("Animations/character.tcontroller");
		}
		o.AddComponent<VisitorAvatar>();
		o.AddComponent<VisitorView>();
		return o;
	}
}
[Component]
class VisitorMotor : CharacterMotor
{
	int testTicks;
	public override void GatherInput(ref NetInput input)
	{
		base.GatherInput(ref input);
		if (Application.Instance.HasArg("--walk-test"))
		{
			testTicks++;
			input = default;
			input.moveZ = testTicks < 150 ? 1 : 0;
			input.SetButton(1, testTicks > 30 && testTicks < 70);
			input.SetButton(0, testTicks >= 80 && testTicks < 84);
		}
		if (Exhibition.Active?.Directory == true || Exhibition.Active?.Overview == true || Exhibition.Active?.document?.Enabled == true || Exhibition.Active?.talk?.View == .Choices || Exhibition.Active?.talk?.View == .Line)
		{
			input.moveX = 0;
			input.moveZ = 0;
			input.buttons = 0;
		}
	}

	public void Face(float yaw, float pitch = 0)
	{
		mYaw = yaw;
		mPitch = pitch;
	}
}
[Component]
class VisitorView : Component
{
	public override void LateUpdate()
	{
		let id = GetComponent<NetworkIdentity>();
		if (Scene.Network != null && Scene.Network.Mode != .Offline && !id.IsOwner) return;
		let w = Exhibition.Active;
		if (w == null || w.camera == null) return;
		w.visitor = GameObject;
		if (!w.Overview)
		{
			let motor = GetComponent<VisitorMotor>();
			w.camera.Transform.Position = Transform.Position + Vector3(0, 0.67f, 0);
			w.camera.Transform.Rotation = Quaternion.Euler(motor.Pitch, motor.Yaw, 0);
		}
	}
}

/// Configure before the base Awake starts the transport; dynamically added components awaken immediately.
[Component]
class TourSession : NetworkSession
{
	public override void Awake()
	{
		playerPrefab.Set("Visitor");
		optimizeSnapshots = true;
		losslessCompression = true;
		snapshotBytesPerSecond = 96000;
		base.Awake();
	}
}

[Component]
class VisitorAvatar : Component
{
	Animator animator;
	Vector3 last;
	float speed;
	bool hidden;
	bool initialized;
	public override void Start()
	{
		animator = GameObject.GetComponentInChildren<Animator>();
		last = Transform.Position;
	}

	public override void Update()
	{
		var delta = Transform.Position - last;
		delta.y = 0;
		last = Transform.Position;
		speed = Mathf.Lerp(speed, delta.Length / Math.Max(Time.DeltaTime, 0.001f), Math.Min(1, Time.DeltaTime * 12));
		animator?.SetFloat("speed", speed * 0.5f);
		animator?.SetBool("grounded", GetComponent<CharacterController>().IsGrounded);
	}

	public override void LateUpdate()
	{
		let id = GetComponent<NetworkIdentity>();
		let local = Scene.Network == null || Scene.Network.Mode == .Offline || id.IsOwner;
		if (!initialized || hidden != local)
		{
			initialized = true;
			hidden = local;
			Hide(Transform, local);
		}
	}

	void Hide(Transform root, bool local)
	{
		let renderer = root.GameObject.GetComponent<MeshRenderer>();
		if (renderer != null)
			renderer.shadowOnly = local;
		for (let child in root.Children)
			Hide(child, local);
	}
}
extension GameSetup
{
	public static GameObject CreateImpactor(Scene scene)
	{
		let o = scene.CreateGameObject("Heavy soft-body impactor");
		o.Transform.LocalScale = .(1.2f, 1.2f, 1.2f);
		o.AddComponent<MeshRenderer>().color = .(0.055f, 0.085f, 0.13f);
		o.AddComponent<BoxCollider>();
		o.AddComponent<Rigidbody>().mass = 200;
		o.AddComponent<NetworkIdentity>();
		o.AddComponent<ExhibitBody>().station = 6;
		return o;
	}
}
