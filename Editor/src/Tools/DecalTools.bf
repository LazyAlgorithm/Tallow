using System;
using Tallow;

namespace Tallow.Editor;

/// Inspector tools for decals: sticking one flat onto the surface it points at.
extension EditorApp
{
	void DrawDecalTools(Decal decal)
	{
		if (ImGui.Button("Stick to Surface"))
		{
			if (StickDecal(decal.GameObject))
				MarkDirty();
			else
				Log.Warning("Stick to Surface: there is nothing in front of or below the decal to stick it to.");
		}
		ImGui.SameLine();
		ImGui.TextDisabled("(?)");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Moves the decal onto the surface its blue arrow points at (or, with none, the one below it),\nand turns it to lie flat on that surface, keeping its picture the same way up.");
		ImGui.TextDisabled("Pressed along the blue axis onto what is in the box.");
	}

	/// Moves a decal onto the surface it faces (or else the one below it) and lays it flat there. False when there
	/// is no surface within reach either way.
	bool StickDecal(GameObject gameObject)
	{
		let transform = gameObject.Transform;
		let forward = transform.Forward;
		// From a little behind the decal, so a surface it already sits on is found again.
		let back = 0.5f;
		Vector3 point, normal;
		if (!RaycastScene(Ray(transform.Position - forward * back, forward), out point, out normal, gameObject, true, 100) &&
			!RaycastScene(Ray(transform.Position + Vector3.Up * 0.5f, .Down), out point, out normal, gameObject, true, 100))
			return false;
		// Keep the picture's up as near to what it was as the new surface allows.
		var up = transform.Up - normal * Vector3.Dot(transform.Up, normal);
		if (up.LengthSquared < 1e-6f)
			up = Math.Abs(normal.y) > 0.95f ? Vector3.Forward : Vector3.Up;
		transform.Rotation = Quaternion.LookRotation(-normal, up.Normalized);
		transform.Position = point;
		return true;
	}
}
