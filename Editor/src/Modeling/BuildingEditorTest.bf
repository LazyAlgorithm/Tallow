using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// Test switch --building-test: lays a building out with the Building tools as the Scene view does (two rooms
/// side by side, a door and a window, a storey above, stairs), checks the walls, holes, floors and roofs with rays,
/// the cut-away, undo, erasing and the plan's text, then logs BUILDING-TEST PASS or FAIL and leaves the building
/// selected and cut away for a screenshot (--building-storey N picks the storey shown, --building-cutaway 0-2 the
/// view: See All, Cut Away, Low Walls).
extension EditorApp
{
	int32 mBuildTestFrames;

	void TickBuildingTest()
	{
		if (mBuildTestFrames > 0 && --mBuildTestFrames == 0)
			RunBuildingTest();
	}

	void RunBuildingTest()
	{
		bool pass = true;
		let report = scope String();
		void Expect(bool condition, StringView what)
		{
			report.AppendF("{}{}: {}", report.IsEmpty ? "" : "; ", what, condition);
			pass &= condition;
		}
		mShowModel = true;
		mUndoPending = false;
		CommitSceneStep();

		let go = CreateBuildingInView();
		// Where New Building put it (on the ground under the view); the checks below are in its own space.
		let placed = go.Transform.Position;
		let building = go.GetComponent<Building>();
		Expect(building.IsValid && SelectedBuilding.IsValid && mBuildTool == .Room, "New Building makes a building, selected, with the Room tool on");

		BuildingPlan Plan()
		{
			let plan = new BuildingPlan();
			plan.Read(building.plan);
			return plan;
		}
		void Drag(BuildTool tool, int32 fromX, int32 fromZ, int32 toX, int32 toZ)
		{
			mBuildTool = tool;
			mBuildFromX = fromX;
			mBuildFromZ = fromZ;
			mBuildToX = toX;
			mBuildToZ = toZ;
			let plan = scope BuildingPlan();
			plan.Read(building.plan);
			let grid = scope BuildingGrid();
			grid.Make(plan, mBuildStorey);
			FinishBuildDrag(go, plan, grid, Math.Min(fromX, toX), Math.Min(fromZ, toZ), Math.Max(fromX, toX) + 1, Math.Max(fromZ, toZ) + 1);
		}
		// The first thing a ray from `from` along `direction` meets in the model (local space), or float.MaxValue.
		float Hit(Vector3 from, Vector3 direction)
		{
			let mesh = go.GetComponent<ModelMesh>().Edit;
			if (mesh.Raycast(.(from, direction.Normalized), let distance, ?) < 0)
				return float.MaxValue;
			return distance;
		}
		bool Near(float a, float b)
		{
			if (Math.Abs(a - b) < 0.01f)
				return true;
			report.AppendF(" [hit {} expected {}]", a, b);
			return false;
		}

		// Two rooms side by side on a 0.5 m grid: A 4 x 4 m from the origin, B 3 x 4 m east of it.
		mBuildStorey = 0;
		Drag(.Room, 0, 0, 7, 7);
		Drag(.Room, 8, 0, 13, 7);
		var plan = Plan();
		Expect(plan.rooms.Count == 2 && plan.rects.Count == 2, scope $"two rooms drawn ({plan.rooms.Count} rooms)");
		delete plan;
		let model = go.GetComponent<ModelMesh>();
		Expect(model.Edit.faces.Count > 0 && go.GetComponent<MeshRenderer>().ActiveMesh != null, scope $"the walls are made into the model ({model.Edit.faces.Count} faces)");
		// Walls are 0.2 thick, centred on the room edges; floors 0.2, storeys 3.
		Expect(Near(Hit(.(-2, 1, 2), .(1, 0, 0)), 1.9f), "outside wall on the west");
		Expect(Near(Hit(.(2, 1, 2), .(1, 0, 0)), 1.9f), "one wall between the two rooms");
		Expect(Near(Hit(.(2, 1.5f, 2), .(0, -1, 0)), 1.3f), "a floor (0.2 thick) in the room");
		Expect(Near(Hit(.(2, 1.5f, 2), .(0, 1, 0)), 1.5f), "a roof on the walls (3 m up)");
		Expect(Near(Hit(.(5.5f, 1, 2), .(-1, 0, 0)), 1.4f), "the second room's side of the shared wall");

		// A door in the shared wall (x = 4 m: axis 1, line 8), 1 wide, 2.1 high, its middle at z = 2.
		mBuildTool = .Door;
		plan = Plan();
		let grid = scope BuildingGrid();
		grid.Make(plan, 0);
		var width = mBuildDoorWidth;
		Expect(FitOpening(grid, BuildingGenerator.Settings.From(building), 1, 8, 2.1f, ref width, let center) && Near(center, 2), scope $"a door's middle snaps along the wall ({center})");
		plan.openings.Add(.() { kind = .Door, storey = 0, axis = 1, line = 8, center = center, width = width, height = mBuildDoorHeight });
		// A window in the south wall (z = 0: axis 0, line 0) of room A.
		plan.openings.Add(.() { kind = .Window, storey = 0, axis = 0, line = 0, center = 2, width = mBuildWindowWidth, height = mBuildWindowHeight, sill = mBuildWindowSill });
		CommitBuilding(go, plan);
		delete plan;
		Expect(Near(Hit(.(2, 1, 2), .(1, 0, 0)), 4.9f), "through the door to room B's far wall");
		Expect(Near(Hit(.(2, 2.6f, 2), .(1, 0, 0)), 1.9f), "the wall over the door is still there");
		Expect(Near(Hit(.(4, 1, 2), .(0, -1, 0)), 0.8f), "the door's threshold is level with the floors");
		Expect(Near(Hit(.(2, 1.6f, -2), .(0, 0, 1)), 5.9f), "through the window to the north wall");
		Expect(Near(Hit(.(2, 0.6f, -2), .(0, 0, 1)), 1.9f), "the wall under the window");
		// A door near a corner is kept on the wall, clear of the corner post.
		width = 1;
		FitOpening(grid, BuildingGenerator.Settings.From(building), 1, 8, 0.1f, ref width, let cornered);
		Expect(cornered - width / 2 >= 0.1f - 0.001f, scope $"a door at a corner is kept clear of the post ({cornered})");

		// A storey above room A, and stairs in room B up to it.
		mBuildStorey = 1;
		Drag(.Room, 0, 0, 7, 7);
		mBuildStorey = 0;
		Drag(.Stairs, 9, 1, 10, 6);
		plan = Plan();
		Expect(plan.TopStorey == 1 && plan.stairs.Count == 1 && plan.stairs[0].direction == 0, "a storey above and stairs climbing north");
		delete plan;
		Expect(Near(Hit(.(2, 1.5f, 2), .(0, 1, 0)), 1.5f), "the floor above is the ceiling below");
		Expect(Near(Hit(.(2, 4.5f, 2), .(0, 1, 0)), 1.5f), "a roof over the top storey");
		Expect(Near(Hit(.(6, 10, 2), .(0, -1, 0)), 6.8f), "room B's roof");
		let overStairs = Hit(.(5, 10, 3), .(0, -1, 0));
		Expect(overStairs > 7 && overStairs < 9.8f, scope $"a hole in the roof over the stairs, down to a step ({10 - overStairs:0.##} m)");
		let foot = Hit(.(5, 0.5f, 0.2f), .(0, 0, 1));
		Expect(foot < 0.6f, scope $"the first step at the foot of the stairs ({foot:0.##})");

		// The cut-away: working on the ground floor hides the storey above and the ceilings.
		mBuildCutaway = 1;
		mBuildStorey = 0;
		UpdateBuildingCutaway();
		let full = model.Edit.faces.Count;
		Expect(model.Previewing && model.DrawnMesh != null, "cut away while the building is selected");
		let cutMesh = scope EditMesh();
		{
			let cutPlan = Plan();
			defer delete cutPlan;
			var settings = BuildingGenerator.Settings.From(building);
			settings.cutaway = true;
			settings.topStorey = 0;
			BuildingGenerator.Generate(cutPlan, settings, cutMesh);
		}
		Expect(cutMesh.faces.Count < full && cutMesh.Bounds.max.y < 3.25f, scope $"the cut-away has no storey above, only the stairs reach up ({cutMesh.faces.Count} of {full} faces, up to {cutMesh.Bounds.max.y:0.##} m)");
		Expect(model.Edit.faces.Count == full, "the model itself is left whole");
		mBuildCutaway = 0;
		UpdateBuildingCutaway();
		Expect(!model.Previewing, "See All draws the whole building again");
		mBuildCutaway = 1;

		// The Inspector's settings make the walls again (Building.OnValidate).
		building.storeyHeight = 3.5f;
		Building.Rebuild(go);
		Expect(Near(Hit(.(2, 1.5f, 2), .(0, 1, 0)), 2), "a taller storey height raises the ceiling");
		building.storeyHeight = 3;
		Building.Rebuild(go);
		let text = scope String(model.data);
		Expect(Building.Rebuild(go) && model.data == text, "making it again from the same plan changes nothing");

		// Undo and redo go through the plan and the model together.
		mUndoPending = false;
		CommitSceneStep();
		mBuildStorey = 0;
		Drag(.Erase, 8, 0, 13, 7);
		plan = Plan();
		Expect(plan.rooms.Count == 2 && plan.stairs.Count == 0 && plan.openings.Count == 2, scope $"erasing room B drops it and its stairs, the door stays in A's wall ({plan.rooms.Count} rooms, {plan.stairs.Count} stairs, {plan.openings.Count} openings)");
		delete plan;
		Expect(Hit(.(2, 1, 2), .(1, 0, 0)) == float.MaxValue, "the door now leads outside");
		mUndoPending = false;
		CommitSceneStep();
		Undo();
		let undoneGo = mScene.FindById(go.Id);
		Building undone = undoneGo != null ? undoneGo.GetComponent<Building>() : default;
		let undonePlan = scope BuildingPlan();
		if (undone.IsValid)
			undonePlan.Read(undone.plan);
		Expect(undone.IsValid && undonePlan.rooms.Count == 3 && undonePlan.stairs.Count == 1, "undo brings room B and the stairs back");
		Redo();

		// The plan's text reads back as it was written.
		let again = scope BuildingPlan();
		let goNow = mScene.FindById(go.Id);
		let buildingNow = goNow.GetComponent<Building>();
		again.Read(buildingNow.plan);
		let written = scope String();
		again.Write(written);
		Expect(written == buildingNow.plan, "the plan's text reads back the same");

		// Bring room B and the stairs back for the screenshot, and put the camera on the building.
		Undo();
		mSelectedId = go.Id;
		var storey = 0;
		let storeyArg = scope String();
		if (GetArg("--building-storey", storeyArg))
			storey = int32.Parse(storeyArg).GetValueOrDefault();
		mBuildStorey = (int32)storey;
		mBuildTool = HasArg("--building-door") ? .Door : .Room;
		let cutawayArg = scope String();
		if (GetArg("--building-cutaway", cutawayArg))
			mBuildCutaway = Math.Clamp(int32.Parse(cutawayArg).GetValueOrDefault(), 0, 2);
		mModelShotFrames = 12;
		mModelTabRequest = (int)ModelTab.Building;
		mCamPosition = placed + Vector3(3.5f, 9.5f, -6.5f);
		mCamYaw = 0;
		mCamPitch = 52;
		Log.Info(scope $"BUILDING-TEST {pass ? "PASS" : "FAIL"}: {report}");
	}
}
