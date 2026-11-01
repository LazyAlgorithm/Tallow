using System;
using System.Collections;

namespace Tallow;

[Reflect(.All)]
enum WindShape : int32
{
	/// Blows over the whole scene.
	Global,
	/// Blows inside a sphere round the object, strongest in the middle and fading to nothing at Radius.
	Sphere
}

/// Wind. It blows the way the object faces (its blue arrow), and bends everything set to sway: Foliage, and any Mesh
/// Renderer with Wind Sway above 0. A Global zone covers the whole scene; a Sphere zone adds its wind inside a
/// radius, for a gusty valley, a fan, a helicopter's downdraught or the blast of something passing. Zones add up.
///
/// The bending is done on the graphics card, so it costs the same for one plant as for fifty thousand. The four
/// Sphere zones nearest the camera take part; Global zones always do. Wind is the same on every machine if the zones
/// are (zones in a scene are; one moved by a script moves on other machines if its object is shared).
[Component]
class WindZone : Component
{
	public WindShape shape = .Global;
	/// How hard it blows: 0 still air, 1 a breeze, 3 a strong wind, 6 a gale.
	public float strength = 1;
	/// How much the wind comes and goes: 0 steady, 1 in gusts. The gustiest Global zone sets it for the scene.
	[Range(0, 1)]
	public float gusts = 0.5f;
	/// How far a Sphere zone reaches.
	public float radius = 10;

	static List<WindZone> sAll = new .() ~ delete _;

	public override void OnRegister() => sAll.Add(this);
	public override void OnUnregister() => sAll.Remove(this);

	/// The wind this zone makes at a point (nothing outside a Sphere zone's reach).
	public Vector3 WindAt(Vector3 position)
	{
		let wind = Transform.Forward * strength;
		if (shape == .Global)
			return wind;
		let reach = Math.Max(radius * Math.Max(Math.Max(Transform.LocalScale.x, Transform.LocalScale.y), Transform.LocalScale.z), 0.0001f);
		return wind * Mathf.Clamp01(1 - (position - Transform.Position).Length / reach);
	}

	public override void OnDrawGizmos(bool selected)
	{
		let from = Transform.Position;
		let color = Color(0.55f, 0.85f, 1.0f, selected ? 1.0f : 0.5f);
		let forward = Transform.Forward, right = Transform.Right;
		let length = 1.0f + Math.Min(strength, 6) * 0.4f;
		let tip = from + forward * length;
		DebugDraw.Line(from, tip, color);
		DebugDraw.Line(tip, tip - forward * 0.3f + right * 0.15f, color);
		DebugDraw.Line(tip, tip - forward * 0.3f - right * 0.15f, color);
		if (shape == .Sphere && selected)
			DebugDraw.Sphere(from, radius, color);
	}

	public static List<WindZone> All => sAll;
}

/// Reading the wind from code, for anything that should drift with it: smoke, a sail, a paper bag.
static class Wind
{
	/// The wind at a point of a scene, every zone added up: a direction whose length is the strength.
	public static Vector3 At(Scene scene, Vector3 position)
	{
		var wind = Vector3.Zero;
		for (let zone in WindZone.All)
		{
			if (zone.GameObject == null || zone.GameObject.IsDestroyed || zone.Scene != scene || !zone.IsActiveAndEnabled)
				continue;
			wind = wind + zone.WindAt(position);
		}
		return wind;
	}

	/// How gusty the scene's wind is (0 steady, 1 in gusts): the gustiest Global zone's Gusts.
	public static float Gusts(Scene scene)
	{
		float gusts = 0;
		for (let zone in WindZone.All)
		{
			if (zone.GameObject != null && !zone.GameObject.IsDestroyed && zone.Scene == scene && zone.IsActiveAndEnabled && zone.shape == .Global)
				gusts = Math.Max(gusts, zone.gusts);
		}
		return gusts;
	}

	/// How rough the air is for cloth and ropes (Soft Body, Rope): some flutter always, more with gusts.
	public static float Turbulence(Scene scene) => 0.35f + 0.65f * Gusts(scene);

	/// What the renderer hands the graphics card: the scene's global wind (w: gustiness) and the four Sphere zones
	/// nearest a point (xyz centre, w reach; and their wind).
	public static void Gather(Scene scene, Vector3 near, out Vector4 global, ref Vector4[4] zones, ref Vector4[4] push)
	{
		var wind = Vector3.Zero;
		float gusts = 0;
		float[4] distance = .(float.MaxValue, float.MaxValue, float.MaxValue, float.MaxValue);
		for (int i < 4)
		{
			zones[i] = default;
			push[i] = default;
		}
		for (let zone in WindZone.All)
		{
			if (zone.GameObject == null || zone.GameObject.IsDestroyed || zone.Scene != scene || !zone.IsActiveAndEnabled)
				continue;
			let blowing = zone.Transform.Forward * zone.strength;
			if (zone.shape == .Global)
			{
				wind = wind + blowing;
				gusts = Math.Max(gusts, zone.gusts);
				continue;
			}
			let scale = zone.Transform.LocalScale;
			let reach = zone.radius * Math.Max(Math.Max(scale.x, scale.y), scale.z);
			if (reach <= 0)
				continue;
			// Kept in order of how near the camera each is; the furthest of five falls off the end.
			let away = Math.Max((zone.Transform.Position - near).Length - reach, 0);
			for (int slot < 4)
			{
				if (away >= distance[slot])
					continue;
				for (int move = 3; move > slot; move--)
				{
					distance[move] = distance[move - 1];
					zones[move] = zones[move - 1];
					push[move] = push[move - 1];
				}
				distance[slot] = away;
				let at = zone.Transform.Position;
				zones[slot] = .(at.x, at.y, at.z, reach);
				push[slot] = .(blowing.x, blowing.y, blowing.z, 0);
				break;
			}
		}
		global = .(wind.x, wind.y, wind.z, gusts);
	}
}

/// Pushes Foliage (and anything else with Wind Sway) out of the way round this object: grass parts round a player's
/// feet and closes again behind them. Put it on whatever should move through plants: a creature, a vehicle, a
/// rolling boulder.
///
/// Characters need nothing: every object with a Character Controller pushes plants aside by itself, sized from the
/// controller. Add this component to one only to change how far it reaches or how hard it pushes, or set Strength to
/// 0 to stop it.
///
/// Nothing is sent over the network. Each machine bends its own plants round the objects it has, and it has every
/// player, so other players part the grass on your screen as they do on theirs. The eight nearest the camera take
/// part.
[Component]
class FoliageBender : Component
{
	/// How far from the object plants are pushed.
	public float radius = 0.9f;
	/// How hard: 1 lays grass well over, 0.3 only brushes it, 0 does nothing.
	[Range(0, 2)]
	public float strength = 1;
	/// Where the pushing is centred, in the object's own space: its feet, as a rule.
	public Vector3 offset = .Zero;

	static List<FoliageBender> sAll = new .() ~ delete _;
	public static List<FoliageBender> All => sAll;

	public override void OnRegister() => sAll.Add(this);
	public override void OnUnregister() => sAll.Remove(this);

	public override void OnDrawGizmos(bool selected)
	{
		if (selected)
			DebugDraw.Sphere(Transform.TransformPoint(offset), radius, .(0.45f, 0.95f, 0.4f, 1));
	}

	/// What the renderer hands the graphics card: the eight pushers nearest a point, nearest first (xyz place, w
	/// reach; x strength). Character Controllers count without a component of their own.
	public static void Gather(Scene scene, Vector3 near, ref Vector4[8] places, ref Vector4[8] push)
	{
		float[8] distance = ?;
		for (int i < 8)
		{
			distance[i] = float.MaxValue;
			places[i] = default;
			push[i] = default;
		}
		void Take(Vector3 at, float reach, float strength, ref Vector4[8] places, ref Vector4[8] push)
		{
			if (reach <= 0 || strength <= 0)
				return;
			let away = (at - near).LengthSquared;
			for (int slot < 8)
			{
				if (away >= distance[slot])
					continue;
				for (int move = 7; move > slot; move--)
				{
					distance[move] = distance[move - 1];
					places[move] = places[move - 1];
					push[move] = push[move - 1];
				}
				distance[slot] = away;
				places[slot] = .(at.x, at.y, at.z, reach);
				push[slot] = .(strength, 0, 0, 0);
				return;
			}
		}
		for (let bender in sAll)
		{
			if (bender.GameObject == null || bender.GameObject.IsDestroyed || bender.Scene != scene || !bender.IsActiveAndEnabled)
				continue;
			let scale = bender.Transform.LocalToWorld.Right.Length;
			Take(bender.Transform.TransformPoint(bender.offset), bender.radius * scale, bender.strength, ref places, ref push);
		}
		for (let component in scene.ComponentsOfType(typeof(CharacterController)))
		{
			let controller = (CharacterController)component;
			if (controller.GameObject.IsDestroyed || !controller.IsActiveAndEnabled)
				continue;
			// One with a Foliage Bender of its own has said how it wants to push.
			if (controller.GetComponent<FoliageBender>() != null)
				continue;
			let feet = controller.Transform.TransformPoint(controller.center - Vector3(0, controller.height * 0.5f, 0));
			Take(feet, Math.Max(controller.radius * 2.2f, 0.6f), 1, ref places, ref push);
		}
	}
}
