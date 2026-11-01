using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// Writes the .tshader file a shader graph stands for, or the .tcompute file of a compute graph (one ending in a
/// Compute Output node). Each node is worked out once, into a local of its own ("vec3 n12 = ...;"), before the nodes
/// that read it, so a node feeding several others costs once. A subgraph's nodes are written in place inside the
/// graph that uses it, their locals named after the node standing for it. For the editor's previews it can also work
/// out every node and show the one u_surface.w picks, unlit; a compute graph's preview instead fills a grid of
/// PreviewCell-pixel cells, one node in each, when u_surface.x (its columns) is above 0.
class ShaderGraphCode
{
	/// A graph being written: the graph, the start of its locals' names, and for a subgraph the node using it.
	class Frame
	{
		public NodeGraph graph;
		public String prefix = new .() ~ delete _;
		public Frame host;
		public GraphNode hostNode;
	}

	/// The deepest subgraphs go inside one another.
	const int MaxSubgraphDepth = 12;

	/// The value of u_surface.w that shows each node in a preview, by node id (from 1; 0 is the surface itself). For a
	/// compute graph, the cell of the preview's grid, counted across from the top left.
	public Dictionary<int32, int32> previewSlots = new .() ~ delete _;
	/// Whether the graph written was a compute graph (a .tcompute file).
	public bool isCompute;
	/// The width and height in pixels of one cell of a compute graph's preview grid.
	public const int32 PreviewCell = 128;
	/// Mistakes found while writing, one message per line.
	public String problems = new .() ~ delete _;

	String mCode = new .() ~ delete _;
	HashSet<String> mDone = new .() ~ DeleteContainerAndItems!(_);
	HashSet<String> mBusy = new .() ~ DeleteContainerAndItems!(_);
	Dictionary<String, NodeGraph> mSubgraphs = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	List<Frame> mFrames = new .() ~ DeleteContainerAndItems!(_);
	bool mVertex;

	public static StringView GlslType(PinType type) => type == .Float ? "float" : (type == .Vector2 ? "vec2" : (type == .Vector3 ? "vec3" : "vec4"));

	static StringView Zero(PinType type) => type == .Float ? "0.0" : (type == .Vector2 ? "vec2_splat(0.0)" : (type == .Vector3 ? "vec3_splat(0.0)" : "vec4_splat(0.0)"));

	/// Whether a node needs a surface being drawn (its position, normal, material or camera), which a compute graph
	/// does not have.
	public static bool SurfaceOnly(StringView key)
	{
		for (let surfaceOnly in sSurfaceOnly)
		{
			if (key == surfaceOnly)
				return true;
		}
		return false;
	}

	static StringView[?] sSurfaceOnly = .("shader.worldpos", "shader.worldnormal", "shader.vertexcolor", "shader.basealbedo", "shader.basealpha", "shader.prop.texture",
		"shader.maintexture", "shader.fresnel", "shader.viewdir", "shader.triplanar", "shader.prop.normal", "shader.normalheight", "shader.objectpos", "shader.objectnormal");

	/// Whether a graph is a compute graph: it ends in a Compute Output node, or (a subgraph) uses compute inputs.
	public static bool IsComputeGraph(NodeGraph graph)
	{
		for (let node in graph.nodes)
		{
			if (node.def.key.StartsWith("shader.compute."))
				return true;
		}
		return false;
	}

	/// The file a shader graph saves as, beside it: ".tcompute" for a compute graph, ".tshader" for the rest.
	public static StringView FileExtension(NodeGraph graph)
	{
		for (let node in graph.nodes)
		{
			if (node.def.key == "shader.compute.output")
				return ".tcompute";
		}
		return ".tshader";
	}

	/// Whether a node is a shader subgraph's output (it has an input for each of the subgraph's results).
	public static bool IsSubgraphOutput(GraphNode node) => node.def.key.StartsWith("shader.sub.output.");

	/// Whether a graph is a shader subgraph: it has Subgraph Output nodes.
	public static bool IsSubgraph(NodeGraph graph)
	{
		for (let node in graph.nodes)
		{
			if (IsSubgraphOutput(node))
				return true;
		}
		return false;
	}

	void Problem(StringView message)
	{
		if (!problems.Contains(message))
			problems..Append(message).Append('\n');
	}

	/// Writes the shader file text. With `preview`, every node is worked out as well, and when u_surface.w is above 0
	/// the surface shows one of them, unlit (previewSlots says which). A subgraph only makes a preview: its first
	/// output as the colour.
	public bool Write(NodeGraph graph, String text, bool preview)
	{
		let top = new Frame();
		top.graph = graph;
		mFrames.Add(top);
		GraphNode output = null;
		GraphNode firstResult = null;
		for (let node in graph.nodes)
		{
			if (node.def.kind == .ShaderOutput)
			{
				if (output != null)
				{
					Problem("A shader graph has one output node (Surface Output or Compute Output); this one has more.");
					return false;
				}
				output = node;
			}
			else if (firstResult == null && IsSubgraphOutput(node))
				firstResult = node;
		}
		if (output == null && (firstResult == null || !preview))
		{
			Problem(firstResult != null ? "A subgraph is used inside other shader graphs, not as a shader of its own." : "Add a Surface Output node (or Compute Output, for a compute shader) and connect something to it.");
			return false;
		}
		isCompute = (output != null) ? (output.def.key == "shader.compute.output") : IsComputeGraph(graph);
		text.Append("// Generated from a shader graph by the Tallow editor.\n// Edit the graph and save it again; changes made here are overwritten.\n");
		WriteProperties(graph, text);
		if (isCompute)
		{
			WriteCompute(top, output ?? firstResult, output == null, preview, text);
			return problems.IsEmpty;
		}

		// Which output-node input is which, by position: see NodeLibrary's "shader.output".
		bool Connected(int32 pin) => output != null && graph.[Friend]FindLinkTo(output.id, pin, let ignored);
		mVertex = false;
		if (output != null)
		{
			Assign(top, output, 0, "\talbedo = toLinear3({});\n", Connected(0));
			Assign(top, output, 1, "\talpha = {};\n", Connected(1));
			Assign(top, output, 2, "\tmetallic = {};\n", Connected(2));
			Assign(top, output, 3, "\troughness = {};\n", Connected(3));
			Assign(top, output, 4, "\temissive += toLinear3({});\n", Connected(4));
			Assign(top, output, 6, "\tsurfaceNormal = normalize({});\n", Connected(6));
			Assign(top, output, 7, "\tocclusion = {};\n", Connected(7));
		}
		else
			Assign(top, firstResult, 1, "\talbedo = toLinear3({});\n", true, .Vector3);
		if (preview)
			WritePreviews(top);
		text.AppendF("\nsurface {{\n{}}}\n", mCode);

		if (Connected(5))
		{
			mVertex = true;
			ClearAndDeleteItems!(mDone);
			mCode.Clear();
			Assign(top, output, 5, "\tposition += {};\n", true);
			text.AppendF("\nvertex {{\n{}}}\n", mCode);
		}
		return problems.IsEmpty;
	}

	/// A compute graph's compute block: the Compute Output's colour (or a subgraph's first output) as the result.
	void WriteCompute(Frame top, GraphNode output, bool subgraph, bool preview, String text)
	{
		if (preview)
		{
			// The editor's preview grid: each cell stands for the whole texture (the one bound as previous), seen
			// through one node.
			mCode.AppendF("\tivec2 tsgCell = pixel / {};\n\tif (u_surface.x > 0.5)\n\t{{\n", PreviewCell);
			mCode.Append("\t\tsize = ivec2(textureSize(s_previous, 0));\n");
			mCode.AppendF("\t\tuv = (vec2(pixel - tsgCell * {0}) + vec2_splat(0.5)) / {0}.0;\n", PreviewCell);
			mCode.Append("\t\tpixel = ivec2(uv * vec2(size));\n\t\tresult = previous(uv);\n\t}\n");
		}
		if (subgraph)
			Assign(top, output, 1, "\tresult = {};\n", true, .Color);
		else
			Assign(top, output, 0, "\tresult = {};\n", top.graph.[Friend]FindLinkTo(output.id, 0, let ignored));
		if (preview)
			WritePreviews(top);
		text.AppendF("\ncompute {{\n{}}}\n", mCode);
	}

	/// One line setting a surface value from what reaches an input of the output node.
	void Assign(Frame frame, GraphNode node, int32 pin, StringView line, bool connected, PinType type = .Float)
	{
		if (!connected || pin >= node.def.inputs.Count)
			return;
		let value = scope String();
		Input(frame, node, pin, value);
		let converted = scope String();
		if (type != .Float)
			NodeGraph.ShaderConvert(node.def.inputs[pin].type, type, value, converted);
		else
			converted.Append(value);
		mCode.AppendF(line, converted);
	}

	/// A property line for each Property node, in the graph and in every subgraph it uses. A name used twice is
	/// one property.
	void WriteProperties(NodeGraph graph, String text)
	{
		List<String> declared = scope .();
		List<NodeGraph> graphs = scope .();
		defer
		{
			for (let d in declared)
				delete d;
		}
		graphs.Add(graph);
		for (int g = 0; g < graphs.Count && g < 64; g++)
		{
			for (let node in graphs[g].nodes)
			{
				if (node.def.key.StartsWith("shsub:"))
				{
					let sub = Subgraph(node.def.key.Substring(6));
					if (sub != null && !graphs.Contains(sub))
						graphs.Add(sub);
					continue;
				}
				if (!node.def.key.StartsWith("shader.prop."))
					continue;
				let name = scope String();
				NodeLibrary.Identifier(node.values[0].IsEmpty ? (StringView)"value" : node.values[0], name);
				if (declared.ContainsAlt(name))
					continue;
				declared.Add(new String(name));
				if (node.def.key == "shader.prop.float")
				{
					text.AppendF("property float {} = ", name);
					NodeGraph.GlslNumber(SceneSerializer.ParseFloat(node.values[1]), text);
					text.Append('\n');
				}
				else if (node.def.key == "shader.prop.color")
					text.AppendF("property color {} = {}\n", name, node.values[1].IsEmpty ? (StringView)"1 1 1 1" : node.values[1]);
				else if (isCompute)
					Problem("A compute graph cannot have texture properties: it reads only its own texture (Previous).");
				else
					text.AppendF("property texture {}\n", name);
			}
		}
	}

	/// Works out every node of the graph that can be shown, and picks the one u_surface.w names.
	void WritePreviews(Frame top)
	{
		let choose = scope String();
		int32 slot = 1;
		for (let node in top.graph.nodes)
		{
			if (node.def.outputs.IsEmpty || node.def.kind == .ShaderOutput || VertexOnly(top.graph, node, 0))
				continue;
			// Nodes that cannot work in this kind of graph say so when they are used; unused, they show nothing.
			if (isCompute ? SurfaceOnly(node.def.key) : node.def.key.StartsWith("shader.compute."))
				continue;
			let value = scope String();
			Output(top, node, 0, value);
			let shown = scope String();
			NodeGraph.ShaderConvert(node.def.outputs[0].type, .Color, value, shown);
			if (isCompute)
				choose.AppendF("\t\t{}if (tsgSlot == {})\n\t\t\tshown = {};\n", slot > 1 ? "else " : "", slot, shown);
			else
				choose.AppendF("\t\t{}if (u_surface.w < {}.5)\n\t\t\tshown = {};\n", slot > 1 ? "else " : "", slot, shown);
			previewSlots[node.id] = slot++;
		}
		if (isCompute)
		{
			mCode.Append("\tif (u_surface.x > 0.5)\n\t{\n\t\tint tsgSlot = tsgCell.y * int(u_surface.x) + tsgCell.x;\n\t\tvec4 shown = result;\n");
			mCode.AppendF("{}\t\tresult = vec4(shown.rgb, 1.0);\n\t}}\n", choose);
			return;
		}
		if (choose.IsEmpty)
			return;
		mCode.AppendF("\tif (u_surface.w > 0.5)\n\t{{\n\t\tvec4 shown = vec4(0.0, 0.0, 0.0, 1.0);\n{}", choose);
		mCode.Append("\t\talbedo = toLinear3(shown.rgb);\n\t\talpha = 1.0;\n\t\temissive = vec3_splat(0.0);\n\t\tsurfaceNormal = vec3(0.0, 0.0, 1.0);\n\t}\n");
	}

	/// Whether a node needs the mesh's own position or normal, which only the vertex block has.
	bool VertexOnly(NodeGraph graph, GraphNode node, int depth)
	{
		if (depth > 64)
			return false;
		if (node.def.key == "shader.objectpos" || node.def.key == "shader.objectnormal")
			return true;
		if (node.def.key.StartsWith("shsub:"))
		{
			let sub = Subgraph(node.def.key.Substring(6));
			if (sub != null && depth < MaxSubgraphDepth)
			{
				for (let inner in sub.nodes)
				{
					if (VertexOnly(sub, inner, depth + 1))
						return true;
				}
			}
		}
		for (let link in graph.links)
		{
			if (link.toNode != node.id)
				continue;
			let source = graph.Find(link.fromNode);
			if (source != null && VertexOnly(graph, source, depth + 1))
				return true;
		}
		return false;
	}

	/// A subgraph by project path, loaded once.
	NodeGraph Subgraph(StringView path)
	{
		if (mSubgraphs.TryGetValueAlt(path, let loaded))
			return loaded;
		let full = scope String();
		Assets.ResolvePath(path, full);
		var graph = new NodeGraph();
		graph.isShader = true;
		if (!graph.Load(full))
			DeleteAndNullify!(graph);
		else
			graph.Validate();
		mSubgraphs[new String(path)] = graph;
		return graph;
	}

	/// The value arriving at an input: what is linked to it, made to fit, or the value typed into it.
	void Input(Frame frame, GraphNode node, int32 pin, String code)
	{
		let wanted = node.def.inputs[pin];
		if (frame.graph.[Friend]FindLinkTo(node.id, pin, let link))
		{
			let source = frame.graph.Find(link.fromNode);
			if (source != null && link.fromPin < source.def.outputs.Count)
			{
				let value = scope String();
				Output(frame, source, link.fromPin, value);
				NodeGraph.ShaderConvert(source.def.outputs[link.fromPin].type, wanted.type, value, code);
				return;
			}
		}
		NodeGraph.ShaderLiteral(wanted, node.values[pin], code);
	}

	/// One output of a node, which is written first if it has not been.
	void Output(Frame frame, GraphNode node, int32 pin, String code)
	{
		let local = scope String();
		Emit(frame, node, local);
		let output = node.def.outputs[pin];
		if (node.def.key.StartsWith("shsub:"))
			code.AppendF("{}_{}", local, pin);
		else if (output.code != null)
			code.Append(scope String(output.code)..Replace("$V", local));
		else
			code.Append(local);
	}

	/// The type a node's local holds: its output's, or for a node with several outputs (each reading part of one
	/// value, "$V.x") the type of its first input.
	static PinType ValueType(GraphNode node)
	{
		if (node.def.outputs.IsEmpty)
			return .Float;
		if (node.def.outputs[0].code != null && !node.def.inputs.IsEmpty)
			return node.def.inputs[0].type;
		return node.def.outputs[0].type;
	}

	/// Writes a node's local (after everything it reads), once per block. `local` gets its name.
	void Emit(Frame frame, GraphNode node, String local)
	{
		local.AppendF("{}n{}", frame.prefix, node.id);
		if (mDone.ContainsAlt(local))
			return;
		if (mBusy.ContainsAlt(local))
		{
			Problem("Some of this shader graph's links go round in a circle: a node cannot read its own result.");
			return;
		}
		let key = node.def.key;
		if (isCompute && SurfaceOnly(key))
			Problem(scope $"{node.def.title} needs a surface being drawn, which a compute graph does not have.");
		else if (!isCompute && key.StartsWith("shader.compute."))
			Problem(scope $"{node.def.title} is for compute graphs (ending in a Compute Output node).");
		else if (!mVertex && (key == "shader.objectpos" || key == "shader.objectnormal"))
			Problem("Object Position and Object Normal are for the Vertex Offset input only.");
		mBusy.Add(new String(local));
		let statement = scope String();
		if (key.StartsWith("shader.sub.input."))
			EmitSubgraphInput(frame, node, local, statement);
		else if (key.StartsWith("shsub:"))
			EmitSubgraph(frame, node, local, statement);
		else if (key.StartsWith("shader.custom."))
			EmitCustom(frame, node, local, statement);
		else
		{
			let expression = scope String();
			Fill(frame, node, expression);
			statement.AppendF("\t{} {} = {};\n", GlslType(ValueType(node)), local, expression);
		}
		mCode.Append(statement);
		if (mBusy.GetAndRemoveAlt(local) case .Ok(let busy))
			delete busy;
		mDone.Add(new String(local));
	}

	/// The node's code with {0}, {1}... replaced by its inputs.
	void Fill(Frame frame, GraphNode node, String code)
	{
		let template = node.def.code;
		int i = 0;
		while (i < template.Length)
		{
			if (template[i] == '{')
			{
				int close = i + 1;
				while (close < template.Length && template[close].IsDigit)
					close++;
				if (close > i + 1 && close < template.Length && template[close] == '}')
				{
					let index = int.Parse(template.Substring(i + 1, close - i - 1)).GetValueOrDefault();
					if (index < node.def.inputs.Count)
						Input(frame, node, (int32)index, code);
					i = close + 1;
					continue;
				}
			}
			code.Append(template[i]);
			i++;
		}
	}

	/// A subgraph's input: inside a graph that uses the subgraph, what reaches that node's input of the same name;
	/// in the subgraph itself (its own preview), the Preview value.
	void EmitSubgraphInput(Frame frame, GraphNode node, StringView local, String statement)
	{
		let type = node.def.outputs[0].type;
		let value = scope String();
		int32 pin = -1;
		if (frame.hostNode != null)
		{
			let name = node.values[0].IsEmpty ? (StringView)"Value" : node.values[0];
			// The host's inputs are the subgraph's input nodes in order; the name decides, the place if it is not found.
			int32 place = 0;
			for (let other in frame.graph.nodes)
			{
				if (other == node)
					break;
				if (other.def.key.StartsWith("shader.sub.input."))
					place++;
			}
			let inputs = frame.hostNode.def.inputs;
			for (int32 i = 0; i < (int32)inputs.Count && pin < 0; i++)
			{
				if (inputs[i].name == name)
					pin = i;
			}
			if (pin < 0 && place < inputs.Count)
				pin = place;
		}
		if (pin >= 0)
		{
			let reaching = scope String();
			Input(frame.host, frame.hostNode, pin, reaching);
			NodeGraph.ShaderConvert(frame.hostNode.def.inputs[pin].type, type, reaching, value);
		}
		else
			Input(frame, node, 1, value);
		statement.AppendF("\t{} {} = {};\n", GlslType(type), local, value);
	}

	/// A node standing for a subgraph: the subgraph's nodes, written in place, and a local for each of its outputs
	/// ("<local>_0", "<local>_1"...).
	void EmitSubgraph(Frame frame, GraphNode node, StringView local, String statement)
	{
		let sub = Subgraph(node.def.key.Substring(6));
		int depth = 0;
		for (var f = frame; f.host != null; f = f.host)
			depth++;
		if (sub == null || depth >= MaxSubgraphDepth)
		{
			Problem(sub == null ? scope $"The subgraph {node.def.key.Substring(6)} could not be read." : "Subgraphs go inside one another too deeply (or use themselves).");
			for (int k < node.def.outputs.Count)
				statement.AppendF("\t{} {}_{} = {};\n", GlslType(node.def.outputs[k].type), local, k, Zero(node.def.outputs[k].type));
			return;
		}
		let inner = new Frame();
		inner.graph = sub;
		inner.prefix.AppendF("{}s{}_", frame.prefix, node.id);
		inner.host = frame;
		inner.hostNode = node;
		mFrames.Add(inner);
		int k = 0;
		for (let result in sub.nodes)
		{
			if (!IsSubgraphOutput(result) || k >= node.def.outputs.Count)
				continue;
			let value = scope String();
			Input(inner, result, 1, value);
			let converted = scope String();
			NodeGraph.ShaderConvert(result.def.inputs[1].type, node.def.outputs[k].type, value, converted);
			statement.AppendF("\t{} {}_{} = {};\n", GlslType(node.def.outputs[k].type), local, k, converted);
			k++;
		}
		for (; k < node.def.outputs.Count; k++)
			statement.AppendF("\t{} {}_{} = {};\n", GlslType(node.def.outputs[k].type), local, k, Zero(node.def.outputs[k].type));
	}

	/// A Custom Code node: its inputs as a, b, v and c, and the code typed into it as an expression (or, when it has
	/// a semicolon, statements that set result), in a block of its own.
	void EmitCustom(Frame frame, GraphNode node, StringView local, String statement)
	{
		let type = node.def.outputs[0].type;
		let a = scope String(), b = scope String(), v = scope String(), c = scope String();
		Input(frame, node, 1, a);
		Input(frame, node, 2, b);
		Input(frame, node, 3, v);
		Input(frame, node, 4, c);
		let code = node.values[0].IsEmpty ? (StringView)Zero(type) : (StringView)node.values[0];
		statement.AppendF("\t{0} {1};\n\t{{\n\t\tfloat a = {2};\n\t\tfloat b = {3};\n\t\tvec3 v = {4};\n\t\tvec4 c = {5};\n\t\t{0} result = {6};\n", GlslType(type), local, a, b, v, c, Zero(type));
		if (code.Contains(';'))
			statement.AppendF("\t\t{}\n", code);
		else
			statement.AppendF("\t\tresult = {};\n", code);
		statement.AppendF("\t\t{} = result;\n\t}}\n", local);
	}
}
