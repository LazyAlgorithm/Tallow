using System;
using System.Collections;
using System.IO;
using System.Reflection;
using Tallow;

namespace Tallow.Editor;

/// Every node kind: the built-in ones plus one per [GraphNode] method found in the program.
static class NodeLibrary
{
	static List<NodeDef> sDefs ~ DeleteContainerAndItems!(_);

	public static List<NodeDef> Defs
	{
		get
		{
			if (sDefs == null)
				Build();
			return sDefs;
		}
	}

	public static NodeDef Find(StringView key)
	{
		for (let def in Defs)
		{
			if (def.key == key)
				return def;
		}
		return null;
	}

	static NodeDef Add(StringView key, StringView category, StringView title, NodeKind kind, StringView code)
	{
		let def = new NodeDef();
		def.key.Set(key);
		def.category.Set(category);
		def.title.Set(title);
		def.kind = kind;
		def.code.Set(code);
		if (kind == .Action || kind == .Branch)
			def.In("", .Flow);
		if (kind == .Event || kind == .Action)
			def.Out("", .Flow);
		sDefs.Add(def);
		return def;
	}

	static void Build()
	{
		sDefs = new .();
		AddEventAndFlowNodes();
		AddNetworkNodes();
		AddValueNodes();
		AddVariableNodes();
		AddBasicNodes();
		AddSubgraphNodes();
		AddShaderNodes();
		AddCodeNodes();
		AddApiNodes();
		AddEcsNodes();
	}

	/// The events a component's code starts from, and branching and loops.
	static void AddEventAndFlowNodes()
	{
		Add("event.start", "Events", "On Start", .Event, "Start");
		TickOutputs(Add("event.update", "Events", "On Update", .Event, "Update"));
		Add("event.fixed", "Events", "On Fixed Update", .Event, "FixedUpdate");
		Add("event.late", "Events", "On Late Update", .Event, "LateUpdate");
		Add("flow.branch", "Flow", "Branch", .Branch, "").In("Condition", .Bool).Out("True", .Flow).Out("False", .Flow);
		Add("flow.for", "Flow", "For Loop", .Loop, "").In("", .Flow).In("First", .Int).In("Last", .Int).Out("Body", .Flow).Out("Index", .Int, "int32", "i$N").Out("Done", .Flow);
		Add("flow.while", "Flow", "While Loop", .While, "").In("", .Flow).In("Condition", .Bool).Out("Body", .Flow).Out("Done", .Flow);

		// The rest of a component's life, and drawing.
		Add("event.awake", "Events", "On Awake", .Event, "Awake");
		Add("event.enable", "Events", "On Enable", .Event, "OnEnable");
		Add("event.disable", "Events", "On Disable", .Event, "OnDisable");
		Add("event.destroy", "Events", "On Destroy", .Event, "OnDestroy");
		Add("event.gui", "Events", "On GUI", .Event, "OnGUI");
	}

	/// Update's signature and outputs: the delta time and the controls (Component.Update).
	static void TickOutputs(NodeDef def)
	{
		def.signature.Set("public override void Update(TickInput input, float deltaTime)");
		def.Out("Delta Time", .Float, "float", "deltaTime").Out("Move", .Vector2, "Vector2", "input.Move").Out("Move Direction", .Vector3, "Vector3", "input.MoveDirection")
			.Out("Yaw", .Float, "float", "input.Yaw").Out("Pitch", .Float, "float", "input.Pitch").Out("Look Rotation", .Quaternion, "Quaternion", "input.LookRotation")
			.Out("Jump", .Bool, "bool", "input.Jump").Out("Jump Pressed", .Bool, "bool", "input.Pressed(.Jump)").Out("Sprint", .Bool, "bool", "input.Sprint")
			.Out("Crouch", .Bool, "bool", "input.Crouch").Out("Fire", .Bool, "bool", "input.Fire").Out("Fire Pressed", .Bool, "bool", "input.Pressed(.Fire)")
			.Out("Use Pressed", .Bool, "bool", "input.Pressed(.Use)");
	}

	/// Multiplayer. Everything a graph does through the engine is shared the same way it is from code; these are
	/// for the cases code would use a Network Script or a message for.
	static void AddNetworkNodes()
	{
		// Graphs saved before Update took the controls: the same event under its old name.
		TickOutputs(Add("net.tick", "Network", "On Tick (old name of On Update)", .Event, "Update"));
		let event = Add("net.event", "Network", "On Network Event", .Event, "OnNetworkEvent");
		event.signature.Set("public override void OnNetworkEvent(StringView name, float value)");
		event.guard.Set("name == {0}");
		event.In("Name", .String).Out("Value", .Float, "float", "value");
		Add("net.send", "Network", "Send Network Event", .Action, "NetworkSync.SendEvent(this, {0}, {1});").In("Name", .String).In("Value", .Float);
		Add("net.isserver", "Network", "Is Server", .Value, "(Scene.Network == null || Scene.Network.IsServer)").Out("", .Bool);
		Add("net.isowner", "Network", "Is Mine", .Value, "NetworkSync.IsMine(this)").Out("", .Bool);
		Add("net.insession", "Network", "In Session", .Value, "NetworkSync.InSession(Scene)").Out("", .Bool);
	}

	/// Whole numbers, comparisons, text and taking values apart: what code gets from operators; and keys and logging.
	static void AddValueNodes()
	{
		Add("math.int", "Values", "Whole Number", .Value, "{0}").In("Value", .Int).Out("", .Int);
		Add("math.text", "Values", "Text", .Value, "{0}").In("Value", .String).Out("", .String);
		Add("math.color", "Values", "Color", .Value, "{0}").In("Value", .Color).Out("", .Color);
		Add("math.rotation", "Values", "Rotation", .Value, "{0}").In("Euler", .Quaternion).Out("", .Quaternion);
		Add("math.vector2", "Values", "Vector 2", .Value, "Vector2({0}, {1})").In("X", .Float).In("Y", .Float).Out("", .Vector2);
		Add("math.self", "Values", "This Object", .Value, "GameObject").Out("", .Object, "GameObject");
		Add("math.null", "Logic", "Is Nothing", .Value, "({0} == null)").In("Object", .Object).Out("", .Bool);
		Add("math.same", "Logic", "Is Same Object", .Value, "({0} === {1})").In("A", .Object).In("B", .Object).Out("", .Bool);
		Add("math.iadd", "Math", "Add (Whole)", .Value, "({0} + {1})").In("A", .Int).In("B", .Int).Out("", .Int);
		Add("math.isub", "Math", "Subtract (Whole)", .Value, "({0} - {1})").In("A", .Int).In("B", .Int).Out("", .Int);
		Add("math.imul", "Math", "Multiply (Whole)", .Value, "({0} * {1})").In("A", .Int).In("B", .Int).Out("", .Int);
		Add("math.imod", "Math", "Remainder", .Value, "({1} != 0 ? {0} % {1} : 0)").In("A", .Int).In("B", .Int).Out("", .Int);
		Add("math.round", "Math", "Round", .Value, "(int32)Math.Round({0})").In("Value", .Float).Out("", .Int);
		Add("math.floor", "Math", "Floor", .Value, "(int32)Math.Floor({0})").In("Value", .Float).Out("", .Int);
		Add("math.neg", "Math", "Negate", .Value, "(-{0})").In("Value", .Float).Out("", .Float);
		Add("math.vsub", "Math", "Subtract Vectors", .Value, "({0} - {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3);
		Add("math.vx", "Math", "Vector X", .Value, "{0}.x").In("Vector", .Vector3).Out("", .Float);
		Add("math.vy", "Math", "Vector Y", .Value, "{0}.y").In("Vector", .Vector3).Out("", .Float);
		Add("math.vz", "Math", "Vector Z", .Value, "{0}.z").In("Vector", .Vector3).Out("", .Float);
		Add("math.qmul", "Math", "Rotate Vector", .Value, "({0} * {1})").In("Rotation", .Quaternion).In("Vector", .Vector3).Out("", .Vector3);
		Add("math.qq", "Math", "Combine Rotations", .Value, "({0} * {1})").In("A", .Quaternion).In("B", .Quaternion).Out("", .Quaternion);
		Add("logic.equal", "Logic", "Equal", .Value, "({0} == {1})").In("A", .Float).In("B", .Float).Out("", .Bool);
		Add("logic.notequal", "Logic", "Not Equal", .Value, "({0} != {1})").In("A", .Float).In("B", .Float).Out("", .Bool);
		Add("logic.gequal", "Logic", "Greater Or Equal", .Value, "({0} >= {1})").In("A", .Float).In("B", .Float).Out("", .Bool);
		Add("logic.lequal", "Logic", "Less Or Equal", .Value, "({0} <= {1})").In("A", .Float).In("B", .Float).Out("", .Bool);
		Add("logic.or", "Logic", "Or", .Value, "({0} || {1})").In("A", .Bool).In("B", .Bool).Out("", .Bool);
		Add("logic.textequal", "Logic", "Text Equal", .Value, "(StringView({0}) == StringView({1}))").In("A", .String).In("B", .String).Out("", .Bool);
		Add("logic.select", "Logic", "Choose Number", .Value, "({0} ? {1} : {2})").In("Condition", .Bool).In("If True", .Float).In("If False", .Float).Out("", .Float);
		Add("logic.selectv", "Logic", "Choose Vector", .Value, "({0} ? {1} : {2})").In("Condition", .Bool).In("If True", .Vector3).In("If False", .Vector3).Out("", .Vector3);
		Add("input.key", "Input", "Key Held", .Value, "Input.GetKey({0})").In("Key", .Enum, "KeyCode").Out("", .Bool);
		Add("input.keydown", "Input", "Key Pressed", .Value, "Input.GetKeyDown({0})").In("Key", .Enum, "KeyCode").Out("", .Bool);
		Add("input.keyup", "Input", "Key Released", .Value, "Input.GetKeyUp({0})").In("Key", .Enum, "KeyCode").Out("", .Bool);
		Add("debug.log", "Debug", "Log", .Action, "Log.Info({0});").In("Text", .String);
		Add("debug.lognumber", "Debug", "Log Number", .Action, "Log.Info(scope String()..AppendF(\"{}: {}\", {0}, {1}));").In("Label", .String).In("Value", .Float);
	}

	/// Get and Set Variable for each type. The variable is named by the node's Name value; the Variables panel of the
	/// Graph tab declares it.
	static void AddVariableNodes()
	{
		for (let type in PinType[?](.Float, .Vector3, .Bool, .String, .Int))
		{
			let label = type == .Float ? "Number" : (type == .Vector3 ? "Vector" : (type == .Bool ? "Boolean" : (type == .Int ? "Whole Number" : "Text")));
			Add(scope $"var.get.{NodeGraph.TypeSuffix(type)}" , "Variables", scope $"Get Variable ({label})" , .GetVariable, "").In("Name", .String).Out("", type);
			Add(scope $"var.set.{NodeGraph.TypeSuffix(type)}" , "Variables", scope $"Set Variable ({label})" , .SetVariable, "").In("", .Flow).In("Name", .String).In("Value", type).Out("", .Flow);
		}
	}

	/// The transform, the object, numbers, vectors, logic, time and input that most graphs start with.
	static void AddBasicNodes()
	{
		Add("transform.translate", "Transform", "Translate", .Action, "Transform.Translate({0});").In("Offset", .Vector3);
		Add("transform.rotate", "Transform", "Rotate", .Action, "Transform.Rotate({0});").In("Degrees", .Vector3);
		Add("transform.setposition", "Transform", "Set Position", .Action, "Transform.Position = {0};").In("Position", .Vector3);
		Add("transform.setscale", "Transform", "Set Scale", .Action, "Transform.LocalScale = {0};").In("Scale", .Vector3);
		Add("transform.position", "Transform", "Get Position", .Value, "Transform.Position").Out("Position", .Vector3);
		Add("transform.forward", "Transform", "Get Forward", .Value, "Transform.Forward").Out("Forward", .Vector3);
		Add("object.setactive", "Object", "Set Active", .Action, "GameObject.SetActive({0});").In("Active", .Bool);
		Add("object.destroy", "Object", "Destroy Self", .Action, "Scene.Destroy(GameObject);");

		Add("math.float", "Values", "Number", .Value, "{0}").In("Value", .Float).Out("", .Float);
		Add("math.vector", "Values", "Vector", .Value, "Vector3({0}, {1}, {2})").In("X", .Float).In("Y", .Float).In("Z", .Float).Out("", .Vector3);
		Add("math.bool", "Values", "Boolean", .Value, "{0}").In("Value", .Bool).Out("", .Bool);
		Add("math.add", "Math", "Add", .Value, "({0} + {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Add("math.sub", "Math", "Subtract", .Value, "({0} - {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Add("math.mul", "Math", "Multiply", .Value, "({0} * {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Add("math.div", "Math", "Divide", .Value, "({0} / {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Add("math.sin", "Math", "Sine", .Value, "Math.Sin({0})").In("Value", .Float).Out("", .Float);
		Add("math.vadd", "Math", "Add Vectors", .Value, "({0} + {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3);
		Add("math.vscale", "Math", "Scale Vector", .Value, "({0} * {1})").In("Vector", .Vector3).In("Factor", .Float).Out("", .Vector3);
		Add("logic.greater", "Logic", "Greater Than", .Value, "({0} > {1})").In("A", .Float).In("B", .Float).Out("", .Bool);
		Add("logic.less", "Logic", "Less Than", .Value, "({0} < {1})").In("A", .Float).In("B", .Float).Out("", .Bool);
		Add("logic.and", "Logic", "And", .Value, "({0} && {1})").In("A", .Bool).In("B", .Bool).Out("", .Bool);
		Add("logic.not", "Logic", "Not", .Value, "(!{0})").In("Value", .Bool).Out("", .Bool);

		Add("time.time", "Time", "Time", .Value, "Time.Time").Out("Seconds", .Float);
		Add("time.delta", "Time", "Delta Time", .Value, "Time.DeltaTime").Out("Seconds", .Float);
		Add("input.axis", "Input", "Axis", .Value, "Input.GetAxis({0})").In("Name", .String).Out("", .Float);
		Add("input.space", "Input", "Space Held", .Value, "Input.GetKey(.Space)").Out("", .Bool);
		Add("input.mouse", "Input", "Left Mouse Held", .Value, "Input.GetMouseButton(0)").Out("", .Bool);

		Add("input.spacepressed", "Input", "Space Pressed", .Value, "Input.GetKeyDown(.Space)").Out("", .Bool);
		Add("input.shift", "Input", "Shift Held", .Value, "Input.GetKey(.LeftShift)").Out("", .Bool);
		Add("input.rightmouse", "Input", "Right Mouse Held", .Value, "Input.GetMouseButton(1)").Out("", .Bool);
		Add("input.mousedelta", "Input", "Mouse Delta", .Value, "Vector3(Input.MouseDelta.x, Input.MouseDelta.y, 0)").Out("", .Vector3);
	}

	/// Building blocks for subgraphs: a graph with a Sub Entry node can be used as a single node in other graphs.
	static void AddSubgraphNodes()
	{
		Add("sub.entry", "Subgraph", "Sub Entry", .Event, "Sub");
		Add("sub.param.float", "Subgraph", "Parameter (Number)", .Param, "").In("Name", .String).Out("", .Float);
		Add("sub.param.vector", "Subgraph", "Parameter (Vector)", .Param, "").In("Name", .String).Out("", .Vector3);
		Add("sub.param.bool", "Subgraph", "Parameter (Boolean)", .Param, "").In("Name", .String).Out("", .Bool);
		Add("sub.param.text", "Subgraph", "Parameter (Text)", .Param, "").In("Name", .String).Out("", .String);
		Add("sub.return.float", "Subgraph", "Return (Number)", .Return, "").In("", .Flow).In("Value", .Float);
		Add("sub.return.vector", "Subgraph", "Return (Vector)", .Return, "").In("", .Flow).In("Value", .Vector3);
		Add("sub.return.bool", "Subgraph", "Return (Boolean)", .Return, "").In("", .Flow).In("Value", .Bool);
	}


	/// Picks up [GraphNode] methods added since the list was built, for example by a script reload. Existing node
	/// kinds are left alone, because open graphs point at them.
	public static void RefreshCodeNodes()
	{
		if (sDefs != null)
		{
			AddCodeNodes();
			AddApiNodes();
			AddEcsNodes();
		}
	}

	// ---- shader graph nodes ----
	// The nodes of a shader graph (.tsgraph). Their code is GLSL, and the graph compiles to a .tshader file: the
	// same surface-shader format a person writes by hand, so the engine's lighting, shadows and fog still apply.

	static NodeDef Shader(StringView key, StringView category, StringView title, StringView code)
	{
		let def = Add(key, category, title, .Value, code);
		def.isShader = true;
		return def;
	}

	static void AddShaderNodes()
	{
		let output = Shader("shader.output", "Shader Output", "Surface Output", "");
		output.kind = .ShaderOutput;
		// New inputs go on the end: graphs name the pins they link by position.
		output.In("Albedo", .Vector3).In("Alpha", .Float).In("Metallic", .Float).In("Roughness", .Float).In("Emissive", .Vector3).In("Vertex Offset", .Vector3)
			.In("Normal", .Vector3).In("Occlusion", .Float);

		// A compute graph ends here instead: it compiles to a .tcompute file, run for every pixel of a texture.
		let compute = Shader("shader.compute.output", "Shader Output", "Compute Output", "");
		compute.kind = .ShaderOutput;
		compute.In("Result", .Color);
		Shader("shader.compute.pixel", "Compute Input", "Pixel", "vec2(pixel)").Out("", .Vector2);
		Shader("shader.compute.size", "Compute Input", "Texture Size", "vec2(size)").Out("", .Vector2);
		Shader("shader.compute.previous", "Compute Input", "Previous", "previous(uv)").Out("", .Color);
		Shader("shader.compute.previousat", "Compute Input", "Previous At UV", "previous({0})").In("UV", .Vector2, "", "uv").Out("", .Color);
		Shader("shader.compute.neighbour", "Compute Input", "Neighbour", "neighbour({0}, {1})").In("Across", .Float).In("Up", .Float).Out("", .Color);
		Shader("shader.compute.neighbours", "Compute Input", "Neighbours Sum", "(neighbour(-1.0, -1.0) + neighbour(0.0, -1.0) + neighbour(1.0, -1.0) + neighbour(-1.0, 0.0) + neighbour(1.0, 0.0) + neighbour(-1.0, 1.0) + neighbour(0.0, 1.0) + neighbour(1.0, 1.0))")
			.Out("", .Color);
		Shader("shader.compute.blur", "Compute Input", "Neighbours Average", "((neighbour(0.0, -1.0) + neighbour(-1.0, 0.0) + neighbour(1.0, 0.0) + neighbour(0.0, 1.0)) * 0.25)").Out("", .Color);

		Shader("shader.time", "Shader Input", "Time", "time").Out("Seconds", .Float);
		Shader("shader.uv", "Shader Input", "UV", "uv").Out("", .Vector2);
		Shader("shader.worldpos", "Shader Input", "World Position", "worldPosition").Out("", .Vector3);
		Shader("shader.worldnormal", "Shader Input", "World Normal", "worldNormal").Out("", .Vector3);
		Shader("shader.vertexcolor", "Shader Input", "Vertex Color", "vertexColor").Out("", .Color);
		Shader("shader.basealbedo", "Shader Input", "Material Albedo", "albedo").Out("", .Vector3);
		Shader("shader.basealpha", "Shader Input", "Material Alpha", "alpha").Out("", .Float);
		Shader("shader.objectpos", "Shader Input", "Object Position (vertex only)", "position").Out("", .Vector3);
		Shader("shader.objectnormal", "Shader Input", "Object Normal (vertex only)", "normal").Out("", .Vector3);

		Shader("shader.number", "Shader Values", "Number", "{0}").In("Value", .Float).Out("", .Float);
		Shader("shader.color", "Shader Values", "Color", "{0}").In("Value", .Color).Out("", .Color);
		Shader("shader.vector", "Shader Values", "Vector", "vec3({0}, {1}, {2})").In("X", .Float).In("Y", .Float).In("Z", .Float).Out("", .Vector3);
		Shader("shader.vector2", "Shader Values", "Vector 2", "vec2({0}, {1})").In("X", .Float).In("Y", .Float).Out("", .Vector2);
		Shader("shader.makecolor", "Shader Values", "Color From Parts", "vec4({0}, {1})").In("RGB", .Vector3).In("Alpha", .Float).Out("", .Color);

		// Properties show in the Inspector of every material that uses the shader.
		Shader("shader.prop.float", "Shader Properties", "Number Property", "{0}").In("Name", .String).In("Default", .Float).Out("", .Float);
		Shader("shader.prop.color", "Shader Properties", "Color Property", "{0}").In("Name", .String).In("Default", .Color).Out("", .Color);
		Shader("shader.prop.texture", "Shader Properties", "Texture Property", "texture2D({0}, {1})").In("Name", .String).In("UV", .Vector2, "", "uv").Out("", .Color);
		Shader("shader.maintexture", "Shader Properties", "Material Texture", "texture2D(mainTexture, {0})").In("UV", .Vector2, "", "uv").Out("", .Color);

		Shader("shader.add", "Shader Math", "Add", "({0} + {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Shader("shader.sub", "Shader Math", "Subtract", "({0} - {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Shader("shader.mul", "Shader Math", "Multiply", "({0} * {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Shader("shader.div", "Shader Math", "Divide", "({0} / max({1}, 0.00001))").In("A", .Float).In("B", .Float).Out("", .Float);
		Shader("shader.sin", "Shader Math", "Sine", "sin({0})").In("Value", .Float).Out("", .Float);
		Shader("shader.cos", "Shader Math", "Cosine", "cos({0})").In("Value", .Float).Out("", .Float);
		Shader("shader.abs", "Shader Math", "Absolute", "abs({0})").In("Value", .Float).Out("", .Float);
		Shader("shader.fract", "Shader Math", "Fraction", "fract({0})").In("Value", .Float).Out("", .Float);
		Shader("shader.floor", "Shader Math", "Floor", "floor({0})").In("Value", .Float).Out("", .Float);
		Shader("shader.sqrt", "Shader Math", "Square Root", "sqrt(max({0}, 0.0))").In("Value", .Float).Out("", .Float);
		Shader("shader.pow", "Shader Math", "Power", "pow(max({0}, 0.0), {1})").In("Value", .Float).In("Power", .Float).Out("", .Float);
		Shader("shader.min", "Shader Math", "Minimum", "min({0}, {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Shader("shader.max", "Shader Math", "Maximum", "max({0}, {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Shader("shader.clamp", "Shader Math", "Clamp", "clamp({0}, {1}, {2})").In("Value", .Float).In("Min", .Float).In("Max", .Float).Out("", .Float);
		Shader("shader.saturate", "Shader Math", "Clamp 0 To 1", "clamp({0}, 0.0, 1.0)").In("Value", .Float).Out("", .Float);
		Shader("shader.oneminus", "Shader Math", "One Minus", "(1.0 - {0})").In("Value", .Float).Out("", .Float);
		Shader("shader.negate", "Shader Math", "Negate", "(-{0})").In("Value", .Float).Out("", .Float);
		Shader("shader.lerp", "Shader Math", "Blend", "mix({0}, {1}, {2})").In("A", .Float).In("B", .Float).In("Amount", .Float).Out("", .Float);
		Shader("shader.step", "Shader Math", "Step", "step({0}, {1})").In("Edge", .Float).In("Value", .Float).Out("", .Float);
		Shader("shader.smoothstep", "Shader Math", "Smooth Step", "smoothstep({0}, {1}, {2})").In("From", .Float).In("To", .Float).In("Value", .Float).Out("", .Float);

		Shader("shader.vadd", "Shader Vectors", "Add Vectors", "({0} + {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3);
		Shader("shader.vsub", "Shader Vectors", "Subtract Vectors", "({0} - {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3);
		Shader("shader.vmul", "Shader Vectors", "Multiply Vectors", "({0} * {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3);
		Shader("shader.vscale", "Shader Vectors", "Scale Vector", "({0} * {1})").In("Vector", .Vector3).In("Amount", .Float).Out("", .Vector3);
		Shader("shader.vlerp", "Shader Vectors", "Blend Vectors", "mix({0}, {1}, {2})").In("A", .Vector3).In("B", .Vector3).In("Amount", .Float).Out("", .Vector3);
		Shader("shader.normalize", "Shader Vectors", "Normalize", "normalize({0})").In("Vector", .Vector3).Out("", .Vector3);
		Shader("shader.dot", "Shader Vectors", "Dot Product", "dot({0}, {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Float);
		Shader("shader.cross", "Shader Vectors", "Cross Product", "cross({0}, {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3);
		Shader("shader.length", "Shader Vectors", "Length", "length({0})").In("Vector", .Vector3).Out("", .Float);
		Shader("shader.distance", "Shader Vectors", "Distance", "distance({0}, {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Float);
		Shader("shader.x", "Shader Vectors", "X", "({0}).x").In("Vector", .Vector3).Out("", .Float);
		Shader("shader.y", "Shader Vectors", "Y", "({0}).y").In("Vector", .Vector3).Out("", .Float);
		Shader("shader.z", "Shader Vectors", "Z", "({0}).z").In("Vector", .Vector3).Out("", .Float);
		Shader("shader.rgb", "Shader Vectors", "Color RGB", "({0}).rgb").In("Color", .Color).Out("", .Vector3);
		Shader("shader.alpha", "Shader Vectors", "Color Alpha", "({0}).a").In("Color", .Color).Out("", .Float);

		Shader("shader.tiling", "Shader UV", "Tiling And Offset", "({0} * {1} + {2})").In("UV", .Vector2, "", "uv").In("Tiling", .Vector2).In("Offset", .Vector2).Out("", .Vector2);
		Shader("shader.panner", "Shader UV", "Scroll", "({0} + {1} * time)").In("UV", .Vector2, "", "uv").In("Speed", .Vector2).Out("", .Vector2);
		Shader("shader.uvx", "Shader UV", "UV X", "({0}).x").In("UV", .Vector2, "", "uv").Out("", .Float);
		Shader("shader.uvy", "Shader UV", "UV Y", "({0}).y").In("UV", .Vector2, "", "uv").Out("", .Float);

		Shader("shader.pulse", "Shader Effects", "Pulse", "(0.5 + 0.5 * sin(time * {0}))").In("Speed", .Float).Out("", .Float);
		Shader("shader.fresnel", "Shader Effects", "Rim (Fresnel)", "pow(1.0 - clamp(dot(worldNormal, normalize(u_camPos.xyz - worldPosition)), 0.0, 1.0), {0})").In("Power", .Float).Out("", .Float);
		Shader("shader.noise", "Shader Effects", "Noise", "fract(sin(dot({0}, vec2(12.9898, 78.233))) * 43758.5453)").In("UV", .Vector2, "", "uv").Out("", .Float);
		Shader("shader.bands", "Shader Effects", "Bands", "(0.5 + 0.5 * sin({0} * {1} - time * {2}))").In("Along", .Float).In("Count", .Float).In("Speed", .Float).Out("", .Float);
		Shader("shader.checker", "Shader Effects", "Checker", "mod(floor(({0}).x * {1}) + floor(({0}).y * {1}), 2.0)").In("UV", .Vector2, "", "uv").In("Squares", .Float).Out("", .Float);
		// Smooth value noise: random heights at the corners of a grid, blended between them.
		Shader("shader.smoothnoise", "Shader Effects", "Smooth Noise", "tsg_noise(({0}) * {1})").In("UV", .Vector2, "", "uv").In("Scale", .Float).Default("8").Out("", .Float);
		Shader("shader.voronoi", "Shader Effects", "Cells (Voronoi)", "tsg_cells(({0}) * {1}, {2})").In("UV", .Vector2, "", "uv").In("Scale", .Float).Default("6").In("Speed", .Float)
			.Out("Distance", .Float, "", "$V.x").Out("Cell", .Float, "", "$V.y");
		Shader("shader.gradient", "Shader Effects", "Gradient", "mix({0}, {1}, clamp({2}, 0.0, 1.0))").In("From", .Color).Default("0 0 0 1").In("To", .Color).In("Amount", .Float).Default("0.5").Out("", .Color);
		Shader("shader.posterize", "Shader Effects", "Posterize", "(floor({0} * {1}) / max({1}, 1.0))").In("Value", .Vector3).In("Steps", .Float).Default("4").Out("", .Vector3);
		Shader("shader.desaturate", "Shader Effects", "Desaturate", "mix({0}, vec3_splat(dot({0}, vec3(0.2126, 0.7152, 0.0722))), {1})").In("Color", .Vector3).In("Amount", .Float).Default("1").Out("", .Vector3);

		Shader("shader.remap", "Shader Math", "Remap", "mix({3}, {4}, ({0} - {1}) / max({2} - {1}, 0.00001))").In("Value", .Float).In("From Min", .Float).In("From Max", .Float).Default("1").In("To Min", .Float).In("To Max", .Float).Default("1").Out("", .Float);
		Shader("shader.mod", "Shader Math", "Modulo", "mod({0}, max({1}, 0.00001))").In("Value", .Float).In("By", .Float).Default("1").Out("", .Float);
		Shader("shader.exp", "Shader Math", "Exponent", "exp({0})").In("Value", .Float).Out("", .Float);
		Shader("shader.round", "Shader Math", "Round", "floor({0} + 0.5)").In("Value", .Float).Out("", .Float);
		Shader("shader.sign", "Shader Math", "Sign", "sign({0})").In("Value", .Float).Out("", .Float);

		Shader("shader.split", "Shader Vectors", "Split Color", "{0}").In("Color", .Color)
			.Out("R", .Float, "", "$V.x").Out("G", .Float, "", "$V.y").Out("B", .Float, "", "$V.z").Out("A", .Float, "", "$V.w");
		Shader("shader.splitvector", "Shader Vectors", "Split Vector", "{0}").In("Vector", .Vector3)
			.Out("X", .Float, "", "$V.x").Out("Y", .Float, "", "$V.y").Out("Z", .Float, "", "$V.z");
		Shader("shader.reflect", "Shader Vectors", "Reflect", "reflect({0}, normalize({1}))").In("Direction", .Vector3).In("Normal", .Vector3).Out("", .Vector3);
		Shader("shader.viewdir", "Shader Input", "View Direction", "normalize(u_camPos.xyz - worldPosition)").Out("", .Vector3);

		Shader("shader.rotateuv", "Shader UV", "Rotate", "tsg_rotate({0}, {1}, {2})").In("UV", .Vector2, "", "uv").In("Center", .Vector2).Default("0.5 0.5").In("Degrees", .Float).Default("45").Out("", .Vector2);
		Shader("shader.polar", "Shader UV", "Polar", "tsg_polar({0}, {1})").In("UV", .Vector2, "", "uv").In("Center", .Vector2).Default("0.5 0.5").Out("Distance And Angle", .Vector2);
		Shader("shader.triplanar", "Shader UV", "Triplanar Texture", "tsg_triplanar(mainTexture, worldPosition * {0}, worldNormal, {1})").In("Scale", .Float).Default("1").In("Sharpness", .Float).Default("4")
			.Out("", .Color);

		// A normal in the surface's own directions, for the output's Normal: x along U, y along V, z out of it.
		// A texture property read as a normal map.
		Shader("shader.prop.normal", "Shader Properties", "Normal Map Property", "tsg_unpackNormal(texture2D({0}, {1}).xyz, {2})").In("Name", .String).In("UV", .Vector2, "", "uv")
			.In("Strength", .Float).Default("1").Out("", .Vector3);
		Shader("shader.normalheight", "Shader Normals", "Normal From Height", "tsg_heightNormal({0}, uv, {1})").In("Height", .Float).In("Strength", .Float).Default("0.1").Out("", .Vector3);
		Shader("shader.normalblend", "Shader Normals", "Blend Normals", "normalize(vec3(({0}).xy + ({1}).xy, ({0}).z * ({1}).z))").In("A", .Vector3).Default("0 0 1").In("B", .Vector3).Default("0 0 1").Out("", .Vector3);
		Shader("shader.normalstrength", "Shader Normals", "Normal Strength", "normalize(vec3(({0}).xy * {1}, ({0}).z))").In("Normal", .Vector3).Default("0 0 1").In("Strength", .Float).Default("1").Out("", .Vector3);

		// Code typed into the node: an expression, or statements that set result. a and b are numbers, v a vector,
		// c a colour.
		CustomCode("shader.custom.float", "Custom Code (Number)", .Float, "a * b");
		CustomCode("shader.custom.vector", "Custom Code (Vector)", .Vector3, "v * a");
		CustomCode("shader.custom.color", "Custom Code (Color)", .Color, "c * a");

		// A shader subgraph: a .tsgraph with Subgraph Output nodes (and no Surface Output) becomes a node of its own
		// in other shader graphs, its Subgraph Inputs its input pins.
		SubgraphPins("float", "Number", .Float);
		SubgraphPins("vector2", "Vector 2", .Vector2);
		SubgraphPins("vector", "Vector", .Vector3);
		SubgraphPins("color", "Color", .Color);
	}

	static void CustomCode(StringView key, StringView title, PinType type, StringView example)
	{
		Shader(key, "Shader Code", title, "").In("Code", .String).Default(example).In("a", .Float).Default("1").In("b", .Float).Default("1").In("v", .Vector3).In("c", .Color).Out("", type);
	}

	static void SubgraphPins(StringView suffix, StringView title, PinType type)
	{
		Shader(scope $"shader.sub.input.{suffix}" , "Shader Subgraph", scope $"Subgraph Input ({title})" , "{1}").In("Name", .String).In("Preview", type).Out("", type);
		Shader(scope $"shader.sub.output.{suffix}" , "Shader Subgraph", scope $"Subgraph Output ({title})" , "").In("Name", .String).In("Value", type);
	}

	/// The node a shader subgraph (.tsgraph with Subgraph Output nodes) becomes, read again from the file: its
	/// Subgraph Inputs, then its Subgraph Outputs, in the order they were placed.
	static void ScanShaderSubgraph(StringView path, StringView relative, StringView text)
	{
		let key = scope $"shsub:{relative}";
		var def = Find(key);
		if (def == null)
		{
			def = new NodeDef();
			def.key.Set(key);
			def.category.Set("Shader Subgraphs");
			def.kind = .Value;
			def.isShader = true;
			sDefs.Add(def);
		}
		let baseName = scope String();
		Path.GetFileNameWithoutExtension(path, baseName);
		def.title.Set(baseName);
		NodeDef.ClearPins(def.inputs);
		NodeDef.ClearPins(def.outputs);
		List<StringView> tokens = scope .();
		List<String> storage = scope .();
		defer
		{
			for (let s in storage)
				delete s;
		}
		for (int pass < 2)
		{
			for (let line in text.Split('\n'))
			{
				tokens.Clear();
				SceneSerializer.Tokenize(line, tokens, storage);
				if (tokens.Count < 5 || tokens[0] != "node" || !tokens[2].StartsWith(pass == 0 ? "shader.sub.input." : "shader.sub.output."))
					continue;
				let pinDef = Find(tokens[2]);
				if (pinDef == null)
					continue;
				let type = pass == 0 ? pinDef.outputs[0].type : pinDef.inputs[1].type;
				let name = (tokens.Count > 5 && !tokens[5].IsEmpty) ? tokens[5] : (StringView)"Value";
				if (pass == 0)
					def.In(name, type);
				else
					def.Out(name, type);
			}
		}
	}

	// ---- nodes read from source ----
	// Every public method, property and field of the engine and of the game's scripts becomes a node, from what
	// ApiIndex reads out of the source files. Nothing here names a particular class, so an engine feature added
	// later, or a script the game writes, has nodes without this file changing.

	static bool MapApiType(StringView typeIn, out PinType pin, String typeName)
	{
		var type = typeIn;
		type.Trim();
		pin = .Float;
		typeName.Set(type);
		switch (type)
		{
		case "float","double":
			pin = .Float;
			typeName.Set("float");
		case "int","int32","uint32","int64","uint64","int16","uint16","int8","uint8": pin = .Int;
		case "bool": pin = .Bool;
		case "Vector3": pin = .Vector3;
		case "Vector2": pin = .Vector2;
		case "Quaternion": pin = .Quaternion;
		case "Color": pin = .Color;
		case "String","StringView": pin = .String;
		default:
			if (type.IsEmpty || type.Contains('<') || type.Contains('*') || type.Contains('[') || type.Contains('(') || type.Contains(' ') || type.Contains('.'))
				return false;
			let entry = ApiIndex.Find(type);
			if (entry == null || entry.isNested || entry.isDelegate)
				return false;
			pin = entry.isEnum ? .Enum : .Object;
		}
		return true;
	}

	/// What stands in for an object input with nothing connected: this object's own, where that makes sense.
	static void SelfExpression(StringView type, bool isTarget, String output)
	{
		// "Nothing" still says what type it is, so that the right overload is picked and the code reads clearly.
		let entry = ApiIndex.Find(type);
		if (entry != null && entry.isStruct && !(entry.IsHandle && isTarget))
			output..Clear().AppendF("default({})", type);
		else if (type == "GameObject" && isTarget)
			output.Set("GameObject");
		else if (type == "Transform" && isTarget)
			output.Set("Transform");
		else if (type == "Scene")
			output.Set("Scene");
		else if (type == "NetworkManager")
			output.Set("Scene.Network");
		else if (type == "PhysicsWorld")
			output.Set("Scene.Physics");
		else if (isTarget && type != "Component" && ApiIndex.IsA(type, "Component"))
			output..Clear().AppendF("GetComponent<{}>()", type);
		else
			output..Clear().AppendF("(({})null)", type);
	}

	/// True when an object pin's stand-in is this object's own thing rather than nothing.
	public static bool IsSelf(PinDef pin) => pin.code != null && !pin.code.StartsWith("((") && !pin.code.StartsWith("default(") && pin.code != "null";

	static bool IsLifecycle(StringView name)
	{
		switch (name)
		{
		case "Awake","Start","Update","FixedUpdate","LateUpdate","OnEnable","OnDisable","OnDestroy","OnRegister","OnUnregister","OnFrame","OnGUI",
			"OnBeforeSave","SaveFields","OnSaving","OnLoaded","OnValidate","OnDrawGizmos","Simulate","GatherInput","OnLocalUpdate","ReadInput","OnNetworkEvent","ToString","GetHashCode","Dispose":
			return true;
		}
		return false;
	}

	/// "minDistance" and "SetDestination" read better on a node as "Min Distance" and "Set Destination".
	public static void Spaced(StringView name, String output)
	{
		for (int i < name.Length)
		{
			let c = name[i];
			if (i == 0)
				output.Append(c.ToUpper);
			else
			{
				if (c.IsUpper && (name[i - 1].IsLower || (i + 1 < name.Length && name[i + 1].IsLower)))
					output.Append(' ');
				output.Append(c);
			}
		}
	}

	static bool LooksPure(StringView name)
	{
		for (let prefix in StringView[?]("Get", "Is", "Has", "Can", "Find", "To", "Contains", "Count", "Distance", "Dot", "Cross", "Lerp", "Clamp", "Min", "Max", "Abs", "Sqrt", "Sin", "Cos",
			"Tan", "Atan", "Pow", "Sign", "Angle", "Normalize", "Euler", "Slerp", "Look", "Evaluate", "Sample", "Weight", "Length", "Raycast", "Check", "Overlap", "World", "Local", "Inverse", "Move"))
		{
			if (name.StartsWith(prefix) && prefix != "Move" && prefix != "Raycast")
				return true;
		}
		return false;
	}

	static void AddApiNodes()
	{
		ApiIndex.Ensure();
		List<ApiIndex.TypeEntry> types = scope .();
		ApiIndex.AllTypes(types);
		types.Sort(scope (a, b) => a.name.CompareTo(b.name));
		for (let type in types)
		{
			if (type.isEnum || type.isNested || type.isDelegate || type.isGeneric || type.name.IsEmpty || !type.name[0].IsUpper || type.name.StartsWith("BT") && type.name != "BTStatus")
				continue;
			let maker = scope ApiNodeMaker(type);
			if (!maker.CanTarget)
				continue;
			for (let member in type.signatures)
			{
				if (member.isMutating && type.isStruct && !type.IsHandle)
					continue;
				if (!member.isPublic || member.isGeneric || member.unreadable || member.name == type.name || IsLifecycle(member.name) || member.name.StartsWith("tn_"))
					continue;
				if (member.kind == .Method)
					maker.AddMethod(member);
				else
					maker.AddProperty(member);
			}
			// Components can be looked up on any object, and added to one.
			if (type.name != "Component" && ApiIndex.IsA(type.name, "Component"))
				maker.AddComponentNodes();
		}
	}

	/// Makes the nodes for the members of one type read from source.
	class ApiNodeMaker
	{
		ApiIndex.TypeEntry mType;
		/// The pin an object of the type goes in, for members called on one.
		PinType mTargetPin;
		String mTargetType = new .() ~ delete _;
		bool mCanTarget;
		/// The type's name spaced out ("Mesh Renderer"): the nodes' category and the start of their titles.
		String mCategory = new .() ~ delete _;
		String mTypeName = new .() ~ delete _;
		String mFallback = new .() ~ delete _;

		public this(ApiIndex.TypeEntry type)
		{
			mType = type;
			mCanTarget = MapApiType(type.name, out mTargetPin, mTargetType);
			Spaced(type.name, mCategory);
		}

		/// Whether a pin can carry the type at all (if not, it gets no nodes).
		public bool CanTarget => mCanTarget;

		/// A new node for the type, or null if one with this key already exists. One for a member called on an object
		/// starts with a pin for that object.
		NodeDef Start(StringView key, StringView title, NodeKind kind, bool isStatic)
		{
			if (Find(key) != null)
				return null;
			let def = Add(key, mCategory, scope $"{mCategory}: {title}" , kind, "");
			def.fromApi = true;
			def.fromGame = mType.fromProject;
			def.group.Set(mType.fromProject ? "" : (mType.group.IsEmpty ? (StringView)"Core" : mType.group));
			if (!isStatic)
			{
				SelfExpression(mType.name, true, mFallback);
				def.In(mType.name, mTargetPin, mTargetType, mFallback);
			}
			return def;
		}

		/// What a member is called on in the generated code: the type for a static member (qualified, because inside
		/// a component "Scene" and "Transform" mean this object's own), else the node's first input.
		void Owner(bool isStatic, String owner)
		{
			if (isStatic)
				owner.AppendF("{}{}", mType.fromProject ? "" : "Tallow.", mType.name);
			else
				owner.Set("{0}");
		}

		/// A field or property: a node reading it, and one setting it if it can be set.
		public void AddProperty(ApiIndex.Member member)
		{
			PinType pin;
			if (!MapApiType(member.type, out pin, mTypeName))
				return;
			let isStatic = member.isStatic;
			let owner = Owner(isStatic, .. scope .());
			let firstArg = isStatic ? 0 : 1;
			let label = Spaced(member.name, .. scope .());
			let get = Start(scope $"api:{mType.name}.{member.name}" , label, .Value, isStatic);
			if (get != null)
			{
				get.code.AppendF("{}.{}", owner, member.name);
				get.Out("", pin, mTypeName);
			}
			if (!member.canSet || (mType.isStruct && !mType.IsHandle))
				return;
			let set = Start(scope $"api:{mType.name}.{member.name}=" , scope $"Set {label}" , .Action, isStatic);
			if (set == null)
				return;
			// Text fields own their String: copy into it instead of replacing it.
			var memberType = (StringView)member.type;
			memberType.Trim();
			if (memberType == "String")
				set.code.AppendF("{}.{}.Set({{{}}});", owner, member.name, firstArg);
			else
				set.code.AppendF("{}.{} = {{{}}};", owner, member.name, firstArg);
			SelfExpression(mTypeName, false, mFallback);
			set.In("Value", pin, mTypeName, pin == .Object ? (StringView)mFallback : "");
		}

		/// A method: every parameter must be something a pin can carry, though trailing ones with defaults may be
		/// left off. One that only works something out is a value node; the rest are actions.
		public void AddMethod(ApiIndex.Member member)
		{
			PinType returnPin = .Flow;
			let returnType = scope String();
			var declared = (StringView)member.type;
			declared.Trim();
			let returns = declared != "void";
			if (returns && !MapApiType(declared, out returnPin, returnType))
				return;
			if (returns && (declared == "String" || declared == "StringView") && !LooksPure(member.name))
				return;
			int usable = 0;
			bool hasOut = false;
			for (let parameter in member.parameters)
			{
				PinType pin;
				if (!MapApiType(parameter.type, out pin, mTypeName) || (parameter.isOut && pin == .String))
				{
					if (!parameter.hasDefault)
						return;
					break;
				}
				hasOut |= parameter.isOut;
				usable++;
			}
			let isStatic = member.isStatic;
			let pure = returns && !hasOut && (LooksPure(member.name) || (mType.isStruct && !mType.IsHandle) || mType.name == "Mathf" || mType.name == "Math");
			let def = Start(scope $"api:{mType.name}.{member.name}/{usable}" , Spaced(member.name, .. scope .()), pure ? .Value : .Action, isStatic);
			if (def == null)
				return;
			def.code.AppendF("{}.{}(", Owner(isStatic, .. scope .()), member.name);
			int input = isStatic ? 0 : 1;
			List<(String name, PinType pin, String type, int index)> outs = scope .();
			defer
			{
				for (let o in outs)
				{
					delete o.name;
					delete o.type;
				}
			}
			for (int i < usable)
			{
				let parameter = member.parameters[i];
				PinType pin;
				MapApiType(parameter.type, out pin, mTypeName);
				if (i > 0)
					def.code.Append(", ");
				let parameterLabel = scope String();
				Spaced(parameter.name, parameterLabel);
				if (parameter.isOut)
				{
					def.code.AppendF("out o$N_{}", i);
					outs.Add((new String(parameterLabel), pin, new String(mTypeName), i));
					continue;
				}
				def.code.AppendF("{{{}}}", input++);
				SelfExpression(mTypeName, false, mFallback);
				def.In(parameterLabel, pin, mTypeName, pin == .Object ? (StringView)mFallback : "");
			}
			def.code.Append(pure ? ")" : ");");
			if (returns)
				def.Out(pure ? "" : "Result", returnPin, returnType, pure ? "" : "r$N");
			for (let o in outs)
				def.Out(o.name, o.pin, o.type, scope $"o$N_{o.index}");
		}

		/// For a component: Get From Object, and (unless it is abstract) Add To Object.
		public void AddComponentNodes()
		{
			let get = Start(scope $"api:{mType.name}.<get>" , "Get From Object", .Value, true);
			if (get != null)
			{
				get.code.AppendF("{{0}}.GetComponent<{}>()", mType.name);
				get.In("Object", .Object, "GameObject", "GameObject").Out("", .Object, mType.name);
			}
			if (mType.isAbstract)
				return;
			let add = Start(scope $"api:{mType.name}.<add>" , "Add To Object", .Action, true);
			if (add != null)
			{
				add.code.AppendF("{{0}}.AddComponent<{}>();", mType.name);
				add.In("Object", .Object, "GameObject", "GameObject").Out("Result", .Object, mType.name, "r$N");
			}
		}
	}

	/// How many nodes were generated from source.
	public static int ApiNodeCount
	{
		get
		{
			int count = 0;
			for (let def in Defs)
			{
				if (def.fromApi)
					count++;
			}
			return count;
		}
	}


	// ---- project-defined ECS data in ordinary visual scripts ----

	static bool EcsPin(Type type, out PinType pin)
	{
		pin = .Float;
		if (type == typeof(float))
			pin = .Float;
		else if (type == typeof(int32))
			pin = .Int;
		else if (type == typeof(bool))
			pin = .Bool;
		else if (type == typeof(Vector2))
			pin = .Vector2;
		else if (type == typeof(Vector3))
			pin = .Vector3;
		else if (type == typeof(Quaternion))
			pin = .Quaternion;
		else if (type == typeof(Color))
			pin = .Color;
		else return false;
		return true;
	}

	/// The same custom [Component] structs appear on GameObjects, in Flecs queries and
	/// in the visual graph. An Object pin defaults to the graph's own GameObject.
	/// These nodes use the GameObject's ECS entity, so scripts and graphs work on
	/// exactly the same data (and [Sync] fields use the normal replication path).
	static void AddEcsNodes()
	{
		for (let info in DataComponents.Types)
		{
			let typeName = info.fullName;
			let has = scope $"ecs:{typeName}.has";
			if (Find(has) == null)
				Add(has, "ECS", scope $"{info.name}: Has Component" , .Value,
scope $"({{0}} != null && {{0}}.HasComponent<{typeName}>())")
					.In("Object", .Object, "GameObject", "GameObject").Out("Has", .Bool);
			let add = scope $"ecs:{typeName}.add";
			if (Find(add) == null)
				Add(add, "ECS", scope $"{info.name}: Add Component" , .Action,
scope $"if ({{0}} != null) {{0}}.AddComponent<{typeName}>();")
					.In("Object", .Object, "GameObject", "GameObject");
			let remove = scope $"ecs:{typeName}.remove";
			if (Find(remove) == null)
				Add(remove, "ECS", scope $"{info.name}: Remove Component" , .Action,
scope $"if ({{0}} != null) {{0}}.RemoveComponent<{typeName}>();")
					.In("Object", .Object, "GameObject", "GameObject");
			// One visual graph can process a whole packed query without one script per object.
			// Its Object output is useful for traditional API calls, and its field
			// outputs read directly from the contiguous ECS column.
			let each = scope $"ecs:{typeName}.each";
			if (Find(each) == null)
			{
				let loop = Add(each, "ECS", scope $"{info.name}: For Each" , .EcsEach, typeName)
					.In("", .Flow).Out("Body", .Flow)
					.Out("Object", .Object, "GameObject", "ecsObject$N");
				for (let field in info.type.GetFields(.Public | .Instance))
				{
					PinType pin;
					if (!EcsPin(field.FieldType, out pin))
						continue;
					loop.Out(field.Name, pin, "", scope $"ecsData$N[ecsIndex$N].{field.Name}");
				}
				loop.Out("Done", .Flow);
			}
			for (let field in info.type.GetFields(.Public | .Instance))
			{
				PinType pin;
				if (!EcsPin(field.FieldType, out pin))
					continue; // Unsupported types should not generate graphs that cannot compile.
				let get = scope $"ecs:{typeName}.{field.Name}.get";
				if (Find(get) == null)
					Add(get, "ECS", scope $"{info.name}: Get {field.Name}" , .Value,
scope $"({{0}} != null && {{0}}.GetComponent<{typeName}>() != null ? {{0}}.GetComponent<{typeName}>().{field.Name} : default)")
						.In("Object", .Object, "GameObject", "GameObject").Out("Value", pin);
				let set = scope $"ecs:{typeName}.{field.Name}.set";
				if (Find(set) == null)
					Add(set, "ECS", scope $"{info.name}: Set {field.Name}" , .Action,
scope $"if ({{0}} != null && {{0}}.GetComponent<{typeName}>() != null) {{0}}.GetComponent<{typeName}>().{field.Name} = {{1}};")
						.In("Object", .Object, "GameObject", "GameObject").In("Value", pin);
			}
		}
	}

	// Methods written in code and marked [GraphNode].
	static void AddCodeNodes()
	{
		for (let type in ScriptReload.ReflectedTypes)
		{
			if (type == null) continue;
			for (let method in type.GetMethods(.Static | .Public))
			{
				if (!(method.GetCustomAttribute<GraphNodeAttribute>() case .Ok))
					continue;
				let typeName = scope String();
				type.GetFullName(typeName);
				if (Find(scope $"call:{typeName}.{method.Name}") != null)
					continue;
				let returnsValue = method.ReturnType != typeof(void);
				PinType returnPin = .Float;
				if (returnsValue && !MapType(method.ReturnType, out returnPin))
					continue;
				let code = scope String();
				code.AppendF("{}.{}(", typeName, method.Name);
				bool supported = true;
				List<(String, PinType)> parameters = scope .();
				defer
				{
					for (let p in parameters)
						delete p.0;
				}
				for (int i < method.ParamCount)
				{
					if (i == 0 && method.GetParamType(i) == typeof(Component))
					{
						code.Append("this");
						continue;
					}
					PinType pin;
					if (!MapType(method.GetParamType(i), out pin))
					{
						supported = false;
						break;
					}
					parameters.Add((new String(method.GetParamName(i)), pin));
					code.AppendF("{}{{{}}}", i > 0 ? ", " : "", parameters.Count - 1);
				}
				if (!supported)
					continue;
				code.Append(returnsValue ? ")" : ");");
				let title = scope String();
				type.GetName(title);
				title.AppendF(".{}", method.Name);
				let def = Add(scope $"call:{typeName}.{method.Name}" , "Code", title, returnsValue ? .Value : .Action, code);
				for (let p in parameters)
					def.In(p.0, p.1);
				if (returnsValue)
					def.Out("", returnPin);
			}
		}
	}

	/// Turns any text into a usable identifier.
	public static void Identifier(StringView text, String result)
	{
		for (let c in text.RawChars)
			result.Append((c.IsLetterOrDigit || c == '_') ? c : '_');
		if (result.IsEmpty || result[0].IsDigit)
			result.Insert(0, "v");
	}

	/// Names a variable cannot take because the generated component already has a member called that.
	public static bool IsReservedName(StringView name)
	{
		for (let reserved in StringView[?]("GameObject", "Transform", "Scene", "IsAwake", "Enabled", "IsActiveAndEnabled", "GetComponent", "Awake", "OnEnable", "Start",
			"FixedUpdate", "Update", "OnLocalUpdate", "LateUpdate", "OnDisable", "OnDestroy", "OnRegister", "OnUnregister", "OnFrame", "OnGUI", "OnBeforeSave", "SaveFields", "OnSaving", "OnLoaded", "OnValidate", "OnDrawGizmos",
			"this", "base", "float", "bool", "int", "String", "Vector3", "true", "false", "null", "var", "let", "if", "else", "for", "while", "return", "class", "public", "delete", "new", "scope"))
		{
			if (name == reserved)
				return true;
		}
		return name.StartsWith("Sub_");
	}

	/// Finds every graph in the project that has a Sub Entry node and offers it as a "Sub: Name" node.
	/// Its Parameter nodes become inputs; a Return node makes it a value node, otherwise it is an action.
	public static void RefreshSubgraphs(StringView assetRoot)
	{
		if (sDefs == null)
			Build();
		ScanSubgraphs(assetRoot, assetRoot);
	}

	static void ScanSubgraphs(StringView folder, StringView assetRoot)
	{
		for (let entry in Directory.EnumerateDirectories(folder))
		{
			let name = scope String();
			entry.GetFileName(name);
			if (!name.StartsWith('.'))
				ScanSubgraphs(scope $"{folder}/{name}" , assetRoot);
		}
		for (let entry in Directory.EnumerateFiles(folder))
		{
			let fileName = scope String();
			entry.GetFileName(fileName);
			if (fileName.EndsWith(".tsgraph"))
			{
				let path = scope $"{folder}/{fileName}";
				let text = scope String();
				if (File.ReadAllText(path, text) case .Ok && text.Contains("shader.sub.output."))
					ScanShaderSubgraph(path, path.Substring(assetRoot.Length + 1), text);
				continue;
			}
			if (!fileName.EndsWith(".tgraph"))
				continue;
			let path = scope $"{folder}/{fileName}";
			let text = scope String();
			if (File.ReadAllText(path, text) case .Err || !text.Contains("sub.entry"))
				continue;
			let relative = scope String(path.Substring(assetRoot.Length + 1));
			let key = scope $"sub:{relative}";
			var def = Find(key);
			if (def == null)
			{
				def = new NodeDef();
				def.key.Set(key);
				def.category.Set("Subgraphs");
				sDefs.Add(def);
			}
			let baseName = scope String();
			Path.GetFileNameWithoutExtension(fileName, baseName);
			def.title.Set(scope $"Sub: {baseName}");
			NodeDef.ClearPins(def.inputs);
			NodeDef.ClearPins(def.outputs);

			PinType returnType = .Flow;
			List<(String, PinType)> parameters = scope .();
			defer
			{
				for (let p in parameters)
					delete p.0;
			}
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
				if (tokens.Count < 5 || tokens[0] != "node")
					continue;
				let type = tokens[2];
				PinType pin = .Float;
				if (type.EndsWith(".vector"))
					pin = .Vector3;
				else if (type.EndsWith(".bool"))
					pin = .Bool;
				else if (type.EndsWith(".text"))
					pin = .String;
				if (type.StartsWith("sub.param."))
					parameters.Add((new String(tokens.Count > 5 ? tokens[5] : "value"), pin));
				else if (type.StartsWith("sub.return."))
					returnType = pin;
			}
			let call = scope String();
			call.Append("Sub_");
			Identifier(baseName, call);
			call.Append('(');
			def.kind = returnType == .Flow ? .Action : .Value;
			if (def.kind == .Action)
				def.In("", .Flow).Out("", .Flow);
			for (int i < parameters.Count)
			{
				def.In(parameters[i].0.IsEmpty ? (StringView)"value" : parameters[i].0, parameters[i].1);
				call.AppendF("{}{{{}}}", i > 0 ? ", " : "", i);
			}
			if (def.kind == .Value)
				def.Out("", returnType);
			call.Append(def.kind == .Action ? ");" : ")");
			def.code.Set(call);
		}
	}

	static bool MapType(Type type, out PinType pin)
	{
		pin = .Float;
		if (type == typeof(float) || type == typeof(int32))
			pin = .Float;
		else if (type == typeof(bool))
			pin = .Bool;
		else if (type == typeof(Vector3))
			pin = .Vector3;
		else if (type == typeof(String) || type == typeof(StringView))
			pin = .String;
		else return false;
		return true;
	}
}
