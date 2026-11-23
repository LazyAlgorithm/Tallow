using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// The Building tools (tallowengine.com/docs/buildings): with a Building selected, rooms are dragged out on the grid of the storey
/// being worked on and walls go round them by themselves; doors, windows and openings are clicked onto walls and
/// cut out of them; stairs are dragged out and cut a hole in the floor above. The storeys above, and the ceiling of
/// the one being worked on, are cut away while it is selected, so its rooms can be seen into. Everything goes into
/// the Building's plan (and so into the scene's undo).
extension EditorApp
{
	enum BuildTool
	{
		None,
		Room,
		Erase,
		Door,
		Window,
		Opening,
		Stairs
	}

	static StringView[?] sBuildToolNames = .("Select", "Room", "Erase", "Door", "Window", "Opening", "Stairs");
	static StringView[?] sBuildToolIcons = .("\u{f245}", "\u{f0c8}", "\u{f12d}", "\u{f52b}", "\u{f2d0}", "\u{f0db}", "\u{f149}");
	static StringView[?] sBuildToolTips = .(
		"Back to picking and moving whole objects.",
		"Drag out a room on the grid: walls go round it by themselves, with one wall between rooms that touch. Shift+drag adds to the selected room (an L-shaped room, or an open plan). A click picks a room.",
		"Drag over squares to take them out of the rooms. Walls close up round what is left.",
		"Click a wall to put a door in it. Click a door to pick it and drag it along the wall.",
		"Click a wall to put a window in it. Click a window to pick it and drag it along the wall.",
		"Click a wall for a wide opening with no door: an archway between two rooms.",
		"Drag out stairs, from their foot towards the top: they climb to the storey above and cut a hole in its floor.");
	static StringView[?] sBuildCutawayNames = .("See All", "Cut Away", "Low Walls");

	BuildTool mBuildTool;
	int32 mBuildStorey;
	/// 0: the whole building. 1: the storeys above and this one's ceiling are cut away. 2: and its walls are low.
	int32 mBuildCutaway = 1;
	bool mBuildDragging;
	int32 mBuildFromX;
	int32 mBuildFromZ;
	int32 mBuildToX;
	int32 mBuildToZ;
	/// The picked door or window (an index into the plan's openings, -1 none) and whether it is being dragged.
	int mBuildOpening = -1;
	bool mBuildMovingOpening;
	bool mBuildOpeningMoved;
	/// The picked room (0 none).
	int32 mBuildRoom;
	uint32 mBuildObject;
	// The sizes new doors, windows and openings get.
	float mBuildDoorWidth = 1;
	float mBuildDoorHeight = 2.1f;
	float mBuildWindowWidth = 1.2f;
	float mBuildWindowHeight = 1.2f;
	float mBuildWindowSill = 0.9f;
	float mBuildOpeningWidth = 2;
	float mBuildOpeningHeight = 2.5f;
	/// The building drawn cut away, and what it was drawn from, to tell when to draw it again.
	uint32 mBuildShownObject;
	String mBuildShownKey = new .() ~ delete _;

	/// The selected object's Building, if it has one (and a Model Mesh to make it into).
	Building SelectedBuilding
	{
		get
		{
			let selected = Selected;
			if (selected == null)
				return default;
			let building = selected.GetComponent<Building>();
			if (!building.IsValid || !selected.GetComponent<ModelMesh>().IsValid)
				return default;
			return building;
		}
	}

	static StringView StoreyName(int32 storey, String into)
	{
		if (storey == 0)
			into.Append("Ground Floor");
		else
			into.AppendF("Floor {}", storey);
		return into;
	}

	// ------------------------------------------------------------------ making and changing buildings

	/// A new building where the Scene view is looking, with the Room tool on.
	GameObject CreateBuildingInView()
	{
		if (mPlay != .Edit)
			return null;
		let made = CreateObject("Building");
		var position = made.Transform.Position;
		if (RaycastScene(mSceneCamera.ViewportPointToRay(0.5f, 0.6f), let point, ?, made, true, 200))
			position = point;
		position.x = Math.Round(position.x * 2) / 2;
		position.z = Math.Round(position.z * 2) / 2;
		made.Transform.Position = position;
		let renderer = made.AddComponent<MeshRenderer>();
		renderer.mesh.Clear();
		renderer.flatShading = false;
		renderer.roughness = 0.9f;
		made.AddComponent<ModelMesh>();
		made.AddComponent<Building>();
		made.AddComponent<MeshCollider>();
		mSelectedId = made.Id;
		mBuildStorey = 0;
		mBuildRoom = 0;
		mBuildOpening = -1;
		mBuildTool = .Room;
		mModelEditing = false;
		mModelDraw = .Off;
		MarkDirty();
		return made;
	}

	void ReadBuildingPlan(Building building, BuildingPlan plan) => plan.Read(building.plan);

	/// Writes a changed plan back and makes the walls again.
	void CommitBuilding(GameObject go, BuildingPlan plan)
	{
		let building = go.GetComponent<Building>();
		plan.Prune(Math.Max(building.gridSize, 0.05f));
		let text = scope String();
		plan.Write(text);
		building.plan.Set(text);
		Building.Rebuild(go);
		if (mBuildOpening >= plan.openings.Count)
			mBuildOpening = -1;
		if (mBuildRoom != 0 && plan.FindRoom(mBuildRoom) == null)
			mBuildRoom = 0;
		mBuildShownKey.Clear();
		MarkDirty();
	}

	/// Keeps the model and drops the plan, so the building can be edited as any model.
	void BakeBuilding(GameObject go)
	{
		ShowBuildingWhole();
		go.RemoveComponent<Building>();
		mBuildTool = .None;
		MarkDirty();
	}

	// ------------------------------------------------------------------ the cut-away

	void ShowBuildingWhole()
	{
		if (mBuildShownObject == 0)
			return;
		let shown = mScene.FindById(mBuildShownObject);
		mBuildShownObject = 0;
		mBuildShownKey.Clear();
		if (shown == null)
			return;
		let model = shown.GetComponent<ModelMesh>();
		if (model.IsValid)
			model.EndShowInstead();
	}

	/// While a building is selected (in edit mode), the storeys above the one being worked on and its ceiling are
	/// cut away; otherwise it is drawn whole.
	void UpdateBuildingCutaway()
	{
		Building building = mPlay == .Edit ? SelectedBuilding : default;
		if (!building.IsValid || mBuildCutaway == 0)
		{
			ShowBuildingWhole();
			return;
		}
		let go = building.GameObject;
		if (mBuildObject != go.Id)
		{
			// Another building: start on its ground floor.
			mBuildObject = go.Id;
			mBuildStorey = 0;
			mBuildRoom = 0;
			mBuildOpening = -1;
		}
		if (mBuildShownObject != 0 && mBuildShownObject != go.Id)
			ShowBuildingWhole();
		let model = go.GetComponent<ModelMesh>();
		let key = scope String();
		key.AppendF("{} {} {}|", mBuildStorey, mBuildCutaway, model.data.Length);
		key.Append(building.plan);
		key.AppendF("|{} {} {} {} {}", building.gridSize, building.storeyHeight, building.wallThickness, building.floorThickness, building.roomColors);
		if (mBuildShownObject == go.Id && key == mBuildShownKey && model.Previewing)
			return;
		let plan = scope BuildingPlan();
		ReadBuildingPlan(building, plan);
		var settings = BuildingGenerator.Settings.From(building);
		settings.cutaway = true;
		settings.topStorey = mBuildStorey;
		settings.lowWalls = mBuildCutaway == 2 ? 1.1f : 0;
		let mesh = scope EditMesh();
		BuildingGenerator.Generate(plan, settings, mesh);
		model.ShowInstead(mesh);
		mBuildShownObject = go.Id;
		mBuildShownKey.Set(key);
	}

	// ------------------------------------------------------------------ the Scene view

	/// The pointer's ray in the building's own space.
	bool BuildingRay(GameObject go, ImGui.Vec2 origin, ImGui.Vec2 size, out Ray ray)
	{
		let mouse = ImGui.GetMousePos();
		let world = mSceneCamera.ViewportPointToRay((mouse.x - origin.x) / size.x, (mouse.y - origin.y) / size.y);
		let toLocal = go.Transform.WorldToLocal;
		ray = .(toLocal.TransformPoint(world.origin), toLocal.TransformDirection(world.direction).Normalized);
		return true;
	}

	/// Where a ray meets the floor of a storey (local space).
	static bool BuildingFloorPoint(BuildingGenerator.Settings s, Ray ray, int32 storey, out Vector3 point)
	{
		point = default;
		let y = storey * s.storeyHeight + s.floor;
		if (Math.Abs(ray.direction.y) < 1.0e-5f)
			return false;
		let t = (y - ray.origin.y) / ray.direction.y;
		if (t <= 0)
			return false;
		point = ray.GetPoint(t);
		return true;
	}

	/// The nearest wall of a storey the ray meets: its axis, line, the point along it and the height above the floor.
	static bool BuildingWallHit(BuildingGrid grid, BuildingGenerator.Settings s, Ray ray, int32 storey, out int32 axis, out int32 line, out float along, out float height)
	{
		axis = line = 0;
		along = height = 0;
		if (grid.width == 0)
			return false;
		let g = s.grid;
		let floorTop = storey * s.storeyHeight + s.floor;
		var best = float.MaxValue;
		for (int32 a < 2)
		{
			let direction = a == 0 ? ray.direction.z : ray.direction.x;
			let start = a == 0 ? ray.origin.z : ray.origin.x;
			if (Math.Abs(direction) < 1.0e-5f)
				continue;
			let from = a == 0 ? grid.minZ : grid.minX;
			let to = a == 0 ? grid.minZ + grid.depth : grid.minX + grid.width;
			for (int32 l = from; l <= to; l++)
			{
				let t = (l * g - start) / direction;
				if (t <= 0 || t >= best)
					continue;
				let p = ray.GetPoint(t);
				let h = p.y - floorTop;
				if (h < -s.floor || h > s.storeyHeight)
					continue;
				let at = a == 0 ? p.x : p.z;
				if (!grid.IsWall(a, l, (int32)Math.Floor(at / g)))
					continue;
				best = t;
				axis = a;
				line = l;
				along = at;
				height = h;
			}
		}
		return best < float.MaxValue;
	}

	/// Draws a line of the building (local points) over the scene.
	void BuildingLine(Matrix4 world, Vector3 a, Vector3 b, Color color, bool onTop = true)
	{
		if (onTop)
			Gizmos.OnTopLines.Line(world.TransformPoint(a), world.TransformPoint(b), color);
		else
			Gizmos.Lines.Line(world.TransformPoint(a), world.TransformPoint(b), color);
	}

	void BuildingQuad(Matrix4 world, Vector3 a, Vector3 b, Vector3 c, Vector3 d, Color color)
	{
		Gizmos.OnTopTriangles.Quad(world.TransformPoint(a), world.TransformPoint(b), world.TransformPoint(c), world.TransformPoint(d), color);
	}

	/// The outline of an opening on its wall (local space), and its bottom and top.
	static void OpeningBox(BuildingPlan.Opening o, BuildingGenerator.Settings s, out Vector3 a, out Vector3 b, out Vector3 c, out Vector3 d)
	{
		let floorTop = o.storey * s.storeyHeight + s.floor;
		let bottom = floorTop + (o.kind == .Window ? o.sill : 0);
		let top = Math.Min(bottom + o.height, (o.storey + 1) * s.storeyHeight);
		let w = o.line * s.grid;
		Vector3 P(float along, float y) => o.axis == 0 ? Vector3(along, y, w) : Vector3(w, y, along);
		a = P(o.center - o.width / 2, bottom);
		b = P(o.center + o.width / 2, bottom);
		c = P(o.center + o.width / 2, top);
		d = P(o.center - o.width / 2, top);
	}

	/// Where an opening of `width` can go on the wall through square `along` of a line: its middle kept on the
	/// straight piece of wall between posts. False when the wall is too short for it.
	static bool FitOpening(BuildingGrid grid, BuildingGenerator.Settings s, int32 axis, int32 line, float at, ref float width, out float center)
	{
		center = at;
		if (!grid.WallRun(axis, line, (int32)Math.Floor(at / s.grid), let from, let to))
			return false;
		let min = from * s.grid + s.wall / 2 + 0.05f, max = to * s.grid - s.wall / 2 - 0.05f;
		if (max - min < 0.3f)
			return false;
		width = Math.Min(width, max - min);
		var c = at;
		if (!ImGui.IsKeyDown(ImGui.Key.LeftAlt))
			c = Math.Round(c / (s.grid * 0.5f)) * s.grid * 0.5f;
		center = Math.Clamp(c, min + width / 2, max - width / 2);
		return true;
	}

	/// Runs the Building tools in the Scene view. True when a tool owns the mouse.
	bool UpdateBuildingTools(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		let building = SelectedBuilding;
		if (mPlay != .Edit || !building.IsValid || mModelDraw != .Off)
		{
			mBuildTool = .None;
			mBuildDragging = false;
			mBuildMovingOpening = false;
			return false;
		}
		let go = building.GameObject;
		let plan = scope BuildingPlan();
		ReadBuildingPlan(building, plan);
		let s = BuildingGenerator.Settings.From(building);
		if (mBuildOpening >= plan.openings.Count)
			mBuildOpening = -1;
		let viewHovered = mSceneHovered;
		let barHovered = ModelBarHovered && !mBuildDragging && !mBuildMovingOpening;
		let hovered = viewHovered && !barHovered;
		DrawBuildingBar(go, plan, origin, size);
		let typing = (ImGui.tn_imgui_capture_flags() & 4) != 0;
		let keysFree = viewHovered && !typing && !mFlying;
		if (keysFree)
		{
			if (ImGui.IsKeyPressed(ImGui.Key.Escape))
			{
				if (mBuildDragging || mBuildMovingOpening)
				{
					mBuildDragging = false;
					mBuildMovingOpening = false;
				}
				else
					mBuildTool = .None;
			}
			// 1-6 pick a tool while one is on.
			if (mBuildTool != .None)
			{
				for (int32 k < 6)
				{
					if (ImGui.IsKeyPressed(ImGui.Key.One + k))
						SetBuildTool((BuildTool)(k + 1));
				}
			}
			let openingTool = mBuildTool == .Door || mBuildTool == .Window || mBuildTool == .Opening;
			if (openingTool && mBuildOpening >= 0 && (ImGui.IsKeyPressed(ImGui.Key.Delete) || ImGui.IsKeyPressed(ImGui.Key.Backspace)))
			{
				plan.openings.RemoveAt(mBuildOpening);
				mBuildOpening = -1;
				CommitBuilding(go, plan);
				return true;
			}
		}

		let world = go.Transform.LocalToWorld;
		let grid = scope BuildingGrid();
		grid.Make(plan, mBuildStorey);
		DrawBuildingPlan(go, plan, grid, s, world, origin, size);
		if (mBuildTool == .None)
			return false;
		if (mFlying)
			return true;
		BuildingRay(go, origin, size, let ray);
		let mouse = ImGui.GetMousePos();
		let g = s.grid;
		let floorY = mBuildStorey * s.storeyHeight + s.floor + 0.02f;
		switch (mBuildTool)
		{
		case .Room,.Erase,.Stairs:
			let onFloor = BuildingFloorPoint(s, ray, mBuildStorey, let point);
			let cx = (int32)Math.Floor(point.x / g), cz = (int32)Math.Floor(point.z / g);
			if (onFloor && hovered && !mBuildDragging && ImGui.IsMouseClicked(0))
			{
				mBuildDragging = true;
				mBuildFromX = mBuildToX = cx;
				mBuildFromZ = mBuildToZ = cz;
			}
			if (onFloor && hovered && !mBuildDragging && ImGui.IsMouseClicked(1))
			{
				// Right-click: remove the room or the stairs under the pointer.
				if (mBuildTool == .Stairs)
				{
					for (int i = plan.stairs.Count - 1; i >= 0; i--)
					{
						let st = plan.stairs[i];
						if (st.storey == mBuildStorey && cx >= st.x0 && cx < st.x1 && cz >= st.z0 && cz < st.z1)
						{
							plan.stairs.RemoveAt(i);
							CommitBuilding(go, plan);
							break;
						}
					}
				}
				else if (grid.Get(cx, cz) != 0)
				{
					RemoveBuildingRoom(plan, grid, grid.Get(cx, cz));
					CommitBuilding(go, plan);
				}
				return true;
			}
			if (mBuildDragging)
			{
				if (onFloor)
				{
					mBuildToX = cx;
					mBuildToZ = cz;
				}
				let x0 = Math.Min(mBuildFromX, mBuildToX);
				let x1 = Math.Max(mBuildFromX, mBuildToX) + 1;
				let z0 = Math.Min(mBuildFromZ, mBuildToZ);
				let z1 = Math.Max(mBuildFromZ, mBuildToZ) + 1;
				let color = mBuildTool == .Erase ? Color(1, 0.35f, 0.3f, 1) : (mBuildTool == .Stairs ? Color(0.45f, 0.75f, 1, 1) : Color(0.4f, 1, 0.55f, 1));
				var fill = color;
				fill.a = 0.18f;
				let a = Vector3(x0 * g, floorY, z0 * g);
				let b = Vector3(x1 * g, floorY, z0 * g);
				let c = Vector3(x1 * g, floorY, z1 * g);
				let d = Vector3(x0 * g, floorY, z1 * g);
				BuildingQuad(world, a, b, c, d, fill);
				BuildingLine(world, a, b, color);
				BuildingLine(world, b, c, color);
				BuildingLine(world, c, d, color);
				BuildingLine(world, d, a, color);
				let label = scope String();
				label.AppendF("{:0.0#} x {:0.0#} m", (x1 - x0) * g, (z1 - z0) * g);
				if (mBuildTool == .Stairs)
				{
					let direction = StairDirection();
					label.Append(direction == 0 ? "  climbing +Z" : (direction == 1 ? "  climbing +X" : (direction == 2 ? "  climbing -Z" : "  climbing -X")));
					// An arrow up the flight.
					let mid = (a + c) * 0.5f;
					let dir = direction == 0 ? Vector3(0, 0, 1) : (direction == 1 ? Vector3(1, 0, 0) : (direction == 2 ? Vector3(0, 0, -1) : Vector3(-1, 0, 0)));
					let len = (direction == 1 || direction == 3 ? (x1 - x0) : (z1 - z0)) * g * 0.4f;
					BuildingLine(world, mid - dir * len, mid + dir * len, color);
				}
				ShadowText(.(mouse.x + 16, mouse.y + 12), .(1, 0.85f, 0.4f, 0.95f), label);
				if (!ImGui.IsMouseDown(0))
				{
					mBuildDragging = false;
					FinishBuildDrag(go, plan, grid, x0, z0, x1, z1);
				}
			}
			else if (onFloor && hovered)
			{
				// The square under the pointer.
				let color = Color(1, 1, 1, 0.8f);
				let a = Vector3(cx * g, floorY, cz * g);
				let b = Vector3((cx + 1) * g, floorY, cz * g);
				let c = Vector3((cx + 1) * g, floorY, (cz + 1) * g);
				let d = Vector3(cx * g, floorY, (cz + 1) * g);
				BuildingLine(world, a, b, color);
				BuildingLine(world, b, c, color);
				BuildingLine(world, c, d, color);
				BuildingLine(world, d, a, color);
			}
		case .Door,.Window,.Opening:
			let kind = mBuildTool == .Door ? BuildingPlan.OpeningKind.Door : (mBuildTool == .Window ? BuildingPlan.OpeningKind.Window : BuildingPlan.OpeningKind.Opening);
			let hit = BuildingWallHit(grid, s, ray, mBuildStorey, let axis, let line, let along, let height);
			if (mBuildMovingOpening && mBuildOpening >= 0)
			{
				// Dragging the picked one along its wall (or onto another wall of the same storey).
				var o = plan.openings[mBuildOpening];
				if (hit)
				{
					var width = o.width;
					if (FitOpening(grid, s, axis, line, along, ref width, let center) && (axis != o.axis || line != o.line || Math.Abs(center - o.center) > 0.001f))
					{
						o.axis = axis;
						o.line = line;
						o.center = center;
						o.width = width;
						plan.openings[mBuildOpening] = o;
						mBuildOpeningMoved = true;
						// Shown at once; written to the plan when let go.
						let text = scope String();
						plan.Write(text);
						building.plan.Set(text);
						mBuildShownKey.Clear();
					}
				}
				if (!ImGui.IsMouseDown(0))
				{
					mBuildMovingOpening = false;
					if (mBuildOpeningMoved)
						CommitBuilding(go, plan);
				}
				return true;
			}
			if (!hit || !hovered)
				return true;
			// An existing door or window under the pointer: click picks it (and drags it), right-click removes it.
			int over = -1;
			for (int i < plan.openings.Count)
			{
				let o = plan.openings[i];
				let bottom = o.kind == .Window ? o.sill : 0;
				if (o.storey == mBuildStorey && o.axis == axis && o.line == line && Math.Abs(along - o.center) <= o.width / 2 && height >= bottom - 0.1f && height <= bottom + o.height + 0.1f)
					over = i;
			}
			if (over >= 0)
			{
				OpeningBox(plan.openings[over], s, let a, let b, let c, let d);
				let color = Color(1, 0.85f, 0.3f, 1);
				BuildingLine(world, a, b, color);
				BuildingLine(world, b, c, color);
				BuildingLine(world, c, d, color);
				BuildingLine(world, d, a, color);
				ShadowText(.(mouse.x + 16, mouse.y + 12), .(1, 0.85f, 0.4f, 0.95f), scope $"{BuildingPlan.OpeningNames[(int)plan.openings[over].kind]}: click to pick and drag  ·  right-click: remove");
				if (ImGui.IsMouseClicked(0))
				{
					mBuildOpening = over;
					mBuildMovingOpening = true;
					mBuildOpeningMoved = false;
				}
				else if (ImGui.IsMouseClicked(1))
				{
					plan.openings.RemoveAt(over);
					mBuildOpening = -1;
					CommitBuilding(go, plan);
				}
				return true;
			}
			var opening = BuildingPlan.Opening();
			opening.kind = kind;
			opening.storey = mBuildStorey;
			opening.axis = axis;
			opening.line = line;
			opening.width = kind == .Door ? mBuildDoorWidth : (kind == .Window ? mBuildWindowWidth : mBuildOpeningWidth);
			opening.height = kind == .Door ? mBuildDoorHeight : (kind == .Window ? mBuildWindowHeight : mBuildOpeningHeight);
			opening.sill = kind == .Window ? mBuildWindowSill : 0;
			if (!FitOpening(grid, s, axis, line, along, ref opening.width, out opening.center))
			{
				ShadowText(.(mouse.x + 16, mouse.y + 12), .(1, 0.5f, 0.4f, 0.95f), "Too little wall here (corners and other walls are in the way)");
				return true;
			}
			OpeningBox(opening, s, let a, let b, let c, let d);
			let color = Color(0.4f, 1, 0.55f, 1);
			var fill = color;
			fill.a = 0.2f;
			BuildingQuad(world, a, b, c, d, fill);
			BuildingLine(world, a, b, color);
			BuildingLine(world, b, c, color);
			BuildingLine(world, c, d, color);
			BuildingLine(world, d, a, color);
			ShadowText(.(mouse.x + 16, mouse.y + 12), .(1, 0.85f, 0.4f, 0.95f), scope $"{BuildingPlan.OpeningNames[(int)kind]} {opening.width:0.0#} x {opening.height:0.0#} m  ·  click to put it in");
			if (ImGui.IsMouseClicked(0))
			{
				plan.openings.Add(opening);
				mBuildOpening = plan.openings.Count - 1;
				CommitBuilding(go, plan);
			}
		default:
		}
		return true;
	}

	/// Which way stairs being dragged climb: from where the drag started towards the pointer, along the longer side.
	int32 StairDirection()
	{
		let dx = mBuildToX - mBuildFromX, dz = mBuildToZ - mBuildFromZ;
		if (Math.Abs(dx) > Math.Abs(dz))
			return dx > 0 ? 1 : 3;
		return dz >= 0 ? 0 : 2;
	}

	void FinishBuildDrag(GameObject go, BuildingPlan plan, BuildingGrid grid, int32 x0, int32 z0, int32 x1, int32 z1)
	{
		let single = x1 - x0 == 1 && z1 - z0 == 1;
		switch (mBuildTool)
		{
		case .Room:
			let under = grid.Get(mBuildFromX, mBuildFromZ);
			if (single && under != 0)
			{
				// A click on a room picks it.
				mBuildRoom = under;
				return;
			}
			// Shift: more squares for the picked room (or the one the drag started in), on this storey.
			var room = mBuildRoom != 0 ? mBuildRoom : under;
			let existing = room != 0 ? plan.FindRoom(room) : null;
			if (!ImGui.IsKeyDown(ImGui.Key.LeftShift) || existing == null || existing.storey != mBuildStorey)
				room = plan.AddRoom(mBuildStorey).id;
			plan.rects.Add(.() { room = room, storey = mBuildStorey, x0 = x0, z0 = z0, x1 = x1, z1 = z1 });
			mBuildRoom = room;
			CommitBuilding(go, plan);
		case .Erase:
			plan.rects.Add(.() { room = 0, storey = mBuildStorey, x0 = x0, z0 = z0, x1 = x1, z1 = z1 });
			CompactBuildingRects(plan, mBuildStorey);
			CommitBuilding(go, plan);
		case .Stairs:
			let direction = StairDirection();
			let length = direction == 1 || direction == 3 ? x1 - x0 : z1 - z0;
			if (length < 2)
			{
				Log.Warning("Stairs need at least two squares of length: drag from their foot towards the top.");
				return;
			}
			plan.stairs.Add(.() { storey = mBuildStorey, x0 = x0, z0 = z0, x1 = x1, z1 = z1, direction = direction });
			CommitBuilding(go, plan);
		default:
		}
	}

	/// Takes a room's squares out (rooms it was drawn over do not come back), so Prune drops it.
	void RemoveBuildingRoom(BuildingPlan plan, BuildingGrid grid, int32 room)
	{
		for (int32 z = grid.minZ; z < grid.minZ + grid.depth; z++)
		{
			var x = grid.minX;
			while (x < grid.minX + grid.width)
			{
				if (grid.Get(x, z) != room)
				{
					x++;
					continue;
				}
				let from = x;
				while (x < grid.minX + grid.width && grid.Get(x, z) == room)
					x++;
				plan.rects.Add(.() { room = 0, storey = mBuildStorey, x0 = from, z0 = z, x1 = x, z1 = z + 1 });
			}
		}
		CompactBuildingRects(plan, mBuildStorey);
		if (mBuildRoom == room)
			mBuildRoom = 0;
	}

	/// Drops rectangles of a storey that later ones cover completely, so erasing does not make the plan grow forever.
	static void CompactBuildingRects(BuildingPlan plan, int32 storey)
	{
		for (int i = plan.rects.Count - 1; i >= 0; i--)
		{
			let r = plan.rects[i];
			if (r.storey != storey)
				continue;
			bool covered = false;
			for (int j = i + 1; j < plan.rects.Count && !covered; j++)
			{
				let o = plan.rects[j];
				covered = o.storey == storey && o.x0 <= r.x0 && o.z0 <= r.z0 && o.x1 >= r.x1 && o.z1 >= r.z1;
			}
			// An erasing rectangle with nothing under it, first in the storey, erases nothing.
			if (!covered && r.room == 0)
			{
				bool anyBefore = false;
				for (int j < i)
					anyBefore |= plan.rects[j].storey == storey;
				covered = !anyBefore;
			}
			if (covered)
				plan.rects.RemoveAt(i);
		}
	}

	/// The grid round the storey, the floor below as a faint outline, room names and the picked door or window.
	void DrawBuildingPlan(GameObject go, BuildingPlan plan, BuildingGrid grid, BuildingGenerator.Settings s, Matrix4 world, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		let g = s.grid;
		let y = mBuildStorey * s.storeyHeight + s.floor + 0.01f;
		if (mBuildTool != .None)
		{
			// The grid: round the rooms with room to grow, or round the origin.
			let pad = (int32)Math.Max(6, 4 / g);
			var x0 = grid.minX - pad, x1 = grid.minX + grid.width + pad, z0 = grid.minZ - pad, z1 = grid.minZ + grid.depth + pad;
			if (grid.width == 0)
			{
				let below = scope BuildingGrid();
				below.Make(plan, Math.Max(mBuildStorey - 1, 0));
				x0 = below.width > 0 ? below.minX - pad : -pad * 2;
				x1 = below.width > 0 ? below.minX + below.width + pad : pad * 2;
				z0 = below.width > 0 ? below.minZ - pad : -pad * 2;
				z1 = below.width > 0 ? below.minZ + below.depth + pad : pad * 2;
			}
			let minor = Color(1, 1, 1, 0.12f), major = Color(1, 1, 1, 0.3f);
			let majorEvery = (int32)Math.Max(Math.Round(1 / g), 1);
			for (var x = x0; x <= x1; x++)
				BuildingLine(world, .(x * g, y, z0 * g), .(x * g, y, z1 * g), (x % majorEvery == 0) ? major : minor, false);
			for (var z = z0; z <= z1; z++)
				BuildingLine(world, .(x0 * g, y, z * g), .(x1 * g, y, z * g), (z % majorEvery == 0) ? major : minor, false);
		}
		// The storey below, as an outline to line the rooms up with.
		if (mBuildStorey > 0)
		{
			let below = scope BuildingGrid();
			below.Make(plan, mBuildStorey - 1);
			let color = Color(0.55f, 0.8f, 1, 0.55f);
			for (int32 axis < 2)
			{
				let lineFrom = axis == 0 ? below.minZ : below.minX, lineTo = axis == 0 ? below.minZ + below.depth : below.minX + below.width;
				let alongFrom = axis == 0 ? below.minX : below.minZ, alongTo = axis == 0 ? below.minX + below.width : below.minZ + below.depth;
				for (var line = lineFrom; line <= lineTo; line++)
				{
					for (var a = alongFrom; a < alongTo; a++)
					{
						if (!below.IsWall(axis, line, a))
							continue;
						if (axis == 0)
							BuildingLine(world, .(a * g, y, line * g), .((a + 1) * g, y, line * g), color);
						else
							BuildingLine(world, .(line * g, y, a * g), .(line * g, y, (a + 1) * g), color);
					}
				}
			}
		}
		// Room names in the middle of their squares; the picked room outlined.
		for (let room in plan.rooms)
		{
			if (room.storey != mBuildStorey)
				continue;
			float sx = 0, sz = 0;
			int count = 0;
			for (int32 z = grid.minZ; z < grid.minZ + grid.depth; z++)
			{
				for (int32 x = grid.minX; x < grid.minX + grid.width; x++)
				{
					if (grid.Get(x, z) == room.id)
					{
						sx += x + 0.5f;
						sz += z + 0.5f;
						count++;
					}
				}
			}
			if (count == 0)
				continue;
			let middle = world.TransformPoint(.(sx / count * g, y + 0.05f, sz / count * g));
			if (SceneToScreen(middle, origin, size, let at))
			{
				let label = scope String();
				label.AppendF("{}  {:0.#} m²", room.name, count * g * g);
				let width = ImGui.CalcStringSize(label).x;
				ShadowText(.(at.x - width / 2, at.y - 8), room.id == mBuildRoom ? Color(1, 0.85f, 0.35f, 1) : Color(1, 1, 1, 0.9f), label);
			}
			if (room.id == mBuildRoom)
			{
				let color = Color(1, 0.85f, 0.3f, 1);
				for (int32 axis < 2)
				{
					for (int32 z = grid.minZ; z <= grid.minZ + grid.depth; z++)
					{
						for (int32 x = grid.minX; x <= grid.minX + grid.width; x++)
						{
							// The edges of the room's squares that face something else.
							if (axis == 0 && (grid.Get(x, z - 1) == room.id) != (grid.Get(x, z) == room.id))
								BuildingLine(world, .(x * g, y + 0.03f, z * g), .((x + 1) * g, y + 0.03f, z * g), color);
							if (axis == 1 && (grid.Get(x - 1, z) == room.id) != (grid.Get(x, z) == room.id))
								BuildingLine(world, .(x * g, y + 0.03f, z * g), .(x * g, y + 0.03f, (z + 1) * g), color);
						}
					}
				}
			}
		}
		if (mBuildOpening >= 0 && mBuildOpening < plan.openings.Count && plan.openings[mBuildOpening].storey == mBuildStorey)
		{
			OpeningBox(plan.openings[mBuildOpening], s, let a, let b, let c, let d);
			let color = Color(1, 0.85f, 0.3f, 1);
			BuildingLine(world, a, b, color);
			BuildingLine(world, b, c, color);
			BuildingLine(world, c, d, color);
			BuildingLine(world, d, a, color);
		}
	}

	void SetBuildTool(BuildTool tool)
	{
		mBuildTool = tool;
		mBuildDragging = false;
		mBuildMovingOpening = false;
		mModelEditing = false;
		mModelDraw = .Off;
	}

	/// Up or down a storey: up to one above the top (to start a new one).
	void SetBuildStorey(BuildingPlan plan, int32 storey)
	{
		mBuildStorey = Math.Clamp(storey, 0, plan.TopStorey + 1);
		mBuildRoom = 0;
		mBuildOpening = -1;
	}

	// ------------------------------------------------------------------ the bar over the Scene view

	void DrawBuildingBar(GameObject go, BuildingPlan plan, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (size.x < 260 || size.y < 120)
			return;
		ModelBarBegin(origin, size);
		ImGui.PushID("buildbar");
		ModelBarBackground();
		if (ModelBarButton("##down", "\u{f078}", "", false, mBuildStorey > 0))
			SetBuildStorey(plan, mBuildStorey - 1);
		ModelTip("Storey below", "", "Work on the storey below.");
		let storeyName = StoreyName(mBuildStorey, .. scope .());
		if (mBuildStorey > plan.TopStorey)
			storeyName.Append(" (new)");
		ModelBarText(storeyName);
		if (ModelBarButton("##up", "\u{f077}", "", false, mBuildStorey <= plan.TopStorey))
			SetBuildStorey(plan, mBuildStorey + 1);
		ModelTip("Storey above", "", "Work on the storey above. One above the top starts a new storey: draw its rooms over the one below (shown as an outline).");
		ModelBarGap();
		for (int t = 1; t < sBuildToolNames.Count; t++)
		{
			ImGui.PushID((int32)t);
			if (ModelBarButton("##tool", scope $"{sBuildToolIcons[t]}  {sBuildToolNames[t]}", scope $"{t}", (int)mBuildTool == t))
				SetBuildTool((int)mBuildTool == t ? .None : (BuildTool)t);
			ModelTip(sBuildToolNames[t], scope $"{t} (while a tool is on)", sBuildToolTips[t]);
			ImGui.PopID();
		}
		ModelBarGap();
		if (ModelBarButton("##cutaway", sBuildCutawayNames[mBuildCutaway], "", mBuildCutaway != 0))
			mBuildCutaway = (mBuildCutaway + 1) % 3;
		ModelTip("What is shown", "", "See All: the whole building. Cut Away: the storeys above and this storey's ceiling are hidden while the building is selected, to see into its rooms. Low Walls: and this storey's walls are cut low. Only the Scene view; the game always has the whole building.");
		if (mBuildTool != .None)
		{
			if (ModelBarButton("##done", "\u{f00c}  Done", "Esc", false))
				SetBuildTool(.None);
			ModelTip("Done", "Esc", "Back to picking and moving whole objects.");
		}
		ModelBarEndRow();
		ImGui.PopID();
		StringView hint;
		switch (mBuildTool)
		{
		case .Room: hint = "Drag out a room  ·  Shift+drag: add to the picked room  ·  click a room: pick it  ·  right-click a room: remove it  ·  Esc: done";
		case .Erase: hint = "Drag over squares to take them out  ·  walls close round what is left";
		case .Door,.Window,.Opening: hint = "Click a wall to put one in  ·  click one to pick it, drag to move it  ·  right-click or Delete: remove  ·  Alt: no snapping";
		case .Stairs: hint = "Drag from the foot of the stairs towards the top  ·  right-click stairs: remove";
		default: hint = "Pick a tool: Room to draw rooms, Door and Window to cut them into walls";
		}
		let status = scope String();
		status.AppendF("Building: {} rooms, {} doors and windows", plan.rooms.Count, plan.openings.Count);
		DrawModelHintBar(origin, size, status, hint);
	}

	// ------------------------------------------------------------------ the Model window's Building tab

	void DrawBuildingTab(GameObject selected)
	{
		let building = SelectedBuilding;
		if (!building.IsValid)
		{
			ImGui.Spacing();
			ModelNote("Block out a building with its rooms: drag rooms out on a grid and the walls build themselves. Click doors and windows onto walls and they are cut out. Add storeys and stairs between them.");
			ImGui.Spacing();
			if (ModelBigButton("New Building"))
				CreateBuildingInView();
			ModelHint("Makes a building where the Scene view is looking, with the Room tool on.");
			if (selected != null && selected.HasComponent<Building>() && !selected.GetComponent<ModelMesh>().IsValid)
				ModelNote("The selected object has a Building but no Model Mesh to make it into: add one.");
			return;
		}
		let go = building.GameObject;
		let plan = scope BuildingPlan();
		ReadBuildingPlan(building, plan);

		ImGui.SeparatorText("Storey");
		ImGui.BeginDisabled(mBuildStorey == 0);
		if (ImGui.Button("\u{f078}##storeydown"))
			SetBuildStorey(plan, mBuildStorey - 1);
		ImGui.EndDisabled();
		ImGui.SameLine();
		let storeyName = StoreyName(mBuildStorey, .. scope .());
		if (mBuildStorey > plan.TopStorey)
			storeyName.Append(" (new: draw its rooms)");
		ImGui.AlignTextToFramePadding();
		ImGui.Text(storeyName);
		ImGui.SameLine();
		ImGui.BeginDisabled(mBuildStorey > plan.TopStorey);
		if (ImGui.Button("\u{f077}##storeyup"))
			SetBuildStorey(plan, mBuildStorey + 1);
		ImGui.EndDisabled();
		ModelGridBegin(96, 3);
		for (int32 c < 3)
		{
			let width = ModelGridNext();
			ImGui.PushID(c);
			if (ModelButton("##cut", sBuildCutawayNames[c], "", width, mBuildCutaway == c))
				mBuildCutaway = c;
			ImGui.PopID();
		}

		ImGui.SeparatorText("Tools");
		ModelGridBegin(96, 3);
		for (int t = 1; t < sBuildToolNames.Count; t++)
		{
			let width = ModelGridNext();
			ImGui.PushID((int32)t);
			if (ModelButton("##tool", scope $"{sBuildToolIcons[t]}  {sBuildToolNames[t]}", scope $"{t}", width, (int)mBuildTool == t))
				SetBuildTool((int)mBuildTool == t ? .None : (BuildTool)t);
			ModelTip(sBuildToolNames[t], "", sBuildToolTips[t]);
			ImGui.PopID();
		}
		if (mBuildTool != .None)
			ModelNote(sBuildToolTips[(int)mBuildTool]);

		// The picked door or window, or the sizes new ones get.
		if (mBuildOpening >= 0 && mBuildOpening < plan.openings.Count)
		{
			var o = plan.openings[mBuildOpening];
			ImGui.SeparatorText(scope $"Picked {BuildingPlan.OpeningNames[(int)o.kind]}" .CStr());
			bool changed = false;
			changed |= ModelNumber("Width", ref o.width, 0.01f, 0.3f, 20, "%.2f m");
			changed |= ModelNumber("Height", ref o.height, 0.01f, 0.2f, building.storeyHeight, "%.2f m");
			if (o.kind == .Window)
				changed |= ModelNumber("Sill", ref o.sill, 0.01f, 0, building.storeyHeight, "%.2f m");
			if (changed)
			{
				plan.openings[mBuildOpening] = o;
				CommitBuilding(go, plan);
			}
			if (ImGui.Button("Remove", .(-1, 0)))
			{
				plan.openings.RemoveAt(mBuildOpening);
				mBuildOpening = -1;
				CommitBuilding(go, plan);
			}
		}
		else if (mBuildTool == .Door || mBuildTool == .Window || mBuildTool == .Opening)
		{
			ImGui.SeparatorText(scope $"New {sBuildToolNames[(int)mBuildTool]}s" .CStr());
			switch (mBuildTool)
			{
			case .Door:
				ModelNumber("Width", ref mBuildDoorWidth, 0.01f, 0.3f, 10, "%.2f m");
				ModelNumber("Height", ref mBuildDoorHeight, 0.01f, 0.5f, 10, "%.2f m");
			case .Window:
				ModelNumber("Width", ref mBuildWindowWidth, 0.01f, 0.2f, 10, "%.2f m");
				ModelNumber("Height", ref mBuildWindowHeight, 0.01f, 0.2f, 10, "%.2f m");
				ModelNumber("Sill", ref mBuildWindowSill, 0.01f, 0, 10, "%.2f m");
			default:
				ModelNumber("Width", ref mBuildOpeningWidth, 0.01f, 0.3f, 20, "%.2f m");
				ModelNumber("Height", ref mBuildOpeningHeight, 0.01f, 0.5f, 10, "%.2f m");
			}
		}

		// The rooms of this storey.
		ImGui.SeparatorText("Rooms");
		bool anyRoom = false;
		for (let room in plan.rooms)
		{
			if (room.storey != mBuildStorey)
				continue;
			anyRoom = true;
			ImGui.PushID(room.id);
			var color = room.color;
			if (ImGui.ColorEdit3("##color", ref color, 32 | 128))
			{
				room.color = color;
				CommitBuilding(go, plan);
			}
			ImGui.SameLine();
			if (room.id == mBuildRoom)
			{
				ImGui.SetNextItemWidth(-ImGui.GetFrameHeight() - 6);
				let name = scope String(room.name);
				if (ImGui.InputText("##name", name) && !name.IsEmpty && !name.Contains('\n'))
				{
					room.name.Set(name);
					CommitBuilding(go, plan);
				}
				ImGui.SameLine();
				if (ImGui.Button("\u{f1f8}##remove", .(ImGui.GetFrameHeight(), 0)))
				{
					let grid = scope BuildingGrid();
					grid.Make(plan, mBuildStorey);
					RemoveBuildingRoom(plan, grid, room.id);
					CommitBuilding(go, plan);
					ImGui.PopID();
					break;
				}
				ModelHint("Removes this room. Its walls go, or close up round the rooms beside it.");
			}
			else if (ImGui.Selectable(room.name.CStr()))
				mBuildRoom = room.id;
			ImGui.PopID();
		}
		if (!anyRoom)
			ModelNote("No rooms on this storey yet: pick Room and drag one out in the Scene view.");

		ImGui.SeparatorText("Building");
		var storeyHeight = building.storeyHeight, wall = building.wallThickness, gridSize = building.gridSize, floor = building.floorThickness;
		bool settings = false;
		settings |= ModelNumber("Storey", ref storeyHeight, 0.01f, 2, 12, "%.2f m");
		ModelHint("From one floor to the next.");
		settings |= ModelNumber("Walls", ref wall, 0.005f, 0.05f, 1, "%.2f m");
		settings |= ModelNumber("Floors", ref floor, 0.005f, 0.02f, 1, "%.2f m");
		settings |= ModelNumber("Grid", ref gridSize, 0.01f, 0.25f, 4, "%.2f m");
		ModelHint("The size of the squares rooms are drawn on. Changing it scales the whole plan.");
		var roomColors = building.roomColors;
		if (ImGui.Checkbox("Room colours on floors", ref roomColors))
		{
			building.roomColors = roomColors;
			settings = true;
		}
		if (settings)
		{
			building.storeyHeight = Math.Clamp(storeyHeight, 2, 12);
			building.wallThickness = Math.Clamp(wall, 0.05f, 1);
			building.floorThickness = Math.Clamp(floor, 0.02f, 1);
			building.gridSize = Math.Clamp(gridSize, 0.25f, 4);
			Building.Rebuild(go);
			mBuildShownKey.Clear();
			MarkDirty();
		}
		ImGui.Spacing();
		if (ImGui.Button("Bake to Model", .(-1, 0)))
			BakeBuilding(go);
		ModelHint("Keeps the walls as an ordinary model and drops the plan: to shape it further with the model tools (Edit tab). The Building tools no longer work on it.");
	}
}
