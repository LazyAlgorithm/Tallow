using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Behavior tab: a canvas for behaviour trees (.tbt files), drawn with the same nodes, links and controls as
/// the Graph tab. Flow runs downward: a node's parent connects to its top, its children to its bottom, and
/// children run left to right.
///   Right-click the canvas to add a node (type to search), drag from the dot under a node to another node to make
///   it a child, Alt+click a dot to disconnect, Delete removes the selected node, middle-drag pans, the wheel zooms.
/// While the game plays, the tree of the selected object (or the first object using this tree) is shown live:
/// amber is running, green succeeded, red failed, and nodes that have not run lately fade.
extension EditorApp
{
	[CLink] static extern void ImDrawList_AddCircleFilled(void* list, ImGui.Vec2 center, float radius, uint32 color, int32 segments);

	const float TreeNodeWidth = 200;
	const float TreeHeader = 26;
	const float TreeRow = 20;

	BehaviorTreeData mTree ~ delete _;
	String mTreePath = new .() ~ delete _;
	String mTreeStatus = new .() ~ delete _;
	String mPendingTree = new .() ~ delete _;
	Vector2 mTreePan = .(360, 50);
	float mTreeZoom = 1.0f;
	int32 mTreeSelected;
	int32 mTreeDragNode;
	bool mShowBehavior;
	bool mDockBehavior;
	bool mTreeFocus;
	// Frame after which the tab takes focus; opening from the command line waits until play mode has claimed its own.
	int64 mTreeFocusAfter = 5;
	// Keep the whole tree in view as the tab is resized, until the user pans, zooms or moves a node.
	bool mTreeFit;
	ImGui.Vec2 mTreeFitSize;
	// Link being dragged out of a pin: from a node's bottom (it will be the parent) or its top (it will be the child).
	bool mTreeLinking;
	int32 mTreeLinkNode;
	bool mTreeLinkFromBottom;
	Vector2 mTreeNewPosition;
	String mTreeSearch = new .() ~ delete _;
	bool mOpenTreeSearch;
	bool mTreeSearchFocus;
	bool mTreeSearchForLink;

	void OpenBehavior(StringView path)
	{
		mShowBehavior = true;
		mDockBehavior = true;
		delete mTree;
		mTree = new BehaviorTreeData();
		mTreePath.Set(path);
		mTree.name.Clear();
		Path.GetFileNameWithoutExtension(path, mTree.name);
		mTree.Load(path);
		mTreeSelected = 0;
		mTreeStatus.Clear();
		mTreeFocus = true;
		mTreeFit = true;
		mTreeFitSize = default;
	}

	/// Pans and zooms so every node is on screen, never zooming in past full size.
	void FitTree(ImGui.Vec2 size)
	{
		if (mTree.nodes.IsEmpty || size.x < 50 || size.y < 50)
			return;
		var min = Vector2(float.MaxValue, float.MaxValue);
		var max = Vector2(-float.MaxValue, -float.MaxValue);
		for (let node in mTree.nodes)
		{
			min = .(Math.Min(min.x, node.position.x), Math.Min(min.y, node.position.y));
			max = .(Math.Max(max.x, node.position.x + TreeNodeWidth), Math.Max(max.y, node.position.y + TreeNodeHeight(node)));
		}
		let margin = 40.0f;
		mTreeZoom = Mathf.Clamp(Math.Min((size.x - margin * 2) / Math.Max(max.x - min.x, 1), (size.y - margin * 2) / Math.Max(max.y - min.y, 1)), 0.25f, 1.0f);
		mTreePan = .((size.x - (max.x - min.x) * mTreeZoom) * 0.5f - min.x * mTreeZoom, margin - min.y * mTreeZoom);
	}

	void CreateBehaviorAsset(StringView name)
	{
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Behaviour tree names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.tbt";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		// Start with something that runs: chase a Player on sight, otherwise wander.
		let tree = scope BehaviorTreeData();
		tree.name.Set(name);
		BTNodeData Add(StringView key, float x, float y, int32 parent)
		{
			let node = tree.AddNode(BehaviorLibrary.Find(key), .(x, y));
			if (parent != 0)
				tree.Connect(parent, node.id);
			return node;
		}
		let root = Add("root", 0, 0, 0);
		let top = Add("reactive.selector", 0, 110, root.id);
		let chase = Add("reactive.sequence", -260, 240, top.id);
		Add("see", -390, 370, chase.id);
		Add("nav.target", -130, 370, chase.id);
		let idle = Add("sequence", 260, 240, top.id);
		Add("nav.wander", 130, 370, idle.id);
		let wait = Add("wait", 390, 370, idle.id);
		wait.values[1].Set("3");
		tree.Save(path);
		RefreshAssetList();
		OpenBehavior(path);
	}

	void SaveBehavior()
	{
		if (mTree == null)
			return;
		mTree.Save(mTreePath);
		BehaviorTreeAssets.Invalidate(mTreePath);
		// Running objects pick the change up straight away, which makes tuning a tree while playing practical.
		int reloaded = 0;
		if (mScene != null && mPlay != .Edit)
		{
			for (let handle in mScene.Components<BehaviorTreeRunner>(.. scope .()))
			{
				let runner = handle.Runtime;
				// Those running it as their tree or as a subtree.
				if (runner.UsesFile(mTreePath))
				{
					runner.Reload();
					reloaded++;
				}
			}
		}
		mTreeStatus.Set(mTree.Root == null ? "Saved. Add a Root node, or the tree will not run." : (reloaded > 0 ? scope $"Saved; reloaded on {reloaded} running object(s)." : "Saved."));
	}

	/// The runner to show live: the selected object's if it uses this tree, otherwise the first one that does.
	BehaviorTreeRunnerState WatchedRunner()
	{
		if (mScene == null || mPlay == .Edit || mTree == null)
			return null;
		bool Uses(BehaviorTreeRunnerState runner) => runner != null && runner.UsesFile(mTreePath);
		if (Selected != null && Selected.HasComponent<BehaviorTreeRunner>())
		{
			let selected = Selected.GetComponent<BehaviorTreeRunner>().Runtime;
			if (Uses(selected))
				return selected;
		}
		for (let handle in mScene.Components<BehaviorTreeRunner>(.. scope .()))
		{
			let runner = handle.Runtime;
			if (Uses(runner))
				return runner;
		}
		return null;
	}

	static float TreeNodeHeight(BTNodeData node) => TreeHeader + Math.Max(node.def.parameters.Count, 1) * TreeRow + 10;
	static Vector2 TreePin(BTNodeData node, bool bottom) => .(node.position.x + TreeNodeWidth * 0.5f, node.position.y + (bottom ? TreeNodeHeight(node) : 0));

	static Color TreeCategoryColor(BTNodeData node)
	{
		if (node.def.kind == .Root) return .(0.62f, 0.22f, 0.22f, 1);
		switch (node.def.category)
		{
		case "Flow": return .(0.40f, 0.40f, 0.44f, 1);
		case "Decorators": return .(0.50f, 0.34f, 0.66f, 1);
		case "Navigation": return .(0.20f, 0.42f, 0.66f, 1);
		case "Detection": return .(0.70f, 0.44f, 0.20f, 1);
		case "Blackboard": return .(0.22f, 0.50f, 0.48f, 1);
		case "Events": return .(0.62f, 0.30f, 0.50f, 1);
		default: return .(0.26f, 0.48f, 0.30f, 1);
		}
	}

	/// Colour for a node's live state, and how strongly to show it (0 = not at all).
	Color TreeStatusColor(BehaviorTreeRunnerState runner, int32 nodeId, out float strength, out StringView label)
	{
		strength = 0;
		label = "";
		if (runner == null)
			return default;
		// The open file may be the runner's tree or one it runs as a subtree.
		let last = runner.LastTickOf(mTreePath, nodeId);
		if (last < 0)
			return default;
		let age = runner.TickCount - last;
		// Fresh results are solid; older ones fade over about a second so a glance shows what happened recently.
		strength = age <= 1 ? 1.0f : Math.Max(0.22f, 1.0f - age / 60.0f);
		switch (runner.StatusOf(mTreePath, nodeId))
		{
		case .Running:
			label = "RUNNING";
			return .(1.0f, 0.72f, 0.20f, 1);
		case .Success:
			label = "SUCCESS";
			return .(0.35f, 0.85f, 0.45f, 1);
		case .Failure:
			label = "FAILED";
			return .(0.92f, 0.35f, 0.35f, 1);
		// Stopped part-way by a branch with higher priority.
		case .Idle:
			label = "STOPPED";
			strength *= 0.6f;
			return .(0.65f, 0.65f, 0.70f, 1);
		}
	}

	/// The node (and pin, 0 top or 1 bottom, if any) under the mouse.
	struct TreeHover
	{
		public BTNodeData node;
		public int pin;
	}

	void DrawBehavior()
	{
		if (!mShowBehavior && mPendingTree.IsEmpty)
			return;
		if (mDockBehavior && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockBehavior = false;
		}
		if (!mPendingTree.IsEmpty)
		{
			if (mTree != null)
				mTree.Save(mTreePath);
			OpenBehavior(mPendingTree);
			mPendingTree.Clear();
		}
		if (mTreeFocus && Time.FrameCount > mTreeFocusAfter)
		{
			ImGui.SetNextWindowFocus();
			mTreeFocus = false;
		}
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		let visible = ImGui.Begin("Behavior", &mShowBehavior, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar();
		if (visible && mTree == null)
		{
			ImGui.SetCursorPosX(16);
			ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 14);
			ImGui.TextDisabled("Create a behaviour tree with Project > + > Behavior Tree, or double-click a .tbt file.");
		}
		else if (visible)
		{
			let runner = WatchedRunner();
			DrawBehaviorToolbar(runner);
			ImGui.BeginChild("treecanvas", .(0, 0), 0, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse | ImGui.WindowFlags.NoMove);
			DrawTreeCanvas(runner);
			ImGui.EndChild();
		}
		ImGui.End();
	}

	void DrawBehaviorToolbar(BehaviorTreeRunnerState runner)
	{
		ImGui.SetCursorPosX(6);
		ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 4);
		if (ImGui.SmallButton("Save"))
			SaveBehavior();
		ImGui.SameLine();
		if (ImGui.SmallButton("Fit View"))
		{
			mTreeFit = true;
			mTreeFitSize = default;
		}
		ImGui.SameLine(0, 14);
		let info = scope String();
		info.AppendF("{}   {:0}%   {}", mTree.name, mTreeZoom * 100, mTreeStatus);
		if (runner != null)
			info.AppendF("   Watching: {}", runner.GameObject.Name);
		else if (mPlay != .Edit)
			info.Append("   No running object uses this tree.");
		ImGui.TextDisabled(info.CStr());
	}

	void DrawTreeCanvas(BehaviorTreeRunnerState runner)
	{
		var canvas = CanvasView.Layout("##treecanvas");
		// Fitted to the canvas while Fit View is on: again whenever the canvas changes size.
		if (mTreeFit && (canvas.size.x != mTreeFitSize.x || canvas.size.y != mTreeFitSize.y))
		{
			FitTree(canvas.size);
			mTreeFitSize = canvas.size;
		}
		let zoomBefore = mTreeZoom;
		let panBefore = mTreePan;
		canvas.Update(ref mTreePan, ref mTreeZoom);
		if (mTreeZoom != zoomBefore || mTreePan != panBefore)
			mTreeFit = false;

		NodeCanvas.BeginFont(canvas.zoom);
		DrawTreeLinks(canvas, runner);
		let hover = DrawTreeNodes(canvas, runner);
		NodeCanvas.EndFont();
		HandleTreeMouse(canvas, hover);
		DrawTreeNodeSearch();
		DrawSelectedTreeNode(canvas);
		if (runner != null)
			DrawBlackboard(canvas, runner);
	}

	/// Parent-to-child links, lit up in the colour of the child's latest result while an object runs the tree.
	void DrawTreeLinks(CanvasView canvas, BehaviorTreeRunnerState runner)
	{
		for (let link in mTree.links)
		{
			let parent = mTree.Find(link.parent);
			let child = mTree.Find(link.child);
			if (parent == null || child == null)
				continue;
			var color = Color(0.62f, 0.62f, 0.66f, 0.9f);
			let live = TreeStatusColor(runner, child.id, let strength, let label);
			if (strength > 0)
				color = .(Mathf.Lerp(0.45f, live.r, strength), Mathf.Lerp(0.45f, live.g, strength), Mathf.Lerp(0.48f, live.b, strength), 1);
			NodeCanvas.DrawLink(canvas.ToScreen(TreePin(parent, true)), canvas.ToScreen(TreePin(child, false)), color, strength >= 1 ? canvas.zoom * 1.6f : canvas.zoom, true);
		}
	}

	/// Every node, with its latest result, settings, pins and its place among its siblings. Returns what is under
	/// the mouse.
	TreeHover DrawTreeNodes(CanvasView canvas, BehaviorTreeRunnerState runner)
	{
		TreeHover hover = default;
		hover.pin = -1;
		let zoom = canvas.zoom;
		let mouse = canvas.mouse;
		let pinRadius = 5.5f * zoom;
		List<int32> order = scope .();
		for (let node in mTree.nodes)
		{
			let min = canvas.ToScreen(node.position);
			let max = canvas.ToScreen(.(node.position.x + TreeNodeWidth, node.position.y + TreeNodeHeight(node)));
			let live = TreeStatusColor(runner, node.id, let strength, let label);
			NodeCanvas.DrawNode(min, max, TreeCategoryColor(node), node.id == mTreeSelected, zoom);
			if (strength > 0)
				DrawTreeNodeGlow(min, max, live, strength, label, zoom);
			if (zoom > 0.4f)
				DrawTreeNodeText(node, min, max, live, strength, label, zoom);
			if (canvas.hovered && mouse.x >= min.x && mouse.x <= max.x && mouse.y >= min.y && mouse.y <= max.y)
				hover.node = node;
			for (int side < 2)
			{
				if ((side == 0 && node.def.kind == .Root) || (side == 1 && node.def.MaxChildren == 0))
					continue;
				let center = canvas.ToScreen(TreePin(node, side == 1));
				let over = canvas.hovered && Math.Abs(mouse.x - center.x) < pinRadius * 2 && Math.Abs(mouse.y - center.y) < pinRadius * 2;
				if (over)
				{
					hover.node = node;
					hover.pin = side;
				}
				ImDrawList_AddCircleFilled(canvas.drawList, center, over ? pinRadius * 1.4f : pinRadius, Color(0.92f, 0.92f, 0.92f, 1).ToABGR(), 12);
			}
			// Running order among siblings, shown beside the node's top pin.
			let parentId = mTree.ParentOf(node.id);
			if (parentId != 0 && zoom > 0.4f)
			{
				mTree.ChildrenOf(parentId, order);
				if (order.Count > 1)
				{
					let top = canvas.ToScreen(TreePin(node, false));
					ImGui.DrawText(.(top.x + 9 * zoom, top.y - 17 * zoom), .(0.75f, 0.75f, 0.80f, 1), scope String()..AppendF("{}", order.IndexOf(node.id) + 1).CStr());
				}
			}
		}
		return hover;
	}

	/// The outline of a node with a fresh result; a running node pulses, so that it stands out from results that
	/// merely happen to be fresh.
	static void DrawTreeNodeGlow(ImGui.Vec2 min, ImGui.Vec2 max, Color live, float strength, StringView label, float zoom)
	{
		let pulse = label == "RUNNING" && strength >= 1 ? 0.75f + 0.25f * (float)Math.Sin(Time.FrameCount * 0.12f) : 1.0f;
		let glow = Color(live.r, live.g, live.b, strength * pulse);
		ImGui.DrawRect(.(min.x - 2, min.y - 2), .(max.x + 2, max.y + 2), glow, 7 * zoom, strength >= 1 ? 3 : 2);
		if (strength >= 1)
			ImGui.DrawRectFilled(min, max, .(live.r, live.g, live.b, 0.10f), 6 * zoom);
	}

	/// A node's title, its latest result (top right) and its settings.
	static void DrawTreeNodeText(BTNodeData node, ImGui.Vec2 min, ImGui.Vec2 max, Color live, float strength, StringView label, float zoom)
	{
		ImGui.DrawText(.(min.x + 9 * zoom, min.y + 5 * zoom), .White, node.def.title.CStr());
		if (strength > 0)
		{
			let text = scope String(label);
			ImGui.DrawText(.(max.x - 8 * zoom - ImGui.CalcTextSize(text.CStr()).x, min.y + 5 * zoom), .(live.r, live.g, live.b, Math.Max(strength, 0.5f)), text.CStr());
		}
		for (int i < node.def.parameters.Count)
		{
			let line = scope String();
			line.AppendF("{}: {}", node.def.parameters[i].name, node.values[i]);
			ImGui.DrawText(.(min.x + 9 * zoom, min.y + (TreeHeader + 4 + i * TreeRow) * zoom), .(0.85f, 0.85f, 0.85f, 1), line.CStr());
		}
	}

	/// The mouse on the canvas: linking (Alt-click undoes a pin's link), selecting and dragging nodes, deleting the
	/// selected one, and the right-click menu of nodes to add.
	void HandleTreeMouse(CanvasView canvas, TreeHover hover)
	{
		let graphMouse = canvas.GraphMouse;
		if (canvas.hovered && ImGui.IsMouseClicked(0))
		{
			if (hover.pin >= 0 && Input.GetKey(.LeftAlt))
				mTree.Disconnect(hover.node.id, hover.pin == 0);
			else if (hover.pin >= 0)
			{
				mTreeLinking = true;
				mTreeLinkNode = hover.node.id;
				mTreeLinkFromBottom = hover.pin == 1;
			}
			else if (hover.node != null)
			{
				mTreeSelected = hover.node.id;
				mTreeDragNode = hover.node.id;
				// Double-clicking a Run Subtree node opens its tree.
				if (ImGui.IsMouseDoubleClicked(0) && hover.node.def.key == "subtree")
					OpenSubtree(hover.node);
			}
			else
				mTreeSelected = 0;
		}
		if (mTreeLinking)
			DragTreeLink(canvas, hover);
		if (mTreeDragNode != 0)
		{
			let dragged = mTree.Find(mTreeDragNode);
			if (dragged != null && ImGui.IsMouseDown(0))
			{
				dragged.position = dragged.position + Input.MouseDelta / canvas.zoom;
				mTreeFit = false;
			}
			else
				mTreeDragNode = 0;
		}
		if (canvas.hovered && ImGui.IsKeyPressed(ImGui.Key.Delete) && (ImGui.tn_imgui_capture_flags() & 4) == 0)
		{
			let selected = mTree.Find(mTreeSelected);
			if (selected != null)
				mTree.RemoveNode(selected);
			mTreeSelected = 0;
		}
		// Ctrl+D: a copy of the selected node and everything under it, beside it.
		if (canvas.hovered && Input.GetKey(.LeftControl) && ImGui.IsKeyPressed(ImGui.Key.D) && (ImGui.tn_imgui_capture_flags() & 4) == 0)
		{
			let copy = mTree.Duplicate(mTreeSelected, .(40, 40));
			if (copy != 0)
			{
				mTreeSelected = copy;
				mTreeStatus.Set("Duplicated. Link the copy to a parent to use it.");
			}
		}
		if (canvas.hovered && ImGui.IsMouseClicked(1))
		{
			mTreeNewPosition = .(graphMouse.x - TreeNodeWidth * 0.5f, graphMouse.y);
			mTreeSearch.Clear();
			mTreeSearchForLink = false;
			mOpenTreeSearch = true;
		}
	}

	/// A link being dragged out of a pin: drawn to the mouse, and on release made to the node it was dropped on (the
	/// end it was dragged from decides which is the parent), or offered new nodes if dropped on nothing.
	void DragTreeLink(CanvasView canvas, TreeHover hover)
	{
		let source = mTree.Find(mTreeLinkNode);
		if (source != null)
		{
			let start = canvas.ToScreen(TreePin(source, mTreeLinkFromBottom));
			if (mTreeLinkFromBottom)
				NodeCanvas.DrawLink(start, canvas.mouse, .(1, 1, 1, 0.8f), canvas.zoom, true);
			else
				NodeCanvas.DrawLink(canvas.mouse, start, .(1, 1, 1, 0.8f), canvas.zoom, true);
		}
		if (ImGui.IsMouseDown(0))
			return;
		if (source != null && hover.node != null && hover.node.id != mTreeLinkNode)
		{
			let error = scope String();
			let ok = mTreeLinkFromBottom ? mTree.Connect(source.id, hover.node.id, error) : mTree.Connect(hover.node.id, source.id, error);
			if (!ok)
				mTreeStatus.Set(error.IsEmpty ? "Those nodes cannot be linked." : error);
		}
		else if (source != null && canvas.hovered && hover.node == null)
		{
			let graphMouse = canvas.GraphMouse;
			mTreeNewPosition = .(graphMouse.x - TreeNodeWidth * 0.5f, graphMouse.y);
			mTreeSearch.Clear();
			mTreeSearchForLink = true;
			mOpenTreeSearch = true;
		}
		mTreeLinking = false;
	}

	/// Whether the add-node menu offers a node: one Root per tree, and a node dragged out of a top pin needs a parent
	/// that can have children.
	bool OfferedTreeNode(BTNodeDef def)
	{
		if (def.kind == .Root)
			return mTree.Root == null && !mTreeSearchForLink;
		return !(mTreeSearchForLink && !mTreeLinkFromBottom && def.MaxChildren == 0);
	}

	/// The add-node menu: browsing by category with nothing typed, else the nodes whose names match.
	void DrawTreeNodeSearch()
	{
		if (mOpenTreeSearch)
		{
			ImGui.OpenPopup("AddTreeNode");
			mOpenTreeSearch = false;
			mTreeSearchFocus = true;
		}
		if (!ImGui.BeginPopup("AddTreeNode"))
			return;
		if (mTreeSearchFocus)
		{
			ImGui.SetKeyboardFocusHere();
			mTreeSearchFocus = false;
		}
		ImGui.SetNextItemWidth(260);
		ImGui.InputText("##treesearch", mTreeSearch, 0, "Search nodes");
		let chosen = mTreeSearch.IsEmpty ? BrowseTreeNodes() : MatchingTreeNodes(ImGui.IsKeyPressed(ImGui.Key.Enter));
		if (chosen != null)
		{
			let created = mTree.AddNode(chosen, mTreeNewPosition);
			mTreeSelected = created.id;
			if (mTreeSearchForLink)
			{
				if (mTreeLinkFromBottom)
					mTree.Connect(mTreeLinkNode, created.id);
				else
					mTree.Connect(created.id, mTreeLinkNode);
			}
			ImGui.CloseCurrentPopup();
		}
		ImGui.EndPopup();
	}

	BTNodeDef BrowseTreeNodes()
	{
		BTNodeDef chosen = null;
		String category = null;
		bool open = false;
		for (let def in BehaviorLibrary.Defs)
		{
			if (!OfferedTreeNode(def))
				continue;
			if (category == null || category != def.category)
			{
				if (open)
					ImGui.EndMenu();
				category = def.category;
				open = ImGui.BeginMenu(category.CStr());
			}
			if (!open)
				continue;
			if (ImGui.MenuItem(def.title.CStr()))
				chosen = def;
			if (ImGui.IsItemHovered() && !def.description.IsEmpty)
				ImGui.SetTooltip(def.description.CStr());
		}
		if (open)
			ImGui.EndMenu();
		return chosen;
	}

	/// Names that start with the typed text come first; Enter takes the top one.
	BTNodeDef MatchingTreeNodes(bool enter)
	{
		BTNodeDef chosen = null;
		ImGui.BeginChild("treematches", .(260, 240));
		int shown = 0;
		for (int pass < 2)
		{
			for (let def in BehaviorLibrary.Defs)
			{
				if (!OfferedTreeNode(def))
					continue;
				let starts = def.title.StartsWith(mTreeSearch, .OrdinalIgnoreCase);
				let contains = def.title.Contains(mTreeSearch, true) || def.category.Contains(mTreeSearch, true);
				if ((pass == 0 && !starts) || (pass == 1 && (starts || !contains)))
					continue;
				let label = scope String();
				label.AppendF("{}   ({})", def.title, def.category);
				if (ImGui.Selectable(label.CStr(), shown == 0) || (enter && shown == 0))
					chosen = def;
				shown++;
			}
		}
		if (shown == 0)
			ImGui.TextDisabled("No matching nodes.");
		ImGui.EndChild();
		return chosen;
	}

	/// The selected node's settings and what it does, in a panel at the canvas's top left.
	void DrawSelectedTreeNode(CanvasView canvas)
	{
		let selectedNode = mTree.Find(mTreeSelected);
		if (selectedNode == null)
			return;
		let rows = selectedNode.def.parameters.Count;
		ImGui.SetCursorScreenPos(.(canvas.origin.x + 10, canvas.origin.y + 10));
		ImGui.PushStyleColor(ImGui.Col.ChildBg, EditorTheme.Canvas);
		ImGui.BeginChild("treevalues", .(300, 92 + rows * 27 + (selectedNode.def.key == "subtree" ? 26 : 0)), ImGui.ChildBorders);
		ImGui.Text(selectedNode.def.title);
		for (int32 i = 0; i < (int32)rows; i++)
		{
			let parameter = selectedNode.def.parameters[i];
			ImGui.PushID(i);
			ImGui.SetNextItemWidth(150);
			if (parameter.type == .Bool)
			{
				bool value = selectedNode.values[i] == "true";
				if (ImGui.Checkbox("##v", ref value))
					selectedNode.values[i].Set(value ? "true" : "false");
			}
			else
				ImGui.InputText("##v", selectedNode.values[i], 0, parameter.type == .Vector ? (char8*)"x y z" : null);
			ImGui.SameLine();
			ImGui.Text(parameter.name);
			ImGui.PopID();
		}
		if (selectedNode.def.key == "subtree")
		{
			if (ImGui.SmallButton("Open"))
				OpenSubtree(selectedNode);
			ImGui.SameLine();
			if (ImGui.SmallButton("New Subtree File"))
				CreateSubtreeFile(selectedNode);
		}
		ImGui.PushStyleColor(ImGui.Col.Text, EditorTheme.CanvasText);
		ImGui.TextWrapped(selectedNode.def.description.CStr());
		ImGui.PopStyleColor();
		ImGui.EndChild();
		ImGui.PopStyleColor();
	}

	/// Opens the tree a Run Subtree node runs (saving this one first).
	void OpenSubtree(BTNodeData node)
	{
		let path = scope String();
		Assets.ResolvePath(node.values[0], path);
		if (!File.Exists(path))
		{
			mTreeStatus.Set(scope $"{node.values[0]} does not exist yet: press New Subtree File.");
			return;
		}
		mPendingTree.Set(path);
	}

	/// Makes the file a Run Subtree node names, with a Root and a Wait under it, and opens it.
	void CreateSubtreeFile(BTNodeData node)
	{
		let path = scope String();
		Assets.ResolvePath(node.values[0], path);
		if (File.Exists(path) || !path.EndsWith(".tbt"))
		{
			mTreeStatus.Set(File.Exists(path) ? "That file already exists: press Open." : "The Tree setting must name a .tbt file.");
			return;
		}
		let folder = scope String();
		Path.GetDirectoryPath(path, folder);
		if (!folder.IsEmpty)
			Directory.CreateDirectory(folder).IgnoreError();
		let tree = scope BehaviorTreeData();
		Path.GetFileNameWithoutExtension(path, tree.name..Clear());
		let root = tree.AddNode(BehaviorLibrary.Find("root"), .(0, 0));
		let wait = tree.AddNode(BehaviorLibrary.Find("wait"), .(0, 110));
		tree.Connect(root.id, wait.id);
		tree.Save(path);
		RefreshAssetList();
		mPendingTree.Set(path);
	}

	/// What the watched object remembers, in a panel at the canvas's bottom left.
	void DrawBlackboard(CanvasView canvas, BehaviorTreeRunnerState runner)
	{
		let count = runner.Blackboard.Values.Count;
		let height = 34 + Math.Max(count, 1) * 19;
		ImGui.SetCursorScreenPos(.(canvas.origin.x + 10, canvas.origin.y + canvas.size.y - height - 10));
		ImGui.PushStyleColor(ImGui.Col.ChildBg, EditorTheme.Canvas);
		ImGui.BeginChild("treeblackboard", .(300, height), ImGui.ChildBorders);
		ImGui.Text(scope String()..AppendF("Blackboard of {}", runner.GameObject.Name));
		if (count == 0)
			ImGui.TextDisabled("Nothing remembered yet.");
		List<String> keys = scope .();
		for (let key in runner.Blackboard.Values.Keys)
			keys.Add(key);
		keys.Sort(scope (a, b) => a.CompareTo(b));
		for (let key in keys)
		{
			let line = scope String();
			line.AppendF("{} = ", key);
			runner.Blackboard.Describe(key, mScene, line);
			ImGui.TextDisabled(line.CStr());
		}
		ImGui.EndChild();
		ImGui.PopStyleColor();
	}
}
