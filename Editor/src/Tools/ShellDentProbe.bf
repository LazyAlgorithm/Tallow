using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Measures how a shell dents when hit on a face, an edge and a corner, so backends can be compared and the dent
/// shape checked without looking at it. Loads a scene with a FromImpacts shell (the Gallery's "Blue shell" by
/// default), fires a 55 kg ball at 30 m/s straight into each spot (a fresh scene each time; the face a second time
/// with three hits in one place) and reports, from the
/// shell's dents in its own space: how many vertices moved, the deepest dent and how far it is from the aim point,
/// how deep the aimed-at vertex itself went along the hit, how well dent directions follow the hit, and how many
/// dented vertices sit well behind the struck surface (other panels moved by a hit they did not take).
/// Run with: TallowLauncher --test-shell-dents <scene.tscene> <Jolt|Rapier> [shell name]
static class ShellDentProbe
{
	public static int Run(StringView scenePath, StringView backend, StringView shellName)
	{
		PhysicsBackends.Override3D(backend);
		let project = scope String(scenePath);
		let scenesAt = project.IndexOf("/Scenes/");
		if (scenesAt <= 0)
			return 1;
		project.RemoveFromEnd(project.Length - scenesAt);
		Assets.ProjectPath.Set(project);

		// The last case hits the face three times in the same place: repeated hits should keep deepening a dent.
		StringView[4] cases = .("face", "edge", "corner", "face x3");
		Vector3[4] outward = .(.(0, 1, 0), Vector3(0, 1, 1).Normalized, Vector3(1, 1, 1).Normalized, .(0, 1, 0));
		int[4] hits = .(1, 1, 1, 3);
		for (int c < 4)
		{
			let scene = scope Scene();
			if (!SceneSerializer.LoadFromFile(scene, scenePath))
				return 1;
			let shell = scene.Find(shellName);
			let soft = shell?.GetComponent<SoftBody>();
			if (soft == null)
				return 1;
			scene.StartPlay();
			for (int i < 120)
			{
				scene.FixedUpdate();
				scene.Update();
			}
			if (!soft.HasBody || soft.Positions.Count == 0)
				return 1;

			// The shell's vertices in its own space, and their bounds.
			let local = scope List<Vector3>();
			var low = Vector3(float.MaxValue), high = Vector3(float.MinValue);
			for (let p in soft.Positions)
			{
				let q = shell.Transform.InverseTransformPoint(p);
				local.Add(q);
				low = Vector3(Math.Min(low.x, q.x), Math.Min(low.y, q.y), Math.Min(low.z, q.z));
				high = Vector3(Math.Max(high.x, q.x), Math.Max(high.y, q.y), Math.Max(high.z, q.z));
			}
			let mid = (low + high) * 0.5f;
			Vector3[4] spots = .(.(mid.x, high.y, mid.z), .(mid.x, high.y, high.z), .(high.x, high.y, high.z), .(mid.x, high.y, mid.z));
			int aim = 0;
			float nearest = float.MaxValue;
			for (int i < local.Count)
			{
				let d = (local[i] - spots[c]).LengthSquared;
				if (d < nearest)
				{
					nearest = d;
					aim = i;
				}
			}
			let dirOut = outward[c];
			let aimWorld = shell.Transform.TransformPoint(local[aim]);
			let outWorld = (shell.Transform.TransformPoint(local[aim] + dirOut) - aimWorld).Normalized;

			for (int h < hits[c])
			{
				let ball = scene.CreateGameObject("Dent probe ball");
				ball.Transform.Position = aimWorld + outWorld * 1.2f;
				ShapeDesc sphere = default;
				sphere.kind = .Sphere;
				sphere.radius = 0.22f;
				RigidbodyData data = .();
				data.mass = 55;
				let body = scene.Physics.CreateBody(ball.Transform, sphere, &data);
				scene.Physics.SetLinearVelocity(body, -outWorld * 30);
				for (int i < 60)
				{
					scene.FixedUpdate();
					scene.Update();
				}
				scene.Physics.DestroyBody(body);
			}

			let dents = scope List<Vector3>();
			soft.GetDents(dents);
			int dented = 0, behind = 0;
			float deepest = 0, deepestFromAim = 0, spread = 0, cosSum = 0;
			for (int i < Math.Min(dents.Count, local.Count))
			{
				let d = dents[i];
				let depth = d.Length;
				if (depth < 0.01f)
					continue;
				dented++;
				let fromAim = (local[i] - local[aim]).Length;
				spread = Math.Max(spread, fromAim);
				cosSum += Vector3.Dot(d / depth, -dirOut);
				if (Vector3.Dot(local[i] - local[aim], dirOut) < -0.3f)
					behind++;
				if (depth > deepest)
				{
					deepest = depth;
					deepestFromAim = fromAim;
				}
			}
			let aimDent = aim < dents.Count ? dents[aim] : Vector3.Zero;
			Console.WriteLine(scope $"DENT,{backend},{cases[c]},vertices {local.Count},dented {dented},deepest {deepest:F3} at {deepestFromAim:F2} m from aim,aim pushed in {Vector3.Dot(aimDent, -dirOut):F3} (total {aimDent.Length:F3}),direction match {(dented > 0 ? cosSum / dented : 0):F2},behind the struck surface {behind},spread {spread:F2} m");
		}
		return 0;
	}
}
