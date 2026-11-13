using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The Graph tab: a zoomable node canvas for visual scripts (.tgraph files).
///   Right-click the canvas to add a node (type to search), drag from a pin to another pin to connect them,
///   or drop a link on empty canvas to pick from the nodes that fit it,
///   drag a link's end off an input to move it (drop it on nothing to remove it), right-click a link or a pin (or
///   Alt+click a pin) to disconnect it, Delete removes the selected node (or the link under the mouse), middle-drag
///   pans, the wheel zooms.
/// Save also compiles the graph to a Beef component next to it; automatic script reload then picks it up like any script.
extension EditorApp
{
	[CLink] static extern void* igGetWindowDrawList();
	[CLink] static extern void ImDrawList_AddCircleFilled(void* list, ImGui.Vec2 center, float radius, uint32 color, int32 segments);
	[CLink] static extern void ImDrawList_AddBezierCubic(void* list, ImGui.Vec2 p1, ImGui.Vec2 p2, ImGui.Vec2 p3, ImGui.Vec2 p4, uint32 color, float thickness, int32 segments);
	[CLink] static extern void igPushFont(void* font, float size);

	const float NodeWidth = 190;
	const float HeaderHeight = 26;
	const float RowHeight = 22;
	/// A shader node's preview picture, under its pins.
	const float NodePreviewSize = 120;
	/// The whole shader's preview, in the canvas's bottom right corner.
	const float SurfacePreviewSize = 200;

	NodeGraph mGraph ~ delete _;
	ShaderGraphPreview mShaderPreview ~ delete _;
	static bool sShowNodePreviews = true;
	String mGraphPath = new .() ~ delete _;
	String mGraphStatus = new .() ~ delete _;
	Vector2 mGraphPan = .(60, 60);
	float mGraphZoom = 1.0f;
	int32 mGraphSelected;
	int32 mGraphDragNode;
	/// Comment boxes: the selected one, the one under the mouse (and whether at its resize corner), and while one is
	/// dragged, the nodes and comments inside it that move with it.
	int mCommentSelected = -1;
	int mCommentHover = -1;
	bool mCommentHoverCorner;
	int mCommentDrag = -1;
	bool mCommentResizing;
	List<int32> mCommentDragNodes = new .() ~ delete _;
	List<GraphComment> mCommentDragInner = new .() ~ delete _;
	const float CommentTitleHeight = 34;
	bool mGraphFocus;
	// Link being dragged out of a pin.
	bool mLinking;
	int32 mLinkNode;
	int32 mLinkPin;
	bool mLinkFromOutput;
	// The link was picked up off an input: dropped on nothing it is removed, not offered the node search.
	bool mLinkDetached;
	// The link under the mouse (index into mGraph.links), or -1.
	int mGraphHoverLink = -1;
	Vector2 mNewNodePosition;

	bool mGraphShowVariables = true;
	// Name being typed in the Variables panel; it is applied when the field loses focus.
	String mVariableEdit = new .() ~ delete _;
	int mVariableEditing = -1;

	String mNodeSearch = new .() ~ delete _;
	bool mOpenNodeSearch;
	bool mNodeSearchFocus;
	bool mSearchForLink;

	void OpenNodeSearch(Vector2 position, bool forLink)
	{
		mNewNodePosition = position;
		mNodeSearch.Clear();
		mSearchForLink = forLink;
		mOpenNodeSearch = true;
	}

	/// For a search opened by dragging a link: the first pin of a node kind that the dragged pin can connect to.
	int32 FirstCompatiblePin(NodeDef def)
	{
		let source = mGraph.Find(mLinkNode);
		if (source == null)
			return -1;
		if (mLinkFromOutput)
		{
			if (mLinkPin >= source.def.outputs.Count)
				return -1;
			let from = source.def.outputs[mLinkPin];
			for (int32 i = 0; i < (int32)def.inputs.Count; i++)
			{
				if (mGraph.CanTake(def, true, i, from))
					return i;
			}
			return -1;
		}
		if (mLinkPin >= source.def.inputs.Count)
			return -1;
		let wanted = source.def.inputs[mLinkPin];
		for (int32 i = 0; i < (int32)def.outputs.Count; i++)
		{
			if (mGraph.CanTake(def, false, i, wanted))
				return i;
		}
		return -1;
	}

	String mPendingGraph = new .() ~ delete _;
	/// The graphs stepped out of to get into the open one (double-clicking subgraph nodes), for the Back button.
	List<String> mGraphBack = new .() ~ DeleteContainerAndItems!(_);
	/// Set while opening a graph by stepping into or back out of a subgraph, which keeps mGraphBack.
	bool mGraphStepping;

	void OpenGraph(StringView path)
	{
		if (!mGraphStepping)
			ClearAndDeleteItems!(mGraphBack);
		mGraphStepping = false;
		mGraphOpenedAtStart = false;
		mShowGraph = true;
		mDockGraph = true;
		NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
		delete mGraph;
		mGraph = new NodeGraph();
		mGraphPath.Set(path);
		mGraph.name.Clear();
		Path.GetFileNameWithoutExtension(path, mGraph.name);
		// A shader graph uses the same canvas with its own nodes, and compiles to a shader, not a script.
		mGraph.isShader = path.EndsWith(".tsgraph");
		mGraph.Load(path);
		DeleteAndNullify!(mShaderPreview);
		if (mGraph.isShader)
			mShaderPreview = new .();
		mGraph.Validate();
		mGraphSelected = 0;
		mCommentSelected = -1;
		mCommentDrag = -1;
		mVariableEditing = -1;
		mGraphStatus.Clear();
		mGraphFocus = true;
	}

	void CreateGraphAsset(StringView name)
	{
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Graph names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.tgraph";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		// Start with something that runs: spin the object a little every frame.
		let graph = scope NodeGraph();
		graph.name.Set(name);
		let update = graph.AddNode(NodeLibrary.Find("event.update"), .(40, 60));
		let rotate = graph.AddNode(NodeLibrary.Find("transform.rotate"), .(560, 60));
		let vector = graph.AddNode(NodeLibrary.Find("math.vector"), .(320, 150));
		let multiply = graph.AddNode(NodeLibrary.Find("math.mul"), .(60, 190));
		multiply.values[1].Set("90");
		graph.Connect(update.id, 0, rotate.id, 0);
		graph.Connect(update.id, 1, multiply.id, 0);
		graph.Connect(multiply.id, 0, vector.id, 1);
		graph.Connect(vector.id, 0, rotate.id, 1);
		graph.Save(path);
		RefreshAssetList();
		OpenGraph(path);
	}

	/// A reusable graph: Sub Entry starts it, Parameter nodes are its inputs, an optional Return node its result.
	/// Makes a new, empty subgraph file next to the open graph and places its node here; double-click the node to
	/// open it, and Back to return.
	void AddNewSubgraphNode(Vector2 position)
	{
		let folder = Path.GetDirectoryPath(mGraphPath, .. scope String());
		let name = scope String();
		for (int i = 1; ; i++)
		{
			name..Clear().AppendF("{}Part{}", mGraph.name, i);
			if (!File.Exists(scope $"{folder}/{name}.tgraph"))
				break;
		}
		let path = scope $"{folder}/{name}.tgraph";
		let graph = scope NodeGraph();
		graph.name.Set(name);
		graph.AddNode(NodeLibrary.Find("sub.entry"), .(40, 60));
		graph.Save(path);
		NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
		let relative = scope String();
		Assets.MakeRelative(path, relative);
		let def = NodeLibrary.Find(scope $"sub:{relative}");
		if (def == null)
		{
			mGraphStatus.Set("Could not make the subgraph.");
			return;
		}
		mGraphSelected = mGraph.AddNode(def, position).id;
		mGraph.Save(mGraphPath);
		RefreshAssetList();
		mGraphStatus.Set(scope $"Made {name}: double-click its node to open it.");
	}

	void CreateSubgraphAsset(StringView name)
	{
		if (!ProjectGenerator.IsValidName(name))
		{
			Log.Error("Subgraph names use letters, digits and underscores, and start with a letter.");
			return;
		}
		let path = scope $"{mBrowsePath}/{name}.tgraph";
		if (File.Exists(path))
		{
			Log.Error(scope $"{path} already exists.");
			return;
		}
		let graph = scope NodeGraph();
		graph.name.Set(name);
		let entry = graph.AddNode(NodeLibrary.Find("sub.entry"), .(40, 60));
		let amount = graph.AddNode(NodeLibrary.Find("sub.param.float"), .(40, 190));
		amount.values[0].Set("amount");
		let vector = graph.AddNode(NodeLibrary.Find("math.vector"), .(300, 170));
		let move = graph.AddNode(NodeLibrary.Find("transform.translate"), .(560, 60));
		graph.Connect(entry.id, 0, move.id, 0);
		graph.Connect(amount.id, 0, vector.id, 1);
		graph.Connect(vector.id, 0, move.id, 1);
		graph.Save(path);
		RefreshAssetList();
		OpenGraph(path);
	}

	void CompileGraph()
	{
		if (mGraph == null)
			return;
		mGraph.Save(mGraphPath);
		if (mGraph.isShader)
		{
			CompileShaderGraph();
			return;
		}
		NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
		mGraph.Validate();
		if (mGraph.IsSubgraph)
		{
			mGraphStatus.Set("Saved. A subgraph is compiled into each graph that uses it: save those to update them.");
			return;
		}
		let folder = scope String();
		Path.GetDirectoryPath(mGraphPath, folder).IgnoreError();
		let fileName = scope String();
		Path.GetFileName(mGraphPath, fileName);
		let code = scope String();
		mGraph.Compile(Project.Current.Name, mGraph.name, fileName, code);
		let target = scope $"{folder}/{mGraph.name}.bf";
		if (File.WriteAllText(target, code) case .Ok)
		{
			mGraphStatus.Set("Saved and compiled.");
			Log.Info(scope $"Graph compiled to {target}");
			RefreshAssetList();
			StartErrorCheck();
		}
		else
			mGraphStatus.Set("Could not write the generated script.");
	}

	/// Saves a shader graph as the .tshader (or .tcompute) file beside it and compiles that. A subgraph has no shader of its own:
	/// the shader graphs that use it are compiled again instead.
	void CompileShaderGraph()
	{
		if (ShaderGraphCode.IsSubgraph(mGraph))
		{
			NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
			let relative = scope String();
			Assets.MakeRelative(mGraphPath, relative);
			let users = CompileShaderGraphsUsing(relative);
			mGraphStatus.Set(scope $"Saved. {users} shader graph{(users == 1) ? "" : "s"} using it compiled again.");
			return;
		}
		let text = scope String();
		let problem = scope String();
		if (!mGraph.CompileShader(text, problem))
		{
			mGraphStatus.Set(problem);
			return;
		}
		let target = scope String(mGraphPath);
		target.RemoveFromEnd(".tsgraph".Length);
		target.Append(ShaderGraphCode.FileExtension(mGraph));
		if (File.WriteAllText(target, text) case .Err)
		{
			mGraphStatus.Set("Could not write the generated shader.");
			return;
		}
		let relative = scope String();
		Assets.MakeRelative(target, relative);
		let use = target.EndsWith(".tcompute") ? "Pick it in a Compute Effect component." : "Pick it as a material's Shader.";
		mGraphStatus.Set(CompileShader(relative) ? scope $"Saved and compiled. {use}" : "Saved, but the shader did not compile: see the Console.");
		AssetPreviews.Invalidate(mGraphPath);
		RefreshAssetList();
	}

	/// Compiles again every shader graph in the project that uses a subgraph (a project path). Returns how many.
	int CompileShaderGraphsUsing(StringView subgraph)
	{
		let graphs = scope List<String>();
		defer
		{
			for (let g in graphs)
				delete g;
		}
		FindFiles(Assets.ProjectPath, ".tsgraph", graphs, 0);
		let key = scope $"shsub:{subgraph}";
		int count = 0;
		for (let path in graphs)
		{
			let text = scope String();
			if (File.ReadAllText(path, text) case .Err || !text.Contains(key) || text.Contains("shader.sub.output."))
				continue;
			let user = scope NodeGraph();
			user.isShader = true;
			if (!user.Load(path))
				continue;
			user.Validate();
			let shader = scope String(), problem = scope String();
			if (!user.CompileShader(shader, problem))
			{
				Log.Error(scope $"{path}: {problem}");
				continue;
			}
			let target = scope String(path);
			target.RemoveFromEnd(".tsgraph".Length);
			target.Append(ShaderGraphCode.FileExtension(user));
			let relative = scope String();
			Assets.MakeRelative(target, relative);
			if (File.WriteAllText(target, shader) case .Ok && CompileShader(relative))
				count++;
			AssetPreviews.Invalidate(path);
		}
		return count;
	}

	static void FindFiles(StringView folder, StringView suffix, List<String> output, int depth)
	{
		if (depth > 12 || !Directory.Exists(folder))
			return;
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (name.EndsWith(suffix))
				output.Add(new String(scope $"{folder}/{name}"));
		}
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.StartsWith('.') && name != "build" && name != "Compiled")
				FindFiles(scope $"{folder}/{name}" , suffix, output, depth + 1);
		}
	}

	/// A reusable piece of shader graph: Subgraph Input nodes become its pins in other shader graphs, Subgraph Output
	/// nodes its results.
	void CreateShaderSubgraphAsset(StringView name)
	{
		if (!ValidAssetName(name, "Shader subgraph"))
			return;
		let path = scope $"{mBrowsePath}/{name}.tsgraph";
		if (File.Exists(path))
		{
			Log.Error(scope $"A shader graph named {name} already exists in this folder.");
			return;
		}
		// Something that works at once: noise at a scale given by the graph that uses it.
		let graph = scope NodeGraph();
		graph.isShader = true;
		graph.name.Set(name);
		let scale = graph.AddNode(NodeLibrary.Find("shader.sub.input.float"), .(40, 80));
		let noise = graph.AddNode(NodeLibrary.Find("shader.smoothnoise"), .(300, 60));
		let result = graph.AddNode(NodeLibrary.Find("shader.sub.output.float"), .(580, 60));
		graph.Validate();
		scale.values[0].Set("Scale");
		scale.values[1].Set("8");
		result.values[0].Set("Noise");
		graph.Connect(scale.id, 0, noise.id, 1);
		graph.Connect(noise.id, 0, result.id, 1);
		graph.Save(path);
		NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
		RefreshAssetList();
		OpenGraph(path);
	}

	void CreateShaderGraphAsset(StringView name)
	{
		if (!ValidAssetName(name, "Shader graph"))
			return;
		let path = scope $"{mBrowsePath}/{name}.tsgraph";
		if (File.Exists(path) || File.Exists(scope $"{mBrowsePath}/{name}.tshader"))
		{
			Log.Error(scope $"A shader named {name} already exists in this folder.");
			return;
		}
		// Something that visibly works: a colour property for the surface, and a pulse of it as glow.
		let graph = scope NodeGraph();
		graph.isShader = true;
		graph.name.Set(name);
		let output = graph.AddNode(NodeLibrary.Find("shader.output"), .(620, 120));
		let tint = graph.AddNode(NodeLibrary.Find("shader.prop.color"), .(60, 80));
		let pulse = graph.AddNode(NodeLibrary.Find("shader.pulse"), .(60, 260));
		let rgb = graph.AddNode(NodeLibrary.Find("shader.rgb"), .(300, 80));
		let glow = graph.AddNode(NodeLibrary.Find("shader.vscale"), .(360, 240));
		graph.Validate();
		tint.values[0].Set("tint");
		tint.values[1].Set("0.2 0.7 1 1");
		pulse.values[0].Set("2");
		graph.Connect(tint.id, 0, rgb.id, 0);
		graph.Connect(rgb.id, 0, output.id, 0);
		graph.Connect(rgb.id, 0, glow.id, 0);
		graph.Connect(pulse.id, 0, glow.id, 1);
		graph.Connect(glow.id, 0, output.id, 4);
		graph.Save(path);
		RefreshAssetList();
		OpenGraph(path);
		CompileGraph();
	}

	/// A shader graph ending in a Compute Output: a .tcompute file, run for every pixel of a texture by a Compute
	/// Effect component.
	void CreateComputeGraphAsset(StringView name)
	{
		if (!ValidAssetName(name, "Compute graph"))
			return;
		let path = scope $"{mBrowsePath}/{name}.tsgraph";
		if (File.Exists(path) || File.Exists(scope $"{mBrowsePath}/{name}.tcompute"))
		{
			Log.Error(scope $"A shader named {name} already exists in this folder.");
			return;
		}
		// Something that visibly runs: drifting spots of ink that leave fading, spreading trails.
		let graph = scope NodeGraph();
		graph.isShader = true;
		graph.name.Set(name);
		let output = graph.AddNode(NodeLibrary.Find("shader.compute.output"), .(1160, 160));
		let spread = graph.AddNode(NodeLibrary.Find("shader.compute.blur"), .(60, 40));
		let spreadRgb = graph.AddNode(NodeLibrary.Find("shader.rgb"), .(320, 40));
		let fade = graph.AddNode(NodeLibrary.Find("shader.vscale"), .(580, 40));
		let cells = graph.AddNode(NodeLibrary.Find("shader.voronoi"), .(60, 260));
		let spots = graph.AddNode(NodeLibrary.Find("shader.smoothstep"), .(320, 260));
		let ink = graph.AddNode(NodeLibrary.Find("shader.prop.color"), .(320, 480));
		let inkRgb = graph.AddNode(NodeLibrary.Find("shader.rgb"), .(580, 480));
		let drawn = graph.AddNode(NodeLibrary.Find("shader.vscale"), .(580, 260));
		let sum = graph.AddNode(NodeLibrary.Find("shader.vadd"), .(840, 140));
		let colour = graph.AddNode(NodeLibrary.Find("shader.makecolor"), .(900, 300));
		graph.Validate();
		fade.values[1].Set("0.985");
		spots.values[0].Set("0.08");
		spots.values[1].Set("0");
		ink.values[0].Set("ink");
		ink.values[1].Set("0.2 0.6 1 1");
		colour.values[1].Set("1");
		graph.Connect(spread.id, 0, spreadRgb.id, 0);
		graph.Connect(spreadRgb.id, 0, fade.id, 0);
		graph.Connect(cells.id, 0, spots.id, 2);
		graph.Connect(ink.id, 0, inkRgb.id, 0);
		graph.Connect(inkRgb.id, 0, drawn.id, 0);
		graph.Connect(spots.id, 0, drawn.id, 1);
		graph.Connect(fade.id, 0, sum.id, 0);
		graph.Connect(drawn.id, 0, sum.id, 1);
		graph.Connect(sum.id, 0, colour.id, 0);
		graph.Connect(colour.id, 0, output.id, 0);
		graph.Save(path);
		RefreshAssetList();
		OpenGraph(path);
		CompileGraph();
	}

	static Color PinColor(PinType type)
	{
		switch (type)
		{
		case .Flow: return .(0.92f, 0.92f, 0.92f, 1);
		case .Float: return .(0.45f, 0.80f, 0.45f, 1);
		case .Bool: return .(0.86f, 0.36f, 0.36f, 1);
		case .Vector3: return .(0.95f, 0.78f, 0.30f, 1);
		case .String: return .(0.80f, 0.50f, 0.85f, 1);
		case .Int: return .(0.35f, 0.75f, 0.70f, 1);
		case .Object: return .(0.40f, 0.62f, 0.95f, 1);
		case .Enum: return .(0.70f, 0.70f, 0.40f, 1);
		case .Vector2: return .(0.95f, 0.62f, 0.30f, 1);
		case .Quaternion: return .(0.62f, 0.55f, 0.95f, 1);
		case .Color: return .(0.95f, 0.50f, 0.70f, 1);
		}
	}

	static Color CategoryColor(StringView category) => NodeCanvas.CategoryColor(category);

	static float NodeHeight(GraphNode node) => HeaderHeight + Math.Max(node.def.inputs.Count, node.def.outputs.Count) * RowHeight + 8 + (HasNodePreview(node) ? NodePreviewSize + 6 : 0);

	/// Whether a node shows its value in a picture (shader graph nodes with a result, while previews are shown).
	static bool HasNodePreview(GraphNode node) => sShowNodePreviews && node.def.isShader && !node.def.outputs.IsEmpty && node.def.kind != .ShaderOutput;

	/// Whether a node kind stands for the graph being edited (a subgraph cannot use itself).
	bool IsThisGraph(NodeDef def)
	{
		let colon = def.key.IndexOf(':');
		if (colon < 0)
			return false;
		let relative = scope String();
		Assets.MakeRelative(mGraphPath, relative);
		return def.key.Substring(colon + 1) == relative;
	}

	/// A shader node's picture of its value, under its pins.
	void DrawNodePreview(CanvasView canvas, GraphNode node, ImGui.Vec2 min, ImGui.Vec2 max)
	{
		if (mShaderPreview == null || !HasNodePreview(node))
			return;
		if (!mShaderPreview.NodePicture(node.id, let texture, let from, let to))
			return;
		let size = NodePreviewSize * canvas.zoom;
		let x = (min.x + max.x - size) * 0.5f;
		let y = max.y - size - 7 * canvas.zoom;
		ImGui.DrawPicture(texture, .(x, y), .(x + size, y + size), from, to);
	}

	/// The whole shader, lit (or a compute graph's texture, running), in the canvas's bottom right corner.
	void DrawSurfacePreview(CanvasView canvas)
	{
		if (mShaderPreview == null)
			return;
		if (!mShaderPreview.SurfacePicture(let texture, let from, let to))
			return;
		let max = ImGui.Vec2(canvas.origin.x + canvas.size.x - 10, canvas.origin.y + canvas.size.y - 10);
		let min = ImGui.Vec2(max.x - SurfacePreviewSize, max.y - SurfacePreviewSize);
		ImGui.DrawRectFilled(.(min.x - 1, min.y - 19), .(max.x + 1, max.y + 1), EditorTheme.Canvas);
		ImGui.DrawText(.(min.x + 4, min.y - 17), .(0.85f, 0.85f, 0.85f, 1), "Preview");
		ImGui.DrawPicture(texture, min, max, from, to);
	}

	/// Pin centre in graph space.
	static Vector2 PinPosition(GraphNode node, int32 pin, bool output)
	{
		return .(node.position.x + (output ? NodeWidth : 0), node.position.y + HeaderHeight + pin * RowHeight + RowHeight * 0.5f);
	}

	/// The node (and pin, if any) under the mouse.
	struct GraphHover
	{
		public GraphNode node;
		public int32 pin;
		public bool pinIsOutput;
	}

	/// Whether the open graph is the one shown when the editor opened (which leaves the Scene tab in front).
	bool mGraphOpenedAtStart;
	bool mGraphStartTried;

	/// With the Graph window open and no graph in it when the editor starts: the project's first visual script
	/// (Scripts/ first, subgraphs left out), so a new project shows its character's graph.
	void OpenStartGraph()
	{
		mGraphStartTried = true;
		let found = scope String();
		void Search(StringView folder, int depth)
		{
			if (!found.IsEmpty || depth > 6)
				return;
			for (let entry in Directory.EnumerateFiles(folder, "*.tgraph"))
			{
				let path = entry.GetFilePath(.. scope .());
				let text = scope String();
				if (File.ReadAllText(path, text) case .Ok && !text.Contains("sub.entry"))
				{
					found.Set(path);
					return;
				}
			}
			for (let entry in Directory.EnumerateDirectories(folder))
			{
				let name = entry.GetFileName(.. scope .());
				if (!name.StartsWith('.'))
					Search(entry.GetFilePath(.. scope .()), depth + 1);
			}
		}
		let scripts = scope $"{Assets.ProjectPath}/Scripts";
		if (Directory.Exists(scripts))
			Search(scripts, 0);
		if (found.IsEmpty)
			Search(Assets.ProjectPath, 0);
		if (found.IsEmpty)
			return;
		OpenGraph(found);
		mGraphFocus = false;
		mGraphOpenedAtStart = true;
		Log.Info(scope $"Graph window: {Path.GetFileName(found, .. scope .())}");
	}

	void DrawGraph()
	{
		if (mShowGraph && mGraph == null && mPendingGraph.IsEmpty && !mGraphStartTried && Time.FrameCount > 2)
			OpenStartGraph();
		if (!mShowGraph && mPendingGraph.IsEmpty)
			return;
		if (mDockGraph && mAssetCenterDock != 0)
		{
			ImGui.SetNextWindowDockID(mAssetCenterDock);
			mDockGraph = false;
		}
		if (!mPendingGraph.IsEmpty)
		{
			if (mGraph != null)
				mGraph.Save(mGraphPath);
			OpenGraph(mPendingGraph);
			mPendingGraph.Clear();
		}
		if (mGraphFocus && Time.FrameCount > 5)
		{
			ImGui.SetNextWindowFocus();
			mGraphFocus = false;
		}
		ImGui.PushStyleVar(ImGui.StyleVar.WindowPadding, ImGui.Vec2(0, 0));
		let visible = ImGui.Begin("Graph", &mShowGraph, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse);
		ImGui.PopStyleVar();
		if (visible && mGraph == null)
		{
			ImGui.SetCursorPosX(16);
			ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 14);
			ImGui.TextDisabled("Create a visual script with Project > + > Graph, or double-click a .tgraph file.");
		}
		else if (visible)
		{
			DrawGraphToolbar();
			ImGui.BeginChild("canvas", .(0, 0), 0, ImGui.WindowFlags.NoScrollbar | ImGui.WindowFlags.NoScrollWithMouse | ImGui.WindowFlags.NoMove);
			DrawGraphCanvas();
			ImGui.EndChild();
		}
		ImGui.End();
	}

	void DrawGraphToolbar()
	{
		ImGui.SetCursorPosX(6);
		ImGui.SetCursorPosY(ImGui.GetCursorPosY() + 4);
		if (!mGraphBack.IsEmpty)
		{
			let parent = Path.GetFileNameWithoutExtension(mGraphBack.Back, .. scope String());
			if (ImGui.SmallButton(scope $"< Back to {parent}"))
			{
				// Saved (and compiled, so the graph using it picks up changes) on the way out.
				CompileGraph();
				mPendingGraph.Set(mGraphBack.Back);
				delete mGraphBack.PopBack();
				mGraphStepping = true;
			}
			ImGui.SameLine();
		}
		if (ImGui.SmallButton("Save"))
			CompileGraph();
		ImGui.SameLine();
		if (ImGui.SmallButton("Reset View"))
		{
			mGraphPan = .(60, 60);
			mGraphZoom = 1;
		}
		ImGui.SameLine();
		// A shader keeps its values in Property nodes.
		if (mGraph.isShader)
		{
			mGraphShowVariables = false;
			if (ImGui.SmallButton(sShowNodePreviews ? "Hide Previews" : "Previews"))
				sShowNodePreviews = !sShowNodePreviews;
		}
		else if (ImGui.SmallButton(mGraphShowVariables ? "Hide Variables" : "Variables"))
			mGraphShowVariables = !mGraphShowVariables;
		ImGui.SameLine(0, 14);
		let previewProblem = (mShaderPreview != null && !mShaderPreview.problem.IsEmpty) ? scope $"   Preview: {mShaderPreview.problem}" : "";
		ImGui.TextDisabled(scope String()..AppendF("{}   {:0}%   {}{}", mGraph.name, mGraphZoom * 100, mGraphStatus, previewProblem).CStr());
	}

	void DrawGraphCanvas()
	{
		let canvas = CanvasView.Begin("##canvas", ref mGraphPan, ref mGraphZoom);

		mShaderPreview?.Update(mGraph);
		DrawGraphComments(canvas);
		NodeCanvas.BeginFont(canvas.zoom);
		DrawGraphLinks(canvas);
		let hover = DrawGraphNodes(canvas);
		NodeCanvas.EndFont();
		DrawSurfacePreview(canvas);

		HandleGraphMouse(canvas, hover);
		DrawNodeSearch(canvas);
		DrawSelectedNodeValues(canvas);
		DrawSelectedComment(canvas);
		if (mGraphShowVariables)
			DrawGraphVariables(.(canvas.origin.x + canvas.size.x - 10, canvas.origin.y + 10), NodeCanvas.CenterNode(canvas.size, mGraphPan, mGraphZoom));
	}

	/// Comment boxes behind everything else: a tinted area with its title in a bar along the top.
	void DrawGraphComments(CanvasView canvas)
	{
		mCommentHover = -1;
		mCommentHoverCorner = false;
		if (mCommentSelected >= mGraph.comments.Count)
			mCommentSelected = -1;
		let zoom = canvas.zoom;
		for (int i < mGraph.comments.Count)
		{
			let comment = mGraph.comments[i];
			let min = canvas.ToScreen(comment.position);
			let max = canvas.ToScreen(comment.position + comment.size);
			let c = comment.color;
			ImGui.DrawRectFilled(min, max, .(c.r, c.g, c.b, 0.22f), 6 * zoom);
			ImGui.DrawRectFilled(min, .(max.x, Math.Min(min.y + CommentTitleHeight * zoom, max.y)), .(c.r, c.g, c.b, 0.85f), 6 * zoom);
			ImGui.DrawRect(min, max, i == mCommentSelected ? Color(1, 0.70f, 0.20f, 1) : Color(c.r, c.g, c.b, 0.9f), 6 * zoom, i == mCommentSelected ? 2 : 1);
			// The resize corner.
			let corner = 14 * zoom;
			ImGui.DrawRectFilled(.(max.x - corner, max.y - corner), max, .(c.r, c.g, c.b, 0.7f), 2);
			if (zoom > 0.25f)
			{
				NodeCanvas.BeginFont(zoom * 1.4f);
				ImGui.DrawText(.(min.x + 10 * zoom, min.y + 6 * zoom), .White, comment.title.CStr());
				NodeCanvas.EndFont();
			}
			let mouse = canvas.mouse;
			if (canvas.hovered && mouse.x >= min.x && mouse.x <= max.x && mouse.y >= min.y && mouse.y <= max.y)
			{
				// Later comments are drawn on top, so the last one under the mouse wins.
				mCommentHover = i;
				mCommentHoverCorner = mouse.x >= max.x - corner && mouse.y >= max.y - corner;
			}
		}
	}

	/// A new comment box: around the selected node if there is one, else where the mouse is.
	void AddComment(Vector2 position)
	{
		let comment = new GraphComment();
		let selected = mGraph.Find(mGraphSelected);
		if (selected != null)
		{
			comment.position = selected.position - Vector2(30, 30 + CommentTitleHeight);
			comment.size = .(NodeWidth + 60, NodeHeight(selected) + 60 + CommentTitleHeight);
		}
		else
			comment.position = position;
		mGraph.comments.Add(comment);
		mCommentSelected = mGraph.comments.Count - 1;
		mGraphSelected = 0;
	}

	/// Starts moving (or resizing) a comment; what lies wholly inside it moves along.
	void StartCommentDrag(int index, bool resize)
	{
		mCommentDrag = index;
		mCommentResizing = resize;
		mCommentDragNodes.Clear();
		mCommentDragInner.Clear();
		if (resize)
			return;
		let comment = mGraph.comments[index];
		bool Inside(Vector2 min, Vector2 max) => min.x >= comment.position.x && min.y >= comment.position.y
			&& max.x <= comment.position.x + comment.size.x && max.y <= comment.position.y + comment.size.y;
		for (let node in mGraph.nodes)
		{
			if (Inside(node.position, node.position + Vector2(NodeWidth, NodeHeight(node))))
				mCommentDragNodes.Add(node.id);
		}
		for (let other in mGraph.comments)
		{
			if (other != comment && Inside(other.position, other.position + other.size))
				mCommentDragInner.Add(other);
		}
	}

	void DragComment(float zoom)
	{
		if (mCommentDrag < 0)
			return;
		if (!ImGui.IsMouseDown(0) || mCommentDrag >= mGraph.comments.Count)
		{
			mCommentDrag = -1;
			return;
		}
		let delta = Input.MouseDelta / zoom;
		let comment = mGraph.comments[mCommentDrag];
		if (mCommentResizing)
		{
			comment.size = .(Math.Max(comment.size.x + delta.x, 120), Math.Max(comment.size.y + delta.y, CommentTitleHeight + 40));
			return;
		}
		comment.position = comment.position + delta;
		for (let id in mCommentDragNodes)
		{
			let node = mGraph.Find(id);
			if (node != null)
				node.position = node.position + delta;
		}
		for (let inner in mCommentDragInner)
			inner.position = inner.position + delta;
	}

	/// The selected comment's title and colour, in a panel at the canvas's top left.
	void DrawSelectedComment(CanvasView canvas)
	{
		if (mCommentSelected < 0 || mCommentSelected >= mGraph.comments.Count)
			return;
		let comment = mGraph.comments[mCommentSelected];
		ImGui.SetCursorScreenPos(.(canvas.origin.x + 10, canvas.origin.y + 10));
		ImGui.PushStyleColor(ImGui.Col.ChildBg, EditorTheme.Canvas);
		ImGui.BeginChild("comment", .(260, 88), ImGui.ChildBorders);
		ImGui.Text("Comment");
		ImGui.SetNextItemWidth(-1);
		if (mCommentFocus)
		{
			ImGui.SetKeyboardFocusHere();
			mCommentFocus = false;
		}
		ImGui.InputText("##title", comment.title, 0, "Title");
		ImGui.SetNextItemWidth(-1);
		ImGui.ColorEdit3("##color", ref comment.color);
		ImGui.EndChild();
		ImGui.PopStyleColor();
	}

	bool mCommentFocus;

	void DrawGraphLinks(CanvasView canvas)
	{
		// The link nearest the mouse within a few pixels is drawn lit up; right-click or Delete removes it.
		mGraphHoverLink = -1;
		var nearest = 6.0f;
		for (int i < mGraph.links.Count)
		{
			let link = mGraph.links[i];
			let from = mGraph.Find(link.fromNode);
			let to = mGraph.Find(link.toNode);
			if (from == null || to == null || !canvas.hovered || mLinking)
				continue;
			let distance = NodeCanvas.LinkDistance(canvas.ToScreen(PinPosition(from, link.fromPin, true)), canvas.ToScreen(PinPosition(to, link.toPin, false)), canvas.mouse, canvas.zoom);
			if (distance < nearest)
			{
				nearest = distance;
				mGraphHoverLink = i;
			}
		}
		for (int i < mGraph.links.Count)
		{
			let link = mGraph.links[i];
			let from = mGraph.Find(link.fromNode);
			let to = mGraph.Find(link.toNode);
			if (from == null || to == null)
				continue;
			let lit = i == mGraphHoverLink;
			let color = PinColor(from.def.outputs[link.fromPin].type);
			canvas.DrawLink(canvas.ToScreen(PinPosition(from, link.fromPin, true)), canvas.ToScreen(PinPosition(to, link.toPin, false)), lit ? Color(Math.Min(color.r + 0.35f, 1), Math.Min(color.g + 0.35f, 1), Math.Min(color.b + 0.35f, 1), 1) : color, lit ? 4 : 2.2f);
		}
	}

	/// Every node with its pins and their labels. Returns what is under the mouse.
	GraphHover DrawGraphNodes(CanvasView canvas)
	{
		GraphHover hover = default;
		hover.pin = -1;
		let zoom = canvas.zoom;
		let mouse = canvas.mouse;
		let pinRadius = 5.5f * zoom;
		for (let node in mGraph.nodes)
		{
			let min = canvas.ToScreen(node.position);
			let max = canvas.ToScreen(.(node.position.x + NodeWidth, node.position.y + NodeHeight(node)));
			NodeCanvas.DrawNode(min, max, CategoryColor(node.def.category), node.id == mGraphSelected, zoom);
			DrawNodePreview(canvas, node, min, max);
			if (zoom > 0.4f)
				ImGui.DrawText(.(min.x + 9 * zoom, min.y + 5 * zoom), .White, NodeGraph.Title(node, .. scope String()).CStr());
			if (canvas.hovered && mouse.x >= min.x && mouse.x <= max.x && mouse.y >= min.y && mouse.y <= max.y)
				hover.node = node;

			for (int side < 2)
			{
				let pins = side == 0 ? node.def.inputs : node.def.outputs;
				for (int32 i = 0; i < (int32)pins.Count; i++)
				{
					let center = canvas.ToScreen(PinPosition(node, i, side == 1));
					let pin = pins[i];
					let over = canvas.hovered && Math.Abs(mouse.x - center.x) < pinRadius * 2 && Math.Abs(mouse.y - center.y) < pinRadius * 2;
					if (over)
					{
						hover.node = node;
						hover.pin = i;
						hover.pinIsOutput = side == 1;
					}
					ImDrawList_AddCircleFilled(canvas.drawList, center, over ? pinRadius * 1.4f : pinRadius, PinColor(pin.type).ToABGR(), 12);
					if (zoom > 0.4f)
						DrawPinLabel(node, i, pin, side == 0, center, zoom);
				}
			}
		}
		return hover;
	}

	/// A pin's name, and for an input with nothing plugged in the value it takes instead.
	void DrawPinLabel(GraphNode node, int32 i, PinDef pin, bool input, ImGui.Vec2 center, float zoom)
	{
		let label = scope String(pin.name);
		if (input && pin.type != .Flow)
		{
			bool connected = false;
			for (let link in mGraph.links)
				connected |= link.toNode == node.id && link.toPin == i;
			// An object pin with nothing plugged in uses this object's own, or nothing.
			if (!connected && pin.type == .Object)
				label.AppendF("{}{}", label.IsEmpty ? "" : ": ", NodeLibrary.IsSelf(pin) ? "self" : "none");
			else if (!connected)
				label.AppendF("{}{}", label.IsEmpty ? "" : ": ", node.values[i]);
		}
		if (label.IsEmpty)
			return;
		let textX = input ? center.x + 10 * zoom : center.x - 10 * zoom - ImGui.CalcTextSize(label.CStr()).x;
		ImGui.DrawText(.(textX, center.y - 8 * zoom), .(0.85f, 0.85f, 0.85f, 1), label.CStr());
	}

	/// The mouse on the canvas: into a subgraph, linking pins (dragging a link's end off an input moves or removes
	/// it; right-click or Alt-click on a pin, or right-click or Delete on a link, disconnects), selecting and
	/// dragging nodes, deleting the selected one, and the right-click menu of nodes to add.
	void HandleGraphMouse(CanvasView canvas, GraphHover hover)
	{
		let hovered = canvas.hovered;
		let graphMouse = canvas.GraphMouse;
		if (hovered && ImGui.IsMouseDoubleClicked(0) && hover.node != null && hover.pin < 0 && (hover.node.def.key.StartsWith("sub:") || hover.node.def.key.StartsWith("shsub:")))
		{
			// Step into the subgraph behind this node; Back returns here.
			Assets.ResolvePath(hover.node.def.key.Substring(hover.node.def.key.IndexOf(':') + 1), mPendingGraph);
			mGraphBack.Add(new String(mGraphPath));
			mGraphStepping = true;
		}
		if (hovered && hover.node != null && hover.pin < 0 && !mLinking && hover.node.def.key.StartsWith("sub:"))
			ImGui.SetTooltip("Double-click to open this subgraph");
		// A link is only under the mouse where no node is.
		if (hover.node != null)
			mGraphHoverLink = -1;
		if (hovered && ImGui.IsMouseClicked(0))
		{
			let alt = ImGui.IsKeyDown(ImGui.Key.LeftAlt) || Input.GetKey(.LeftAlt);
			if (hover.pin >= 0 && !ImGui.IsKeyDown(ImGui.Key.LeftCtrl) && alt)
				mGraph.DisconnectPin(hover.node.id, hover.pin, !hover.pinIsOutput);
			else if (hover.pin >= 0 && !hover.pinIsOutput && PickUpLink(hover.node.id, hover.pin))
			{
				// Dragging from an input that has a link moves that link's end.
			}
			else if (hover.pin >= 0)
			{
				mLinking = true;
				mLinkDetached = false;
				mLinkNode = hover.node.id;
				mLinkPin = hover.pin;
				mLinkFromOutput = hover.pinIsOutput;
			}
			else if (hover.node != null)
			{
				mGraphSelected = hover.node.id;
				mGraphDragNode = hover.node.id;
				mCommentSelected = -1;
			}
			else if (mCommentHover >= 0 && mGraphHoverLink < 0)
			{
				// A comment box: drag it (and what is in it), or its corner to resize; double-click to rename.
				mCommentSelected = mCommentHover;
				mGraphSelected = 0;
				StartCommentDrag(mCommentHover, mCommentHoverCorner);
				if (ImGui.IsMouseDoubleClicked(0))
					mCommentFocus = true;
			}
			else
			{
				mGraphSelected = 0;
				mCommentSelected = -1;
			}
		}
		DragComment(canvas.zoom);
		// C adds a comment box (around the selected node), as in Unreal.
		if (hovered && ImGui.IsKeyPressed(ImGui.Key.C) && (ImGui.tn_imgui_capture_flags() & 4) == 0 && !ImGui.IsKeyDown(ImGui.Key.LeftCtrl))
			AddComment(graphMouse);
		if (mLinking)
			DragLink(canvas, hover, graphMouse);
		if (mGraphDragNode != 0)
		{
			let dragged = mGraph.Find(mGraphDragNode);
			if (dragged != null && ImGui.IsMouseDown(0))
				dragged.position = dragged.position + Input.MouseDelta / canvas.zoom;
			else
				mGraphDragNode = 0;
		}
		if (hovered && ImGui.IsKeyPressed(ImGui.Key.Delete) && (ImGui.tn_imgui_capture_flags() & 4) == 0 && mGraphHoverLink >= 0)
		{
			mGraph.links.RemoveAt(mGraphHoverLink);
			mGraphHoverLink = -1;
		}
		else if (hovered && ImGui.IsKeyPressed(ImGui.Key.Delete) && (ImGui.tn_imgui_capture_flags() & 4) == 0 && mCommentSelected >= 0 && mCommentSelected < mGraph.comments.Count)
		{
			// Deleting a comment box leaves its nodes.
			delete mGraph.comments[mCommentSelected];
			mGraph.comments.RemoveAt(mCommentSelected);
			mCommentSelected = -1;
		}
		else if (hovered && ImGui.IsKeyPressed(ImGui.Key.Delete) && (ImGui.tn_imgui_capture_flags() & 4) == 0)
		{
			let selected = mGraph.Find(mGraphSelected);
			if (selected != null)
				mGraph.RemoveNode(selected);
			mGraphSelected = 0;
		}
		// Right-click on a link, or on a pin with links, disconnects it; elsewhere it opens the node search.
		if (hovered && ImGui.IsMouseClicked(1) && hover.pin >= 0 && PinHasLinks(hover.node.id, hover.pin, !hover.pinIsOutput))
			mGraph.DisconnectPin(hover.node.id, hover.pin, !hover.pinIsOutput);
		else if (hovered && ImGui.IsMouseClicked(1) && mGraphHoverLink >= 0)
		{
			mGraph.links.RemoveAt(mGraphHoverLink);
			mGraphHoverLink = -1;
		}
		else if (hovered && ImGui.IsMouseClicked(1))
		{
			// Pick up subgraphs created or changed since the list was last built.
			NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
			mGraph.Validate();
			OpenNodeSearch(graphMouse, false);
		}
	}

	bool PinHasLinks(int32 nodeId, int32 pin, bool isInput)
	{
		for (let link in mGraph.links)
		{
			if (isInput ? (link.toNode == nodeId && link.toPin == pin) : (link.fromNode == nodeId && link.fromPin == pin))
				return true;
		}
		return false;
	}

	/// Takes the (last) link into an input off it and carries on dragging it from its output. False if the input
	/// has none.
	bool PickUpLink(int32 nodeId, int32 pin)
	{
		for (int i = mGraph.links.Count - 1; i >= 0; i--)
		{
			let link = mGraph.links[i];
			if (link.toNode != nodeId || link.toPin != pin)
				continue;
			mGraph.links.RemoveAt(i);
			mLinking = true;
			mLinkDetached = true;
			mLinkNode = link.fromNode;
			mLinkPin = link.fromPin;
			mLinkFromOutput = true;
			return true;
		}
		return false;
	}

	/// A link being dragged out of a pin: drawn to the mouse, and on release connected to the pin it was dropped on
	/// (of the other direction and a type that fits), or offered the nodes that can take it if dropped on nothing.
	void DragLink(CanvasView canvas, GraphHover hover, Vector2 graphMouse)
	{
		let source = mGraph.Find(mLinkNode);
		if (source != null)
		{
			let start = canvas.ToScreen(PinPosition(source, mLinkPin, mLinkFromOutput));
			if (mLinkFromOutput)
				canvas.DrawLink(start, canvas.mouse, .(1, 1, 1, 0.8f));
			else
				canvas.DrawLink(canvas.mouse, start, .(1, 1, 1, 0.8f));
		}
		if (ImGui.IsMouseDown(0))
			return;
		if (source != null && hover.pin >= 0 && hover.node.id != mLinkNode && hover.pinIsOutput != mLinkFromOutput)
		{
			let output = mLinkFromOutput ? source : hover.node;
			let outputPin = mLinkFromOutput ? mLinkPin : hover.pin;
			let input = mLinkFromOutput ? hover.node : source;
			let inputPin = mLinkFromOutput ? hover.pin : mLinkPin;
			// A node with versions for other types (Add, Print, Split...) switches to the one that fits.
			if (!mGraph.TryConnect(output, outputPin, input, inputPin))
				mGraphStatus.Set("Those pins have different types.");
		}
		else if (source != null && canvas.hovered && hover.node == null && !mLinkDetached)
			OpenNodeSearch(graphMouse, true);
		mLinking = false;
		mLinkDetached = false;
	}

	/// The add-node menu: browsing by category with nothing typed, else the nodes whose names match as you type.
	void DrawNodeSearch(CanvasView canvas)
	{
		if (mOpenNodeSearch)
		{
			ImGui.OpenPopup("AddNode");
			mOpenNodeSearch = false;
			mNodeSearchFocus = true;
		}
		if (!ImGui.BeginPopup("AddNode"))
			return;
		if (mNodeSearchFocus)
		{
			ImGui.SetKeyboardFocusHere();
			mNodeSearchFocus = false;
		}
		ImGui.SetNextItemWidth(260);
		ImGui.InputText("##nodesearch", mNodeSearch, 0, mSearchForLink ? "Search nodes that fit this pin" : "Search nodes");
		let chosen = (mNodeSearch.IsEmpty && !mSearchForLink) ? BrowseNodes() : MatchingNodes(ImGui.IsKeyPressed(ImGui.Key.Enter));
		if (chosen != null)
		{
			let created = mGraph.AddNode(chosen, mNewNodePosition);
			mGraphSelected = created.id;
			if (mSearchForLink)
			{
				// Finish the link that was dragged out to open this search.
				let pin = FirstCompatiblePin(chosen);
				let source = mGraph.Find(mLinkNode);
				if (pin >= 0 && source != null && mLinkFromOutput)
					mGraph.TryConnect(source, mLinkPin, created, pin);
				else if (pin >= 0 && source != null)
					mGraph.TryConnect(created, pin, source, mLinkPin);
			}
			ImGui.CloseCurrentPopup();
		}
		ImGui.EndPopup();
	}

	/// One level of the add-node menu: its submenus and the nodes listed in it.
	class NodeMenu
	{
		public String name = new .() ~ delete _;
		public List<NodeMenu> menus = new .() ~ DeleteContainerAndItems!(_);
		public List<NodeDef> items = new .() ~ delete _;
		/// Lists only nodes read from source (an engine or game class), so it goes after the hand-made submenus.
		public bool fromSource = true;

		public NodeMenu Child(StringView childName)
		{
			for (let menu in menus)
			{
				if (menu.name == childName)
					return menu;
			}
			let menu = new NodeMenu();
			menu.name.Set(childName);
			menus.Add(menu);
			return menu;
		}
	}

	NodeMenu mNodeMenu ~ delete _;
	int mNodeMenuCount = -1;
	bool mNodeMenuShader;

	/// The menu tree, built again when nodes were added (a script reload) or the graph kind changed.
	NodeMenu NodeMenuTree()
	{
		let defs = NodeLibrary.Defs;
		if (mNodeMenu != null && mNodeMenuCount == defs.Count && mNodeMenuShader == mGraph.isShader)
			return mNodeMenu;
		delete mNodeMenu;
		mNodeMenu = new NodeMenu();
		mNodeMenuCount = defs.Count;
		mNodeMenuShader = mGraph.isShader;
		for (let def in defs)
		{
			if (def.isShader != mGraph.isShader || def.hidden)
				continue;
			var menu = mNodeMenu;
			for (let part in def.category.Split('|'))
			{
				menu = menu.Child(part);
				menu.fromSource &= def.fromApi;
			}
			menu.items.Add(def);
		}
		// Top-level categories in Unreal's order (the rest keep the order they were made in).
		let order = scope List<(int rank, int index, NodeMenu menu)>();
		for (int i < mNodeMenu.menus.Count)
			order.Add((NodeLibrary.CategoryRank(mNodeMenu.menus[i].name), i, mNodeMenu.menus[i]));
		order.Sort(scope (a, b) => a.rank != b.rank ? a.rank <=> b.rank : a.index <=> b.index);
		for (int i < order.Count)
			mNodeMenu.menus[i] = order[i].menu;
		return mNodeMenu;
	}

	/// Nothing typed: every node in nested menus by category, as Unreal's Blueprint menu has them ("Math", then
	/// "Float", then the nodes). Nodes read from the engine's source sit in their area's category, under their class;
	/// the game's own scripts are under My Scripts. Returns the node chosen, or null.
	NodeDef BrowseNodes()
	{
		NodeDef chosen = null;
		if (ImGui.MenuItem("Add Comment", "C"))
		{
			AddComment(mNewNodePosition);
			ImGui.CloseCurrentPopup();
		}
		if (!mGraph.isShader && ImGui.MenuItem("New Subgraph Here"))
		{
			AddNewSubgraphNode(mNewNodePosition);
			ImGui.CloseCurrentPopup();
		}
		ImGui.Separator();
		for (let menu in NodeMenuTree().menus)
			chosen = DrawNodeMenu(menu) ?? chosen;
		return chosen;
	}

	NodeDef DrawNodeMenu(NodeMenu menu)
	{
		if (!ImGui.BeginMenu(menu.name.CStr()))
			return null;
		NodeDef chosen = null;
		for (let def in menu.items)
		{
			if (IsThisGraph(def) || (mSearchForLink && FirstCompatiblePin(def) < 0))
				continue;
			// Inside a class's menu its name is not repeated on every entry.
			var title = (StringView)def.title;
			if (title.StartsWith(menu.name) && title.Length > menu.name.Length + 2 && title[menu.name.Length] == ':')
				title = title.Substring(menu.name.Length + 2);
			if (ImGui.MenuItem(scope String(title).CStr()))
				chosen = def;
		}
		// Hand-made submenus, then (after a line) those of classes read from source.
		bool any = !menu.items.IsEmpty;
		for (int pass < 2)
		{
			bool separated = false;
			for (let sub in menu.menus)
			{
				if (sub.fromSource != (pass == 1))
					continue;
				if (pass == 1 && any && !separated)
				{
					ImGui.Separator();
					separated = true;
				}
				chosen = DrawNodeMenu(sub) ?? chosen;
				any = true;
			}
		}
		ImGui.EndMenu();
		return chosen;
	}

	/// Whether typed text finds a node: in its title, its other names (Unreal's among them) or its category.
	static bool Finds(NodeDef def, StringView text) => def.title.Contains(text, true) || def.keywords.Contains(text, true) || def.category.Contains(text, true);

	/// Typed text narrows the list as you type: names that start with it come first, and Enter takes the top one.
	NodeDef MatchingNodes(bool enter)
	{
		NodeDef chosen = null;
		ImGui.BeginChild("matches", .(260, 240));
		int shown = 0;
		for (int pass < 2)
		{
			for (let def in NodeLibrary.Defs)
			{
				if (def.isShader != mGraph.isShader || def.hidden || IsThisGraph(def) || (mSearchForLink && FirstCompatiblePin(def) < 0))
					continue;
				let starts = mNodeSearch.IsEmpty || def.title.StartsWith(mNodeSearch, .OrdinalIgnoreCase);
				let contains = Finds(def, mNodeSearch);
				if ((pass == 0 && !starts) || (pass == 1 && (starts || !contains)))
					continue;
				let label = scope String();
				label.AppendF("{}   ({})", def.title, def.category);
				label.Replace("|", " > ");
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

	/// The selected node's input values, in a panel at the canvas's top left.
	void DrawSelectedNodeValues(CanvasView canvas)
	{
		let selectedNode = mGraph.Find(mGraphSelected);
		if (selectedNode == null)
			return;
		int editable = 0;
		for (let pin in selectedNode.def.inputs)
			editable += pin.type != .Flow ? 1 : 0;
		if (editable == 0)
			return;
		ImGui.SetCursorScreenPos(.(canvas.origin.x + 10, canvas.origin.y + 10));
		ImGui.PushStyleColor(ImGui.Col.ChildBg, EditorTheme.Canvas);
		ImGui.BeginChild("values", .(250, 34 + editable * 27), ImGui.ChildBorders);
		ImGui.Text(NodeGraph.Title(selectedNode, .. scope String()));
		for (int32 i = 0; i < (int32)selectedNode.def.inputs.Count; i++)
		{
			let pin = selectedNode.def.inputs[i];
			if (pin.type == .Flow)
				continue;
			ImGui.PushID(i);
			ImGui.SetNextItemWidth(150);
			EditPinValue(pin, selectedNode.values[i]);
			ImGui.SameLine();
			ImGui.Text(pin.name.IsEmpty ? (StringView)"Value" : pin.name);
			ImGui.PopID();
		}
		ImGui.EndChild();
		ImGui.PopStyleColor();
	}

	/// The field for an input's value, as fits its type.
	static void EditPinValue(PinDef pin, String value)
	{
		switch (pin.type)
		{
		case .Bool:
			bool on = value == "true";
			if (ImGui.Checkbox("##v", ref on))
				value.Set(on ? "true" : "false");
		case .Int:
			int32 number = (int32)SceneSerializer.ParseFloat(value);
			if (ImGui.InputInt("##v", ref number))
				value..Clear().AppendF("{}", number);
		case .Enum:
			let entry = pin.typeName != null ? ApiIndex.Find(pin.typeName) : null;
			if (value.IsEmpty && entry != null && entry.members.Count > 0)
				value.Set(entry.members[0]);
			if (ImGui.BeginCombo("##v", value.CStr()))
			{
				if (entry != null)
				{
					for (let name in entry.members)
					{
						if (ImGui.Selectable(name.CStr(), name == value))
							value.Set(name);
					}
				}
				ImGui.EndCombo();
			}
		case .Color:
			Color color = .(1, 1, 1, 1);
			var parts = value.Split(' ', .RemoveEmptyEntries);
			float* channels = &color.r;
			for (int k < 4)
			{
				if (parts.GetNext() case .Ok(let part))
					channels[k] = SceneSerializer.ParseFloat(part);
			}
			if (ImGui.ColorEdit4("##v", ref color))
				value..Clear().AppendF("{} {} {} {}", color.r, color.g, color.b, color.a);
		case .Object:
			ImGui.TextDisabled(NodeLibrary.IsSelf(pin) ? "this object's own" : "connect a value");
		default:
			ImGui.InputText("##v", value, 0, pin.type == .Vector3 || pin.type == .Quaternion ? (char8*)"x y z" : (pin.type == .Vector2 ? (char8*)"x y" : (char8*)""));
		}
	}

	/// The Variables panel: each variable becomes a public field of the compiled component, so its default set here
	/// can be changed per object in the Inspector. Get and Set place nodes that read and write it.
	void DrawGraphVariables(ImGui.Vec2 topRight, Vector2 nodePosition)
	{
		const float VariablesWidth = 470;
		ImGui.SetCursorScreenPos(.(topRight.x - VariablesWidth, topRight.y));
		ImGui.PushStyleColor(ImGui.Col.ChildBg, EditorTheme.Canvas);
		ImGui.BeginChild("variables", .(VariablesWidth, 62 + Math.Min(mGraph.variables.Count, 8) * 27), ImGui.ChildBorders);
		ImGui.Text("Variables");
		ImGui.SameLine();
		if (ImGui.SmallButton("+ Add"))
			mGraph.AddVariable("variable", .Float);
		GraphVariable removed = null;
		for (int i < mGraph.variables.Count)
		{
			let variable = mGraph.variables[i];
			ImGui.PushID((int32)i);
			let name = mVariableEditing == i ? mVariableEdit : scope String(variable.name);
			ImGui.SetNextItemWidth(110);
			if (ImGui.InputText("##name", name) && mVariableEditing != i)
			{
				mVariableEdit.Set(name);
				mVariableEditing = i;
			}
			if (mVariableEditing == i && ImGui.IsItemDeactivatedAfterEdit())
			{
				if (!mGraph.RenameVariable(variable, mVariableEdit))
					mGraphStatus.Set("That variable name is already in use.");
				mVariableEditing = -1;
			}
			ImGui.SameLine();
			ImGui.SetNextItemWidth(84);
			if (ImGui.BeginCombo("##type", TypeLabel(variable.type)))
			{
				for (let type in NodeGraph.VariableTypes)
				{
					if (ImGui.Selectable(TypeLabel(type), type == variable.type))
						mGraph.SetVariableType(variable, type);
				}
				ImGui.EndCombo();
			}
			ImGui.SameLine();
			if (variable.type == .Object)
			{
				// What it refers to; the object itself is picked per object in the Inspector.
				ImGui.SetNextItemWidth(100);
				if (ImGui.BeginCombo("##refers", variable.typeName.CStr()))
				{
					ImGui.SetNextItemWidth(-1);
					ImGui.InputText("##filter", mReferenceFilter, 0, "Search types");
					if (mReferenceTypes == null)
						mReferenceTypes = NodeLibrary.ReferenceTypes(.. new .());
					for (let typeName in mReferenceTypes)
					{
						if (!mReferenceFilter.IsEmpty && !typeName.Contains(mReferenceFilter, true))
							continue;
						if (ImGui.Selectable(typeName.CStr(), typeName == variable.typeName))
							mGraph.SetVariableType(variable, .Object, typeName);
					}
					ImGui.EndCombo();
				}
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("What it refers to. Pick the object for it per object in the Inspector.");
				ImGui.SameLine(322);
			}
			else if (variable.type == .Bool)
			{
				bool value = variable.value == "true";
				if (ImGui.Checkbox("##default", ref value))
					variable.value.Set(value ? "true" : "false");
				ImGui.SameLine(322);
			}
			else
			{
				ImGui.SetNextItemWidth(100);
				char8* hint = "default";
				switch (variable.type)
				{
				case .Vector3: hint = "x y z";
				case .Vector2: hint = "x y";
				case .Quaternion: hint = "pitch yaw roll";
				case .Color: hint = "r g b a";
				default:
				}
				ImGui.InputText("##default", variable.value, 0, hint);
				ImGui.SameLine();
			}
			if (variable.type == .Object)
				ImGui.Dummy(.(ImGui.GetFrameHeight(), ImGui.GetFrameHeight()));
			else
			{
				ImGui.Checkbox("##net", ref variable.networked);
				if (ImGui.IsItemHovered())
					ImGui.SetTooltip("Networked: in multiplayer the server's value is copied to every client.");
			}
			ImGui.SameLine();
			if (ImGui.SmallButton("Get"))
				mGraphSelected = mGraph.AddVariableNode(variable, false, nodePosition).id;
			ImGui.SameLine();
			if (ImGui.SmallButton("Set"))
				mGraphSelected = mGraph.AddVariableNode(variable, true, nodePosition).id;
			ImGui.SameLine();
			if (ImGui.SmallButton("x"))
				removed = variable;
			ImGui.PopID();
		}
		if (removed != null)
		{
			mGraph.RemoveVariable(removed);
			mVariableEditing = -1;
		}
		ImGui.TextDisabled(mGraph.variables.IsEmpty ? "Values you can set per object in the Inspector." : "Defaults; set per object in the Inspector.");
		ImGui.EndChild();
		ImGui.PopStyleColor();
	}

	static char8* TypeLabel(PinType type) => NodeLibrary.TypeLabel(type).Ptr;

	List<String> mReferenceTypes ~ DeleteContainerAndItems!(_);
	String mReferenceFilter = new .() ~ delete _;
}
