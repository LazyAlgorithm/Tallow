using System;
using System.Collections;
using Tallow;

namespace Tallow.Editor;

/// The modeller's bar over the Scene view (and the Model View the pointer is in), so modelling needs no window:
/// - with nothing being edited: Draw a shape (and which), and for a selected model Edit Model and Cut a Hole;
/// - while drawing: what is being drawn, Keep Drawing, Snap and Stop;
/// - in edit mode: Done, what is picked (vertices, edges, faces), the options, every tool's menu and search, and
///   down the left the tools used most, each with its key.
/// A line at the bottom of the view says what the mouse and keys do right now. The bar's buttons are the Model
/// window's (ModelWindow.bf): the same names, keys and tooltips.
extension EditorApp
{
	/// Where the bar's panels were drawn (min x, min y, max x, max y): this frame's, and the frame before's, which
	/// their backgrounds are drawn from and clicks are tested against.
	List<ImGui.Vec4> mModelBarRects = new .() ~ delete _;
	List<ImGui.Vec4> mModelBarLast = new .() ~ delete _;
	int64 mModelBarFrame = -10;
	bool mModelSearchRequest;

	// Laying the bar's row out: items go left to right and wrap when the view is narrow.
	float mBarLeft;
	float mBarRight;
	float mBarX;
	float mBarY;
	float mBarTop;
	float mBarMaxX;
	float mBarHeight;

	const float BarPad = 6;

	/// Whether the pointer is over the bar (as it was drawn last), so the scene under it is left alone.
	bool ModelBarHovered
	{
		get
		{
			if (Time.FrameCount - mModelBarFrame > 1)
				return false;
			let mouse = ImGui.GetMousePos();
			for (let r in mModelBarRects)
			{
				if (mouse.x >= r.x - BarPad && mouse.x <= r.z + BarPad && mouse.y >= r.y - BarPad && mouse.y <= r.w + BarPad)
					return true;
			}
			return false;
		}
	}

	void ModelBarBegin(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (mModelBarFrame != Time.FrameCount)
		{
			mModelBarLast.Clear();
			// A bar not drawn last frame has no backgrounds to carry over.
			if (Time.FrameCount - mModelBarFrame <= 1)
				mModelBarLast.AddRange(mModelBarRects);
			mModelBarRects.Clear();
			mModelBarFrame = Time.FrameCount;
		}
		mBarHeight = ImGui.GetFrameHeight() + 2;
		mBarLeft = origin.x + 12;
		// Clear of the view selector in the corner.
		mBarRight = origin.x + size.x - 118;
		mBarX = mBarLeft;
		mBarY = mBarTop = origin.y + 32;
		mBarMaxX = mBarLeft;
	}

	/// The panel behind the bar's next group of buttons, where that group was last frame.
	void ModelBarBackground()
	{
		let index = mModelBarRects.Count;
		if (index >= mModelBarLast.Count)
			return;
		let r = mModelBarLast[index];
		var back = ImGui.GetStyleColor(ImGui.Col.WindowBg);
		back.a = 0.9f;
		ImGui.DrawRectFilled(.(r.x - BarPad, r.y - BarPad + 1), .(r.z + BarPad, r.w + BarPad - 1), back, 6);
	}

	/// Places the row's next item, on a new line when it would not fit.
	void ModelBarPlace(float width)
	{
		if (mBarX > mBarLeft && mBarX + width > mBarRight)
		{
			mBarX = mBarLeft;
			mBarY += mBarHeight + 4;
		}
		ImGui.SetCursorScreenPos(.(mBarX, mBarY));
		mBarX += width + 4;
		mBarMaxX = Math.Max(mBarMaxX, mBarX - 4);
	}

	void ModelBarGap()
	{
		if (mBarX > mBarLeft)
			mBarX += 8;
	}

	float ModelBarWidth(StringView label, StringView keys) => ImGui.CalcStringSize(label).x + (keys.IsEmpty ? 0 : ImGui.CalcStringSize(keys).x + 10) + 18;

	bool ModelBarButton(char8* id, StringView label, StringView keys, bool lit, bool enabled = true)
	{
		let width = ModelBarWidth(label, keys);
		ModelBarPlace(width);
		return ModelButton(id, label, keys, width, lit, enabled, mBarHeight);
	}

	void ModelBarText(StringView text)
	{
		let size = ImGui.CalcStringSize(text);
		ModelBarPlace(size.x + 4);
		ImGui.DrawString(.(mBarX - size.x - 6, mBarY + (mBarHeight - size.y) * 0.5f), ImGui.GetStyleColor(ImGui.Col.Text), text);
	}

	/// Ends the row: remembers where it was.
	void ModelBarEndRow()
	{
		mModelBarRects.Add(.(mBarLeft, mBarTop, mBarMaxX, mBarY + mBarHeight));
	}

	/// The list of shapes under a bar button; picking one starts drawing it.
	void ModelBarShapes(char8* id, bool start, uint32 cutTarget = 0)
	{
		if (!ImGui.BeginPopup(id))
			return;
		ImGui.TextDisabled("Shape to draw");
		ImGui.Separator();
		for (int32 k < (int32)MeshShapes.Names.Count)
		{
			if (ImGui.MenuItem(scope String(MeshShapes.Names[k]).CStr(), null, k == mModelDrawKind))
			{
				mModelDrawKind = k;
				if (start)
					StartShapeDrawing(cutTarget);
			}
		}
		ImGui.EndPopup();
	}

	/// A line (or two) at the bottom left of the view: what is going on, and what the mouse and keys do now.
	void DrawModelHintBar(ImGui.Vec2 origin, ImGui.Vec2 size, StringView status, StringView hint)
	{
		// The camera's own line is there while flying.
		if (mFlying || size.y < 150)
			return;
		let lineHeight = ImGui.GetTextLineHeight() + 3;
		let lines = (status.IsEmpty ? 0 : 1) + (hint.IsEmpty ? 0 : 1);
		if (lines == 0)
			return;
		let width = Math.Min(Math.Max(ImGui.CalcStringSize(status).x, ImGui.CalcStringSize(hint).x), size.x - 44);
		let min = ImGui.Vec2(origin.x + 12, origin.y + size.y - 14 - lines * lineHeight - 8);
		let max = ImGui.Vec2(min.x + width + 20, origin.y + size.y - 14);
		var back = ImGui.GetStyleColor(ImGui.Col.WindowBg);
		back.a = 0.9f;
		ImGui.DrawRectFilled(min, max, back, 6);
		ImGui.PushClipRect(min, .(max.x - 6, max.y));
		var y = min.y + 5;
		if (!status.IsEmpty)
		{
			ImGui.DrawString(.(min.x + 10, y), EditorTheme.Warning, status);
			y += lineHeight;
		}
		if (!hint.IsEmpty)
		{
			var color = ImGui.GetStyleColor(ImGui.Col.Text);
			color.a = 0.82f;
			ImGui.DrawString(.(min.x + 10, y), color, hint);
		}
		ImGui.PopClipRect();
	}

	// ------------------------------------------------------------------ nothing being edited

	/// Draw a shape; for a selected model, Edit Model and Cut a Hole. Shown for a selected model, or whenever the
	/// Model window is open.
	void DrawModelIdleBar(GameObject selected, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		let isModel = selected != null && selected.GetComponent<ModelMesh>().IsValid;
		if ((!isModel && !mShowModel) || size.x < 260 || size.y < 120)
			return;
		ModelBarBegin(origin, size);
		ImGui.PushID("modelbar");
		ModelBarBackground();
		if (isModel)
		{
			if (ModelBarButton("##edit", "\u{f040}  Edit Model", FirstKey(ModelShortcutText(ShortcutEditMode)), true))
				StartModelEditing(selected);
			ModelTip("Edit mode", ModelShortcutText(ShortcutEditMode), "Pick this model's faces, edges and corners and pull, cut and bevel them.");
			ModelBarGap();
		}
		let shape = MeshShapes.Names[mModelDrawKind];
		if (ModelBarButton("##draw", scope $"\u{f067}  Draw {shape}", "", false))
			StartShapeDrawing();
		ModelTip("Draw a shape", "", "Drag out its base on the ground or a surface, let go, move up for the height and click. The quick way to block out a map.");
		if (ModelBarButton("##shape", "\u{f0d7}", "", false))
			ImGui.OpenPopup("##barshapes");
		ModelTip("Which shape", ModelKeys(.AddShape), "Box, ramp, stairs, cylinder and the rest.");
		ModelBarShapes("##barshapes", true);
		if (ModelBarButton("##building", "\u{f1ad}  Building", "", false))
			CreateBuildingInView();
		ModelTip("New building", "", "Drag rooms out on a grid and the walls build themselves; click doors and windows onto walls and they are cut out.");
		if (isModel)
		{
			if (ModelBarButton("##cut", "\u{f0c4}  Cut a Hole", "", false))
				StartShapeDrawing(selected.Id);
			ModelTip("Cut a Hole", "", scope $"Draw a {shape} through this model and it is cut out of it: doors, windows, pits.");
		}
		ModelBarEndRow();
		ImGui.PopID();
	}

	// ------------------------------------------------------------------ drawing a shape

	void DrawModelDrawBar(ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (size.x < 260 || size.y < 120)
			return;
		ModelBarBegin(origin, size);
		ImGui.PushID("modelbar");
		ModelBarBackground();
		let target = mModelCutTarget != 0 ? mScene.FindById(mModelCutTarget) : null;
		ModelBarText(target != null ? scope $"Cutting {target.Name} with a" : "Drawing a");
		if (ModelBarButton("##shape", scope $"{MeshShapes.Names[mModelDrawKind]}  \u{f0d7}", "", false, mModelDraw == .Waiting))
			ImGui.OpenPopup("##barshapes");
		ModelBarShapes("##barshapes", false);
		ModelBarGap();
		if (ModelBarButton("##keep", "Keep Drawing", "", mModelDrawKeep))
		{
			mModelDrawKeep = !mModelDrawKeep;
			SaveModelWindow();
		}
		ModelTip("Keep Drawing", "", "Go on drawing shapes one after another until Esc. Off, holding Shift on the last click does one more.");
		if (ModelBarButton("##snap", "Snap", "", mSnap))
			mSnap = !mSnap;
		ModelTip("Snap", "Ctrl", scope $"Snap the base and the height to the grid step ({mSnapMove:0.##} m). Holding Ctrl flips it.");
		if (ModelBarButton("##snapobjects", "Snap to Objects", "", mModelSnapObjects))
		{
			mModelSnapObjects = !mModelSnapObjects;
			SaveModelWindow();
		}
		ModelTip("Snap to Objects", "Alt: off for now", "The pointer near a corner, an edge or the middle of an edge of another object takes that point, for the base and for the height.");
		ModelBarGap();
		if (ModelBarButton("##stop", "Stop", "Esc", false))
			StopShapeDrawing();
		ModelBarEndRow();
		ImGui.PopID();
		StringView hint;
		switch (mModelDraw)
		{
		case .Base: hint = "Drag to the opposite corner of the base, then let go";
		case .Height: hint = "Move the pointer up or down for the height, then click";
		default: hint = "Drag out the base on the ground or a surface  ·  near a corner or edge it snaps (Alt: not)  ·  a click alone places one of the set size  ·  Esc: stop";
		}
		DrawModelHintBar(origin, size, default, hint);
	}

	// ------------------------------------------------------------------ edit mode

	void DrawModelBar(ModelMesh model, EditMesh mesh, ImGui.Vec2 origin, ImGui.Vec2 size)
	{
		if (size.x < 260 || size.y < 120)
			return;
		ModelBarBegin(origin, size);
		let busy = ModelToolActive;
		ModelCommand? run = null;
		ImGui.PushID("modelbar");
		ModelBarBackground();
		if (ModelBarButton("##done", "\u{f00c}  Done", FirstKey(ModelShortcutText(ShortcutEditMode)), false, !busy))
			mModelEditing = false;
		ModelTip("Leave edit mode", ModelShortcutText(ShortcutEditMode), "Back to moving whole objects.");
		ModelBarGap();
		if (mModelPainting)
		{
			ModelBarText(mModelPaintTexture ? "Painting the texture" : "Painting vertex colours");
			if (ModelBarButton("##stoppaint", "Stop Painting", "", false))
				mModelPainting = false;
		}
		else
		{
			for (let mode in ModelSelectMode[3](.Vertex, .Edge, .Face))
			{
				let action = mode == .Vertex ? ShortcutVertexMode : (mode == .Edge ? ShortcutEdgeMode : ShortcutFaceMode);
				let name = mode == .Vertex ? "Vertices" : (mode == .Edge ? "Edges" : "Faces");
				ImGui.PushID((int32)action);
				if (ModelBarButton("##mode", name, FirstKey(ModelShortcutText(action)), mModelMode == mode, !busy))
					SetModelMode(mode, mesh);
				ModelTip(scope $"Pick {name}", ModelShortcutText(action), mode == .Vertex ? "Clicks pick the model's corners." : (mode == .Edge ? "Clicks pick the lines between corners." : "Clicks pick whole faces: the usual way to shape a block."));
				ImGui.PopID();
			}
			ModelBarGap();
			void Option(ModelCommand command, StringView label)
			{
				let keys = FirstKey(ModelKeys(command));
				let width = ModelBarWidth(label, keys);
				ModelBarPlace(width);
				if (ModelCommandButton(model, mesh, command, width, label, false, mBarHeight))
					run = command;
			}
			Option(.XRay, "X-Ray");
			Option(.Proportional, "Proportional");
			Option(.SymmetryX, "Mirror X");
			Option(.SymmetryY, "Y");
			Option(.SymmetryZ, "Z");
			LoadModelShowOnly();
			if (ModelBarButton("##only", "Only This", FirstKey(ModelShortcutText(ShortcutShowOnly)), mModelShowOnly))
				SetModelShowOnly(!mModelShowOnly);
			ModelTip("Show only this model", ModelShortcutText(ShortcutShowOnly), "Hides every other object's mesh while you edit, so this one is easy to see and pick.");
			if (mModelAnyHidden)
				Option(.Reveal, "Show Hidden");
			ModelBarGap();
			if (ModelBarButton("##tools", "All Tools  \u{f0d7}", "", false, !busy))
				mModelMenuRequest = true;
			ModelTip("Every tool", "Right-click", scope $"A menu of every tool for the picked {ModeNoun()}. A right-click in the view opens it at the pointer.");
			if (ModelBarButton("##find", "\u{f002}", FirstKey(ModelShortcutText(ShortcutSearch)), false, !busy))
				mModelSearchRequest = true;
			ModelTip("Find a tool", ModelShortcutText(ShortcutSearch), "Type part of a tool's name and press Enter.");
			Option(.Help, "?");
		}
		ModelBarEndRow();

		// Down the left: the tools used most.
		let tools = ModelCommand[?](.Grab, .Rotate, .Scale, .Extrude, .Inset, .Bevel, .LoopCut, .Knife, .Delete);
		StringView[?] icons = .("\u{f047}", "\u{f01e}", "\u{f065}", "\u{f0aa}", "\u{f066}", "\u{f1b2}", "\u{f0db}", "\u{f0c4}", "\u{f1f8}");
		int count = 0;
		for (let command in tools)
		{
			if (ModelCommandApplies(sModelCommands[ModelCommandIndex(command)].modes))
				count++;
		}
		var y = mBarY + mBarHeight + 2 * BarPad + 2;
		let stripWidth = ImGui.GetFontSize() * 9.5f;
		if (!mModelPainting && size.x > 420 && origin.y + size.y - y > count * (mBarHeight + 3) + 64)
		{
			ModelBarBackground();
			let top = y;
			for (int i < tools.Count)
			{
				let command = tools[i];
				if (!ModelCommandApplies(sModelCommands[ModelCommandIndex(command)].modes))
					continue;
				ImGui.SetCursorScreenPos(.(mBarLeft, y));
				if (ModelCommandButton(model, mesh, command, stripWidth, scope $"{icons[i]}  {ModelCommandLabel(command)}", false, mBarHeight))
					run = command;
				y += mBarHeight + 3;
			}
			mModelBarRects.Add(.(mBarLeft, top, mBarLeft + stripWidth, y - 3));
		}
		ImGui.PopID();

		// The bottom line.
		let status = scope String();
		let hint = scope String();
		if (busy)
		{
			ModelToolStatus(status);
			hint.Append(mModelTool == .LoopCut || mModelTool == .Knife ? "Esc or right-click: stop" : "Click or Enter: keep  ·  Esc or right-click: cancel  ·  X Y Z: along an axis (Shift: across it)  ·  type a number for an exact amount");
		}
		else if (mModelPainting)
			hint.Append(mModelPaintTexture ? "Drag to paint  ·  Shift+click: fill a face  ·  Alt+click: pick up its colour" : "Drag to paint  ·  Shift: paint whole faces flat");
		else if (ModelSelectionCount == 0)
			hint.AppendF("Click a {} to pick it  ·  drag: box  ·  Shift: add  ·  Alt+click: loop  ·  right-click: every tool", ModeNoun(false));
		else
		{
			let picked = ModelSelectionCount;
			status.AppendF("{} {} picked", picked, ModeNoun(picked != 1));
			hint.AppendF("{} move  ·  {} rotate  ·  {} scale  ·  {} extrude  ·  {} delete  ·  right-click: every tool  ·  {}: find a tool",
				FirstKey(ModelKeys(.Grab)), FirstKey(ModelKeys(.Rotate)), FirstKey(ModelKeys(.Scale)), FirstKey(ModelKeys(.Extrude)), FirstKey(ModelKeys(.Delete)), FirstKey(ModelShortcutText(ShortcutSearch)));
		}
		DrawModelHintBar(origin, size, status, hint);

		if (run.HasValue)
			RunModelCommand(model, mesh, run.Value);
	}
}
