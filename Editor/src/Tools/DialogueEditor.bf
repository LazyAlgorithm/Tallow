using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Dialogue tab: edits a `.tdialogue` file. Nodes and speakers on the left, the selected node's steps in the
/// middle (each a line, an answer, a variable change, an event, a jump or an end, with an optional condition), and a
/// preview on the right that plays the conversation from the selected node, with the variables it changes.
extension EditorApp
{
	DialogueAsset mDialogue ~ delete _;
	String mDialoguePath = new .() ~ delete _;
	String mDialogueRelative = new .() ~ delete _;
	int32 mDialogueNode;
	bool mShowDialogue;
	bool mDockDialogue;
	bool mDialogueFocus;
	// Frame after which the tab takes focus; opening from the command line waits for the layout to settle.
	int64 mDialogueFocusAfter = 5;
	bool mDialogueDirty;
	String mDialogueNewNode = new .() ~ delete _;
	DialogueConversation mDialoguePreview ~ delete _;
	List<String> mDialoguePreviewEvents = new .() ~ DeleteContainerAndItems!(_);

	static readonly StringView[?] DialogueKinds = .("Say", "Choice", "Set", "Add", "Event", "Goto", "End");

	/// Opens a dialogue file (a full path) in the Dialogue tab, saving the one open before.
	void OpenDialogue(StringView path)
	{
		if (mDialogue != null && mDialogueDirty)
			SaveDialogue();
		delete mDialogue;
		mDialogue = new DialogueAsset();
		mDialoguePath.Set(path);
		mDialogueRelative.Clear();
		Assets.MakeRelative(path, mDialogueRelative);
		mDialogue.path.Set(mDialogueRelative);
		let text = scope String();
		if (File.ReadAllText(path, text, true) case .Ok)
			mDialogue.Parse(text);
		mDialogueNode = 0;
		mDialogueDirty = false;
		mShowDialogue = true;
		mDockDialogue = true;
		mDialogueFocus = true;
		DeleteAndNullify!(mDialoguePreview);
	}

	void SaveDialogue()
	{
		if (mDialogue == null)
			return;
		let text = scope String();
		mDialogue.Write(text);
		if (File.WriteAllText(mDialoguePath, text) case .Err)
		{
			Log.Error(scope $"{mDialoguePath} could not be written.");
			return;
		}
		// Read again, so its problems are up to date and running games use the new text.
		mDialogue.Parse(text);
		DialogueAsset.Forget(mDialogueRelative);
		mDialogueDirty = false;
	}

	/// What a new dialogue file holds: a speaker and a short conversation to change.
	public static void NewDialogueText(String text)
	{
		text.Append("""
			speaker npc "Stranger"

			node start
				say npc "Hello there."
				choice "Hello." greet
				choice "Goodbye."
				end

			node greet
				say npc "Nice to meet you."
				event Greeted

			""");
	}

	void DrawDialogue()
	{
		if (!mShowDialogue)
			return;
		if (mDockDialogue && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockDialogue = false;
		}
		if (mDialogueFocus && Time.FrameCount > mDialogueFocusAfter)
		{
			ImGui.SetNextWindowFocus();
			mDialogueFocus = false;
		}
		let visible = ImGui.Begin("Dialogue", &mShowDialogue);
		if (visible && mDialogue == null)
			ImGui.TextDisabled("Create a dialogue with Project > + > Dialogue, or double-click a .tdialogue file.");
		else if (visible)
		{
			DrawDialogueToolbar();
			let height = ImGui.GetContentRegionAvail().y;
			ImGui.BeginChild("nodes", .(230, height), 1);
			DrawDialogueNodes();
			ImGui.EndChild();
			ImGui.SameLine();
			let previewWidth = 300.0f;
			ImGui.BeginChild("steps", .(Math.Max(ImGui.GetContentRegionAvail().x - previewWidth - 8, 200), height), 1);
			DrawDialogueSteps();
			ImGui.EndChild();
			ImGui.SameLine();
			ImGui.BeginChild("preview", .(0, height), 1);
			DrawDialoguePreview();
			ImGui.EndChild();
		}
		ImGui.End();
		if (!mShowDialogue && mDialogueDirty)
			SaveDialogue();
	}

	void DrawDialogueToolbar()
	{
		if (ImGui.SmallButton("Save"))
			SaveDialogue();
		ImGui.SameLine();
		if (ImGui.SmallButton("Reload") && !mDialoguePath.IsEmpty)
		{
			mDialogueDirty = false;
			OpenDialogue(scope String(mDialoguePath));
		}
		ImGui.SameLine(0, 14);
		ImGui.TextDisabled(scope String()..AppendF("{}{}", mDialogueRelative, mDialogueDirty ? " *" : "").CStr());
		if (!mDialogue.problems.IsEmpty)
		{
			ImGui.SameLine(0, 14);
			ImGui.TextColored(EditorTheme.Warning, "Problems (hover)");
			if (ImGui.IsItemHovered())
				ImGui.SetTooltip(mDialogue.problems.CStr());
		}
	}

	void DrawDialogueNodes()
	{
		ImGui.SeparatorText("Nodes");
		for (int32 i < (int32)mDialogue.nodes.Count)
		{
			let node = mDialogue.nodes[i];
			ImGui.PushID(i);
			if (ImGui.Selectable(scope String()..AppendF("{}  ({})", node.name, node.steps.Count).CStr(), i == mDialogueNode))
				mDialogueNode = i;
			if (ImGui.BeginPopupContextItem("node"))
			{
				ImGui.SetNextItemWidth(160);
				if (ImGui.InputText("Name", node.name))
					mDialogueDirty = true;
				if (ImGui.MenuItem("Move Up", null, false, i > 0))
				{
					Swap!(mDialogue.nodes[i], mDialogue.nodes[i - 1]);
					mDialogueNode = i - 1;
					mDialogueDirty = true;
				}
				if (ImGui.MenuItem("Delete Node"))
				{
					delete mDialogue.nodes[i];
					mDialogue.nodes.RemoveAt(i);
					mDialogueNode = Math.Max(0, Math.Min(mDialogueNode, (int32)mDialogue.nodes.Count - 1));
					mDialogueDirty = true;
					ImGui.EndPopup();
					ImGui.PopID();
					break;
				}
				ImGui.EndPopup();
			}
			ImGui.PopID();
		}
		ImGui.SetNextItemWidth(-60);
		ImGui.InputText("##newnode", mDialogueNewNode, 0, "new node name");
		ImGui.SameLine();
		if (ImGui.Button("Add") && !mDialogueNewNode.IsEmpty && !mDialogueNewNode.Contains(' ') && mDialogue.FindNode(mDialogueNewNode) == null)
		{
			let node = new DialogueNode();
			node.name.Set(mDialogueNewNode);
			mDialogue.nodes.Add(node);
			mDialogueNode = (int32)mDialogue.nodes.Count - 1;
			mDialogueNewNode.Clear();
			mDialogueDirty = true;
		}
		ImGui.TextDisabled("Right-click a node to rename or delete it.");

		ImGui.SeparatorText("Speakers");
		for (int32 i < (int32)mDialogue.speakers.Count)
		{
			let speaker = mDialogue.speakers[i];
			ImGui.PushID(1000 + i);
			ImGui.SetNextItemWidth(70);
			mDialogueDirty |= ImGui.InputText("##id", speaker.id, 0, "id");
			ImGui.SameLine();
			ImGui.SetNextItemWidth(-56);
			mDialogueDirty |= ImGui.InputText("##name", speaker.name, 0, "shown name");
			ImGui.SameLine();
			mDialogueDirty |= ImGui.ColorEdit3("##color", ref speaker.color, ImGui.ColorFlags.NoInputs);
			ImGui.SameLine();
			bool remove = ImGui.SmallButton("x");
			ImGui.SetNextItemWidth(-1);
			mDialogueDirty |= ImGui.InputText("##object", speaker.objectName, 0, "voice from object (optional)");
			ImGui.PopID();
			if (remove)
			{
				delete speaker;
				mDialogue.speakers.RemoveAt(i);
				mDialogueDirty = true;
				break;
			}
		}
		if (ImGui.Button("Add Speaker"))
		{
			let speaker = new DialogueSpeaker();
			speaker.id.AppendF("speaker{}", mDialogue.speakers.Count + 1);
			speaker.name.Set("Someone");
			mDialogue.speakers.Add(speaker);
			mDialogueDirty = true;
		}
	}

	/// A drop-down of the dialogue's nodes; none (empty) is offered when allowNone, with that label.
	bool DialogueNodeCombo(char8* label, String target, char8* noneLabel)
	{
		bool changed = false;
		if (ImGui.BeginCombo(label, target.IsEmpty ? noneLabel : target.CStr()))
		{
			if (noneLabel != null && ImGui.Selectable(noneLabel, target.IsEmpty))
			{
				target.Clear();
				changed = true;
			}
			for (let node in mDialogue.nodes)
			{
				if (ImGui.Selectable(node.name.CStr(), node.name == target))
				{
					target.Set(node.name);
					changed = true;
				}
			}
			ImGui.EndCombo();
		}
		return changed;
	}

	void DrawDialogueSteps()
	{
		if (mDialogueNode < 0 || mDialogueNode >= mDialogue.nodes.Count)
		{
			ImGui.TextDisabled("Add a node on the left.");
			return;
		}
		let node = mDialogue.nodes[mDialogueNode];
		ImGui.SeparatorText(scope String()..AppendF("node {}", node.name).CStr());
		int32 removeAt = -1, moveUp = -1;
		for (int32 i < (int32)node.steps.Count)
		{
			let step = node.steps[i];
			ImGui.PushID(i);
			ImGui.SetNextItemWidth(84);
			if (ImGui.BeginCombo("##kind", scope String(DialogueKinds[(int)step.kind]).CStr()))
			{
				for (int32 k < DialogueKinds.Count)
				{
					if (ImGui.Selectable(scope String(DialogueKinds[k]).CStr(), (int32)step.kind == k))
					{
						step.kind = (DialogueStepKind)k;
						mDialogueDirty = true;
					}
				}
				ImGui.EndCombo();
			}
			ImGui.SameLine();
			DrawDialogueStepFields(step);
			ImGui.SetNextItemWidth(-70);
			mDialogueDirty |= ImGui.InputText("##if", step.condition, 0, "only if... (e.g. gold >= 10)");
			ImGui.SameLine();
			if (ImGui.SmallButton("^") && i > 0)
				moveUp = i;
			ImGui.SameLine();
			if (ImGui.SmallButton("x"))
				removeAt = i;
			ImGui.Separator();
			ImGui.PopID();
		}
		if (moveUp > 0)
		{
			Swap!(node.steps[moveUp], node.steps[moveUp - 1]);
			mDialogueDirty = true;
		}
		if (removeAt >= 0)
		{
			delete node.steps[removeAt];
			node.steps.RemoveAt(removeAt);
			mDialogueDirty = true;
		}
		if (ImGui.Button("Add Step"))
			ImGui.OpenPopup("addstep");
		if (ImGui.BeginPopup("addstep"))
		{
			for (int32 k < DialogueKinds.Count)
			{
				if (ImGui.MenuItem(scope String(DialogueKinds[k]).CStr()))
				{
					let step = new DialogueStep();
					step.kind = (DialogueStepKind)k;
					if (step.kind == .Say && !mDialogue.speakers.IsEmpty)
						step.speaker.Set(mDialogue.speakers[0].id);
					node.steps.Add(step);
					mDialogueDirty = true;
				}
			}
			ImGui.EndPopup();
		}
	}

	void DrawDialogueStepFields(DialogueStep step)
	{
		switch (step.kind)
		{
		case .Say:
			ImGui.SetNextItemWidth(130);
			let speaker = mDialogue.FindSpeaker(step.speaker);
			if (ImGui.BeginCombo("##speaker", step.speaker.IsEmpty ? "(narrator)" : (speaker != null ? speaker.name.CStr() : step.speaker.CStr())))
			{
				if (ImGui.Selectable("(narrator)", step.speaker.IsEmpty))
				{
					step.speaker.Clear();
					mDialogueDirty = true;
				}
				for (let option in mDialogue.speakers)
				{
					if (ImGui.Selectable(option.name.CStr(), option.id == step.speaker))
					{
						step.speaker.Set(option.id);
						mDialogueDirty = true;
					}
				}
				ImGui.EndCombo();
			}
			ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			mDialogueDirty |= ImGui.DragFloat("##time", ref step.time, 0.1f, 0, 60, step.time > 0 ? "%.1f s" : "auto time");
			mDialogueDirty |= ImGui.InputTextMultiline("##text", step.text, .(-1, ImGui.GetFontSize() * 3.2f));
			ImGui.TextDisabled("Voice");
			ImGui.SameLine();
			mDialogueDirty |= DrawAssetPicker(step.audio, "audioClip");
		case .Choice:
			ImGui.SetNextItemWidth(-170);
			mDialogueDirty |= ImGui.InputText("##text", step.text, 0, "the answer");
			ImGui.SameLine();
			ImGui.SetNextItemWidth(160);
			mDialogueDirty |= DialogueNodeCombo("##target", step.target, "(carry on)");
		case .Set,.Add:
			ImGui.SetNextItemWidth(160);
			mDialogueDirty |= ImGui.InputText("##variable", step.target, 0, "variable");
			ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			mDialogueDirty |= ImGui.DragFloat("##value", ref step.value, 0.1f);
		case .Event:
			ImGui.SetNextItemWidth(160);
			mDialogueDirty |= ImGui.InputText("##event", step.target, 0, "event name");
			ImGui.SameLine();
			ImGui.SetNextItemWidth(90);
			mDialogueDirty |= ImGui.DragFloat("##value", ref step.value, 0.1f);
		case .Goto:
			ImGui.SetNextItemWidth(160);
			mDialogueDirty |= DialogueNodeCombo("##target", step.target, null);
		case .End:
			ImGui.TextDisabled("ends the conversation");
		}
	}

	void DrawDialoguePreview()
	{
		ImGui.SeparatorText("Preview");
		let nodeName = mDialogueNode >= 0 && mDialogueNode < mDialogue.nodes.Count ? (StringView)mDialogue.nodes[mDialogueNode].name : "";
		if (ImGui.Button(scope String()..AppendF("Play from {}", nodeName).CStr()) && !nodeName.IsEmpty)
		{
			delete mDialoguePreview;
			mDialoguePreview = new DialogueConversation();
			ClearAndDeleteItems(mDialoguePreviewEvents);
			mDialoguePreview.OnEvent.Add(new (name, value) => mDialoguePreviewEvents.Add(new $"event {name} {value}"));
			mDialoguePreview.Start(mDialogue, nodeName);
		}
		ImGui.SameLine();
		if (ImGui.Button("Clear Variables"))
			DialogueVariables.Clear();
		let preview = mDialoguePreview;
		if (preview != null)
		{
			ImGui.Spacing();
			switch (preview.View)
			{
			case .Line:
				let speaker = mDialogue.FindSpeaker(preview.Line.speaker);
				if (speaker != null)
					ImGui.TextColored(speaker.color, speaker.name.CStr());
				ImGui.TextWrapped(preview.Line.text.CStr());
				if (!preview.Line.audio.IsEmpty)
				{
					if (ImGui.SmallButton("Hear it"))
						Audio.PlayOneShot2D(preview.Line.audio, 1, .Voice);
				}
				if (ImGui.Button("Next"))
					preview.Advance();
			case .Choices:
				for (int i < preview.Choices.Count)
				{
					ImGui.PushID((int32)i);
					if (ImGui.Button(scope String()..AppendF("{}. {}", i + 1, preview.Choices[i].text).CStr(), .(-1, 0)))
					{
						preview.Choose(i);
						ImGui.PopID();
						break;
					}
					ImGui.PopID();
				}
			case .Ended,.None:
				ImGui.TextDisabled("(the conversation has ended)");
			}
			for (let event in mDialoguePreviewEvents)
				ImGui.TextDisabled(event.CStr());
		}
		ImGui.SeparatorText("Variables");
		if (DialogueVariables.All.IsEmpty)
			ImGui.TextDisabled("none set yet");
		let text = scope String();
		DialogueVariables.ToText(text);
		for (let line in text.Split('\n', .RemoveEmptyEntries))
			ImGui.Text(line);
	}

	/// Under a Dialogue Runner: open its file, pick its start node and, while playing, move its conversation on.
	void DrawDialogueRunnerTools(DialogueRunner runner)
	{
		let asset = runner.dialogue.IsEmpty ? null : DialogueAsset.Load(runner.dialogue);
		if (asset == null)
		{
			ImGui.TextDisabled("Pick a .tdialogue file (Project > + > Dialogue makes one).");
			return;
		}
		if (ImGui.Button("Edit Dialogue"))
		{
			let full = scope String();
			Assets.ResolvePath(runner.dialogue, full);
			OpenDialogue(full);
		}
		ImGui.SameLine();
		ImGui.SetNextItemWidth(-1);
		if (ImGui.BeginCombo("##start", scope String()..AppendF("Start at {}", runner.startNode).CStr()))
		{
			for (let node in asset.nodes)
			{
				if (ImGui.Selectable(node.name.CStr(), node.name == runner.startNode))
				{
					runner.startNode.Set(node.name);
					MarkDirty();
				}
			}
			ImGui.EndCombo();
		}
		if (!asset.problems.IsEmpty)
			ImGui.TextColored(EditorTheme.Warning, asset.problems.CStr());
		if (mPlay == .Edit)
			return;
		switch (runner.View)
		{
		case .Line:
			ImGui.TextWrapped(scope String()..AppendF("{}: {}", runner.Speaker?.name ?? "", runner.Line.text).CStr());
			if (ImGui.Button("Next"))
				runner.Advance();
		case .Choices:
			for (int i < runner.Choices.Count)
			{
				ImGui.PushID((int32)i);
				if (ImGui.Button(runner.Choices[i].text.CStr()))
					runner.Choose(i);
				ImGui.PopID();
			}
		default:
			if (ImGui.Button("Play"))
				runner.Play();
		}
		if (runner.IsPlaying)
		{
			ImGui.SameLine();
			if (ImGui.Button("Stop"))
				runner.Stop();
		}
	}
}
