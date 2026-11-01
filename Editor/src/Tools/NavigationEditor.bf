using System;
using System.IO;
using Tallow;

namespace Tallow.Editor;

extension EditorApp
{
	Vector3 mNavigationDirtyCenter, mNavigationDirtySize = .(16, 10, 16);
	void DrawNavigationTools(NavigationSurface surface)
	{
		ImGui.TextWrapped("Position is the minimum corner of the bake bounds. Backend: NavMesh is the one for walking agents (fast with many agents, floors above each other work); Grid walks the highest floor only. Flying always uses a 3D grid of free space. Cell size trades detail for memory and bake time.");
		if (surface.flying)
			ImGui.TextDisabled("Flying: baked as a 3D grid, whatever the Backend.");
		if (ImGui.Button("Bake & Save Navigation"))
		{
			if (surface.bakedData.IsEmpty)
			{
				let name = scope String();
				for (let c in (StringView)surface.GameObject.Name)
					name.Append(c.IsLetterOrDigit ? c : '_');
				surface.bakedData.Set(scope $"{name}.tnav");
				MarkDirty();
			}
			if (surface.Bake() && surface.SaveData())
			{
				Log.Info("Navigation baked and saved.");
				RefreshAssetList();
			}
		}
		ImGui.SameLine();
		if (ImGui.Button("Load Baked Data"))
			surface.LoadData();
		if (surface.Data != null)
		{
			let mesh = surface.Data.Mesh;
			if (mesh != null)
				ImGui.Text(scope $"{mesh.PolygonCount} polygons; {mesh.TileCount} tiles ({mesh.LastRebuiltTiles} rebuilt last time)");
			else
				ImGui.Text(scope $"{surface.Data.cells.Count} cells; revision {surface.Data.Revision}; chunk size {surface.Data.chunkSize}");
		}
		if (surface.Data != null && !surface.Data.flying && surface.Data.IsNavMesh != (surface.backend == .NavMesh))
			ImGui.TextWrapped("The baked data is for the other walking backend: Bake & Save Navigation to use this one.");
		if (ImGui.CollapsingHeader("Rebuild Changed Bounds"))
		{
			ImGui.DragFloat3("Changed bounds center", ref mNavigationDirtyCenter);
			ImGui.DragFloat3("Changed bounds size", ref mNavigationDirtySize, 0.1f, 0.1f, 100000);
			if (ImGui.Button("Rebuild Bounds"))
			{
				let half = Vector3.Abs(mNavigationDirtySize) * 0.5f;
				if (surface.Rebuild(.(mNavigationDirtyCenter - half, mNavigationDirtyCenter + half)))
				{
					surface.SaveData();
					Log.Info("Changed navigation chunks rebuilt.");
				}
			}
		}
	}

	// ---- Navigation Links, Obstacles and Areas ----

	/// The baked surface whose grid a point is on (within a distance), or null.
	NavigationSurface SurfaceUnder(Vector3 point, float distance, out int32 cell)
	{
		cell = -1;
		for (let component in mScene.ComponentsOfType(typeof(NavigationSurface)))
		{
			let surface = (NavigationSurface)component;
			if (surface.Data == null || !surface.IsActiveAndEnabled)
				continue;
			cell = surface.Data.Nearest(point, distance);
			if (cell >= 0)
				return surface;
		}
		return null;
	}

	void DrawNavigationLinkTools(NavigationLink link)
	{
		let snap = Math.Max(link.snapDistance, 0.5f);
		let start = SurfaceUnder(link.StartPoint, snap, ?);
		let end = SurfaceUnder(link.EndPoint, snap, ?);
		if (start != null && end != null)
			ImGui.TextDisabled("Both ends reach a baked surface.");
		else
			ImGui.TextColored(EditorTheme.Warning, start == null && end == null ? "Neither end is near a baked surface (bake one, or move the ends)." : (start == null ? "The start (this object) is not near a baked surface." : "The end is not near a baked surface."));
		if (ImGui.Button("Drop Ends to Ground"))
		{
			let endPoint = link.EndPoint;
			if (RaycastScene(Ray(link.StartPoint + Vector3.Up * 0.5f, .Down), let point, ?, link.GameObject, true, 50))
				link.Transform.Position = point;
			if (RaycastScene(Ray(endPoint + Vector3.Up * 0.5f, .Down), let endHit, ?, link.GameObject, true, 50))
				link.end = link.Transform.Rotation.Normalized.Conjugate * (endHit - link.Transform.Position);
			MarkDirty();
		}
		ImGui.SameLine();
		if (ImGui.Button("End at View Centre"))
		{
			// Where the Scene view's camera looks.
			let forward = Quaternion.Euler(mCamPitch, mCamYaw, 0) * Vector3.Forward;
			if (RaycastScene(Ray(mCamPosition, forward), let point, ?, link.GameObject, true, 500))
			{
				link.end = link.Transform.Rotation.Normalized.Conjugate * (point - link.Transform.Position);
				MarkDirty();
			}
		}
		ImGui.TextDisabled(scope String()..AppendF("{:0.0} m long. Agents cross it with OnLinkStarted / OnLinkFinished.", (link.EndPoint - link.StartPoint).Length).CStr());
	}

	/// Sizes an obstacle or area to what its object draws.
	bool FitNavigationShape(GameObject gameObject, ref Vector3 size, ref Vector3 center)
	{
		if (!HierarchyBounds(gameObject, let bounds) || !bounds.IsValid)
			return false;
		// In the object's own space (its scale and turn taken out).
		let inverse = gameObject.Transform.WorldToLocal;
		var local = Bounds.Empty;
		for (int corner < 8)
		{
			let point = Vector3((corner & 1) != 0 ? bounds.max.x : bounds.min.x, (corner & 2) != 0 ? bounds.max.y : bounds.min.y, (corner & 4) != 0 ? bounds.max.z : bounds.min.z);
			local.Encapsulate(inverse.TransformPoint(point));
		}
		let scale = gameObject.Transform.LocalScale;
		size = (local.max - local.min) * scale;
		center = (local.max + local.min) * 0.5f * scale;
		return true;
	}

	void DrawNavigationObstacleTools(NavigationObstacle obstacle)
	{
		if (ImGui.Button("Fit to Object"))
		{
			if (FitNavigationShape(obstacle.GameObject, ref obstacle.size, ref obstacle.center))
				MarkDirty();
			else
				Log.Warning("Fit to Object: the object draws nothing to fit to.");
		}
		ImGui.SameLine();
		ImGui.TextDisabled(mPlay == .Edit ? "Shown carved where it stands." : (obstacle.Carving ? "Carving." : "Moving: steered round."));
	}

	void DrawNavigationAreaTools(NavigationArea area)
	{
		if (ImGui.Button("Fit to Object"))
		{
			var center = Vector3.Zero;
			if (FitNavigationShape(area.GameObject, ref area.size, ref center))
				MarkDirty();
		}
		ImGui.SameLine();
		ImGui.TextDisabled(area.blocked ? "Agents never enter it." : scope String()..AppendF("Crossing costs {:0.#} times its length.", area.cost).CStr());
	}
}
