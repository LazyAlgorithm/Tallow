using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// The Foliage brush: painting and erasing plants in the Scene view, from a Foliage component's Inspector.
extension EditorApp
{
	Foliage mFoliagePainting;
	float mFoliageBrush = 5;

	void DrawFoliageTools(Foliage foliage)
	{
		let painting = mFoliagePainting == foliage;
		if (ToolButton("Paint", painting, 90))
		{
			mFoliagePainting = painting ? null : foliage;
			// On a terrain this is the Terrain Tools' Foliage tool; elsewhere no terrain brush is in the way.
			mBrushTool = (mFoliagePainting != null && foliage.GameObject.GetComponent<VoxelTerrain>() != null) ? FoliageTool : -1;
		}
		ImGui.SameLine();
		ImGui.TextDisabled(scope String()..AppendF("{} plants", foliage.Count).CStr());
		if (BeginPropertyTable("foliagebrush"))
		{
			BeginProperty("Brush Size");
			ImGui.SliderFloat("##foliagesize", ref mFoliageBrush, 0.5f, 30, "%.1f");
			ImGui.EndTable();
		}
		let terrain = foliage.GameObject.GetComponent<VoxelTerrain>() ?? mScene.FindComponent<VoxelTerrain>();
		ImGui.BeginDisabled(terrain == null || terrain.mode != .Fixed);
		if (ImGui.Button("Fill Terrain"))
		{
			// Brush-sized patches side by side over every tile; the brush itself leaves steep ground bare.
			List<TerrainTile> tiles = scope .();
			terrain.GetTiles(tiles);
			let w = terrain.TileWorldSize;
			let patch = 8.0f;
			for (let tile in tiles)
			{
				for (float z = patch * 0.5f; z < w; z += patch)
				{
					for (float x = patch * 0.5f; x < w; x += patch)
					{
						let center = terrain.Transform.TransformPoint(.(tile.x * w + x, terrain.flatHeight + 40, tile.z * w + z));
						foliage.Paint(center, patch * 0.75f, 0.6f);
					}
				}
			}
			MarkDirty();
		}
		ImGui.EndDisabled();
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Paints the whole of every terrain tile at once. On a large terrain at a high Density this is a great many plants.");
		ImGui.SameLine();
		if (ImGui.Button("Clear"))
		{
			foliage.Clear();
			MarkDirty();
		}
		if (painting)
			ImGui.TextWrapped("Drag in the Scene view to paint plants on the ground. Hold Shift to erase. Ctrl+Z undoes a stroke. Add another Foliage component for another kind of plant.");
		else
			ImGui.TextDisabled("Press Paint, then drag in the Scene view.");
	}

	/// Runs the Foliage brush under the mouse. Returns true when it is in control of the mouse.
	bool UpdateFoliageBrush(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (mFoliagePainting == null)
			return false;
		// The component may have been removed, or another object selected.
		if (selected == null || !selected.Components.Contains(mFoliagePainting))
		{
			mFoliagePainting = null;
			return false;
		}
		if (!mSceneHovered || mFlying)
			return true;
		let foliage = mFoliagePainting;
		let mouse = ImGui.GetMousePos();
		let ray = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);
		Vector3 point = default;
		bool found = false;
		let terrain = selected.GetComponent<VoxelTerrain>() ?? mScene.FindComponent<VoxelTerrain>();
		if (terrain != null)
			found = terrain.Raycast(ray, 800, out point);
		else if (Math.Abs(ray.direction.y) > 0.0001f)
		{
			// No terrain: level ground at the object's height.
			let t = (selected.Transform.Position.y - ray.origin.y) / ray.direction.y;
			if (t > 0)
			{
				point = ray.origin + ray.direction * t;
				found = true;
			}
		}
		if (!found)
			return true;
		let erasing = ImGui.IsKeyDown(ImGui.Key.LeftShift);
		let color = erasing ? Color(1.0f, 0.4f, 0.3f, 1) : Color(0.45f, 0.95f, 0.4f, 1);
		Gizmos.Lines.Circle(point + Vector3(0, 0.05f, 0), .Up, mFoliageBrush, color, 48);
		Gizmos.Lines.Line(point, point + Vector3(0, mFoliageBrush * 0.4f, 0), color);
		if (ImGui.IsMouseDown(0))
		{
			let changed = erasing ? foliage.Erase(point, mFoliageBrush) : foliage.Paint(point, mFoliageBrush, Math.Min(Time.UnscaledDeltaTime, 0.05f) * 4);
			if (changed > 0)
				MarkDirty();
		}
		return true;
	}
}
