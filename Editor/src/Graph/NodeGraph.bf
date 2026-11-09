using System;
using System.Collections;
using System.IO;
using System.Reflection;
using Tallow;

namespace Tallow.Editor;

/// A visual script: nodes, the links between their pins, and the compiler that turns it into a Beef component.
class NodeGraph
{
	public String name = new .("NewGraph") ~ delete _;
	public List<GraphNode> nodes = new .() ~ DeleteContainerAndItems!(_);
	public List<GraphLink> links = new .() ~ delete _;
	public List<GraphVariable> variables = new .() ~ DeleteContainerAndItems!(_);
	/// A shader graph (.tsgraph): its nodes are GLSL and it compiles to a .tshader file, not a component.
	public bool isShader;
	int32 mNextId = 1;

	public static StringView TypeSuffix(PinType type)
	{
		switch (type)
		{
		case .Bool: return "bool";
		case .Vector3: return "vector";
		case .String: return "text";
		case .Int: return "int";
		default: return "float";
		}
	}

	public static StringView DefaultValue(PinType type) => type == .Vector3 ? "0 0 0" : (type == .Bool ? "false" : ((type == .Float || type == .Int) ? "0" : ""));

	/// Whether a link is allowed in this graph. In a shader graph numbers, vectors and colours convert into each
	/// other, as they do in shader code.
	public bool Links(PinDef from, PinDef to)
	{
		if (!isShader)
			return CanLink(from, to);
		bool Numeric(PinType type) => type == .Float || type == .Vector2 || type == .Vector3 || type == .Color;
		return Numeric(from.type) && Numeric(to.type);
	}

	/// A number as GLSL wants it: always with a decimal point.
	public static void GlslNumber(float value, String code)
	{
		let text = scope String();
		text.AppendF("{}", value);
		if (!text.Contains('.') && !text.Contains('e') && !text.Contains('E'))
			text.Append(".0");
		code.Append(text);
	}

	public static void ShaderLiteral(PinDef pin, StringView value, String code)
	{
		// An input with a stand-in ("uv" for texture coordinates) uses it when nothing is connected.
		if (pin.code != null)
		{
			code.Append(pin.code);
			return;
		}
		float[4] v = pin.type == .Color ? float[4](1, 1, 1, 1) : default;
		var parts = value.Split(' ', .RemoveEmptyEntries);
		for (int i < 4)
		{
			if (parts.GetNext() case .Ok(let part))
				v[i] = SceneSerializer.ParseFloat(part);
		}
		switch (pin.type)
		{
		case .Float:
			GlslNumber(v[0], code);
		case .Vector2:
			code.Append("vec2(");
			GlslNumber(v[0], code);
			code.Append(", ");
			GlslNumber(v[1], code);
			code.Append(')');
		case .Vector3:
			code.Append("vec3(");
			GlslNumber(v[0], code);
			code.Append(", ");
			GlslNumber(v[1], code);
			code.Append(", ");
			GlslNumber(v[2], code);
			code.Append(')');
		case .Color:
			code.Append("vec4(");
			GlslNumber(v[0], code);
			code.Append(", ");
			GlslNumber(v[1], code);
			code.Append(", ");
			GlslNumber(v[2], code);
			code.Append(", ");
			GlslNumber(v[3], code);
			code.Append(')');
		case .String:
			// A property's name: an identifier in the shader.
			NodeLibrary.Identifier(value.IsEmpty ? (StringView)"value" : value, code);
		default:
			code.Append("0.0");
		}
	}

	static int Components(PinType type) => type == .Float ? 1 : (type == .Vector2 ? 2 : (type == .Vector3 ? 3 : 4));

	/// Wraps a shader expression so that a value of one width fits a pin of another: a number fills every
	/// component, a wider value is cut down, a narrower one is padded (with 1 for a colour's alpha).
	public static void ShaderConvert(PinType from, PinType to, StringView expression, String code)
	{
		let have = Components(from), want = Components(to);
		if (have == want)
			code.Append(expression);
		else if (have == 1)
			code.AppendF("vec{}_splat({})", want, expression);
		else if (want == 1)
			code.AppendF("({}).x", expression);
		else if (want < have)
			code.AppendF("({}).{}", expression, want == 2 ? "xy" : "xyz");
		else if (have == 2)
			code.AppendF(want == 3 ? "vec3({}, 0.0)" : "vec4({}, 0.0, 1.0)", expression);
		else
			code.AppendF("vec4({}, 1.0)", expression);
	}

	/// Whether an output can feed an input: the same kind of value, a whole number and a number either way, or
	/// objects where one type is built on the other.
	public static bool CanLink(PinDef from, PinDef to)
	{
		if ((from.type == .Flow) != (to.type == .Flow))
			return false;
		if ((from.type == .Int && to.type == .Float) || (from.type == .Float && to.type == .Int))
			return true;
		if (from.type != to.type)
			return false;
		if (from.type == .Enum)
			return from.typeName == null || to.typeName == null || from.typeName == to.typeName;
		if (from.type == .Object)
		{
			if (from.typeName == null || to.typeName == null || from.typeName == to.typeName)
				return true;
			return ApiIndex.IsA(from.typeName, to.typeName) || ApiIndex.IsA(to.typeName, from.typeName);
		}
		return true;
	}

	static bool IsVariableNode(GraphNode node) => node.def.kind == .GetVariable || node.def.kind == .SetVariable;

	/// The pin of a variable node that holds the variable's name.
	static int32 NamePin(GraphNode node) => node.def.kind == .SetVariable ? 1 : 0;

	public static StringView VariableName(GraphNode node) => node.values[NamePin(node)].IsEmpty ? (StringView)"value" : node.values[NamePin(node)];

	public GraphVariable FindVariable(StringView name)
	{
		for (let variable in variables)
		{
			if (variable.name == name)
				return variable;
		}
		return null;
	}

	/// Adds a variable with a name no other variable has.
	public GraphVariable AddVariable(StringView name, PinType type)
	{
		let variable = new GraphVariable();
		NodeLibrary.Identifier(name, variable.name);
		let stem = scope String(variable.name);
		for (int suffix = 2; FindVariable(variable.name) != null || NodeLibrary.IsReservedName(variable.name); suffix++)
			variable.name..Set(stem).AppendF("{}", suffix);
		variable.type = type;
		variable.value.Set(DefaultValue(type));
		variables.Add(variable);
		return variable;
	}

	/// Places a Get or Set node for a variable.
	public GraphNode AddVariableNode(GraphVariable variable, bool set, Vector2 position)
	{
		let node = AddNode(NodeLibrary.Find(scope $"var.{set ? "set" : "get"}.{TypeSuffix(variable.type)}"), position);
		node.values[NamePin(node)].Set(variable.name);
		return node;
	}

	/// Renames a variable and the nodes that use it. Fails if the name is taken.
	public bool RenameVariable(GraphVariable variable, StringView name)
	{
		let identifier = scope String();
		NodeLibrary.Identifier(name, identifier);
		if (identifier == variable.name)
			return true;
		if (FindVariable(identifier) != null || NodeLibrary.IsReservedName(identifier))
			return false;
		for (let node in nodes)
		{
			if (IsVariableNode(node) && VariableName(node) == variable.name)
				node.values[NamePin(node)].Set(identifier);
		}
		variable.name.Set(identifier);
		return true;
	}

	/// Changes a variable's type; its nodes change with it and links that no longer fit are dropped.
	public void SetVariableType(GraphVariable variable, PinType type)
	{
		if (variable.type == type)
			return;
		variable.type = type;
		variable.value.Set(DefaultValue(type));
		for (let node in nodes)
		{
			if (!IsVariableNode(node) || VariableName(node) != variable.name)
				continue;
			let set = node.def.kind == .SetVariable;
			node.def = NodeLibrary.Find(scope $"var.{set ? "set" : "get"}.{TypeSuffix(type)}");
			if (set)
				node.values[2].Set(DefaultValue(type));
		}
		Validate();
	}

	public void RemoveVariable(GraphVariable variable)
	{
		for (int i = nodes.Count - 1; i >= 0; i--)
		{
			if (IsVariableNode(nodes[i]) && VariableName(nodes[i]) == variable.name)
				RemoveNode(nodes[i]);
		}
		variables.Remove(variable);
		delete variable;
	}

	/// Node title; variable nodes show the variable they read or write.
	public static void Title(GraphNode node, String title)
	{
		if (IsVariableNode(node))
			title.AppendF("{} {}", node.def.kind == .SetVariable ? "Set" : "Get", VariableName(node));
		else
			title.Append(node.def.title);
	}

	public GraphNode Find(int32 id)
	{
		for (let node in nodes)
		{
			if (node.id == id)
				return node;
		}
		return null;
	}

	public GraphNode AddNode(NodeDef def, Vector2 position, int32 id = 0)
	{
		let node = new GraphNode();
		node.id = id > 0 ? id : mNextId;
		mNextId = Math.Max(mNextId, node.id) + 1;
		node.def = def;
		node.position = position;
		for (let pin in def.inputs)
			node.values.Add(new String(pin.initial != null ? (StringView)pin.initial : DefaultValue(pin.type)));
		nodes.Add(node);
		return node;
	}

	public void RemoveNode(GraphNode node)
	{
		for (int i = links.Count - 1; i >= 0; i--)
		{
			if (links[i].fromNode == node.id || links[i].toNode == node.id)
				links.RemoveAt(i);
		}
		nodes.Remove(node);
		delete node;
	}

	/// Connects an output to an input. An input takes one link, and so does a flow output.
	public void Connect(int32 fromNode, int32 fromPin, int32 toNode, int32 toPin)
	{
		let source = Find(fromNode);
		let isFlow = source != null && source.def.outputs[fromPin].type == .Flow;
		for (int i = links.Count - 1; i >= 0; i--)
		{
			let link = links[i];
			if ((link.toNode == toNode && link.toPin == toPin) || (isFlow && link.fromNode == fromNode && link.fromPin == fromPin))
				links.RemoveAt(i);
		}
		GraphLink link;
		link.fromNode = fromNode;
		link.fromPin = fromPin;
		link.toNode = toNode;
		link.toPin = toPin;
		links.Add(link);
	}

	/// Drops links and pads values that no longer fit after a subgraph's pins changed.
	public void Validate()
	{
		for (let node in nodes)
		{
			while (node.values.Count < node.def.inputs.Count)
				node.values.Add(new String());
		}
		for (int i = links.Count - 1; i >= 0; i--)
		{
			let from = Find(links[i].fromNode);
			let to = Find(links[i].toNode);
			if (from == null || to == null || links[i].fromPin >= from.def.outputs.Count || links[i].toPin >= to.def.inputs.Count
				|| !Links(from.def.outputs[links[i].fromPin], to.def.inputs[links[i].toPin]))
				links.RemoveAt(i);
		}
	}

	public bool IsSubgraph
	{
		get
		{
			for (let node in nodes)
			{
				if (node.def.key == "sub.entry")
					return true;
			}
			return false;
		}
	}

	public void DisconnectPin(int32 nodeId, int32 pin, bool isInput)
	{
		for (int i = links.Count - 1; i >= 0; i--)
		{
			let link = links[i];
			if (isInput ? (link.toNode == nodeId && link.toPin == pin) : (link.fromNode == nodeId && link.fromPin == pin))
				links.RemoveAt(i);
		}
	}

	// ---- file ----

	public void Save(StringView path)
	{
		let text = scope String();
		text.AppendF("graph {}\n", SceneSerializer.Quote(name, .. scope .()));
		for (let variable in variables)
			text.AppendF("variable {} {} {}{}\n", TypeSuffix(variable.type), SceneSerializer.Quote(variable.name, .. scope .()), SceneSerializer.Quote(variable.value, .. scope .()), variable.networked ? " networked" : "");
		for (let node in nodes)
		{
			text.AppendF("node {} {} {} {}", node.id, node.def.key, node.position.x, node.position.y);
			for (let value in node.values)
				text.AppendF(" {}", SceneSerializer.Quote(value, .. scope .()));
			text.Append('\n');
		}
		for (let link in links)
			text.AppendF("link {} {} {} {}\n", link.fromNode, link.fromPin, link.toNode, link.toPin);
		File.WriteAllText(path, text).IgnoreError();
	}

	public bool Load(StringView path)
	{
		let text = scope String();
		if (File.ReadAllText(path, text) case .Err)
			return false;
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (let line in text.Split('\n'))
		{
			tokens.Clear();
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.Count >= 2 && tokens[0] == "graph")
				name.Set(tokens[1]);
			else if (tokens.Count >= 3 && tokens[0] == "variable")
			{
				if (FindVariable(tokens[2]) != null)
					continue;
				PinType type = .Float;
				switch (tokens[1])
				{
				case "vector": type = .Vector3;
				case "bool": type = .Bool;
				case "text": type = .String;
				}
				let variable = AddVariable(tokens[2], type);
				if (tokens.Count > 3)
					variable.value.Set(tokens[3]);
				variable.networked = tokens.Count > 4 && tokens[4] == "networked";
			}
			else if (tokens.Count >= 5 && tokens[0] == "node")
			{
				let def = NodeLibrary.Find(tokens[2]);
				if (def == null)
				{
					Log.Warning(scope $"Graph uses unknown node '{tokens[2]}'; it was dropped.");
					continue;
				}
				let node = AddNode(def, .(SceneSerializer.ParseFloat(tokens[3]), SceneSerializer.ParseFloat(tokens[4])), SceneSerializer.ParseInt(tokens[1]));
				for (int i = 0; i < node.values.Count && 5 + i < tokens.Count; i++)
					node.values[i].Set(tokens[5 + i]);
			}
			else if (tokens.Count >= 5 && tokens[0] == "link")
			{
				GraphLink link;
				link.fromNode = SceneSerializer.ParseInt(tokens[1]);
				link.fromPin = SceneSerializer.ParseInt(tokens[2]);
				link.toNode = SceneSerializer.ParseInt(tokens[3]);
				link.toPin = SceneSerializer.ParseInt(tokens[4]);
				let from = Find(link.fromNode);
				let to = Find(link.toNode);
				if (from != null && to != null && link.fromPin < from.def.outputs.Count && link.toPin < to.def.inputs.Count)
					links.Add(link);
			}
		}
		return true;
	}

	// ---- compiler: graph to Beef source ----

	bool FindLinkTo(int32 node, int32 pin, out GraphLink result)
	{
		result = default;
		for (let link in links)
		{
			if (link.toNode == node && link.toPin == pin)
			{
				result = link;
				return true;
			}
		}
		return false;
	}

	GraphNode FollowFlow(GraphNode node, int32 outputPin)
	{
		for (let link in links)
		{
			if (link.fromNode == node.id && link.fromPin == outputPin)
				return Find(link.toNode);
		}
		return null;
	}

	static void Literal(PinDef pin, StringView value, String code)
	{
		if (pin.type == .Object)
		{
			// Nothing connected: the pin's own stand-in (this object's component of that type, usually).
			code.Append(pin.code != null ? (StringView)pin.code : "null");
			return;
		}
		if (pin.type == .Enum)
		{
			var name = value;
			if (name.IsEmpty && pin.typeName != null)
			{
				let entry = ApiIndex.Find(pin.typeName);
				if (entry != null && entry.members.Count > 0)
					name = entry.members[0];
			}
			if (name.IsEmpty)
				code.Append("default");
			else
			{
				code.Append('.');
				NodeLibrary.Identifier(name, code);
			}
			return;
		}
		Literal(pin.type, value, code);
	}

	static void Literal(PinType type, StringView value, String code)
	{
		float[4] v = default;
		void Parts(int count)
		{
			var parts = value.Split(' ', .RemoveEmptyEntries);
			for (int i < count)
			{
				if (parts.GetNext() case .Ok(let part))
					v[i] = SceneSerializer.ParseFloat(part);
			}
		}
		switch (type)
		{
		case .Int:
			code.AppendF("{}", (int32)SceneSerializer.ParseFloat(value));
		case .Vector2:
			Parts(2);
			code.AppendF("Vector2({}f, {}f)", v[0], v[1]);
		case .Quaternion:
			Parts(3);
			code.AppendF("Quaternion.Euler({}f, {}f, {}f)", v[0], v[1], v[2]);
		case .Color:
			v = .(1, 1, 1, 1);
			Parts(4);
			code.AppendF("Color({}f, {}f, {}f, {}f)", v[0], v[1], v[2], v[3]);
		case .Object:
			code.Append("null");
		case .Enum:
			code.Append("default");
		case .Float:
			let number = SceneSerializer.ParseFloat(value);
			code.AppendF("{}f", number);
		case .Bool:
			code.Append((value == "true" || value == "1") ? "true" : "false");
		case .Vector3:
			Parts(3);
			code.AppendF("Vector3({}f, {}f, {}f)", v[0], v[1], v[2]);
		case .String:
			SceneSerializer.Quote(value, code);
		case .Flow:
		}
	}

	/// Code for the value arriving at an input pin: the connected node's expression, or the pin's literal.
	void InputCode(GraphNode node, int32 pin, String code, int depth)
	{
		GraphLink link;
		if (depth < 48 && FindLinkTo(node.id, pin, out link))
		{
			let source = Find(link.fromNode);
			if (source != null && link.fromPin < source.def.outputs.Count)
			{
				// A whole number into a number pin (or the reverse) and an object into a more exact type are converted.
				let from = source.def.outputs[link.fromPin];
				let to = node.def.inputs[pin];
				if (from.type == .Int && to.type == .Float)
					code.Append("(float)(");
				else if (from.type == .Float && to.type == .Int)
					code.Append("(int32)(");
				else if (to.type == .Object && to.typeName != null && from.typeName != null && from.typeName != to.typeName && ApiIndex.IsA(to.typeName, from.typeName))
				{
					code.Append("((");
					OutputCode(source, link.fromPin, code, depth + 1);
					code.AppendF(") as {})", to.typeName);
					return;
				}
				else
				{
					OutputCode(source, link.fromPin, code, depth + 1);
					return;
				}
				OutputCode(source, link.fromPin, code, depth + 1);
				code.Append(')');
				return;
			}
		}
		Literal(node.def.inputs[pin], node.values[pin], code);
	}

	void OutputCode(GraphNode node, int32 outputPin, String code, int depth)
	{
		// A value the node keeps somewhere of its own: an event's argument, a loop's counter, an action's result.
		if (outputPin < node.def.outputs.Count && node.def.outputs[outputPin].code != null)
		{
			let id = scope String();
			id.AppendF("{}", node.id);
			let expression = scope String(node.def.outputs[outputPin].code);
			expression.Replace("$N", id);
			code.Append(expression);
			return;
		}
		if (node.def.kind == .Event)
		{
			code.Append("Time.DeltaTime");
			return;
		}
		if (node.def.kind == .Param)
		{
			// Inside a subgraph a parameter is simply the method argument of that name.
			NodeLibrary.Identifier(node.values[0].IsEmpty ? (StringView)"value" : node.values[0], code);
			return;
		}
		if (node.def.kind == .GetVariable)
		{
			NodeLibrary.Identifier(VariableName(node), code);
			return;
		}
		Fill(node, code, depth);
	}

	/// Substitutes {n} in a node's code with its data inputs, in order.
	void Fill(GraphNode node, String code, int depth) => Fill(node, node.def.code, code, depth);

	void Fill(GraphNode node, StringView templateIn, String code, int depth)
	{
		List<int32> dataPins = scope .();
		for (int32 i = 0; i < (int32)node.def.inputs.Count; i++)
		{
			if (node.def.inputs[i].type != .Flow)
				dataPins.Add(i);
		}
		let id = scope String();
		id.AppendF("{}", node.id);
		let template = scope String(templateIn);
		template.Replace("$N", id);
		int i = 0;
		while (i < template.Length)
		{
			int close = i + 1;
			while (close < template.Length && template[close].IsDigit)
				close++;
			if (template[i] == '{' && close > i + 1 && close < template.Length && template[close] == '}')
			{
				int index = 0;
				for (int k = i + 1; k < close; k++)
					index = index * 10 + (int)(template[k] - '0');
				if (index < dataPins.Count)
					InputCode(node, dataPins[index], code, depth);
				i = close + 1;
			}
			else
				code.Append(template[i++]);
		}
	}

	void EmitFlow(GraphNode start, String code, int indent, int depth)
	{
		var node = start;
		int guard = 0;
		while (node != null && guard++ < 256 && depth < 24)
		{
			code.Append('\t', indent);
			if (node.def.kind == .Branch)
			{
				code.Append("if (");
				InputCode(node, 1, code, 0);
				code.Append(")\n");
				code.Append('\t', indent);
				code.Append("{\n");
				EmitFlow(FollowFlow(node, 0), code, indent + 1, depth + 1);
				code.Append('\t', indent);
				code.Append("}\n");
				let otherwise = FollowFlow(node, 1);
				if (otherwise != null)
				{
					code.Append('\t', indent);
					code.Append("else\n");
					code.Append('\t', indent);
					code.Append("{\n");
					EmitFlow(otherwise, code, indent + 1, depth + 1);
					code.Append('\t', indent);
					code.Append("}\n");
				}
				return;
			}
			if (node.def.kind == .Loop || node.def.kind == .While)
			{
				if (node.def.kind == .Loop)
				{
					// Counts from First to Last inclusive.
					code.AppendF("for (int32 i{0} = ", node.id);
					InputCode(node, 1, code, 0);
					code.AppendF(", last{0} = ", node.id);
					InputCode(node, 2, code, 0);
					code.AppendF("; i{0} <= last{0}; i{0}++)\n", node.id);
				}
				else
				{
					// A guard so that a condition that never turns false cannot hang the game.
					code.AppendF("for (int32 guard{0} = 0; guard{0} < 100000 && (", node.id);
					InputCode(node, 1, code, 0);
					code.AppendF("); guard{0}++)\n", node.id);
				}
				code.Append('\t', indent);
				code.Append("{\n");
				EmitFlow(FollowFlow(node, 0), code, indent + 1, depth + 1);
				code.Append('\t', indent);
				code.Append("}\n");
				node = FollowFlow(node, node.def.kind == .Loop ? 2 : 1);
				continue;
			}
			if (node.def.kind == .EcsEach)
			{
				// Query once per World, not once per object or per frame. Outputs on this
				// node refer to the current packed data row inside its Body flow.
				// Defer structural changes until iteration finishes (also on early return).
				code.Append("{\n");
				code.Append('\t', indent + 1);
				code.AppendF("let ecsQuery{0} = Scene.World.ObjectsWith<{1}>();\n", node.id, node.def.code);
				code.Append('\t', indent + 1);
				code.Append("Scene.World.DeferBegin();\n");
				code.Append('\t', indent + 1);
				code.Append("defer Scene.World.DeferEnd();\n");
				code.Append('\t', indent + 1);
				code.AppendF("for (var ecsChunk{0} in ecsQuery{0})\n", node.id);
				code.Append('\t', indent + 1);
				code.Append("{\n");
				code.Append('\t', indent + 2);
				code.AppendF("let ecsData{0} = ecsChunk{0}.Write<{1}>();\n", node.id, node.def.code);
				code.Append('\t', indent + 2);
				code.AppendF("let ecsLinks{0} = ecsChunk{0}.Read<ObjectLink>();\n", node.id);
				code.Append('\t', indent + 2);
				code.AppendF("for (int32 ecsIndex{0} = 0; ecsIndex{0} < ecsChunk{0}.Count; ecsIndex{0}++)\n", node.id);
				code.Append('\t', indent + 2);
				code.Append("{\n");
				code.Append('\t', indent + 3);
				code.AppendF("let ecsObject{0} = ecsLinks{0}[ecsIndex{0}].gameObject;\n", node.id);
				code.Append('\t', indent + 3);
				code.AppendF("if (ecsObject{0} == null || !ecsObject{0}.ActiveInHierarchy) continue;\n", node.id);
				EmitFlow(FollowFlow(node, 0), code, indent + 3, depth + 1);
				code.Append('\t', indent + 2);
				code.Append("}\n");
				code.Append('\t', indent + 1);
				code.Append("}\n");
				code.Append('\t', indent);
				code.Append("}\n");
				node = FollowFlow(node, (int32)node.def.outputs.Count - 1);
				continue;
			}
			if (node.def.kind == .Return)
			{
				code.Append("return ");
				InputCode(node, 1, code, 0);
				code.Append(";\n");
				return;
			}
			if (node.def.kind == .SetVariable)
			{
				// Text variables own their String, so they copy the new text instead of taking the reference.
				NodeLibrary.Identifier(VariableName(node), code);
				code.Append(node.def.inputs[2].type == .String ? ".Set(" : " = ");
				InputCode(node, 2, code, 0);
				code.Append(node.def.inputs[2].type == .String ? ");\n" : ";\n");
				node = FollowFlow(node, 0);
				continue;
			}
			if (node.def.kind != .Action)
			{
				code.RemoveFromEnd(indent);
				return;
			}
			// An action that hands something back keeps it in a local the nodes after it read.
			for (let pin in node.def.outputs)
			{
				if (pin.type != .Flow && pin.code != null && pin.code.StartsWith("r$N"))
					code.AppendF("r{} = ", node.id);
			}
			Fill(node, code, 0);
			code.Append('\n');
			node = FollowFlow(node, 0);
		}
	}

	/// Declares the locals that actions with results write to, for every such node in the graph.
	void EmitLocals(String code, int indent)
	{
		for (let node in nodes)
		{
			if (!node.def.HasResults)
				continue;
			for (let pin in node.def.outputs)
			{
				if (pin.type == .Flow || pin.code == null || pin.typeName == null || !pin.code.Contains("$N"))
					continue;
				let local = scope String(pin.code);
				local.Replace("$N", scope $"{node.id}");
				code.Append('\t', indent);
				code.AppendF("{} {} = default;\n", pin.typeName, local);
			}
		}
	}

	/// Writes the shader file (.tshader, or .tcompute) a shader graph stands for (see ShaderGraphCode). False, with the first
	/// problem, when it cannot.
	public bool CompileShader(String text, String problem)
	{
		let writer = scope ShaderGraphCode();
		if (writer.Write(this, text, false))
			return true;
		problem.Set(writer.problems.Split('\n').GetNext().GetValueOrDefault());
		return false;
	}

	/// The code one output of a node stands for. Used to check nodes and to show what a node does.
	public void ExpressionOf(GraphNode node, int32 outputPin, String code) => OutputCode(node, outputPin, code, 0);

	/// The statements a flow starting at a node becomes, with the locals it needs.
	public void StatementOf(GraphNode node, String code, int indent)
	{
		EmitLocals(code, indent);
		EmitFlow(node, code, indent, 0);
	}

	/// The class the generated script is built on: Script, unless a node needs more.
	public void BaseClass(String output)
	{
		output.Set("Script");
		for (let node in nodes)
		{
			if (!node.def.requiresBase.IsEmpty)
				output.Set(node.def.requiresBase);
		}
	}

	/// Generates a Beef component class from the graph. Each event node becomes a method.
	public void Compile(StringView namespaceName, StringView className, StringView sourceFile, String code)
	{
		code.AppendF("// Generated from {} by the Tallow graph compiler.\n// Edit the graph and compile it again; changes made here are overwritten.\n", sourceFile);
		let baseClass = scope String();
		BaseClass(baseClass);
		code.AppendF("using System;\nusing Tallow;\n\nnamespace {};\n\n[Component]\nclass {} : {}\n{{\n", namespaceName, className, baseClass);
		List<String> fields = scope .();
		defer
		{
			for (let s in fields)
				delete s;
		}
		EmitFields(fields, code);
		// One method per kind of event in the graph; events of the same kind run one after another.
		List<String> methods = scope .();
		defer
		{
			for (let m in methods)
				delete m;
		}
		for (let node in nodes)
		{
			if (node.def.kind != .Event || node.def.key == "sub.entry")
				continue;
			bool seen = false;
			for (let m in methods)
				seen |= m == node.def.code;
			if (!seen)
				methods.Add(new String(node.def.code));
		}
		for (let method in methods)
		{
			let body = scope String();
			StringView signature = "";
			for (let node in nodes)
			{
				if (node.def.kind != .Event || node.def.code != method)
					continue;
				signature = node.def.signature;
				if (node.def.guard.IsEmpty)
					EmitFlow(FollowFlow(node, 0), body, 2, 0);
				else
				{
					body.Append("\t\tif (");
					Fill(node, node.def.guard, body, 0);
					body.Append(")\n\t\t{\n");
					EmitFlow(FollowFlow(node, 0), body, 3, 0);
					body.Append("\t\t}\n");
				}
			}
			if (body.IsEmpty && signature.IsEmpty)
				continue;
			let locals = scope String();
			EmitLocals(locals, 2);
			if (signature.IsEmpty)
				code.AppendF("\tpublic override void {0}()\n\t{{\n\t\tbase.{0}();\n{1}{2}\t}}\n\n", method, locals, body);
			else
				code.AppendF("\t{}\n\t{{\n{}{}\t}}\n\n", signature, locals, body);
		}
		// Subgraphs used here (and any they use) become private methods of this component.
		List<String> pending = scope .();
		List<String> done = scope .();
		defer
		{
			for (let s in pending)
				delete s;
			for (let s in done)
				delete s;
		}
		CollectSubgraphs(pending);
		while (pending.Count > 0)
		{
			let key = pending.PopBack();
			bool seen = false;
			for (let d in done)
				seen |= d == key;
			if (seen)
			{
				delete key;
				continue;
			}
			done.Add(key);
			let path = scope String();
			Assets.ResolvePath(key.Substring(4), path);
			let sub = scope NodeGraph();
			if (!sub.Load(path))
				continue;
			let baseName = scope String();
			Path.GetFileNameWithoutExtension(path, baseName);
			sub.EmitSubMethod(baseName, code);
			sub.EmitFields(fields, code);
			sub.CollectSubgraphs(pending);
		}
		code.Append("}\n");
	}

	/// Declares this graph's variables as public fields, skipping names already declared (a subgraph shares its
	/// host's variable of the same name). A variable node whose variable was never declared gets a default field.
	void EmitFields(List<String> declared, String code)
	{
		void Emit(StringView name, PinType type, StringView value, bool networked = false)
		{
			let identifier = scope String();
			NodeLibrary.Identifier(name, identifier);
			for (let d in declared)
			{
				if (d == identifier)
					return;
			}
			declared.Add(new String(identifier));
			let literal = scope String();
			Literal(type, value, literal);
			if (type == .String)
				code.AppendF("\t{}public String {} = new .({}) ~ delete _;\n", networked ? "[Sync] " : "", identifier, literal);
			else
				code.AppendF("\t{}public {} {} = {};\n", networked ? "[Sync] " : "", TypeName(type), identifier, literal);
		}
		let before = declared.Count;
		for (let variable in variables)
			Emit(variable.name, variable.type, variable.value, variable.networked);
		for (let node in nodes)
		{
			if (IsVariableNode(node))
				Emit(VariableName(node), node.def.kind == .SetVariable ? node.def.inputs[2].type : node.def.outputs[0].type, DefaultValue(node.def.kind == .SetVariable ? node.def.inputs[2].type : node.def.outputs[0].type));
		}
		if (declared.Count > before)
			code.Append('\n');
	}

	void CollectSubgraphs(List<String> keys)
	{
		for (let node in nodes)
		{
			if (node.def.key.StartsWith("sub:"))
				keys.Add(new String(node.def.key));
		}
	}

	static StringView TypeName(PinType type)
	{
		switch (type)
		{
		case .Bool: return "bool";
		case .Vector3: return "Vector3";
		case .String: return "String";
		case .Int: return "int32";
		case .Vector2: return "Vector2";
		case .Quaternion: return "Quaternion";
		case .Color: return "Color";
		default: return "float";
		}
	}

	/// Writes this subgraph as a method: parameters from its Parameter nodes, body from its Sub Entry node.
	void EmitSubMethod(StringView name, String code)
	{
		GraphNode entry = null;
		PinType returnType = .Flow;
		let parameters = scope String();
		for (let node in nodes)
		{
			if (node.def.key == "sub.entry")
				entry = node;
			else if (node.def.kind == .Return)
				returnType = node.def.inputs[1].type;
			else if (node.def.kind == .Param)
			{
				if (!parameters.IsEmpty)
					parameters.Append(", ");
				parameters.AppendF("{} ", TypeName(node.def.outputs[0].type));
				NodeLibrary.Identifier(node.values[0].IsEmpty ? (StringView)"value" : node.values[0], parameters);
			}
		}
		if (entry == null)
			return;
		let method = scope String("Sub_");
		NodeLibrary.Identifier(name, method);
		code.AppendF("\t{} {}({})\n\t{{\n", returnType == .Flow ? "void" : TypeName(returnType), method, parameters);
		EmitLocals(code, 2);
		EmitFlow(FollowFlow(entry, 0), code, 2, 0);
		if (returnType != .Flow)
			code.Append("\t\treturn default;\n");
		code.Append("\t}\n\n");
	}
}
