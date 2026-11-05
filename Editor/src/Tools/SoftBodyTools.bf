using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Paint Pins and Paint Stiffness for a Soft Body (docs/soft-bodies.md): brushes in the Scene view that write its
/// pins and stiffness map, shown on its vertices while painting.
extension EditorApp
{
	enum SoftPaint
	{
		None,
		Pins,
		Stiffness
	}

	SoftPaint mSoftPaint = .None;
	/// The brush's radius, as a share of the mesh's size.
	float mSoftRadius = 0.08f;
	float mSoftStiffness = 0.3f;
	// The welded vertices of the mesh being painted (as the simulation will have them), and which mesh they are of.
	List<Vector3> mSoftRest = new .() ~ delete _;
	Mesh mSoftMesh;
	int mSoftMeshVertices;

	/// Test switch: --soft-paint pins|stiffness picks that brush (with --select picking the object).
	void ApplySoftBodySwitches()
	{
		let brush = scope String();
		if (!GetArg("--soft-paint", brush))
			return;
		mSoftPaint = brush == "stiffness" ? .Stiffness : .Pins;
	}

	void DrawSoftBodyTools(SoftBody body)
	{
		ImGui.Spacing();
		ImGui.SeparatorText("Soft Body Tools");
		let width = (ImGui.GetContentRegionAvail().x - 6) / 2;
		if (ToolButton("Paint Pins", mSoftPaint == .Pins, width))
			mSoftPaint = mSoftPaint == .Pins ? .None : .Pins;
		ImGui.SameLine();
		if (ToolButton("Paint Stiffness", mSoftPaint == .Stiffness, width))
			mSoftPaint = mSoftPaint == .Stiffness ? .None : .Stiffness;
		if (mSoftPaint != .None && BeginPropertyTable("softbrush"))
		{
			BeginProperty("Brush Size");
			ImGui.SliderFloat("##size", ref mSoftRadius, 0.01f, 0.5f, "%.2f");
			if (mSoftPaint == .Stiffness)
			{
				BeginProperty("Stiffness");
				ImGui.SliderFloat("##stiffness", ref mSoftStiffness, 0, 1, "%.2f");
			}
			ImGui.EndTable();
		}
		if (mSoftPaint == .Pins)
			ImGui.TextWrapped("Drag over the mesh in the Scene view to pin vertices to the object (orange); Shift unpins. Ctrl+Z undoes a stroke.");
		else if (mSoftPaint == .Stiffness)
			ImGui.TextWrapped("Drag over the mesh to give vertices this stiffness (red soft, white as stiff as the body); Shift sets them back. Ctrl+Z undoes a stroke.");
		else
			ImGui.TextDisabled("Pick a brush to paint on the mesh in the Scene view.");
		if (!body.pins.IsEmpty || !body.stiffnessMap.IsEmpty)
		{
			if (ImGui.Button("Clear Pins"))
			{
				body.pins.Clear();
				MarkDirty();
			}
			ImGui.SameLine();
			if (ImGui.Button("Clear Stiffness"))
			{
				body.stiffnessMap.Clear();
				MarkDirty();
			}
		}
	}

	/// The Scene view while painting a soft body. True: the brush has the mouse.
	bool UpdateSoftBodyPaint(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		let body = selected?.GetComponent<SoftBody>();
		let mesh = MeshRenderer.MeshOf(selected);
		if (mSoftPaint == .None || body == null || mesh == null || mPlay != .Edit)
			return false;
		if (mesh != mSoftMesh || mesh.Vertices.Count != mSoftMeshVertices)
		{
			mSoftRest.Clear();
			SoftBody.Weld(mesh, mSoftRest, scope .(), scope .());
			mSoftMesh = mesh;
			mSoftMeshVertices = mesh.Vertices.Count;
		}

		// What is painted so far.
		let toWorld = selected.Transform.LocalToWorld;
		let pinned = scope List<uint32>();
		SoftBody.ParsePins(body.pins, mSoftRest.Count, pinned);
		let stiffness = scope List<float>();
		stiffness.Resize(mSoftRest.Count, 1);
		SoftBody.ParseStiffness(body.stiffnessMap, stiffness);
		let bounds = mesh.Bounds;
		let dot = Math.Max(bounds.Size.Length * 0.006f, 0.005f);
		for (int i < mSoftRest.Count)
		{
			let at = toWorld.TransformPoint(mSoftRest[i]);
			if (pinned.Contains((uint32)i))
				Gizmos.OnTopLines.Sphere(at, dot * 1.6f, .(1, 0.55f, 0.1f, 1));
			else if (mSoftPaint == .Stiffness)
				Gizmos.OnTopLines.Sphere(at, dot, .(1, stiffness[i], stiffness[i], 0.8f));
		}

		if (!mSceneHovered || mFlying)
			return true;
		let mouse = ImGui.GetMousePos();
		let ray = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);
		let toLocal = selected.Transform.WorldToLocal;
		let localOrigin = toLocal.TransformPoint(ray.origin);
		let localRay = Ray(localOrigin, (toLocal.TransformPoint(ray.origin + ray.direction) - localOrigin).Normalized);
		let t = mesh.Raycast(localRay);
		if (t < 0)
			return true;
		let point = localRay.GetPoint(t);
		let radius = mSoftRadius * Math.Max(bounds.Size.Length, 1e-3f);
		let worldRadius = radius * toWorld.TransformDirection(.(1, 0, 0)).Length;
		Gizmos.OnTopLines.Sphere(toWorld.TransformPoint(point), worldRadius, .(1, 0.85f, 0.2f, 1));
		if (!ImGui.IsMouseDown(0))
			return true;

		let erase = ImGui.IsKeyDown(ImGui.Key.LeftShift);
		bool changed = false;
		for (int i < mSoftRest.Count)
		{
			if ((mSoftRest[i] - point).Length > radius)
				continue;
			if (mSoftPaint == .Pins)
			{
				let index = pinned.IndexOf((uint32)i);
				if (erase && index >= 0)
					pinned.RemoveAt(index);
				else if (!erase && index < 0)
					pinned.Add((uint32)i);
				else
					continue;
			}
			else
			{
				let value = erase ? 1 : mSoftStiffness;
				if (stiffness[i] == value)
					continue;
				stiffness[i] = value;
			}
			changed = true;
		}
		if (changed)
		{
			if (mSoftPaint == .Pins)
				SoftBody.FormatPins(pinned, body.pins..Clear());
			else
				SoftBody.FormatStiffness(stiffness, body.stiffnessMap..Clear());
			MarkDirty();
		}
		return true;
	}
}
