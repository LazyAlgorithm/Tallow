using System;
using Tallow;

namespace {NAMESPACE};

/// Optional integration checks for the authored scene and cooperative tour.
[Component]
class CooperativeValidation : Component
{
	float start;
	int stage;
	bool failed, done;
	int maxPeers, maxVisible;
	public override void Start()
	{
		start = Time.RealTime;
	}

	void Check(bool pass, StringView name)
	{
		Console.WriteLine(scope $"COOP_CHECK,{name},{pass}");
		if (!pass)
			failed = true;
	}

	public override void Update()
	{
		let app = Application.Instance;
		let w = Exhibition.Active;
		let elapsed = Time.RealTime - start;
		if (app.HasArg("--edit-probe") && elapsed > 1 && !done)
		{
			done = true;
			let o = Scene.Find("Edit persistence probe");
			Check(o != null && (o.Transform.LocalPosition - Vector3(1.25f, 3, 2)).Length < 0.001f, "edited_transform_preserved");
			Check(o != null && Math.Abs(o.GetComponent<MeshRenderer>().color.r - 0.123f) < 0.0001f, "edited_colour_preserved");
			Check(w.exhibits.Count == 24, "single_authored_layout");
			Console.WriteLine(scope $"COOP_VALID,{!failed}");
			app.Running = false;
			return;
		}
		if (!app.HasArg("--tour-test")) return;
		let net = Scene.Network;
		if (net == null) return;
		maxPeers = Math.Max(maxPeers, net.ClientCount);
		int visibleNow = 0;
		for (let c in Scene.ComponentsOfType(typeof(VisitorAvatar)))
		{
			let a = (VisitorAvatar)c;
			let id = a.GetComponent<NetworkIdentity>();
			let r = a.GameObject.GetComponentInChildren<MeshRenderer>();
			if (id != null && !id.IsOwner && r != null && !r.shadowOnly)
				visibleNow++;
		}
		maxVisible = Math.Max(maxVisible, visibleNow);
		let observer = app.HasArg("--observer");
		if (!net.IsServer && !observer)
		{
			if (stage == 0 && elapsed > 2)
			{
				stage++;
				w.Travel(18);
			}
			else if (stage == 1 && elapsed > 3.5f)
			{
				stage++;
				w.Use(18);
			}
			else if (stage == 2 && elapsed > 4.5f)
			{
				stage++;
				w.Travel(11);
			}
			else if (stage == 3 && elapsed > 6)
			{
				stage++;
				w.Use(11);
			}
			else if (stage == 4 && elapsed > 7)
			{
				stage++;
				w.Travel(6);
			}
			else if (stage == 5 && elapsed > 8.5f)
			{
				stage++;
				w.Use(6);
			}
			else if (stage == 6 && elapsed > 9.5f)
			{
				stage++;
				w.Travel(8);
			}
			else if (stage == 7 && elapsed > 11)
			{
				stage++;
				w.Use(8);
			}
			else if (stage == 8 && elapsed > 12)
			{
				stage++;
				w.Travel(3);
			}
			else if (stage == 9 && elapsed > 13.5f)
			{
				stage++;
				w.Use(3);
			}
		}
		let end = net.IsServer ? 21f : observer ? 4.5f : 16f;
		if (elapsed > end && !done)
		{
			done = true;
			Check(net.IsConnected, "connected");
			Check(net.IsServer ? maxPeers >= 2 : net.LocalClientId > 0, "joined_tour");
			Check(w.terminal.presses == 1, "client_console_action");
			Check(w.pool.look == .LowPoly, "shared_water_look");
			Check(!w.GateClosed, "shared_gate");
			Check(w.decalMode == 1, "shared_decal");
			Check(Scene.Find("Heavy soft-body impactor") != null, "network_spawned_impactor");
			int loaded = 0;
			for (let rope in w.ropes)
			{
				if (w.StationOf(rope.GameObject) == 7 && rope.endAttachedTo != null && rope.endAttachedTo.GameObject.GetComponent<Rigidbody>() != null && rope.HasBody)
					loaded++;
			}
			Check(loaded == 4, "all_exhibit_ropes_loaded");
			int visible = 0;
			for (let c in Scene.ComponentsOfType(typeof(VisitorAvatar)))
			{
				let a = (VisitorAvatar)c;
				let id = a.GetComponent<NetworkIdentity>();
				let r = a.GameObject.GetComponentInChildren<MeshRenderer>();
				if (id != null && !id.IsOwner && r != null && !r.shadowOnly)
					visible++;
			}
			Check(maxVisible >= 1, "other_players_have_visible_models");
			Console.WriteLine(scope $"COOP_VISITORS,{visible}");
			Console.WriteLine(scope $"COOP_VALID,{!failed}");
			app.Running = false;
		}
	}
}
