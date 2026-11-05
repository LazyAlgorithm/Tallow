using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Sculpting and painting brushes for VoxelTerrain, and carving for VoxelObject, used from the Scene view.
extension EditorApp
{
	int32 mBrushTool = -1;
	float mBrushSize = 6.0f;
	float mBrushStrength = 0.6f;
	int32 mPaintLayer = 1;
	float mFlattenHeight;
	bool mBrushStroke;
	/// The terrain a stroke is being recorded on, for undo.
	uint32 mStrokeTerrain;
	int32 mSelectedTile;
	bool mBrushPreview = true;
	bool mBrushTest;
	Vector3 mBrushTestPoint;

	const int32 TilesTool = 5;
	const int32 FoliageTool = 6;
	static readonly char8*[?] BrushNames = .("Raise", "Lower", "Smooth", "Flatten", "Paint", "Tiles", "Foliage");
	static readonly char8*[?] LayerNames = .("Automatic", "Grass", "Rock", "Sand", "Snow", "Dirt");

	void DrawTerrainTools(VoxelTerrain terrain)
	{
		ImGui.Spacing();
		ImGui.SeparatorText("Terrain Tools");
		// Two rows: the sculpting brushes, then tiles and foliage.
		let width = (ImGui.GetContentRegionAvail().x - 4 * 6) / 5;
		for (int32 i < 7)
		{
			if (i != 0 && i != 5)
				ImGui.SameLine();
			if (ToolButton(BrushNames[i], mBrushTool == i, width))
			{
				mBrushTool = mBrushTool == i ? -1 : i;
				if (mBrushTool != FoliageTool)
					mFoliagePainting = default;
			}
			if (i == FoliageTool && ImGui.IsItemHovered())
				ImGui.SetTooltip("Grass, bushes and trees painted on the ground.");
		}
		if (mBrushTool == FoliageTool)
		{
			DrawTerrainFoliage(terrain);
			return;
		}

		if (mBrushTool == TilesTool)
		{
			DrawTileTools(terrain);
			return;
		}
		if (BeginPropertyTable("brush"))
		{
			BeginProperty("Brush Size");
			ImGui.SliderFloat("##size", ref mBrushSize, 1, 40, "%.1f");
			BeginProperty("Strength");
			ImGui.SliderFloat("##strength", ref mBrushStrength, 0.05f, 2, "%.2f");
			if (mBrushTool == (int32)VoxelBrush.Paint)
			{
				BeginProperty("Layer");
				if (ImGui.BeginCombo("##layer", LayerNames[mPaintLayer]))
				{
					for (int32 i < 6)
					{
						if (ImGui.Selectable(LayerNames[i], mPaintLayer == i))
							mPaintLayer = i;
					}
					ImGui.EndCombo();
				}
			}
			if (mBrushTool == (int32)VoxelBrush.Flatten)
			{
				BeginProperty("Height");
				ImGui.DragFloat("##height", ref mFlattenHeight, 0.1f);
			}
			BeginProperty("Preview");
			ImGui.Checkbox("##preview", ref mBrushPreview);
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Shows, under the mouse, the ground the brush covers and the shape it is about to make of it.");
			ImGui.EndTable();
		}
		if (mBrushTool >= 0)
			ImGui.TextWrapped("Drag in the Scene view to apply; brushes carry on across tile edges. Shift swaps Raise and Lower. Flatten uses the height where the stroke starts. Ctrl+Z undoes a stroke.");
		else
			ImGui.TextDisabled("Pick a tool to sculpt or paint in the Scene view, or Tiles to add, move and remove tiles.");

		let status = scope String();
		status.AppendF("{} tiles, {} chunks, {} pending{}", terrain.TileCount, terrain.ChunkCount, terrain.PendingChunks, terrain.HasUnsavedEdits ? ", unsaved edits" : "");
		ImGui.TextDisabled(status.CStr());
		if (ImGui.Button("Rebuild"))
			terrain.Regenerate();
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Builds every piece of the ground again from its sculpting.");
		ImGui.SameLine();
		ImGui.TextDisabled(terrain.editsFolder.IsEmpty ? "Sculpting is saved with the scene" : terrain.editsFolder.CStr());
	}

	/// The Foliage tool: the kinds of plant on this terrain (each a Foliage on the terrain's object or one of its
	/// children: an object has one Foliage at most), buttons to add more, and which one the brush paints.
	void DrawTerrainFoliage(VoxelTerrain terrain)
	{
		let owner = terrain.GameObject;
		List<Foliage> kinds = scope .();
		let own = owner.GetComponent<Foliage>();
		if (own)
			kinds.Add(own);
		for (let child in owner.Transform.Children)
		{
			let foliage = child.GameObject.GetComponent<Foliage>();
			if (foliage)
				kinds.Add(foliage);
		}
		ImGui.TextDisabled("Add a kind of plant:");
		char8*[4] labels = .("Grass", "Bush", "Tree", "Pine");
		char8*[4] meshes = .("builtin:grass", "builtin:bush", "builtin:tree", "builtin:pine");
		float[4] densities = .(6, 0.05f, 0.012f, 0.012f);
		float[4] sways = .(1, 0.35f, 0.25f, 0.2f);
		float[4] distances = .(70, 150, 300, 300);
		for (int i < 4)
		{
			if (i > 0)
				ImGui.SameLine();
			if (ImGui.Button(scope String()..AppendF("+ {}", StringView(labels[i])).CStr()))
			{
				// A child of the terrain for each kind, placed on it, so it follows the terrain's own ground.
				let holder = mScene.CreateGameObject(StringView(labels[i]), owner.Transform);
				holder.Transform.SetParent(owner.Transform, false);
				var added = holder.AddComponent<Foliage>();
				added.mesh = StringView(meshes[i]);
				added.density = densities[i];
				added.sway = sways[i];
				added.viewDistance = distances[i];
				added.castShadows = i >= 2;
				mFoliagePainting = added;
				MarkDirty();
			}
		}
		if (kinds.Count == 0)
		{
			ImGui.TextWrapped("Nothing planted yet. Press a button above, then drag over the ground in the Scene view.");
			return;
		}
		ImGui.Spacing();
		for (let foliage in kinds)
		{
			ImGui.PushID(Internal.UnsafeCastToPtr(foliage.GameObject));
			let painting = mFoliagePainting == foliage;
			var name = StringView(foliage.mesh);
			if (name.StartsWith("builtin:"))
				name.RemoveFromStart(8);
			let slash = name.LastIndexOf('/');
			if (slash >= 0)
				name.RemoveFromStart(slash + 1);
			if (ToolButton(scope String()..AppendF("{}  ({})", name, foliage.Count).CStr(), painting, ImGui.GetContentRegionAvail().x - 70))
				mFoliagePainting = painting ? default : foliage;
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Paint this kind of plant. Its settings (mesh, density, sizes, sway) are in its Foliage component below.");
			ImGui.SameLine();
			if (ImGui.Button("Clear", .(62, 0)))
			{
				foliage.Clear();
				MarkDirty();
			}
			ImGui.PopID();
		}
		if (BeginPropertyTable("terrainfoliage"))
		{
			BeginProperty("Brush Size");
			ImGui.SliderFloat("##foliagesize", ref mFoliageBrush, 0.5f, 30, "%.1f");
			ImGui.EndTable();
		}
		if (mFoliagePainting)
			ImGui.TextWrapped("Drag in the Scene view to paint. Hold Shift to erase. Ctrl+Z undoes a stroke.");
		else
			ImGui.TextDisabled("Pick a kind of plant above to paint it.");
	}

	void DrawTileTools(VoxelTerrain terrain)
	{
		if (terrain.mode != .Fixed)
		{
			ImGui.TextWrapped("Tiles are for a Fixed terrain. An Endless one is generated around the camera.");
			return;
		}
		let status = scope String();
		status.AppendF("{} tiles of {} x {} chunks ({} m square)", terrain.TileCount, terrain.tileSize, terrain.tileSize, (int)terrain.TileWorldSize);
		ImGui.TextDisabled(status.CStr());
		ImGui.TextWrapped("In the Scene view: click a + to add a tile beside the others, Ctrl+click any empty place to add one apart from them, click a tile to select it, Shift+click an empty place to move the selected tile there.");
		TerrainTile tile = default;
		if (mSelectedTile == 0 || !terrain.FindTile(mSelectedTile, out tile))
		{
			mSelectedTile = 0;
			ImGui.TextDisabled("No tile selected.");
			return;
		}
		ImGui.Spacing();
		ImGui.Text(scope $"Tile {tile.id} at ({tile.x}, {tile.z})");
		void Move(char8* label, int32 dx, int32 dz)
		{
			let free = terrain.TileAt(tile.x + dx, tile.z + dz) == 0;
			ImGui.BeginDisabled(!free);
			if (ImGui.Button(label) && terrain.MoveTile(tile.id, tile.x + dx, tile.z + dz))
				MarkDirty();
			ImGui.EndDisabled();
		}
		Move("Move -X", -1, 0);
		ImGui.SameLine();
		Move("Move +X", 1, 0);
		ImGui.SameLine();
		Move("Move -Z", 0, -1);
		ImGui.SameLine();
		Move("Move +Z", 0, 1);
		if (ImGui.Button("Remove Tile"))
		{
			terrain.RemoveTile(tile.id);
			mSelectedTile = 0;
			MarkDirty();
			return;
		}
		ImGui.SameLine();
		ImGui.TextDisabled("leaves a hole; undo brings it back");
	}

	/// Finishes the brush stroke in progress, keeping it as one undo step.
	void EndBrushStroke()
	{
		mBrushStroke = false;
		if (mStrokeTerrain == 0)
			return;
		let owner = mScene.FindById(mStrokeTerrain);
		mStrokeTerrain = 0;
		let terrain = owner?.GetComponent<VoxelTerrain>();
		if (terrain != null)
			PushTerrainUndo(terrain, terrain.EndEditRecord());
	}

	/// The tile grid in the Scene view: outlines, + where a tile can go, and clicks to add, select and move.
	void UpdateTileTool(VoxelTerrain terrain, Ray ray)
	{
		if (terrain.mode != .Fixed)
			return;
		let w = terrain.TileWorldSize;
		let height = terrain.flatHeight + 0.05f;
		let toWorld = terrain.Transform.LocalToWorld;
		void Square(int32 x, int32 z, float inset, Color color)
		{
			let a = toWorld.TransformPoint(.(x * w + inset, height, z * w + inset));
			let b = toWorld.TransformPoint(.((x + 1) * w - inset, height, z * w + inset));
			let c = toWorld.TransformPoint(.((x + 1) * w - inset, height, (z + 1) * w - inset));
			let d = toWorld.TransformPoint(.(x * w + inset, height, (z + 1) * w - inset));
			Gizmos.Lines.Line(a, b, color);
			Gizmos.Lines.Line(b, c, color);
			Gizmos.Lines.Line(c, d, color);
			Gizmos.Lines.Line(d, a, color);
		}
		void Plus(int32 x, int32 z, Color color)
		{
			let center = Vector3((x + 0.5f) * w, height, (z + 0.5f) * w);
			let arm = w * 0.12f;
			Gizmos.Lines.Line(toWorld.TransformPoint(center - Vector3(arm, 0, 0)), toWorld.TransformPoint(center + Vector3(arm, 0, 0)), color);
			Gizmos.Lines.Line(toWorld.TransformPoint(center - Vector3(0, 0, arm)), toWorld.TransformPoint(center + Vector3(0, 0, arm)), color);
		}

		// Where the mouse is on the grid.
		bool hovering = false;
		int32 hx = 0, hz = 0;
		let toLocal = terrain.Transform.WorldToLocal;
		let o = toLocal.TransformPoint(ray.origin);
		let dir = toLocal.TransformDirection(ray.direction);
		if (Math.Abs(dir.y) > 0.0001f)
		{
			let t = (terrain.flatHeight - o.y) / dir.y;
			if (t > 0)
			{
				let p = o + dir * t;
				hx = (int32)Math.Floor(p.x / w);
				hz = (int32)Math.Floor(p.z / w);
				hovering = true;
			}
		}

		List<TerrainTile> tiles = scope .();
		terrain.GetTiles(tiles);
		HashSet<int64> taken = scope .();
		for (let tile in tiles)
			taken.Add(((int64)tile.x << 32) | (uint32)tile.z);
		bool Taken(int32 x, int32 z) => taken.Contains(((int64)x << 32) | (uint32)z);
		HashSet<int64> slots = scope .();
		for (let tile in tiles)
		{
			let selected = tile.id == mSelectedTile;
			let hovered = hovering && hx == tile.x && hz == tile.z;
			Square(tile.x, tile.z, 0, selected ? Color(1, 0.85f, 0.2f, 1) : (hovered ? Color(1, 1, 1, 1) : Color(0.45f, 0.8f, 0.45f, 0.9f)));
			if (selected)
				Square(tile.x, tile.z, w * 0.01f, Color(1, 0.85f, 0.2f, 1));
			for (int i < 4)
			{
				let x = tile.x + (i == 0 ? 1 : (i == 1 ? -1 : 0));
				let z = tile.z + (i == 2 ? 1 : (i == 3 ? -1 : 0));
				if (!Taken(x, z) && slots.Add(((int64)x << 32) | (uint32)z))
					Plus(x, z, hovering && hx == x && hz == z ? Color(1, 1, 1, 1) : Color(0.6f, 0.75f, 1, 0.8f));
			}
		}
		if (tiles.Count == 0)
		{
			slots.Add(0);
			Plus(0, 0, Color(0.6f, 0.75f, 1, 0.8f));
		}
		if (!hovering)
			return;
		let slot = ((int64)hx << 32) | (uint32)hz;
		let free = !Taken(hx, hz);
		if (free && !slots.Contains(slot))
			Square(hx, hz, w * 0.02f, Color(0.6f, 0.75f, 1, ImGui.IsKeyDown(ImGui.Key.LeftCtrl) || ImGui.IsKeyDown(ImGui.Key.LeftShift) ? 0.8f : 0.25f));
		if (!ImGui.IsMouseClicked(0))
			return;
		if (!free)
		{
			mSelectedTile = terrain.TileAt(hx, hz);
			return;
		}
		if (ImGui.IsKeyDown(ImGui.Key.LeftShift) && mSelectedTile != 0)
		{
			if (terrain.MoveTile(mSelectedTile, hx, hz))
				MarkDirty();
		}
		else if (slots.Contains(slot) || ImGui.IsKeyDown(ImGui.Key.LeftCtrl))
		{
			let id = terrain.AddTile(hx, hz);
			if (id != 0)
			{
				mSelectedTile = id;
				MarkDirty();
			}
		}
	}

	void DrawVoxelObjectTools(VoxelObject voxels)
	{
		ImGui.Spacing();
		ImGui.SeparatorText("Carving");
		if (ToolButton("Carve in Scene", mBrushTool == 1, 140))
			mBrushTool = mBrushTool == 1 ? -1 : 1;
		ImGui.SameLine();
		if (ImGui.Button("Reset Shape"))
		{
			voxels.ResetShape();
			MarkDirty();
		}
		// Any model can be made destructible: this takes the one the object is already drawn with.
		let drawn = voxels.GetComponent<MeshRenderer>();
		if (drawn && !drawn.mesh.IsEmpty && !drawn.mesh.StartsWith("builtin:") && (voxels.shape != .Mesh || voxels.mesh != drawn.mesh))
		{
			if (ImGui.Button("Make This Model Destructible"))
			{
				voxels.shape = .Mesh;
				voxels.mesh.Set(drawn.mesh);
				voxels.OnValidate();
				MarkDirty();
			}
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip("Sets Shape to Mesh with the Mesh Renderer's model. The model must be closed (no open sides) to be filled in.");
		}
		if (voxels.shape == .Mesh && voxels.IsEmpty)
			ImGui.TextColored(EditorTheme.Warning, voxels.mesh.IsEmpty ? "Choose a model in Mesh." : "Nothing came of that model: is it closed, with no open sides?");
		ImGui.SetNextItemWidth(-1);
		ImGui.SliderFloat("##carvesize", ref mBrushSize, 0.1f, 10, "Brush %.2f");
		ImGui.TextWrapped("At runtime call Carve(point, radius) from a script; loose pieces break off and fall.");
	}

	/// The patch of ground under the brush, sampled on a square grid: the ground's height at each point (NaN where
	/// there is none), the height the brush is about to give it, and how much the brush acts there.
	struct BrushPatch
	{
		public Vector3 center;
		public float radius;
		public int cells;
		public int side;
		public float spacing;
		/// How far the preview floats above the ground, so that it does not flicker into it.
		public float lift;
		public float[] ground;
		public float[] after;
		public float[] weight;

		public Vector3 On(int i, int j, float[] heights) => .(center.x - radius + i * spacing, heights[i + j * side] + lift, center.z - radius + j * spacing);

		/// The height at a point inside the patch, between the samples round it.
		public float Height(float x, float z, float[] heights)
		{
			let fi = Math.Clamp((x - (center.x - radius)) / spacing, 0, cells - 0.001f), fj = Math.Clamp((z - (center.z - radius)) / spacing, 0, cells - 0.001f);
			let i = (int)fi, j = (int)fj;
			let h00 = heights[i + j * side], h10 = heights[i + 1 + j * side], h01 = heights[i + (j + 1) * side], h11 = heights[i + 1 + (j + 1) * side];
			if (h00.IsNaN || h10.IsNaN || h01.IsNaN || h11.IsNaN)
				return center.y;
			let tx = fi - i, tz = fj - j;
			return Mathf.Lerp(Mathf.Lerp(h00, h10, tx), Mathf.Lerp(h01, h11, tx), tz);
		}
	}

	/// The brush's preview in the Scene view: the patch of ground inside the brush, lying on the ground as it is, with a
	/// see-through mesh over it of the shape the brush is about to give it (higher, lower, levelled, evened out, or
	/// tinted with the paint layer). It is a guide to where and which way, not an exact forecast: how far the ground
	/// moves depends on how long the brush is held. Returns false when the ground under the brush could not be read.
	bool DrawBrushPreview(VoxelTerrain terrain, Vector3 center, VoxelBrush mode, float flattenHeight)
	{
		BrushPatch patch;
		patch.center = center;
		patch.radius = mBrushSize;
		patch.cells = (int)Math.Clamp(Math.Round(patch.radius * 2 / Math.Max(terrain.voxelSize, 0.1f)), 10, 32);
		patch.side = patch.cells + 1;
		patch.spacing = patch.radius * 2 / patch.cells;
		patch.lift = Math.Max(terrain.voxelSize * 0.04f, 0.03f);
		patch.ground = scope float[patch.side * patch.side];
		patch.after = scope float[patch.side * patch.side];
		patch.weight = scope float[patch.side * patch.side];
		if (SampleBrushGround(terrain, ref patch) < 4)
			return false;
		ShapeUnderBrush(ref patch, mode, flattenHeight);
		let tint = BrushTint(mode);
		DrawBrushShape(patch, tint);
		DrawBrushEdge(patch);
		return true;
	}

	/// Reads the ground's height at every point of the patch (and a little beyond the brush, so that the patch has a
	/// clean round edge to be cut to), with how much the brush acts there. Returns how many points have ground.
	static int SampleBrushGround(VoxelTerrain terrain, ref BrushPatch patch)
	{
		let center = patch.center;
		let radius = patch.radius;
		let top = center.y + radius + 2;
		int found = 0;
		for (int j < patch.side)
		{
			for (int i < patch.side)
			{
				let at = i + j * patch.side;
				let x = center.x - radius + i * patch.spacing, z = center.z - radius + j * patch.spacing;
				let away = Math.Sqrt((x - center.x) * (x - center.x) + (z - center.z) * (z - center.z));
				patch.weight[at] = Math.Max(1 - away / radius, 0);
				patch.ground[at] = float.NaN;
				if (away > radius + patch.spacing * 1.5f)
					continue;
				Vector3 hit;
				if (terrain.Raycast(Ray(.(x, top, z), .(0, -1, 0)), (radius + 2) * 2, out hit))
				{
					patch.ground[at] = hit.y;
					found++;
				}
			}
		}
		return found;
	}

	/// What the brush makes of each point. Raise and Lower move the ground by about what a second of holding does.
	void ShapeUnderBrush(ref BrushPatch patch, VoxelBrush mode, float flattenHeight)
	{
		let push = Math.Clamp(mBrushStrength, 0.05f, 2) * Math.Min(patch.radius * 0.35f, 4);
		let side = patch.side;
		let ground = patch.ground;
		for (int j < side)
		{
			for (int i < side)
			{
				let at = i + j * side;
				let height = ground[at];
				if (height.IsNaN)
				{
					patch.after[at] = float.NaN;
					continue;
				}
				let w = patch.weight[at];
				switch (mode)
				{
				case .Raise: patch.after[at] = height + push * w;
				case .Lower: patch.after[at] = height - push * w;
				case .Flatten: patch.after[at] = Mathf.Lerp(height, flattenHeight, Math.Min(w * 2.5f, 1));
				case .Smooth:
					float sum = 0;
					int count = 0;
					for (int dj = -2; dj <= 2; dj++)
					{
						for (int di = -2; di <= 2; di++)
						{
							let ni = i + di, nj = j + dj;
							if (ni < 0 || nj < 0 || ni >= side || nj >= side || ground[ni + nj * side].IsNaN)
								continue;
							sum += ground[ni + nj * side];
							count++;
						}
					}
					patch.after[at] = Mathf.Lerp(height, count > 0 ? sum / count : height, Math.Min(w * 2, 1));
				default: patch.after[at] = height;
				}
			}
		}
	}

	/// The preview's colour: one for each sculpting brush, and for Paint the colour of the layer about to go on.
	Color BrushTint(VoxelBrush mode)
	{
		switch (mode)
		{
		case .Raise: return .(0.35f, 0.9f, 0.45f, 1);
		case .Lower: return .(1.0f, 0.45f, 0.3f, 1);
		case .Flatten: return .(0.35f, 0.7f, 1.0f, 1);
		case .Smooth: return .(0.8f, 0.6f, 1.0f, 1);
		default:
			float[6][3] layers = .(.(1, 1, 1), .(0.41f, 0.62f, 0.29f), .(0.5f, 0.48f, 0.45f), .(0.84f, 0.77f, 0.56f), .(0.93f, 0.94f, 0.96f), .(0.49f, 0.36f, 0.24f));
			let layer = layers[Math.Clamp(mPaintLayer, 0, 5)];
			return .(layer[0], layer[1], layer[2], 1);
		}
	}

	/// The shape to come, see-through: stronger in the middle, fading to nothing at the brush's edge, with its lines
	/// every other cell so that the slope reads.
	static void DrawBrushShape(BrushPatch patch, Color tint)
	{
		let side = patch.side;
		for (int j < patch.cells)
		{
			for (int i < patch.cells)
			{
				let a = i + j * side, b = a + 1, c = a + side + 1, d = a + side;
				if (patch.ground[a].IsNaN || patch.ground[b].IsNaN || patch.ground[c].IsNaN || patch.ground[d].IsNaN)
					continue;
				let w = (patch.weight[a] + patch.weight[b] + patch.weight[c] + patch.weight[d]) * 0.25f;
				if (w <= 0)
					continue;
				let after = patch.after;
				let fill = Color(tint.r * 0.75f, tint.g * 0.75f, tint.b * 0.75f, 0.3f + 0.45f * Math.Min(w * 1.6f, 1));
				Gizmos.Triangles.Quad(patch.On(i, j, after), patch.On(i + 1, j, after), patch.On(i + 1, j + 1, after), patch.On(i, j + 1, after), fill);
				let line = Color(tint.r * 0.35f, tint.g * 0.35f, tint.b * 0.35f, 0.9f * Math.Min(w * 3, 1));
				if (i % 2 == 0)
					Gizmos.Lines.Line(patch.On(i, j, after), patch.On(i, j + 1, after), line);
				if (j % 2 == 0)
					Gizmos.Lines.Line(patch.On(i, j, after), patch.On(i + 1, j, after), line);
			}
		}
	}

	/// The brush's edge, lying on the ground as it is now, and a post in the middle from the ground to the shape to
	/// come: how far and which way.
	static void DrawBrushEdge(BrushPatch patch)
	{
		let center = patch.center;
		let ringColor = Color(1.0f, 0.45f, 0.05f, 1);
		Vector3 previous = default;
		for (int s <= 64)
		{
			let angle = s * (Mathf.PI * 2 / 64);
			let x = center.x + Math.Cos(angle) * patch.radius, z = center.z + Math.Sin(angle) * patch.radius;
			let point = Vector3(x, patch.Height(x, z, patch.ground) + patch.lift * 2, z);
			if (s > 0)
				Gizmos.Lines.Line(previous, point, ringColor);
			previous = point;
		}
		let middle = patch.side / 2 + (patch.side / 2) * patch.side;
		if (!patch.ground[middle].IsNaN)
			Gizmos.Lines.Line(.(center.x, patch.ground[middle] + patch.lift, center.z), .(center.x, patch.after[middle] + patch.lift, center.z), ringColor);
	}

	/// Runs the active brush under the mouse. Returns true when the brush is in control of the mouse.
	bool UpdateBrush(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (mBrushTest && selected != null)
		{
			// --brush-preview: the preview at a fixed place, for screenshots taken with nobody at the mouse.
			let tested = selected.GetComponent<VoxelTerrain>();
			Vector3 ground;
			if (tested != null && mBrushTool >= 0 && mBrushTool < TilesTool && tested.Raycast(Ray(mBrushTestPoint + Vector3(0, 300, 0), .(0, -1, 0)), 800, out ground))
				DrawBrushPreview(tested, ground, (VoxelBrush)mBrushTool, ground.y + 2);
		}
		if (UpdateFoliageBrush(selected, origin, size))
		{
			EndBrushStroke();
			return true;
		}
		if (mBrushTool < 0 || selected == null)
		{
			EndBrushStroke();
			return false;
		}
		let terrain = selected.GetComponent<VoxelTerrain>();
		let voxels = selected.GetComponent<VoxelObject>();
		if (terrain == null && voxels == null)
		{
			EndBrushStroke();
			return false;
		}
		if (!mSceneHovered || mFlying)
		{
			EndBrushStroke();
			return true;
		}
		let mouse = ImGui.GetMousePos();
		let ray = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);
		if (terrain == null)
		{
			CarveWithBrush(selected, voxels, ray);
			return true;
		}
		if (mBrushTool == TilesTool)
		{
			EndBrushStroke();
			UpdateTileTool(terrain, ray);
		}
		// The Foliage tool with no kind of plant picked: nothing to do, and the sculpting brushes stay out of it.
		else if (mBrushTool == FoliageTool)
			EndBrushStroke();
		else
			SculptWithBrush(terrain, ray);
		return true;
	}

	/// The sculpting brush picked, with Shift turning Raise into Lower and back.
	VoxelBrush BrushModeWithShift()
	{
		let mode = (VoxelBrush)mBrushTool;
		if (!ImGui.IsKeyDown(ImGui.Key.LeftShift))
			return mode;
		if (mode == .Raise)
			return .Lower;
		if (mode == .Lower)
			return .Raise;
		return mode;
	}

	/// A sculpting or paint brush on the terrain: its preview where the mouse points, and while the mouse is down the
	/// brush itself (a whole stroke, mouse down to up, is one undo step).
	void SculptWithBrush(VoxelTerrain terrain, Ray ray)
	{
		let down = ImGui.IsMouseDown(0);
		Vector3 point;
		if (!terrain.Raycast(ray, 800, out point))
		{
			if (!down)
				EndBrushStroke();
			return;
		}
		let mode = BrushModeWithShift();
		if (!mBrushPreview || !DrawBrushPreview(terrain, point, mode, mBrushStroke ? mFlattenHeight : point.y))
		{
			Gizmos.Lines.Circle(point, .Up, mBrushSize, BrushColor, 48);
			Gizmos.Lines.Line(point, point + Vector3(0, mBrushSize * 0.5f, 0), BrushColor);
		}
		if (!down)
		{
			EndBrushStroke();
			return;
		}
		if (!mBrushStroke && mode == .Flatten)
			mFlattenHeight = point.y;
		if (!mBrushStroke && mPlay == .Edit)
		{
			terrain.BeginEditRecord();
			mStrokeTerrain = terrain.GameObject.Id;
		}
		mBrushStroke = true;
		let amount = mode == .Paint ? 1.0f : mBrushStrength * Math.Min(Time.UnscaledDeltaTime, 0.05f) * 6.0f;
		terrain.Brush(point, mBrushSize, amount, mode, mPaintLayer, mFlattenHeight);
		MarkDirty();
	}

	/// The brush's colour where it has no preview of its own.
	static readonly Color BrushColor = .(1.0f, 0.85f, 0.2f, 1);

	/// The brush on a destructible object: a sphere where the mouse meets its current mesh, carving while held.
	void CarveWithBrush(GameObject selected, VoxelObject voxels, Ray ray)
	{
		let renderer = selected.GetComponent<MeshRenderer>();
		let mesh = renderer ? renderer.ActiveMesh : null;
		if (mesh == null)
			return;
		let toLocal = selected.Transform.WorldToLocal;
		let localOrigin = toLocal.TransformPoint(ray.origin);
		let localRay = Ray(localOrigin, (toLocal.TransformPoint(ray.origin + ray.direction) - localOrigin).Normalized);
		let t = mesh.Raycast(localRay);
		if (t < 0)
			return;
		let hit = selected.Transform.TransformPoint(localRay.GetPoint(t));
		let radius = Math.Min(mBrushSize, 10.0f) * 0.25f;
		Gizmos.Lines.Sphere(hit, radius, BrushColor);
		if (ImGui.IsMouseDown(0) && voxels.Carve(hit, radius))
			MarkDirty();
	}
}
