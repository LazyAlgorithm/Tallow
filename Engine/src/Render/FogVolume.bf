using System;

namespace Tallow;

/// The shape of a Fog Volume.
[Reflect(.All)]
enum FogVolumeShape : int32
{
	/// A box: the object's position, rotation and scale give it.
	Box,
	/// A ball (an ellipsoid when the object's scale is uneven): the object's position, rotation and scale give it.
	Sphere
}

/// A box or ball of fog for a part of the scene (tallowengine.com/docs/day-night): with Volumetric Fog on, the fog
/// inside it takes its density and colour, so a misty hollow, a smoke-filled room or a warm glow in the air is one
/// object. Its edges fade out, so it has no hard sides, and like the rest of the fog it is lit by the sun (shadows cut
/// light shafts out of it), the sky's ambient light and the point and spot lights that scatter in it. Several can
/// overlap; their fog adds up.
///
/// Only fog drawn volumetrically knows volumes: with Volumetric Fog off, or beyond the scene's Volumetric Distance,
/// the distance fog (Fog Density) is all there is, and it has no volumes. Open web and mobile devices that cannot run
/// compute shaders likewise use the distance fog.
///
/// A handle (ComponentHandle): its settings are FogVolumeData's fields, in the object's entity.
[Component, HandleFields]
struct FogVolume : ComponentHandle<FogVolumeData>
{
	/// The volume in the world: its size scaled by the object's scale (its rotation is not in this box, which is
	/// axis-aligned, so a turned volume's box is a little bigger than the volume).
	public Bounds WorldBounds
	{
		get
		{
			let world = Transform.LocalToWorld;
			let scale = Vector3(world.Right.Length, world.Up.Length, world.Forward.Length);
			let size = this.size;
			let half = Vector3(Math.Abs(size.x * scale.x), Math.Abs(size.y * scale.y), Math.Abs(size.z * scale.z)) * 0.5f;
			let center = Transform.Position;
			return .(center - half, center + half);
		}
	}

	/// The matrix taking a point in the world into the volume's own space, where the box runs from -1 to 1 on each
	/// axis (and the sphere is 1 from its middle). The fog shaders use it (RenderViewVolumetric.bf).
	public Matrix4 ToLocal
	{
		get
		{
			let size = this.size;
			// A zero side would make the volume's space infinite: a hair's breadth keeps it finite.
			let x = Math.Max(Math.Abs(size.x), 0.001f);
			let y = Math.Max(Math.Abs(size.y), 0.001f);
			let z = Math.Max(Math.Abs(size.z), 0.001f);
			return Matrix4.Scale(.(2 / x, 2 / y, 2 / z)) * Transform.LocalToWorld.Inverse;
		}
	}

	static void DrawGizmos(GameObject gameObject, bool selected)
	{
		let volume = gameObject.GetComponent<FogVolume>();
		let tint = selected ? Color(0.55f, 0.75f, 1.0f, 1) : Color(0.45f, 0.65f, 0.95f, 0.35f);
		let area = volume.WorldBounds;
		switch (volume.shape)
		{
		case .Box:
			Gizmos.Lines.Box(area, .Identity, tint);
		case .Sphere:
			Gizmos.Lines.Sphere(area.Center, (area.max - area.min).Length * 0.5f, tint);
		}
	}
}

/// A Fog Volume's settings.
[Component, HandleData]
struct FogVolumeData
{
	/// A box, or a ball (an ellipsoid when the object's scale is uneven).
	public FogVolumeShape shape = .Box;
	/// Its size in metres before the object's scale (a sphere's width, height and depth).
	public Vector3 size = .(12, 5, 12);
	/// How much fog it holds: the fog's optical depth through a metre of it. Higher is thicker mist; 0 is none.
	[Range(0, 4)]
	public float density = 0.15f;
	/// The colour of the fog in it.
	public Color color = .(1, 1, 1, 1);
	/// How much of the way in from its edge the fog fades from full density to none (0: right up to the edge; 1: from
	/// the middle outwards). A little keeps it from ending in a hard line.
	[Range(0, 1)]
	public float edgeFade = 0.3f;

	public this()
	{
	}
}
