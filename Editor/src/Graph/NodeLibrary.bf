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

	// The add-node menu follows Unreal's Blueprints: Add Event, Flow Control, Variables, Math (Float, Integer,
	// Boolean, Vector, Rotation, Trig, Random, Interpolation), Utilities, Transformation, Game, Collision, Input,
	// Audio, Debug, Networking... Nodes read from the engine's source join the matching category (see ApiCategory).
	// Keys never change (graph files name nodes by key); titles and categories may.

	/// Top-level categories in the order the menu lists them; any other comes after, alphabetically.
	public static readonly StringView[?] CategoryOrder = .("Add Event", "Flow Control", "Variables", "Math", "Utilities", "Transformation", "Game", "Physics",
		"Collision", "Input", "Audio", "Animation", "AI", "Rendering", "World", "User Interface", "Save Game", "Cinematics", "Dialogue", "Networking", "Debug", "Subgraphs",
		"Code", "ECS");

	/// The menu category for nodes read from one folder of the engine's source (Engine/src/<group>).
	public static StringView ApiCategory(StringView group)
	{
		switch (group)
		{
		case "Scene","Platform": return "Game";
		case "Core","Scripting","Assets": return "Utilities";
		case "Render","Lighting": return "Rendering";
		case "Net": return "Networking";
		case "UI": return "User Interface";
		case "Saving": return "Save Game";
		case "Sequence": return "Cinematics";
		case "Animation","Rigging": return "Animation";
		case "Water","Voxel","Modeling": return "World";
		case "Ecs": return "ECS";
		default: return group;
		}
	}

	/// Where a menu's top-level category sorts.
	public static int CategoryRank(StringView top)
	{
		for (int i < CategoryOrder.Count)
		{
			if (CategoryOrder[i] == top)
				return i;
		}
		return top == "My Scripts" ? 1000 : 100;
	}

	/// The events a component's code starts from, and flow control: branching, loops and Blueprint's macros.
	static void AddEventAndFlowNodes()
	{
		Add("event.start", "Add Event", "On Start", .Event, "Start").Also("Event BeginPlay Begin Play");
		TickOutputs(Add("event.update", "Add Event", "On Update", .Event, "Update")).Also("Event Tick");
		Add("event.fixed", "Add Event", "On Fixed Update", .Event, "FixedUpdate").Also("Physics Tick");
		Add("event.late", "Add Event", "On Late Update", .Event, "LateUpdate").Also("Post Update Tick");
		Add("event.awake", "Add Event", "On Awake", .Event, "Awake").Also("Construction Script Initialize");
		Add("event.enable", "Add Event", "On Enable", .Event, "OnEnable");
		Add("event.disable", "Add Event", "On Disable", .Event, "OnDisable");
		Add("event.destroy", "Add Event", "On Destroy", .Event, "OnDestroy").Also("Event End Play Destroyed");
		Add("event.gui", "Add Event", "On GUI", .Event, "OnGUI").Also("Draw HUD");
		// A method of the component's own that Call Custom Event (or code) runs.
		Add("event.custom", "Add Event", "Custom Event", .Event, "Custom").In("Name", .String).Default("MyEvent").Also("Function");
		// Input events: they share Update with On Update, each under its condition.
		InputEvent("event.actionpressed", "On Input Action Pressed", "InputActions.Pressed({0})").In("Action", .String).Default("Jump").Also("InputAction Enhanced Input Action Event Started");
		InputEvent("event.actionreleased", "On Input Action Released", "InputActions.Released({0})").In("Action", .String).Default("Jump").Also("InputAction Enhanced Input Action Event Completed");
		InputEvent("event.keypressed", "On Key Pressed", "Input.GetKeyDown({0})").In("Key", .Enum, "KeyCode").Also("Key Event Keyboard");
		InputEvent("event.keyreleased", "On Key Released", "Input.GetKeyUp({0})").In("Key", .Enum, "KeyCode").Also("Key Event Keyboard");

		Add("flow.branch", "Flow Control", "Branch", .Branch, "").In("Condition", .Bool).Out("True", .Flow).Out("False", .Flow).Also("If");
		let sequence = Control("flow.sequence", "Sequence").In("", .Flow).Also("Then");
		for (int i < 6)
			sequence.Out(scope $"Then {i}", .Flow);
		Add("flow.for", "Flow Control", "For Loop", .Loop, "").In("", .Flow).In("First", .Int).In("Last", .Int).Out("Body", .Flow).Out("Index", .Int, "int32", "i$N").Out("Done", .Flow).Also("ForLoop Loop Body Completed");
		Control("flow.forbreak", "For Loop with Break").In("", .Flow).In("Break", .Flow).In("First", .Int).In("Last", .Int)
			.Out("Body", .Flow).Out("Index", .Int, "int32", "i$N").Out("Completed", .Flow).Also("ForLoopWithBreak");
		Add("flow.while", "Flow Control", "While Loop", .While, "").In("", .Flow).In("Condition", .Bool).Out("Body", .Flow).Out("Done", .Flow).Also("WhileLoop");
		let doOnce = Control("flow.doonce", "Do Once").In("", .Flow).In("Reset", .Flow).In("Start Closed", .Bool).Out("Completed", .Flow).Also("DoOnce");
		doOnce.fields.Set("bool doOnce$N = {0};");
		let doN = Control("flow.don", "Do N").In("Enter", .Flow).In("Reset", .Flow).In("N", .Int).Default("1").Out("Exit", .Flow).Out("Counter", .Int, "", "doN$N").Also("DoN");
		doN.fields.Set("int32 doN$N = 0;");
		let flipFlop = Control("flow.flipflop", "Flip Flop").In("", .Flow).Out("A", .Flow).Out("B", .Flow).Out("Is A", .Bool, "", "flipA$N").Also("FlipFlop Toggle");
		flipFlop.fields.Set("bool flipA$N = false;");
		let gate = Control("flow.gate", "Gate").In("Enter", .Flow).In("Open", .Flow).In("Close", .Flow).In("Toggle", .Flow).In("Start Closed", .Bool).Out("Exit", .Flow);
		gate.fields.Set("bool gateOpen$N = !{0};");
		let delay = Control("flow.delay", "Delay").In("", .Flow).In("Duration", .Float).Default("0.2").Out("Completed", .Flow).Also("Wait Timer Latent");
		delay.fields.Set("bool delayOn$N = false;\nfloat delayLeft$N = 0;");
		let retrigger = Control("flow.retrigger", "Retriggerable Delay").In("", .Flow).In("Duration", .Float).Default("0.2").Out("Completed", .Flow).Also("Wait Timer Latent");
		retrigger.fields.Set("bool delayOn$N = false;\nfloat delayLeft$N = 0;");
		let switchInt = Control("flow.switchint", "Switch on Int").In("", .Flow).In("Selection", .Int);
		for (int i < 6)
			switchInt.Out(scope $"{i}", .Flow);
		switchInt.Out("Default", .Flow).Also("Switch Case");
		let switchString = Control("flow.switchstring", "Switch on String").In("", .Flow).In("Selection", .String);
		for (int i < 4)
			switchString.In(scope $"Case {i}", .String);
		for (int i < 4)
			switchString.Out(scope $"Case {i}", .Flow);
		switchString.Out("Default", .Flow).Also("Switch Case Name Text");
		Control("flow.isvalid", "Is Valid").In("", .Flow).In("Object", .Object).Out("Is Valid", .Flow).Out("Is Not Valid", .Flow).Also("IsValid Null Check");
		Control("flow.callcustom", "Call Custom Event").In("", .Flow).In("Name", .String).Default("MyEvent").Out("", .Flow).Also("Call Function");
	}

	static NodeDef InputEvent(StringView key, StringView title, StringView test)
	{
		let def = Add(key, "Add Event|Input", title, .Event, "Update");
		def.signature.Set(NodeGraph.UpdateSignature);
		def.guard.Set(test);
		return def;
	}

	static NodeDef Control(StringView key, StringView title) => Add(key, "Flow Control", title, .Control, "");

	/// Update's signature and outputs: the delta time and the controls (Component.Update).
	static NodeDef TickOutputs(NodeDef def)
	{
		def.signature.Set(NodeGraph.UpdateSignature);
		def.Out("Delta Time", .Float, "float", "deltaTime").Out("Move", .Vector2, "Vector2", "input.Move").Out("Move Direction", .Vector3, "Vector3", "input.MoveDirection")
			.Out("Yaw", .Float, "float", "input.Yaw").Out("Pitch", .Float, "float", "input.Pitch").Out("Look Rotation", .Quaternion, "Quaternion", "input.LookRotation")
			.Out("Jump", .Bool, "bool", "input.Jump").Out("Jump Pressed", .Bool, "bool", "input.Pressed(.Jump)").Out("Sprint", .Bool, "bool", "input.Sprint")
			.Out("Crouch", .Bool, "bool", "input.Crouch").Out("Fire", .Bool, "bool", "input.Fire").Out("Fire Pressed", .Bool, "bool", "input.Pressed(.Fire)")
			.Out("Use Pressed", .Bool, "bool", "input.Pressed(.Use)");
		return def;
	}

	/// Multiplayer. Everything a graph does through the engine is shared the same way it is from code; these are
	/// for the cases code would use a Network Script or a message for.
	static void AddNetworkNodes()
	{
		// Graphs saved before Update took the controls: the same event under its old name.
		TickOutputs(Add("net.tick", "Add Event|Networking", "On Tick (old name of On Update)", .Event, "Update"));
		let event = Add("net.event", "Add Event|Networking", "On Network Event", .Event, "OnNetworkEvent").Also("Replicated Event RPC Multicast");
		event.signature.Set("public override void OnNetworkEvent(StringView name, float value)");
		event.guard.Set("name == {0}");
		event.In("Name", .String).Out("Value", .Float, "float", "value");
		Add("net.send", "Networking", "Send Network Event", .Action, "NetworkSync.SendEvent(this, {0}, {1});").In("Name", .String).In("Value", .Float).Also("RPC Multicast Run on Server");
		Add("net.isserver", "Networking", "Is Server", .Value, "(Scene.Network == null || Scene.Network.IsServer)").Out("", .Bool).Also("Has Authority Switch Has Authority");
		Add("net.isowner", "Networking", "Is Mine", .Value, "NetworkSync.IsMine(this)").Out("", .Bool).Also("Is Locally Controlled Owner");
		Add("net.insession", "Networking", "In Session", .Value, "NetworkSync.InSession(Scene)").Out("", .Bool).Also("Is Online Multiplayer");
	}

	/// Pure nodes: literals, maths, logic, text and taking values apart; and keys and logging.
	static void AddValueNodes()
	{
		// Literals.
		Add("math.float", "Utilities|Literals", "Make Literal Float", .Value, "{0}").In("Value", .Float).Out("", .Float).Also("Number");
		Add("math.int", "Utilities|Literals", "Make Literal Int", .Value, "{0}").In("Value", .Int).Out("", .Int).Also("Whole Number Integer");
		Add("math.bool", "Utilities|Literals", "Make Literal Bool", .Value, "{0}").In("Value", .Bool).Out("", .Bool).Also("Boolean");
		Add("math.text", "Utilities|Literals", "Make Literal String", .Value, "{0}").In("Value", .String).Out("", .String).Also("Text");
		Add("math.self", "Utilities", "Self", .Value, "GameObject").Out("", .Object, "GameObject").Also("This Object Get a reference to self");
		Add("util.isvalid", "Utilities", "Is Valid", .Value, "({0} != null)").In("Object", .Object).Out("", .Bool).Also("IsValid Null");
		Add("math.null", "Utilities", "Is Nothing", .Value, "({0} == null)").In("Object", .Object).Out("", .Bool).Also("Null Not Valid");
		Add("math.same", "Utilities", "Is Same Object", .Value, "({0} === {1})").In("A", .Object).In("B", .Object).Out("", .Bool).Also("Equal Object");
		Add("logic.select", "Utilities", "Select Float", .Value, "({0} ? {1} : {2})").In("Pick A", .Bool).In("A", .Float).In("B", .Float).Out("", .Float).Also("Choose Number");
		Add("logic.selectv", "Utilities", "Select Vector", .Value, "({0} ? {1} : {2})").In("Pick A", .Bool).In("A", .Vector3).In("B", .Vector3).Out("", .Vector3).Also("Choose Vector");

		// Float.
		Add("math.add", "Math|Float", "Add (Float)", .Value, "({0} + {1})").In("A", .Float).In("B", .Float).Out("", .Float).Also("+ Plus");
		Add("math.sub", "Math|Float", "Subtract (Float)", .Value, "({0} - {1})").In("A", .Float).In("B", .Float).Out("", .Float).Also("- Minus");
		Add("math.mul", "Math|Float", "Multiply (Float)", .Value, "({0} * {1})").In("A", .Float).In("B", .Float).Out("", .Float).Also("* Times");
		Add("math.div", "Math|Float", "Divide (Float)", .Value, "({0} / {1})").In("A", .Float).In("B", .Float).Default("1").Out("", .Float).Also("/");
		Add("math.fmod", "Math|Float", "Modulo (Float)", .Value, "({1} != 0 ? {0} % {1} : 0)").In("A", .Float).In("B", .Float).Default("1").Out("", .Float).Also("% Remainder Percent");
		Add("math.neg", "Math|Float", "Negate (Float)", .Value, "(-{0})").In("Value", .Float).Out("", .Float);
		Add("math.abs", "Math|Float", "Absolute (Float)", .Value, "Math.Abs((float){0})").In("Value", .Float).Out("", .Float).Also("Abs");
		Add("math.min", "Math|Float", "Min (Float)", .Value, "Math.Min({0}, {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Add("math.max", "Math|Float", "Max (Float)", .Value, "Math.Max({0}, {1})").In("A", .Float).In("B", .Float).Out("", .Float);
		Add("math.clamp", "Math|Float", "Clamp (Float)", .Value, "Math.Clamp({0}, {1}, {2})").In("Value", .Float).In("Min", .Float).In("Max", .Float).Default("1").Out("", .Float);
		Add("math.pow", "Math|Float", "Power", .Value, "Math.Pow({0}, {1})").In("Base", .Float).In("Exp", .Float).Default("2").Out("", .Float).Also("Pow Exponent");
		Add("math.sqrt", "Math|Float", "Square Root", .Value, "Math.Sqrt({0})").In("Value", .Float).Out("", .Float).Also("Sqrt");
		Add("math.sign", "Math|Float", "Sign (Float)", .Value, "Mathf.Sign({0})").In("Value", .Float).Out("", .Float);
		Add("math.round", "Math|Float", "Round", .Value, "(int32)Math.Round({0})").In("Value", .Float).Out("", .Int);
		Add("math.floor", "Math|Float", "Floor", .Value, "(int32)Math.Floor({0})").In("Value", .Float).Out("", .Int);
		Add("math.ceil", "Math|Float", "Ceil", .Value, "(int32)Math.Ceiling({0})").In("Value", .Float).Out("", .Int).Also("Ceiling");
		Add("math.trunc", "Math|Float", "Truncate", .Value, "(int32)({0})").In("Value", .Float).Out("", .Int).Also("To Integer");
		Add("math.nearly", "Math|Float", "Nearly Equal (Float)", .Value, "(Math.Abs({0} - {1}) <= {2})").In("A", .Float).In("B", .Float).In("Tolerance", .Float).Default("0.0001").Out("", .Bool);
		Add("logic.equal", "Math|Float", "Equal (Float)", .Value, "({0} == {1})").In("A", .Float).In("B", .Float).Out("", .Bool).Also("==");
		Add("logic.notequal", "Math|Float", "Not Equal (Float)", .Value, "({0} != {1})").In("A", .Float).In("B", .Float).Out("", .Bool).Also("!=");
		Add("logic.greater", "Math|Float", "Greater (Float)", .Value, "({0} > {1})").In("A", .Float).In("B", .Float).Out("", .Bool).Also("> Greater Than");
		Add("logic.less", "Math|Float", "Less (Float)", .Value, "({0} < {1})").In("A", .Float).In("B", .Float).Out("", .Bool).Also("< Less Than");
		Add("logic.gequal", "Math|Float", "Greater Equal (Float)", .Value, "({0} >= {1})").In("A", .Float).In("B", .Float).Out("", .Bool).Also(">= Greater Or Equal");
		Add("logic.lequal", "Math|Float", "Less Equal (Float)", .Value, "({0} <= {1})").In("A", .Float).In("B", .Float).Out("", .Bool).Also("<= Less Or Equal");
		Add("math.inrange", "Math|Float", "In Range (Float)", .Value, "({0} >= {1} && {0} <= {2})").In("Value", .Float).In("Min", .Float).In("Max", .Float).Default("1").Out("", .Bool).Also("Between");

		// Integer.
		Add("math.iadd", "Math|Integer", "Add (Integer)", .Value, "({0} + {1})").In("A", .Int).In("B", .Int).Out("", .Int).Also("+ Whole");
		Add("math.isub", "Math|Integer", "Subtract (Integer)", .Value, "({0} - {1})").In("A", .Int).In("B", .Int).Out("", .Int).Also("- Whole");
		Add("math.imul", "Math|Integer", "Multiply (Integer)", .Value, "({0} * {1})").In("A", .Int).In("B", .Int).Out("", .Int).Also("* Whole");
		Add("math.idiv", "Math|Integer", "Divide (Integer)", .Value, "({1} != 0 ? {0} / {1} : 0)").In("A", .Int).In("B", .Int).Default("1").Out("", .Int).Also("/ Whole");
		Add("math.imod", "Math|Integer", "Modulo (Integer)", .Value, "({1} != 0 ? {0} % {1} : 0)").In("A", .Int).In("B", .Int).Default("1").Out("", .Int).Also("% Remainder");
		Add("math.iabs", "Math|Integer", "Absolute (Integer)", .Value, "(int32)Math.Abs({0})").In("Value", .Int).Out("", .Int);
		Add("math.imin", "Math|Integer", "Min (Integer)", .Value, "(int32)Math.Min({0}, {1})").In("A", .Int).In("B", .Int).Out("", .Int);
		Add("math.imax", "Math|Integer", "Max (Integer)", .Value, "(int32)Math.Max({0}, {1})").In("A", .Int).In("B", .Int).Out("", .Int);
		Add("math.iclamp", "Math|Integer", "Clamp (Integer)", .Value, "(int32)Math.Clamp({0}, {1}, {2})").In("Value", .Int).In("Min", .Int).In("Max", .Int).Default("1").Out("", .Int);
		Add("math.iequal", "Math|Integer", "Equal (Integer)", .Value, "({0} == {1})").In("A", .Int).In("B", .Int).Out("", .Bool).Also("==");
		Add("math.igreater", "Math|Integer", "Greater (Integer)", .Value, "({0} > {1})").In("A", .Int).In("B", .Int).Out("", .Bool).Also(">");
		Add("math.iless", "Math|Integer", "Less (Integer)", .Value, "({0} < {1})").In("A", .Int).In("B", .Int).Out("", .Bool).Also("<");
		Add("math.itofloat", "Math|Integer", "To Float (Integer)", .Value, "(float)({0})").In("Value", .Int).Out("", .Float).Also("Convert");

		// Boolean.
		Add("logic.and", "Math|Boolean", "AND Boolean", .Value, "({0} && {1})").In("A", .Bool).In("B", .Bool).Out("", .Bool).Also("&&");
		Add("logic.or", "Math|Boolean", "OR Boolean", .Value, "({0} || {1})").In("A", .Bool).In("B", .Bool).Out("", .Bool).Also("||");
		Add("logic.not", "Math|Boolean", "NOT Boolean", .Value, "(!{0})").In("Value", .Bool).Out("", .Bool).Also("!");
		Add("logic.xor", "Math|Boolean", "XOR Boolean", .Value, "({0} != {1})").In("A", .Bool).In("B", .Bool).Out("", .Bool).Also("Exclusive Or");
		Add("logic.nand", "Math|Boolean", "NAND Boolean", .Value, "!({0} && {1})").In("A", .Bool).In("B", .Bool).Out("", .Bool);
		Add("logic.bequal", "Math|Boolean", "Equal (Boolean)", .Value, "({0} == {1})").In("A", .Bool).In("B", .Bool).Out("", .Bool).Also("==");

		// Vector.
		Add("math.vector", "Math|Vector", "Make Vector", .Value, "Vector3({0}, {1}, {2})").In("X", .Float).In("Y", .Float).In("Z", .Float).Out("", .Vector3).Also("Vector");
		Add("math.vbreak", "Math|Vector", "Break Vector", .Value, "{0}").In("Vector", .Vector3).Out("X", .Float, "", "{0}.x").Out("Y", .Float, "", "{0}.y").Out("Z", .Float, "", "{0}.z").Also("Split");
		Add("math.vx", "Math|Vector", "Get X (Vector)", .Value, "{0}.x").In("Vector", .Vector3).Out("", .Float).Also("Vector X");
		Add("math.vy", "Math|Vector", "Get Y (Vector)", .Value, "{0}.y").In("Vector", .Vector3).Out("", .Float).Also("Vector Y");
		Add("math.vz", "Math|Vector", "Get Z (Vector)", .Value, "{0}.z").In("Vector", .Vector3).Out("", .Float).Also("Vector Z");
		Add("math.vadd", "Math|Vector", "Add (Vector)", .Value, "({0} + {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3).Also("+ Add Vectors");
		Add("math.vsub", "Math|Vector", "Subtract (Vector)", .Value, "({0} - {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3).Also("- Subtract Vectors");
		Add("math.vscale", "Math|Vector", "Multiply (Vector * Float)", .Value, "({0} * {1})").In("Vector", .Vector3).In("Factor", .Float).Default("1").Out("", .Vector3).Also("* Scale Vector");
		Add("math.vmul", "Math|Vector", "Multiply (Vector * Vector)", .Value, "({0} * {1})").In("A", .Vector3).In("B", .Vector3).Default("1 1 1").Out("", .Vector3).Also("*");
		Add("math.vdiv", "Math|Vector", "Divide (Vector / Float)", .Value, "({1} != 0 ? {0} / {1} : Vector3.Zero)").In("Vector", .Vector3).In("Divisor", .Float).Default("1").Out("", .Vector3).Also("/");
		Add("math.vneg", "Math|Vector", "Negate (Vector)", .Value, "(-{0})").In("Vector", .Vector3).Out("", .Vector3);
		Add("math.vlength", "Math|Vector", "Vector Length", .Value, "{0}.Length").In("Vector", .Vector3).Out("", .Float).Also("VSize Magnitude");
		Add("math.vnormal", "Math|Vector", "Normalize", .Value, "{0}.Normalized").In("Vector", .Vector3).Out("", .Vector3).Also("Unit");
		Add("math.vdistance", "Math|Vector", "Distance (Vector)", .Value, "Vector3.Distance({0}, {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Float).Also("Distance");
		Add("math.vdot", "Math|Vector", "Dot Product", .Value, "Vector3.Dot({0}, {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Float).Also("Dot");
		Add("math.vcross", "Math|Vector", "Cross Product", .Value, "Vector3.Cross({0}, {1})").In("A", .Vector3).In("B", .Vector3).Out("", .Vector3).Also("Cross");
		Add("math.vdirection", "Math|Vector", "Get Unit Direction (Vector)", .Value, "({1} - {0}).Normalized").In("From", .Vector3).In("To", .Vector3).Out("", .Vector3).Also("Direction");
		Add("math.vequal", "Math|Vector", "Equal (Vector)", .Value, "(Vector3.Distance({0}, {1}) <= {2})").In("A", .Vector3).In("B", .Vector3).In("Tolerance", .Float).Default("0.0001").Out("", .Bool).Also("==");
		Add("math.vlerp", "Math|Vector", "Lerp (Vector)", .Value, "Vector3.Lerp({0}, {1}, {2})").In("A", .Vector3).In("B", .Vector3).In("Alpha", .Float).Out("", .Vector3);
		Add("math.qmul", "Math|Vector", "Rotate Vector", .Value, "({0} * {1})").In("Rotation", .Quaternion).In("Vector", .Vector3).Out("", .Vector3);
		Add("math.vunrotate", "Math|Vector", "Unrotate Vector", .Value, "({0}.Conjugate * {1})").In("Rotation", .Quaternion).In("Vector", .Vector3).Out("", .Vector3).Also("Inverse Transform Direction");
		Add("math.vaxis", "Math|Vector", "Rotate Vector Around Axis", .Value, "(Quaternion.AngleAxis({1}, {2}) * {0})").In("Vector", .Vector3).In("Angle", .Float).In("Axis", .Vector3).Default("0 1 0").Out("", .Vector3);
		Add("math.vup", "Math|Vector", "Up Vector", .Value, "Vector3.Up").Out("", .Vector3).Also("Constant");
		Add("math.vforward", "Math|Vector", "Forward Vector", .Value, "Vector3.Forward").Out("", .Vector3).Also("Constant");
		Add("math.vright", "Math|Vector", "Right Vector", .Value, "Vector3.Right").Out("", .Vector3).Also("Constant");
		Add("math.vector2", "Math|Vector 2D", "Make Vector 2D", .Value, "Vector2({0}, {1})").In("X", .Float).In("Y", .Float).Out("", .Vector2).Also("Vector2");
		Add("math.v2break", "Math|Vector 2D", "Break Vector 2D", .Value, "{0}").In("Vector", .Vector2).Out("X", .Float, "", "{0}.x").Out("Y", .Float, "", "{0}.y").Also("Vector2 Split");
		Add("math.v2length", "Math|Vector 2D", "Vector 2D Length", .Value, "{0}.Length").In("Vector", .Vector2).Out("", .Float);
		Add("math.v2to3", "Math|Vector 2D", "To Vector (X, 0, Y)", .Value, "Vector3({0}.x, 0, {0}.y)").In("Vector", .Vector2).Out("", .Vector3).Also("Convert Ground");

		// Rotation.
		Add("math.rotation", "Math|Rotation", "Make Rotation", .Value, "{0}").In("Euler", .Quaternion).Out("", .Quaternion).Also("Make Rotator Rotator");
		Add("math.reuler", "Math|Rotation", "Make Rotation From Euler", .Value, "Quaternion.Euler({0}, {1}, {2})").In("Pitch (X)", .Float).In("Yaw (Y)", .Float).In("Roll (Z)", .Float).Out("", .Quaternion).Also("Make Rotator");
		Add("math.rbreak", "Math|Rotation", "Break Rotation", .Value, "{0}").In("Rotation", .Quaternion).Out("Pitch (X)", .Float, "", "{0}.EulerAngles.x").Out("Yaw (Y)", .Float, "", "{0}.EulerAngles.y")
			.Out("Roll (Z)", .Float, "", "{0}.EulerAngles.z").Also("Break Rotator Euler");
		Add("math.qq", "Math|Rotation", "Combine Rotations", .Value, "({0} * {1})").In("A", .Quaternion).In("B", .Quaternion).Out("", .Quaternion).Also("Compose Rotators");
		Add("math.rinverse", "Math|Rotation", "Invert Rotation", .Value, "{0}.Conjugate").In("Rotation", .Quaternion).Out("", .Quaternion).Also("Negate Rotator");
		Add("math.rlookat", "Math|Rotation", "Find Look at Rotation", .Value, "Quaternion.LookRotation(({1} - {0}).Normalized, Vector3.Up)").In("Start", .Vector3).In("Target", .Vector3).Default("0 0 1").Out("", .Quaternion).Also("Look At");
		Add("math.rfromdir", "Math|Rotation", "Rotation From Direction", .Value, "Quaternion.LookRotation({0}.Normalized, Vector3.Up)").In("Direction", .Vector3).Default("0 0 1").Out("", .Quaternion).Also("Make Rot From X");
		Add("math.raxis", "Math|Rotation", "Rotation Around Axis", .Value, "Quaternion.AngleAxis({0}, {1})").In("Angle", .Float).In("Axis", .Vector3).Default("0 1 0").Out("", .Quaternion).Also("Angle Axis");
		Add("math.rforward", "Math|Rotation", "Get Forward Vector", .Value, "({0} * Vector3.Forward)").In("Rotation", .Quaternion).Out("", .Vector3);
		Add("math.rright", "Math|Rotation", "Get Right Vector", .Value, "({0} * Vector3.Right)").In("Rotation", .Quaternion).Out("", .Vector3);
		Add("math.rup", "Math|Rotation", "Get Up Vector", .Value, "({0} * Vector3.Up)").In("Rotation", .Quaternion).Out("", .Vector3);

		// Interpolation.
		Add("math.lerp", "Math|Interpolation", "Lerp (Float)", .Value, "Mathf.Lerp({0}, {1}, {2})").In("A", .Float).In("B", .Float).Default("1").In("Alpha", .Float).Out("", .Float).Also("Linear Blend");
		Add("math.finterp", "Math|Interpolation", "FInterp To", .Value, "Mathf.Lerp({0}, {1}, Mathf.Clamp01({2} * {3}))").In("Current", .Float).In("Target", .Float).In("Delta Time", .Float).In("Interp Speed", .Float).Default("5").Out("", .Float).Also("Smooth Damp");
		Add("math.vinterp", "Math|Interpolation", "VInterp To", .Value, "Vector3.Lerp({0}, {1}, Mathf.Clamp01({2} * {3}))").In("Current", .Vector3).In("Target", .Vector3).In("Delta Time", .Float).In("Interp Speed", .Float).Default("5").Out("", .Vector3).Also("Smooth Damp Vector");
		Add("math.rinterp", "Math|Interpolation", "RInterp To", .Value, "Quaternion.Slerp({0}, {1}, Mathf.Clamp01({2} * {3}))").In("Current", .Quaternion).In("Target", .Quaternion).In("Delta Time", .Float).In("Interp Speed", .Float).Default("5").Out("", .Quaternion).Also("Slerp Rotation");
		Add("math.slerp", "Math|Interpolation", "Slerp (Rotation)", .Value, "Quaternion.Slerp({0}, {1}, {2})").In("A", .Quaternion).In("B", .Quaternion).In("Alpha", .Float).Out("", .Quaternion).Also("Lerp Rotator");
		Add("math.movetowards", "Math|Interpolation", "Move Towards (Float)", .Value, "Mathf.MoveTowards({0}, {1}, {2})").In("Current", .Float).In("Target", .Float).In("Max Step", .Float).Default("1").Out("", .Float).Also("FInterp To Constant");
		Add("math.maprange", "Math|Interpolation", "Map Range Clamped", .Value, "Mathf.Lerp({3}, {4}, Mathf.Clamp01(({2} - {1}) != 0 ? ({0} - {1}) / ({2} - {1}) : 0))")
			.In("Value", .Float).In("In Range A", .Float).In("In Range B", .Float).Default("1").In("Out Range A", .Float).In("Out Range B", .Float).Default("1").Out("", .Float).Also("Remap");
		Add("math.smoothstep", "Math|Interpolation", "Smooth Step", .Value, "Mathf.SmoothStep({0}, {1}, {2})").In("A", .Float).In("B", .Float).Default("1").In("Alpha", .Float).Out("", .Float).Also("Ease");

		// Trig.
		Add("math.sin", "Math|Trig", "Sin (Radians)", .Value, "Math.Sin({0})").In("Value", .Float).Out("", .Float).Also("Sine");
		Add("math.cos", "Math|Trig", "Cos (Radians)", .Value, "Math.Cos({0})").In("Value", .Float).Out("", .Float).Also("Cosine");
		Add("math.tan", "Math|Trig", "Tan (Radians)", .Value, "Math.Tan({0})").In("Value", .Float).Out("", .Float).Also("Tangent");
		Add("math.asin", "Math|Trig", "Asin (Radians)", .Value, "Math.Asin(Math.Clamp({0}, -1, 1))").In("Value", .Float).Out("", .Float);
		Add("math.acos", "Math|Trig", "Acos (Radians)", .Value, "Math.Acos(Math.Clamp({0}, -1, 1))").In("Value", .Float).Out("", .Float);
		Add("math.atan2", "Math|Trig", "Atan2 (Radians)", .Value, "Math.Atan2({0}, {1})").In("Y", .Float).In("X", .Float).Default("1").Out("", .Float).Also("Atan");
		Add("math.sindeg", "Math|Trig", "Sin (Degrees)", .Value, "Math.Sin({0} * Mathf.Deg2Rad)").In("Degrees", .Float).Out("", .Float).Also("Sine");
		Add("math.cosdeg", "Math|Trig", "Cos (Degrees)", .Value, "Math.Cos({0} * Mathf.Deg2Rad)").In("Degrees", .Float).Out("", .Float).Also("Cosine");
		Add("math.torad", "Math|Trig", "Degrees To Radians", .Value, "({0} * Mathf.Deg2Rad)").In("Degrees", .Float).Out("", .Float);
		Add("math.todeg", "Math|Trig", "Radians To Degrees", .Value, "({0} * Mathf.Rad2Deg)").In("Radians", .Float).Out("", .Float);
		Add("math.pi", "Math|Trig", "Get PI", .Value, "Mathf.PI").Out("", .Float).Also("Pi Constant");

		// Random: different on every machine (fine for effects); the network-safe one is the same everywhere.
		Add("math.random", "Math|Random", "Random Float", .Value, "(float)gRand.NextDouble()").Out("", .Float).Also("Rand");
		Add("math.randomrange", "Math|Random", "Random Float in Range", .Value, "Mathf.Lerp({0}, {1}, (float)gRand.NextDouble())").In("Min", .Float).In("Max", .Float).Default("1").Out("", .Float).Also("Rand");
		Add("math.randomint", "Math|Random", "Random Integer in Range", .Value, "(int32)gRand.Next((int32)({0}), (int32)Math.Max({0}, {1}) + 1)").In("Min", .Int).In("Max", .Int).Default("10").Out("", .Int).Also("Rand");
		Add("math.randombool", "Math|Random", "Random Bool", .Value, "(gRand.NextDouble() < 0.5)").Out("", .Bool).Also("Coin");
		Add("math.randomunit", "Math|Random", "Random Unit Vector", .Value, "Vector3((float)gRand.NextDoubleSigned(), (float)gRand.NextDoubleSigned(), (float)gRand.NextDoubleSigned()).Normalized")
			.Out("", .Vector3).Also("Direction");
		Add("math.netrandom", "Math|Random", "Random Float in Range (Network Safe)", .Value, "NetRandom.Range(this, {0}, {1}, $N)").In("Min", .Float).In("Max", .Float).Default("1").Out("", .Float).Also("Deterministic Seeded");

		// Color.
		Add("math.color", "Math|Color", "Make Color", .Value, "{0}").In("Value", .Color).Out("", .Color).Also("Linear Color");
		Add("math.cbreak", "Math|Color", "Break Color", .Value, "{0}").In("Color", .Color).Out("R", .Float, "", "{0}.r").Out("G", .Float, "", "{0}.g").Out("B", .Float, "", "{0}.b").Out("A", .Float, "", "{0}.a");
		Add("math.crgba", "Math|Color", "Make Color From RGBA", .Value, "Color({0}, {1}, {2}, {3})").In("R", .Float).In("G", .Float).In("B", .Float).In("A", .Float).Default("1").Out("", .Color);

		// Text.
		Add("text.append", "Utilities|String", "Append", .Value, "scope:: String()..Append({0})..Append({1})").In("A", .String).In("B", .String).Out("", .String).Also("Concatenate Join + String");
		Add("text.float", "Utilities|String", "To String (Float)", .Value, "scope:: String()..AppendF(\"{}\", {0})").In("Value", .Float).Out("", .String).Also("Convert Text Number");
		Add("text.int", "Utilities|String", "To String (Integer)", .Value, "scope:: String()..AppendF(\"{}\", {0})").In("Value", .Int).Out("", .String).Also("Convert Text");
		Add("text.bool", "Utilities|String", "To String (Boolean)", .Value, "({0} ? \"true\" : \"false\")").In("Value", .Bool).Out("", .String).Also("Convert Text");
		Add("text.vector", "Utilities|String", "To String (Vector)", .Value, "scope:: String()..AppendF(\"X={:0.###} Y={:0.###} Z={:0.###}\", {0}.x, {0}.y, {0}.z)").In("Value", .Vector3).Out("", .String).Also("Convert Text");
		Add("text.length", "Utilities|String", "Length (String)", .Value, "(int32)StringView({0}).Length").In("Text", .String).Out("", .Int).Also("Len");
		Add("text.contains", "Utilities|String", "Contains (String)", .Value, "StringView({0}).Contains({1})").In("Text", .String).In("Substring", .String).Out("", .Bool).Also("Find");
		Add("logic.textequal", "Utilities|String", "Equal (String)", .Value, "(StringView({0}) == StringView({1}))").In("A", .String).In("B", .String).Out("", .Bool).Also("Text Equal ==");
		Add("text.empty", "Utilities|String", "Is Empty (String)", .Value, "StringView({0}).IsEmpty").In("Text", .String).Out("", .Bool);

		// Keys, mouse and input actions.
		Add("input.key", "Input|Keyboard", "Key Held", .Value, "Input.GetKey({0})").In("Key", .Enum, "KeyCode").Out("", .Bool).Also("Is Input Key Down");
		Add("input.keydown", "Input|Keyboard", "Key Pressed", .Value, "Input.GetKeyDown({0})").In("Key", .Enum, "KeyCode").Out("", .Bool).Also("Was Input Key Just Pressed");
		Add("input.keyup", "Input|Keyboard", "Key Released", .Value, "Input.GetKeyUp({0})").In("Key", .Enum, "KeyCode").Out("", .Bool).Also("Was Input Key Just Released");
		Add("input.actionheld", "Input|Actions", "Input Action Held", .Value, "InputActions.Held({0})").In("Action", .String).Default("Jump").Out("", .Bool).Also("Enhanced Input Action Value");
		Add("input.actionpressed", "Input|Actions", "Input Action Pressed", .Value, "InputActions.Pressed({0})").In("Action", .String).Default("Jump").Out("", .Bool).Also("Enhanced Input Triggered Started");
		Add("input.actionreleased", "Input|Actions", "Input Action Released", .Value, "InputActions.Released({0})").In("Action", .String).Default("Jump").Out("", .Bool).Also("Enhanced Input Completed");
		Add("input.actionvalue", "Input|Actions", "Input Action Value", .Value, "InputActions.Value({0})").In("Action", .String).Default("Fire").Out("", .Float).Also("Get Input Axis Value Enhanced Input");
		Add("input.actionvector", "Input|Actions", "Input Action Vector", .Value, "InputActions.Vector({0})").In("Action", .String).Default("Move").Out("", .Vector2).Also("Get Input Axis Value Move Enhanced Input");
		Add("input.actiondelta", "Input|Actions", "Input Action Delta", .Value, "InputActions.Delta({0})").In("Action", .String).Default("Look").Out("", .Vector2).Also("Look Mouse Turn Enhanced Input");
		Add("input.gamepad", "Input", "Using Gamepad", .Value, "Input.UsingGamepad").Out("", .Bool).Also("Controller");
		Add("debug.log", "Debug", "Print String", .Action, "Log.Info({0});").In("Text", .String).Default("Hello").Also("Log");
		Add("debug.lognumber", "Debug", "Print Number", .Action, "Log.Info(scope String()..AppendF(\"{}: {}\", {0}, {1}));").In("Label", .String).In("Value", .Float).Also("Log Number Float");
		Add("debug.line", "Debug", "Draw Debug Line", .Action, "DebugDraw.Line({0}, {1}, {2});").In("Start", .Vector3).In("End", .Vector3).Default("0 1 0").In("Color", .Color).Default("1 0 0 1").Also("Gizmo");
		Add("debug.sphere", "Debug", "Draw Debug Sphere", .Action, "DebugDraw.Sphere({0}, {1}, {2});").In("Center", .Vector3).In("Radius", .Float).Default("0.5").In("Color", .Color).Default("0 1 0 1").Also("Gizmo");
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
		// Transformation. Target is this object unless something is linked.
		Add("transform.translate", "Transformation", "Add World Offset", .Action, "Transform.Translate({0});").In("Delta Location", .Vector3).Also("Translate Move AddActorWorldOffset");
		Add("transform.rotate", "Transformation", "Add Rotation (Degrees)", .Action, "Transform.Rotate({0});").In("Degrees", .Vector3).Also("Rotate AddActorWorldRotation");
		Add("transform.setposition", "Transformation", "Set World Location", .Action, "Transform.Position = {0};").In("Position", .Vector3).Also("Set Position SetActorLocation Teleport");
		Add("transform.setscale", "Transformation", "Set Scale", .Action, "Transform.LocalScale = {0};").In("Scale", .Vector3).Default("1 1 1").Also("SetActorScale3D");
		Add("transform.setrotation", "Transformation", "Set World Rotation", .Action, "Transform.Rotation = {0};").In("Rotation", .Quaternion).Also("SetActorRotation");
		Add("transform.lookat", "Transformation", "Look At", .Action, "Transform.LookAt({0});").In("Target", .Vector3).Also("Face Find Look at Rotation");
		Add("transform.position", "Transformation", "Get World Location", .Value, "Transform.Position").Out("Position", .Vector3).Also("Get Position GetActorLocation");
		Add("transform.rotation", "Transformation", "Get World Rotation", .Value, "Transform.Rotation").Out("Rotation", .Quaternion).Also("GetActorRotation");
		Add("transform.scale", "Transformation", "Get Scale", .Value, "Transform.LocalScale").Out("Scale", .Vector3).Also("GetActorScale3D");
		Add("transform.forward", "Transformation", "Get Forward Vector", .Value, "Transform.Forward").Out("Forward", .Vector3).Also("GetActorForwardVector");
		Add("transform.right", "Transformation", "Get Right Vector", .Value, "Transform.Right").Out("Right", .Vector3).Also("GetActorRightVector");
		Add("transform.up", "Transformation", "Get Up Vector", .Value, "(Transform.Rotation * Vector3.Up)").Out("Up", .Vector3).Also("GetActorUpVector");
		Add("transform.objposition", "Transformation", "Get Location Of", .Value, "({0} != null ? {0}.Transform.Position : Vector3.Zero)").In("Target", .Object, "GameObject", "GameObject").Out("Position", .Vector3).Also("GetActorLocation Target");
		Add("transform.objsetposition", "Transformation", "Set Location Of", .Action, "if ({0} != null) {0}.Transform.Position = {1};").In("Target", .Object, "GameObject", "GameObject").In("Position", .Vector3).Also("SetActorLocation Target Teleport");

		// Game: objects, spawning, time and the application.
		Add("object.setactive", "Game", "Set Active", .Action, "GameObject.SetActive({0});").In("Active", .Bool).Default("true").Also("Set Actor Hidden In Game Enable");
		Add("object.destroy", "Game", "Destroy Self", .Action, "Scene.Destroy(GameObject);").Also("DestroyActor");
		Add("game.destroy", "Game", "Destroy Object", .Action, "if ({0} != null) Scene.Destroy({0});").In("Target", .Object, "GameObject").Also("DestroyActor Target");
		Add("game.spawn", "Game", "Spawn Prefab", .Action, "r$N = Prefab.Instantiate(Scene, {0}, {1}, {2});").In("Prefab", .String).In("Location", .Vector3).In("Rotation", .Quaternion)
			.Out("Spawned", .Object, "GameObject", "r$N").Also("SpawnActor Spawn Actor from Class Instantiate").locals.Set("GameObject r$N = null;");
		Add("game.find", "Game", "Find Object By Name", .Value, "Scene.Find({0})").In("Name", .String).Out("", .Object, "GameObject").Also("Get Actor Of Class");
		Add("game.findtag", "Game", "Find Object With Tag", .Value, "Scene.FindWithTag({0})").In("Tag", .String).Out("", .Object, "GameObject").Also("Get All Actors With Tag");
		Add("game.hastag", "Game", "Has Tag", .Value, "({0} != null && {0}.HasTag({1}))").In("Target", .Object, "GameObject", "GameObject").In("Tag", .String).Out("", .Bool).Also("Actor Has Tag");
		Add("game.name", "Game", "Get Name", .Value, "({0} != null ? (StringView){0}.Name : \"\")").In("Target", .Object, "GameObject", "GameObject").Out("", .String).Also("Get Display Name Object Name");
		Add("game.quit", "Game", "Quit Game", .Action, "Application.Quit();").Also("Exit");
		Add("time.time", "Game|Time", "Get Game Time In Seconds", .Value, "Time.Time").Out("Seconds", .Float).Also("Time Get Time Seconds");
		Add("time.delta", "Game|Time", "Get World Delta Seconds", .Value, "Time.DeltaTime").Out("Seconds", .Float).Also("Delta Time");
		Add("time.real", "Game|Time", "Get Real Time Seconds", .Value, "Time.RealTime").Out("Seconds", .Float).Also("Unscaled");
		Add("time.settimescale", "Game|Time", "Set Global Time Dilation", .Action, "Time.TimeScale = Math.Max({0}, 0);").In("Time Scale", .Float).Default("1").Also("Time Scale Slow Motion Pause");
		Add("time.timescale", "Game|Time", "Get Global Time Dilation", .Value, "Time.TimeScale").Out("", .Float).Also("Time Scale");

		// Physics and collision.
		Add("physics.trace", "Collision", "Line Trace By Channel", .Action, "r$N = Scene.Physics.Raycast({0}, ({1} - {0}).Normalized, ({1} - {0}).Length, out hit$N);")
			.In("Start", .Vector3).In("End", .Vector3).Default("0 0 10").Out("Return Value", .Bool, "bool", "r$N").Out("Hit Object", .Object, "GameObject", "hit$N.gameObject")
			.Out("Hit Location", .Vector3, "Vector3", "hit$N.point").Out("Distance", .Float, "float", "hit$N.distance").Also("Raycast LineTrace Ray").locals.Set("bool r$N = false;\nRaycastHit hit$N = default;");
		Add("physics.raycast", "Collision", "Raycast (Direction)", .Action, "r$N = Scene.Physics.Raycast({0}, {1}.Normalized, {2}, out hit$N);")
			.In("Origin", .Vector3).In("Direction", .Vector3).Default("0 0 1").In("Max Distance", .Float).Default("100").Out("Hit", .Bool, "bool", "r$N").Out("Hit Object", .Object, "GameObject", "hit$N.gameObject")
			.Out("Hit Location", .Vector3, "Vector3", "hit$N.point").Out("Distance", .Float, "float", "hit$N.distance").Also("Line Trace").locals.Set("bool r$N = false;\nRaycastHit hit$N = default;");
		Add("physics.spheretrace", "Collision", "Sphere Trace", .Action, "r$N = Scene.Physics.SphereCast({0}, {2}, ({1} - {0}).Normalized, ({1} - {0}).Length, out hit$N);")
			.In("Start", .Vector3).In("End", .Vector3).Default("0 0 10").In("Radius", .Float).Default("0.5").Out("Return Value", .Bool, "bool", "r$N").Out("Hit Object", .Object, "GameObject", "hit$N.gameObject")
			.Out("Hit Location", .Vector3, "Vector3", "hit$N.point").Out("Hit Normal", .Vector3, "Vector3", "hit$N.normal").Also("SphereTrace Shape Cast").locals.Set("bool r$N = false;\nShapeCastHit hit$N = default;");
		Add("physics.addforce", "Physics", "Add Force", .Action, "if ({0} != null && {0}.HasComponent<Rigidbody>()) {0}.GetComponent<Rigidbody>().AddForce({1});")
			.In("Target", .Object, "GameObject", "GameObject").In("Force", .Vector3).Also("Push");
		Add("physics.addimpulse", "Physics", "Add Impulse", .Action, "if ({0} != null && {0}.HasComponent<Rigidbody>()) {0}.GetComponent<Rigidbody>().AddImpulse({1});")
			.In("Target", .Object, "GameObject", "GameObject").In("Impulse", .Vector3).Also("Launch Knock Back");
		Add("physics.addtorque", "Physics", "Add Torque", .Action, "if ({0} != null && {0}.HasComponent<Rigidbody>()) {0}.GetComponent<Rigidbody>().AddTorque({1});")
			.In("Target", .Object, "GameObject", "GameObject").In("Torque", .Vector3).Also("Spin");
		Add("physics.setvelocity", "Physics", "Set Physics Linear Velocity", .Action, "if ({0} != null && {0}.HasComponent<Rigidbody>()) {0}.GetComponent<Rigidbody>().Velocity = {1};")
			.In("Target", .Object, "GameObject", "GameObject").In("Velocity", .Vector3).Also("Set Velocity");
		Add("physics.velocity", "Physics", "Get Physics Linear Velocity", .Value, "(({0} != null && {0}.HasComponent<Rigidbody>()) ? {0}.GetComponent<Rigidbody>().Velocity : Vector3.Zero)")
			.In("Target", .Object, "GameObject", "GameObject").Out("", .Vector3).Also("Get Velocity Speed");

		// Audio.
		Add("audio.play2d", "Audio", "Play Sound 2D", .Action, "Audio.PlayOneShot2D({0}, {1});").In("Sound", .String).In("Volume", .Float).Default("1").Also("PlaySound2D UI Sound");
		Add("audio.playat", "Audio", "Play Sound at Location", .Action, "Audio.PlayOneShot({0}, {1}, {2});").In("Sound", .String).In("Location", .Vector3).In("Volume", .Float).Default("1").Also("PlaySoundAtLocation 3D");

		// Input (older shortcuts).
		Add("input.axis", "Input", "Axis", .Value, "Input.GetAxis({0})").In("Name", .String).Out("", .Float).Also("Get Input Axis Value");
		Add("input.space", "Input|Keyboard", "Space Held", .Value, "Input.GetKey(.Space)").Out("", .Bool);
		Add("input.spacepressed", "Input|Keyboard", "Space Pressed", .Value, "Input.GetKeyDown(.Space)").Out("", .Bool);
		Add("input.shift", "Input|Keyboard", "Shift Held", .Value, "Input.GetKey(.LeftShift)").Out("", .Bool);
		Add("input.mouse", "Input|Mouse", "Left Mouse Held", .Value, "Input.GetMouseButton(0)").Out("", .Bool).Also("Left Mouse Button");
		Add("input.rightmouse", "Input|Mouse", "Right Mouse Held", .Value, "Input.GetMouseButton(1)").Out("", .Bool).Also("Right Mouse Button");
		Add("input.mousepressed", "Input|Mouse", "Left Mouse Pressed", .Value, "Input.GetMouseButtonDown(0)").Out("", .Bool).Also("Click Left Mouse Button");
		Add("input.mousedelta", "Input|Mouse", "Mouse Delta", .Value, "Vector3(Input.MouseDelta.x, Input.MouseDelta.y, 0)").Out("", .Vector3).Also("Turn Look Mouse X Y");
	}

	/// Building blocks for subgraphs: a graph with a Sub Entry node can be used as a single node in other graphs.
	static void AddSubgraphNodes()
	{
		Add("sub.entry", "Subgraphs|Building Blocks", "Sub Entry", .Event, "Sub");
		Add("sub.param.float", "Subgraphs|Building Blocks", "Parameter (Number)", .Param, "").In("Name", .String).Out("", .Float);
		Add("sub.param.vector", "Subgraphs|Building Blocks", "Parameter (Vector)", .Param, "").In("Name", .String).Out("", .Vector3);
		Add("sub.param.bool", "Subgraphs|Building Blocks", "Parameter (Boolean)", .Param, "").In("Name", .String).Out("", .Bool);
		Add("sub.param.text", "Subgraphs|Building Blocks", "Parameter (Text)", .Param, "").In("Name", .String).Out("", .String);
		Add("sub.return.float", "Subgraphs|Building Blocks", "Return (Number)", .Return, "").In("", .Flow).In("Value", .Float);
		Add("sub.return.vector", "Subgraphs|Building Blocks", "Return (Vector)", .Return, "").In("", .Flow).In("Value", .Vector3);
		Add("sub.return.bool", "Subgraphs|Building Blocks", "Return (Boolean)", .Return, "").In("", .Flow).In("Value", .Bool);
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
			let group = mType.fromProject ? "" : (mType.group.IsEmpty ? (StringView)"Core" : mType.group);
			let path = scope String();
			path.AppendF("{}|{}", mType.fromProject ? "My Scripts" : ApiCategory(group), mCategory);
			let def = Add(key, path, scope $"{mCategory}: {title}" , kind, "");
			def.fromApi = true;
			def.fromGame = mType.fromProject;
			def.group.Set(group);
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
				Add(has, scope $"ECS|{info.name}", scope $"{info.name}: Has Component" , .Value,
scope $"({{0}} != null && {{0}}.HasComponent<{typeName}>())")
					.In("Object", .Object, "GameObject", "GameObject").Out("Has", .Bool);
			let add = scope $"ecs:{typeName}.add";
			if (Find(add) == null)
				Add(add, scope $"ECS|{info.name}", scope $"{info.name}: Add Component" , .Action,
scope $"if ({{0}} != null) {{0}}.AddComponent<{typeName}>();")
					.In("Object", .Object, "GameObject", "GameObject");
			let remove = scope $"ecs:{typeName}.remove";
			if (Find(remove) == null)
				Add(remove, scope $"ECS|{info.name}", scope $"{info.name}: Remove Component" , .Action,
scope $"if ({{0}} != null) {{0}}.RemoveComponent<{typeName}>();")
					.In("Object", .Object, "GameObject", "GameObject");
			// One visual graph can process a whole packed query without one script per object.
			// Its Object output is useful for traditional API calls, and its field
			// outputs read directly from the contiguous ECS column.
			let each = scope $"ecs:{typeName}.each";
			if (Find(each) == null)
			{
				let loop = Add(each, scope $"ECS|{info.name}", scope $"{info.name}: For Each" , .EcsEach, typeName)
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
					Add(get, scope $"ECS|{info.name}", scope $"{info.name}: Get {field.Name}" , .Value,
scope $"({{0}} != null && {{0}}.GetComponent<{typeName}>() != null ? {{0}}.GetComponent<{typeName}>().{field.Name} : default)")
						.In("Object", .Object, "GameObject", "GameObject").Out("Value", pin);
				let set = scope $"ecs:{typeName}.{field.Name}.set";
				if (Find(set) == null)
					Add(set, scope $"ECS|{info.name}", scope $"{info.name}: Set {field.Name}" , .Action,
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
