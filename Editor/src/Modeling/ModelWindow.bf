using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Model window (docs/modeling.md). Five tabs, in the order a model is made: Blockout (draw shapes fast, cut
/// holes), Edit (the tools of edit mode: a few essentials, or all of them), Paint, Texture and Model (the whole
/// model: mirror, origin, booleans, levels of detail, export). Every tool button shows its key, says what it does
/// when pointed at, and is greyed out with the reason when it cannot run. The same tools are on the Scene view's
/// own bar (ModelToolbar.bf), so the window is never needed for the common ones.
extension EditorApp
{
	enum ModelTab
	{
		Blockout,
		Edit,
		Paint,
		Texture,
		Model
	}

	static char8*[?] sModelTabNames = .("Blockout", "Edit", "Paint", "Texture", "Model");
	static StringView[?] sModelTabTips = .(
		"Draw boxes, ramps, stairs and other shapes straight into the scene, and cut holes in them: the quick way to block out a map.",
		"Edit mode: pick a model's faces, edges and corners and pull, cut and bevel them.",
		"Paint vertex colours or the texture, and give faces colours and materials.",
		"How the texture lies on the model: projections, unwrapping and the UV Editor.",
		"The whole model: mirror, repeat, clean up, origin, booleans, levels of detail and saving as a file.");
	/// Labels without a key sit in the middle of their button (tabs, switches) instead of on the left (tool lists).
	bool mModelCentreLabels;

	ModelTab mModelTab;
	/// The tab the program wants shown (-1: leave it to the user).
	int mModelTabRequest = -1;
	bool mModelWasEditing;
	/// The Edit tab shows every tool instead of the essentials. Remembered.
	bool mModelAllTools;
	/// Draw in Scene goes on drawing shapes until stopped. Remembered.
	bool mModelDrawKeep;
	bool mModelWindowLoaded;
	String mModelFilter = new .() ~ delete _;
	/// Cut a Hole: the model the next drawn shape is cut out of (0: shapes are new objects).
	uint32 mModelCutTarget;

	// ------------------------------------------------------------------ what is remembered

	static void ModelWindowFile(String file)
	{
		RecentProjects.GetConfigFolder(file);
		file.Append("model_window.txt");
	}

	void LoadModelWindow()
	{
		if (mModelWindowLoaded)
			return;
		mModelWindowLoaded = true;
		let saved = scope String();
		if (File.ReadAllText(ModelWindowFile(.. scope .()), saved) case .Ok)
		{
			mModelAllTools = saved.Length > 0 && saved[0] == '1';
			mModelDrawKeep = saved.Length > 1 && saved[1] == '1';
			mModelSnapObjects = saved.Length < 3 || saved[2] == '1';
		}
	}

	void SaveModelWindow()
	{
		mModelWindowLoaded = true;
		File.WriteAllText(ModelWindowFile(.. scope .()), scope $"{(mModelAllTools ? 1 : 0)}{(mModelDrawKeep ? 1 : 0)}{(mModelSnapObjects ? 1 : 0)}").IgnoreError();
	}

	// ------------------------------------------------------------------ what the buttons say

	static int ModelCommandIndex(ModelCommand command)
	{
		for (int i < sModelCommands.Count)
		{
			if (sModelCommands[i].command == command)
				return i;
		}
		return 0;
	}

	/// A command's name on a button (shorter than in the menus).
	static StringView ModelCommandLabel(ModelCommand command)
	{
		switch (command)
		{
		case .Grab: return "Move";
		case .ExtrudeEach: return "Extrude Each";
		case .LoopCut: return "Loop Cut";
		case .Slide,.VertexSlide: return "Slide";
		case .Poke: return "Poke";
		case .Solidify: return "Solidify";
		case .Duplicate: return "Duplicate";
		case .MakeFace: return "Make Face / Fill";
		case .Connect: return "Connect";
		case .Bridge: return "Bridge";
		case .Merge: return "Merge";
		case .Dissolve: return "Dissolve";
		case .SplitEdges: return "Split in Middle";
		case .SmoothVertices: return "Smooth";
		case .Weld: return "Weld";
		case .TrianglesToQuads: return "Tris to Quads";
		case .Flip: return "Flip";
		case .Separate: return "Separate Object";
		case .MarkHard: return "Hard Edge";
		case .ClearHard: return "Soft Edge";
		case .SelectAll: return "All";
		case .SelectNone: return "None";
		case .Invert: return "Invert";
		case .Grow: return "Grow";
		case .Shrink: return "Shrink";
		case .Linked: return "Linked";
		case .SelectLoop: return "Edge Loop";
		case .SelectRing: return "Edge Ring";
		case .SelectSharp: return "Sharp Edges";
		case .SelectOpen: return "Open Edges";
		case .SelectSameSlot: return "Same Material";
		case .HideOthers: return "Hide Others";
		case .Reveal: return "Show Hidden";
		case .OriginToGeometry: return "To Geometry";
		case .OriginToCentre: return "To Bounds Centre";
		case .OriginToVolumeMass: return "To Mass (Volume)";
		case .OriginToSurfaceMass: return "To Mass (Surface)";
		case .OriginToBase: return "To Base";
		case .OriginHere: return "To Selection";
		case .OriginToObject: return "To Object";
		case .Frame: return "Frame";
		case .Proportional: return "Proportional";
		case .XRay: return "X-Ray";
		case .Help: return "Shortcuts";
		default: return sModelCommands[ModelCommandIndex(command)].name;
		}
	}

	/// What a command does, for its button's tooltip.
	static StringView ModelCommandTip(ModelCommand command)
	{
		switch (command)
		{
		case .Grab: return "Moves what is picked with the pointer. Click to keep, Esc to cancel. X, Y or Z holds it to an axis; type a number for an exact distance.";
		case .Rotate: return "Turns what is picked about its middle. X, Y or Z picks the axis; type the degrees for an exact turn.";
		case .Scale: return "Makes what is picked bigger or smaller about its middle. X, Y or Z scales along one axis only.";
		case .Extrude: return "Pulls new faces out of what is picked: the way to grow walls, legs and ledges out of a block.";
		case .ExtrudeEach: return "Extrudes every picked face on its own, along its own direction.";
		case .Inset: return "Shrinks the picked faces inwards, leaving a ring of faces round them: the start of a window, a panel or a rim.";
		case .Bevel: return "Cuts the picked edges off with a slanted face. The wheel adds segments, which round the edge.";
		case .LoopCut: return "Cuts a new loop of edges all the way round the model. Point at an edge to see the cut, click, then slide it into place.";
		case .Knife: return "Draws cuts by hand: click points on edges, corners or inside faces, then Enter.";
		case .Slide: return "Slides the picked edges (or vertices) along the faces beside them, without changing the shape.";
		case .VertexSlide: return "Slides each picked vertex along one of its own edges.";
		case .Subdivide: return "Cuts each picked face into four.";
		case .SmoothSubdivide: return "Cuts each picked face into four and rounds the shape off.";
		case .Poke: return "Puts a vertex in the middle of each picked face, with a fan of triangles round it.";
		case .Solidify: return "Gives the picked faces thickness: a plane becomes a slab. Set the thickness under Exact Amounts.";
		case .Duplicate: return "Copies the picked faces and moves the copy.";
		case .MakeFace: return "Makes a face from the picked vertices, or fills the hole the picked edges go round.";
		case .Connect: return "Cuts a face between two of its corners.";
		case .Bridge: return "Joins two open chains of edges with faces.";
		case .Merge: return "Joins the picked vertices into one, at their middle.";
		case .Collapse: return "Shrinks each picked edge or face to a single point.";
		case .Dissolve: return "Removes the picked edges and joins the faces either side of them.";
		case .SplitEdges: return "Puts a new vertex in the middle of each picked edge.";
		case .SmoothVertices: return "Evens out bumps: moves vertices towards the average of their neighbours.";
		case .Weld: return "Joins picked vertices that are closer together than the weld distance (under Exact Amounts).";
		case .Triangulate: return "Cuts the picked faces into triangles.";
		case .TrianglesToQuads: return "Joins triangles that lie flat together back into four-sided faces.";
		case .Flip: return "Turns the picked faces round, so their other side shows.";
		case .Detach: return "Gives the picked faces vertices of their own, so they come away from the rest.";
		case .Separate: return "Moves the picked faces into a new object.";
		case .Delete: return "Deletes what is picked.";
		case .SmoothShading: return "Light blends across the picked faces, so they look curved.";
		case .FlatShading: return "Each picked face is lit on its own, so its edges look sharp.";
		case .MarkSeam: return "Marks the picked edges as seams: where Unwrap at Seams cuts the model open (drawn red).";
		case .ClearSeam: return "Takes the seam off the picked edges.";
		case .MarkHard: return "Light does not blend across the picked edges, even between smooth faces (drawn blue).";
		case .ClearHard: return "Lets light blend across the picked edges again.";
		case .SelectAll: return "Picks everything.";
		case .SelectNone: return "Picks nothing.";
		case .Invert: return "Picks everything that is not picked, and drops what is.";
		case .Grow: return "Adds everything next to what is picked.";
		case .Shrink: return "Drops the outer ring of what is picked.";
		case .Linked: return "Picks everything joined to what is picked: a whole separate piece of the model.";
		case .SelectLoop: return "Picks the loop of edges running on from the picked edge. Alt+click an edge does the same.";
		case .SelectRing: return "Picks the ring of edges lying across from the picked edge.";
		case .SelectSharp: return "Picks the edges where the faces turn more than the sharp angle (under Exact Amounts).";
		case .SelectOpen: return "Picks the edges with a face on one side only: the borders of holes.";
		case .SelectSameSlot: return "Picks every face in the same material slot as the picked ones.";
		case .Hide: return "Hides what is picked while you edit, to work inside a model.";
		case .HideOthers: return "Hides everything that is not picked.";
		case .Reveal: return "Shows everything hidden again.";
		case .FixNormals: return "Turns every face to point outwards. Fixes faces that look dark or see-through.";
		case .MirrorX,.MirrorY,.MirrorZ: return "Copies the model across its origin and joins the two halves: model half of something symmetrical, then mirror it.";
		case .WeldAll: return "Joins every pair of vertices that sit in the same place.";
		case .CleanUp: return "Removes leftovers: unused vertices, cracks and corners in the middle of straight edges.";
		case .OriginToGeometry: return "Puts the origin at the middle of the model's vertices.";
		case .OriginToCentre: return "Puts the origin at the middle of the box round the model.";
		case .OriginToVolumeMass: return "Puts the origin at the model's centre of mass as a solid: where it would balance.";
		case .OriginToSurfaceMass: return "Puts the origin at the model's centre of mass as a thin shell.";
		case .OriginToBase: return "Puts the origin at the middle of the model's bottom, so it stands on what it is put on.";
		case .OriginHere: return "Puts the origin at the middle of what is picked (in edit mode).";
		case .OriginToObject: return "Puts the origin where the object picked in the list is.";
		case .GeometryToOrigin: return "Moves the model so it stands round its origin; the object stays where it is.";
		case .AddShape: return "Adds a new shape into this model.";
		case .Frame: return "Points the camera at what is picked.";
		case .Proportional: return "Vertices near the ones you move follow along, less the further away they are. The wheel sets how far it reaches.";
		case .SymmetryX,.SymmetryY,.SymmetryZ: return "What you do on one side of the model's origin happens on the other side too.";
		case .XRay: return "Clicks and boxes also pick what is hidden behind the model.";
		case .Help: return "A sheet of every shortcut, in a window that can be moved aside.";
		}
	}

	/// Commands that do nothing with nothing picked.
	static bool ModelCommandNeedsSelection(ModelCommand command)
	{
		switch (command)
		{
		case .LoopCut,.Knife,.SelectAll,.SelectNone,.Invert,.SelectSharp,.SelectOpen,.Reveal,.FixNormals,.MirrorX,.MirrorY,.MirrorZ,.WeldAll,.CleanUp,
			.OriginToCentre,.OriginToBase,.OriginToGeometry,.OriginToVolumeMass,.OriginToSurfaceMass,.OriginToObject,.GeometryToOrigin,.AddShape,.Frame,
			.Proportional,.SymmetryX,.SymmetryY,.SymmetryZ,.XRay,.Help:
			return false;
		default:
			return true;
		}
	}

	/// Commands for the whole model, which work outside edit mode too.
	static bool ModelCommandWholeModel(ModelCommand command)
	{
		switch (command)
		{
		case .FixNormals,.MirrorX,.MirrorY,.MirrorZ,.WeldAll,.CleanUp,.OriginToCentre,.OriginToBase,.OriginToGeometry,.OriginToVolumeMass,.OriginToSurfaceMass,
			.OriginToObject,.GeometryToOrigin:
			return true;
		default:
			return false;
		}
	}

	/// Whether a command's tool is the one following the pointer now.
	bool ModelCommandRunning(ModelCommand command)
	{
		switch (mModelTool)
		{
		case .Grab: return command == .Grab;
		case .Rotate: return command == .Rotate;
		case .Scale: return command == .Scale;
		case .Extrude: return command == .Extrude;
		case .Inset: return command == .Inset;
		case .Bevel: return command == .Bevel;
		case .LoopCut: return command == .LoopCut;
		case .Knife: return command == .Knife;
		case .Slide: return command == .Slide;
		case .VertexSlide: return command == .VertexSlide || command == .Slide;
		default: return false;
		}
	}

	/// The first of an action's keys ("X" of "X, Delete").
	static StringView FirstKey(StringView keys)
	{
		let comma = keys.IndexOf(", ");
		return comma > 0 ? keys.Substring(0, comma) : keys;
	}

	StringView ModeNoun(bool plural = true)
	{
		switch (mModelMode)
		{
		case .Vertex: return plural ? "vertices" : "vertex";
		case .Edge: return plural ? "edges" : "edge";
		case .Face: return plural ? "faces" : "face";
		}
	}

	// ------------------------------------------------------------------ widgets

	/// A button drawn by hand: its label on the left and its key, dim, on the right when there is room. Lit ones are
	/// drawn in the accent colour (the mode or option that is on, the tool running). Width 0 or less fills the line.
	bool ModelButton(char8* id, StringView label, StringView keys, float width, bool lit = false, bool enabled = true, float height = 0)
	{
		let h = height > 0 ? height : ImGui.GetFrameHeight() + 2;
		let w = width > 0 ? width : ImGui.GetContentRegionAvail().x;
		ImGui.BeginDisabled(!enabled);
		let clicked = ImGui.InvisibleButton(id, .(Math.Max(w, 4), h));
		ImGui.EndDisabled();
		let min = ImGui.GetItemRectMin();
		let max = ImGui.GetItemRectMax();
		let hovered = enabled && ImGui.IsItemHovered();
		let held = enabled && ImGui.IsItemActive();
		var back = lit ? EditorTheme.Accent : ImGui.GetStyleColor(held ? ImGui.Col.ButtonActive : (hovered ? ImGui.Col.ButtonHovered : ImGui.Col.Button));
		if (lit && hovered)
			back = Color.Lerp(back, .(1, 1, 1, back.a), held ? 0.25f : 0.14f);
		var text = ImGui.GetStyleColor(ImGui.Col.Text);
		var dim = ImGui.GetStyleColor(ImGui.Col.TextDisabled);
		if (lit)
			dim = .(text.r, text.g, text.b, 0.72f);
		if (!enabled)
		{
			back.a *= 0.45f;
			text = dim;
			dim.a *= 0.6f;
		}
		ImGui.DrawRectFilled(min, max, back, 3);
		let labelSize = ImGui.CalcStringSize(label);
		let keySize = keys.IsEmpty ? ImGui.Vec2(0, 0) : ImGui.CalcStringSize(keys);
		let textY = min.y + (h - labelSize.y) * 0.5f;
		ImGui.PushClipRect(.(min.x + 2, min.y), .(max.x - 2, max.y));
		let showKeys = !keys.IsEmpty && labelSize.x + keySize.x + 22 <= w;
		let labelX = (!mModelCentreLabels || showKeys || labelSize.x + 16 > w || !keys.IsEmpty) ? min.x + 8 : min.x + (w - labelSize.x) * 0.5f;
		ImGui.DrawString(.(labelX, textY), text, label);
		if (showKeys)
			ImGui.DrawString(.(max.x - 8 - keySize.x, textY), dim, keys);
		ImGui.PopClipRect();
		return clicked;
	}

	/// A tooltip for the last item: its name and key, what it does, and (in the warning colour) why it is off.
	void ModelTip(StringView title, StringView keys, StringView text, StringView warning = default)
	{
		if (!ImGui.IsItemHovered(ImGui.HoveredFlags.ForTooltip | ImGui.HoveredFlags.AllowWhenDisabled))
			return;
		if (!ImGui.BeginTooltip())
			return;
		ImGui.Text(title);
		if (!keys.IsEmpty)
		{
			ImGui.SameLine();
			ImGui.TextColored(ModelSelectColor, scope String(keys).CStr());
		}
		ImGui.PushTextWrapPos(ImGui.GetFontSize() * 22);
		if (!text.IsEmpty)
			ImGui.TextDisabled(scope String(text).CStr());
		if (!warning.IsEmpty)
			ImGui.TextColored(EditorTheme.Warning, scope String(warning).CStr());
		ImGui.PopTextWrapPos();
		ImGui.EndTooltip();
	}

	/// A plain tooltip for the last item, after the pointer has rested on it.
	static void ModelHint(char8* text)
	{
		if (!ImGui.IsItemHovered(ImGui.HoveredFlags.ForTooltip | ImGui.HoveredFlags.AllowWhenDisabled))
			return;
		if (!ImGui.BeginTooltip())
			return;
		ImGui.PushTextWrapPos(ImGui.GetFontSize() * 22);
		ImGui.Text(StringView(text));
		ImGui.PopTextWrapPos();
		ImGui.EndTooltip();
	}

	/// A wide button for the main thing to do next.
	static bool ModelBigButton(char8* label, bool accent = true)
	{
		if (accent)
			ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
		let clicked = ImGui.Button(label, .(-1, ImGui.GetFrameHeight() * 1.45f));
		if (accent)
			ImGui.PopStyleColor();
		return clicked;
	}

	static void ModelNote(StringView text)
	{
		ImGui.PushStyleColor(ImGui.Col.Text, ImGui.GetStyleColor(ImGui.Col.TextDisabled));
		ImGui.TextWrapped(scope String(text).CStr());
		ImGui.PopStyleColor();
	}

	static bool ModelSection(char8* label, bool open = true) => ImGui.CollapsingHeader(label, open ? ImGui.TreeFlags.DefaultOpen : 0);

	// Buttons laid out in as many equal columns as fit.
	int mModelGridColumns = 1;
	int mModelGridAt;
	float mModelGridWidth;

	void ModelGridBegin(float minWidth = 138, int maxColumns = 4)
	{
		let avail = ImGui.GetContentRegionAvail().x;
		mModelGridColumns = Math.Clamp((int)(avail / minWidth), 1, maxColumns);
		mModelGridWidth = Math.Floor((avail - (mModelGridColumns - 1) * 4) / mModelGridColumns);
		mModelGridAt = 0;
	}

	/// Moves to the next cell; its width.
	float ModelGridNext()
	{
		if (mModelGridAt % mModelGridColumns != 0)
			ImGui.SameLine(0, 4);
		mModelGridAt++;
		return mModelGridWidth;
	}

	/// A command as a button: its short name and first key, its tooltip, lit while it runs or is on, and off (with
	/// the reason in the tooltip) when it has nothing to work on. True when clicked; runs it unless told not to.
	bool ModelCommandButton(ModelMesh model, EditMesh mesh, ModelCommand command, float width, StringView label = default, bool run = true, float height = 0)
	{
		let entry = sModelCommands[ModelCommandIndex(command)];
		let whole = ModelCommandWholeModel(command);
		StringView why = default;
		if (!whole && !mModelEditing)
			why = "Edit the model first (Edit tab, or Tab over the Scene view).";
		else if (ModelToolActive && !ModelCommandRunning(command))
			why = "Finish the tool that is running first (click, or Esc).";
		else if (!whole && !ModelCommandApplies(entry.modes))
			why = "Not for what is being picked now: switch between vertices, edges and faces.";
		else if (ModelCommandNeedsSelection(command) && !ModelHasSelection)
			why = scope:: $"Pick some {ModeNoun()} in the Scene view first.";
		let keys = FirstKey(ModelKeys(command));
		ImGui.PushID((int32)command.Underlying);
		let clicked = ModelButton("##command", label.IsEmpty ? ModelCommandLabel(command) : label, keys, width, ModelCommandChecked(command) || ModelCommandRunning(command), why.IsEmpty, height);
		ModelTip(entry.name, ModelKeys(command), ModelCommandTip(command), why);
		ImGui.PopID();
		if (clicked && run)
			RunModelCommand(model, mesh, command);
		return clicked;
	}

	/// A number with its name before it; buttons that use it go on the same line after (ModelNumberButton).
	static bool ModelNumber(char8* label, ref float value, float speed, float min, float max, char8* format = "%.2f")
	{
		ImGui.AlignTextToFramePadding();
		ImGui.Text(StringView(label));
		ImGui.SameLine(ImGui.GetFontSize() * 6.2f);
		ImGui.SetNextItemWidth(ImGui.GetFontSize() * 5);
		ImGui.PushID(label);
		let changed = ImGui.DragFloat("##value", ref value, speed, min, max, format);
		ImGui.PopID();
		return changed;
	}

	static bool ModelCount(char8* label, ref int32 value, int32 min, int32 max)
	{
		ImGui.AlignTextToFramePadding();
		ImGui.Text(StringView(label));
		ImGui.SameLine(ImGui.GetFontSize() * 6.2f);
		ImGui.SetNextItemWidth(ImGui.GetFontSize() * 5);
		ImGui.PushID(label);
		let changed = ImGui.DragInt("##value", ref value, 0.1f, min, max);
		ImGui.PopID();
		return changed;
	}

	/// One of `count` buttons sharing the rest of a number's line.
	static bool ModelNumberButton(char8* label, int index, int count, bool enabled, char8* tip)
	{
		ImGui.SameLine(0, index == 0 ? 6 : 4);
		let width = (ImGui.GetContentRegionAvail().x - 4 * (count - 1 - index)) / (count - index);
		ImGui.BeginDisabled(!enabled);
		let clicked = ImGui.Button(label, .(Math.Max(width, 20), 0));
		ImGui.EndDisabled();
		ModelHint(tip);
		return clicked;
	}

	// ------------------------------------------------------------------ the window

	void DrawModelWindow()
	{
		TickModelTest();
		TickModelSelectBench();
		TickGraphNodeTest();
		TickGraphMenuTest();
		TickFirstPersonTemplate();
		DrawModelHelp();
		if (!mShowModel)
		{
			// The Scene view's own bar can still start a shape; only the window's drawing stops with it.
			mModelWasEditing = mModelEditing;
			return;
		}
		LoadModelWindow();
		let viewport = ImGui.GetMainViewport();
		ImGui.SetNextWindowPos(.(viewport.workPos.x + viewport.workSize.x - 700, viewport.workPos.y + 80), 4);
		ImGui.SetNextWindowSize(.(340, 720), 4);
		// A tab beside the Inspector the first time; it can be moved from there.
		if (mDockModel && mInspectorDock != 0)
		{
			ImGui.SetNextWindowDockID(mInspectorDock);
			mDockModel = false;
			mModelFocus = true;
		}
		else if (mModelFocus)
		{
			ImGui.SetNextWindowFocus();
			mModelFocus = false;
		}
		// Going into edit mode from the Blockout tab (Tab over the Scene view) brings its tools up.
		if (mModelEditing && !mModelWasEditing && mModelTab == .Blockout)
			mModelTabRequest = (int)ModelTab.Edit;
		mModelWasEditing = mModelEditing;
		if (ImGui.Begin("Model", &mShowModel))
		{
			// The tabs: a row of buttons, the one shown lit.
			var shown = mModelTabRequest >= 0 ? (ModelTab)mModelTabRequest : mModelTab;
			mModelTabRequest = -1;
			let tabWidth = Math.Floor((ImGui.GetContentRegionAvail().x - 2 * (sModelTabNames.Count - 1)) / sModelTabNames.Count);
			mModelCentreLabels = true;
			for (int tab < sModelTabNames.Count)
			{
				if (tab > 0)
					ImGui.SameLine(0, 2);
				ImGui.PushID((int32)tab);
				if (ModelButton("##tab", StringView(sModelTabNames[tab]), "", tabWidth, (int)shown == tab, true, ImGui.GetFrameHeight() + 6))
					shown = (ModelTab)tab;
				ModelTip(StringView(sModelTabNames[tab]), "", sModelTabTips[tab]);
				ImGui.PopID();
			}
			mModelCentreLabels = false;
			ImGui.Spacing();
			if (shown != mModelTab)
			{
				// The brush belongs to the Paint tab: leaving it goes back to picking.
				if (mModelTab == .Paint)
					mModelPainting = false;
				mModelTab = shown;
			}
			ImGui.BeginChild("##modelbody");
			let selected = Selected;
			let model = GameObject.ComponentOn<ModelMesh>(selected);
			if (mPlay != .Edit)
				ModelNote("Stop the game to model.");
			else
			{
				switch (mModelTab)
				{
				case .Blockout: DrawModelBlockoutTab(selected, model);
				case .Edit: DrawModelEditTab(selected, model);
				case .Paint: DrawModelPaintTab(selected, model);
				case .Texture: DrawModelTextureTab(selected, model);
				case .Model: DrawModelWholeTab(selected, model);
				}
			}
			ImGui.EndChild();
		}
		ImGui.End();
		DrawUVEditor();
	}

	/// What a tab shows when the selected object is not a model.
	void DrawModelNeedsModel(GameObject selected)
	{
		ImGui.Spacing();
		if (selected != null && selected.HasComponent<MeshRenderer>())
		{
			ModelNote(scope $"{selected.Name} has an ordinary mesh. Turn it into a model to change it here.");
			if (ModelBigButton("Make Editable Model"))
				ConvertToModel(selected);
			ModelHint("Turns its mesh into faces the model tools can change. The object keeps its place, material and collider.");
			return;
		}
		ModelNote("Select a model in the Scene view, or draw a new shape.");
		if (ModelBigButton("Draw a Shape", false))
			mModelTabRequest = (int)ModelTab.Blockout;
	}

	// ------------------------------------------------------------------ Blockout

	void StartShapeDrawing(uint32 cutTarget = 0)
	{
		mModelDraw = .Waiting;
		mModelEditing = false;
		mModelCutTarget = cutTarget;
	}

	void StopShapeDrawing()
	{
		mModelDraw = .Off;
		mModelCutTarget = 0;
	}

	void DrawModelBlockoutTab(GameObject selected, ModelMesh model)
	{
		let drawing = mModelDraw != .Off;
		ImGui.SeparatorText("Shape");
		ModelGridBegin(96, 4);
		for (int32 k < (int32)MeshShapes.Names.Count)
		{
			let width = ModelGridNext();
			ImGui.PushID(k);
			if (ModelButton("##shape", MeshShapes.Names[k], "", width, k == mModelDrawKind))
				mModelDrawKind = k;
			ImGui.PopID();
		}
		let kind = (MeshShapes.Kind)mModelDrawKind;
		if (kind == .Cylinder || kind == .Cone || kind == .Sphere || kind == .Torus || kind == .Arch || kind == .Pipe)
			ModelCount("Sides", ref mModelShape.sides, 3, 64);
		if (kind == .Stairs || kind == .Sphere || kind == .Torus)
			ModelCount(kind == .Stairs ? "Steps" : "Rings", ref mModelShape.steps, 1, 64);
		if (kind == .Torus || kind == .Arch || kind == .Pipe || kind == .Corner)
			ModelNumber("Wall", ref mModelShape.thickness, 0.01f, 0.01f, 100, "%.2f m");
		if (kind == .Cylinder || kind == .Cone || kind == .Sphere || kind == .Torus || kind == .Pipe)
			ImGui.Checkbox("Smooth sides", ref mModelShape.smooth);

		ImGui.Spacing();
		if (ModelBigButton(drawing ? "Stop Drawing (Esc)" : scope $"Draw {MeshShapes.Names[mModelDrawKind]} in Scene" .CStr(), !drawing))
		{
			if (drawing)
				StopShapeDrawing();
			else
				StartShapeDrawing();
		}
		if (drawing)
		{
			if (mModelCutTarget != 0)
				ImGui.TextColored(EditorTheme.Warning, "Cutting: draw the shape through the model.");
			ModelNote("Drag out the base on the ground or a surface, let go, move the pointer up for the height, click. A click without a drag places one of the size below.");
		}
		if (ImGui.Checkbox("Keep drawing", ref mModelDrawKeep))
			SaveModelWindow();
		ModelHint("Go on drawing shapes one after another until Esc. Off, holding Shift on the last click does the same for one more.");
		ImGui.SameLine();
		ImGui.Checkbox("Snap", ref mSnap);
		ModelHint("Snap the base and the height to the grid step (the toolbar's Snap; Ctrl held flips it).");
		ImGui.SameLine();
		ImGui.SetNextItemWidth(-1);
		ImGui.DragFloat("##snapstep", ref mSnapMove, 0.01f, 0.01f, 100, "step %.2f m");
		if (ImGui.Checkbox("Snap to other objects", ref mModelSnapObjects))
			SaveModelWindow();
		ModelHint("While drawing, the pointer near a corner, an edge or the middle of an edge of another object takes that point: the base's corners and the height. Put a ramp's top on the edge of the platform it leads to. Hold Alt to draw freely for a moment.");

		ImGui.SeparatorText("Fixed size");
		ModelVector3("Size", ref mModelShape.size);
		if (ImGui.Button("Add One in View", .(-1, 0)))
			AddShapeInView(kind);
		ModelHint("Puts one shape of this size where the Scene view is looking.");

		ImGui.SeparatorText(model.IsValid ? scope $"Selected: {selected.Name}" .CStr() : "Selected");
		if (model.IsValid)
		{
			ModelGridBegin(138, 2);
			var width = ModelGridNext();
			if (ModelButton("##editmodel", mModelEditing ? "Done Editing" : "Edit Shape", FirstKey(ModelShortcutText(ShortcutEditMode)), width, mModelEditing))
			{
				if (mModelEditing)
					mModelEditing = false;
				else
				{
					StartModelEditing(selected);
					mModelTabRequest = (int)ModelTab.Edit;
				}
			}
			ModelTip("Edit mode", ModelShortcutText(ShortcutEditMode), "Pick the shape's faces, edges and corners and pull, cut and bevel them.");
			width = ModelGridNext();
			let cutting = drawing && mModelCutTarget == selected.Id;
			if (ModelButton("##cuthole", cutting ? "Stop Cutting" : "Cut a Hole", "", width, cutting))
			{
				if (cutting)
					StopShapeDrawing();
				else
					StartShapeDrawing(selected.Id);
			}
			ModelTip("Cut a Hole", "", "Draw the shape above through this model and it is cut out of it: doors, windows, pits and trenches. With Keep drawing on, cut one after another.");
			ModelNote("Mirror, booleans and the origin are on the Model tab.");
		}
		else if (selected != null && selected.HasComponent<MeshRenderer>())
		{
			if (ImGui.Button("Make Editable Model", .(-1, 0)))
				ConvertToModel(selected);
			ModelHint("Turns this object's mesh into faces the model tools can change.");
		}
		else
			ModelNote("Nothing to edit: draw a shape, or select one.");

		ImGui.Spacing();
		DrawModelReferences();
		if (ImGui.Button(mShowModelViews ? "Close Model Views" : "Open Model Views (four views)", .(-1, 0)))
			mShowModelViews = mFocusModelViews = !mShowModelViews;
		ModelHint("Top, Front, Left and Perspective side by side, for lining things up.");
	}

	// ------------------------------------------------------------------ Edit

	/// Vertices, Edges, Faces: three buttons, the one being picked lit.
	void DrawModelModes(EditMesh mesh)
	{
		ModelGridBegin(60, 3);
		for (let mode in ModelSelectMode[3](.Vertex, .Edge, .Face))
		{
			let width = ModelGridNext();
			let action = mode == .Vertex ? ShortcutVertexMode : (mode == .Edge ? ShortcutEdgeMode : ShortcutFaceMode);
			let name = mode == .Vertex ? "Vertices" : (mode == .Edge ? "Edges" : "Faces");
			ImGui.PushID((int32)action);
			if (ModelButton("##mode", name, FirstKey(ModelShortcutText(action)), width, mModelMode == mode))
				SetModelMode(mode, mesh);
			ModelTip(scope $"Pick {name}", ModelShortcutText(action), mode == .Vertex ? "Clicks pick the model's corners." : (mode == .Edge ? "Clicks pick the lines between corners." : "Clicks pick whole faces: the usual way to shape a block."));
			ImGui.PopID();
		}
	}

	void DrawModelEditTab(GameObject selected, ModelMesh model)
	{
		if (!model.IsValid)
		{
			DrawModelNeedsModel(selected);
			return;
		}
		let mesh = model.Edit;
		if (!mModelEditing)
		{
			ImGui.Spacing();
			ImGui.Text(selected.Name);
			ImGui.SameLine();
			ImGui.TextDisabled(scope $"{mesh.faces.Count} faces, {mesh.positions.Count} vertices" .CStr());
			if (ModelBigButton(scope $"Edit This Model ({FirstKey(ModelShortcutText(ShortcutEditMode))})###startedit" .CStr()))
				StartModelEditing(selected);
			ModelNote("In edit mode, clicks in the Scene view pick the model's faces, edges and corners, and the tools here pull, cut and bevel them. The same key (or Done) leaves it.");
			return;
		}
		if (mModelPainting)
		{
			ModelNote("The paint brush is on, so clicks paint instead of picking.");
			if (ImGui.Button("Stop Painting", .(-1, 0)))
				mModelPainting = false;
			return;
		}
		DrawModelModes(mesh);
		let count = ModelSelectionCount;
		ImGui.AlignTextToFramePadding();
		if (count == 0)
			ImGui.TextDisabled(scope $"Nothing picked: click a {ModeNoun(false)} in the Scene view." .CStr());
		else
			ImGui.Text(scope $"{count} {ModeNoun(count != 1)} picked");

		// Essentials or everything, and leaving.
		let third = (ImGui.GetContentRegionAvail().x - 8) / 3;
		if (ModelButton("##essentials", "Essentials", "", third, !mModelAllTools))
		{
			mModelAllTools = false;
			SaveModelWindow();
		}
		ModelTip("Essentials", "", "The few tools most models need: quick for blocking out.");
		ImGui.SameLine(0, 4);
		if (ModelButton("##alltools", "All Tools", "", third, mModelAllTools))
		{
			mModelAllTools = true;
			SaveModelWindow();
		}
		ModelTip("All Tools", "", "Every tool, in groups, with a box to find one by name.");
		ImGui.SameLine(0, 4);
		if (ModelButton("##done", "Done", FirstKey(ModelShortcutText(ShortcutEditMode)), third))
		{
			mModelEditing = false;
			return;
		}
		ModelTip("Leave edit mode", ModelShortcutText(ShortcutEditMode), "Back to moving whole objects.");
		ImGui.Spacing();

		if (!mModelAllTools)
		{
			DrawModelEssentials(model, mesh);
			return;
		}
		ImGui.SetNextItemWidth(-1);
		ImGui.InputText("##modelfilter", mModelFilter, 0, "Find a tool...");
		if (!mModelFilter.IsEmpty)
		{
			// Whatever matches, from every group.
			ModelGridBegin();
			bool any = false;
			for (let entry in sModelCommands)
			{
				if (entry.command == .AddShape || (!ModelCommandApplies(entry.modes) && !ModelCommandWholeModel(entry.command)))
					continue;
				if (!entry.name.Contains(mModelFilter, true) && !ModelCommandLabel(entry.command).Contains(mModelFilter, true))
					continue;
				any = true;
				ModelCommandButton(model, mesh, entry.command, ModelGridNext());
			}
			if (!any)
				ModelNote(scope $"No tool for {ModeNoun()} is called that. Other tools appear when picking vertices, edges or faces.");
			return;
		}
		void Group(char8* title, StringView group, bool open = true)
		{
			bool any = false;
			for (let entry in sModelCommands)
				any |= entry.group == group && ModelCommandApplies(entry.modes);
			if (!any || !ModelSection(title, open))
				return;
			ModelGridBegin();
			for (let entry in sModelCommands)
			{
				if (entry.group == group && ModelCommandApplies(entry.modes) && entry.command != .AddShape)
					ModelCommandButton(model, mesh, entry.command, ModelGridNext());
			}
			ImGui.Spacing();
		}
		Group("Move###grouptransform", "Transform");
		Group("Build###groupbuild", "Build");
		Group("Change and remove###groupchange", "Change");
		if (ModelSection("Exact amounts###groupexact", false))
		{
			DrawModelExact(model, mesh);
			ImGui.Spacing();
		}
		Group("Select###groupselect", "Select");
		Group("Shading and marks###groupmarks", "Shading and marks", false);
		Group("Hide and show###groupshow", "Show", false);
		if (ModelSection("Options###groupoptions"))
			DrawModelOptions();
		if (mModelMode == .Vertex && mModelVerts.Count == 1)
		{
			var only = 0;
			for (let v in mModelVerts)
				only = v;
			if (ImGui.Button("Put Object Origin Here", .(-1, 0)))
				SetModelOrigin(model, mesh.positions[only]);
		}
	}

	/// The Edit tab's short list: the tools a blockout needs, picking helpers and the options.
	void DrawModelEssentials(ModelMesh model, EditMesh mesh)
	{
		ModelGridBegin();
		for (let command in ModelCommand[?](.Grab, .Rotate, .Scale, .Extrude, .Inset, .Bevel, .LoopCut, .Knife, .Slide, .VertexSlide, .MakeFace, .Merge, .Connect, .Duplicate, .Delete))
		{
			if (ModelCommandApplies(sModelCommands[ModelCommandIndex(command)].modes))
				ModelCommandButton(model, mesh, command, ModelGridNext());
		}
		ImGui.SeparatorText("Pick");
		ModelGridBegin(66, 4);
		for (let command in ModelCommand[?](.SelectAll, .SelectNone, .Linked, .Invert))
			ModelCommandButton(model, mesh, command, ModelGridNext());
		ModelNote("Click picks, Shift+click adds, drag boxes. Alt+click picks a loop.");
		ImGui.SeparatorText("Options");
		DrawModelOptions();
		ImGui.Spacing();
		ModelNote(scope $"Right-click in the Scene view for every tool at the pointer, or press {FirstKey(ModelShortcutText(ShortcutSearch))} to find one by name.");
	}

	/// Proportional editing, mirrored edits, x-ray, showing only the model, and the shortcut sheet.
	void DrawModelOptions()
	{
		ImGui.Checkbox(ModelLabel("Proportional", ModelCommandShortcut(.Proportional)), ref mModelProportional);
		ModelHint("Vertices near the ones you move follow along, less the further away they are: for soft bumps and bends.");
		if (mModelProportional)
		{
			ImGui.SameLine();
			ImGui.SetNextItemWidth(-1);
			ImGui.DragFloat("##propradius", ref mModelPropRadius, 0.01f, 0.01f, 1000, "reach %.2f m");
		}
		ImGui.AlignTextToFramePadding();
		ImGui.Text("Mirror edits");
		ModelHint("What you do on one side of the model's origin happens on the other side too: model half of something symmetrical.");
		for (int axis < 3)
		{
			ImGui.SameLine();
			ImGui.Checkbox(axis == 0 ? "X##sym" : (axis == 1 ? "Y##sym" : "Z##sym"), ref mModelSymmetry[axis]);
		}
		ImGui.Checkbox("X-ray: pick what is behind too", ref mModelXRay);
		ModelHint("Clicks and boxes also pick what is hidden behind the model.");
		LoadModelShowOnly();
		var showOnly = mModelShowOnly;
		if (ImGui.Checkbox(ModelLabel("Show only this model", ShortcutShowOnly), ref showOnly))
			SetModelShowOnly(showOnly);
		ModelHint("In edit mode, hide every other object's mesh so this one is easy to see and pick. Remembered.");
		if (ImGui.Button(mModelShowHelp ? "Hide Shortcut Sheet (F1)" : "Shortcut Sheet (F1)", .(-1, 0)))
			mModelShowHelp = !mModelShowHelp;
	}

	/// Tools run by a typed amount instead of the pointer.
	void DrawModelExact(ModelMesh model, EditMesh mesh)
	{
		let any = ModelHasSelection;
		switch (mModelMode)
		{
		case .Face:
			ModelNumber("Extrude", ref mModelExtrude, 0.01f, -100, 100, "%.2f m");
			if (ModelNumberButton("Together", 0, 2, any, "Pushes the picked faces out by this much as one block (negative pushes in)."))
				ModelFaceAction(model, mesh, .Extrude);
			if (ModelNumberButton("Each", 1, 2, any, "Pushes each picked face out on its own."))
				ModelFaceAction(model, mesh, .ExtrudeEach);
			ModelNumber("Inset", ref mModelInset, 0.005f, 0.001f, 100, "%.3f m");
			if (ModelNumberButton("Together##inset", 0, 2, any, "Shrinks the picked faces inwards as one region."))
				ModelFaceAction(model, mesh, .InsetRegion);
			if (ModelNumberButton("Each##inset", 1, 2, any, "Shrinks each picked face inwards on its own."))
				ModelFaceAction(model, mesh, .Inset);
			ModelNumber("Thickness", ref mModelSolidify, 0.005f, -100, 100, "%.3f m");
			if (ModelNumberButton("Solidify", 0, 1, any, "Gives the picked faces this thickness."))
				ModelFaceAction(model, mesh, .Solidify);
		case .Edge:
			ModelNumber("Bevel", ref mModelBevel, 0.005f, 0.001f, 100, "%.3f m");
			if (ModelNumberButton("Bevel", 0, 1, any, "Bevels the picked edges this wide, with the segments below."))
				ModelEdgeAction(model, mesh, .Bevel);
			ModelCount("Segments", ref mModelBevelSegments, 1, 32);
			ModelCount("Cuts", ref mModelCuts, 1, 32);
			if (ModelNumberButton("Loop Cut", 0, 1, any, "Cuts this many evenly spaced loops through the picked edge's ring."))
				ModelEdgeAction(model, mesh, .LoopCut);
			ModelNumber("Sharp over", ref mModelSharpAngle, 0.5f, 1, 179, "%.0f°");
			if (ModelNumberButton("Select Sharp", 0, 1, true, "Picks the edges where the faces turn more than this."))
				SelectModelSharp(mesh);
		case .Vertex:
			ModelNumber("Weld within", ref mModelWeld, 0.001f, 0.0001f, 10, "%.3f m");
			if (ModelNumberButton("Weld", 0, 1, any, "Joins picked vertices closer together than this."))
				ModelVertexAction(model, mesh, .Weld);
		}
		ModelNote("Tools that follow the pointer take typed amounts too: press the key, type the number, Enter.");
	}

	// ------------------------------------------------------------------ Paint

	void DrawModelPaintTab(GameObject selected, ModelMesh model)
	{
		if (!model.IsValid)
		{
			DrawModelNeedsModel(selected);
			return;
		}
		let mesh = model.Edit;
		ImGui.SeparatorText("Brush");
		let third = (ImGui.GetContentRegionAvail().x - 8) / 3;
		let brush = !mModelEditing || !mModelPainting ? 0 : (mModelPaintTexture ? 2 : 1);
		if (ModelButton("##brushoff", "Off", "", third, brush == 0))
			mModelPainting = false;
		ModelTip("Brush off", "", "Clicks pick faces again.");
		ImGui.SameLine(0, 4);
		if (ModelButton("##brushvertex", "Vertex Colours", "", third, brush == 1))
		{
			if (!mModelEditing)
				StartModelEditing(selected);
			mModelPainting = true;
			mModelPaintTexture = false;
		}
		ModelTip("Paint vertex colours", "", "Colours kept in the model's corners, which tint its material. Needs no texture; as fine as the model's faces are.");
		ImGui.SameLine(0, 4);
		if (ModelButton("##brushtexture", "Texture", "", third, brush == 2))
		{
			if (!mModelEditing)
				StartModelEditing(selected);
			mModelPainting = true;
			mModelPaintTexture = true;
		}
		ModelTip("Paint the texture", "", "Paints the model's picture straight onto it in the Scene view.");
		if (brush != 0)
		{
			ImGui.ColorEdit4("Colour", ref mModelColor);
			ImGui.SetNextItemWidth(-90);
			ImGui.DragFloat("Radius", ref mModelPaintRadius, 0.01f, 0.01f, 50, "%.2f m");
			ImGui.SetNextItemWidth(-90);
			ImGui.SliderFloat("Strength", ref mModelPaintStrength, 0.05f, 1);
			if (mModelPaintTexture)
				DrawTexturePaintSettings(model, mesh);
			else
				ModelNote("Drag over the model to paint. Shift paints whole faces flat.");
			return;
		}
		ModelNote("Pick a brush to paint in the Scene view, or colour whole faces below.");

		ImGui.SeparatorText("Picked faces");
		if (!mModelEditing || mModelMode != .Face)
		{
			ModelNote("To colour faces or give them a material, pick them first.");
			if (ImGui.Button("Pick Faces", .(-1, 0)))
			{
				if (!mModelEditing)
					StartModelEditing(selected);
				SetModelMode(.Face, mesh);
			}
			return;
		}
		let any = !mModelFaces.IsEmpty;
		ImGui.TextDisabled(any ? scope $"{mModelFaces.Count} picked" .CStr() : "Click faces in the Scene view.");
		ImGui.BeginDisabled(!any);
		ImGui.ColorEdit4("##facecolour", ref mModelColor, ImGui.ColorFlags.NoInputs);
		ImGui.SameLine();
		if (ImGui.Button("Colour Faces", .(-1, 0)))
			ModelFaceAction(model, mesh, .Color);
		ModelHint("Gives the picked faces this colour (vertex colours, which tint the material).");
		ModelCount("Material slot", ref mModelSlot, 0, 15);
		if (ModelNumberButton("Set", 0, 2, any, "Puts the picked faces in this slot. Slot 0 uses the Mesh Renderer's material; 1 and up use Model Mesh > Materials."))
			ModelFaceAction(model, mesh, .Slot);
		ImGui.EndDisabled();
		if (ModelNumberButton("Pick Same", 1, 2, any, "Picks every face in the same slot as the picked ones."))
			SelectModelSameSlot(mesh);
		DrawPaletteFaces(model, mesh);
	}

	// ------------------------------------------------------------------ Texture

	void DrawModelTextureTab(GameObject selected, ModelMesh model)
	{
		if (!model.IsValid)
		{
			DrawModelNeedsModel(selected);
			return;
		}
		let mesh = model.Edit;
		let faces = scope List<int32>();
		ModelUVFaces(mesh, faces);
		let some = mModelEditing && mModelMode == .Face && !mModelFaces.IsEmpty;
		ImGui.Spacing();
		ModelNote(some ? scope $"These work on the {mModelFaces.Count} picked faces." : "These work on every face. Pick faces in edit mode to do only some.");

		void Apply(char8* label, char8* tip, delegate void() action)
		{
			if (ImGui.Button(label, .(ModelGridNext(), 0)))
			{
				action();
				CommitModel(model);
			}
			ModelHint(tip);
		}
		ImGui.SeparatorText("Lay the texture on");
		ModelGridBegin(100, 3);
		Apply("Auto (world)", "The texture is laid on from the side each face looks at most, once a metre, and stays that size however the shape is stretched. What new faces use: best for blockouts.", scope () =>
			{
				for (let f in faces)
					mesh.faces[f].uvMode = .Auto;
			});
		Apply("Box", "Projected from six sides, as onto a box.", scope () => MeshUV.Box(mesh, faces));
		Apply("Planar", "Projected flat from one side.", scope () => MeshUV.Planar(mesh, faces));
		Apply("Cylinder", "Wrapped round, as a label round a tin.", scope () => MeshUV.Cylinder(mesh, faces));
		Apply("Sphere", "Wrapped round, as a map round a globe.", scope () => MeshUV.Sphere(mesh, faces));

		ImGui.SeparatorText("Unwrap");
		ModelGridBegin(138, 2);
		Apply("Smart Unwrap", "Finds its own flat pieces (faces turned less than the angle below from each other) and packs them into the picture. Good for hard-edged models.", scope () => MeshUV.SmartUnwrap(mesh, faces, mModelSmartAngle));
		Apply("Unwrap at Seams", "Cuts the model open along the edges marked as seams and lays each piece flat.", scope () => MeshUV.Unwrap(mesh, faces));
		Apply("Pack", "Packs the pieces as they are into the picture, without overlap.", scope () => MeshUV.Pack(mesh, faces));
		if (ImGui.Button("UV Editor...", .(ModelGridNext(), 0)))
			mShowUVEditor = true;
		ModelHint("Shows the pieces over the texture, to move, turn, pin and stitch them.");
		ModelNumber("Smart angle", ref mModelSmartAngle, 0.5f, 1, 89, "%.0f°");
		if (mModelEditing && mModelMode == .Edge)
		{
			ModelGridBegin(138, 2);
			ModelCommandButton(model, mesh, .MarkSeam, ModelGridNext());
			ModelCommandButton(model, mesh, .ClearSeam, ModelGridNext());
		}
		else
			ModelNote("Seams are marked on edges: in edit mode pick edges, then Mark Seam appears here.");
		if (some)
			DrawFaceUVSettings(model, mesh);
	}

	// ------------------------------------------------------------------ Model (the whole of it)

	void DrawModelWholeTab(GameObject selected, ModelMesh model)
	{
		if (!model.IsValid)
		{
			DrawModelNeedsModel(selected);
			return;
		}
		let mesh = model.Edit;
		ImGui.Spacing();
		ImGui.Text(selected.Name);
		ImGui.SameLine();
		ImGui.TextDisabled(scope $"{mesh.faces.Count} faces, {mesh.positions.Count} vertices" .CStr());
		if (!mesh.IsClosed())
		{
			ImGui.PushStyleColor(ImGui.Col.Text, EditorTheme.Warning);
			ImGui.TextWrapped("Not closed: it has holes. Booleans need closed models.");
			ImGui.PopStyleColor();
		}
		if (ModelSection("Mirror and repeat###wholemirror"))
		{
			ModelGridBegin(80, 3);
			ModelCommandButton(model, mesh, .MirrorX, ModelGridNext());
			ModelCommandButton(model, mesh, .MirrorY, ModelGridNext());
			ModelCommandButton(model, mesh, .MirrorZ, ModelGridNext());
			ModelCount("Copies", ref mModelArrayCount, 2, 100);
			if (ModelNumberButton("Array", 0, 1, true, "Repeats the model this many times, each copy moved on by the step."))
			{
				MeshOps.Array(mesh, mModelArrayCount, mModelArrayOffset);
				ClearModelSelection();
				CommitModel(model);
			}
			ModelVector3("Step", ref mModelArrayOffset);
			ImGui.Spacing();
		}
		if (ModelSection("Clean up###wholeclean"))
		{
			ModelGridBegin(138, 2);
			ModelCommandButton(model, mesh, .FixNormals, ModelGridNext());
			ModelCommandButton(model, mesh, .WeldAll, ModelGridNext());
			if (ImGui.Button("Join Flat Faces", .(ModelGridNext(), 0)))
			{
				let joined = mesh.MergeFlatNeighbours();
				ClearModelSelection();
				Log.Info(scope $"Joined {joined} faces.");
				CommitModel(model);
			}
			ModelHint("Joins neighbouring faces that lie flat together into one.");
			ModelCommandButton(model, mesh, .CleanUp, ModelGridNext());
			ImGui.Spacing();
		}
		if (ModelSection("Origin###wholeorigin", false))
		{
			DrawModelOrigin(model, mesh);
			ImGui.Spacing();
		}
		if (ModelSection("Combine with another object###wholeboolean", false))
		{
			DrawModelBoolean(model);
			ImGui.Spacing();
		}
		if (ModelSection("Levels of detail###wholelod", false))
		{
			ModelNote("Simpler copies as children, picked by distance with a LOD Group. Make them again after editing.");
			ImGui.SetNextItemWidth(-140);
			ImGui.DragInt("Levels", ref mModelLodLevels, 0.05f, 2, 4);
			for (int32 level = 1; level < mModelLodLevels; level++)
			{
				ImGui.SetNextItemWidth(-140);
				ImGui.SliderFloat(scope $"Level {level} keeps" .CStr(), ref mModelLodShares[level], 0.02f, 1, "%.2f");
			}
			if (ImGui.Button("Make Levels of Detail", .(-1, 0)))
				MakeModelLods(model);
			ImGui.Spacing();
		}
		if (ModelSection("Save as a file###wholeexport", false))
		{
			if (mModelExportPath.IsEmpty)
				mModelExportPath.AppendF("Models/{}.glb", model.GameObject.Name);
			ImGui.SetNextItemWidth(-1);
			ImGui.InputText("##modelexport", mModelExportPath, 0, "Models/Name.glb or .tmesh");
			if (ImGui.Button("Export", .(-1, 0)))
				ExportModel(model);
			ModelNote(".glb opens in Blender and other tools. .tmesh is the engine's own and keeps everything. The model is saved with the scene either way.");
		}
	}

	/// Join, cut out or overlap with another object.
	void DrawModelBoolean(ModelMesh model)
	{
		ModelNote("Cut out is how doors and windows go into walls. To draw the cut straight in, use Cut a Hole on the Blockout tab.");
		let other = mModelBooleanOther != 0 ? mScene.FindById(mModelBooleanOther) : null;
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##booleanother", other != null ? other.Name.CStr() : "Pick the other object"))
		{
			for (let renderer in mScene.Renderers)
			{
				let go = renderer.GameObject;
				if (go == model.GameObject || go.Transient || renderer.ActiveMesh == null)
					continue;
				if (ImGui.Selectable(scope $"{go.Name}##{go.Id}" .CStr(), go.Id == mModelBooleanOther))
					mModelBooleanOther = go.Id;
			}
			ImGui.EndCombo();
		}
		let third = (ImGui.GetContentRegionAvail().x - 8) / 3;
		if (ModelButton("##booljoin", "Join", "", third, mModelBooleanOp == 0))
			mModelBooleanOp = 0;
		ModelTip("Join", "", "The two become one solid.");
		ImGui.SameLine(0, 4);
		if (ModelButton("##boolcut", "Cut Out", "", third, mModelBooleanOp == 1))
			mModelBooleanOp = 1;
		ModelTip("Cut Out", "", "The other object is cut out of this one.");
		ImGui.SameLine(0, 4);
		if (ModelButton("##booloverlap", "Overlap", "", third, mModelBooleanOp == 2))
			mModelBooleanOp = 2;
		ModelTip("Overlap", "", "Only where the two overlap is kept.");
		ImGui.Checkbox("Keep the other object", ref mModelBooleanKeep);
		ImGui.BeginDisabled(other == null);
		if (ImGui.Button("Apply", .(-1, 0)) && other != null)
			ModelBoolean(model, other);
		ImGui.EndDisabled();
	}
}
