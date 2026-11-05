using System;
using System.Collections;

namespace Tallow;

/// A place where players or other objects may appear. Put as many in the scene as you like and ask SpawnPoints for
/// one; the object's position is where to appear and its rotation is which way to face.
[Component]
class SpawnPoint : Component
{
	/// Which team may use this point. 0 means any team.
	public int32 team = 0;
	/// Only for the start of the game: used at most once each, while the start phase lasts. After that players
	/// appear at the ordinary points. Use it for a starting line-up.
	public bool startOnly = false;
	/// A point with a character or moving body this close is passed over while another is free.
	public float clearRadius = 1.0f;

	/// Order of use; the point used longest ago is the "next" one.
	[NonSerialized] public int64 LastUsed;
	[NonSerialized] public bool UsedThisStart;
	[NonSerialized] public int32 UseCount;

	public Vector3 Position => Transform.Position;
	public Quaternion Rotation => Transform.Rotation;

	static Color TeamColor(int32 team)
	{
		switch (team)
		{
		case 0: return .(0.85f, 0.85f, 0.85f, 1);
		case 1: return .(0.95f, 0.35f, 0.30f, 1);
		case 2: return .(0.30f, 0.55f, 0.95f, 1);
		case 3: return .(0.35f, 0.80f, 0.40f, 1);
		case 4: return .(0.95f, 0.80f, 0.25f, 1);
		default: return .(0.75f, 0.45f, 0.90f, 1);
		}
	}

	/// A ring on the ground, a post the height of a person and an arrow for the facing, in the team's colour.
	/// Start-only points have a second, inner ring.
	public override void OnDrawGizmos(bool selected)
	{
		var color = TeamColor(team);
		color.a = selected ? 1.0f : 0.55f;
		let p = Transform.Position;
		Gizmos.Lines.Circle(p, .Up, Math.Max(clearRadius, 0.2f), color, 24);
		if (startOnly)
			Gizmos.Lines.Circle(p, .Up, Math.Max(clearRadius, 0.2f) * 0.6f, color, 16);
		Gizmos.Lines.Line(p, p + .(0, 1.8f, 0), color);
		var forward = Transform.Forward;
		forward.y = 0;
		if (forward.LengthSquared > 0.0001f)
		{
			forward = forward.Normalized;
			let side = Vector3(forward.z, 0, -forward.x);
			let from = p + .(0, 0.9f, 0);
			let tip = from + forward * 1.0f;
			Gizmos.Lines.Line(from, tip, color);
			Gizmos.Lines.Line(tip, tip - forward * 0.3f + side * 0.2f, color);
			Gizmos.Lines.Line(tip, tip - forward * 0.3f - side * 0.2f, color);
		}
	}
}

/// Chooses spawn points.
///
///   let point = SpawnPoints.Next(Scene);                // the one used longest ago
///   let point = SpawnPoints.Random(Scene, team);        // any free one for a team
///   SpawnPoints.Place(player, team);                    // move an object to the next one, facing its way
///
/// How a point is chosen, in order of preference:
///   1. During the start phase, a start-only point for the team that has not been used yet.
///   2. An ordinary point for the team with nobody standing on it.
///   3. An ordinary any-team point with nobody standing on it.
///   4. The same again, ignoring whether someone is standing there.
/// A team is never given another team's point while it has any of its own or any shared one.
///
/// The start phase begins when the scene starts playing and lasts StartWindow seconds, or until EndStart is
/// called. BeginStart begins it again, for a new round.
static class SpawnPoints
{
	/// Seconds from the start of play during which start-only points can be used. 0 keeps the start phase open
	/// until EndStart is called.
	public static float StartWindow = 5;

	static int64 sSequence;
	static Random sRandom = new .() ~ delete _;

	public static bool IsStartPhase(Scene scene) => !scene.SpawnStartOver && (StartWindow <= 0 || scene.SpawnPhaseTime <= StartWindow);

	/// Starts a new start phase: start-only points can be used again, once each.
	public static void BeginStart(Scene scene)
	{
		scene.SpawnStartOver = false;
		scene.SpawnPhaseTime = 0;
		for (let component in scene.ComponentsOfType(typeof(SpawnPoint)))
			((SpawnPoint)component).UsedThisStart = false;
	}

	/// Closes the start phase now; from here only ordinary points are given out.
	public static void EndStart(Scene scene)
	{
		scene.SpawnStartOver = true;
	}

	/// How many points a team could be given (its own and any-team ones), not counting start-only points.
	public static int Count(Scene scene, int32 team = 0)
	{
		int count = 0;
		for (let component in scene.ComponentsOfType(typeof(SpawnPoint)))
		{
			if (let point = component as SpawnPoint)
			{
				if (point.IsActiveAndEnabled && !point.startOnly && (team == 0 || point.team == team || point.team == 0))
					count++;
			}
		}
		return count;
	}

	static bool Occupied(SpawnPoint point, List<Vector3> bodies)
	{
		let p = point.Position;
		for (let body in bodies)
		{
			let dx = body.x - p.x, dz = body.z - p.z;
			if (dx * dx + dz * dz < point.clearRadius * point.clearRadius && Math.Abs(body.y - p.y) < 3)
				return true;
		}
		return false;
	}

	static SpawnPoint Choose(List<SpawnPoint> tier, bool random)
	{
		if (tier.IsEmpty)
			return null;
		if (random)
			return tier[(int)(sRandom.NextDouble() * tier.Count) % tier.Count];
		var best = tier[0];
		for (let point in tier)
		{
			if (point.LastUsed < best.LastUsed)
				best = point;
		}
		return best;
	}

	static SpawnPoint Pick(Scene scene, int32 team, bool random)
	{
		List<SpawnPoint> all = scope .();
		List<Vector3> bodies = scope .();
		for (let component in scene.Components)
		{
			if (let point = component as SpawnPoint)
			{
				if (point.IsActiveAndEnabled)
					all.Add(point);
			}
		}
		for (let controller in scene.Components<CharacterController>(.. scope .()))
		{
			if (controller.GameObject.ActiveInHierarchy)
				bodies.Add(controller.Transform.Position);
		}
		for (let body in scene.Components<Rigidbody>(.. scope .()))
		{
			if (body.GameObject.ActiveInHierarchy && !body.isKinematic)
				bodies.Add(body.Transform.Position);
		}
		if (all.IsEmpty)
			return null;
		List<SpawnPoint> tier = scope .();
		SpawnPoint chosen = null;
		if (IsStartPhase(scene))
		{
			// Own team's line-up first, then shared start points.
			for (let point in all)
			{
				if (point.startOnly && !point.UsedThisStart && team != 0 && point.team == team)
					tier.Add(point);
			}
			if (tier.IsEmpty)
			{
				for (let point in all)
				{
					if (point.startOnly && !point.UsedThisStart && (team == 0 || point.team == 0))
						tier.Add(point);
				}
			}
			chosen = Choose(tier, random);
		}
		for (int pass = 0; pass < 2 && chosen == null; pass++)
		{
			let mustBeFree = pass == 0;
			tier.Clear();
			for (let point in all)
			{
				if (!point.startOnly && (team == 0 || point.team == team) && (!mustBeFree || !Occupied(point, bodies)))
					tier.Add(point);
			}
			chosen = Choose(tier, random);
			if (chosen == null && team != 0)
			{
				tier.Clear();
				for (let point in all)
				{
					if (!point.startOnly && point.team == 0 && (!mustBeFree || !Occupied(point, bodies)))
						tier.Add(point);
				}
				chosen = Choose(tier, random);
			}
		}
		if (chosen == null)
		{
			// Nothing suitable at all: any ordinary point is better than none, then any point.
			tier.Clear();
			for (let point in all)
			{
				if (!point.startOnly)
					tier.Add(point);
			}
			chosen = Choose(tier, random) ?? Choose(all, random);
		}
		chosen.LastUsed = ++sSequence;
		chosen.UseCount++;
		if (chosen.startOnly)
			chosen.UsedThisStart = true;
		return chosen;
	}

	/// The point used longest ago that suits the team (0 for no team), or null if the scene has no spawn points.
	/// Asking counts as using it.
	public static SpawnPoint Next(Scene scene, int32 team = 0) => Pick(scene, team, false);

	/// A random point that suits the team, or null if the scene has no spawn points.
	public static SpawnPoint Random(Scene scene, int32 team = 0) => Pick(scene, team, true);

	/// Position and facing of the next (or a random) point. False, leaving them unset, when there are no points.
	public static bool TryGet(Scene scene, int32 team, bool random, out Vector3 position, out Quaternion rotation)
	{
		position = default;
		rotation = .Identity;
		let point = Pick(scene, team, random);
		if (point == null)
			return false;
		position = point.Position;
		rotation = point.Rotation;
		return true;
	}

	/// Moves an object to the next (or a random) point for the team and turns it to face the point's way. Works for
	/// a character controller, a rigid body or a plain object. Returns the point, or null if there were none.
	/// In multiplayer, call it on the server.
	public static SpawnPoint Place(GameObject object, int32 team = 0, bool random = false)
	{
		let point = Pick(object.Scene, team, random);
		if (point == null)
			return null;
		object.Transform.SetPositionAndRotation(point.Position, point.Rotation);
		let controller = object.GetComponent<CharacterController>();
		if (controller.IsValid)
			controller.Teleport(point.Position);
		let body = object.GetComponent<Rigidbody>();
		if (body.IsValid && body.HasBody)
		{
			var state = body.State;
			state.position = point.Position;
			state.rotation = point.Rotation;
			state.linearVelocity = .Zero;
			state.angularVelocity = .Zero;
			body.SetState(state);
		}
		return point;
	}
}
