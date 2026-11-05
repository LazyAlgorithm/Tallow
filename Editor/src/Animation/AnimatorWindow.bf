using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Animator window: the state machine of an Animator Controller (.tcontroller), laid out the way Unity's is.
///   Parameters are on the left. States are boxes on the canvas: the orange one is the default, entered from Entry;
///   Any State stands for "whatever state is current". Right-click the canvas to create a state; right-click a
///   state to make a transition from it (then click the state it goes to), make it the default, or delete it.
///   Click a state or a transition arrow to edit it on the left. Delete removes the selection. Middle-drag pans,
///   the wheel zooms.
/// While the game plays, the selected object's Animator is shown live: its current state is highlighted with a
/// progress bar, and the parameters show (and set) its values.
extension EditorApp
{
	const float StateWidth = 170;
	const float StateHeight = 38;
	static readonly Vector2 AnyStatePosition = .(60, 40);
	static readonly Vector2 EntryPosition = .(60, 140);

	bool mShowAnimator;
	bool mDockAnimator;
	bool mAnimFocus;
	AnimatorController mAnimController;
	String mAnimControllerPath = new .() ~ delete _;
	Vector2 mAnimPan = .(40, 30);
	float mAnimZoom = 1;
	/// The selected state (-1 for Any State, -2 for none) and transition (-1 for none).
	int32 mAnimState = -2;
	int32 mAnimTransition = -1;
	/// The state a transition is being drawn from (-1 Any State), or -3 when none is.
	int32 mAnimLinkFrom = -3;
	int32 mAnimDragState = -2;
	bool mAnimDirty;
	int32 mAnimMenuState = -2;
	Vector2 mAnimMenuPosition;
	List<String> mAnimClipChoices = new .() ~ DeleteContainerAndItems!(_);
	int mAnimClipChoicesFrame = -1000;
	/// The layer shown on the canvas.
	int32 mAnimLayer = 0;

	/// Opens a controller in the Animator window. The path is a file on disk.
	public void OpenAnimator(StringView fullPath)
	{
		let relative = scope String();
		Assets.MakeRelative(fullPath, relative);
		let controller = AnimatorController.Load(relative);
		if (controller == null)
			return;
		mAnimController = controller;
		mAnimControllerPath.Set(relative);
		mAnimState = -2;
		mAnimTransition = -1;
		mAnimLinkFrom = -3;
		mShowAnimator = true;
		mDockAnimator = true;
		mAnimFocus = true;
	}

	void CreateAnimatorAsset(StringView name)
	{
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Animator controller names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.tcontroller";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		// Something to start from: one state, entered by default.
		let controller = scope AnimatorController();
		controller.AddState("Idle", "", .(260, 130));
		controller.Save(path);
		OpenAnimator(path);
	}

	/// The Animator, in play or edit mode, on the selected object or the nearest object above it.
	Animator SelectedAnimator()
	{
		var object = Selected;
		while (object != null)
		{
			let animator = object.GetComponent<Animator>();
			if (animator != null)
				return animator;
			object = object.Transform.Parent?.GameObject;
		}
		return null;
	}

	void SaveAnimator()
	{
		if (mAnimController == null || mAnimControllerPath.IsEmpty)
			return;
		let full = scope String();
		Assets.ResolvePath(mAnimControllerPath, full);
		mAnimController.Save(full);
		mAnimDirty = false;
	}

	/// Every .tanim file in the project, for the clip picker. Refreshed now and then rather than every frame.
	void RefreshClipChoices()
	{
		if (Time.FrameCount - mAnimClipChoicesFrame < 240)
			return;
		mAnimClipChoicesFrame = Time.FrameCount;
		ClearAndDeleteItems!(mAnimClipChoices);
		void Scan(StringView folder, int depth)
		{
			if (depth > 8 || !Directory.Exists(folder))
				return;
			for (let entry in Directory.EnumerateFiles(folder))
			{
				let name = scope String();
				entry.GetFileName(name);
				if (!name.EndsWith(".tanim"))
					continue;
				let relative = new String();
				Assets.MakeRelative(scope $"{folder}/{name}" , relative);
				mAnimClipChoices.Add(relative);
			}
			for (let entry in Directory.EnumerateDirectories(folder))
			{
				let name = scope String();
				entry.GetFileName(name);
				if (!name.StartsWith('.') && name != "build")
					Scan(scope $"{folder}/{name}" , depth + 1);
			}
		}
		Scan(Assets.ProjectPath, 0);
		mAnimClipChoices.Sort(scope (a, b) => a.CompareTo(b));
	}

	static StringView ConditionLabel(AnimatorConditionMode mode)
	{
		switch (mode)
		{
		case .If: return "is true";
		case .IfNot: return "is false";
		case .Greater: return "greater than";
		case .Less: return "less than";
		case .Equals: return "equals";
		case .NotEqual: return "not equal to";
		}
	}

	Vector2 AnimStatePosition(int32 index) => index == -1 ? AnyStatePosition : mAnimController.states[index].position;

	void DrawAnimator()
	{
		if (!mShowAnimator)
			return;
		let selectedAnimator = SelectedAnimator();
		FollowSelectedController(selectedAnimator);
		if (mDockAnimator && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockAnimator = false;
		}
		// Brought to the front when a controller is opened (once the layout exists, at start-up).
		if (mAnimFocus && Time.FrameCount > 30)
		{
			ImGui.SetNextWindowFocus();
			mAnimFocus = false;
		}
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		let visible = ImGui.Begin("Animator", &mShowAnimator, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar();
		if (visible && mAnimController == null)
		{
			ImGui.SetCursorPosX(16);
			ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 14);
			ImGui.TextDisabled("Create a controller with Project > + > Animator Controller, double-click a .tcontroller file,\nor select an object whose Animator has a controller.");
		}
		else if (visible)
		{
			let controller = mAnimController;
			// The running Animator to watch: the selected one, if it uses this controller.
			Animator live = (mPlay != .Edit && selectedAnimator != null && selectedAnimator.Controller == controller) ? selectedAnimator : null;
			mAnimState = Math.Min(mAnimState, (int32)controller.states.Count - 1);
			if (mAnimTransition >= controller.transitions.Count)
				mAnimTransition = -1;
			ImGui.BeginChild("animleft", .(270, 0), ImGui.ChildBorders);
			DrawAnimatorSidebar(controller, live, selectedAnimator);
			ImGui.EndChild();
			ImGui.SameLine(0, 0);
			ImGui.BeginChild("animcanvas", .(0, 0), 0, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse | ImGui.WindowFlags.NoMove);
			DrawStateMachine(controller, live);
			ImGui.EndChild();
		}
		ImGui.End();
		// Changes are written as soon as the mouse is let go, so there is no separate save step to forget.
		if (visible && mAnimController != null && mAnimDirty && !ImGui.IsMouseDown(0))
			SaveAnimator();
	}

	/// Follows the selection: an object whose Animator uses another controller switches the window to it.
	void FollowSelectedController(Animator selectedAnimator)
	{
		if (selectedAnimator == null || selectedAnimator.controller.IsEmpty || selectedAnimator.controller == mAnimControllerPath)
			return;
		let controller = AnimatorController.Load(selectedAnimator.controller);
		if (controller == null)
			return;
		if (mAnimDirty)
			SaveAnimator();
		mAnimController = controller;
		mAnimControllerPath.Set(selectedAnimator.controller);
		mAnimState = -2;
		mAnimTransition = -1;
	}

	/// The left side: layers, parameters, and the selected state or transition.
	void DrawAnimatorSidebar(AnimatorController controller, Animator live, Animator selectedAnimator)
	{
		mAnimLayer = Math.Clamp(mAnimLayer, 0, (int32)controller.layers.Count - 1);
		DrawAnimatorLayers(controller, live);
		ImGui.Dummy(.(0, 6));
		ImGui.Separator();
		DrawAnimatorParameters(controller, live);
		ImGui.Dummy(.(0, 8));
		ImGui.Separator();
		ImGui.Dummy(.(0, 4));
		if (mAnimTransition >= 0)
			DrawAnimatorTransition(controller, controller.transitions[mAnimTransition]);
		else if (mAnimState >= 0)
			DrawAnimatorState(controller, controller.states[mAnimState], selectedAnimator);
		else
		{
			ImGui.SetCursorPosX(8);
			ImGui.TextDisabled(mAnimState == -1 ? "Any State: transitions from here\ncan fire from every state." : "Select a state or a transition.");
		}
	}

	/// The parameters: a + menu to add one of each type, then each with its name, value and a remove button. In play
	/// mode the value shown is the running Animator's, and editing it sets it there.
	void DrawAnimatorParameters(AnimatorController controller, Animator live)
	{
		ImGui.SetCursorPosX(8);
		ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 6);
		ImGui.Text("Parameters");
		ImGui.SameLine();
		if (ImGui.SmallButton("+##param"))
			ImGui.OpenPopup("AddParameter");
		if (ImGui.BeginPopup("AddParameter"))
		{
			for (let type in AnimatorParameterType[?](.Float, .Int, .Bool, .Trigger))
			{
				let label = scope String();
				type.ToString(label);
				if (!ImGui.MenuItem(label.CStr()))
					continue;
				// A name that is not taken yet.
				let name = scope String();
				for (int n = 0;; n++)
				{
					name.Clear();
					name.AppendF(n == 0 ? "New {0}" : "New {0} {1}", label, n);
					if (controller.FindParameter(name) < 0)
						break;
				}
				controller.AddParameter(name, type);
				mAnimDirty = true;
			}
			ImGui.EndPopup();
		}
		int32 removeParameter = -1;
		for (int32 i = 0; i < (int32)controller.parameters.Count; i++)
		{
			ImGui.PushID(i);
			if (DrawParameterRow(controller, i, live))
				removeParameter = i;
			ImGui.PopID();
		}
		if (removeParameter >= 0)
		{
			controller.RemoveParameter(removeParameter);
			mAnimDirty = true;
		}
		if (controller.parameters.Count == 0)
		{
			ImGui.SetCursorPosX(8);
			ImGui.TextDisabled("None yet. Scripts set these;\ntransitions test them.");
		}
	}

	/// One parameter's name, value and remove button. True when it is to be removed.
	bool DrawParameterRow(AnimatorController controller, int32 i, Animator live)
	{
		let parameter = controller.parameters[i];
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(118);
		if (ImGui.InputText("##name", parameter.name))
		{
			controller.Revision++;
			mAnimDirty = true;
		}
		ImGui.SameLine();
		var value = live != null ? live.GetParameter(i) : parameter.defaultValue;
		bool changed = false;
		ImGui.SetNextItemWidth(72);
		switch (parameter.type)
		{
		case .Float:
			changed = ImGui.DragFloat("##value", ref value, 0.05f);
		case .Int:
			int32 whole = (int32)Math.Round(value);
			changed = ImGui.InputInt("##value", ref whole);
			value = whole;
		case .Bool:
			bool flag = value != 0;
			changed = ImGui.Checkbox("##value", ref flag);
			value = flag ? 1 : 0;
		case .Trigger:
			if (ImGui.SmallButton(value != 0 ? "(set)" : "fire"))
			{
				value = 1;
				changed = live != null;
			}
		}
		if (changed && live != null)
		{
			switch (parameter.type)
			{
			case .Float: live.SetFloat(parameter.name, value);
			case .Int: live.SetInteger(parameter.name, (int32)value);
			case .Bool: live.SetBool(parameter.name, value != 0);
			case .Trigger: live.SetTrigger(parameter.name);
			}
		}
		else if (changed && parameter.type != .Trigger)
		{
			parameter.defaultValue = value;
			controller.Revision++;
			mAnimDirty = true;
		}
		ImGui.SameLine();
		return ImGui.SmallButton("x");
	}

	Vector2 StateCenter(int32 state) => AnimStatePosition(state) + Vector2(StateWidth * 0.5f, StateHeight * 0.5f);

	/// The right side: the layer's state machine, with Any State and Entry, which states and transitions are made,
	/// moved, linked and deleted on.
	void DrawStateMachine(AnimatorController controller, Animator live)
	{
		let canvas = CanvasView.Begin("##animcanvas", ref mAnimPan, ref mAnimZoom);
		NodeCanvas.BeginFont(canvas.zoom);
		let hoverState = StateUnderMouse(controller, canvas);
		let hoverTransition = DrawTransitions(controller, canvas, hoverState);
		DrawStates(controller, canvas, live);
		NodeCanvas.EndFont();
		HandleStateMachineMouse(controller, canvas, hoverState, hoverTransition);
		DrawStateMachineMenu(controller);
		if (canvas.hovered && ImGui.IsKeyPressed(ImGui.Key.Delete))
			DeleteAnimatorSelection(controller);
		if (ImGui.IsKeyPressed(ImGui.Key.Escape))
			mAnimLinkFrom = -3;

		// Status line, top left of the canvas.
		let status = scope String();
		status.Append(mAnimControllerPath);
		if (live != null)
			status.AppendF("   Watching: {}  ({})", live.GameObject.Name, live.CurrentState);
		else if (mAnimLinkFrom != -3)
			status.Append("   Click the state this transition goes to (Esc cancels).");
		ImGui.DrawText(.(canvas.origin.x + 8, canvas.origin.y + 6), .(1, 1, 1, 0.55f), status.CStr());
	}

	/// The state (of this layer, or Any State: -1) under the mouse, or -2 for none.
	int32 StateUnderMouse(AnimatorController controller, CanvasView canvas)
	{
		if (!canvas.hovered)
			return -2;
		let graphMouse = canvas.GraphMouse;
		for (int32 i = (int32)controller.states.Count - 1; i >= -1; i--)
		{
			if (i >= 0 && controller.states[i].layer != mAnimLayer)
				continue;
			let p = AnimStatePosition(i);
			if (graphMouse.x >= p.x && graphMouse.x <= p.x + StateWidth && graphMouse.y >= p.y && graphMouse.y <= p.y + StateHeight)
				return i;
		}
		return -2;
	}

	/// A line from one point to another with an arrowhead in the middle, pointing the way it goes.
	static void DrawArrow(CanvasView canvas, Vector2 from, Vector2 to, Color color, float thickness)
	{
		let a = canvas.ToScreen(from), b = canvas.ToScreen(to);
		ImGui.DrawLine(a, b, color, thickness);
		let direction = (to - from).Normalized;
		let side = Vector2(-direction.y, direction.x);
		let middle = (from + to) * 0.5f;
		let tip = canvas.ToScreen(middle + direction * 8);
		ImGui.DrawLine(tip, canvas.ToScreen(middle - direction * 6 + side * 7), color, thickness);
		ImGui.DrawLine(tip, canvas.ToScreen(middle - direction * 6 - side * 7), color, thickness);
	}

	/// The layer's transitions, the arrow from Entry to its default state, and one being made. Returns the
	/// transition under the mouse, or -1.
	int32 DrawTransitions(AnimatorController controller, CanvasView canvas, int32 hoverState)
	{
		let zoom = canvas.zoom;
		let graphMouse = canvas.GraphMouse;
		int32 hoverTransition = -1;
		for (int32 i = 0; i < (int32)controller.transitions.Count; i++)
		{
			let transition = controller.transitions[i];
			if (controller.LayerOf(transition) != mAnimLayer)
				continue;
			var from = StateCenter(transition.from), to = StateCenter(transition.to);
			if (from == to)
				continue;
			// Two transitions between the same pair run side by side instead of on top of each other.
			let direction = (to - from).Normalized;
			let offset = Vector2(-direction.y, direction.x) * 9;
			from += offset;
			to += offset;
			// Distance from the mouse to the line, for picking.
			let along = Mathf.Clamp(Vector2.Dot(graphMouse - from, direction), 0, (to - from).Length);
			let nearest = from + direction * along;
			if (canvas.hovered && hoverState == -2 && (graphMouse - nearest).Length < 7 / Math.Max(zoom, 0.3f))
				hoverTransition = i;
			let selected = i == mAnimTransition;
			let color = selected ? Color(0.45f, 0.70f, 1, 1) : (hoverTransition == i ? Color(1, 1, 1, 1) : Color(0.75f, 0.75f, 0.78f, 0.9f));
			DrawArrow(canvas, from, to, color, (selected ? 2.4f : 1.5f) * zoom);
		}
		let layerDefault = controller.DefaultStateOf(mAnimLayer);
		if (layerDefault >= 0)
			DrawArrow(canvas, EntryPosition + Vector2(StateWidth * 0.5f, StateHeight * 0.5f), StateCenter(layerDefault), .(0.90f, 0.62f, 0.20f, 0.9f), 1.5f * zoom);
		if (mAnimLinkFrom != -3)
			DrawArrow(canvas, StateCenter(mAnimLinkFrom), graphMouse, .(1, 1, 1, 0.9f), 1.5f * zoom);
		return hoverTransition;
	}

	/// A state's box, with a bar along its bottom for how far through its clip it is (`progress` below 0: none).
	static void DrawStateBox(CanvasView canvas, Vector2 position, StringView label, Color color, bool selected, float progress)
	{
		let zoom = canvas.zoom;
		let min = canvas.ToScreen(position), max = canvas.ToScreen(position + Vector2(StateWidth, StateHeight));
		ImGui.DrawRectFilled(min, max, color, 5 * zoom);
		if (progress >= 0)
			ImGui.DrawRectFilled(.(min.x, max.y - 5 * zoom), .(min.x + (max.x - min.x) * Mathf.Clamp01(progress), max.y), .(0.35f, 0.65f, 1, 1), 2 * zoom);
		ImGui.DrawRect(min, max, selected ? Color(0.45f, 0.70f, 1, 1) : Color(0, 0, 0, 0.8f), 5 * zoom, selected ? 2.5f : 1);
		let text = scope String(label);
		let textSize = ImGui.CalcTextSize(text.CStr());
		ImGui.DrawText(.((min.x + max.x - textSize.x) * 0.5f, (min.y + max.y - textSize.y) * 0.5f), .(1, 1, 1, 1), text.CStr());
	}

	/// Any State, Entry and the layer's states: the default one orange, the one playing (in play mode) blue.
	void DrawStates(AnimatorController controller, CanvasView canvas, Animator live)
	{
		DrawStateBox(canvas, AnyStatePosition, "Any State", .(0.20f, 0.52f, 0.52f, 1), mAnimState == -1 && mAnimTransition < 0, -1);
		DrawStateBox(canvas, EntryPosition, "Entry", .(0.20f, 0.50f, 0.25f, 1), false, -1);
		let layerDefault = controller.DefaultStateOf(mAnimLayer);
		for (int32 i = 0; i < (int32)controller.states.Count; i++)
		{
			let state = controller.states[i];
			if (state.layer != mAnimLayer)
				continue;
			let isLive = live != null && live.StateIndexOn(mAnimLayer) == i;
			var color = i == layerDefault ? Color(0.78f, 0.48f, 0.14f, 1) : Color(0.32f, 0.32f, 0.35f, 1);
			if (isLive)
				color = .(0.22f, 0.40f, 0.68f, 1);
			let time = isLive ? live.NormalizedTimeOn(mAnimLayer) : 0;
			let progress = isLive ? (state.loop ? time % 1.0f : time) : -1;
			let label = scope String(state.name);
			if (state.blend != null)
				label.Append("  (blend)");
			DrawStateBox(canvas, state.position, label, color, mAnimState == i && mAnimTransition < 0, progress);
		}
	}

	/// Clicks finish a transition being made, or select (and start dragging) a state or select a transition; a
	/// right-click opens the menu.
	void HandleStateMachineMouse(AnimatorController controller, CanvasView canvas, int32 hoverState, int32 hoverTransition)
	{
		if (canvas.hovered && ImGui.IsMouseClicked(0))
		{
			if (mAnimLinkFrom != -3)
			{
				// Finishing a transition: it goes to the state clicked. Nothing goes to Any State.
				if (hoverState >= 0 && hoverState != mAnimLinkFrom)
				{
					let transition = controller.AddTransition(mAnimLinkFrom, hoverState);
					transition.layer = mAnimLayer;
					// From Any State a transition needs a condition to mean anything; from a state, waiting for
					// the clip to end is the usual default.
					transition.hasExitTime = mAnimLinkFrom >= 0;
					mAnimTransition = (int32)controller.transitions.Count - 1;
					mAnimDirty = true;
				}
				mAnimLinkFrom = -3;
			}
			else if (hoverState != -2)
			{
				mAnimState = hoverState;
				mAnimTransition = -1;
				mAnimDragState = hoverState >= 0 ? hoverState : -2;
			}
			else if (hoverTransition >= 0)
				mAnimTransition = hoverTransition;
			else
			{
				mAnimState = -2;
				mAnimTransition = -1;
			}
		}
		if (mAnimDragState >= 0 && mAnimDragState < controller.states.Count && ImGui.IsMouseDown(0))
		{
			if (ImGui.IsMouseDragging(0, 2))
			{
				controller.states[mAnimDragState].position += Input.MouseDelta / canvas.zoom;
				mAnimDirty = true;
			}
		}
		else
			mAnimDragState = -2;
		if (canvas.hovered && ImGui.IsMouseClicked(1))
		{
			mAnimLinkFrom = -3;
			mAnimMenuState = hoverState;
			mAnimMenuPosition = canvas.GraphMouse;
			ImGui.OpenPopup("AnimatorMenu");
		}
	}

	/// The right-click menu: Create State on empty canvas; Make Transition, Set as Default State and Delete on a state.
	void DrawStateMachineMenu(AnimatorController controller)
	{
		if (!ImGui.BeginPopup("AnimatorMenu"))
			return;
		if (mAnimMenuState == -2)
		{
			if (ImGui.MenuItem("Create State"))
			{
				let name = scope String();
				for (int n = 0;; n++)
				{
					name.Clear();
					name.AppendF(n == 0 ? "New State" : "New State {0}", n);
					if (controller.FindState(name) < 0)
						break;
				}
				controller.AddState(name, "", mAnimMenuPosition).layer = mAnimLayer;
				mAnimState = (int32)controller.states.Count - 1;
				mAnimTransition = -1;
				mAnimDirty = true;
			}
		}
		else
		{
			if (ImGui.MenuItem("Make Transition"))
				mAnimLinkFrom = mAnimMenuState;
			if (mAnimMenuState >= 0)
			{
				if (ImGui.MenuItem("Set as Default State"))
				{
					if (mAnimLayer == 0)
						controller.defaultState = mAnimMenuState;
					else
						controller.layers[mAnimLayer].defaultState = mAnimMenuState;
					controller.Revision++;
					mAnimDirty = true;
				}
				if (ImGui.MenuItem("Delete"))
				{
					controller.RemoveState(mAnimMenuState);
					mAnimState = -2;
					mAnimTransition = -1;
					mAnimDirty = true;
				}
			}
		}
		ImGui.EndPopup();
	}

	/// Delete: removes the selected transition, else the selected state.
	void DeleteAnimatorSelection(AnimatorController controller)
	{
		if (mAnimTransition >= 0)
		{
			delete controller.transitions[mAnimTransition];
			controller.transitions.RemoveAt(mAnimTransition);
			controller.Revision++;
			mAnimTransition = -1;
			mAnimDirty = true;
		}
		else if (mAnimState >= 0)
		{
			controller.RemoveState(mAnimState);
			mAnimState = -2;
			mAnimDirty = true;
		}
	}

	void DrawAnimatorState(AnimatorController controller, AnimatorController.State state, Animator selectedAnimator)
	{
		ImGui.SetCursorPosX(8);
		ImGui.Text("State");
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		if (ImGui.InputText("Name##state", state.name))
		{
			controller.Revision++;
			mAnimDirty = true;
		}
		// What the state plays: one clip, or clips mixed by parameters.
		ImGui.SetCursorPosX(8);
		var useTree = state.blend != null;
		if (ImGui.RadioButton("Clip##motion", !useTree) && useTree)
		{
			DeleteAndNullify!(state.blend);
			useTree = false;
			mAnimDirty = true;
		}
		ImGui.SameLine();
		if (ImGui.RadioButton("Blend Tree##motion", useTree) && !useTree)
		{
			state.blend = new .();
			// Start from the clip it had, so nothing is lost.
			if (!state.clip.IsEmpty)
			{
				let first = new AnimatorController.Motion();
				first.clip.Set(state.clip);
				state.blend.motions.Add(first);
			}
			useTree = true;
			mAnimDirty = true;
		}
		if (!useTree)
		{
			ImGui.SetCursorPosX(8);
			ImGui.SetNextItemWidth(170);
			if (AnimClipCombo("Clip##state", state.clip, selectedAnimator))
				mAnimDirty = true;
		}
		else
			DrawBlendTree(controller, state.blend, selectedAnimator);
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		if (ImGui.DragFloat("Speed##state", ref state.speed, 0.02f))
			mAnimDirty = true;
		ImGui.SetCursorPosX(8);
		if (ImGui.Checkbox("Loop##state", ref state.loop))
			mAnimDirty = true;
		if (mAnimDirty)
			controller.Revision++;
	}

	/// A clip picker: .tanim files in the project and, for an object with a rigged model, the model's own clips.
	bool AnimClipCombo(char8* label, String clip, Animator selectedAnimator)
	{
		bool changed = false;
		if (ImGui.BeginCombo(label, clip.IsEmpty ? (char8*)"(none)" : clip.CStr()))
		{
			RefreshClipChoices();
			if (ImGui.Selectable("(none)", clip.IsEmpty))
			{
				clip.Clear();
				changed = true;
			}
			for (let choice in mAnimClipChoices)
			{
				if (ImGui.Selectable(choice.CStr(), choice == clip))
				{
					clip.Set(choice);
					changed = true;
				}
			}
			// Clips inside the selected object's skinned model are named, not files.
			SkinnedMeshRenderer skinned = selectedAnimator != null ? FindSkinned(selectedAnimator) : default;
			if (skinned && skinned.Model != null)
			{
				for (let modelClip in skinned.Model.Clips)
				{
					let entry = scope String();
					entry.AppendF("{}  (model)", modelClip.name);
					if (ImGui.Selectable(entry.CStr(), modelClip.name == clip))
					{
						clip.Set(modelClip.name);
						changed = true;
					}
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// A float parameter picker for a blend tree.
	bool AnimParameterCombo(char8* label, AnimatorController controller, ref int32 parameter)
	{
		bool changed = false;
		let current = parameter >= 0 && parameter < controller.parameters.Count ? controller.parameters[parameter].name.CStr() : (char8*)"(choose)";
		if (ImGui.BeginCombo(label, current))
		{
			for (int32 i < (int32)controller.parameters.Count)
			{
				let p = controller.parameters[i];
				if (p.type != .Float && p.type != .Int)
					continue;
				if (ImGui.Selectable(p.name.CStr(), parameter == i))
				{
					parameter = i;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// A blend tree's settings: its kind, its parameters, each clip and where it sits, and a picture of them with
	/// the parameters' values now (live while the game plays).
	void DrawBlendTree(AnimatorController controller, AnimatorController.BlendTree tree, Animator selectedAnimator)
	{
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		char8*[2] kinds = .("1D (one number)", "2D (two numbers)");
		if (ImGui.BeginCombo("Kind##blend", kinds[(int)tree.type]))
		{
			for (int i < 2)
			{
				if (ImGui.Selectable(kinds[i], (int)tree.type == i))
				{
					tree.type = (BlendTreeType)i;
					mAnimDirty = true;
				}
			}
			ImGui.EndCombo();
		}
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		if (AnimParameterCombo(tree.type == .Simple1D ? "Parameter##bx" : "X##bx", controller, ref tree.parameterX))
			mAnimDirty = true;
		if (tree.type == .Freeform2D)
		{
			ImGui.SetCursorPosX(8);
			ImGui.SetNextItemWidth(170);
			if (AnimParameterCombo("Y##by", controller, ref tree.parameterY))
				mAnimDirty = true;
		}
		if (controller.parameters.Count == 0)
		{
			ImGui.SetCursorPosX(8);
			ImGui.TextDisabled("Add a Float parameter above first.");
		}
		DrawBlendMotions(tree, selectedAnimator);
		if (tree.motions.Count > 0)
			DrawBlendPicture(controller, tree, selectedAnimator);
	}

	/// The tree's clips, each with the value (or X and Y) where it plays alone, and + Clip.
	void DrawBlendMotions(AnimatorController.BlendTree tree, Animator selectedAnimator)
	{
		ImGui.SetCursorPosX(8);
		ImGui.TextDisabled(tree.type == .Simple1D ? "Clips, and the value where each plays alone:" : "Clips, and the X, Y where each plays alone:");
		int remove = -1;
		for (int i < tree.motions.Count)
		{
			let motion = tree.motions[i];
			ImGui.PushID((int32)i);
			ImGui.SetCursorPosX(8);
			ImGui.SetNextItemWidth(120);
			if (AnimClipCombo("##clip", motion.clip, selectedAnimator))
				mAnimDirty = true;
			ImGui.SameLine();
			if (tree.type == .Simple1D)
			{
				ImGui.SetNextItemWidth(70);
				if (ImGui.DragFloat("##threshold", ref motion.threshold, 0.05f))
					mAnimDirty = true;
			}
			else
			{
				ImGui.SetNextItemWidth(70);
				if (ImGui.DragFloat2("##position", &motion.position.x, 0.05f))
					mAnimDirty = true;
			}
			ImGui.SameLine();
			if (ImGui.SmallButton("x"))
				remove = i;
			ImGui.PopID();
		}
		if (remove >= 0)
		{
			delete tree.motions[remove];
			tree.motions.RemoveAt(remove);
			mAnimDirty = true;
		}
		ImGui.SetCursorPosX(8);
		if (ImGui.SmallButton("+ Clip"))
		{
			let motion = new AnimatorController.Motion();
			// Placed past the last one, so that it can be seen at once.
			if (tree.motions.Count > 0)
			{
				motion.threshold = tree.motions.Back.threshold + 1;
				motion.position = tree.motions.Back.position + Vector2(1, 0);
			}
			tree.motions.Add(motion);
			mAnimDirty = true;
		}
	}

	/// The tree as a picture: clips as dots, each as big as its share now, and the parameters now as a cross.
	void DrawBlendPicture(AnimatorController controller, AnimatorController.BlendTree tree, Animator selectedAnimator)
	{
		let live = (mPlay != .Edit && selectedAnimator != null && selectedAnimator.Controller == controller) ? selectedAnimator : null;
		let x = tree.parameterX >= 0 ? (live != null ? live.GetParameter(tree.parameterX) : (tree.parameterX < controller.parameters.Count ? controller.parameters[tree.parameterX].defaultValue : 0)) : 0;
		let y = tree.parameterY >= 0 ? (live != null ? live.GetParameter(tree.parameterY) : (tree.parameterY < controller.parameters.Count ? controller.parameters[tree.parameterY].defaultValue : 0)) : 0;
		List<float> weights = scope .();
		tree.Weights(x, y, weights);
		ImGui.Dummy(.(0, 4));
		ImGui.SetCursorPosX(8);
		let origin = ImGui.GetCursorScreenPos();
		let width = 240.0f, height = tree.type == .Simple1D ? 36.0f : 150.0f;
		ImGui.InvisibleButton("##blendpicture", .(width, height));
		ImGui.DrawRectFilled(origin, .(origin.x + width, origin.y + height), .(0.12f, 0.12f, 0.14f, 1), 4);
		var low = Vector2(float.MaxValue, float.MaxValue), high = Vector2(-float.MaxValue, -float.MaxValue);
		for (let motion in tree.motions)
		{
			let p = tree.type == .Simple1D ? Vector2(motion.threshold, 0) : motion.position;
			low = .(Math.Min(low.x, p.x), Math.Min(low.y, p.y));
			high = .(Math.Max(high.x, p.x), Math.Max(high.y, p.y));
		}
		low = .(Math.Min(low.x, x), Math.Min(low.y, y));
		high = .(Math.Max(high.x, x), Math.Max(high.y, y));
		let spanX = Math.Max(high.x - low.x, 0.001f), spanY = Math.Max(high.y - low.y, 0.001f);
		ImGui.Vec2 At(Vector2 p) => .(origin.x + 14 + (p.x - low.x) / spanX * (width - 28), tree.type == .Simple1D ? origin.y + height * 0.5f : origin.y + height - 14 - (p.y - low.y) / spanY * (height - 28));
		if (tree.type == .Simple1D)
			ImGui.DrawLine(.(origin.x + 10, origin.y + height * 0.5f), .(origin.x + width - 10, origin.y + height * 0.5f), .(0.4f, 0.4f, 0.45f, 1));
		for (int i < tree.motions.Count)
		{
			let motion = tree.motions[i];
			let at = At(tree.type == .Simple1D ? Vector2(motion.threshold, 0) : motion.position);
			ImGui.DrawCircleFilled(at, 3 + 7 * weights[i], .(0.35f, 0.65f, 1, 0.9f));
		}
		let now = At(.(x, y));
		ImGui.DrawLine(.(now.x - 6, now.y), .(now.x + 6, now.y), .(1, 0.62f, 0.15f, 1), 2);
		ImGui.DrawLine(.(now.x, now.y - 6), .(now.x, now.y + 6), .(1, 0.62f, 0.15f, 1), 2);
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Each dot is a clip, as big as its share now; the cross is where the parameters are.");
	}

	/// The layers: which one the canvas shows, and the selected one's weight, blending and mask.
	void DrawAnimatorLayers(AnimatorController controller, Animator live)
	{
		ImGui.SetCursorPosX(8);
		ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 6);
		ImGui.Text("Layers");
		ImGui.SameLine();
		if (ImGui.SmallButton("+##layer"))
		{
			let name = scope String();
			for (int n = 1;; n++)
			{
				name.Clear();
				name.AppendF("Layer {}", n);
				if (controller.FindLayer(name) < 0)
					break;
			}
			controller.AddLayer(name);
			mAnimLayer = (int32)controller.layers.Count - 1;
			mAnimState = -2;
			mAnimTransition = -1;
			mAnimDirty = true;
		}
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("A layer is a state machine of its own laid over the ones below: the upper body aiming\nwhile the legs run (Override with a mask), or a recoil added on top (Additive).");
		for (int32 i < (int32)controller.layers.Count)
		{
			ImGui.PushID(i + 5000);
			ImGui.SetCursorPosX(8);
			if (ImGui.Selectable(controller.layers[i].name.CStr(), mAnimLayer == i, 0, .(250, 0)))
			{
				mAnimLayer = i;
				mAnimState = -2;
				mAnimTransition = -1;
			}
			ImGui.PopID();
		}
		let layer = controller.layers[mAnimLayer];
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		if (ImGui.InputText("Name##layer", layer.name))
			mAnimDirty = true;
		if (mAnimLayer == 0)
		{
			ImGui.SetCursorPosX(8);
			ImGui.TextDisabled("The whole body, always at full weight.");
			return;
		}
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		// While the game plays the weight shown is the running Animator's, and changing it changes it there.
		var weight = live != null ? live.GetLayerWeight(mAnimLayer) : layer.weight;
		if (ImGui.SliderFloat("Weight##layer", ref weight, 0, 1))
		{
			if (live != null)
				live.SetLayerWeight(mAnimLayer, weight);
			else
			{
				layer.weight = weight;
				mAnimDirty = true;
			}
		}
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		char8*[2] modes = .("Override", "Additive");
		if (ImGui.BeginCombo("Blending##layer", modes[(int)layer.blending]))
		{
			for (int i < 2)
			{
				if (ImGui.Selectable(modes[i], (int)layer.blending == i))
				{
					layer.blending = (AnimatorLayerBlend)i;
					mAnimDirty = true;
				}
			}
			ImGui.EndCombo();
		}
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(170);
		if (ImGui.InputText("Mask##layer", layer.mask))
			mAnimDirty = true;
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("The bones this layer moves: each named bone and everything below it, separated by ;\n(\"spine_02\" for the upper body). Empty: every bone.");
		ImGui.SetCursorPosX(8);
		if (ImGui.SmallButton("Remove Layer"))
		{
			controller.RemoveLayer(mAnimLayer);
			mAnimLayer = 0;
			mAnimState = -2;
			mAnimTransition = -1;
			mAnimDirty = true;
		}
		if (mAnimDirty)
			controller.Revision++;
	}

	static SkinnedMeshRenderer FindSkinned(Animator animator)
	{
		let own = animator.GetComponent<SkinnedMeshRenderer>();
		if (own)
			return own;
		for (let child in animator.Transform.Children)
		{
			let found = child.GameObject.GetComponent<SkinnedMeshRenderer>();
			if (found)
				return found;
		}
		return default;
	}

	/// One condition of a transition: its parameter, how it is compared and with what. True when it is to be removed.
	bool DrawConditionRow(AnimatorController controller, ref AnimatorController.Condition condition)
	{
		let parameter = controller.parameters[condition.parameter];
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(92);
		if (ImGui.BeginCombo("##parameter", parameter.name.CStr()))
		{
			for (int32 p = 0; p < (int32)controller.parameters.Count; p++)
			{
				if (ImGui.Selectable(controller.parameters[p].name.CStr(), p == condition.parameter))
				{
					condition.parameter = p;
					let numeric = controller.parameters[p].type == .Float || controller.parameters[p].type == .Int;
					condition.mode = numeric ? .Greater : .If;
					mAnimDirty = true;
				}
			}
			ImGui.EndCombo();
		}
		let numeric = parameter.type == .Float || parameter.type == .Int;
		if (parameter.type != .Trigger)
		{
			ImGui.SameLine();
			ImGui.SetNextItemWidth(92);
			if (ImGui.BeginCombo("##mode", scope String(ConditionLabel(condition.mode)).CStr()))
			{
				for (let mode in AnimatorConditionMode[?](.If, .IfNot, .Greater, .Less, .Equals, .NotEqual))
				{
					// Numbers are compared; booleans are simply true or false.
					if ((mode == .If || mode == .IfNot) == numeric)
						continue;
					if (parameter.type == .Float && (mode == .Equals || mode == .NotEqual))
						continue;
					if (ImGui.Selectable(scope String(ConditionLabel(mode)).CStr(), mode == condition.mode))
					{
						condition.mode = mode;
						mAnimDirty = true;
					}
				}
				ImGui.EndCombo();
			}
		}
		if (numeric)
		{
			ImGui.SameLine();
			ImGui.SetNextItemWidth(46);
			if (ImGui.DragFloat("##threshold", ref condition.threshold, parameter.type == .Int ? 1 : 0.05f))
				mAnimDirty = true;
		}
		ImGui.SameLine();
		return ImGui.SmallButton("x");
	}

	void DrawAnimatorTransition(AnimatorController controller, AnimatorController.Transition transition)
	{
		ImGui.SetCursorPosX(8);
		let title = scope String();
		title.AppendF("{}  ->  {}", transition.from < 0 ? (StringView)"Any State" : controller.states[transition.from].name, controller.states[transition.to].name);
		ImGui.Text(title);
		ImGui.SetCursorPosX(8);
		if (ImGui.Checkbox("Has Exit Time", ref transition.hasExitTime))
			mAnimDirty = true;
		if (transition.hasExitTime)
		{
			ImGui.SetCursorPosX(8);
			ImGui.SetNextItemWidth(120);
			if (ImGui.DragFloat("Exit Time", ref transition.exitTime, 0.01f, 0, 100))
				mAnimDirty = true;
		}
		ImGui.SetCursorPosX(8);
		ImGui.SetNextItemWidth(120);
		if (ImGui.DragFloat("Duration (s)", ref transition.duration, 0.01f, 0, 10))
			mAnimDirty = true;
		ImGui.Dummy(.(0, 4));
		ImGui.SetCursorPosX(8);
		ImGui.Text("Conditions");
		ImGui.SameLine();
		ImGui.BeginDisabled(controller.parameters.Count == 0);
		if (ImGui.SmallButton("+##condition"))
		{
			AnimatorController.Condition condition;
			condition.parameter = 0;
			condition.threshold = 0;
			condition.mode = controller.parameters[0].type == .Float || controller.parameters[0].type == .Int ? .Greater : .If;
			transition.conditions.Add(condition);
			mAnimDirty = true;
		}
		ImGui.EndDisabled();
		int remove = -1;
		for (int i < transition.conditions.Count)
		{
			var condition = ref transition.conditions[i];
			condition.parameter = Math.Clamp(condition.parameter, 0, (int32)controller.parameters.Count - 1);
			if (condition.parameter < 0)
				continue;
			ImGui.PushID((int32)i + 1000);
			if (DrawConditionRow(controller, ref condition))
				remove = i;
			ImGui.PopID();
		}
		if (remove >= 0)
		{
			transition.conditions.RemoveAt(remove);
			mAnimDirty = true;
		}
		if (transition.conditions.Count == 0 && !transition.hasExitTime)
		{
			ImGui.SetCursorPosX(8);
			ImGui.TextDisabled("With no condition and no exit\ntime, this never fires.");
		}
		if (mAnimDirty)
			controller.Revision++;
	}
}
