using System;

namespace Tallow;

/// A box of closer-together light probes for the light baker (docs/baked-lighting.md): where light changes over a
/// short way (a room, a doorway, under a roof, round a lamp) the scene's grid of probes is too coarse. Things whose
/// middle is in the box take their ambient light from its probes, fading into the scene's grid over blendDistance
/// inside its edges. The smallest box wins where boxes overlap. Bake again after changing one.
///
/// A handle (ComponentHandle): its settings are LightProbeVolumeData's fields, in the object's entity.
[Component, HandleFields]
struct LightProbeVolume : ComponentHandle<LightProbeVolumeData>
{
	/// The box in the world.
	public Bounds WorldBox
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

	/// How many probes it has along each axis (2 or more, up to 64), at its spacing over its box.
	public void Counts(out int32 x, out int32 y, out int32 z)
	{
		let area = WorldBox;
		let extents = area.max - area.min;
		let step = Math.Max(spacing, 0.25f);
		int32 Along(float length) => (int32)Math.Clamp(Math.Round(length / step) + 1, 2, 64);
		x = Along(extents.x);
		y = Along(extents.y);
		z = Along(extents.z);
	}

	static void DrawGizmos(GameObject gameObject, bool selected) => gameObject.GetComponent<LightProbeVolume>().DrawBox(selected);

	void DrawBox(bool selected)
	{
		let tint = selected ? Color(1.0f, 0.85f, 0.35f, 1) : Color(0.95f, 0.75f, 0.3f, 0.45f);
		let area = WorldBox;
		Gizmos.Lines.Box(area, .Identity, tint);
		if (!selected)
			return;
		// Each probe as a small cross, unless there are too many to read.
		Counts(let cx, let cy, let cz);
		if (cx * cy * cz > 4096)
			return;
		let mark = Math.Min(Math.Max(spacing, 0.25f) * 0.12f, 0.15f);
		for (int z < cz)
		{
			for (int y < cy)
			{
				for (int x < cx)
				{
					let p = Vector3(area.min.x + (area.max.x - area.min.x) * x / (cx - 1), area.min.y + (area.max.y - area.min.y) * y / (cy - 1), area.min.z + (area.max.z - area.min.z) * z / (cz - 1));
					Gizmos.Lines.Line(p - .(mark, 0, 0), p + .(mark, 0, 0), tint);
					Gizmos.Lines.Line(p - .(0, mark, 0), p + .(0, mark, 0), tint);
				}
			}
		}
	}
}

/// A Light Probe Volume's settings.
[Component, HandleData]
struct LightProbeVolumeData
{
	/// The box it covers, in metres around the object (scaled with it, not turned with it).
	public Vector3 size = .(10, 4, 10);
	/// How far apart its probes are, in metres.
	[Range(0.25f, 10)]
	public float spacing = 1;
	/// How far inside the box, in metres, its light fades in from the scene's probes round it.
	public float blendDistance = 1;

	public this() { }
}
