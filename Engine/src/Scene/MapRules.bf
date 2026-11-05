using System;
using System.Collections;
using System.IO;

namespace Tallow;

/// One line of a game's MapRules.txt: a map needs at least Count components of a type (or, for a "most" rule, may
/// have no more than Count), or only those whose field passes a test ("raceOrder >= 0").
class MapRule
{
	public int32 Count;
	/// A limit ("most") rather than a need.
	public bool AtMost;
	/// The component's full name, "Tallow.SpawnPoint".
	public String Component = new .() ~ delete _;
	/// Empty when every component of the type counts.
	public String Field = new .() ~ delete _;
	public String Compare = new .() ~ delete _;
	public double Value;
	/// What the components are, for the warning ("spawn points"). The component's name when the rule gives none.
	public String What = new .() ~ delete _;

	public bool Passes(double value)
	{
		switch (Compare)
		{
		case "=","==": return value == Value;
		case "!=": return value != Value;
		case "<": return value < Value;
		case "<=": return value <= Value;
		case ">": return value > Value;
		case ">=": return value >= Value;
		default: return false;
		}
	}
}

/// What a scene needs to be played as a map in this game: MapRules.txt in the game's files (src/MapRules.txt in a
/// project). MapFiles.Find refuses a map that breaks a rule, and the editor warns when such a scene is saved or
/// exported. One rule a line:
///
///   need 4 Tallow.SpawnPoint "spawn points"
///   need 2 MyGame.Checkpoint order >= 0 "checkpoints with an order"
///   most 500 Tallow.Rigidbody "physics items"
///   ignore Scenes/MainMenu.tscene
///
/// A field test compares the field's number (a bool is 1 or 0); a component that leaves the field out of the scene
/// file has the field's default. ignore names a scene that is not a map, so saving it gives no warning.
static class MapRules
{
	public const String FileName = "MapRules.txt";

	/// Whether the game has rules. Without them every scene can be a map.
	public static bool Exists => Assets.FileExists(FileName);

	/// Reads the rules, and the scenes (project paths) that are not maps.
	public static void Load(List<MapRule> rules, List<String> ignored)
	{
		let text = scope String();
		if (!Assets.ReadText(FileName, text))
			return;
		for (var line in text.Split('\n'))
		{
			line.Trim();
			if (line.IsEmpty || line.StartsWith('#'))
				continue;
			if (line.StartsWith("ignore "))
			{
				var path = line.Substring(7);
				path.Trim();
				ignored?.Add(new String(path));
				continue;
			}
			if (!line.StartsWith("need ") && !line.StartsWith("most "))
			{
				Log.Warning(scope $"{FileName}: \"{line}\" is not a rule (need, most or ignore).");
				continue;
			}
			var rest = line.Substring(5);
			let rule = new MapRule();
			rule.AtMost = line.StartsWith("most ");
			let quote = rest.IndexOf('"');
			if (quote >= 0)
			{
				var what = rest.Substring(quote + 1);
				if (what.EndsWith('"'))
					what.RemoveFromEnd(1);
				rule.What.Set(what);
				rest = rest.Substring(0, quote);
			}
			let words = scope List<StringView>();
			for (let word in rest.Split(' ', .RemoveEmptyEntries))
				words.Add(word);
			if (words.Count == 2 || words.Count == 5)
			{
				if (int32.Parse(words[0]) case .Ok(let count))
					rule.Count = count;
				else
					words.Clear();
			}
			if (words.Count != 2 && words.Count != 5)
			{
				Log.Warning(scope $"{FileName}: \"{line}\" should be need (or most) <count> <component> [<field> <compare> <number>] \"<what>\".");
				delete rule;
				continue;
			}
			rule.Component.Set(words[1]);
			if (words.Count == 5)
			{
				rule.Field.Set(words[2]);
				rule.Compare.Set(words[3]);
				rule.Value = Number(words[4]);
			}
			if (rule.What.IsEmpty)
				rule.What.Set(rule.Component);
			rules.Add(rule);
		}
	}

	/// Whether a scene (a project path, or a full path inside the project) is one the rules say is not a map.
	public static bool Ignores(StringView scenePath)
	{
		let relative = Assets.MakeRelative(scenePath, .. scope .());
		let rules = scope List<MapRule>();
		let ignored = scope List<String>();
		defer
		{
			ClearAndDeleteItems!(rules);
			ClearAndDeleteItems!(ignored);
		}
		Load(rules, ignored);
		for (let path in ignored)
		{
			if (path == relative)
				return true;
		}
		return false;
	}

	/// Adds "ignore <scene>" to the project's MapRules.txt, so saving that scene no longer warns. For the editor.
	public static Result<void> Ignore(StringView scenePath)
	{
		let relative = Assets.MakeRelative(scenePath, .. scope .());
		let file = scope $"{Assets.ProjectPath}/{FileName}";
		let text = scope String();
		if (System.IO.File.Exists(file))
			Try!(System.IO.File.ReadAllText(file, text));
		if (!text.IsEmpty && !text.EndsWith('\n'))
			text.Append('\n');
		text.AppendF("ignore {}\n", relative);
		return System.IO.File.WriteAllText(file, text);
	}

	/// Adds a line to problems for each rule the scene (as saved text) breaks: "It needs at least 4 spawn points and
	/// has 2."
	public static void Check(StringView sceneText, List<String> problems)
	{
		let rules = scope List<MapRule>();
		defer
		{
			ClearAndDeleteItems!(rules);
		}
		Load(rules, null);
		for (let rule in rules)
		{
			let found = Count(sceneText, rule);
			if (rule.AtMost && found > rule.Count)
				problems.Add(new $"It can have at most {rule.Count} {rule.What} and has {found}.");
			else if (!rule.AtMost && found < rule.Count)
				problems.Add(new $"It needs at least {rule.Count} {rule.What} and has {found}.");
		}
	}

	/// How many of the rule's components the scene has (those passing its field test, if it has one).
	public static int Count(StringView sceneText, MapRule rule)
	{
		let fallback = scope String();
		if (!rule.Field.IsEmpty)
			DefaultValue(rule.Component, rule.Field, fallback);
		int count = 0;
		bool inside = false;
		bool seenField = false;
		double value = 0;
		for (var line in sceneText.Split('\n'))
		{
			line.TrimEnd();
			let starts = line.StartsWith("component ") || line.StartsWith("object ");
			if (starts && inside)
			{
				if (rule.Field.IsEmpty || rule.Passes(seenField ? value : Number(fallback)))
					count++;
				inside = false;
			}
			if (line.StartsWith("component "))
			{
				var type = line.Substring(10);
				let space = type.IndexOf(' ');
				if (space >= 0)
					type = type.Substring(0, space);
				inside = type == rule.Component;
				seenField = false;
			}
			else if (inside && line.StartsWith("field ") && !rule.Field.IsEmpty)
			{
				var rest = line.Substring(6);
				if (rest.StartsWith(rule.Field) && rest.Length > rule.Field.Length && rest[rule.Field.Length] == ' ')
				{
					value = Number(rest.Substring(rule.Field.Length + 1));
					seenField = true;
				}
			}
		}
		if (inside && (rule.Field.IsEmpty || rule.Passes(seenField ? value : Number(fallback))))
			count++;
		return count;
	}

	/// A field's value on a new component of the type, as the scene file would write it. Empty if the game has no
	/// such component or field.
	static void DefaultValue(StringView typeName, StringView fieldName, String text)
	{
		// A built-in component (a handle): its data's field initializers.
		if (let handle = HandleComponents.Find(typeName))
		{
			let fields = scope List<FieldRef>();
			DataComponents.GetFields(handle.dataType, handle.defaults.Ptr, fields);
			for (let field in fields)
			{
				if (field.name == fieldName)
				{
					SceneSerializer.WriteValue(field, text);
					return;
				}
			}
			return;
		}
		let info = ComponentRegistry.Find(typeName);
		if (info == null)
			return;
		let component = ComponentRegistry.Create(info.type);
		if (component == null)
			return;
		defer delete component;
		let fields = scope List<FieldRef>();
		ComponentRegistry.GetFields(component, fields);
		for (let field in fields)
		{
			if (field.name == fieldName)
			{
				SceneSerializer.WriteValue(field, text);
				return;
			}
		}
	}

	/// The first number in a value ("3", "-1", "0.5 0 0"); 0 if there is none.
	static double Number(StringView value)
	{
		var word = value;
		word.Trim();
		let space = word.IndexOf(' ');
		if (space >= 0)
			word = word.Substring(0, space);
		if (word == "true")
			return 1;
		if (double.Parse(word) case .Ok(let number))
			return number;
		return 0;
	}
}
