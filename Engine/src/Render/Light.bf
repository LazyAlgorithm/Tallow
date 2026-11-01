using System;
using System.Collections;
using Bgfx;

namespace Tallow;

/// What kind of light a Light is.
[Reflect(.All)]
enum LightType : int32
{
	Directional,
	Point,
	Spot
}

/// Directional, point or spot light. The sun casts cascaded shadows; point and spot lights cast shadows from tiles
/// of a shared atlas (a point light six, one for each face of a cube), the nearest few of them in each view
/// (Quality's Shadowed Lights). A view draws up to 256 point and spot lights, by cluster (docs/lighting.md).
[Component]
class Light : Component
{
	/// Directional (like the sun: everywhere, from one direction), point (from a point, all round) or spot (from a
	/// point, in a cone).
	public LightType type = .Directional;
	/// The light's colour.
	public Color color = .(1.0f, 0.96f, 0.88f);
	/// How bright the light is.
	public float intensity = 1.0f;
	/// How far a point or spot light reaches, in metres.
	public float range = 10.0f;
	/// Physical inverse-square distance attenuation; intensity is then measured per square metre.
	public bool inverseSquare = false;
	/// Baked diffuse already supplies this light on surfaces with a lightmap.
	public bool bakedOnly = false;
	/// Which channel of baked shadowmasks holds this light's shadows (-1: none). Set when lighting is baked.
	public int32 shadowMaskChannel = -1;
	/// Negative keeps the engine default, 80% of Spot Angle.
	public float innerSpotAngle = -1;
	/// How wide a spot light's cone is, in degrees.
	[Range(1, 170)]
	public float spotAngle = 45.0f;
	/// Whether the light casts shadows. A point light's cost six spot lights' (one for each face of its cube).
	public bool castShadows = true;
	/// How dark the light's shadows are: 1 is fully dark, 0 none.
	[Range(0, 1)]
	public float shadowStrength = 1.0f;
	// What NetworkSync last saw of these settings (0: not looked at yet).
	uint64 mSharedHash;

	public override void OnRegister() => Scene.Lights.Add(this);
	public override void OnUnregister() => Scene.Lights.Remove(this);

	public override void OnDrawGizmos(bool selected)
	{
		let position = Transform.Position;
		let tint = Color(color.r, color.g, color.b, 1);
		switch (type)
		{
		case .Directional:
			let forward = Transform.Forward;
			let right = Transform.Right * 0.3f;
			let up = Transform.Up * 0.3f;
			Gizmos.Lines.Line(position, position + forward * 1.5f, tint);
			Gizmos.Lines.Line(position + right, position + right + forward * 1.2f, tint);
			Gizmos.Lines.Line(position - right, position - right + forward * 1.2f, tint);
			Gizmos.Lines.Line(position + up, position + up + forward * 1.2f, tint);
			Gizmos.Lines.Line(position - up, position - up + forward * 1.2f, tint);
		case .Point:
			Gizmos.Lines.Sphere(position, selected ? range : 0.25f, tint);
		case .Spot:
			let forward = Transform.Forward;
			let radius = Math.Tan(spotAngle * 0.5f * Mathf.Deg2Rad) * range;
			let end = position + forward * range;
			Gizmos.Lines.Circle(end, forward, radius, tint);
			Gizmos.Lines.Line(position, end + Transform.Right * radius, tint);
			Gizmos.Lines.Line(position, end - Transform.Right * radius, tint);
			Gizmos.Lines.Line(position, end + Transform.Up * radius, tint);
			Gizmos.Lines.Line(position, end - Transform.Up * radius, tint);
		}
	}
}
