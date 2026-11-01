using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The modeller's keyboard shortcuts. Every modelling tool, the selection modes, edit mode, search, the quick menu and
/// Show Only This Model can have keys (several each, "X, Delete"), changed in Edit > Preferences > Modelling and kept
/// for this user on this machine (model_shortcuts.txt with the editor's other settings). A key pressed with exactly
/// the modifiers written runs the action; when two actions share a key (M merges vertices and collapses edges), the
/// one that works in the current mode runs.
extension EditorApp
{
	// Actions that are not commands; commands follow them, in ModelCommand's order.
	const int ShortcutEditMode = 0;
	const int ShortcutVertexMode = 1;
	const int ShortcutEdgeMode = 2;
	const int ShortcutFaceMode = 3;
	const int ShortcutSearch = 4;
	const int ShortcutMenu = 5;
	const int ShortcutShowOnly = 6;
	const int ShortcutCommands = 7;

	static (StringView id, StringView name, StringView keys)[?] sModelShortcutExtras = .(
		("EditMode", "Edit Mode on and off", "Tab"),
		("VertexMode", "Pick Vertices", "1"),
		("EdgeMode", "Pick Edges", "2"),
		("FaceMode", "Pick Faces", "3"),
		("Search", "Find a Tool by Name", "Space"),
		("QuickMenu", "Tool Menu", "Ctrl+E, Ctrl+F, Ctrl+V"),
		("ShowOnly", "Show Only This Model", "/"));

	// Keys beyond the one the command table shows, so the old ones keep working.
	static (ModelCommand command, StringView keys)[?] sModelShortcutMore = .(
		(.Delete, "X, Delete, Shift+Delete"),
		(.SelectAll, "A, Ctrl+A"),
		(.Duplicate, "Shift+D, Ctrl+D"),
		(.Linked, "L, Ctrl+L"),
		(.Grow, "Ctrl+=, Ctrl+Keypad +"),
		(.Shrink, "Ctrl+-, Ctrl+Keypad -"),
		(.Slide, ""),
		(.SelectLoop, ""));

	// A chord: the key, with the modifiers above it.
	const int32 ChordCtrl = 0x10000;
	const int32 ChordShift = 0x20000;
	const int32 ChordAlt = 0x40000;
	const int32 ChordKey = 0xFFFF;

	List<List<int32>> mModelShortcuts ~ DeleteContainerAndItems!(_);
	List<String> mModelShortcutText ~ DeleteContainerAndItems!(_);
	/// The action Preferences is waiting for a key for (-1: none).
	int mShortcutCapture = -1;
	String mShortcutFilter = new .() ~ delete _;

	/// The shortcut action of a command.
	static int ModelCommandShortcut(ModelCommand command) => ShortcutCommands + command.Underlying;

	static int ModelShortcutCount => ShortcutCommands + ModelCommand.Help.Underlying + 1;

	/// The id kept in the file: the extras' own, or the command's name.
	static void ModelShortcutKey(int action, String output)
	{
		if (action < ShortcutCommands)
			output.Append(sModelShortcutExtras[action].id);
		else
			((ModelCommand)(action - ShortcutCommands)).ToString(output);
	}

	static void ModelShortcutName(int action, String output)
	{
		if (action < ShortcutCommands)
		{
			output.Append(sModelShortcutExtras[action].name);
			return;
		}
		let command = (ModelCommand)(action - ShortcutCommands);
		for (let entry in sModelCommands)
		{
			if (entry.command == command)
			{
				output.Append(entry.name);
				return;
			}
		}
		command.ToString(output);
	}

	static StringView ModelShortcutGroup(int action)
	{
		if (action < ShortcutCommands)
			return "Modes and menus";
		let command = (ModelCommand)(action - ShortcutCommands);
		for (let entry in sModelCommands)
		{
			if (entry.command == command)
				return entry.group;
		}
		return "Model";
	}

	/// The keys an action starts with.
	static StringView ModelShortcutDefault(int action)
	{
		if (action < ShortcutCommands)
			return sModelShortcutExtras[action].keys;
		let command = (ModelCommand)(action - ShortcutCommands);
		for (let more in sModelShortcutMore)
		{
			if (more.command == command)
				return more.keys;
		}
		for (let entry in sModelCommands)
		{
			if (entry.command == command)
				return entry.keys;
		}
		return "";
	}

	/// A key's name, as shortcuts are written ("" for one with no name).
	public static void ShortcutKeyName(int32 key, String output)
	{
		if (key >= ImGui.Key.A && key <= ImGui.Key.Z)
			output.Append((char8)('A' + (key - ImGui.Key.A)));
		else if (key >= ImGui.Key.Zero && key <= ImGui.Key.Nine)
			output.Append((char8)('0' + (key - ImGui.Key.Zero)));
		else if (key >= ImGui.Key.F1 && key < ImGui.Key.F1 + 12)
			output.AppendF("F{}", key - ImGui.Key.F1 + 1);
		else if (key >= ImGui.Key.Keypad0 && key <= ImGui.Key.Keypad9)
			output.AppendF("Keypad {}", key - ImGui.Key.Keypad0);
		else
		{
			switch (key)
			{
			case 512: output.Append("Tab");
			case 513: output.Append("Left");
			case 514: output.Append("Right");
			case 515: output.Append("Up");
			case 516: output.Append("Down");
			case 517: output.Append("Page Up");
			case 518: output.Append("Page Down");
			case 519: output.Append("Home");
			case 520: output.Append("End");
			case 521: output.Append("Insert");
			case 522: output.Append("Delete");
			case 523: output.Append("Backspace");
			case 524: output.Append("Space");
			case 525: output.Append("Enter");
			case 526: output.Append("Escape");
			case 596: output.Append("'");
			case 597: output.Append(",");
			case 598: output.Append("-");
			case 599: output.Append(".");
			case 600: output.Append("/");
			case 601: output.Append(";");
			case 602: output.Append("=");
			case 603: output.Append("[");
			case 604: output.Append("\\");
			case 605: output.Append("]");
			case 606: output.Append("`");
			case 622: output.Append("Keypad .");
			case 623: output.Append("Keypad /");
			case 624: output.Append("Keypad *");
			case 625: output.Append("Keypad -");
			case 626: output.Append("Keypad +");
			case 627: output.Append("Keypad Enter");
			default:
			}
		}
	}

	/// "Ctrl+Shift+B" for a chord.
	public static void ShortcutChordName(int32 chord, String output)
	{
		if ((chord & ChordCtrl) != 0)
			output.Append("Ctrl+");
		if ((chord & ChordShift) != 0)
			output.Append("Shift+");
		if ((chord & ChordAlt) != 0)
			output.Append("Alt+");
		ShortcutKeyName(chord & ChordKey, output);
	}

	/// Reads one chord ("Ctrl+B", "Shift+Keypad +"); 0 when it names no key.
	public static int32 ShortcutParseChord(StringView text)
	{
		var rest = text;
		rest.Trim();
		int32 mods = 0;
		while (true)
		{
			if (rest.StartsWith("Ctrl+", .OrdinalIgnoreCase) && rest.Length > 5)
			{
				mods |= ChordCtrl;
				rest = rest.Substring(5);
			}
			else if (rest.StartsWith("Shift+", .OrdinalIgnoreCase) && rest.Length > 6)
			{
				mods |= ChordShift;
				rest = rest.Substring(6);
			}
			else if (rest.StartsWith("Alt+", .OrdinalIgnoreCase) && rest.Length > 4)
			{
				mods |= ChordAlt;
				rest = rest.Substring(4);
			}
			else
				break;
		}
		let name = scope String();
		for (int32 key = 512; key <= 627; key++)
		{
			ShortcutKeyName(key, name..Clear());
			if (!name.IsEmpty && StringView.Compare(name, rest, true) == 0)
				return mods | key;
		}
		return 0;
	}

	/// Reads a list of chords ("X, Delete") into keys. A ',' key is written "Ctrl+," and needs no special care
	/// except on its own, which is read as the comma key.
	static void ShortcutParseList(StringView text, List<int32> keys)
	{
		keys.Clear();
		var trimmed = text;
		trimmed.Trim();
		if (trimmed == ",")
		{
			keys.Add(597);
			return;
		}
		for (var part in text.Split(','))
		{
			let chord = ShortcutParseChord(part);
			if (chord != 0 && !keys.Contains(chord))
				keys.Add(chord);
		}
	}

	static void ModelShortcutsFile(String file)
	{
		RecentProjects.GetConfigFolder(file);
		file.Append("model_shortcuts.txt");
	}

	/// The shortcuts in use: the defaults, with this user's changes read over them (made the first time).
	void EnsureModelShortcuts()
	{
		if (mModelShortcuts != null)
			return;
		mModelShortcuts = new .();
		mModelShortcutText = new .();
		for (int a < ModelShortcutCount)
		{
			let keys = new List<int32>();
			ShortcutParseList(ModelShortcutDefault(a), keys);
			mModelShortcuts.Add(keys);
			mModelShortcutText.Add(new .());
		}
		let text = scope String();
		if (File.ReadAllText(ModelShortcutsFile(.. scope .()), text) case .Ok)
		{
			let id = scope String();
			for (let line in text.Split('\n'))
			{
				let equals = line.IndexOf('=');
				if (equals <= 0)
					continue;
				let name = line.Substring(0, equals)..Trim();
				for (int a < ModelShortcutCount)
				{
					ModelShortcutKey(a, id..Clear());
					if (id == name)
						ShortcutParseList(line.Substring(equals + 1), mModelShortcuts[a]);
				}
			}
		}
		RefreshModelShortcutText();
	}

	void RefreshModelShortcutText()
	{
		for (int a < ModelShortcutCount)
		{
			let text = mModelShortcutText[a]..Clear();
			for (let chord in mModelShortcuts[a])
			{
				if (!text.IsEmpty)
					text.Append(", ");
				ShortcutChordName(chord, text);
			}
		}
	}

	/// Writes the shortcuts that differ from the defaults.
	void SaveModelShortcuts()
	{
		let output = scope String();
		let defaults = scope List<int32>();
		let id = scope String();
		for (int a < ModelShortcutCount)
		{
			ShortcutParseList(ModelShortcutDefault(a), defaults);
			let keys = mModelShortcuts[a];
			bool same = defaults.Count == keys.Count;
			for (int i < keys.Count)
				same &= same && defaults[i] == keys[i];
			if (same)
				continue;
			ModelShortcutKey(a, id..Clear());
			output.AppendF("{}={}\n", id, mModelShortcutText[a]);
		}
		File.WriteAllText(ModelShortcutsFile(.. scope .()), output).IgnoreError();
	}

	/// The keys of an action, for labels ("" when it has none).
	StringView ModelShortcutText(int action)
	{
		EnsureModelShortcuts();
		return mModelShortcutText[action];
	}

	/// The keys of a command, for menus: its shortcuts, or how it is reached with the mouse ("Alt+click").
	StringView ModelKeys(ModelCommand command)
	{
		let text = ModelShortcutText(ModelCommandShortcut(command));
		if (!text.IsEmpty)
			return text;
		for (let entry in sModelCommands)
		{
			if (entry.command == command && (entry.keys == "Alt+click" || entry.keys == "G G"))
				return entry.keys;
		}
		return "";
	}

	List<String> mModelLabels = new .() ~ DeleteContainerAndItems!(_);
	int mModelLabelFrame = -1;

	/// A button's label with the action's first key: "Bevel (Ctrl+B)", the same ImGui id whatever the key. Kept
	/// for the frame.
	char8* ModelLabel(StringView name, int action)
	{
		if (mModelLabelFrame != Time.FrameCount)
		{
			mModelLabelFrame = Time.FrameCount;
			ClearAndDeleteItems!(mModelLabels);
		}
		EnsureModelShortcuts();
		let label = new String(name);
		if (!mModelShortcuts[action].IsEmpty)
		{
			label.Append(" (");
			ShortcutChordName(mModelShortcuts[action][0], label);
			label.Append(')');
		}
		label.AppendF("###{}", name);
		mModelLabels.Add(label);
		return label.CStr();
	}

	/// The modifiers held now, as a chord's.
	static int32 HeldModifiers()
	{
		int32 mods = 0;
		if (ImGui.IsKeyDown(ImGui.Key.LeftCtrl) || ImGui.IsKeyDown(531))
			mods |= ChordCtrl;
		if (ImGui.IsKeyDown(ImGui.Key.LeftShift) || ImGui.IsKeyDown(532))
			mods |= ChordShift;
		if (ImGui.IsKeyDown(ImGui.Key.LeftAlt) || ImGui.IsKeyDown(533))
			mods |= ChordAlt;
		return mods;
	}

	/// Whether one of an action's chords was pressed this frame.
	bool ModelShortcutPressed(int action)
	{
		EnsureModelShortcuts();
		let mods = HeldModifiers();
		for (let chord in mModelShortcuts[action])
		{
			if ((chord & ~ChordKey) == mods && ImGui.IsKeyPressed(chord & ChordKey))
				return true;
		}
		return false;
	}

	/// The action whose shortcut was pressed this frame (-1: none); of two on one key, the one the mode allows.
	int PressedModelShortcut()
	{
		int found = -1;
		for (int a < ModelShortcutCount)
		{
			if (a == ShortcutEditMode || !ModelShortcutPressed(a))
				continue;
			if (found < 0 || (!ModelShortcutApplies(found) && ModelShortcutApplies(a)))
				found = a;
		}
		return found;
	}

	bool ModelShortcutApplies(int action)
	{
		if (action < ShortcutCommands)
			return true;
		let command = (ModelCommand)(action - ShortcutCommands);
		for (let entry in sModelCommands)
		{
			if (entry.command == command)
				return ModelCommandApplies(entry.modes);
		}
		return true;
	}

	/// Edit > Preferences > Modelling: every action with its keys. Click a key to change it (press the new one,
	/// Esc to cancel), + adds another, x takes one away.
	void DrawModelShortcutsPage()
	{
		EnsureModelShortcuts();
		ImGui.SeparatorText("Modelling shortcuts");
		ImGui.TextDisabled("Used over the Scene view while editing a model. Click a key to change it, then press the new one\n(with Ctrl, Shift or Alt). Esc cancels; + adds another key; x removes one.");
		ImGui.SetNextItemWidth(-130);
		ImGui.InputText("##shortcutfilter", mShortcutFilter, 0, "Find...");
		ImGui.SameLine();
		if (ImGui.Button("Reset All", .(-1, 0)))
		{
			for (int a < ModelShortcutCount)
				ShortcutParseList(ModelShortcutDefault(a), mModelShortcuts[a]);
			mShortcutCapture = -1;
			RefreshModelShortcutText();
			SaveModelShortcuts();
		}
		// Waiting for a key: the first one pressed (not a modifier alone) with the modifiers held.
		if (mShortcutCapture >= 0)
		{
			if (ImGui.IsKeyPressed(ImGui.Key.Escape))
				mShortcutCapture = -1;
			else
			{
				for (int32 key = 512; key <= 627; key++)
				{
					if (key >= 527 && key <= 535)
						continue;
					if (!ImGui.IsKeyPressed(key))
						continue;
					let name = ShortcutKeyName(key, .. scope .());
					if (name.IsEmpty)
						continue;
					let action = mShortcutCapture / 16;
					let slot = mShortcutCapture % 16;
					let chord = HeldModifiers() | key;
					let keys = mModelShortcuts[action];
					if (slot < keys.Count)
						keys[slot] = chord;
					else if (!keys.Contains(chord))
						keys.Add(chord);
					mShortcutCapture = -1;
					RefreshModelShortcutText();
					SaveModelShortcuts();
					break;
				}
			}
		}
		if (!ImGui.BeginChild("##shortcuts", .(0, 0)))
		{
			ImGui.EndChild();
			return;
		}
		let name = scope String();
		let chordName = scope String();
		let conflicts = scope List<int>();
		StringView[?] groups = .("Modes and menus", "Transform", "Build", "Change", "Shading and marks", "Select", "Show", "Model", "Options");
		for (let group in groups)
		{
			bool header = false;
			for (int a < ModelShortcutCount)
			{
				if (ModelShortcutGroup(a) != group)
					continue;
				ModelShortcutName(a, name..Clear());
				if (!mShortcutFilter.IsEmpty && !name.Contains(mShortcutFilter, true) && !mModelShortcutText[a].Contains(mShortcutFilter, true))
					continue;
				if (!header)
				{
					ImGui.SeparatorText(scope String(group).CStr());
					header = true;
				}
				ImGui.PushID((int32)a);
				ImGui.AlignTextToFramePadding();
				ImGui.Text(name);
				ImGui.SameLine(240);
				let keys = mModelShortcuts[a];
				int remove = -1;
				for (int k < keys.Count)
				{
					ImGui.PushID((int32)k);
					let capturing = mShortcutCapture == a * 16 + k;
					ShortcutChordName(keys[k], chordName..Clear());
					// Another action on the same key, where both could run at once.
					conflicts.Clear();
					for (int other < ModelShortcutCount)
					{
						if (other != a && mModelShortcuts[other].Contains(keys[k]) && ModelShortcutGroup(other) != "" && !SharedModelKey(a, other))
							conflicts.Add(other);
					}
					if (capturing)
						ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
					else if (!conflicts.IsEmpty)
						ImGui.PushStyleColor(ImGui.Col.Button, Color.Lerp(ImGui.GetStyleColor(ImGui.Col.Button), EditorTheme.Warning, 0.6f));
					if (ImGui.Button(capturing ? "Press a key..." : chordName.CStr()))
						mShortcutCapture = capturing ? -1 : a * 16 + k;
					if (capturing || !conflicts.IsEmpty)
						ImGui.PopStyleColor();
					if (!conflicts.IsEmpty && ImGui.IsItemHovered())
					{
						let tip = scope String("Also used by: ");
						for (int c < conflicts.Count)
						{
							if (c > 0)
								tip.Append(", ");
							ModelShortcutName(conflicts[c], tip);
						}
						ImGui.SetTooltip(tip);
					}
					ImGui.SameLine(0, 1);
					if (ImGui.SmallButton("x"))
						remove = k;
					ImGui.SameLine();
					ImGui.PopID();
				}
				let adding = mShortcutCapture == a * 16 + keys.Count;
				if (keys.Count < 15)
				{
					if (adding)
						ImGui.PushStyleColor(ImGui.Col.Button, EditorTheme.Accent);
					if (ImGui.Button(adding ? "Press a key..." : "+"))
						mShortcutCapture = adding ? -1 : a * 16 + keys.Count;
					if (adding)
						ImGui.PopStyleColor();
					if (!adding && ImGui.IsItemHovered())
						ImGui.SetTooltip("Add a key");
				}
				if (remove >= 0)
				{
					keys.RemoveAt(remove);
					mShortcutCapture = -1;
					RefreshModelShortcutText();
					SaveModelShortcuts();
				}
				ImGui.PopID();
			}
		}
		ImGui.EndChild();
	}

	/// Two actions that may share a key because they never apply at once (M: merge vertices, collapse edges).
	static bool SharedModelKey(int a, int b)
	{
		if (a < ShortcutCommands || b < ShortcutCommands)
			return false;
		int32 modesA = 0, modesB = 0;
		for (let entry in sModelCommands)
		{
			if ((int)entry.command == a - ShortcutCommands)
				modesA = entry.modes;
			if ((int)entry.command == b - ShortcutCommands)
				modesB = entry.modes;
		}
		return (modesA & modesB) == 0;
	}
}
