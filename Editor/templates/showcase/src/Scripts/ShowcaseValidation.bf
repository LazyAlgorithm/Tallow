using System;
using Tallow;

namespace {NAMESPACE};

/// Optional end-to-end smoke harness, enabled only by the validation command line switches.
[Component]
class ShowcaseValidation : Component
{
	int frame, actions, savedExpected;
	bool netDone;
	int maxPeers;
	bool failed;
	float begun;
	Vector3 start;
	Quaternion firstArm;
	Transform animatedArm;
	public override void Start()
	{
		begun = Time.RealTime;
		animatedArm = FindBone(Exhibition.Active.skins[0].Transform, "RightArm");
		if (animatedArm != null)
			firstArm = animatedArm.LocalRotation;
		start = Exhibition.Active.visitor?.Transform.Position ?? Vector3.Zero;
	}

	Transform FindBone(Transform root, StringView name)
	{
		if (root.GameObject.Name == name) return root;
		for (let child in root.Children)
		{
			let found = FindBone(child, name);
			if (found != null) return found;
		}
		return null;
	}

	void Check(bool ok, StringView name)
	{
		Console.WriteLine(scope $"SHOWCASE_CHECK,{name},{ok}");
		if (!ok)
			failed = true;
	}

	public override void Update()
	{
		frame++;
		let w = Exhibition.Active;
		let app = Application.Instance;
		if (app.HasArg("--directory") && frame == 20)
			w.Directory = true;
		if (app.HasArg("--document") && frame == 20)
			w.document.Enabled = true;
		if (app.HasArg("--self-test"))
		{
			if (frame == 35)
			{
				Check(w.exhibits.Count == 24, "exhibit_count");
				Check(w.NavReady && w.FlightReady, "navigation_bakes");
				for (let soft in w.softs)
					Check(soft.HasBody, "softbody_created");
				for (let rope in w.ropes)
					Check(rope.HasBody, "rope_created");
				Check(w.skins.Count == 3 && w.skins[0].Model != null, "skinned_model_loaded");
				Check(w.behavior.TickCount > 0, "behavior_tree_running");
				Check(animatedArm != null && Math.Abs(Quaternion.Dot(firstArm, animatedArm.LocalRotation)) < 0.999f, "skeletal_animation_moves");
				Check((w.limb.tip.Position - w.limb.target.Position).Length < 0.08f, "ik_reaches_target");
			}
			if (frame >= 60 && (frame - 60) % 35 == 0 && actions < w.exhibits.Count)
			{
				let i = actions++;
				w.Travel(i);
				w.Use(i);
				Console.WriteLine(scope $"SHOWCASE_ACTION,{i},{w.exhibits[i].title}");
			}
			if (frame == 900)
			{
				savedExpected = w.savedVisits;
				w.savedVisits = -100;
				w.LoadVisit();
			}
			if (frame == 980)
			{
				Check(actions == 24, "all_exhibit_actions");
				Check(w.TileUpdates > 0, "tiled_navigation_update");
				Check(w.terrain.ChunkCount > 0, "terrain_loaded");
				Check(w.limb.tip != null && w.limb.target != null, "ik_configured");
				Check(SaveSystem.Exists("exhibition"), "save_written");
				Check(w.savedVisits == savedExpected, "save_loaded");
				for (let p in w.props)
				{
					let v = p.body.Transform.Position;
					Check(v.x.IsFinite && v.y.IsFinite && v.z.IsFinite, "finite_physics");
				}
				Check(w.visitor != null && w.visitor.Transform.Position.y > -10, "visitor_alive");
				Console.WriteLine(scope $"SHOWCASE_VALID,{!failed}");
				app.Running = false;
			}
		}
		if (app.HasArg("--net-smoke"))
		{
			let net = w.Scene.Network;
			let elapsed = Time.RealTime - begun;
			if (net != null && net.IsServer)
				maxPeers = Math.Max(maxPeers, net.ClientCount);
			if (net != null && net.IsServer && elapsed > 3)
				w.terminal.presses = 7;
			if (!netDone && net != null && elapsed > (net.IsServer ? 9 : 6))
			{
				netDone = true;
				Check(net.IsConnected, "session_connected");
				Check(net.IsServer ? maxPeers >= 1 : net.LocalClientId > 0, "tour_peers");
				Check(w.terminal.presses == 7, "console_replication");
				Check(net.Mode == .Server || w.visitor != null, "local_visitor");
				Console.WriteLine(scope $"SHOWCASE_NET,{net.Mode},{net.LocalClientId},{net.ClientCount},{net.Identities.Count}");
				Console.WriteLine(scope $"SHOWCASE_VALID,{!failed}");
				app.Running = false;
			}
		}
		if (app.HasArg("--walk-test") && Time.RealTime - begun > 4)
		{
			let distance = (w.visitor.Transform.Position - start).Length;
			Check(distance > 5, "walking_displacement");
			Check(w.visitor.GetComponent<CharacterController>().IsGrounded, "walking_grounded");
			Console.WriteLine(scope $"SHOWCASE_WALK,{distance},{w.visitor.Transform.Position}");
			Console.WriteLine(scope $"SHOWCASE_VALID,{!failed}");
			app.Running = false;
		}
	}
}
