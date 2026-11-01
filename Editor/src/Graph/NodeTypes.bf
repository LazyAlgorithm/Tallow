using System;
using System.Collections;
using System.IO;
using System.Reflection;
using Tallow;

namespace Tallow.Editor;

/// What travels along a link. Object is any reference or engine value type (a GameObject, a component, a
/// RaycastHit); its pin names the exact type. Enum names its enum the same way.
enum PinType { Flow, Float, Bool, Vector3, String, Int, Object, Enum, Vector2, Quaternion, Color }

enum NodeKind { Event, Action, Value, Branch, Param, Return, GetVariable, SetVariable, Loop, While, ShaderOutput }

struct PinDef
{
	public String name;
	public PinType type;
	/// The Beef type behind an Object or Enum pin ("AudioSource", "KeyCode"), and behind any output that is kept
	/// in a local variable. Null when the pin type says it all.
	public String typeName;
	/// Inputs: the code used when nothing is connected and the pin has no literal ("GetComponent<AudioSource>()").
	/// Outputs: the code that reads the value ("input.Yaw"); "$N" stands for the node's id. In a shader graph "$V"
	/// stands for the node's value, for nodes with several outputs ("$V.x").
	public String code;
	/// Inputs: the value a new node starts with, when not the type's own default.
	public String initial;
}

/// A kind of node: its pins and the Beef code it turns into.
class NodeDef
{
	public String key = new .() ~ delete _;
	public String title = new .() ~ delete _;
	public String category = new .() ~ delete _;
	public NodeKind kind;
	public List<PinDef> inputs = new .() ~ { ClearPins(_); delete _; };
	public List<PinDef> outputs = new .() ~ { ClearPins(_); delete _; };
	/// Code with {0}, {1}... standing for the data inputs. For events it is the method name.
	public String code = new .() ~ delete _;
	/// Events: the whole method declaration when it is not simply "public override void Name()".
	public String signature = new .() ~ delete _;
	/// Events: a condition (with {0}... for the inputs) the event's flow runs under, for events that share a method.
	public String guard = new .() ~ delete _;
	/// The class the generated component must be built on for this node to work, if not Component.
	public String requiresBase = new .() ~ delete _;
	/// Generated from source by ApiIndex rather than written by hand.
	/// A node of a shader graph (.tsgraph) rather than of a script graph: its code is GLSL.
	public bool isShader;
	public bool fromApi;
	/// For nodes read from source: the part of the engine ("Audio"), or "" for the game's own scripts.
	public String group = new .() ~ delete _;
	public bool fromGame;

	public static void ClearPins(List<PinDef> pins)
	{
		for (let p in pins)
		{
			delete p.name;
			delete p.typeName;
			delete p.code;
			delete p.initial;
		}
		pins.Clear();
	}

	static PinDef Pin(StringView name, PinType type, StringView typeName, StringView code)
	{
		PinDef p = default;
		p.name = new String(name);
		p.type = type;
		if (!typeName.IsEmpty)
			p.typeName = new String(typeName);
		if (!code.IsEmpty)
			p.code = new String(code);
		return p;
	}

	public NodeDef In(StringView name, PinType type, StringView typeName = "", StringView fallback = "")
	{
		inputs.Add(Pin(name, type, typeName, fallback));
		return this;
	}

	/// Sets the value the last input added starts with on a new node.
	public NodeDef Default(StringView value)
	{
		var pin = ref inputs[inputs.Count - 1];
		String.NewOrSet!(pin.initial, value);
		return this;
	}

	public NodeDef Out(StringView name, PinType type, StringView typeName = "", StringView code = "")
	{
		outputs.Add(Pin(name, type, typeName, code));
		return this;
	}

	/// True when the node runs in a flow and also hands back values, which are kept in local variables.
	public bool HasResults
	{
		get
		{
			if (kind != .Action)
				return false;
			for (let pin in outputs)
			{
				if (pin.type != .Flow)
					return true;
			}
			return false;
		}
	}
}

/// One node placed in a visual-scripting graph: what kind it is, where it sits, and the values typed into its
/// unconnected inputs.
class GraphNode
{
	public int32 id;
	public NodeDef def;
	public Vector2 position;
	/// Literal used for each input that has nothing connected.
	public List<String> values = new .() ~ DeleteContainerAndItems!(_);
}

/// A value stored on the generated component. It becomes a public field, so each object can set it in the Inspector.
class GraphVariable
{
	public String name = new .() ~ delete _;
	public PinType type = .Float;
	/// Default, written the same way as a pin literal.
	public String value = new .("0") ~ delete _;
	/// Shared in multiplayer: the server's value is copied to every client (the field is marked [Sync]).
	public bool networked;
}

struct GraphLink
{
	public int32 fromNode;
	public int32 fromPin;
	public int32 toNode;
	public int32 toPin;
}
