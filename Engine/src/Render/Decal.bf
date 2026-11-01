using System;
using System.Collections;

namespace Tallow;

/// Projects a picture onto whatever lies inside its box: posters, signs, cracks, stains, scorch marks. The picture
/// is pressed along the object's forward (blue) axis onto the surfaces in the box, lit like them, and fades out on
/// surfaces turned away from it. Moving or rotating the object moves the decal; parent it to a moving object to
/// carry it along. For many short-lived marks (bullet holes, footprints), use Decals.Spawn instead.
[Component]
class Decal : Component
{
	/// The picture. Its alpha decides where the decal shows; none draws a solid rectangle in the colour.
	public String texture = new .() ~ delete _;
	/// Multiplies the picture; its alpha fades the whole decal.
	public Color color = .White;
	/// The box's width (X), height (Y) and depth (Z, along the projection), in metres, before the object's scale.
	public Vector3 size = .(1, 1, 0.5f);
	/// How strongly the decal covers what is under it.
	[Range(0, 1)]
	public float opacity = 1;
	/// How metal-like the decal's surface is.
	[Range(0, 1)]
	public float metallic = 0;
	/// How rough the decal's surface is.
	[Range(0, 1)]
	public float roughness = 0.8f;
	/// Surfaces turned further than this from the decal (in degrees) do not show it; it fades out over the last 15
	/// degrees. Keeps a decal on a floor from smearing down the sides of things standing on it.
	[Range(1, 90)]
	public float angleLimit = 70;
	/// Draws the picture as it is, ignoring light: glowing signs, holograms.
	public bool unlit = false;
	/// Decals with a higher order are drawn over those with a lower one where they overlap.
	public int32 order = 0;

	/// The box the decal projects through, in the world: the unit cube scaled by size, then by the object.
	public Matrix4 BoxMatrix => Transform.LocalToWorld * Matrix4.Scale(size);

	public override void OnDrawGizmos(bool selected)
	{
		let tint = selected ? Color(1.0f, 0.75f, 0.2f, 1) : Color(0.9f, 0.6f, 0.2f, 0.6f);
		let volume = BoxMatrix;
		Gizmos.Lines.Box(.(.(-0.5f), .(0.5f)), volume, tint);
		// Which way the picture is pressed: an arrow from the box's centre along its depth.
		let center = volume.TransformPoint(.Zero);
		let tip = volume.TransformPoint(.(0, 0, 0.5f));
		Gizmos.Lines.Line(center, tip, tint);
		let up = volume.TransformPoint(.(0, 0.5f, 0));
		Gizmos.Lines.Line(center, up, tint);
	}
}

/// A decal made by Decals.Spawn: not an object, just a box, a picture and how long it lasts.
struct SpawnedDecal
{
	/// The box the picture projects through (as Decal.BoxMatrix).
	public Matrix4 volume;
	public String texture;
	public Color color;
	/// When it was made (Time.Time), and how long it lasts (0: until pushed out by newer ones).
	public float born;
	public float lifetime;
	public float angleLimit;
}

/// Short-lived decals made from code, for marks that come and go in numbers: bullet holes, blood, scorch marks,
/// footprints. They are kept in a pool per scene: when it is full, the oldest makes way. They are not objects
/// and are not sent over the network, so make them on every machine (from code that runs on each, such as the
/// handler of the message that says a shot hit).
static class Decals
{
	/// How many spawned decals a scene keeps at once; making another replaces the oldest.
	public static int MaxSpawned = 256;
	/// How long, in seconds, a decal with a lifetime takes to fade away at the end of it.
	public const float FadeTime = 1.0f;

	/// Presses a picture onto the surface at position, whose outward facing is normal: size wide and high, and
	/// size / 2 deep. It lasts lifetime seconds (0: until newer ones push it out), fading over the last second.
	/// spin turns the picture about the normal, in degrees (vary it so that repeated marks do not all line up).
	public static void Spawn(Scene scene, Vector3 position, Vector3 normal, StringView texture, float size, float lifetime = 0, Color color = .White, float spin = 0)
	{
		if (scene == null || normal.LengthSquared < 1e-8f || size <= 0)
			return;
		let facing = normal.Normalized;
		// Pressed into the surface: the box's forward points against the normal.
		let reference = Math.Abs(facing.y) > 0.95f ? Vector3.Forward : Vector3.Up;
		let rotation = Quaternion.AngleAxis(spin, facing) * Quaternion.LookRotation(-facing, reference);
		Spawn(scene, Matrix4.TRS(position, rotation, .(size, size, size * 0.5f)), texture, lifetime, color);
	}

	/// Presses a picture through a box of your own (the unit cube placed by volume, projected along its Z axis).
	public static void Spawn(Scene scene, Matrix4 volume, StringView texture, float lifetime = 0, Color color = .White, float angleLimit = 70)
	{
		// In a session the server's decals are pressed on every machine (docs/networking.md).
		if (scene == null || NetworkSync.DecalSpawned(scene, volume, texture, lifetime, color, angleLimit) || MaxSpawned <= 0)
			return;
		let list = scene.SpawnedDecals;
		while (list.Count >= MaxSpawned)
		{
			delete list[0].texture;
			list.RemoveAt(0);
		}
		SpawnedDecal decal;
		decal.volume = volume;
		decal.texture = new String(texture);
		decal.color = color;
		decal.born = Time.Time;
		decal.lifetime = Math.Max(lifetime, 0);
		decal.angleLimit = angleLimit;
		list.Add(decal);
	}

	/// Removes every spawned decal from the scene.
	public static void Clear(Scene scene)
	{
		if (scene == null)
			return;
		for (let decal in scene.SpawnedDecals)
			delete decal.texture;
		scene.SpawnedDecals.Clear();
	}

	/// Drops spawned decals whose time is up; called by the renderer each frame.
	public static void Expire(Scene scene)
	{
		let list = scene.SpawnedDecals;
		for (int i = list.Count - 1; i >= 0; i--)
		{
			let decal = list[i];
			// Time going backwards means the scene was restarted: what was made before is gone too.
			if ((decal.lifetime > 0 && Time.Time - decal.born >= decal.lifetime) || Time.Time < decal.born)
			{
				delete decal.texture;
				list.RemoveAt(i);
			}
		}
	}

	/// How much of a spawned decal still shows: 1, falling to 0 over the last FadeTime of its life.
	public static float Fade(SpawnedDecal decal)
	{
		if (decal.lifetime <= 0)
			return 1;
		let left = decal.lifetime - (Time.Time - decal.born);
		return Math.Clamp(left / Math.Min(FadeTime, decal.lifetime), 0, 1);
	}
}
