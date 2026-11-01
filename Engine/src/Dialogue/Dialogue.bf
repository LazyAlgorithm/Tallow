using System;
using System.Collections;

namespace Tallow;

/// What one step of a dialogue does (see DialogueAsset for the file format).
enum DialogueStepKind : int32
{
	/// A speaker says a line: shown as a subtitle, with its voice recording if it has one.
	Say,
	/// One answer the player may pick. Choices next to each other are offered together.
	Choice,
	/// Sets a variable to a number.
	Set,
	/// Adds a number to a variable.
	Add,
	/// Tells the game something happened (DialogueRunner.OnEvent): open a gate, give an item, start a quest.
	Event,
	/// Carries on at another node.
	Goto,
	/// Ends the conversation.
	End
}

/// One step of a dialogue node.
class DialogueStep
{
	public DialogueStepKind kind;
	/// Say: the speaker's id ("-" or empty: a narrator, with no name shown).
	public String speaker = new .() ~ delete _;
	/// Say: the line. Choice: the answer as the player sees it.
	public String text = new .() ~ delete _;
	/// Say: a voice recording to play with the line (optional).
	public String audio = new .() ~ delete _;
	/// Say: how long the line stays up when it advances by itself, in seconds (0: from its recording, or its
	/// length in characters).
	public float time;
	/// Choice and Goto: the node to carry on at (a choice with none carries on after its group of choices).
	/// Set and Add: the variable. Event: the event's name.
	public String target = new .() ~ delete _;
	/// Set, Add and Event: the number.
	public float value;
	/// The step happens only when this holds ("metGuard", "!metGuard", "gold >= 10", joined with "and" / "or").
	/// Empty: always.
	public String condition = new .() ~ delete _;
	/// The line in the file it came from (for messages), 0 when it was made in code.
	public int32 line;

	public DialogueStep Clone()
	{
		let copy = new DialogueStep();
		copy.kind = kind;
		copy.speaker.Set(speaker);
		copy.text.Set(text);
		copy.audio.Set(audio);
		copy.time = time;
		copy.target.Set(target);
		copy.value = value;
		copy.condition.Set(condition);
		copy.line = line;
		return copy;
	}
}

/// A named part of a dialogue: steps run from the top until one waits for the player (a line or choices), the
/// conversation goes to another node, or the node runs out (which ends the conversation).
class DialogueNode
{
	public String name = new .() ~ delete _;
	public List<DialogueStep> steps = new .() ~ DeleteContainerAndItems!(_);
}

/// Someone who speaks in a dialogue: the id used in the file, the name shown with their lines, its colour, and
/// optionally the object in the scene their voice comes from.
class DialogueSpeaker
{
	public String id = new .() ~ delete _;
	public String name = new .() ~ delete _;
	public Color color = .White;
	/// The name of the object whose Audio Source plays this speaker's recordings (empty: the runner's own).
	public String objectName = new .() ~ delete _;
}

/// A conversation: speakers and nodes, read from a `.tdialogue` file. The file is plain text, one step to a line:
///
///   speaker guard "Gate Guard" color 1 0.8 0.3 object "Guard"
///
///   node start
///       say guard "Halt! Who goes there?" audio "Voice/halt.ogg"
///       choice "A friend." friend
///       choice "Let me through, or else." threat if courage >= 2
///       choice "Never mind."
///       end
///   node friend
///       set metGuard 1
///       say guard "Pass, friend."
///       event OpenGate
///   node threat
///       add courage -1
///       say guard "Ha! Try it." time 3
///       goto start
///
/// Lines starting with # are comments. Any step may end with `if <condition>` and is skipped when it does not hold.
/// `say - "..."` is a narrator. Variables (DialogueVariables) are numbers; a missing one is 0, and true is 1.
class DialogueAsset
{
	public String path = new .() ~ delete _;
	public List<DialogueSpeaker> speakers = new .() ~ DeleteContainerAndItems!(_);
	public List<DialogueNode> nodes = new .() ~ DeleteContainerAndItems!(_);
	/// What was wrong with the file, one problem to a line ("line 12: ..."). Empty when it is fine.
	public String problems = new .() ~ delete _;

	static Dictionary<String, DialogueAsset> sCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);

	/// The dialogue in a project file, read once and kept (null when the file cannot be read). Its problems are
	/// written to the log the first time.
	public static DialogueAsset Load(StringView path)
	{
		if (path.IsEmpty)
			return null;
		if (sCache.TryGetValueAlt(path, let cached))
			return cached;
		let text = scope String();
		DialogueAsset asset = null;
		if (Assets.ReadText(path, text))
		{
			asset = new DialogueAsset();
			asset.path.Set(path);
			asset.Parse(text);
			for (let problem in asset.problems.Split('\n', .RemoveEmptyEntries))
				Log.Warning(scope $"{path}: {problem}");
		}
		else
			Log.Warning(scope $"Dialogue {path} could not be read.");
		sCache[new String(path)] = asset;
		return asset;
	}

	/// Forgets every dialogue read so far (after one is changed on disk).
	public static void ClearCache()
	{
		for (let (key, value) in sCache)
		{
			delete key;
			delete value;
		}
		sCache.Clear();
	}

	/// Forgets one dialogue read so far, so it is read again from its file.
	public static void Forget(StringView path)
	{
		if (sCache.GetAndRemoveAlt(path) case .Ok(let entry))
		{
			delete entry.key;
			delete entry.value;
		}
	}

	public DialogueNode FindNode(StringView name)
	{
		for (let node in nodes)
		{
			if (node.name == name)
				return node;
		}
		return null;
	}

	public int NodeIndex(StringView name)
	{
		for (int i < nodes.Count)
		{
			if (nodes[i].name == name)
				return i;
		}
		return -1;
	}

	public DialogueSpeaker FindSpeaker(StringView id)
	{
		for (let speaker in speakers)
		{
			if (speaker.id == id)
				return speaker;
		}
		return null;
	}

	/// Reads the file's text, replacing what the dialogue held.
	public void Parse(StringView text)
	{
		ClearAndDeleteItems(speakers);
		ClearAndDeleteItems(nodes);
		problems.Clear();
		DialogueNode node = null;
		int32 lineNumber = 0;
		let tokens = scope List<StringView>();
		let storage = scope List<String>();
		for (let rawLine in text.Split('\n'))
		{
			lineNumber++;
			var line = StringView(rawLine)..Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			tokens.Clear();
			ClearAndDeleteItems(storage);
			SceneSerializer.Tokenize(line, tokens, storage);
			if (tokens.IsEmpty)
				continue;
			let keyword = tokens[0];
			if (keyword == "speaker")
			{
				ParseSpeaker(tokens, lineNumber);
				continue;
			}
			if (keyword == "node")
			{
				if (tokens.Count < 2)
				{
					problems.AppendF("line {}: a node needs a name\n", lineNumber);
					continue;
				}
				if (FindNode(tokens[1]) != null)
					problems.AppendF("line {}: there is already a node called '{}'\n", lineNumber, tokens[1]);
				node = new DialogueNode();
				node.name.Set(tokens[1]);
				nodes.Add(node);
				continue;
			}
			if (node == null)
			{
				problems.AppendF("line {}: '{}' comes before the first node\n", lineNumber, keyword);
				continue;
			}
			let step = ParseStep(tokens, lineNumber);
			if (step != null)
				node.steps.Add(step);
		}
		ClearAndDeleteItems(storage);
		Check();
	}

	void ParseSpeaker(List<StringView> tokens, int32 lineNumber)
	{
		if (tokens.Count < 2)
		{
			problems.AppendF("line {}: a speaker needs an id\n", lineNumber);
			return;
		}
		let speaker = new DialogueSpeaker();
		speaker.id.Set(tokens[1]);
		speaker.name.Set(tokens.Count > 2 && tokens[2] != "color" && tokens[2] != "object" ? tokens[2] : tokens[1]);
		for (int i = 2; i < tokens.Count; i++)
		{
			if (tokens[i] == "color" && i + 3 < tokens.Count)
			{
				speaker.color = .(Number(tokens[i + 1]), Number(tokens[i + 2]), Number(tokens[i + 3]), 1);
				i += 3;
			}
			else if (tokens[i] == "object" && i + 1 < tokens.Count)
				speaker.objectName.Set(tokens[++i]);
		}
		speakers.Add(speaker);
	}

	static float Number(StringView token) => float.Parse(token) case .Ok(let value) ? value : 0;

	DialogueStep ParseStep(List<StringView> tokens, int32 lineNumber)
	{
		// Everything after "if" is the condition.
		int end = tokens.Count;
		for (int i = 1; i < tokens.Count; i++)
		{
			if (tokens[i] == "if")
			{
				end = i;
				break;
			}
		}
		let step = new DialogueStep();
		step.line = lineNumber;
		for (int i = end + 1; i < tokens.Count; i++)
		{
			if (!step.condition.IsEmpty)
				step.condition.Append(' ');
			step.condition.Append(tokens[i]);
		}
		if (end < tokens.Count && step.condition.IsEmpty)
			problems.AppendF("line {}: 'if' needs a condition after it\n", lineNumber);
		bool ok = true;
		switch (tokens[0])
		{
		case "say":
			step.kind = .Say;
			ok = end >= 3;
			if (ok)
			{
				step.speaker.Set(tokens[1] == "-" ? "" : tokens[1]);
				step.text.Set(tokens[2]);
				for (int i = 3; i < end; i++)
				{
					if (tokens[i] == "audio" && i + 1 < end)
						step.audio.Set(tokens[++i]);
					else if (tokens[i] == "time" && i + 1 < end)
						step.time = Number(tokens[++i]);
				}
			}
		case "choice":
			step.kind = .Choice;
			ok = end >= 2;
			if (ok)
			{
				step.text.Set(tokens[1]);
				if (end >= 3)
					step.target.Set(tokens[2]);
			}
		case "set","add":
			step.kind = tokens[0] == "set" ? .Set : .Add;
			ok = end >= 3 && (float.Parse(tokens[2]) case .Ok);
			if (ok)
			{
				step.target.Set(tokens[1]);
				step.value = Number(tokens[2]);
			}
		case "event":
			step.kind = .Event;
			ok = end >= 2;
			if (ok)
			{
				step.target.Set(tokens[1]);
				step.value = end >= 3 ? Number(tokens[2]) : 0;
			}
		case "goto":
			step.kind = .Goto;
			ok = end >= 2;
			if (ok)
				step.target.Set(tokens[1]);
		case "end":
			step.kind = .End;
		default:
			problems.AppendF("line {}: unknown step '{}' (use say, choice, set, add, event, goto or end)\n", lineNumber, tokens[0]);
			delete step;
			return null;
		}
		if (!ok)
		{
			problems.AppendF("line {}: '{}' is missing something; see docs/dialogue.md\n", lineNumber, tokens[0]);
			delete step;
			return null;
		}
		return step;
	}

	/// Looks for jumps to nodes that do not exist and lines by speakers that are not declared.
	void Check()
	{
		for (let node in nodes)
		{
			for (let step in node.steps)
			{
				if ((step.kind == .Goto || step.kind == .Choice) && !step.target.IsEmpty && FindNode(step.target) == null)
					problems.AppendF("line {}: there is no node called '{}'\n", step.line, step.target);
				if (step.kind == .Say && !step.speaker.IsEmpty && FindSpeaker(step.speaker) == null)
					problems.AppendF("line {}: speaker '{}' is not declared (add: speaker {} \"Name\")\n", step.line, step.speaker, step.speaker);
			}
		}
	}

	/// Writes the dialogue back as a file's text (comments in the original are not kept).
	public void Write(String text)
	{
		for (let speaker in speakers)
		{
			text.AppendF("speaker {} ", speaker.id);
			SceneSerializer.Quote(speaker.name, text);
			if (speaker.color != .White)
				text.AppendF(" color {} {} {}", speaker.color.r, speaker.color.g, speaker.color.b);
			if (!speaker.objectName.IsEmpty)
			{
				text.Append(" object ");
				SceneSerializer.Quote(speaker.objectName, text);
			}
			text.Append('\n');
		}
		for (let node in nodes)
		{
			text.AppendF("\nnode {}\n", node.name);
			for (let step in node.steps)
			{
				text.Append('\t');
				WriteStep(step, text);
				text.Append('\n');
			}
		}
	}

	static void WriteStep(DialogueStep step, String text)
	{
		switch (step.kind)
		{
		case .Say:
			text.AppendF("say {} ", step.speaker.IsEmpty ? "-" : step.speaker);
			SceneSerializer.Quote(step.text, text);
			if (!step.audio.IsEmpty)
			{
				text.Append(" audio ");
				SceneSerializer.Quote(step.audio, text);
			}
			if (step.time > 0)
				text.AppendF(" time {}", step.time);
		case .Choice:
			text.Append("choice ");
			SceneSerializer.Quote(step.text, text);
			if (!step.target.IsEmpty)
				text.AppendF(" {}", step.target);
		case .Set,.Add:
			text.AppendF("{} {} {}", step.kind == .Set ? "set" : "add", step.target, step.value);
		case .Event:
			text.AppendF("event {}", step.target);
			if (step.value != 0)
				text.AppendF(" {}", step.value);
		case .Goto:
			text.AppendF("goto {}", step.target);
		case .End:
			text.Append("end");
		}
		if (!step.condition.IsEmpty)
			text.AppendF(" if {}", step.condition);
	}

}

/// The numbers dialogues remember (`set`, `add`, conditions): shared by every dialogue in the game, kept while the
/// game runs and saved with it by any Dialogue Runner in the scene. Games can read and change them too:
///
///   DialogueVariables.Set("gold", 25);
///   if (DialogueVariables.Get("metGuard") > 0) ...
static class DialogueVariables
{
	static Dictionary<String, float> sValues = new .() ~ DeleteDictionaryAndKeys!(_);

	public static Dictionary<String, float> All => sValues;

	public static float Get(StringView name) => sValues.TryGetValueAlt(name, let value) ? value : 0;

	public static void Set(StringView name, float value)
	{
		if (name.IsEmpty || !value.IsFinite)
			return;
		if (sValues.TryGetAlt(name, let key, ?))
			sValues[key] = value;
		else
			sValues[new String(name)] = value;
	}

	public static void Add(StringView name, float amount) => Set(name, Get(name) + amount);

	public static void Clear()
	{
		for (let key in sValues.Keys)
			delete key;
		sValues.Clear();
	}

	/// The variables as text, "name value" to a line, in name order (for saving).
	public static void ToText(String text)
	{
		let names = scope List<StringView>();
		for (let key in sValues.Keys)
			names.Add(key);
		names.Sort(scope (a, b) => a.CompareTo(b));
		for (let name in names)
			text.AppendF("{} {}\n", name, sValues[scope String(name)]);
	}

	/// Replaces the variables with ones written by ToText.
	public static void FromText(StringView text)
	{
		Clear();
		for (let line in text.Split('\n', .RemoveEmptyEntries))
		{
			let space = line.LastIndexOf(' ');
			if (space <= 0)
				continue;
			if (float.Parse(line.Substring(space + 1)..Trim()) case .Ok(let value))
				Set(line.Substring(0, space)..Trim(), value);
		}
	}

	/// Whether a condition holds: "name" (not 0), "!name" (0), "name op number" with op one of == != < <= > >=,
	/// joined left to right with "and" / "or". Empty holds.
	public static bool Evaluate(StringView condition)
	{
		if (condition.IsEmpty)
			return true;
		let parts = scope List<StringView>();
		for (let part in condition.Split(' ', .RemoveEmptyEntries))
			parts.Add(part);
		bool result = true;
		bool joinAnd = true;
		int i = 0;
		while (i < parts.Count)
		{
			bool term;
			let first = parts[i];
			if (i + 2 < parts.Count && IsComparison(parts[i + 1]))
			{
				let left = Get(first);
				let right = float.Parse(parts[i + 2]) case .Ok(let number) ? number : Get(parts[i + 2]);
				term = Compare(left, parts[i + 1], right);
				i += 3;
			}
			else
			{
				term = first.StartsWith('!') ? Get(first.Substring(1)) == 0 : Get(first) != 0;
				i += 1;
			}
			result = joinAnd ? (result && term) : (result || term);
			if (i < parts.Count)
			{
				joinAnd = parts[i] != "or";
				i++;
			}
		}
		return result;
	}

	static bool IsComparison(StringView op) => op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=";

	static bool Compare(float left, StringView op, float right)
	{
		switch (op)
		{
		case "==": return Math.Abs(left - right) < 1e-5f;
		case "!=": return Math.Abs(left - right) >= 1e-5f;
		case "<": return left < right;
		case "<=": return left <= right;
		case ">": return left > right;
		default: return left >= right;
		}
	}
}

/// What a conversation is showing.
enum DialogueView : int32
{
	/// Not started (or stopped).
	None,
	/// A line, waiting for Advance.
	Line,
	/// Answers to pick from, waiting for Choose.
	Choices,
	/// Finished.
	Ended
}

/// A conversation in progress: where it is in a dialogue and what it shows. Pure logic (no drawing, no sound):
/// the Dialogue Runner component shows it, and tests and the editor's preview drive it directly.
class DialogueConversation
{
	public DialogueAsset Asset;
	public DialogueView View;
	/// The node and step it is at.
	public int32 NodeIndex = -1;
	public int32 StepIndex;
	/// The line shown (View == Line).
	public DialogueStep Line;
	/// The answers offered (View == Choices): each choice step that passed its condition, in order.
	public List<DialogueStep> Choices = new .() ~ delete _;
	/// Steps run to show the current line or choices; a loop of gotos with nothing to show is stopped.
	public const int MaxStepsAtOnce = 1000;
	/// Called for each `event` step: its name and number.
	public Event<delegate void(StringView name, float value)> OnEvent ~ _.Dispose();

	int32 mChoicesEnd;

	public DialogueNode Node => Asset != null && NodeIndex >= 0 && NodeIndex < Asset.nodes.Count ? Asset.nodes[NodeIndex] : null;
	public bool IsRunning => View == .Line || View == .Choices;

	/// Starts the dialogue at a node and runs to the first line or choices. False when there is no such node.
	public bool Start(DialogueAsset asset, StringView node)
	{
		Asset = asset;
		Choices.Clear();
		Line = null;
		let index = asset != null ? asset.NodeIndex(node) : -1;
		if (index < 0)
		{
			View = .Ended;
			return false;
		}
		NodeIndex = (int32)index;
		StepIndex = 0;
		Run();
		return true;
	}

	/// Goes on from the line shown. Does nothing unless a line is shown.
	public void Advance()
	{
		if (View != .Line)
			return;
		StepIndex++;
		Run();
	}

	/// Picks one of the answers offered (0 is the first). False when no answers are offered or there is no such one.
	public bool Choose(int index)
	{
		if (View != .Choices || index < 0 || index >= Choices.Count)
			return false;
		let choice = Choices[index];
		if (choice.target.IsEmpty)
			StepIndex = mChoicesEnd;
		else if (!Jump(choice.target))
			return true;
		Run();
		return true;
	}

	/// Ends the conversation where it is.
	public void Stop()
	{
		View = .Ended;
		Line = null;
		Choices.Clear();
	}

	/// Puts the conversation back at a node and step (from a save, or the server) without running the steps before
	/// it: what is there is shown again.
	public bool Restore(DialogueAsset asset, int32 nodeIndex, int32 stepIndex)
	{
		Asset = asset;
		if (asset == null || nodeIndex < 0 || nodeIndex >= asset.nodes.Count)
		{
			Stop();
			return false;
		}
		NodeIndex = nodeIndex;
		StepIndex = Math.Max(stepIndex, 0);
		Run();
		return true;
	}

	bool Jump(StringView node)
	{
		let index = Asset.NodeIndex(node);
		if (index < 0)
		{
			Log.Warning(scope $"{Asset.path}: there is no node called '{node}'; the conversation ends.");
			Stop();
			return false;
		}
		NodeIndex = (int32)index;
		StepIndex = 0;
		return true;
	}

	void Run()
	{
		Line = null;
		Choices.Clear();
		for (int guard < MaxStepsAtOnce)
		{
			let node = Node;
			if (node == null || StepIndex >= node.steps.Count)
			{
				View = .Ended;
				return;
			}
			let step = node.steps[StepIndex];
			if (step.kind == .Choice)
			{
				// The whole group of choices together, less those whose condition does not hold.
				int32 end = StepIndex;
				while (end < node.steps.Count && node.steps[end].kind == .Choice)
				{
					if (DialogueVariables.Evaluate(node.steps[end].condition))
						Choices.Add(node.steps[end]);
					end++;
				}
				mChoicesEnd = end;
				if (Choices.IsEmpty)
				{
					StepIndex = end;
					continue;
				}
				View = .Choices;
				return;
			}
			if (!DialogueVariables.Evaluate(step.condition))
			{
				StepIndex++;
				continue;
			}
			switch (step.kind)
			{
			case .Say:
				Line = step;
				View = .Line;
				return;
			case .Set:
				DialogueVariables.Set(step.target, step.value);
				StepIndex++;
			case .Add:
				DialogueVariables.Add(step.target, step.value);
				StepIndex++;
			case .Event:
				// Past the event before it is announced, so the game may stop or restart the conversation from it.
				StepIndex++;
				OnEvent(step.target, step.value);
				if (View == .Ended || View == .None)
					return;
			case .Goto:
				if (!Jump(step.target))
					return;
			case .End:
				View = .Ended;
				return;
			case .Choice:
			}
		}
		Log.Warning(scope $"{Asset.path}: node '{Node?.name}' goes round without showing anything; the conversation ends.");
		View = .Ended;
	}
}
