using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Window > Input Actions: the project's controls. Maps on the left (groups switched on and off together), the
/// actions of the chosen map in the middle, and on the right the keys, mouse buttons and controller buttons that
/// work the chosen action. Saved as Input.tinput in the asset folder; game code asks InputActions for the actions
/// by name.
extension EditorApp
{
	bool mShowInputActions;
	bool mInputDirty;
	int mInputMap, mInputAction;
	// Waiting for a key or button to give to this binding of the chosen action; -1 when not listening.
	int mInputListen = -1;
	String mInputStatus = new .() ~ delete _;

	static readonly char8*[?] InputKinds = .("Button", "Axis", "Direction");
	static readonly char8*[?] InputKindHints = .("Down or not: jump, fire, use. A trigger also says how far it is pulled.", "One number from -1 to 1: throttle, zoom, lean.", "Two axes, such as moving and looking around.");
	/// One name for each InputBindingKind, in its order (sized by the enum, so that a kind added there without a name
	/// here does not compile).
	static readonly char8*[(int)InputBindingKind.Touch + 1] BindingKindNames = .("Key", "Mouse button", "Mouse wheel", "Mouse movement", "Controller button", "Controller axis", "Controller stick",
		"Controller d-pad", "Two keys (- and +)", "Four keys (up down left right)", "On-screen control");

	void SaveInputActions()
	{
		let text = scope String();
		InputActions.ToText(text);
		let path = scope String();
		Project.Current.GetAssetPath(path);
		path.AppendF("/{}", InputActions.FileName);
		if (File.WriteAllText(path, text) case .Ok)
		{
			mInputDirty = false;
			mInputStatus.Set(scope $"Saved to {InputActions.FileName}. The running game uses it straight away.");
			RefreshAssetList();
		}
		else
			mInputStatus.Set("Could not save.");
	}

	/// A combo of every key the engine knows.
	bool KeyCombo(char8* label, ref KeyCode key)
	{
		bool changed = false;
		let current = scope String();
		InputActions.KeyName(key, current);
		ImGui.SetNextItemWidth(104);
		if (ImGui.BeginCombo(label, current.CStr()))
		{
			for (let (name, value) in Enum.GetEnumerator<KeyCode>())
			{
				if (value == .None)
					continue;
				let shown = scope String();
				InputActions.KeyName(value, shown);
				if (ImGui.Selectable(scope String()..AppendF("{}##{}", shown, name).CStr(), value == key))
				{
					key = value;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	bool EnumCombo<T>(char8* label, ref T value, float width = 150) where T : enum
	{
		bool changed = false;
		ImGui.SetNextItemWidth(width);
		if (ImGui.BeginCombo(label, scope String()..AppendF("{}", value).CStr()))
		{
			for (let (name, option) in Enum.GetEnumerator<T>())
			{
				if (name == "Count")
					continue;
				if (ImGui.Selectable(scope String(name).CStr(), option == value))
				{
					value = option;
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// Whether a kind of binding makes sense for a kind of action: directions take sticks, key crosses and mouse
	/// movement; buttons and axes take everything else.
	static bool BindingFits(InputBindingKind binding, InputActionKind action)
	{
		// An on-screen control can be a button, an axis or a stick, whichever the action needs.
		if (binding == .Touch)
			return true;
		let directional = binding == .MouseDelta || binding == .PadStick || binding == .PadDpad || binding == .Keys;
		return (action == .Vector) == directional;
	}

	static void UniqueName(String name, delegate bool(StringView) taken)
	{
		let stem = scope String(name);
		for (int suffix = 2; taken(name); suffix++)
			name..Clear().AppendF("{}{}", stem, suffix);
	}

	void DrawInputActions()
	{
		if (!mShowInputActions)
			return;
		ImGui.SetNextWindowSize(.(1180, 560), ImGui.Cond.FirstUseEver);
		if (ImGui.Begin("Input Actions", &mShowInputActions, ImGui.WindowFlags.NoCollapse))
			DrawInputActionsContents();
		ImGui.End();
	}

	void DrawInputActionsContents()
	{
		let maps = InputActions.Maps;
		DrawInputToolbar(maps);
		mInputMap = Math.Clamp(mInputMap, 0, Math.Max(maps.Count - 1, 0));
		let map = maps.Count > 0 ? maps[mInputMap] : null;
		if (map != null)
			mInputAction = Math.Clamp(mInputAction, 0, Math.Max(map.actions.Count - 1, 0));
		let action = (map != null && map.actions.Count > 0) ? map.actions[mInputAction] : null;
		let height = ImGui.GetContentRegionAvail().y;

		ImGui.BeginChild("##inputmaps", .(200, height), 1);
		let mapKept = DrawInputMaps(maps, map);
		ImGui.EndChild();
		// The map was removed: the rest is drawn from the next frame.
		if (!mapKept)
			return;
		ImGui.SameLine();
		ImGui.BeginChild("##inputactions", .(240, height), 1);
		DrawInputActionList(map);
		ImGui.EndChild();
		ImGui.SameLine();
		ImGui.BeginChild("##inputbindings", .(0, height), 1);
		if (action == null)
			ImGui.TextDisabled(map == null ? "Add a map, then actions to it." : "Add an action to this map.");
		else
			DrawInputAction(map, action);
		ImGui.EndChild();
	}

	/// Save, a way to start from the engine's standard actions when there are none, and the controllers connected.
	void DrawInputToolbar(List<InputMap> maps)
	{
		if (ImGui.Button(mInputDirty ? "Save *" : "Save"))
			SaveInputActions();
		ImGui.SameLine();
		if (maps.IsEmpty)
		{
			if (ImGui.Button("Start From The Standard Actions"))
			{
				InputActions.LoadText(InputActions.StandardText);
				mInputDirty = true;
				mInputMap = mInputAction = 0;
			}
			ImGui.SameLine();
		}
		ImGui.TextDisabled(mInputStatus.IsEmpty ? scope String()..AppendF("{} controller(s) connected{}", Gamepad.Count, Gamepad.Count > 0 ? scope $": {Gamepad.Name()}" : "").CStr() : mInputStatus.CStr());
		ImGui.Separator();
		if (maps.IsEmpty)
		{
			ImGui.PushTextWrapPos(0);
			ImGui.TextDisabled("This project has no actions of its own, so it has the engine's standard ones: Move, Look, Jump, Sprint, Crouch, Fire, Use, Reload, Ability1, Ability2, Talk, Submit and Cancel, on the keyboard and mouse and on a controller. Start from those to change them or add your own, or add an empty map below.");
			ImGui.PopTextWrapPos();
		}
	}

	/// The maps column: the list, + Map, and the chosen map's name and Remove Map. False when the map was removed.
	bool DrawInputMaps(List<InputMap> maps, InputMap map)
	{
		ImGui.TextDisabled("Maps");
		for (int i < maps.Count)
		{
			if (ImGui.Selectable(scope String()..AppendF("{}##map{}", maps[i].name, i).CStr(), i == mInputMap))
			{
				mInputMap = i;
				mInputAction = 0;
				mInputListen = -1;
			}
		}
		ImGui.Spacing();
		if (ImGui.SmallButton("+ Map"))
		{
			let added = new InputMap();
			added.name.Set("Map");
			UniqueName(added.name, scope (name) =>
				{
					for (let other in maps)
					{
						if (other.name == name)
							return true;
					}
					return false;
				});
			maps.Add(added);
			mInputMap = maps.Count - 1;
			mInputAction = 0;
			mInputDirty = true;
			InputActions.Changed();
		}
		if (map == null)
			return true;
		ImGui.Spacing();
		ImGui.TextDisabled("Name");
		ImGui.SetNextItemWidth(-1);
		if (ImGui.InputText("##mapname", map.name))
		{
			map.name.Replace(' ', '_');
			mInputDirty = true;
			InputActions.Changed();
		}
		if (ImGui.SmallButton("Remove Map"))
		{
			maps.RemoveAt(mInputMap);
			delete map;
			mInputDirty = true;
			mInputListen = -1;
			InputActions.Changed();
			return false;
		}
		ImGui.PushTextWrapPos(0);
		ImGui.TextDisabled("A map is switched on and off as a whole with InputActions.SetMapEnabled.");
		ImGui.PopTextWrapPos();
		return true;
	}

	/// The actions column: the chosen map's actions, each with what it gives, and + Action.
	void DrawInputActionList(InputMap map)
	{
		ImGui.TextDisabled("Actions");
		if (map == null)
			return;
		for (int i < map.actions.Count)
		{
			let entry = map.actions[i];
			if (ImGui.Selectable(scope String()..AppendF("{}##action{}", entry.name, i).CStr(), i == mInputAction))
			{
				mInputAction = i;
				mInputListen = -1;
			}
			ImGui.SameLine(170);
			ImGui.TextDisabled(InputKinds[(int)entry.kind]);
		}
		ImGui.Spacing();
		if (ImGui.SmallButton("+ Action"))
		{
			let added = new InputAction();
			added.name.Set("Action");
			UniqueName(added.name, scope (name) => map.Find(name) != null);
			map.actions.Add(added);
			mInputAction = map.actions.Count - 1;
			mInputDirty = true;
			InputActions.Changed();
		}
	}

	/// The chosen action: its name, what it gives (and what it gives now), its bindings, and how a script reads it.
	void DrawInputAction(InputMap map, InputAction action)
	{
		ImGui.TextDisabled("Name");
		ImGui.SameLine(70);
		ImGui.SetNextItemWidth(220);
		if (ImGui.InputText("##actionname", action.name))
		{
			action.name.Replace(' ', '_');
			mInputDirty = true;
			InputActions.Changed();
		}
		ImGui.SameLine();
		if (ImGui.SmallButton("Remove Action"))
		{
			map.actions.RemoveAt(mInputAction);
			delete action;
			mInputDirty = true;
			mInputListen = -1;
			InputActions.Changed();
			return;
		}
		ImGui.TextDisabled("Gives");
		ImGui.SameLine(70);
		ImGui.SetNextItemWidth(220);
		if (ImGui.BeginCombo("##actionkind", InputKinds[(int)action.kind]))
		{
			for (int32 i < 3)
			{
				if (!ImGui.Selectable(InputKinds[i], (int32)action.kind == i))
					continue;
				action.kind = (InputActionKind)i;
				// Bindings that make no sense for the new kind go.
				for (int b = action.bindings.Count - 1; b >= 0; b--)
				{
					if (!BindingFits(action.bindings[b].kind, action.kind))
						action.bindings.RemoveAt(b);
				}
				mInputDirty = true;
			}
			ImGui.EndCombo();
		}
		ImGui.SameLine();
		ImGui.TextDisabled(InputKindHints[(int)action.kind]);
		// What the action is doing right now: try the keys and the controller and watch.
		if (action.kind == .Vector)
			ImGui.TextDisabled(scope String()..AppendF("Now: {:0.00}, {:0.00}", action.vector.x, action.vector.y).CStr());
		else
			ImGui.TextDisabled(scope String()..AppendF("Now: {:0.00}", action.value).CStr());
		ImGui.SeparatorText("Bindings");

		for (int i = 0; i < action.bindings.Count; i++)
		{
			ImGui.PushID((int32)i);
			let removed = DrawBindingRow(action, i);
			ImGui.PopID();
			if (removed)
				break;
		}
		// None of its own: a standard action's name and kind means it uses the standard bindings.
		if (action.bindings.IsEmpty)
		{
			let standard = InputActions.Standard(action.name);
			ImGui.PushTextWrapPos(0);
			if (standard != null && standard.kind == action.kind)
			{
				let names = scope String();
				for (let binding in standard.bindings)
					InputActions.BindingName(binding, names..Append(names.IsEmpty ? "" : ", "));
				ImGui.TextDisabled(scope String()..AppendF("No bindings of its own, so it uses the standard ones: {}.", names).CStr());
				ImGui.PopTextWrapPos();
				if (ImGui.SmallButton("Copy The Standard Bindings"))
				{
					action.bindings.AddRange(standard.bindings);
					mInputDirty = true;
				}
				ImGui.SameLine();
			}
			else
			{
				ImGui.TextDisabled("No bindings: nothing works it yet.");
				ImGui.PopTextWrapPos();
			}
		}
		if (ImGui.SmallButton("+ Binding"))
		{
			action.bindings.Add(action.kind == .Vector ? InputBinding.WASD : InputBinding.Key(.Space));
			mInputDirty = true;
		}
		ListenForBinding(action);
		ImGui.Spacing();
		ImGui.PushTextWrapPos(0);
		ImGui.TextDisabled(scope String()..AppendF("In a script: InputActions.{}", action.kind == .Vector ? scope $"Vector(\"{action.name}\")  or  Delta(\"{action.name}\")" : (action.kind == .Axis ? scope $"Value(\"{action.name}\")" : scope $"Pressed(\"{action.name}\")  Held(\"{action.name}\")  Released(\"{action.name}\")")).CStr());
		ImGui.PopTextWrapPos();
	}

	/// One binding: its kind, what it is bound to, then Scale, Invert, Listen and Remove. True when it was removed.
	bool DrawBindingRow(InputAction action, int i)
	{
		var binding = ref action.bindings[i];
		bool changed = BindingKindCombo(ref binding, action.kind);
		ImGui.SameLine();
		changed |= EditBinding(ref binding);
		// A second row for the extras, so that the first stays readable.
		ImGui.SetNextItemWidth(90);
		changed |= ImGui.DragFloat("Scale", ref binding.scale, 0.05f, -10000, 10000, "%.2f");
		if (ImGui.IsItemHovered())
			ImGui.SetTooltip("Multiplies what the binding gives. For InputActions.Delta (looking around) it is how fast a stick or keys turn: units a second, where the mouse gives its own movement.");
		ImGui.SameLine();
		changed |= ImGui.Checkbox("Invert", ref binding.invert);
		if (binding.kind == .Key || binding.kind == .MouseButton || binding.kind == .PadButton)
		{
			ImGui.SameLine();
			if (ImGui.SmallButton(mInputListen == i ? "Press a key or button..." : "Listen"))
				mInputListen = mInputListen == i ? -1 : i;
		}
		ImGui.SameLine();
		if (ImGui.SmallButton("Remove"))
		{
			action.bindings.RemoveAt(i);
			mInputListen = -1;
			mInputDirty = true;
			return true;
		}
		ImGui.Separator();
		mInputDirty |= changed;
		return false;
	}

	/// The kind of input a binding reads, among those that fit the action. A new kind starts from a sensible key.
	static bool BindingKindCombo(ref InputBinding binding, InputActionKind actionKind)
	{
		bool changed = false;
		ImGui.SetNextItemWidth(210);
		if (!ImGui.BeginCombo("##kind", BindingKindNames[(int)binding.kind]))
			return false;
		for (int32 k < (int32)BindingKindNames.Count)
		{
			if (!BindingFits((InputBindingKind)k, actionKind))
				continue;
			if (!ImGui.Selectable(BindingKindNames[k], (int32)binding.kind == k))
				continue;
			let scale = binding.scale;
			binding = .();
			binding.kind = (InputBindingKind)k;
			binding.scale = scale;
			if (binding.kind == .Key)
				binding.key = .Space;
			else if (binding.kind == .KeyAxis)
			{
				binding.key = .S;
				binding.key2 = .W;
			}
			else if (binding.kind == .Keys)
				binding = InputBinding.WASD;
			else if (binding.kind == .MouseWheel)
				binding.index = 1;
			changed = true;
		}
		ImGui.EndCombo();
		return changed;
	}

	/// A combo of named choices for one of a binding's numbers (a mouse button, a wheel direction, a stick). The
	/// first name is shown for a number that is none of them.
	static bool IndexCombo(char8* id, ref int32 index, Span<int32> values, Span<char8*> names)
	{
		char8* current = names[0];
		for (int i < values.Length)
		{
			if (values[i] == index)
				current = names[i];
		}
		bool changed = false;
		ImGui.SetNextItemWidth(120);
		if (ImGui.BeginCombo(id, current))
		{
			for (int i < values.Length)
			{
				if (ImGui.Selectable(names[i], index == values[i]))
				{
					index = values[i];
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	/// What a binding is bound to, as its kind needs: a key, a mouse button, keys for an axis or a vector, and so on.
	bool EditBinding(ref InputBinding binding)
	{
		bool changed = false;
		switch (binding.kind)
		{
		case .Key:
			changed |= KeyCombo("##key", ref binding.key);
		case .MouseButton:
			changed |= IndexCombo("##mouse", ref binding.index, int32[3](0, 1, 2), char8*[3] ("Left", "Right", "Middle"));
		case .MouseWheel:
			changed |= IndexCombo("##wheel", ref binding.index, int32[2](1, -1), char8*[2] ("Up", "Down"));
		case .PadButton:
			changed |= EnumCombo("##padbutton", ref binding.button);
		case .PadAxis:
			changed |= EnumCombo("##padaxis", ref binding.axis);
		case .PadStick:
			changed |= IndexCombo("##stick", ref binding.index, int32[2](0, 1), char8*[2] ("Left", "Right"));
		case .KeyAxis:
			changed |= KeyCombo("##minus", ref binding.key);
			ImGui.SameLine();
			changed |= KeyCombo("##plus", ref binding.key2);
		case .Keys:
			changed |= KeyCombo("##up", ref binding.key);
			ImGui.SameLine();
			changed |= KeyCombo("##down", ref binding.key2);
			ImGui.SameLine();
			changed |= KeyCombo("##left", ref binding.key3);
			ImGui.SameLine();
			changed |= KeyCombo("##right", ref binding.key4);
		case .Touch:
			// The name of an on-screen control the game adds with TouchControls.
			let controlName = scope String(TouchControls.NameOf(binding.index));
			ImGui.SetNextItemWidth(160);
			if (ImGui.InputText("##touch", controlName))
			{
				binding.index = TouchControls.NameId(controlName);
				changed = true;
			}
		default:
		}
		return changed;
	}

	/// Listening: the next key, mouse button or controller button pressed becomes the binding.
	void ListenForBinding(InputAction action)
	{
		if (mInputListen < 0 || mInputListen >= action.bindings.Count || ImGui.IsMouseDown(0))
			return;
		InputBinding captured;
		if (!InputActions.Capture(out captured))
			return;
		captured.scale = action.bindings[mInputListen].scale;
		captured.invert = action.bindings[mInputListen].invert;
		action.bindings[mInputListen] = captured;
		mInputListen = -1;
		mInputDirty = true;
	}
}
