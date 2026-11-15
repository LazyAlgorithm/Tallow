using System;
using System.Collections;
using System.IO;

namespace Tallow.Editor;

/// Visual scripting graphs in C# projects compile to C# (NodeGraph.csharp). Node code is written in Beef; most of
/// it reads the same in C#, and this turns the rest over: type names, Beef's shorthand ("let", ".(", "scope"), the
/// lower-case vector members and float maths. A node whose code needs more says so with NodeDef.cs.
static class GraphCSharp
{
	static bool IsWordChar(char8 c) => c.IsLetterOrDigit || c == '_';

	/// Replaces a whole word (not part of a longer name).
	static void Word(String text, StringView from, StringView to)
	{
		int at = 0;
		while ((at = text.IndexOf(from, at)) >= 0)
		{
			let end = at + from.Length;
			let before = (at > 0) ? text[at - 1] : ' ';
			let after = (end < text.Length) ? text[end] : ' ';
			if (IsWordChar(before) || IsWordChar(after) || before == '.')
			{
				at = end;
				continue;
			}
			text.Remove(at, from.Length);
			text.Insert(at, to);
			at += to.Length;
		}
	}

	/// Replaces a member access ".from" with ".to" when from is the whole member name.
	static void MemberWord(String text, StringView from, StringView to)
	{
		int at = 0;
		while ((at = text.IndexOf(scope $".{from}", at)) >= 0)
		{
			let end = at + 1 + from.Length;
			if ((end < text.Length) && IsWordChar(text[end]))
			{
				at = end;
				continue;
			}
			text.Remove(at + 1, from.Length);
			text.Insert(at + 1, to);
			at += 1 + to.Length;
		}
	}

	/// Puts "new " before a constructor call Beef writes bare ("Vector3(1, 2, 3)").
	static void Construct(String text, StringView type)
	{
		let call = scope $"{type}(";
		int at = 0;
		while ((at = text.IndexOf(call, at)) >= 0)
		{
			let before = (at > 0) ? text[at - 1] : ' ';
			let isNew = (at >= 4) && StringView(text, at - 4, 4) == "new ";
			if (IsWordChar(before) || before == '.' || isNew)
			{
				at += call.Length;
				continue;
			}
			text.Insert(at, "new ");
			at += 4 + call.Length;
		}
	}

	/// Replaces a member access ".x" with ".X" when the letter is the whole member name.
	static void Member(String text, char8 from, char8 to)
	{
		for (int i = 0; i + 1 < text.Length; i++)
		{
			if (text[i] != '.' || text[i + 1] != from)
				continue;
			let after = (i + 2 < text.Length) ? text[i + 2] : ' ';
			let before = (i > 0) ? text[i - 1] : ' ';
			// "1.x" is not a member; "foo.x" and ").x" are.
			if (IsWordChar(after) || before.IsDigit)
				continue;
			text[i + 1] = to;
		}
	}

	public static void FromBeef(StringView beef, String output)
	{
		let text = scope String(beef);
		Word(text, "int32", "int");
		Word(text, "int64", "long");
		Word(text, "uint32", "uint");
		Word(text, "uint64", "ulong");
		Word(text, "StringView", "string");
		Word(text, "String", "string");
		Word(text, "let", "var");
		text.Replace("scope $\"", "$\"");
		text.Replace("scope String(", "(");
		text.Replace("===", "==");
		text.Replace("!==", "!=");
		// The engine's Beef API by its Tallow.API names.
		text.Replace("NetworkSync.IsMine(this)", "IsMine");
		text.Replace("NetworkSync.InSession(Scene)", "Scene.IsNetworked");
		text.Replace("NetworkSync.SendEvent(this, ", "SendNetworkEvent(");
		text.Replace("(Scene.Network == null || Scene.Network.IsServer)", "Scene.IsServer");
		text.Replace("Scene.Physics.Raycast(", "GraphRuntime.Raycast(Scene, ");
		text.Replace("Scene.Physics.SphereCast(", "GraphRuntime.SphereCast(Scene, ");
		text.Replace("Scene.Destroy(", "GraphRuntime.Destroy(");
		text.Replace("Input.LockCursor", "Cursor.Locked");
		text.Replace("gRand.", "GraphRuntime.Random.");
		text.Replace("= null;", "= default;");
		// A C# GameObject is a handle that is never null: ask whether it is still there.
		for (int i < 10)
		{
			text.Replace(scope $"{{{i}}} != null", scope $"GraphRuntime.IsValid({{{i}}})");
			text.Replace(scope $"{{{i}}} == null", scope $"!GraphRuntime.IsValid({{{i}}})");
		}
		text.Replace("GameObject != null", "GraphRuntime.IsValid(GameObject)");
		Word(text, "RaycastHit", "GraphHit");
		Word(text, "ShapeCastHit", "GraphHit");
		MemberWord(text, "gameObject", "GameObject");
		MemberWord(text, "point", "Point");
		MemberWord(text, "normal", "Normal");
		MemberWord(text, "distance", "Distance");
		// Beef's Time.Time (a C# member cannot share its class's name).
		MemberWord(text, "Time", "GameTime");
		for (let call in StringView[?]("GetMouseButton(", "GetMouseButtonDown(", "GetMouseButtonUp("))
		{
			int at = 0;
			while ((at = text.IndexOf(call, at)) >= 0)
			{
				at += call.Length;
				if (at < text.Length && text[at].IsDigit)
					text.Insert(at, "(MouseButton)");
			}
		}
		for (let type in StringView[?]("Vector2", "Vector3", "Vector4", "Color", "Quaternion"))
			Construct(text, type);
		text.Replace(".Pressed(.", ".Pressed(InputButton.");
		for (let call in StringView[?]("GetKey(", "GetKeyDown(", "GetKeyUp("))
			text.Replace(scope $"{call}.", scope $"{call}KeyCode.");
		text.Replace(".Released(.", ".Released(InputButton.");
		text.Replace(".Held(.", ".Held(InputButton.");
		// Float maths: System.Math's double functions would not assign back to float.
		for (let name in StringView[?]("Sqrt", "Pow", "Sin", "Cos", "Tan", "Asin", "Acos", "Atan", "Atan2", "Floor", "Ceiling", "Round", "Exp", "Log", "Log10", "Truncate"))
			text.Replace(scope $"Math.{name}(", scope $"MathF.{name}(");
		Member(text, 'x', 'X');
		Member(text, 'y', 'Y');
		Member(text, 'z', 'Z');
		Member(text, 'w', 'W');
		Member(text, 'r', 'R');
		Member(text, 'g', 'G');
		Member(text, 'b', 'B');
		Member(text, 'a', 'A');
		// Beef's ".(a, b)" makes a value of the type the context wants; C#'s "new(a, b)" does too.
		for (int i = 0; i + 1 < text.Length; i++)
		{
			if (text[i] == '.' && text[i + 1] == '(' && (i == 0 || !IsWordChar(text[i - 1]) && text[i - 1] != ')' && text[i - 1] != ']'))
			{
				text.Remove(i, 1);
				text.Insert(i, "new");
				i += 3;
			}
		}
		// Beef's StringView(x) and String(x) views or copies text; a C# string is that already.
		for (int i = 0; i + 7 <= text.Length; i++)
		{
			if (StringView(text, i, 7) == "string(" && (i == 0 || !IsWordChar(text[i - 1]) && text[i - 1] != '.'))
				text.Remove(i, 6);
		}
		output.Append(text);
	}

	/// Compiles a graph file to C# beside it (Name.cs), without the editor: the launcher's --graph-compile switch,
	/// for tests and build scripts. The project's subgraphs are found as the editor finds them (under src/).
	public static bool CompileFile(StringView graphPath, StringView namespaceName, String scriptPath, String error)
	{
		NodeLibrary.CSharp = true;
		// The project's C# nodes (.tallow-csharp/graph-nodes.tsv, from its last build), from the folder above with
		// project.tallow in it.
		let folder = Path.GetDirectoryPath(graphPath, .. scope String());
		for (int depth < 32)
		{
			if (File.Exists(scope $"{folder}/project.tallow"))
			{
				NodeLibrary.RefreshCSharpScripts(folder);
				// Subgraph nodes are named by their file under the project's assets (src/), and their methods are
				// read from there when the graph is compiled.
				if (Assets.ProjectPath.IsEmpty)
					Assets.ProjectPath.Set(scope $"{folder}/src");
				NodeLibrary.RefreshSubgraphs(Assets.ProjectPath);
				break;
			}
			let parent = scope String();
			// No project above it: compile with the built-in nodes only (the root has no parent).
			if (Path.GetDirectoryPath(folder, parent) case .Err || parent.IsEmpty || parent == folder)
				break;
			folder.Set(parent);
		}
		let graph = scope NodeGraph();
		if (!graph.Load(graphPath))
		{
			error.AppendF("Could not read the graph {}", graphPath);
			return false;
		}
		Path.GetFileNameWithoutExtension(graphPath, graph.name..Clear());
		graph.csharp = true;
		let code = scope String();
		graph.Compile(namespaceName, graph.name, Path.GetFileName(graphPath, .. scope .()), code);
		scriptPath.Append(graphPath.Substring(0, graphPath.Length - Path.GetExtension(graphPath, .. scope .()).Length));
		scriptPath.Append(".cs");
		if (File.WriteAllText(scriptPath, code) case .Err)
		{
			error.AppendF("Could not write {}", scriptPath);
			return false;
		}
		return true;
	}

	/// The graph node a line of a generated C# file belongs to: the "// #id" mark on it, or on the nearest line
	/// above it in the same method. -1 when there is none (a field, or a line before any node).
	public static int32 NodeAt(StringView code, int32 line)
	{
		let lines = scope List<StringView>();
		for (let text in code.Split('\n'))
			lines.Add(text);
		for (int i = Math.Min(line, (int32)lines.Count - 1); i >= 0; i--)
		{
			var text = lines[i];
			text.TrimEnd();
			let mark = text.IndexOf("// #");
			if (mark >= 0)
			{
				if (int32.Parse(text.Substring(mark + 4)) case .Ok(let id))
					return id;
			}
			// A method's start: what is above it is another method's.
			if (text.StartsWith("\tpublic ") || text == "\t{")
				break;
		}
		return -1;
	}

	/// The C# for an event's method when the node does not give its whole declaration.
	public static void Signature(StringView method, String output)
	{
		switch (method)
		{
		case "FixedUpdate", "LocalEarlyUpdate", "LocalUpdate", "LocalLateUpdate":
			output.AppendF("public override void {}(float deltaTime)", method);
		case "EarlyUpdate", "LateUpdate": output.AppendF("public override void {}(TickInput input, float deltaTime)", method);
		default: output.AppendF("public override void {}()", method);
		}
	}

	/// The base call that starts it.
	public static void BaseCall(StringView method, String output)
	{
		switch (method)
		{
		case "FixedUpdate", "LocalEarlyUpdate", "LocalUpdate", "LocalLateUpdate": output.AppendF("base.{}(deltaTime);", method);
		case "EarlyUpdate", "LateUpdate": output.AppendF("base.{}(input, deltaTime);", method);
		default: output.AppendF("base.{}();", method);
		}
	}
}
