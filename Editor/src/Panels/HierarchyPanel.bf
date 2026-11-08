using System;
using System.Collections;
using System.IO;
using Tallow;
using Bgfx;

namespace Tallow.Editor;

/// The Hierarchy panel.
extension EditorApp
{
	// The row pressed with the left button, selected when the button is let go over it (0: none, or it became a drag).
	uint32 mHierarchyPressed;
	uint32 mHierarchyDoubleClicked;
	uint32 mHierarchyRenaming;
	String mHierarchyRenameText = new .() ~ delete _;
	bool mHierarchyRenameFocus;

	void BeginHierarchyRename(GameObject gameObject)
	{
		if (gameObject == null || mPlay != .Edit)
			return;
		mHierarchyRenaming = gameObject.Id;
		mHierarchyRenameText.Set(gameObject.Name);
		mHierarchyRenameFocus = true;
	}

	void FinishHierarchyRename(bool commit)
	{
		let gameObject = mScene.FindById(mHierarchyRenaming);
		if (commit && gameObject != null && !mHierarchyRenameText.IsEmpty &&
			gameObject.Name != mHierarchyRenameText)
		{
			gameObject.Name.Set(mHierarchyRenameText);
			if (mInspectorLock == gameObject.Id)
				mInspectorLockName.Set(gameObject.Name);
			MarkDirty();
		}
		mHierarchyRenaming = 0;
		mHierarchyRenameFocus = false;
	}

	void DrawHierarchy()
	{
		if (ImGui.Begin("Hierarchy"))
		{
			DrawPrefabBar();
			if (ImGui.Button("+"))
				ImGui.OpenPopup("CreateObject");
			if (ImGui.BeginPopup("CreateObject"))
			{
				DrawCreateMenu();
				ImGui.EndPopup();
			}
			ImGui.SameLine();
			ImGui.SetNextItemWidth(-1);
			ImGui.InputText("##search", mHierarchySearch, 0, "Search");
			ImGui.Separator();

			ImGui.BeginChild("tree");
			// The eyes and locks have a column of their own at the left (SceneVisibility.bf).
			let gutterLeft = ImGui.GetCursorScreenPos().x;
			mHierarchyGutter = gutterLeft;
			ImGui.Indent(VisibilityGutterWidth);
			let sceneLabel = scope String();
			sceneLabel.AppendF("{}{}", mScene.Name, mDirty ? "*" : "");
			if (ImGui.TreeNode(sceneLabel.CStr(), ImGui.TreeFlags.DefaultOpen | ImGui.TreeFlags.SpanAvailWidth))
			{
				for (int i = 0; i < mScene.Roots.Count; i++)
					DrawHierarchyNode(mScene.Roots[i]);
				ImGui.TreePop();
			}
			// Empty space: click to deselect, drop to un-parent, right click to create.
			ImGui.Unindent(VisibilityGutterWidth);
			EndVisibilityDrag();
			let avail = ImGui.GetContentRegionAvail();
			ImGui.InvisibleButton("##empty", .(Math.Max(avail.x, 1), Math.Max(avail.y, 40)));
			if (ImGui.IsItemClicked(0) && !OverVisibilityGutter(gutterLeft))
				mSelectedId = 0;
			if (ImGui.BeginDragDropTarget())
			{
				let payload = ImGui.AcceptDragDropPayload("GAMEOBJECT");
				if (payload != null)
				{
					let dragged = mScene.FindById(*(uint32*)payload.data);
					if (dragged != null)
					{
						dragged.Transform.SetParent(null);
						MarkDirty();
					}
				}
				let asset = ImGui.AcceptDragDropPayload("ASSET");
				if (asset != null)
				{
					mSelectedId = 0;
					DropAssetIntoScene(StringView((char8*)asset.data, asset.dataSize), false, 0.5f, 0.5f);
				}
				ImGui.EndDragDropTarget();
			}
			if (ImGui.BeginPopupContextItem("HierarchyContext"))
			{
				DrawCreateMenu();
				ImGui.EndPopup();
			}
			ImGui.EndChild();
		}
		ImGui.End();
	}

	void DrawHierarchyNode(GameObject gameObject)
	{
		if (gameObject.Transient || gameObject.IsDestroyed)
			return;
		int visibleChildren = 0;
		for (let child in gameObject.Transform.Children)
		{
			if (!child.GameObject.Transient)
				visibleChildren++;
		}
		if (!mHierarchySearch.IsEmpty && visibleChildren == 0 && !gameObject.Name.Contains(mHierarchySearch, true))
			return;

		var flags = ImGui.TreeFlags.OpenOnArrow | ImGui.TreeFlags.SpanAvailWidth | ImGui.TreeFlags.OpenOnDoubleClick;
		if (visibleChildren == 0)
			flags |= ImGui.TreeFlags.Leaf;
		if (gameObject.Id == mSelectedId)
			flags |= ImGui.TreeFlags.Selected;
		let inactive = !gameObject.ActiveInHierarchy;
		if (inactive)
			ImGui.PushStyleColor(ImGui.Col.Text, EditorTheme.TextDim);
		ImGui.PushID((int32)gameObject.Id);
		DrawVisibilityButtons(gameObject, mHierarchyGutter);
		let nodeLabel = scope String();
		nodeLabel.AppendF("{}  {}###node", StringView(ObjectIcon(gameObject)), gameObject.Name.IsEmpty ? "(unnamed)" : (StringView)gameObject.Name);
		if (gameObject.IsFolder && !inactive)
			ImGui.PushStyleColor(ImGui.Col.Text, Icons.FolderColor);
		let open = ImGui.TreeNode(nodeLabel.CStr(), flags);
		NoteTestRect(scope $"row:{gameObject.Id}");
		if (inactive || gameObject.IsFolder)
			ImGui.PopStyleColor();
		// Selected when the click is let go, not when it is pressed: dragging the row (into an Inspector field, or onto
		// another object) leaves the selection, and so the Inspector, as it was.
		if (ImGui.IsItemClicked(0) && !ImGui.IsItemToggledOpen() && mVisibilityDrag == .None)
			mHierarchyPressed = gameObject.Id;
		if (ImGui.IsItemHovered() && ImGui.IsMouseDoubleClicked(0))
		{
			mHierarchyDoubleClicked = gameObject.Id;
			mSelectedId = gameObject.Id;
			FocusSelected();
		}
		if (mHierarchyPressed == gameObject.Id && ImGui.IsMouseReleased(0))
		{
			if (ImGui.IsItemHovered())
			{
				let alreadySelected = mSelectedId == gameObject.Id;
				mSelectedId = gameObject.Id;
				// A second deliberate click renames the selected item; a
				// double-click still frames it, and a drag never starts editing.
				if (alreadySelected && mHierarchyDoubleClicked != gameObject.Id)
					BeginHierarchyRename(gameObject);
			}
			mHierarchyPressed = 0;
			mHierarchyDoubleClicked = 0;
		}
		if (gameObject.Id == mSelectedId && mHierarchyRenaming == 0 &&
			ImGui.IsWindowFocused() && ImGui.IsKeyPressed(ImGui.Key.F2))
			BeginHierarchyRename(gameObject);
		if (ImGui.BeginPopupContextItem())
		{
			mSelectedId = gameObject.Id;
			if (ImGui.MenuItem("Rename", "F2"))
				BeginHierarchyRename(gameObject);
			if (ImGui.MenuItem("Duplicate"))
				DuplicateSelected();
			if (ImGui.MenuItem("Delete"))
				DeleteSelected();
			if (ImGui.MenuItem("Frame in Scene"))
				FocusSelected();
			if (ImGui.MenuItem("Save as Prefab"))
				SaveSelectedAsPrefab();
			ImGui.Separator();
			DrawCreateMenu();
			ImGui.EndPopup();
		}
		if (mHierarchyRenaming != gameObject.Id && ImGui.BeginDragDropSource())
		{
			mHierarchyPressed = 0;
			var id = gameObject.Id;
			ImGui.SetDragDropPayload("GAMEOBJECT", &id, sizeof(uint32));
			ImGui.Text(gameObject.Name);
			ImGui.EndDragDropSource();
		}
		if (ImGui.BeginDragDropTarget())
		{
			let payload = ImGui.AcceptDragDropPayload("GAMEOBJECT");
			if (payload != null)
			{
				let dragged = mScene.FindById(*(uint32*)payload.data);
				if (dragged != null && dragged != gameObject)
				{
					dragged.Transform.SetParent(gameObject.Transform);
					MarkDirty();
				}
			}
			ImGui.EndDragDropTarget();
		}
		if (mHierarchyRenaming == gameObject.Id)
		{
			// Overlay the label, retaining the TreeNode's expand/collapse
			// affordance and its stable row rectangle for dragging.
			let afterRow = ImGui.GetCursorScreenPos();
			let row = ImGui.GetItemRectMin();
			ImGui.SetCursorScreenPos(.(row.x + 30, row.y));
			ImGui.SetNextItemWidth(Math.Max(ImGui.GetContentRegionAvail().x - 6, 90));
			if (mHierarchyRenameFocus)
			{
				ImGui.SetKeyboardFocusHere();
				mHierarchyRenameFocus = false;
			}
			let confirmed = ImGui.InputText("##hierarchyrename", mHierarchyRenameText, ImGui.InputFlags.EnterReturnsTrue);
			let cancelled = ImGui.IsKeyPressed(ImGui.Key.Escape);
			let finished = ImGui.IsItemDeactivated();
			ImGui.SetCursorScreenPos(afterRow);
			if (confirmed || cancelled || finished)
				FinishHierarchyRename(!cancelled);
		}
		if (open)
		{
			for (int i = 0; i < gameObject.Transform.Children.Count; i++)
				DrawHierarchyNode(gameObject.Transform.Children[i].GameObject);
			ImGui.TreePop();
		}
		ImGui.PopID();
	}
}
