using System;
using System.Collections;
using System.IO;
using Tallow;

namespace Tallow.Editor;

/// The first-person character a new empty project starts with: a visual script (FirstPersonCharacter.tgraph) with a
/// comment box over each part, and the Beef code it compiles to. Both are kept in Editor/templates/empty and copied
/// into new projects; the test switch --write-first-person-template <folder> writes them again from Build below
/// after a change.
static class FirstPersonTemplate
{
	public const String GraphName = "FirstPersonCharacter";

	/// Fills a graph with the character: walk and sprint, jump, turn to face where the mouse looks, and a camera
	/// at eye height.
	public static void Build(NodeGraph graph)
	{
		graph.name.Set(GraphName);
		GraphNode Node(StringView key, Vector2 position)
		{
			let def = NodeLibrary.Find(key);
			Runtime.Assert(def != null, scope $"First-person template: no node {key}");
			return graph.AddNode(def, position);
		}
		GraphVariable Variable(StringView name, PinType type, StringView value)
		{
			let variable = graph.AddVariable(name, type);
			variable.value.Set(value);
			return variable;
		}
		void Link(GraphNode from, int32 fromPin, GraphNode to, int32 toPin)
		{
			let linked = graph.TryConnect(from, fromPin, to, toPin);
			Runtime.Assert(linked, scope $"First-person template: cannot link {from.def.key} to {to.def.key}");
		}

		let walkSpeed = Variable("walkSpeed", .Float, "5");
		let sprintSpeed = Variable("sprintSpeed", .Float, "9");
		let jumpSpeed = Variable("jumpSpeed", .Float, "6");
		let eyeHeight = Variable("eyeHeight", .Float, "0.7");
		// Pick the camera in the Inspector, or leave it empty to use the scene's Main Camera.
		let camera = Variable("camera", .Object, "");

		// Start: lock the mouse and find the camera.
		let start = Node("event.start", .(0, 0));
		let lockMouse = Node("input.lockmouse", .(260, 0));
		Link(start, 0, lockMouse, 0);
		let cameraForCheck = graph.AddVariableNode(camera, false, .(260, 120));
		let hasCamera = Node("flow.isvalid", .(520, 0));
		Link(lockMouse, 0, hasCamera, 0);
		Link(cameraForCheck, 0, hasCamera, 1);
		let findCamera = Node("game.find", .(520, 130));
		findCamera.values[0].Set("Main Camera");
		let setCamera = graph.AddVariableNode(camera, true, .(780, 0));
		Link(hasCamera, 1, setCamera, 0);
		Link(findCamera, 0, setCamera, 2);

		// Every frame. On Update's outputs: 1 Delta Time, 3 Move Direction, 4 Yaw, 6 Look Rotation, 8 Jump Pressed,
		// 9 Sprint.
		let update = Node("event.update", .(0, 400));

		// Walk and sprint.
		let walk = graph.AddVariableNode(walkSpeed, false, .(300, 470));
		let sprint = graph.AddVariableNode(sprintSpeed, false, .(300, 540));
		let speed = Node("logic.select", .(540, 430));
		Link(update, 9, speed, 0);
		Link(sprint, 0, speed, 1);
		Link(walk, 0, speed, 2);
		let velocity = Node("math.any.mul", .(800, 430));
		Link(update, 3, velocity, 0);
		Link(speed, 0, velocity, 1);

		// Jump: the jump speed on the frame Jump is pressed, otherwise 0.
		let jump = graph.AddVariableNode(jumpSpeed, false, .(300, 740));
		let jumpNow = Node("logic.select", .(540, 700));
		Link(update, 8, jumpNow, 0);
		Link(jump, 0, jumpNow, 1);

		// Move the character (it keeps its own gravity and only jumps from the ground).
		let move = Node("physics.charmove", .(1090, 430));
		Link(update, 0, move, 0);
		Link(velocity, 0, move, 2);
		Link(update, 1, move, 3);
		Link(jumpNow, 0, move, 4);

		// Turn the body to where the player looks (sideways only).
		let facing = Node("math.reuler", .(1090, 690));
		Link(update, 4, facing, 1);
		let turn = Node("transform.setrotation", .(1370, 690));
		Link(move, 0, turn, 0);
		Link(facing, 0, turn, 1);

		// The first-person camera: at eye height, looking up, down and around with the mouse.
		let cameraNow = graph.AddVariableNode(camera, false, .(1660, 560));
		let position = Node("transform.position", .(1660, 640));
		let eye = graph.AddVariableNode(eyeHeight, false, .(1660, 730));
		let eyeOffset = Node("math.vector", .(1900, 730));
		Link(eye, 0, eyeOffset, 1);
		let eyePosition = Node("math.any.add", .(2140, 640));
		Link(position, 0, eyePosition, 0);
		Link(eyeOffset, 0, eyePosition, 1);
		let placeCamera = Node("transform.objsetposition", .(2140, 430));
		Link(turn, 0, placeCamera, 0);
		Link(cameraNow, 0, placeCamera, 1);
		Link(eyePosition, 0, placeCamera, 2);
		let aimCamera = Node("transform.objsetrotation", .(2400, 430));
		Link(placeCamera, 0, aimCamera, 0);
		Link(cameraNow, 0, aimCamera, 1);
		Link(update, 6, aimCamera, 2);

		Comment(graph, "Start: lock the mouse and find the camera", .(0.30f, 0.45f, 0.35f, 1), start, lockMouse, cameraForCheck, hasCamera, findCamera, setCamera);
		Comment(graph, "Walk, or run while Sprint is held", .(0.35f, 0.42f, 0.55f, 1), walk, sprint, speed, velocity);
		Comment(graph, "Jump: only on the frame Jump is pressed", .(0.55f, 0.42f, 0.28f, 1), jump, jumpNow);
		Comment(graph, "Move the character (gravity is built in)", .(0.45f, 0.35f, 0.55f, 1), move);
		Comment(graph, "Turn the body to face where you look", .(0.55f, 0.32f, 0.32f, 1), facing, turn);
		Comment(graph, "First-person camera at eye height", .(0.28f, 0.48f, 0.52f, 1), cameraNow, position, eye, eyeOffset, eyePosition, placeCamera, aimCamera);
	}

	/// A comment box around some nodes, with room for its title above them.
	static void Comment(NodeGraph graph, StringView title, Color color, params Span<GraphNode> nodes)
	{
		var min = Vector2(float.MaxValue, float.MaxValue);
		var max = Vector2(float.MinValue, float.MinValue);
		for (let node in nodes)
		{
			let height = 26 + Math.Max(node.def.inputs.Count, node.def.outputs.Count) * 22 + 8;
			min = .(Math.Min(min.x, node.position.x), Math.Min(min.y, node.position.y));
			max = .(Math.Max(max.x, node.position.x + 190), Math.Max(max.y, node.position.y + height));
		}
		let comment = new GraphComment();
		comment.title.Set(title);
		comment.color = color;
		comment.position = min - Vector2(20, 54);
		comment.size = max - comment.position + Vector2(20, 20);
		graph.comments.Add(comment);
	}

	/// Writes the graph and its compiled code (namespace left as {NAMESPACE}, filled in per project) to a folder.
	public static void Write(StringView folder)
	{
		let graph = scope NodeGraph();
		Build(graph);
		Directory.CreateDirectory(folder).IgnoreError();
		graph.Save(scope $"{folder}/{GraphName}.tgraph");
		let code = scope String();
		graph.Compile("{NAMESPACE}", GraphName, scope $"{GraphName}.tgraph", code);
		File.WriteAllText(scope $"{folder}/{GraphName}.bf.txt", code).IgnoreError();
		Log.Info(scope $"FIRST-PERSON-TEMPLATE wrote {folder}");
	}
}
